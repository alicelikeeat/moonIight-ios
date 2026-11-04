import Foundation

// Local 3D generation core (v1.67). Pure Swift, no Apple frameworks, so it
// is tested on Linux: depth field → real triangle mesh, the mesh file
// format, OBJ export, the asset manifest, and video frame quality rules.
// Nothing here pretends: a single picture becomes a depth relief (front
// surface from estimated depth, closed back and sides), never a "360°" model.

// MARK: Depth field

/// Depth and subject mask on a regular grid, row-major, top row first.
/// `nearness`: larger = closer to the camera (disparity-like), any scale.
/// `mask`: 0 … 1 subject confidence.
struct DepthField: Equatable, Sendable {
    var width: Int
    var height: Int
    var nearness: [Float]
    var mask: [Float]

    var valid: Bool { width >= 2 && height >= 2 && nearness.count == width * height && mask.count == width * height }

    /// Bilinear sample at normalised (u, v) in 0…1, v = 0 at the top.
    func sample(_ values: [Float], u: Double, v: Double) -> Float {
        let x = min(max(u, 0), 1) * Double(width - 1), y = min(max(v, 0), 1) * Double(height - 1)
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        let a = values[y0 * width + x0], b = values[y0 * width + x1], c = values[y1 * width + x0], d = values[y1 * width + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Share of the picture covered by the subject (mask ≥ threshold).
    func subjectCoverage(threshold: Float = 0.5) -> Double {
        guard !mask.isEmpty else { return 0 }
        return Double(mask.filter { $0 >= threshold }.count) / Double(mask.count)
    }

    /// Resamples both layers to a new grid (the mesh resolution).
    func resampled(width w: Int, height h: Int) -> DepthField {
        var near = [Float](repeating: 0, count: w * h), m = near
        for y in 0..<h {
            for x in 0..<w {
                let u = w > 1 ? Double(x) / Double(w - 1) : 0, v = h > 1 ? Double(y) / Double(h - 1) : 0
                near[y * w + x] = sample(nearness, u: u, v: v); m[y * w + x] = sample(mask, u: u, v: v)
            }
        }
        return DepthField(width: w, height: h, nearness: near, mask: m)
    }

    /// 3×3 box blur of the depth inside the subject (removes speckle).
    func smoothed(passes: Int = 1) -> DepthField {
        var out = self
        for _ in 0..<max(0, passes) {
            var next = out.nearness
            for y in 0..<height {
                for x in 0..<width where out.mask[y * width + x] >= 0.5 {
                    var sum: Float = 0, n: Float = 0
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, yy >= 0, xx < width, yy < height, out.mask[yy * width + xx] >= 0.5 else { continue }
                            sum += out.nearness[yy * width + xx]; n += 1
                        }
                    }
                    if n > 0 { next[y * width + x] = sum / n }
                }
            }
            out.nearness = next
        }
        return out
    }
}

// MARK: Mesh

/// Triangle mesh: positions/normals xyz, uvs (v = 0 at the bottom of the
/// picture, the RealityKit / OBJ convention), counter-clockwise triangles.
struct GeneratedMesh: Equatable, Sendable {
    var positions: [Float] = []
    var normals: [Float] = []
    var uvs: [Float] = []
    var indices: [UInt32] = []

    var vertexCount: Int { positions.count / 3 }
    var triangleCount: Int { indices.count / 3 }
    var valid: Bool {
        positions.count % 3 == 0 && normals.count == positions.count && uvs.count / 2 == vertexCount && indices.count % 3 == 0 &&
            indices.allSatisfy { Int($0) < vertexCount } && positions.allSatisfy(\.isFinite)
    }

    /// Axis-aligned bounds (min xyz, max xyz).
    var bounds: (min: [Float], max: [Float]) {
        var lo: [Float] = [.infinity, .infinity, .infinity], hi: [Float] = [-.infinity, -.infinity, -.infinity]
        for i in 0..<vertexCount { for a in 0..<3 { lo[a] = min(lo[a], positions[i * 3 + a]); hi[a] = max(hi[a], positions[i * 3 + a]) } }
        return (lo, hi)
    }

    /// Real 3D test: the model has depth, not a flat card.
    var depthExtent: Float { let b = bounds; return vertexCount == 0 ? 0 : b.max[2] - b.min[2] }

