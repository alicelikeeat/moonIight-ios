import Foundation
import RealityKit
import UIKit

// v1.91: one runtime for every rigged character in the world, the preview
// and the workbench. Callers (world, combat, UI) only say WHO, WHAT state
// and WHERE the camera is; whether the character is a HumanBase body with
// outfit layers or a rigged AI model is the runtime's business.
//
// - Shared and immutable: shaped bodies per (shape, LOD), outfit shells,
//   equipment meshes and materials, cached and reused by every instance.
// - Per instance: its own animation controller and its own deforming
//   meshes, so two characters never share a pose.
// - Cost control: LOD by camera distance, deformation rate by distance,
//   nothing deformed while off screen (the controller still keeps time).
// - Safety: a pose with invalid numbers is dropped for the last good one
//   (or the bind pose) and recorded; it never reaches the GPU.

/// What a runtime instance is made of.
enum CharacterSource: Sendable {
    /// The universal base body with an appearance (rebuilt per LOD).
    case humanBase(CharacterAppearance)
    /// A rigged model of its own (AI-generated or imported), one LOD.
    case rigged(mesh: GeneratedMesh, skeleton: SkeletonDefinition, skin: SkinInfluences, motions: [UniversalMotion])
}

@available(iOS 18.0, *)
@MainActor final class CharacterRuntime {
    struct Incident: Equatable, Sendable { var owner: String; var motion: String; var reason: String; var date: Date }
    struct Stats: Equatable, Sendable { var instances = 0; var deformations = 0; var skipped = 0; var cachedBodies = 0; var lodCounts = [0, 0, 0]; var deferred = 0 }

    @MainActor private final class Layer {
        let player: SkinnedMeshPlayer
        let skin: SkinInfluences
        let entity: ModelEntity
        init(player: SkinnedMeshPlayer, skin: SkinInfluences, entity: ModelEntity) { self.player = player; self.skin = skin; self.entity = entity }
    }
    @MainActor private final class Instance {
        let owner: String
        var source: CharacterSource
        let root = Entity()
        let body = Entity()
        var lod = -1
        var skeleton: SkeletonDefinition
        var layers: [Layer] = []
        var equipment: [(EquipmentItem, ModelEntity)] = []
        var controller: CharacterAnimationController
        var lastDeform: Double = -1
        var lastGood: MotionSample?
        var events: [FiredMotionEvent] = []
        /// A rigged model's own picture (loaded by the caller, kept across LODs).
        var texture: RealityKit.Material?
        var facesCamera = false
        var shownHighlight: Set<String> = []
        init(owner: String, source: CharacterSource, skeleton: SkeletonDefinition, controller: CharacterAnimationController) {
            self.owner = owner; self.source = source; self.skeleton = skeleton; self.controller = controller
            root.name = "character:" + owner
            root.addChild(body)
        }
    }

    private var instances: [String: Instance] = [:]
    private var bodyCache: [String: HumanBody] = [:]
    private var bodyOrder: [String] = []
    private var outfitCache: [String: SkinnedPart] = [:]
    private var equipmentCache: [String: MeshResource] = [:]
    private var materialCache: [String: RealityKit.Material] = [:]
    private(set) var incidents: [Incident] = []
    private(set) var stats = Stats()
    /// Show joints as small spheres (workbench).
    var showSkeleton = false
    /// Joints drawn larger and in another colour (the base-body view's selected region).
    var highlightedJoints: Set<String> = []

    static let lodDistances: [Float] = [7, 20]
    static let maxCachedBodies = 12

    // MARK: Instances

