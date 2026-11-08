import Foundation

// v1.90: a person photo (and optionally their back) painted onto the base
// body. The texture is an atlas: the front photo on the left half, the back
// on the right half (a real back photo, or a colour-only guess made from the
// front). Vertices where a triangle crosses from front to back are
// duplicated so no triangle stretches across the two halves.

struct PaintedBody: Equatable, Sendable {
    var mesh: GeneratedMesh
    var skin: SkinInfluences
    /// Each new vertex's original base-body vertex (for tests and re-posing).
    var source: [Int]
    /// Vertices with no spot in either photo (painted from the nearest one).
    var unpainted: Int
}

enum BaseBodyPaint {
    /// `back`: the person's back photo; nil uses the front photo's own spots
    /// on the right half (which the app fills with a blurred, colour-only copy).
    static func paint(_ model: BaseBodyModel, front: BodyPhoto, back: BodyPhoto?) -> PaintedBody {
        let frontUV = BodyPhotoFit.uvs(model, photo: front, everywhere: true)
        let backUV: [SIMD2<Float>?]
        if let back { backUV = BodyPhotoFit.uvs(model, photo: back, everywhere: true) }
        else { backUV = frontUV }
        // Which half a triangle lives on: the side most of its corners face.
        var out = GeneratedMesh()
        var joints: [UInt8] = [], weights: [Float] = [], source: [Int] = []
        var made: [Int: UInt32] = [:]   // key: vertex * 2 + side
        var unpainted = 0
        func fallback(_ uv: [SIMD2<Float>?], _ v: Int) -> SIMD2<Float>? {
            // A vertex the mapper could not place: borrow a neighbour along its ring.
            if let spot = uv[v] { return spot }
            let target = model.vertices[v]
            return model.vertices.indices.lazy.filter { model.vertices[$0].from == target.from && uv[$0] != nil }
                .min { abs(model.vertices[$0].along - target.along) < abs(model.vertices[$1].along - target.along) }.flatMap { uv[$0] }
        }
        func vertex(_ v: Int, back side: Bool) -> UInt32 {
            if let i = made[v * 2 + (side ? 1 : 0)] { return i }
            let spot: SIMD2<Float>
            if let s = fallback(side ? backUV : frontUV, v) { spot = s } else { spot = SIMD2(0.5, 0.5); unpainted += 1 }
            let i = UInt32(out.vertexCount)
            out.positions += model.mesh.positions[v * 3 ..< v * 3 + 3]
            out.normals += model.mesh.normals[v * 3 ..< v * 3 + 3]
            // Image v (down) → mesh v (up); the half picks the atlas side.
            out.uvs += [(side ? 0.5 : 0) + spot.x * 0.5, 1 - spot.y]
            joints += model.skin.joints[v * 4 ..< v * 4 + 4]
            weights += model.skin.weights[v * 4 ..< v * 4 + 4]
            source.append(v)
            made[v * 2 + (side ? 1 : 0)] = i
            return i
        }
        for t in 0..<model.mesh.triangleCount {
            let corners = (0..<3).map { Int(model.mesh.indices[t * 3 + $0]) }
            let facing = corners.filter { model.vertices[$0].front }.count
            let side = facing < 2   // true: the back half
            for v in corners { out.indices.append(vertex(v, back: side)) }
        }
        return PaintedBody(mesh: out, skin: SkinInfluences(joints: joints, weights: weights), source: source, unpainted: unpainted)
    }
}