    /// Centre on the origin and scale so the tallest side is `size`.
    mutating func normalize(size: Float = 1) {
        guard vertexCount > 0 else { return }
        let b = bounds
        let center = (0..<3).map { (b.min[$0] + b.max[$0]) / 2 }
        let span = max(b.max[0] - b.min[0], b.max[1] - b.min[1], b.max[2] - b.min[2])
        guard span > 0 else { return }
        let k = size / span
        for i in 0..<vertexCount { for a in 0..<3 { positions[i * 3 + a] = (positions[i * 3 + a] - center[a]) * k } }
    }

    /// Per-vertex normals from the triangles (area weighted).
    mutating func computeNormals() {
        normals = [Float](repeating: 0, count: positions.count)
        for t in 0..<triangleCount {
            let i0 = Int(indices[t * 3]), i1 = Int(indices[t * 3 + 1]), i2 = Int(indices[t * 3 + 2])
            let p0 = point(i0), p1 = point(i1), p2 = point(i2)
            let e1 = (p1.0 - p0.0, p1.1 - p0.1, p1.2 - p0.2), e2 = (p2.0 - p0.0, p2.1 - p0.1, p2.2 - p0.2)
            let n = (e1.1 * e2.2 - e1.2 * e2.1, e1.2 * e2.0 - e1.0 * e2.2, e1.0 * e2.1 - e1.1 * e2.0)
            for i in [i0, i1, i2] { normals[i * 3] += n.0; normals[i * 3 + 1] += n.1; normals[i * 3 + 2] += n.2 }
        }
        for i in 0..<vertexCount {
            let x = normals[i * 3], y = normals[i * 3 + 1], z = normals[i * 3 + 2]
            let l = (x * x + y * y + z * z).squareRoot()
            if l > 0 { normals[i * 3] = x / l; normals[i * 3 + 1] = y / l; normals[i * 3 + 2] = z / l } else { normals[i * 3 + 2] = 1 }
        }
    }

    private func point(_ i: Int) -> (Float, Float, Float) { (positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]) }
}

/// Mesh detail levels; chosen from the device's memory and temperature.
enum GenerationQuality: String, Codable, CaseIterable, Sendable {
    case low, medium, high
    /// Grid points along the longer side of the picture.
    var gridResolution: Int { switch self { case .low: 96; case .medium: 144; case .high: 208 } }
    /// Longest side of the saved texture (1024–2048 per the spec).
    var textureSize: Int { switch self { case .low: 1024; case .medium: 1536; case .high: 2048 } }
    var title: String { switch self { case .low: L10n.t("省电", "Light"); case .medium: L10n.t("标准", "Standard"); case .high: L10n.t("精细", "Detailed") } }

    /// Physical memory in bytes and thermal level 0 (nominal) … 3 (critical).
    static func recommended(memory: UInt64, thermal: Int) -> GenerationQuality {
        if thermal >= 2 || memory < 3_000_000_000 { return .low }
        if thermal == 1 || memory < 5_500_000_000 { return .medium }
        return .high
    }
}

enum DepthMeshBuilder {
    struct Options: Equatable, Sendable {
        /// Grid points along the longer side.
        var resolution = 144
        /// Relief depth as a share of the picture height.
        var depthScale: Float = 0.35
        /// Back plate thickness behind the deepest point, share of height.
        var backThickness: Float = 0.04
        var maskThreshold: Float = 0.5
        var smoothingPasses = 2
        /// Close the model with a flat back and side walls.
        var closed = true
    }

    enum Failure: Error, Equatable { case invalidField, noSubject, tooSmall }

