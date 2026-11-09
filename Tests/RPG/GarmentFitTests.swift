import Foundation

/// v1.93: clothes from any model fitted onto a base body.
func garmentFitTests() {
    guard let body = HumanBase.build(.standard, lod: 1) else { check(false, "garments: base body builds"); return }
    let m = body.mesh, h = m.bounds.max[1]
    func point(_ mesh: GeneratedMesh, _ v: Int) -> SIMD3<Float> { SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2]) }
    func strongest(_ skin: SkinInfluences, _ v: Int) -> UInt8 {
        var best = 0
        for k in 1..<4 where skin.weights[v * 4 + k] > skin.weights[v * 4 + best] { best = k }
        return skin.joints[v * 4 + best]
    }

    // A full-body suit: the body's own surface lifted by 1 cm.
    var suit = m
    for v in 0..<m.vertexCount { for a in 0..<3 { suit.positions[v * 3 + a] += m.normals[v * 3 + a] * 0.01 } }
    // As an AI model gives it: arms lowered 40°, turned a quarter, another size and place.
    let q = MotionLibrary.rz(40)
    var sample = MotionSample()
    sample.rotations["rightUpperArm"] = q; sample.rotations["leftUpperArm"] = MotionLibrary.mirror(q)
    let mats = RigPoser.skinning(sample, skeleton: body.skeleton)
    var posed = suit
    for v in 0..<m.vertexCount {
        var p = SIMD3<Float>.zero
        for k in 0..<4 where body.skin.joints[v * 4 + k] != 255 { p += mats[Int(body.skin.joints[v * 4 + k])].point(point(suit, v)) * body.skin.weights[v * 4 + k] }
        posed.positions[v * 3] = p.x * 0.37 + 5; posed.positions[v * 3 + 1] = p.y * 0.37 + 2; posed.positions[v * 3 + 2] = p.z * 0.37 - 3
    }
    posed = GarmentFit.turned(posed, 1)
    check(GarmentFit.measureArmDrop(GarmentFit.turned(suit, 0).positions, body: body) < 8, "garments: a T-pose suit measures level sleeves")
    if let fit = GarmentFit.fit(posed, slot: .full, on: body, adjust: GarmentAdjust(quarterTurns: 3)) {
        let out = fit.part.mesh
        var errors: [Float] = [], same = 0, overlap: Float = 0
        for v in 0..<m.vertexCount {
            errors.append(cLength(point(out, v) - point(suit, v)))
            if strongest(fit.part.skin, v) == strongest(body.skin, v) { same += 1 }
            // Shared weight between the garment point and the body point under it (1 = identical).
            for k in 0..<4 where fit.part.skin.joints[v * 4 + k] != 255 {
                for j in 0..<4 where body.skin.joints[v * 4 + j] == fit.part.skin.joints[v * 4 + k] { overlap += min(fit.part.skin.weights[v * 4 + k], body.skin.weights[v * 4 + j]) }
            }
        }
        overlap /= Float(m.vertexCount)
        errors.sort()
        let mean = errors.reduce(0, +) / Float(errors.count), p95 = errors[errors.count * 95 / 100]
        check(fit.armDrop > 28 && fit.armDrop < 52, "garments: the A-pose sleeves are measured (\(fit.armDrop)° for 40°)")
        check(mean < 0.015 * h && p95 < 0.05 * h, "garments: a lowered-arm, turned, rescaled suit returns to the T-pose on the body (mean \(mean) m, 95% \(p95) m)")
        check(overlap > 0.75 && same * 100 >= m.vertexCount * 60,
              "garments: each point takes the weights of the body under it (shared weight \(overlap), same main joint \(same)/\(m.vertexCount))")
        check(out.valid && out.indices == suit.indices && fit.part.skin.valid(jointCount: body.skeleton.joints.count, vertexCount: out.vertexCount),
              "garments: the fitted suit keeps its triangles and has valid weights")
    } else { check(false, "garments: the suit fits") }

    // A separate top on the body: pushed outside the skin everywhere.
    if let shell = OutfitBuilder.build(OutfitPiece.find("top.longSleeve")!, on: body), let fit = GarmentFit.fit(shell.mesh, slot: .top, on: body) {
        let grid = PointGrid(points: (0..<m.vertexCount).map { point(m, $0) }, cell: 0.035 * h)
        var outside = 0
        for v in 0..<fit.part.mesh.vertexCount {
            let p = point(fit.part.mesh, v)
            if let n = grid.nearest(p, k: 1).first {
                let normal = SIMD3(m.normals[n.0 * 3], m.normals[n.0 * 3 + 1], m.normals[n.0 * 3 + 2])
                if cDot(p - point(m, n.0), normal) > 0 { outside += 1 }
            }
        }
        check(outside * 100 >= fit.part.mesh.vertexCount * 97 && fit.armDrop < 8,
              "garments: a top sits outside the skin (\(outside)/\(fit.part.mesh.vertexCount)), sleeves level (\(fit.armDrop)°)")
        check(fit.part.skin.valid(jointCount: body.skeleton.joints.count, vertexCount: fit.part.mesh.vertexCount), "garments: the top's weights are valid")
    } else { check(false, "garments: a top fits") }

    // Refused: empty, broken or too large meshes.
    var broken = suit; broken.positions[7] = .nan
    var huge = GeneratedMesh()
    huge.positions = [Float](repeating: 0, count: (GarmentFit.maxVertices + 1) * 3); huge.indices = [0, 1, 2]
    check(GarmentFit.fit(GeneratedMesh(), slot: .top, on: body) == nil && GarmentFit.fit(broken, slot: .top, on: body) == nil && GarmentFit.fit(huge, slot: .top, on: body) == nil,
          "garments: empty, NaN and over-budget meshes are refused")
    check(GarmentAdjust(scale: 9, lift: .nan, quarterTurns: -1, armDrop: 200, gap: -1).clamped == GarmentAdjust(scale: 1.6, lift: 0, quarterTurns: 3, armDrop: 85, gap: 0),
          "garments: adjustments are clamped")

    // Wearing rules: a fitted garment takes its slot; a full outfit takes all; a built-in piece takes the slot back.
    func garment(_ id: String, _ slot: CustomGarment.Slot) -> CustomGarment { CustomGarment(id: id, name: id, slot: slot, mesh: id + ".m3dg") }
    var look = CharacterAppearance.presets[0].1
    look.wear(garment("g1", .top))
    check(look.garmentList.map(\.id) == ["g1"] && !look.outfit.contains("top.shirt") && look.outfit.contains("bottom.trousers"), "garments: a fitted top replaces the built-in top only")
    look.wear(garment("g2", .full))
    check(look.garmentList.map(\.id) == ["g2"] && look.outfit.isEmpty, "garments: a full outfit replaces everything")
    look.wear("hair.short")
    check(look.garments == nil && look.outfit == ["hair.short"], "garments: a built-in piece takes its slot back from a full outfit")
    look.wear(garment("g3", .shoes)); look.takeOff(garment: "g3")
    check(look.garments == nil, "garments: taking the last garment off leaves none")

    // Saved with the character (Garments/), names checked.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("garments-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var dressed = CharacterAppearance()
    dressed.wear(garment("g4", .top))
    if var package = CharacterPackage.humanBase(id: "dressed", name: "Dressed", appearance: dressed) {
        package.garments["g4.m3dg"] = GeneratedMeshCodec.encode(suit)
        package.garments["../escape.m3dg"] = Data([1])
        let store = CharacterPackageStore(folder: folder)
        do {
            try store.save(package)
            let loaded = try store.load("dressed")
            check(loaded.appearance.garmentList.map(\.id) == ["g4"] && loaded.garments.count == 1 && loaded.garments["g4.m3dg"].flatMap(GeneratedMeshCodec.decode) == suit,
                  "garments: the garment and its mesh are saved in the package, odd names are not")
        } catch { check(false, "garments: the package saves (\(error))") }
    }
    print("RPG garments: suit \(m.vertexCount) points fitted from an A-pose")
}
