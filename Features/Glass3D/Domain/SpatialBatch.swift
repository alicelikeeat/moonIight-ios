import Foundation

/// v1.83: still blocks are drawn as one merged mesh per chunk and material
/// instead of one object each. A generated world has 1 000–3 000 blocks;
/// as separate transparent objects every one was its own draw (and its own
/// sort) every frame, which kept the GPU busy and the phone hot. Moving
/// platforms and blocks with media stay separate objects.
enum SpatialBatch {
    /// Blocks that can be merged: still (no moving group) and without media.
    static func batchable(_ block: SpatialBlock, pivots: [String: SpatialVector]) -> Bool {
        // Roofs and walls toggle per building. A merged mesh cannot hide one of them.
        if block.hybridPart == .roof || block.hybridPart == .wall { return false }
        return block.media == nil && block.groupID.flatMap { pivots[$0] } == nil
    }

    /// 32×32 chunk index (8×8 chunks), the same as the ground and culling.
    static func chunk(_ block: SpatialBlock) -> Int { (block.y / 32) * 8 + block.x / 32 }

    /// Look of a block's material (blocks with the same key share a mesh).
    static func materialKey(_ glass: SpatialGlass, collision: SpatialCollision) -> String {
        "glass|\(glass.tintHex ?? "-")|\(glass.density)|\(glass.frosted)|\(glass.glow)|\(collision == .trigger)|\(glass.surface?.rawValue ?? "g")"
    }

    /// Batch key: chunk and material.
    static func key(_ block: SpatialBlock) -> String { "\(chunk(block))|" + materialKey(block.glass, collision: block.collision) }

    /// Changes whenever a block in the batch is added, removed or reshaped.
    static func signature(_ blocks: [SpatialBlock]) -> Int {
        var h = Hasher()
        for b in blocks { h.combine(b.id); h.combine(b.x); h.combine(b.y); h.combine(b.elevation); h.combine(b.thickness); h.combine(b.size); h.combine(b.yaw) }
        return h.finalize()
    }

    /// Triangle mesh data in RealityKit space (x = map x, y = height,
    /// z = −map y). Each box has 24 vertices (4 per face, flat normals,
    /// 0…1 texture coordinates per face) and 36 indices, counter-clockwise
    /// when seen from outside.
    struct Mesh: Equatable {
        var positions: [Float] = []   // xyz
        var normals: [Float] = []     // xyz
        var uvs: [Float] = []         // uv
        var indices: [UInt32] = []
        var vertexCount: Int { positions.count / 3 }
    }

    static func mesh(_ blocks: [SpatialBlock]) -> Mesh {
        var m = Mesh()
        m.positions.reserveCapacity(blocks.count * 72); m.normals.reserveCapacity(blocks.count * 72)
        m.uvs.reserveCapacity(blocks.count * 48); m.indices.reserveCapacity(blocks.count * 36)
        for block in blocks { append(block, to: &m) }
        return m
    }

    /// Unit-cube faces: outward normal and four corners (CCW from outside).
    private static let faces: [(n: (Float, Float, Float), c: [(Float, Float, Float)])] = [
        ((1, 0, 0), [(1, -1, 1), (1, -1, -1), (1, 1, -1), (1, 1, 1)]),
        ((-1, 0, 0), [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)]),
        ((0, 1, 0), [(-1, 1, 1), (1, 1, 1), (1, 1, -1), (-1, 1, -1)]),
        ((0, -1, 0), [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)]),
        ((0, 0, 1), [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
        ((0, 0, -1), [(1, -1, -1), (-1, -1, -1), (-1, 1, -1), (1, 1, -1)]),
    ]
    private static let corners: [(Float, Float)] = [(0, 1), (1, 1), (1, 0), (0, 0)]

    private static func append(_ block: SpatialBlock, to m: inout Mesh) {
        let hx = Float(block.size * 0.98 / 2), hy = Float(block.thickness / 2)
        // Centre in RealityKit space.
        let cx = Float(Double(block.x) + 0.5), cy = Float(block.elevation + block.thickness / 2), cz = Float(-(Double(block.y) + 0.5))
        let a = Float(block.yaw * .pi / 180), cosA = cos(a), sinA = sin(a)
        // Rotation about +y (the same as simd_quatf(angle:, axis: [0, 1, 0])).
        func turn(_ x: Float, _ z: Float) -> (Float, Float) { (x * cosA + z * sinA, -x * sinA + z * cosA) }
        for face in faces {
            let base = UInt32(m.vertexCount)
            let (nx, nz) = turn(face.n.0, face.n.2)
            for (i, c) in face.c.enumerated() {
                let (px, pz) = turn(c.0 * hx, c.2 * hx)
                m.positions += [cx + px, cy + c.1 * hy, cz + pz]
                m.normals += [nx, face.n.1, nz]
                m.uvs += [corners[i].0, corners[i].1]
            }
            m.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
    }
}
