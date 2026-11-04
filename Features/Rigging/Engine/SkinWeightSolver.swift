import Foundation

// v1.73 M04: automatic skin weights on the CPU (correct first; a Metal
// version can follow). Each bone grows outward over the mesh surface
// (geodesic distance, so an arm resting on the torso does not pull torso
// vertices), weights fall off smoothly with the distance difference, a
// few diffusion passes soften the joints (extra at shoulders, elbows,
// hips and knees), and each vertex keeps its 4 strongest joints,
// normalised. Small separate pieces (accessories) follow one joint rigidly.

struct SkinSolverOptions: Equatable, Sendable {
    /// Blend width at joints (model units; the model is 1 tall).
    var falloff: Float = 0.018
    var smoothingPasses = 2
    var jointFocusPasses = 4
    /// Pieces below this share of vertices are treated as rigid accessories.
    var rigidPieceShare: Float = 0.015
    var rigidAccessories = true
    /// How much depth (z) counts when deciding which bone owns a vertex.
    var depthWeight: Float = 0.35
    /// A vertex seeds a bone only when it is this much nearer to it than to any other.
    var ownership: Float = 0.7
    /// Bones may only own vertices in the same horizontal body piece.
    var crossSectionVisibility = true
    /// Per-joint influence scale (1 = default; >1 reaches further).
    var influenceScale: [String: Float] = [:]
}

enum SkinWeightSolver {
    /// Joints that carry weights (end joints only mark bone tips).
    static func bones(_ skeleton: SkeletonDefinition) -> [(joint: Int, tip: Int)] {
        skeleton.joints.indices.compactMap { j in
            guard !skeleton.joints[j].semanticTag.isEnd else { return nil }
            let children = skeleton.children(j)
            guard !children.isEmpty else { return nil }
            let preferred: JointTag? = switch skeleton.joints[j].semanticTag { case .pelvis: .spine; case .chest: .neck; default: nil }
            let tip = preferred.flatMap { tag in children.first { skeleton.joints[$0].semanticTag == tag } } ?? children[0]
            return (j, tip)
        }
    }

