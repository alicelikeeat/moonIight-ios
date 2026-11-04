import Foundation

// v1.75: meshes with colours per vertex (TripoSR, many GLB files) become
// a textured mesh, because the app's renderers use a texture. Each
// triangle gets its own small cell in the texture: its three corners sit
// on texel centres holding the vertex colours, and the cell is filled by
// barycentric interpolation, so the look matches per-vertex colouring.
// Triangles get their own vertices (rigging welds them back by position).
// Pure Swift.

enum VertexColorBaker {
    /// `colors`: RGB 0…1, 3 per vertex.
    static func bake(_ mesh: GeneratedMesh, colors: [Float], cell: Int = 4) -> (mesh: GeneratedMesh, texture: RasterImage) {
        let t = mesh.triangleCount
        let perRow = max(1, Int(Double(t).squareRoot().rounded(.up)))
        let side = min(4096, max(cell, perRow * cell))
        let rowsNeeded = (t + perRow - 1) / perRow
        let height = min(4096, max(cell, rowsNeeded * cell))
        var texture = RasterImage(width: side, height: height, fill: [128, 128, 128, 255])
        var out = GeneratedMesh()
        out.positions.reserveCapacity(t * 9); out.normals.reserveCapacity(t * 9); out.uvs.reserveCapacity(t * 6); out.indices.reserveCapacity(t * 3)
        let span = Float(cell - 1)
        for tri in 0..<t {
            let cx = (tri % perRow) * cell, cy = (tri / perRow) * cell
            guard cx + cell <= side, cy + cell <= height else { break }
            let ids = (0..<3).map { Int(mesh.indices[tri * 3 + $0]) }
            let c = ids.map { v -> SIMD3<Float> in
                guard v * 3 + 2 < colors.count else { return [0.5, 0.5, 0.5] }
                return SIMD3(colors[v * 3], colors[v * 3 + 1], colors[v * 3 + 2])
            }
            // Corners at texel centres (0,0), (span,0), (0,span) of the cell.
            for y in 0..<cell { for x in 0..<cell {
                let u = Float(x) / span, v = Float(y) / span
                let w1 = min(1, max(0, u)), w2 = min(1, max(0, v)), w0 = max(0, 1 - w1 - w2)
                let sum = max(1e-6, w0 + w1 + w2)
                let colour = (c[0] * w0 + c[1] * w1 + c[2] * w2) / sum
                let o = ((cy + y) * side + cx + x) * 4
                texture.rgba[o] = UInt8(min(255, max(0, colour.x * 255))); texture.rgba[o + 1] = UInt8(min(255, max(0, colour.y * 255)))
                texture.rgba[o + 2] = UInt8(min(255, max(0, colour.z * 255))); texture.rgba[o + 3] = 255
            } }
            let corners: [(Float, Float)] = [(0, 0), (span, 0), (0, span)]
            for (k, v) in ids.enumerated() {
                out.positions += [mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2]]
                out.normals += mesh.normals.count == mesh.positions.count ? [mesh.normals[v * 3], mesh.normals[v * 3 + 1], mesh.normals[v * 3 + 2]] : [0, 0, 1]
                let px = Float(cx) + corners[k].0 + 0.5, py = Float(cy) + corners[k].1 + 0.5
                out.uvs += [px / Float(side), 1 - py / Float(height)]
                out.indices.append(UInt32(tri * 3 + k))
            }
        }
        return (out, texture)
    }
}