    /// Builds a closed depth relief from the field. The picture's aspect is
    /// kept: x right, y up, z towards the viewer, height 1 before normalising.
    static func build(_ source: DepthField, aspect: Double, options: Options = Options()) throws -> GeneratedMesh {
        guard source.valid, aspect.isFinite, aspect > 0 else { throw Failure.invalidField }
        let longer = max(8, options.resolution)
        let cols = aspect >= 1 ? longer : max(4, Int((Double(longer) * aspect).rounded()))
        let rows = aspect >= 1 ? max(4, Int((Double(longer) / aspect).rounded())) : longer
        let field = source.resampled(width: cols, height: rows).smoothed(passes: options.smoothingPasses)
        let inside = field.mask.map { $0 >= options.maskThreshold }
        let count = inside.filter { $0 }.count
        guard count > 0 else { throw Failure.noSubject }
        guard count >= 12 else { throw Failure.tooSmall }

        // Robust depth range inside the subject (2nd–98th percentile).
        let values = zip(field.nearness, inside).compactMap { $1 && $0.isFinite ? $0 : nil }.sorted()
        let lo = values[Int(Double(values.count - 1) * 0.02)], hi = values[Int(Double(values.count - 1) * 0.98)]
        let range = max(hi - lo, 1e-6)
        let width = Float(aspect), heightUnits: Float = 1
        let depth = options.depthScale * heightUnits, back = -options.backThickness * heightUnits

        var mesh = GeneratedMesh()
        var front = [Int32](repeating: -1, count: cols * rows)
        for y in 0..<rows {
            for x in 0..<cols where inside[y * cols + x] {
                let u = Float(x) / Float(cols - 1), v = Float(y) / Float(rows - 1)
                let n = min(max((field.nearness[y * cols + x] - lo) / range, 0), 1)
                front[y * cols + x] = Int32(mesh.vertexCount)
                mesh.positions += [(u - 0.5) * width, (0.5 - v) * heightUnits, n * depth]
                mesh.uvs += [u, 1 - v]
            }
        }
        // Front triangles: full quads as two triangles, three-corner quads as one.
        var edgeUse: [UInt64: Int] = [:]
        func addTriangle(_ a: Int32, _ b: Int32, _ c: Int32) {
            mesh.indices += [UInt32(a), UInt32(b), UInt32(c)]
            for (p, q) in [(a, b), (b, c), (c, a)] { edgeUse[key(p, q), default: 0] += 1 }
        }
        for y in 0..<(rows - 1) {
            for x in 0..<(cols - 1) {
                let tl = front[y * cols + x], tr = front[y * cols + x + 1], bl = front[(y + 1) * cols + x], br = front[(y + 1) * cols + x + 1]
                let valid = [tl, tr, bl, br].filter { $0 >= 0 }.count
                if valid == 4 { addTriangle(tl, bl, br); addTriangle(tl, br, tr) }
                else if valid == 3 {
                    if tl < 0 { addTriangle(tr, bl, br) } else if tr < 0 { addTriangle(tl, bl, br) }
                    else if bl < 0 { addTriangle(tl, br, tr) } else { addTriangle(tl, bl, tr) }
                }
            }
        }
        guard mesh.triangleCount > 0 else { throw Failure.tooSmall }
        let frontTriangles = mesh.triangleCount

        if options.closed {
            // Back: the same outline on a flat plate, reversed winding.
            let frontCount = mesh.vertexCount
            for i in 0..<frontCount {
                mesh.positions += [mesh.positions[i * 3], mesh.positions[i * 3 + 1], back]
                mesh.uvs += [mesh.uvs[i * 2], mesh.uvs[i * 2 + 1]]
            }
            for t in 0..<frontTriangles {
                let a = mesh.indices[t * 3], b = mesh.indices[t * 3 + 1], c = mesh.indices[t * 3 + 2]
                mesh.indices += [a + UInt32(frontCount), c + UInt32(frontCount), b + UInt32(frontCount)]
            }
            // Sides: every outline edge (used by one front triangle) becomes a wall.
            for t in 0..<frontTriangles {
                let tri = [mesh.indices[t * 3], mesh.indices[t * 3 + 1], mesh.indices[t * 3 + 2]]
                for (p, q) in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])] where edgeUse[key(Int32(p), Int32(q))] == 1 {
                    let pb = p + UInt32(frontCount), qb = q + UInt32(frontCount)
                    mesh.indices += [q, p, pb, q, pb, qb]
                }
            }
        }
        mesh.computeNormals()
        return mesh
    }

    private static func key(_ a: Int32, _ b: Int32) -> UInt64 {
        let lo = UInt64(UInt32(bitPattern: min(a, b))), hi = UInt64(UInt32(bitPattern: max(a, b)))
        return lo << 32 | hi
    }
}

// MARK: Mesh file

/// Compact binary mesh ("M3DG", version 1, little endian float32 / uint32).
enum GeneratedMeshCodec {
    static let magic: [UInt8] = Array("M3DG".utf8)