    /// Unique edges as an adjacency list with lengths.
    static func adjacency(_ mesh: GeneratedMesh, depthWeight: Float = 1) -> [[(Int32, Float)]] {
        var adj = [[(Int32, Float)]](repeating: [], count: mesh.vertexCount)
        // Seams: vertices at the same position are joined at zero length.
        let weld = MeshAnalyzer.weldMap(mesh)
        for v in 0..<mesh.vertexCount where weld[v] != v { adj[v].append((Int32(weld[v]), 0)); adj[weld[v]].append((Int32(v), 0)) }
        var seen = Set<UInt64>()
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[t * 3], b = mesh.indices[t * 3 + 1], c = mesh.indices[t * 3 + 2]
            for (u, v) in [(a, b), (b, c), (c, a)] where u != v && seen.insert(MeshAnalyzer.key(u, v)).inserted {
                let p = mesh.positions, i = Int(u) * 3, j = Int(v) * 3
                let dx = p[i] - p[j], dy = p[i + 1] - p[j + 1], dz = (p[i + 2] - p[j + 2]) * depthWeight
                let l = (dx * dx + dy * dy + dz * dz).squareRoot()
                adj[Int(u)].append((Int32(v), l)); adj[Int(v)].append((Int32(u), l))
            }
        }
        return adj
    }

    static func segmentDistance(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a, l2 = (ab * ab).sum()
        let t = l2 > 0 ? min(1, max(0, ((p - a) * ab).sum() / l2)) : 0
        return rigLength(p - (a + ab * t))
    }

    static func solve(_ mesh: GeneratedMesh, skeleton: SkeletonDefinition, options: SkinSolverOptions = SkinSolverOptions(),
                      cancelled: () -> Bool = { false }) throws -> SkinInfluences {
        let n = mesh.vertexCount
        let boneList = bones(skeleton)
        let B = boneList.count
        guard n > 0, B > 0 else { throw CancellationError() }
        let world = skeleton.worldRest.map(\.origin)
        func point(_ v: Int) -> SIMD3<Float> { SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2]) }

        // Distance of every vertex to every bone segment. Depth counts
        // less: relief models are slabs whose front surface is far from
        // the centre line, and limbs are told apart mostly across the view.
        let squash = SIMD3<Float>(1, 1, options.depthWeight)
        var euclid = [Float](repeating: 0, count: n * B)
        for v in 0..<n {
            let p = point(v) * squash
            for (k, bone) in boneList.enumerated() { euclid[v * B + k] = segmentDistance(p, world[bone.joint] * squash, world[bone.tip] * squash) }
        }
        if cancelled() { throw CancellationError() }

        // Seeds: vertices clearly owned by one bone (nearest, and well
        // nearer than the second nearest).
        let adj = adjacency(mesh, depthWeight: options.depthWeight)
        // Bones joined parent-to-child may share vertices; any other bone
        // must be clearly farther away for a vertex to seed.
        var related = [[Bool]](repeating: [Bool](repeating: false, count: B), count: B)
        for a in 0..<B { for b in 0..<B {
            let ja = boneList[a].joint, jb = boneList[b].joint
            related[a][b] = a == b || skeleton.parentIndex(ja) == jb || skeleton.parentIndex(jb) == ja
        } }
        // A bone can only own vertices of the body piece it runs through:
        // in the horizontal cut at the vertex, the bone's nearest point
        // must fall inside the same piece (a hanging arm does not own the
        // side of the torso next to it).
        let cuts = JointEstimator.slices(mesh, gap: 0.004)
        func visible(_ v: Int, _ b: Int) -> Bool {
            guard options.crossSectionVisibility else { return true }
            let p = point(v)
            let s = min(cuts.count - 1, max(0, Int(p.y * Float(cuts.count))))
            guard let piece = cuts[s].pieces.first(where: { p.x >= $0.minX - 0.006 && p.x <= $0.maxX + 0.006 && p.z >= $0.minZ - 0.006 && p.z <= $0.maxZ + 0.006 }) else { return true }
            let a = world[boneList[b].joint], c = world[boneList[b].tip]
            let ab = c - a, l2 = (ab * ab).sum()
            let t = l2 > 0 ? min(1, max(0, ((p - a) * ab).sum() / l2)) : 0
            let q = a + ab * t
            // Only judge when the nearest bone point is near this cut.
            guard abs(q.y - p.y) < 0.05 else { return true }
            return q.x >= piece.minX - 0.01 && q.x <= piece.maxX + 0.01 && q.z >= piece.minZ - 0.02 && q.z <= piece.maxZ + 0.02
        }
        var owner = [Int](repeating: -1, count: n)
        for v in 0..<n {
            var order = Array(0..<B)
            order.sort { euclid[v * B + $0] < euclid[v * B + $1] }
            guard let k = order.first(where: { visible(v, $0) }) else { continue }
            let best = euclid[v * B + k]
            var other = Float.infinity
            for b in order where !related[k][b] && visible(v, b) { other = euclid[v * B + b]; break }
            if best <= other * options.ownership { owner[v] = k }
        }
        var geodesic = [Float](repeating: .infinity, count: n * B)
        for k in 0..<B {
            if cancelled() { throw CancellationError() }
            var heap = MinHeap()
            for v in 0..<n where owner[v] == k {
                let d = euclid[v * B + k]
                geodesic[v * B + k] = d; heap.push(d, Int32(v))
            }
            while let (d, v) = heap.pop() {
                let vi = Int(v)
                guard d <= geodesic[vi * B + k] else { continue }
                for (u, l) in adj[vi] {
                    let nd = d + l
                    if nd < geodesic[Int(u) * B + k] { geodesic[Int(u) * B + k] = nd; heap.push(nd, u) }
                }
            }
        }

        // Rigid accessories: small separate pieces follow their nearest bone.
        let comps = MeshAnalyzer.components(mesh)
        let largest = comps.sizes.enumerated().max { $0.element < $1.element }?.offset ?? 0
        var rigid = [Int](repeating: -1, count: n)
        if options.rigidAccessories {
            for (label, size) in comps.sizes.enumerated() where label != largest && Float(size) < Float(n) * options.rigidPieceShare {
                let members = (0..<n).filter { comps.labels[$0] == label }
                var sum = SIMD3<Float>.zero
                for v in members { sum += point(v) }
                let centre = sum / Float(members.count)
                let bone = (0..<B).min { segmentDistance(centre, world[boneList[$0].joint], world[boneList[$0].tip]) < segmentDistance(centre, world[boneList[$1].joint], world[boneList[$1].tip]) } ?? 0
                for v in members { rigid[v] = bone }
            }
        }

        // Weights from the distance difference to the nearest bone.
        var dense = [Float](repeating: 0, count: n * B)
        for v in 0..<n {
            if rigid[v] >= 0 { dense[v * B + rigid[v]] = 1; continue }
            var row = (0..<B).map { k -> Float in
                let d = geodesic[v * B + k]
                let scale = options.influenceScale[skeleton.joints[boneList[k].joint].jointID] ?? 1
                return d.isFinite ? d / max(0.2, scale) : euclid[v * B + k] * 4 / max(0.2, scale)
            }
            let m = row.min() ?? 0
            for k in 0..<B {
                let x = (row[k] - m) / options.falloff
                row[k] = x < 3 ? exp(-x * x) : 0
            }
            for k in 0..<B { dense[v * B + k] = row[k] }
        }

        // Diffusion passes, extra around the bending joints.
        let focusTags: Set<JointTag> = [.rightUpperArm, .leftUpperArm, .rightForearm, .leftForearm, .rightThigh, .leftThigh, .rightShin, .leftShin]
        let focusPoints = skeleton.joints.indices.filter { focusTags.contains(skeleton.joints[$0].semanticTag) }.map { world[$0] }
        let focus = (0..<n).map { v in focusPoints.contains { rigLength(point(v) - $0) < 0.07 } }
        for pass in 0..<(options.smoothingPasses + options.jointFocusPasses) {
            if cancelled() { throw CancellationError() }
            let onlyFocus = pass >= options.smoothingPasses
            var next = dense
            for v in 0..<n where rigid[v] < 0 && (!onlyFocus || focus[v]) && !adj[v].isEmpty {
                for k in 0..<B {
                    var s: Float = 0
                    for (u, _) in adj[v] { s += dense[Int(u) * B + k] }
                    next[v * B + k] = 0.5 * dense[v * B + k] + 0.5 * s / Float(adj[v].count)
                }
            }
            dense = next
        }

        // Keep 4, normalise.
        var skin = SkinInfluences(count: n)
        for v in 0..<n {
            let top = strongest(dense, offset: v * B, count: B)
            if top.isEmpty {
                var k = 0
                for b in 1..<B where euclid[v * B + b] < euclid[v * B + k] { k = b }
                skin.joints[v * 4] = UInt8(boneList[k].joint); skin.weights[v * 4] = 1
                continue
            }
            write(top.map { (boneList[$0.index].joint, $0.weight) }, into: &skin, vertex: v)
        }
        unifySeams(&skin, mesh: mesh)
        return skin
    }

    /// Extra diffusion around `joints` only (automatic repair).
    static func relaxed(_ skin: SkinInfluences, mesh: GeneratedMesh, skeleton: SkeletonDefinition, around joints: [Int], radius: Float = 0.08, passes: Int = 4) -> SkinInfluences {
        let n = mesh.vertexCount, J = skeleton.joints.count
        let adj = adjacency(mesh)
        let world = skeleton.worldRest.map(\.origin)
        func point(_ v: Int) -> SIMD3<Float> { SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2]) }
        let mask = (0..<n).map { v in joints.contains { rigLength(point(v) - world[$0]) < radius } }
        var dense = [Float](repeating: 0, count: n * J)
        for v in 0..<n { for (j, w) in skin.influences(v) { dense[v * J + j] = w } }
        for _ in 0..<passes {
            var next = dense
            for v in 0..<n where mask[v] && !adj[v].isEmpty {
                for j in 0..<J {
                    var s: Float = 0
                    for (u, _) in adj[v] { s += dense[Int(u) * J + j] }
                    next[v * J + j] = 0.5 * dense[v * J + j] + 0.5 * s / Float(adj[v].count)
                }
            }
            dense = next
        }
        var out = SkinInfluences(count: n)
        for v in 0..<n {
            let top = strongest(dense, offset: v * J, count: J)
            if top.isEmpty { out.joints[v * 4] = skin.joints[v * 4]; out.weights[v * 4] = 1; continue }
            write(top.map { ($0.index, $0.weight) }, into: &out, vertex: v)
        }
        unifySeams(&out, mesh: mesh)
        return out
    }

    /// Split copies of a vertex get exactly the same weights (no cracks).
    static func unifySeams(_ skin: inout SkinInfluences, mesh: GeneratedMesh) {
        let weld = MeshAnalyzer.weldMap(mesh)
        for v in 0..<mesh.vertexCount where weld[v] != v {
            for k in 0..<4 { skin.joints[v * 4 + k] = skin.joints[weld[v] * 4 + k]; skin.weights[v * 4 + k] = skin.weights[weld[v] * 4 + k] }
        }
    }

    /// The 4 largest positive entries of `row[offset ..< offset + count]`.
    static func strongest(_ row: [Float], offset: Int, count: Int) -> [(index: Int, weight: Float)] {
        var top: [(index: Int, weight: Float)] = []
        for k in 0..<count {
            let w: Float = row[offset + k]
            guard w > 1e-4 else { continue }
            top.append((index: k, weight: w))
        }
        top.sort { $0.weight > $1.weight }
        return Array(top.prefix(SkinInfluences.maxInfluences))
    }

    /// Writes normalised influences (sum exactly 1).
    static func write(_ entries: [(Int, Float)], into skin: inout SkinInfluences, vertex v: Int) {
        var sum: Float = 0
        for e in entries { sum += e.1 }
        guard sum > 0 else { return }
        var total: Float = 0
        for (slot, e) in entries.enumerated() {
            let w = e.1 / sum
            skin.joints[v * 4 + slot] = UInt8(e.0); skin.weights[v * 4 + slot] = w
            total += w
        }
        skin.weights[v * 4] += 1 - total
    }

    /// Linear blend skinning: v' = Σ wᵢ Bᵢ v.
    static func deform(_ mesh: GeneratedMesh, skin: SkinInfluences, matrices: [RigXform]) -> (positions: [Float], normals: [Float]) {
        var positions = mesh.positions, normals = mesh.normals
        for v in 0..<min(mesh.vertexCount, skin.count) {
            let p = SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2])
            let nv = SIMD3(mesh.normals[v * 3], mesh.normals[v * 3 + 1], mesh.normals[v * 3 + 2])
            var q = SIMD3<Float>.zero, m = SIMD3<Float>.zero
            for k in 0..<4 {
                let j = skin.joints[v * 4 + k]
                guard j != 255 else { continue }
                let w = skin.weights[v * 4 + k], x = matrices[Int(j)]
                q += x.point(p) * w; m += x.direction(nv) * w
            }
            let l = rigLength(m)
            if l > 0 { m /= l }
            positions[v * 3] = q.x; positions[v * 3 + 1] = q.y; positions[v * 3 + 2] = q.z
            normals[v * 3] = m.x; normals[v * 3 + 1] = m.y; normals[v * 3 + 2] = m.z
        }
        return (positions, normals)
    }
}
