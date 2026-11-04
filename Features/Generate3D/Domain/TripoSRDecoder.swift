import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// v1.75: the second half of TripoSR (VAST AI / Stability AI, MIT licence)
// running on the phone. The Core ML encoder turns a picture into a
// "triplane" (3 planes × 40 channels × 64 × 64); this file reads that
// field the way TripoSR does (bilinear grid_sample with align_corners =
// false and zero padding, features concatenated per plane), runs the
// small decoder MLP (120 → 64 ×9 → 4, SiLU; density = exp(x − 1), colour
// = sigmoid), extracts the surface at density 25 with surface nets and
// colours every vertex. TripoSR is z-up; meshes come out y-up, front +z.
// Pure Swift (Accelerate on Apple platforms).

struct TripoSRDecoder: Sendable {
    struct Layer: Sendable { var outputs: Int; var inputs: Int; var weights: [Float]; var bias: [Float] }
    var layers: [Layer]
    var radius: Float = 0.87
    var densityBias: Float = -1
    var threshold: Float = 25
    var channels = 40
    var planeSize = 64

    enum LoadError: Error, Equatable, LocalizedError {
        case badFile(String)
        var errorDescription: String? { L10n.t("TripoSR 解码器文件无效：", "Invalid TripoSR decoder file: ") + { if case .badFile(let w) = self { return w }; return "" }() }
    }