    static func encode(_ mesh: GeneratedMesh) -> Data {
        var data = Data(magic)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func floats(_ list: [Float]) { for f in list { u32(f.bitPattern) } }
        u32(1); u32(UInt32(mesh.vertexCount)); u32(UInt32(mesh.indices.count))
        floats(mesh.positions); floats(mesh.normals); floats(mesh.uvs)
        for i in mesh.indices { u32(i) }
        return data
    }

    static func decode(_ data: Data) -> GeneratedMesh? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, Array(bytes[0..<4]) == magic else { return nil }
        var offset = 4
        func u32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            let v = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4; return v
        }
        guard u32() == 1, let vertices = u32().map(Int.init), let indexCount = u32().map(Int.init),
              vertices < 50_000_000, indexCount < 150_000_000, bytes.count == 16 + (vertices * 8 + indexCount) * 4 else { return nil }
        func floats(_ n: Int) -> [Float] { (0..<n).map { _ in Float(bitPattern: u32() ?? 0) } }
        var mesh = GeneratedMesh()
        mesh.positions = floats(vertices * 3); mesh.normals = floats(vertices * 3); mesh.uvs = floats(vertices * 2)
        mesh.indices = (0..<indexCount).map { _ in u32() ?? 0 }
        return mesh.valid ? mesh : nil
    }
}

/// Wavefront OBJ + MTL text (for sharing with other 3D apps).
enum OBJWriter {
    static func obj(_ mesh: GeneratedMesh, materialFile: String, material: String = "moonlight") -> String {
        var lines = ["# Moonlight generated model", "mtllib \(materialFile)", "o model"]
        lines.reserveCapacity(mesh.vertexCount * 3 + mesh.triangleCount + 8)
        for i in 0..<mesh.vertexCount { lines.append(String(format: "v %.5f %.5f %.5f", mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2])) }
        for i in 0..<mesh.vertexCount { lines.append(String(format: "vt %.5f %.5f", mesh.uvs[i * 2], mesh.uvs[i * 2 + 1])) }
        for i in 0..<mesh.vertexCount { lines.append(String(format: "vn %.4f %.4f %.4f", mesh.normals[i * 3], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2])) }
        lines.append("usemtl \(material)")
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[t * 3] + 1, b = mesh.indices[t * 3 + 1] + 1, c = mesh.indices[t * 3 + 2] + 1
            lines.append("f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
    static func mtl(texture: String, material: String = "moonlight") -> String {
        "newmtl \(material)\nKa 1 1 1\nKd 1 1 1\nKs 0 0 0\nd 1\nillum 1\nmap_Kd \(texture)\n"
    }
}

// MARK: Manifest

/// What a generated model is and what it can do. Capabilities are only
/// marked true after they really work (spec: no fake completion).
struct Generated3DManifest: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case image, video }
    enum Geometry: String, Codable, Sendable {
        /// Front surface from depth, closed back: not a full 360° model.
        case depthRelief
        /// Multi-view photogrammetry (Object Capture).
        case photogrammetry
        var title: String {
            switch self {
            case .depthRelief: L10n.t("深度立体模型（正面为真实深度，背面为封闭平板，非完整 360°）", "Depth relief (real depth on the front, closed flat back; not a full 360° model)")
            case .photogrammetry: L10n.t("多视角重建模型", "Multi-view reconstruction")
            }
        }
    }
    enum DepthSource: String, Codable, Sendable { case cameraDepth, depthAnythingV2, objectCapture
        var title: String {
            switch self {
            case .cameraDepth: L10n.t("照片自带的相机深度", "Camera depth stored in the photo")
            case .depthAnythingV2: L10n.t("本地 AI 深度估计（Depth Anything V2 Small）", "On-device AI depth (Depth Anything V2 Small)")
            case .objectCapture: L10n.t("RealityKit Object Capture", "RealityKit Object Capture")
            }
        }
    }
    /// Experimental features: never `.ready` without device-verified output.
    enum Capability: String, Codable, Sendable { case ready, notAvailable, experimentalNotImplemented }

    var id: String
    var name: String
    var createdAt: Date
    var source: Source
    var sourceName: String
    /// SHA-256 of the input file (reuse instead of a second copy).
    var sourceHash: String
    var engine: String
    var engineVersion: String
    var depthSource: DepthSource
    var geometry: Geometry
    var quality: GenerationQuality
    var vertexCount: Int
    var triangleCount: Int
    var textureWidth: Int
    var textureHeight: Int
    /// Files inside the model's folder.
    var meshFile: String?
    var textureFile: String?
    var usdzFile: String?
    var thumbnailFile: String?
    var humanoidDetected: Bool
    var rigging: Capability
    var animation: Capability
    /// Separate clothes / hair: single pictures cannot recover them.
    var separableParts: Capability
    var skinPresets: [SkinPreset] = []
    var notes: [String] = []

    var valid: Bool { !id.isEmpty && !name.isEmpty && vertexCount >= 0 && triangleCount >= 0 && (meshFile != nil || usdzFile != nil) }

    struct SkinPreset: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var name: String
        /// Multiplied into the texture; nil keeps the original colours.
        var tintHex: String?
        /// Replacement texture file in the model folder.
        var textureFile: String?
    }
}