    /// The entity for an owner (created on first use). Nil when the source
    /// cannot be built (missing base body, invalid model): the caller keeps
    /// its default look.
    func entity(owner: String, source: CharacterSource) -> Entity? {
        if let existing = instances[owner] { return existing.root }
        let skeleton: SkeletonDefinition
        var library = MotionLibrary.standard
        switch source {
        case .humanBase(let look):
            guard let body = body(for: look, lod: 0) else { return nil }
            skeleton = body.skeleton
            // A model base has its own bind pose: the shared motions are retargeted onto it.
            if look.base?.hasPrefix("model.") == true, let base = HumanBaseAsset.shared.flatMap({ HumanBase.build(.standard, asset: $0) })?.skeleton {
                library = MotionLibrary.standard.map { MotionRetargeter.retarget($0, from: base, to: skeleton).0 }
            }
        case .rigged(let mesh, let s, let skin, let own):
            let check = CharacterValidator.validate(mesh: mesh, skeleton: s, skin: skin, humanoid: true)
            guard check.ok else {
                record(owner, "-", L10n.t("模型未通过检查：", "The model failed its checks: ") + check.errors.map(\.message).prefix(2).joined(separator: "; "))
                return nil
            }
            skeleton = s
            // The standard library, retargeted from the base body onto this rig, plus the model's own clips.
            if let base = HumanBaseAsset.shared.flatMap({ HumanBase.build(.standard, asset: $0) })?.skeleton {
                library = MotionLibrary.standard.map { MotionRetargeter.retarget($0, from: base, to: s).0 }
            }
            library += own.filter { o in !library.contains { $0.id == o.id } }
        }
        let controller = CharacterAnimationController(library: library, legLength: RigPoser.legLength(skeleton))
        let instance = Instance(owner: owner, source: source, skeleton: skeleton, controller: controller)
        // Moonlight rigs face +z; world holders face +x (their "nose").
        instance.body.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        instances[owner] = instance
        setLOD(instance, 0)
        stats.instances = instances.count
        return instance.root
    }

    func has(_ owner: String) -> Bool { instances[owner] != nil }

    func remove(_ owner: String) {
        instances[owner]?.root.removeFromParent()
        instances[owner] = nil
        stats.instances = instances.count
    }
    func removeAll() { for owner in Array(instances.keys) { remove(owner) } }

    /// New look for an existing instance (keeps its animation state).
    func setAppearance(_ owner: String, _ look: CharacterAppearance) {
        guard let instance = instances[owner], case .humanBase = instance.source, let body = body(for: look, lod: max(0, instance.lod)) else { return }
        instance.source = .humanBase(look)
        instance.skeleton = body.skeleton
        instance.controller.legLength = RigPoser.legLength(body.skeleton)
        let lod = max(0, instance.lod)
        instance.lod = -1
        setLOD(instance, lod)
    }

    /// A rigged model's own material (its texture), kept across LODs.
    func applyMaterial(_ owner: String, _ material: RealityKit.Material) {
        guard let instance = instances[owner] else { return }
        instance.texture = material
        for layer in instance.layers { layer.entity.model?.materials = [material] }
    }