    // File: "TSRD", u32 version 1, f32 radius, f32 densityBias, f32 threshold,
    // u32 channels, u32 planeSize, u32 layer count, then per layer u32 out,
    // u32 in, f32 weights[out × in] (row-major, torch Linear), f32 bias[out].
    static func load(_ data: Data) throws -> TripoSRDecoder {
        let b = [UInt8](data)
        var o = 0
        func u32() throws -> Int {
            guard o + 4 <= b.count else { throw LoadError.badFile("truncated") }
            defer { o += 4 }
            return Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        func f32() throws -> Float { Float(bitPattern: UInt32(try u32())) }
        guard b.count > 8, Array(b[0..<4]) == Array("TSRD".utf8) else { throw LoadError.badFile("magic") }
        o = 4
        guard try u32() == 1 else { throw LoadError.badFile("version") }
        var d = TripoSRDecoder(layers: [])
        d.radius = try f32(); d.densityBias = try f32(); d.threshold = try f32()
        d.channels = try u32(); d.planeSize = try u32()
        let count = try u32()
        guard (1...32).contains(count), d.channels > 0, d.channels <= 256, (8...512).contains(d.planeSize) else { throw LoadError.badFile("header") }
        var previous = d.channels * 3
        for _ in 0..<count {
            let out = try u32(), inp = try u32()
            guard inp == previous, out > 0, out <= 4096 else { throw LoadError.badFile("layer shape") }
            var w = [Float](repeating: 0, count: out * inp), bias = [Float](repeating: 0, count: out)
            for i in 0..<(out * inp) { w[i] = try f32() }
            for i in 0..<out { bias[i] = try f32() }
            d.layers.append(Layer(outputs: out, inputs: inp, weights: w, bias: bias))
            previous = out
        }
        guard previous == 4 else { throw LoadError.badFile("last layer must have 4 outputs") }
        return d
    }

    func encoded() -> Data {
        var data = Data("TSRD".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func f32(_ v: Float) { var x = v.bitPattern.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        u32(1); f32(radius); f32(densityBias); f32(threshold); u32(channels); u32(planeSize); u32(layers.count)
        for l in layers { u32(l.outputs); u32(l.inputs); l.weights.forEach(f32); l.bias.forEach(f32) }
        return data
    }

    // MARK: Field

    /// TripoSR coordinates of a point in ours (y up, front +z).
    @inline(__always) static func raw(_ p: SIMD3<Float>) -> SIMD3<Float> { SIMD3(-p.z, -p.x, p.y) }

    /// Features (3 × channels) for points in TripoSR coordinates.
    func features(_ triplane: [Float], points: [SIMD3<Float>]) -> [Float] {
        let C = channels, S = planeSize, F = 3 * C
        var out = [Float](repeating: 0, count: points.count * F)
        let planeStride = C * S * S
        for (n, p) in points.enumerated() {
            let q = p / radius
            let pairs: [(Float, Float)] = [(q.x, q.y), (q.x, q.z), (q.y, q.z)]
            for plane in 0..<3 {
                // align_corners = false: pixel = ((g + 1) × size − 1) / 2.
                let px = ((pairs[plane].0 + 1) * Float(S) - 1) / 2, py = ((pairs[plane].1 + 1) * Float(S) - 1) / 2
                let x0 = Int(px.rounded(.down)), y0 = Int(py.rounded(.down))
                let fx = px - Float(x0), fy = py - Float(y0)
                let taps: [(Int, Int, Float)] = [(x0, y0, (1 - fx) * (1 - fy)), (x0 + 1, y0, fx * (1 - fy)), (x0, y0 + 1, (1 - fx) * fy), (x0 + 1, y0 + 1, fx * fy)]
                let base = plane * planeStride, dst = n * F + plane * C
                for (x, y, w) in taps where x >= 0 && y >= 0 && x < S && y < S && w > 0 {
                    let pixel = y * S + x
                    for c in 0..<C { out[dst + c] += w * triplane[base + c * S * S + pixel] }
                }
            }
        }
        return out
    }

    /// Decoder MLP on rows of features → rows of 4 (density, r, g, b raw).
    func mlp(_ input: [Float], rows: Int) -> [Float] {
        var x = input
        for (index, layer) in layers.enumerated() {
            var y = [Float](repeating: 0, count: rows * layer.outputs)
            #if canImport(Accelerate)
            // y = x · Wᵀ (x: rows × in, W: out × in).
            x.withUnsafeBufferPointer { xp in layer.weights.withUnsafeBufferPointer { wp in y.withUnsafeMutableBufferPointer { yp in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(layer.outputs), Int32(layer.inputs), 1,
                            xp.baseAddress!, Int32(layer.inputs), wp.baseAddress!, Int32(layer.inputs), 0, yp.baseAddress!, Int32(layer.outputs))
            } } }
            for r in 0..<rows { for o in 0..<layer.outputs { y[r * layer.outputs + o] += layer.bias[o] } }
            #else
            for r in 0..<rows {
                for o in 0..<layer.outputs {
                    var s = layer.bias[o]
                    let wo = o * layer.inputs, xr = r * layer.inputs
                    for i in 0..<layer.inputs { s += layer.weights[wo + i] * x[xr + i] }
                    y[r * layer.outputs + o] = s
                }
            }
            #endif
            if index < layers.count - 1 { for i in 0..<y.count { let v = y[i]; y[i] = v / (1 + exp(-v)) } } // SiLU
            x = y
        }
        return x
    }

    /// Density (after exp) and colour (after sigmoid) at points in our frame.
    func query(_ triplane: [Float], points: [SIMD3<Float>]) -> (density: [Float], color: [Float]) {
        let raw = points.map(Self.raw)
        let out = mlp(features(triplane, points: raw), rows: points.count)
        var density = [Float](repeating: 0, count: points.count), color = [Float](repeating: 0, count: points.count * 3)
        for i in 0..<points.count {
            density[i] = exp(out[i * 4] + densityBias)
            for c in 0..<3 { color[i * 3 + c] = 1 / (1 + exp(-out[i * 4 + 1 + c])) }
        }
        return (density, color)
    }

    // MARK: Mesh

    /// Surface at the density threshold on a resolution³ grid over the
    /// TripoSR cube, with colours per vertex.
    func mesh(_ triplane: [Float], resolution: Int = 128, batch: Int = 16_384, cancelled: () -> Bool = { false }) throws -> (mesh: GeneratedMesh, colors: [Float]) {
        let R = max(8, resolution)
        let step = 2 * radius / Float(R - 1)
        func point(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { SIMD3(-radius + Float(i) * step, -radius + Float(j) * step, -radius + Float(k) * step) }
        var field = [Float](repeating: 0, count: R * R * R)
        var pending: [SIMD3<Float>] = [], slots: [Int] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let d = query(triplane, points: pending).density
            for (n, slot) in slots.enumerated() { field[slot] = d[n] }
            pending.removeAll(keepingCapacity: true); slots.removeAll(keepingCapacity: true)
        }
        for k in 0..<R {
            if cancelled() { throw CancellationError() }
            for j in 0..<R { for i in 0..<R {
                pending.append(point(i, j, k)); slots.append((k * R + j) * R + i)
                if pending.count >= batch { flush() }
            } }
        }
        flush()
        let surface = SurfaceNets.extract(field, nx: R, ny: R, nz: R, iso: threshold)
        guard !surface.indices.isEmpty else { throw TripoSRError.empty }
        var mesh = GeneratedMesh()
        mesh.positions.reserveCapacity(surface.positions.count * 3)
        for g in surface.positions {
            let p: SIMD3<Float> = g * step - SIMD3(repeating: radius)
            mesh.positions += [p.x, p.y, p.z]
        }
        mesh.indices = surface.indices
        mesh.uvs = [Float](repeating: 0, count: surface.positions.count * 2)
        mesh.computeNormals()
        var colors: [Float] = []
        colors.reserveCapacity(surface.positions.count * 3)
        let vertices = (0..<mesh.vertexCount).map { SIMD3(mesh.positions[$0 * 3], mesh.positions[$0 * 3 + 1], mesh.positions[$0 * 3 + 2]) }
        var start = 0
        while start < vertices.count {
            let end = min(vertices.count, start + batch)
            colors += query(triplane, points: Array(vertices[start..<end])).color
            start = end
        }
        return (mesh, colors)
    }
}

enum TripoSRError: Error, Equatable, LocalizedError {
    case empty, modelMissing, unsupportedDevice, badOutput(String)
    var errorDescription: String? {
        switch self {
        case .empty: L10n.t("模型没有生成任何形体，请换一张主体清晰、背景干净的图片", "The model produced no shape; try a picture with a clear subject and plain background")
        case .modelMissing: L10n.t("还没有导入 TripoSR 模型文件（见「本机 AI 建模」里的说明）", "The TripoSR model files are not imported yet (see On-device AI modelling)")
        case .unsupportedDevice: L10n.t("这台 iPhone 内存不足，无法在本机运行 TripoSR（需要 8 GB 内存的机型）", "This iPhone does not have enough memory for TripoSR on device (8 GB models needed)")
        case .badOutput(let w): L10n.t("TripoSR 输出异常：", "Unexpected TripoSR output: ") + w
        }
    }
}

/// Surface nets on a scalar grid (inside where value > iso). Positions are
/// in grid units (0…n − 1 per axis).
enum SurfaceNets {
    static func extract(_ field: [Float], nx: Int, ny: Int, nz: Int, iso: Float) -> (positions: [SIMD3<Float>], indices: [UInt32]) {
        func at(_ i: Int, _ j: Int, _ k: Int) -> Float {
            guard i >= 0, j >= 0, k >= 0, i < nx, j < ny, k < nz else { return -Float.infinity }
            return field[(k * ny + j) * nx + i]
        }
        // Cells from −1 to n−1 so a surface touching the grid edge closes.
        let cx = nx + 1, cy = ny + 1, cz = nz + 1
        func cell(_ i: Int, _ j: Int, _ k: Int) -> Int { ((k + 1) * cy + (j + 1)) * cx + (i + 1) }
        var vertex = [Int32](repeating: -1, count: cx * cy * cz)
        var positions: [SIMD3<Float>] = []
        let corners: [(Int, Int, Int)] = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        for k in -1..<nz { for j in -1..<ny { for i in -1..<nx {
            var values = [Float](repeating: 0, count: 8), inside = 0
            for (n, c) in corners.enumerated() { let v = at(i + c.0, j + c.1, k + c.2); values[n] = v; if v > iso { inside += 1 } }
            guard inside > 0 && inside < 8 else { continue }
            var sum = SIMD3<Float>.zero, count: Float = 0
            for (a, b) in edges where (values[a] > iso) != (values[b] > iso) {
                let va = values[a].isFinite ? values[a] : iso - 1, vb = values[b].isFinite ? values[b] : iso - 1
                let t = min(1, max(0, (iso - va) / (vb - va)))
                let ca = corners[a], cb = corners[b]
                sum += SIMD3(Float(ca.0) + Float(cb.0 - ca.0) * t, Float(ca.1) + Float(cb.1 - ca.1) * t, Float(ca.2) + Float(cb.2 - ca.2) * t)
                count += 1
            }
            vertex[cell(i, j, k)] = Int32(positions.count)
            positions.append(SIMD3(Float(i), Float(j), Float(k)) + sum / count)
        } } }
        var indices: [UInt32] = []
        func quad(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, flip: Bool) {
            guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
            let q = [UInt32(a), UInt32(b), UInt32(c), UInt32(d)]
            indices += flip ? [q[0], q[2], q[1], q[0], q[3], q[2]] : [q[0], q[1], q[2], q[0], q[2], q[3]]
        }
        for k in -1..<nz { for j in -1..<ny { for i in -1..<nx {
            let here = at(i, j, k) > iso
            if j >= 0, k >= 0, here != (at(i + 1, j, k) > iso) {
                quad(vertex[cell(i, j - 1, k - 1)], vertex[cell(i, j, k - 1)], vertex[cell(i, j, k)], vertex[cell(i, j - 1, k)], flip: !here)
            }
            if i >= 0, k >= 0, here != (at(i, j + 1, k) > iso) {
                quad(vertex[cell(i - 1, j, k - 1)], vertex[cell(i - 1, j, k)], vertex[cell(i, j, k)], vertex[cell(i, j, k - 1)], flip: !here)
            }
            if i >= 0, j >= 0, here != (at(i, j, k + 1) > iso) {
                quad(vertex[cell(i - 1, j - 1, k)], vertex[cell(i, j - 1, k)], vertex[cell(i, j, k)], vertex[cell(i - 1, j, k)], flip: !here)
            }
        } } }
        return (positions, indices)
    }
}
