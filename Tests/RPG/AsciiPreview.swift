import Foundation

/// Text renders of characters in the CI log (screenshots cannot always be
/// opened where the log is read): the shaded silhouette at low resolution.
func asciiPreview(_ title: String, mesh: GeneratedMesh, positions: [Float]? = nil, yaw: Float = 0, width: Int = 56, height: Int = 34) -> String {
    var m = mesh
    if let positions { m.positions = positions }
    m.normals = BaseBody.smoothNormals(m)
    m.normalize(size: 1)
    let image = ModelRasterizer.render(m, texture: nil, camera: RasterCamera(yaw: yaw, pitch: 0.05, lighting: true), width: width, height: height, background: [0, 0, 0, 0], supersample: 1)
    let ramp = Array(" .:-=+*#%@")
    var lines = ["── " + title]
    for y in 0..<height {
        var row = ""
        for x in 0..<width {
            let i = (y * width + x) * 4
            if image.rgba[i + 3] < 10 { row.append(" "); continue }
            let lum = (Int(image.rgba[i]) + Int(image.rgba[i + 1]) + Int(image.rgba[i + 2])) / 3
            row.append(ramp[max(1, min(ramp.count - 1, lum * ramp.count / 256))])
        }
        lines.append(row.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
    }
    return lines.joined(separator: "\n")
}

func characterPreviews() {
    guard let body = HumanBase.build(.standard) else { return }
    let sk = body.skeleton, leg = RigPoser.legLength(sk)
    func posed(_ id: String, _ t: Float) -> [Float] {
        SkinWeightSolver.deform(body.mesh, skin: body.skin, matrices: RigPoser.skinning(MotionLibrary.motion(id)!.sample(at: t, legLength: leg), skeleton: sk)).positions
    }
    print(asciiPreview("HumanBase bind (T-pose), front", mesh: body.mesh))
    print(asciiPreview("idle, front", mesh: body.mesh, positions: posed("idle", 0.5)))
    print(asciiPreview("walk at a quarter, side", mesh: body.mesh, positions: posed("walk", 0.26), yaw: .pi / 2))
    print(asciiPreview("attack1 at the hit, front", mesh: body.mesh, positions: posed("attack1", 0.2)))
    print(asciiPreview("attack3 at the hit, side", mesh: body.mesh, positions: posed("attack3", 0.45), yaw: .pi / 2))
    print(asciiPreview("roll halfway, side", mesh: body.mesh, positions: posed("roll", 0.31), yaw: .pi / 2))
    print(asciiPreview("death at the end, side", mesh: body.mesh, positions: posed("death", 1.3), yaw: .pi / 2))
    for (name, look) in CharacterAppearance.presets {
        guard let b = HumanBase.build(look.shape) else { continue }
        var combined = b.mesh
        for piece in look.pieces {
            guard let part = OutfitBuilder.build(piece, on: b) else { continue }
            let base = UInt32(combined.vertexCount)
            combined.positions += part.mesh.positions; combined.uvs += part.mesh.uvs
            combined.indices += part.mesh.indices.map { $0 + base }
        }
        print(asciiPreview("preset \(name) (\(look.shape.height) m) with outfit, idle-free bind, front", mesh: combined))
    }
}
