import Foundation

// v1.73 M02: mesh preprocessing before rigging. Checks the mesh, finds
// separate pieces (likely rigid accessories), normalises axes and scale,
// and reduces very dense meshes. Never edits the source file: results are
// copies. Pure Swift.

struct MeshAnalysis: Codable, Equatable, Sendable {
    enum PoseType: String, Codable, Sendable { case tPose, aPose, armsDown, unknown
        var title: String {
            switch self {
            case .tPose: "T-Pose"; case .aPose: "A-Pose"
            case .armsDown: L10n.t("手臂下垂", "Arms down"); case .unknown: L10n.t("非标准姿势", "Non-standard pose")
            }
        }
    }
    var vertices: Int
    var triangles: Int
    var degenerateTriangles: Int
    var duplicateTriangles: Int
    var nonManifoldEdges: Int
    var boundaryEdges: Int
    var invalidNormals: Int
    var components: Int
    /// Vertex count of every piece, largest first.
    var componentSizes: [Int]
    var boundsMin: [Float]
    var boundsMax: [Float]
    var center: [Float]
    var height: Float
    /// Mean edge length (scale for thresholds).
    var meanEdge: Float
    /// 0…1: how mirror-symmetric the model is about x = centre.
    var symmetry: Float

    var watertight: Bool { boundaryEdges == 0 && nonManifoldEdges == 0 }
    var issues: [String] {
        var list: [String] = []
        if degenerateTriangles > 0 { list.append(L10n.t("退化三角形 \(degenerateTriangles) 个", "\(degenerateTriangles) degenerate triangles")) }
        if duplicateTriangles > 0 { list.append(L10n.t("重复面 \(duplicateTriangles) 个", "\(duplicateTriangles) duplicate faces")) }
        if nonManifoldEdges > 0 { list.append(L10n.t("非流形边 \(nonManifoldEdges) 条", "\(nonManifoldEdges) non-manifold edges")) }
        if invalidNormals > 0 { list.append(L10n.t("无效法线 \(invalidNormals) 个", "\(invalidNormals) invalid normals")) }
        if components > 1 { list.append(L10n.t("由 \(components) 块独立网格组成", "Made of \(components) separate pieces")) }
        return list
    }
}

enum MeshAnalyzer {
    /// Recommended upper bound before rigging locally (spec: 150,000).
    static let triangleLimit = 150_000

    static func analyze(_ mesh: GeneratedMesh) -> MeshAnalysis {
        let n = mesh.vertexCount, t = mesh.triangleCount
        var degenerate = 0, duplicates = 0
        var faces = Set<[UInt32]>()
        var edgeUse: [UInt64: Int] = [:]
        edgeUse.reserveCapacity(t * 3)
        var edgeSum: Double = 0, edgeCount = 0
        for k in 0..<t {
            let a = mesh.indices[k * 3], b = mesh.indices[k * 3 + 1], c = mesh.indices[k * 3 + 2]
            if a == b || b == c || a == c || area(mesh, Int(a), Int(b), Int(c)) < 1e-12 { degenerate += 1; continue }
            if !faces.insert([a, b, c].sorted()).inserted { duplicates += 1; continue }
            for (u, v) in [(a, b), (b, c), (c, a)] {
                edgeUse[key(u, v), default: 0] += 1
                edgeSum += Double(distance(mesh, Int(u), Int(v))); edgeCount += 1
            }
        }
        let nonManifold = edgeUse.values.filter { $0 > 2 }.count
        let boundary = edgeUse.values.filter { $0 == 1 }.count
        var invalidNormals = 0
        for v in 0..<n {
            let x = mesh.normals[v * 3], y = mesh.normals[v * 3 + 1], z = mesh.normals[v * 3 + 2]
            let l = (x * x + y * y + z * z).squareRoot()
            if !l.isFinite || abs(l - 1) > 0.05 { invalidNormals += 1 }
        }
        let comps = components(mesh)
        let sizes = comps.sizes.sorted(by: >)
        let b = mesh.bounds
        let center = (0..<3).map { (b.min[$0] + b.max[$0]) / 2 }
        return MeshAnalysis(vertices: n, triangles: t, degenerateTriangles: degenerate, duplicateTriangles: duplicates, nonManifoldEdges: nonManifold,
                            boundaryEdges: boundary, invalidNormals: invalidNormals, components: sizes.count, componentSizes: Array(sizes.prefix(32)),
                            boundsMin: b.min, boundsMax: b.max, center: center, height: b.max[1] - b.min[1],
                            meanEdge: edgeCount > 0 ? Float(edgeSum / Double(edgeCount)) : 0, symmetry: symmetry(mesh, centerX: center[0]))
    }