// MARK: Video frames

/// Quality numbers for one sampled video frame (computed on a small
/// greyscale copy).
struct FrameStat: Equatable, Sendable {
    var index: Int
    var time: Double
    /// Variance of the Laplacian: low = blurry.
    var sharpness: Double
    var hash: UInt64
    /// Horizontal / vertical shift from the previous frame, share of width.
    var shiftX: Double = 0
    var shiftY: Double = 0
    /// A person was detected in the frame.
    var person = false
}

enum FrameQuality {
    /// Variance of the 4-neighbour Laplacian of an 8-bit greyscale image.
    static func sharpness(_ gray: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, gray.count == width * height else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let c = Double(gray[y * width + x]) * 4
                let l = c - Double(gray[y * width + x - 1]) - Double(gray[y * width + x + 1]) - Double(gray[(y - 1) * width + x]) - Double(gray[(y + 1) * width + x])
                sum += l; sumSq += l * l; n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
    }

    /// Difference hash from a 9×8 greyscale thumbnail (64 bits).
    static func differenceHash(_ gray9x8: [UInt8]) -> UInt64 {
        guard gray9x8.count == 72 else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { hash = hash << 1 | (gray9x8[y * 9 + x] > gray9x8[y * 9 + x + 1] ? 1 : 0) } }
        return hash
    }
    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Area-average downscale of greyscale pixels (for the hash and checks).
    static func downscale(_ gray: [UInt8], width: Int, height: Int, to w: Int, _ h: Int) -> [UInt8] {
        guard width > 0, height > 0, gray.count == width * height, w > 0, h > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = y * height / h, y1 = max(y0 + 1, (y + 1) * height / h)
            for x in 0..<w {
                let x0 = x * width / w, x1 = max(x0 + 1, (x + 1) * width / w)
                var sum = 0, n = 0
                for yy in y0..<min(y1, height) { for xx in x0..<min(x1, width) { sum += Int(gray[yy * width + xx]); n += 1 } }
                out[y * w + x] = UInt8(sum / max(1, n))
            }
        }
        return out
    }

    /// Drops blurry frames (below 35% of the median sharpness, or nearly
    /// flat) and near duplicates of the last kept frame. Order is kept.
    static func select(_ frames: [FrameStat], duplicateDistance: Int = 5) -> (kept: [FrameStat], blurry: Int, duplicates: Int) {
        guard !frames.isEmpty else { return ([], 0, 0) }
        let sorted = frames.map(\.sharpness).sorted()
        let median = sorted[sorted.count / 2]
        let floor = max(median * 0.35, 4)
        var kept: [FrameStat] = [], blurry = 0, duplicates = 0
        for frame in frames {
            if frame.sharpness < floor { blurry += 1; continue }
            if let last = kept.last, distance(last.hash, frame.hash) <= duplicateDistance { duplicates += 1; continue }
            kept.append(frame)
        }
        return (kept, blurry, duplicates)
    }
}

/// What a video can be used for. Only `.multiView` goes on to multi-view
/// reconstruction; everything else is told why and offered the depth relief.
enum VideoAssessment: Equatable, Sendable {
    /// Enough distinct sharp views moving around a subject.
    case multiView(frames: Int, sweep: Double)
    /// Camera moved too little: shoot again walking around the object.
    case insufficientViews(frames: Int, sweep: Double)
    /// A person filmed from a fixed position: not a multi-view capture.
    case personFixedCamera
    /// Too few sharp, distinct frames to do anything.
    case tooFewFrames(frames: Int)

