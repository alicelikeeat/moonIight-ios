import Foundation
#if canImport(ModelIO)
import ModelIO
#endif

// v1.87 USDZ export: package layout, scene text, skeleton maths, and a
// read-back with Model I/O on macOS. Sample files go to build/usdz-samples
// for usdchecker when the runner has it.

private func close(_ a: [Float], _ b: [Float], _ eps: Float = 1e-3) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= eps } }

private func cube() -> GeneratedMesh {
    var m = GeneratedMesh()
    let p: [[Float]] = [[-0.5, 0, -0.5], [0.5, 0, -0.5], [0.5, 1, -0.5], [-0.5, 1, -0.5], [-0.5, 0, 0.5], [0.5, 0, 0.5], [0.5, 1, 0.5], [-0.5, 1, 0.5]]
    m.positions = p.flatMap { $0 }
    m.uvs = p.flatMap { [($0[0] + 0.5), $0[1]] }
    m.indices = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
    m.computeNormals()
    return m
}

private func sampleDirectory() -> URL? {
    let url = URL(fileURLWithPath: "build/usdz-samples", isDirectory: true)
    return (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ? url : nil
}

func usdzExportTests() {
    // Matrices.
    let rot = Mat4.rotation(axis: [0, 0, 1], angle: .pi / 3).m
    let moved = USDMatrix.multiply(USDMatrix.translation([1, 2, 3]), rot)
    check(close(USDMatrix.multiply(USDMatrix.inverse(moved)!, moved), USDMatrix.identity), "affine inverse")
    let parts = USDMatrix.decompose(moved)
    let half = Float.pi / 6
    check(close(parts.t, [1, 2, 3]) && close(parts.s, [1, 1, 1]) && close(parts.q, [cos(half), 0, 0, sin(half)]), "decompose gives translation, (w,x,y,z) rotation and scale (\(parts.q))")

    // Static mesh with a texture.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 100))
    let staticFile = USDZPackage.make(mesh: cube(), texture: png, skin: nil)
    let entries = USDZPackage.entries(staticFile.data) ?? []
    check(entries.map(\.name) == ["model.usda", "texture.png"], "the root layer comes first, the texture next to it")
    check(entries.allSatisfy { $0.offset % USDZPackage.alignment == 0 }, "every file's data starts on a 64-byte boundary (\(entries.map(\.offset)))")
    check(entries.last?.data == png, "files are stored, not compressed")
    let text = String(decoding: entries.first?.data ?? Data(), as: UTF8.self)
    check(text.hasPrefix("#usda 1.0") && text.contains("defaultPrim = \"Root\"") && text.contains("int[] faceVertexCounts") && text.contains("UsdPreviewSurface") &&
          text.contains("@texture.png@") && text.contains("texCoord2f[] primvars:st") && !text.contains("SkelRoot"), "static scene: mesh, UVs, normals, textured preview surface")
    check(staticFile.contents.triangles == 12 && staticFile.contents.texture && !staticFile.contents.skinned, "contents report for a static mesh")
    let crcOK = entries.count == 2 && USDZPackage.crc32(Data("123456789".utf8)) == 0xCBF4_3926
    check(crcOK, "CRC-32 matches the standard check value")
    var coloured = cube(); coloured.uvs = []
    let colourScene = USDAWriter.scene(mesh: coloured, colors: Array(repeating: 0.5, count: coloured.vertexCount * 3), textureName: nil, skin: nil)
    check(colourScene.contents.vertexColours && colourScene.text.contains("primvars:displayColor") && colourScene.text.contains("UsdPrimvarReader_float3"), "no texture: vertex colours drive the material")

    // Moonlight's own rig: the exported skinning matrix is the preview's matrix.
    let heads: [RigBone: [Float]] = [.torso: [0, 1, 0], .head: [0, 1.5, 0], .rightUpperArm: [-0.2, 1.4, 0], .rightForearm: [-0.45, 1.4, 0],
                                     .leftUpperArm: [0.2, 1.4, 0], .leftForearm: [0.45, 1.4, 0], .rightThigh: [-0.1, 0.9, 0], .rightShin: [-0.1, 0.5, 0],
                                     .leftThigh: [0.1, 0.9, 0], .leftShin: [0.1, 0.5, 0]]
    let skeleton = RigSkeleton(bones: RigBone.allCases.map { RigSkeleton.Bone(bone: $0, head: heads[$0]!, tail: heads[$0]!.enumerated().map { $0.offset == 1 ? $0.element - 0.2 : $0.element }) })
    let mesh = cube()
    let weights = SkinWeights(bone0: Array(repeating: 0, count: mesh.vertexCount), bone1: Array(repeating: 2, count: mesh.vertexCount), weight0: Array(repeating: 0.7, count: mesh.vertexCount))
    let clips = Array(RigClip.standard.prefix(2))
    if let rig = USDSkinnedData.moonlight(skeleton: skeleton, skin: weights, clips: clips) {
        check(rig.valid && rig.jointNames.count == 10 && rig.clips.map(\.name) == clips.map(\.name), "the auto-rig becomes a valid USD skeleton with its clips")
        let expected = clips.reduce(0) { $0 + max(2, Int((Double($1.period) * 24).rounded())) }
        check(rig.frames.count == expected, "every clip is sampled at 24 fps on one timeline (\(rig.frames.count) frames)")
        var maxError: Float = 0
        for (clip, range) in zip(clips, rig.clips) {
            for f in stride(from: range.start, through: range.end, by: 5) {
                let deltas = RigPose.matrices(skeleton, clip: clip, time: Float(Double(f - range.start) / 24))
                var world: [[Float]] = []
                for j in 0..<10 { world.append(rig.parents[j].map { USDMatrix.multiply(world[$0], rig.frames[f][j]) } ?? rig.frames[f][j]) }
                for j in 0..<10 {
                    let skinning = USDMatrix.multiply(world[j], USDMatrix.inverse(rig.bindWorld[j])!)
                    maxError = max(maxError, zip(skinning, deltas[j].m).map { abs($0 - $1) }.max() ?? 0)
                }
            }
        }
        check(maxError < 1e-3, "USD skinning (world × inverse bind) equals the preview's bone matrices (max error \(maxError))")
        let skinned = USDZPackage.make(mesh: mesh, texture: nil, skin: rig)
        let skelText = String(decoding: USDZPackage.entries(skinned.data)?.first?.data ?? Data(), as: UTF8.self)
        check(skinned.contents.skinned && skinned.contents.joints == 10 && skinned.contents.clipNames == clips.map(\.name), "contents report: skeleton, skin, clips")
        check(skelText.contains("def SkelRoot \"Root\"") && skelText.contains("def Skeleton \"Skel\"") && skelText.contains("def SkelAnimation \"Anim\"") &&
              skelText.contains("primvars:skel:jointIndices") && skelText.contains("elementSize = 4") && skelText.contains("\"torso/head\"") &&
              skelText.contains("rotations.timeSamples") && skelText.contains("timeCodesPerSecond = 24"), "skeleton, skin and animation are written as UsdSkel")
        if let dir = sampleDirectory() { try? skinned.data.write(to: dir.appendingPathComponent("rigged.usdz")) }
    } else {
        check(false, "the auto-rig converts")
    }

    // A rig from a model file (the procedural builder's exact rig), with clips.
    let character = ProceduralCharacterBuilder.build(CharacterSpec(name: "Knight"))
    let motion = ["idle", "walk"].compactMap { MotionClip.standard($0) }
    if let rig = USDSkinnedData.imported(skeleton: character.skeleton, skin: character.skin, clips: motion) {
        check(rig.valid && rig.jointNames.count == character.skeleton.joints.count && rig.jointIndices.count == character.mesh.vertexCount * 4, "a file rig keeps every joint and four weights per vertex")
        check(rig.parents.enumerated().allSatisfy { i, p in p.map { $0 < i } ?? true }, "joints are written parent-first")
        check(rig.frames.count > 0 && rig.clips.count == motion.count, "the file rig's clips are sampled (\(rig.frames.count) frames)")
        let made = USDZPackage.make(mesh: character.mesh, texture: nil, skin: rig)
        check(made.contents.skinned && !made.contents.clipNames.isEmpty, "a procedural character exports with skeleton and motion")
        if let dir = sampleDirectory() { try? made.data.write(to: dir.appendingPathComponent("character.usdz")) }
    } else {
        check(false, "the file rig converts")
    }
    if let dir = sampleDirectory() { try? staticFile.data.write(to: dir.appendingPathComponent("static.usdz")) }

    #if canImport(ModelIO)
    // Read back with Apple's USD importer (macOS test runner).
    if let dir = sampleDirectory() {
        for name in ["static", "rigged", "character"] {
            let url = dir.appendingPathComponent(name + ".usdz")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = MDLAsset(url: url)
            var meshes = 0
            func walk(_ o: MDLObject) { if o is MDLMesh { meshes += 1 }; for c in o.children.objects { walk(c) } }
            for i in 0..<asset.count { walk(asset.object(at: i)) }
            check(meshes >= 1, "Model I/O reads the mesh back from \(name).usdz")
        }
    }
    #endif
    print("USDZ export: static \(staticFile.data.count) bytes")
}