    /// Connected pieces: label per vertex and size per label.
    static func components(_ mesh: GeneratedMesh) -> (labels: [Int], sizes: [Int]) {
        var parent = Array(0..<mesh.vertexCount)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        for k in 0..<mesh.triangleCount {
            let a = find(Int(mesh.indices[k * 3])), b = find(Int(mesh.indices[k * 3 + 1])), c = find(Int(mesh.indices[k * 3 + 2]))
            parent[b] = a; parent[find(c)] = a
        }
        var label = [Int](repeating: -1, count: mesh.vertexCount), map: [Int: Int] = [:], sizes: [Int] = []
        for v in 0..<mesh.vertexCount {
            let r = find(v)
            if let l = map[r] { label[v] = l; sizes[l] += 1 } else { map[r] = sizes.count; label[v] = sizes.count; sizes.append(1) }
        }
        return (label, sizes)
    }

    /// Copy with degenerate and duplicate triangles removed and normals
    /// recomputed where missing.
    static func cleaned(_ mesh: GeneratedMesh) -> GeneratedMesh {
        var out = mesh
        var faces = Set<[UInt32]>(), indices: [UInt32] = []
        for k in 0..<mesh.triangleCount {
            let a = mesh.indices[k * 3], b = mesh.indices[k * 3 + 1], c = mesh.indices[k * 3 + 2]
            guard a != b, b != c, a != c, area(mesh, Int(a), Int(b), Int(c)) >= 1e-12, faces.insert([a, b, c].sorted()).inserted else { continue }
            indices += [a, b, c]
        }
        out.indices = indices
        let badNormals = (0..<mesh.vertexCount).contains { v in
            let x = mesh.normals[v * 3], y = mesh.normals[v * 3 + 1], z = mesh.normals[v * 3 + 2]
            return !(x * x + y * y + z * z).isFinite || x * x + y * y + z * z < 0.5
        }
        if badNormals || mesh.normals.count != mesh.positions.count { out.computeNormals() }
        return out
    }

    /// Feet at y = 0, centred on x / z, height 1 (the rigging frame).
    /// Returns the copy and the transform back to the source frame.
    static func rigFrame(_ mesh: GeneratedMesh) -> (mesh: GeneratedMesh, scale: Float, offset: [Float]) {
        let b = mesh.bounds
        let h = max(1e-6, b.max[1] - b.min[1])
        let offset = [(b.min[0] + b.max[0]) / 2, b.min[1], (b.min[2] + b.max[2]) / 2]
        var out = mesh
        for v in 0..<mesh.vertexCount { for a in 0..<3 { out.positions[v * 3 + a] = (mesh.positions[v * 3 + a] - offset[a]) / h } }
        return (out, h, offset)
    }

