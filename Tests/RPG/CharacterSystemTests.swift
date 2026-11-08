import Foundation

/// Legacy rigs, outfits and equipment, validation, and the package format.
func characterSystemTests() {
    // 1. Ten-bone rig → standard skeleton: same bind deformation, same motion.
    let tube = BaseBody.build(.standard)
    let j = BaseBody.joints(.standard)
    func f(_ v: SIMD3<Float>?) -> [Float] { let v = v ?? .zero; return [v.x, v.y, v.z] }
    let bones: [RigSkeleton.Bone] = [
        .init(bone: .torso, head: f(j[.pelvis]), tail: f(j[.neck])), .init(bone: .head, head: f(j[.head]), tail: f(j[.headEnd])),
        .init(bone: .rightUpperArm, head: f(j[.rightUpperArm]), tail: f(j[.rightForearm])), .init(bone: .rightForearm, head: f(j[.rightForearm]), tail: f(j[.rightHand])),
        .init(bone: .leftUpperArm, head: f(j[.leftUpperArm]), tail: f(j[.leftForearm])), .init(bone: .leftForearm, head: f(j[.leftForearm]), tail: f(j[.leftHand])),
        .init(bone: .rightThigh, head: f(j[.rightThigh]), tail: f(j[.rightShin])), .init(bone: .rightShin, head: f(j[.rightShin]), tail: f(j[.rightFoot])),
        .init(bone: .leftThigh, head: f(j[.leftThigh]), tail: f(j[.leftShin])), .init(bone: .leftShin, head: f(j[.leftShin]), tail: f(j[.leftFoot])),
    ]
    let oldSkeleton = RigSkeleton(bones: bones)
    let oldSkin = AutoRig.weights(for: tube.mesh, skeleton: oldSkeleton)
    let package = RigPackage(skeleton: oldSkeleton, joints: BodyJoints2D(points: [:]), clips: RigClip.standard,
                             validation: RigValidation(passed: true, clips: [:], maxStretch: 0, problems: []))
    if let converted = LegacyRigAdapter.convert(package, skin: oldSkin, vertexCount: tube.mesh.vertexCount) {
        do { try converted.skeleton.validate() } catch { check(false, "legacy: the converted skeleton validates (\(error))") }
        check(converted.inferred.contains("spine1") && converted.inferred.contains("rightClavicle") && !converted.inferred.contains("rightForearm"),
              "legacy: joints the old rig never had are marked inferred, its own joints are not")
        check(converted.skeleton.joints.filter { $0.source == .inferred }.allSatisfy { $0.confidence == 0 }, "legacy: inferred joints carry no confidence")
        let rest = SkinWeightSolver.deform(tube.mesh, skin: converted.skin, matrices: RigPoser.skinning(MotionSample(), skeleton: converted.skeleton))
        let restDrift = zip(rest.positions, tube.mesh.positions).map { abs($0 - $1) }.max() ?? 1
        check(restDrift < 1e-4, "legacy: the converted rig keeps the bind pose exactly (\(restDrift))")
        if let walk = RigClip.standard.first(where: { $0.id == "walk" }), let motion = converted.motions.first(where: { $0.id == "walk" }) {
            let t: Float = 1.1 * 10 / 33
            let old = RigPose.deform(tube.mesh, skin: oldSkin, matrices: RigPose.matrices(oldSkeleton, clip: walk, time: t))
            let new = SkinWeightSolver.deform(tube.mesh, skin: converted.skin, matrices: RigPoser.skinning(motion.sample(at: t, legLength: 0), skeleton: converted.skeleton))
            let worst = zip(old.positions, new.positions).map { abs($0 - $1) }.max() ?? 1
            check(worst < 0.002, "legacy: an old walk plays the same through the unified interface (\(worst) m)")
        }
    } else { check(false, "legacy: a ten-bone rig converts") }
    check(LegacyRigAdapter.convert(package, skin: oldSkin, vertexCount: tube.mesh.vertexCount + 1) == nil, "legacy: weights for another mesh are refused")

    // 2. Outfits follow the body; equipment rides its joint.
    guard let body = HumanBase.build(.standard), let chibi = HumanBase.build(.chibi) else { check(false, "character: HumanBase available"); return }
    for piece in OutfitPiece.catalog {
        guard let part = OutfitBuilder.build(piece, on: body) else { check(false, "outfit: \(piece.id) builds"); continue }
        let issues = CharacterValidator.mesh(part.mesh, name: piece.id).filter { $0.severity == .error }
        check(issues.isEmpty && part.skin.valid(jointCount: body.skeleton.joints.count, vertexCount: part.mesh.vertexCount) && part.mesh.triangleCount > 50,
              "outfit: \(piece.id) is a valid skinned mesh (\(part.mesh.triangleCount) triangles) \(issues.map(\.code))")
    }
    if let shirt = OutfitPiece.find("top.longSleeve"), let part = OutfitBuilder.build(shirt, on: body), let walk = MotionLibrary.motion("attack3") {
        // Sleeves stay on the arms in a motion: every shell vertex stays close to the posed body.
        let mats = RigPoser.skinning(walk.sample(at: 0.45, legLength: RigPoser.legLength(body.skeleton)), skeleton: body.skeleton)
        let posedShell = SkinWeightSolver.deform(part.mesh, skin: part.skin, matrices: mats).positions
        let posedBody = SkinWeightSolver.deform(body.mesh, skin: body.skin, matrices: mats).positions
        let hand = RigPoser.positions(walk.sample(at: 0.45, legLength: RigPoser.legLength(body.skeleton)), skeleton: body.skeleton)[body.skeleton.index(.rightForearm)!]
        var nearest: Float = 9
        for v in stride(from: 0, to: posedBody.count, by: 3) { nearest = min(nearest, cLength(SIMD3(posedBody[v], posedBody[v + 1], posedBody[v + 2]) - hand)) }
        var sleeve: Float = 9
        for v in stride(from: 0, to: posedShell.count, by: 3) { sleeve = min(sleeve, cLength(SIMD3(posedShell[v], posedShell[v + 1], posedShell[v + 2]) - hand)) }
        check(sleeve < nearest + 0.05, "outfit: the sleeve follows the raised arm (sleeve \(sleeve) m, skin \(nearest) m from the elbow)")
    }
    if let hair = OutfitPiece.find("hair.short"), let onChibi = OutfitBuilder.build(hair, on: chibi), let onStd = OutfitBuilder.build(hair, on: body) {
        check(onChibi.mesh.bounds.max[1] > chibi.mesh.bounds.max[1] - 0.001 && onStd.mesh.bounds.max[1] > body.mesh.bounds.max[1] - 0.001, "outfit: hair covers the crown on every body")
    }
    if let sword = EquipmentItem.find("weapon.sword") {
        let mesh = EquipmentBuilder.mesh(sword)
        check(CharacterValidator.mesh(mesh).allSatisfy { $0.severity != .error } && abs(mesh.bounds.max[1] - sword.length) < 0.05, "equipment: the sword mesh is valid and as long as stated")
        let pose = MotionLibrary.motion("attack1")!.sample(at: 0.2, legLength: 0.9)
        let world = body.skeleton.worldTransforms(local: RigPoser.locals(pose, skeleton: body.skeleton))
        if let at = EquipmentBuilder.transform(sword, skeleton: body.skeleton, world: world) {
            let grip = at.point(.zero), hand = world[body.skeleton.index(.rightHand)!].origin
            check(cLength(grip - hand) < 0.15, "equipment: the sword's grip stays in the right hand during a slash (\(cLength(grip - hand)) m)")
        }
    }
    var look = CharacterAppearance()
    look.wear("top.shirt"); look.wear("top.armor"); look.equip("weapon.sword"); look.equip("weapon.axe"); look.equip("shield.round")
    check(look.outfit == ["top.armor"] && Set(look.equipment) == ["weapon.axe", "shield.round"], "appearance: one piece per slot, a new one replaces the old")
    let glass = CharacterMaterialProfile.preset(.glass, color: SIMD3(0.5, 0.8, 1)).clamped
    check(glass.transparent && glass.opacity <= 0.85 && CharacterMaterialProfile(baseColor: SIMD3(.nan, 2, -1), opacity: 9).clamped.baseColor == SIMD3(0.8, 1, 0),
          "material: glass is transparent; impossible values are clamped")
    check(CharacterAppearance.presets.count == 3 && Set(CharacterAppearance.presets.map(\.1.shape.height)).count == 3, "appearance: three presets of different builds")

    // 3. Validation catches broken models without crashing.
    let ok = CharacterValidator.validate(mesh: body.mesh, skeleton: body.skeleton, skin: body.skin, motions: MotionLibrary.standard)
    check(ok.ok, "validator: the base body passes (\(ok.errors.map(\.code)))")
    var nanMesh = body.mesh; nanMesh.positions[5] = .nan
    var badIndex = body.mesh; badIndex.indices[7] = UInt32(body.mesh.vertexCount + 10)
    var badSkin = body.skin; badSkin.joints[0] = 200; badSkin.weights[1] = -3
    var cyclic = body.skeleton; cyclic.joints[1].parentID = cyclic.joints[5].jointID
    var badMotion = MotionLibrary.motion("walk")!; badMotion.duration = .nan
    check(!CharacterValidator.validate(mesh: nanMesh, skeleton: body.skeleton, skin: body.skin).ok, "validator: a NaN vertex is refused")
    check(!CharacterValidator.validate(mesh: badIndex, skeleton: body.skeleton, skin: body.skin).ok, "validator: an index past the vertices is refused")
    check(CharacterValidator.validate(mesh: body.mesh, skeleton: body.skeleton, skin: badSkin).errors.contains { $0.code == "skin.joint" }, "validator: weights on missing joints are refused")
    check(CharacterValidator.validate(mesh: body.mesh, skeleton: cyclic, skin: body.skin).errors.contains { $0.code == "skeleton.invalid" }, "validator: a joint loop is refused")
    check(!CharacterValidator.validate(mesh: body.mesh, skeleton: body.skeleton, skin: body.skin, motions: [badMotion]).ok, "validator: a motion with bad timing is refused")
    var wrongBind = body.skeleton; wrongBind.joints[3].inverseBindMatrix = RigXform.translation(0.3, 0, 0).matrix
    check(!CharacterValidator.validate(mesh: body.mesh, skeleton: wrongBind, skin: body.skin).ok, "validator: inverse binds that disagree with the skeleton are refused")

    // 4. Packages: save, reload, list, refuse newer formats, survive damage.
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcpkg-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = CharacterPackageStore(folder: folder)
    var saved: [CharacterPackage] = []
    for (name, appearance) in CharacterAppearance.presets {
        guard let p = CharacterPackage.humanBase(name: name, appearance: appearance, date: Date(timeIntervalSince1970: 1_800_000_000)) else { check(false, "package: \(name) builds"); continue }
        check(p.validation.ok && p.manifest.quality != .failed, "package: \(name) passes validation")
        do { try store.save(p); saved.append(p) } catch { check(false, "package: \(name) saves (\(error))") }
    }
    if let first = saved.first {
        let back = try? store.load(first.manifest.id)
        check(back == first, "package: a saved character loads back identical")
        var edited = first; edited.appearance.wear("hair.long"); edited.manifest.history.append(.init(date: Date(timeIntervalSince1970: 1_800_000_100), what: "hair"))
        do { try store.save(edited) } catch { check(false, "package: an edit saves over the old one") }
        check((try? store.load(first.manifest.id))?.appearance.outfit.contains("hair.long") == true, "package: the edit is what loads")
        let manifestURL = store.url(first.manifest.id).appendingPathComponent("Manifest.json")
        if var text = try? String(contentsOf: manifestURL, encoding: .utf8) {
            text = text.replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":99")
            try? text.write(to: manifestURL, atomically: true, encoding: .utf8)
            var refusedLoad = false, refusedSave = false
            do { _ = try store.load(first.manifest.id) } catch CharacterPackageError.newerFormat(99) { refusedLoad = true } catch {}
            do { try store.save(edited) } catch CharacterPackageError.newerFormat(99) { refusedSave = true } catch {}
            check(refusedLoad && refusedSave, "package: a newer format is neither read wrongly nor overwritten")
        }
        if saved.count > 1 { try? "{".write(to: store.url(saved[1].manifest.id).appendingPathComponent("Skeleton/Skeleton.json"), atomically: true, encoding: .utf8) }
        let listing = store.list()
        check(listing.packages.count == max(0, saved.count - 2) && listing.damaged.count == min(2, saved.count), "package: damaged packages are listed apart, the rest still load")
        let size = (try? FileManager.default.contentsOfDirectory(atPath: store.url(first.manifest.id).appendingPathComponent("Meshes").path))?.count ?? -1
        check(size == 0, "package: HumanBase characters store no geometry of their own")
    }
    // Custom geometry round-trips with its weights.
    var custom = saved.last ?? CharacterPackage.humanBase(name: "x", appearance: CharacterAppearance())!
    custom.manifest.id = "custom-test"; custom.manifest.geometry = .custom(lods: 1); custom.meshes = [body.mesh]; custom.skins = [body.skin]
    do { try store.save(custom); let back = try store.load("custom-test"); check(back.meshes == [body.mesh] && back.skins == [body.skin], "package: custom meshes and weights round-trip") }
    catch { check(false, "package: custom geometry saves (\(error))") }
    check(SkinCodec.decode(Data("SKI1".utf8) + Data([1, 0, 0, 0])) == nil, "package: a truncated weights file is refused")
    print("RPG character system: legacy rig, \(OutfitPiece.catalog.count) outfit pieces, \(EquipmentItem.catalog.count) items, validator and packages checked")
}