    static let minimumFrames = 20
    /// Sum of horizontal shifts (share of frame width) for a usable orbit.
    static let minimumSweep = 1.5

    static func assess(_ kept: [FrameStat]) -> VideoAssessment {
        guard kept.count >= 6 else { return .tooFewFrames(frames: kept.count) }
        let sweep = kept.reduce(0) { $0 + abs($1.shiftX) + abs($1.shiftY) * 0.5 }
        let personShare = Double(kept.filter(\.person).count) / Double(kept.count)
        if personShare >= 0.6 && sweep < minimumSweep { return .personFixedCamera }
        if kept.count >= minimumFrames && sweep >= minimumSweep { return .multiView(frames: kept.count, sweep: sweep) }
        return .insufficientViews(frames: kept.count, sweep: sweep)
    }

    var canReconstruct: Bool { if case .multiView = self { return true }; return false }

    var message: String {
        switch self {
        case .multiView(let frames, _):
            return L10n.t("可用于多视角重建：\(frames) 张清晰且不重复的画面，视角变化足够。", "Ready for multi-view reconstruction: \(frames) sharp, distinct frames with enough camera movement.")
        case .insufficientViews(let frames, let sweep):
            return L10n.t("视角不够（\(frames) 张有效画面，镜头移动约 \(String(format: "%.1f", sweep)) 个画面宽度）。请绕物体慢慢走一圈重拍，或改用「基础立体化」。",
                          "Not enough views (\(frames) usable frames, about \(String(format: "%.1f", sweep)) frame widths of movement). Walk slowly around the object and film again, or use the basic depth model.")
        case .personFixedCamera:
            return L10n.t("这是固定机位的人物视频，不能做多视角重建。可以用最清晰的一帧生成深度立体模型。", "This is a person filmed from one spot, which cannot be reconstructed from many views. The sharpest frame can still become a depth relief model.")
        case .tooFewFrames(let frames):
            return L10n.t("清晰、不重复的画面太少（\(frames) 张），无法使用。请在光线充足处重拍。", "Too few sharp, distinct frames (\(frames)). Film again in good light.")
        }
    }
}

// MARK: Pixel helpers

enum PixelMath {
    /// IEEE 754 half → Float (no Float16 type needed on any platform).
    static func half(_ bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F), fraction = UInt32(bits & 0x3FF)
        if exponent == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            let value = Float(fraction) / 1024 * 0.000061035156  // 2^-14
            return sign == 0 ? value : -value
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | fraction << 13) }
        return Float(bitPattern: sign | UInt32(exponent - 15 + 127) << 23 | fraction << 13)
    }

    /// Converts metric depth (metres, near = small) to nearness (near = large).
    static func nearness(fromDepth depth: [Float]) -> [Float] {
        depth.map { $0.isFinite && $0 > 0 ? 1 / $0 : 0 }
    }

    /// Mask from depth alone (subject = nearer part): Otsu threshold on the
    /// nearness histogram. Used only when no segmentation is available.
    static func otsuMask(_ nearness: [Float]) -> [Float] {
        let finite = nearness.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max(), hi > lo else { return nearness.map { _ in 0 } }
        var histogram = [Double](repeating: 0, count: 64)
        for v in finite { histogram[min(63, Int((v - lo) / (hi - lo) * 63))] += 1 }
        let total = Double(finite.count)
        var sumAll = 0.0
        for i in 0..<64 { sumAll += Double(i) * histogram[i] }
        var best = 0, bestVariance = -1.0, weightB = 0.0, sumB = 0.0
        for t in 0..<64 {
            weightB += histogram[t]; if weightB == 0 { continue }
            let weightF = total - weightB; if weightF == 0 { break }
            sumB += Double(t) * histogram[t]
            let meanB = sumB / weightB, meanF = (sumAll - sumB) / weightF
            let variance = weightB * weightF * (meanB - meanF) * (meanB - meanF)
            if variance > bestVariance { bestVariance = variance; best = t }
        }
        // Compare bins, not values: everything above the split bin is subject.
        return nearness.map { $0.isFinite && min(63, Int(($0 - lo) / (hi - lo) * 63)) > best ? 1 : 0 }
    }
}