    /// Vertex-clustering simplification for meshes above the limit. Keeps
    /// UVs of the first vertex in each cell (texture seams may blur).
    static func simplified(_ mesh: GeneratedMesh, targetTriangles: Int) -> GeneratedMesh {
        guard mesh.triangleCount > targetTriangles, targetTriangles > 0 else { return mesh }
        let b = mesh.bounds
        let span = max(1e-6, (0..<3).map { b.max[$0] - b.min[$0] }.max()!)
        var cells = Int((Double(targetTriangles) / 2).squareRoot()) * 2
        var result = mesh
        for _ in 0..<6 {
            let size = span / Float(max(8, cells))
            var map: [Int64: UInt32] = [:], remap = [UInt32](repeating: 0, count: mesh.vertexCount)
            var positions: [Float] = [], uvs: [Float] = [], counts: [Float] = []
            for v in 0..<mesh.vertexCount {
                let q = (0..<3).map { Int64(((mesh.positions[v * 3 + $0] - b.min[$0]) / size).rounded(.down)) }
                let k = q[0] &* 1_000_003 &+ q[1] &* 1_009 &+ q[2]
                if let id = map[k] {
                    remap[v] = id
                    let o = Int(id) * 3
                    for a in 0..<3 { positions[o + a] += mesh.positions[v * 3 + a] }
                    counts[Int(id)] += 1
                } else {
                    let id = UInt32(counts.count)
                    map[k] = id; remap[v] = id
                    positions += [mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2]]
                    uvs += [mesh.uvs[v * 2], mesh.uvs[v * 2 + 1]]
                    counts.append(1)
                }
            }
            for i in 0..<counts.count { for a in 0..<3 { positions[i * 3 + a] /= counts[i] } }
            var indices: [UInt32] = [], faces = Set<[UInt32]>()
            for t in 0..<mesh.triangleCount {
                let a = remap[Int(mesh.indices[t * 3])], c1 = remap[Int(mesh.indices[t * 3 + 1])], c2 = remap[Int(mesh.indices[t * 3 + 2])]
                guard a != c1, c1 != c2, a != c2, faces.insert([a, c1, c2].sorted()).inserted else { continue }
                indices += [a, c1, c2]
            }
            var out = GeneratedMesh(positions: positions, normals: [], uvs: uvs, indices: indices)
            out.computeNormals()
            result = out
            if out.triangleCount <= targetTriangles { break }
            cells = Int(Double(cells) * 0.8)
        }
        return result
    }

    // MARK: Helpers

    static func key(_ a: UInt32, _ b: UInt32) -> UInt64 { a < b ? UInt64(a) << 32 | UInt64(b) : UInt64(b) << 32 | UInt64(a) }
    static func distance(_ m: GeneratedMesh, _ a: Int, _ b: Int) -> Float {
        let dx = m.positions[a * 3] - m.positions[b * 3], dy = m.positions[a * 3 + 1] - m.positions[b * 3 + 1], dz = m.positions[a * 3 + 2] - m.positions[b * 3 + 2]
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
    static func area(_ m: GeneratedMesh, _ a: Int, _ b: Int, _ c: Int) -> Float {
        let p = m.positions
        let u = (p[b * 3] - p[a * 3], p[b * 3 + 1] - p[a * 3 + 1], p[b * 3 + 2] - p[a * 3 + 2])
        let v = (p[c * 3] - p[a * 3], p[c * 3 + 1] - p[a * 3 + 1], p[c * 3 + 2] - p[a * 3 + 2])
        let x = u.1 * v.2 - u.2 * v.1, y = u.2 * v.0 - u.0 * v.2, z = u.0 * v.1 - u.1 * v.0
        return 0.5 * (x * x + y * y + z * z).squareRoot()
    }

    /// Share of sampled vertices whose mirror (x → 2c − x) lies near the surface.
    static func symmetry(_ mesh: GeneratedMesh, centerX: Float) -> Float {
        let n = mesh.vertexCount
        guard n > 0 else { return 0 }
        let b = mesh.bounds
        let cell = max(1e-4, (b.max[1] - b.min[1]) / 40)
        var grid = Set<Int64>()
        func k(_ x: Float, _ y: Float, _ z: Float) -> Int64 {
            Int64((x / cell).rounded(.down)) &* 73_856_093 ^ Int64((y / cell).rounded(.down)) &* 19_349_663 ^ Int64((z / cell).rounded(.down)) &* 83_492_791
        }
        for v in 0..<n { grid.insert(k(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2])) }
        var hits = 0, total = 0
        for v in stride(from: 0, to: n, by: max(1, n / 4000)) {
            let x = 2 * centerX - mesh.positions[v * 3], y = mesh.positions[v * 3 + 1], z = mesh.positions[v * 3 + 2]
            total += 1
            var found = false
            for dx in [-cell, 0, cell] where !found { for dz in [-cell, 0, cell] where !found { if grid.contains(k(x + dx, y, z + dz)) { found = true } } }
            if found { hits += 1 }
        }
        return Float(hits) / Float(max(1, total))
    }
}