    /// v1.92: a painted skin's texture on the body (outfit layers keep their own materials).
    func applySkinTexture(_ owner: String, _ texture: TextureResource) {
        guard let instance = instances[owner], let body = instance.layers.first else { return }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white, texture: .init(texture))
        m.roughness = .init(floatLiteral: 0.75)
        instance.texture = m
        body.entity.model?.materials = [m]
    }

    // MARK: Garments (v1.93)

    private var garmentSources: [String: GeneratedMesh] = [:]
    private var garmentMaterials: [String: RealityKit.Material] = [:]
    private var garmentFits: [String: SkinnedPart] = [:]
    private var fitting: Set<String> = []
    private var failedFits: Set<String> = []
    /// What the last fit of each garment reported (sleeve angle, pushed points).
    private(set) var garmentNotes: [String: [String]] = [:]
    /// Called when a garment's fit is ready (the workbench shows its notes).
    var onGarmentFitted: ((String) -> Void)?

    static func garmentKey(_ g: CustomGarment, look: CharacterAppearance) -> String {
        let a = g.adjust.clamped
        return g.id + "|" + (look.base ?? "") + key(look.shape) + String(format: "|%.3f|%.3f|%.3f|%d|%.1f|%.4f", a.scale, a.lift, a.forward, a.quarterTurns, a.armDrop ?? -1, a.gap)
    }

    /// A garment's source mesh (from its character package or a model); fitted when worn.
    func registerGarment(_ id: String, mesh: GeneratedMesh) {
        guard garmentSources[id] != mesh else { return }
        garmentSources[id] = mesh
        garmentFits = garmentFits.filter { !$0.key.hasPrefix(id + "|") }
        failedFits = failedFits.filter { !$0.hasPrefix(id + "|") }
        refresh(wearing: id)
    }
    func hasGarment(_ id: String) -> Bool { garmentSources[id] != nil }
    func applyGarmentTexture(_ id: String, _ texture: TextureResource) {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: .white, texture: .init(texture))
        m.roughness = .init(floatLiteral: 0.7)
        garmentMaterials[id] = m
        refresh(wearing: id)
    }
    private func refresh(wearing id: String) {
        for instance in instances.values {
            guard case .humanBase(let look) = instance.source, look.garmentList.contains(where: { $0.id == id }) else { continue }
            let lod = max(0, instance.lod)
            instance.lod = -1
            setLOD(instance, lod)
        }
        onGarmentFitted?(id)
    }

    /// The owner is turned by a billboard, not by its facing (front-only reliefs).
    func setFacesCamera(_ owner: String) { instances[owner]?.facesCamera = true }

    // MARK: Model bases (v1.92)

    private var modelBodies: [String: HumanBody] = [:]
    private var modelMaterials: [String: RealityKit.Material] = [:]
    /// A model base (AI 3D or imported model, rigged) ready to use; `material` is its own texture.
    func registerModelBase(_ id: String, body: HumanBody, material: RealityKit.Material?) {
        modelBodies[id] = body
        if let material { modelMaterials[id] = material }
    }
    func hasModelBase(_ id: String) -> Bool { modelBodies[id] != nil }
    private var loadingBases: Set<String> = []
    /// Loads a model base ("model.<Generated3D id>") with its texture and registers it.
    /// False when the model is gone or has no rig.
    @discardableResult
    func prepareModelBase(_ id: String) async -> Bool {
        if modelBodies[id] != nil { return true }
        guard id.hasPrefix("model."), !loadingBases.contains(id) else { return false }
        loadingBases.insert(id); defer { loadingBases.remove(id) }
        guard let loaded = await CharacterLibrary.loadModelBody(String(id.dropFirst(6))) else {
            record(id, "-", L10n.t("模型底模无法加载（模型已删除或没有骨骼）", "The model base could not load (deleted, or no rig)"))
            return false
        }
        var material: RealityKit.Material?
        if let url = loaded.texture, let texture = try? await TextureResource(contentsOf: url, options: .init(semantic: .color)) {
            var m = PhysicallyBasedMaterial(); m.baseColor = .init(tint: .white, texture: .init(texture)); m.roughness = .init(floatLiteral: 0.8)
            material = m
        }
        registerModelBase(id, body: loaded.body, material: material)
        return true
    }
    /// The body for a look: its model base when it has one, else HumanBase in its shape.
    private func body(for look: CharacterAppearance, lod: Int) -> HumanBody? {
        if let base = look.base, base.hasPrefix("model.") { return modelBodies[base] }
        return body(look.shape, lod: lod)
    }

    /// The skeleton an owner is posed with (workbench, sockets, IK).
    func skeleton(_ owner: String) -> SkeletonDefinition? { instances[owner]?.skeleton }

    // MARK: Per frame

    /// Advances an owner's animation to `input.clock` and deforms it if it is
    /// visible and due. Returns the motion events crossed (each once).
    @discardableResult
    func update(_ owner: String, input: AnimationInput, cameraDistance: Float, visible: Bool, facingDegrees: Float? = nil) -> [FiredMotionEvent] {
        guard let instance = instances[owner] else { return [] }
        let result = instance.controller.update(input)
        if let facingDegrees, facingDegrees.isFinite, !instance.facesCamera {
            instance.root.orientation = simd_quatf(angle: facingDegrees * .pi / 180, axis: [0, 1, 0])
        }
        // A squashed holder (a dead creature's old look) must not flatten the body.
        if let parent = instance.root.parent, parent.scale != [1, 1, 1] { instance.root.scale = SIMD3(1 / max(0.05, parent.scale.x), 1 / max(0.05, parent.scale.y), 1 / max(0.05, parent.scale.z)) }
        else if instance.root.scale != [1, 1, 1] { instance.root.scale = [1, 1, 1] }
        guard visible else { stats.skipped += 1; return result.events }
        let lod = cameraDistance < Self.lodDistances[0] ? 0 : cameraDistance < Self.lodDistances[1] ? 1 : 2
        if lod != instance.lod { setLOD(instance, lod) }
        // Near: 30 updates a second; middle: 15; far: 8.
        let interval = lod == 0 ? 1.0 / 30 : lod == 1 ? 1.0 / 15 : 1.0 / 8
        guard input.clock - instance.lastDeform >= interval || instance.lastDeform < 0 || input.clock < instance.lastDeform else { return result.events }
        // v1.93: a main-thread budget. Skinning runs on the main thread; past the budget a
        // character waits for a later frame (the player at least every 0.1 s, everyone at
        // least once a second), so touches and the rest of the frame keep their time.
        if overBudget(), instance.lastDeform >= 0, input.clock >= instance.lastDeform {
            let waited = input.clock - instance.lastDeform
            let mustRun = owner == SpatialBattle.playerID ? waited >= 0.1 : waited >= 1
            if !mustRun { stats.deferred += 1; return result.events }
        }
        instance.lastDeform = input.clock
        deform(instance, result.pose, motion: input.action.rawValue)
        return result.events
    }

    /// Holds an owner at one level of detail (the base-body view compares them).
    func useLOD(_ owner: String, _ lod: Int) {
        guard let instance = instances[owner], (0...2).contains(lod), lod != instance.lod else { return }
        setLOD(instance, lod)
    }
    func lod(_ owner: String) -> Int { instances[owner]?.lod ?? -1 }

    /// Poses an owner directly (workbench preview: a chosen motion and time, or the bind pose).
    func pose(_ owner: String, motion: UniversalMotion?, time: Float) {
        guard let instance = instances[owner] else { return }
        // The instance's own (for rigged models: retargeted) copy of the motion.
        let motion = motion.map { instance.controller.library[$0.id] ?? $0 }
        let sample = motion?.sample(at: time, legLength: RigPoser.legLength(instance.skeleton), skeleton: instance.skeleton) ?? MotionSample()
        if instance.lod < 0 { setLOD(instance, 0) }
        deform(instance, sample, motion: motion?.id ?? "bind")
    }

    /// Share of wall time skinning may take, over a quarter-second window.
    static let busyShare = 0.4, busyWindow = 0.25
    private var windowStart = CFAbsoluteTimeGetCurrent()
    private var windowSpent = 0.0
    private func overBudget() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - windowStart > Self.busyWindow { windowStart = now; windowSpent = 0 }
        return windowSpent > Self.busyWindow * Self.busyShare
    }

    private func deform(_ instance: Instance, _ sample: MotionSample, motion: String) {
        let started = CFAbsoluteTimeGetCurrent()
        defer { windowSpent += CFAbsoluteTimeGetCurrent() - started }
        var pose = sample
        var matrices = RigPoser.skinning(pose, skeleton: instance.skeleton)
        if !matrices.allSatisfy(\.finite) {
            record(instance.owner, motion, L10n.t("动作产生了无效的骨骼矩阵，已退回上一帧", "the motion produced invalid joint matrices; the last good pose is shown"))
            pose = instance.lastGood ?? MotionSample()
            matrices = RigPoser.skinning(pose, skeleton: instance.skeleton)
        } else {
            instance.lastGood = pose
        }
        for layer in instance.layers {
            let out = SkinWeightSolver.deform(layer.player.mesh, skin: layer.skin, matrices: matrices)
            layer.player.update(positions: out.positions, normals: out.normals)
        }
        stats.deformations += 1
        if !instance.equipment.isEmpty || showSkeleton {
            let world = instance.skeleton.worldTransforms(local: RigPoser.locals(pose, skeleton: instance.skeleton))
            for (item, entity) in instance.equipment {
                if let x = EquipmentBuilder.transform(item, skeleton: instance.skeleton, world: world), x.finite { entity.transform = Transform(matrix: x.simd) }
            }
            if showSkeleton { showJoints(instance, world) }
        }
    }

    private func showJoints(_ instance: Instance, _ world: [RigXform]) {
        let holder = instance.body.findEntity(named: "joints") ?? {
            let e = Entity(); e.name = "joints"; instance.body.addChild(e)
            let material = UnlitMaterial(color: .systemYellow)
            for i in instance.skeleton.joints.indices { e.addChild(ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [material])) }
            return e
        }()
        for (i, child) in holder.children.enumerated() where i < world.count { child.position = world[i].origin }
        if instance.shownHighlight != highlightedJoints {
            instance.shownHighlight = highlightedJoints
            let plain = UnlitMaterial(color: .systemYellow), marked = UnlitMaterial(color: .systemPink)
            for (i, child) in holder.children.enumerated() where i < instance.skeleton.joints.count {
                let on = highlightedJoints.contains(instance.skeleton.joints[i].jointID)
                (child as? ModelEntity)?.model?.materials = [on ? marked : plain]
                child.scale = on ? [2, 2, 2] : [1, 1, 1]
            }
        }
        holder.isEnabled = showSkeleton
    }

    // MARK: Building

    private func body(_ shape: HumanShape, lod: Int) -> HumanBody? {
        let key = Self.key(shape) + "|\(lod)"
        if let cached = bodyCache[key] { return cached }
        guard let built = HumanBase.build(shape, lod: lod) else { return nil }
        bodyCache[key] = built; bodyOrder.append(key)
        if bodyOrder.count > Self.maxCachedBodies { let old = bodyOrder.removeFirst(); bodyCache[old] = nil; outfitCache = outfitCache.filter { !$0.key.hasPrefix(old) } }
        stats.cachedBodies = bodyCache.count
        return built
    }

    static func key(_ shape: HumanShape) -> String {
        let s = shape.clamped
        return [s.height, s.build, s.muscle, s.gender, s.age ?? 0, s.shoulders, s.hips, s.waist, s.neck, s.legLength, s.armLength, s.torsoLength, s.headSize, s.hands, s.feet, s.faceOval, s.faceRound, s.faceSquare]
            .map { String(format: "%.3f", $0) }.joined(separator: ",")
    }

    private func setLOD(_ instance: Instance, _ lod: Int) {
        for layer in instance.layers { layer.entity.removeFromParent() }
        for (_, e) in instance.equipment { e.removeFromParent() }
        instance.layers = []; instance.equipment = []
        instance.lod = lod
        switch instance.source {
        case .humanBase(let look):
            guard let body = body(for: look, lod: lod) else { return }
            instance.skeleton = body.skeleton
            if let skin = look.painted {
                // v1.92: the body repainted from its skin photos for this shape and LOD (cached).
                let key = (look.base ?? "") + Self.key(look.shape) + "|\(lod)|skin|\(skin.front.points.count)|\(skin.back != nil)|\(skin.atlas)"
                let part = outfitCache[key] ?? { let p = BaseBodyPaint.paint(body.model, front: skin.front, back: skin.back); return SkinnedPart(mesh: p.mesh, skin: p.skin) }()
                outfitCache[key] = part
                addLayer(instance, mesh: part.mesh, skin: part.skin, material: instance.texture ?? material(CharacterMaterialProfile(baseColor: SIMD3(1, 1, 1), roughness: 0.8)))
            } else {
                addLayer(instance, mesh: body.mesh, skin: body.skin, material: look.base.flatMap { modelMaterials[$0] } ?? material(look.skin))
            }
            for piece in look.pieces {
                let key = (look.base ?? "") + Self.key(look.shape) + "|\(lod)|" + piece.id
                let part = outfitCache[key] ?? OutfitBuilder.build(piece, on: body)
                if let part { outfitCache[key] = part; addLayer(instance, mesh: part.mesh, skin: part.skin, material: material(piece.material)) }
            }
            // v1.93: garments from AI 3D / imported models, fitted off the main thread once per body.
            for garment in look.garmentList {
                let key = Self.garmentKey(garment, look: look)
                if let part = garmentFits[key] {
                    addLayer(instance, mesh: part.mesh, skin: part.skin, material: garmentMaterials[garment.id] ?? material(CharacterMaterialProfile(baseColor: garment.color, roughness: 0.7)))
                } else if let source = garmentSources[garment.id], !fitting.contains(key), !failedFits.contains(key), let fitBody = self.body(for: look, lod: 0) {
                    fitting.insert(key)
                    let slot = garment.slot, adjust = garment.adjust, id = garment.id, owner = instance.owner
                    Task { @MainActor [weak self] in
                        let result = await Task.detached(priority: .userInitiated) { GarmentFit.fit(source, slot: slot, on: fitBody, adjust: adjust) }.value
                        guard let self else { return }
                        self.fitting.remove(key)
                        if let result { self.garmentFits[key] = result.part; self.garmentNotes[id] = result.notes }
                        else { self.failedFits.insert(key); self.record(owner, "-", L10n.t("服装无法贴合（模型为空、损坏或超过 6 万顶点）", "The garment could not be fitted (empty, damaged or over 60,000 vertices)")) }
                        self.refresh(wearing: id)
                    }
                }
            }
            for item in look.items {
                let resource = equipmentCache[item.id] ?? (try? Self.resource(EquipmentBuilder.mesh(item)))
                guard let resource else { continue }
                equipmentCache[item.id] = resource
                let entity = ModelEntity(mesh: resource, materials: [material(item.material)])
                instance.body.addChild(entity); instance.equipment.append((item, entity))
            }
        case .rigged(let mesh, _, let skin, _):
            addLayer(instance, mesh: mesh, skin: skin, material: instance.texture ?? material(CharacterMaterialProfile(baseColor: SIMD3(1, 1, 1), roughness: 0.8)))
        }
        if stats.lodCounts.indices.contains(lod) { stats.lodCounts[lod] += 1 }
        instance.lastDeform = -1
        if let good = instance.lastGood { deform(instance, good, motion: "lod") }
    }

    private func addLayer(_ instance: Instance, mesh: GeneratedMesh, skin: SkinInfluences, material: RealityKit.Material) {
        guard let player = try? SkinnedMeshPlayer(mesh: mesh) else { record(instance.owner, "-", L10n.t("无法创建动态网格", "could not create a dynamic mesh")); return }
        let entity = ModelEntity(mesh: player.resource, materials: [material])
        instance.body.addChild(entity)
        instance.layers.append(Layer(player: player, skin: skin, entity: entity))
    }

    /// RealityKit material for a profile (cached by value).
    func material(_ profile: CharacterMaterialProfile) -> RealityKit.Material {
        let p = profile.clamped
        let key = "\(p.baseColor)|\(p.metallic)|\(p.roughness)|\(p.opacity)|\(p.emission)|\(p.emissionStrength)|\(p.style.rawValue)"
        if let cached = materialCache[key] { return cached }
        let color = UIColor(red: CGFloat(p.baseColor.x), green: CGFloat(p.baseColor.y), blue: CGFloat(p.baseColor.z), alpha: 1)
        let made: RealityKit.Material
        switch p.style {
        case .toon, .pixel:
            // Flat, unlit colour reads as cel / pixel art from any light.
            made = UnlitMaterial(color: color)
        default:
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: color)
            m.metallic = .init(floatLiteral: p.metallic)
            m.roughness = .init(floatLiteral: p.style == .oilPaint ? 1 : p.roughness)
            if p.emissionStrength > 0 {
                m.emissiveColor = .init(color: UIColor(red: CGFloat(p.emission.x), green: CGFloat(p.emission.y), blue: CGFloat(p.emission.z), alpha: 1))
                m.emissiveIntensity = p.emissionStrength
            }
            if p.transparent { m.blending = .transparent(opacity: .init(floatLiteral: p.opacity)) }
            made = m
        }
        materialCache[key] = made
        return made
    }

    static func resource(_ mesh: GeneratedMesh) throws -> MeshResource {
        var d = MeshDescriptor(name: "character-part")
        d.positions = MeshBuffers.Positions((0..<mesh.vertexCount).map { SIMD3(mesh.positions[$0 * 3], mesh.positions[$0 * 3 + 1], mesh.positions[$0 * 3 + 2]) })
        d.normals = MeshBuffers.Normals((0..<mesh.vertexCount).map { SIMD3(mesh.normals[$0 * 3], mesh.normals[$0 * 3 + 1], mesh.normals[$0 * 3 + 2]) })
        d.textureCoordinates = MeshBuffers.TextureCoordinates((0..<mesh.vertexCount).map { SIMD2(mesh.uvs[$0 * 2], mesh.uvs[$0 * 2 + 1]) })
        d.primitives = .triangles(mesh.indices)
        return try MeshResource.generate(from: [d])
    }

    private func record(_ owner: String, _ motion: String, _ reason: String) {
        incidents.append(Incident(owner: owner, motion: motion, reason: reason, date: Date()))
        if incidents.count > 50 { incidents.removeFirst(incidents.count - 50) }
    }
}
