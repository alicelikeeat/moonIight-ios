import RealityKit
import UIKit

/// Skill visuals and media characters for the RealityKit world.
/// Particles use RealityKit's GPU particle emitters (one per burst, short
/// lived, capped); projectiles and beams come from small reused pools;
/// characters are camera-facing media planes (billboards), direction
/// pictures, flat layers or USDZ models.
@available(iOS 18.0, *)
@MainActor final class Glass3DEffects {
    static let burstLimit = 40
    let root = Entity()
    private var bursts: [(entity: Entity, until: Double)] = []
    private var projectilePool: [ModelEntity] = []
    private var beamPool: [ModelEntity] = []
    private(set) var shake = 0.0

    // MARK: Particles

    func burst(_ preset: ParticlePreset, at point: SpatialVector, seconds: Double, clock: Double, quality: RPGGlassQuality) {
        if bursts.count >= Self.burstLimit { bursts.removeFirst().entity.removeFromParent() }
        let entity = Entity()
        entity.position = Glass3DRenderer.position(point)
        entity.components.set(Self.emitter(preset, seconds: seconds, quality: quality))
        root.addChild(entity)
        bursts.append((entity, clock + seconds + 1.2))
    }

    static func emitter(_ preset: ParticlePreset, seconds: Double, quality: RPGGlassQuality) -> ParticleEmitterComponent {
        var emitter = ParticleEmitterComponent()
        let color = UIColor(rpgHex: preset.hex)
        // Performance quality halves the particle count; hits are unaffected.
        let scale: Float = quality == .performance ? 0.5 : quality == .high ? 1.3 : 1
        emitter.emitterShape = .sphere
        emitter.emitterShapeSize = [0.25, 0.25, 0.25]
        emitter.mainEmitter.blendMode = .additive
        emitter.mainEmitter.color = .evolving(start: .single(color), end: .single(color.withAlphaComponent(0)))
        emitter.timing = .once(warmUp: nil, emit: .init(duration: max(0.15, seconds)))
        switch preset {
        case .fire:
            emitter.mainEmitter.birthRate = 260 * scale; emitter.mainEmitter.lifeSpan = 0.7; emitter.speed = 0.8; emitter.mainEmitter.size = 0.08; emitter.mainEmitter.acceleration = [0, 1.5, 0]
        case .ice:
            emitter.mainEmitter.birthRate = 180 * scale; emitter.mainEmitter.lifeSpan = 0.9; emitter.speed = 1.2; emitter.mainEmitter.size = 0.05
        case .lightning:
            emitter.mainEmitter.birthRate = 400 * scale; emitter.mainEmitter.lifeSpan = 0.25; emitter.speed = 3; emitter.mainEmitter.size = 0.03
        case .spark:
            emitter.mainEmitter.birthRate = 300 * scale; emitter.mainEmitter.lifeSpan = 0.5; emitter.speed = 2.5; emitter.mainEmitter.size = 0.025; emitter.mainEmitter.acceleration = [0, -4, 0]
        case .smoke:
            emitter.mainEmitter.blendMode = .alpha
            emitter.mainEmitter.birthRate = 90 * scale; emitter.mainEmitter.lifeSpan = 1.4; emitter.speed = 0.5; emitter.mainEmitter.size = 0.18; emitter.mainEmitter.acceleration = [0, 0.6, 0]
        case .magic:
            emitter.mainEmitter.birthRate = 220 * scale; emitter.mainEmitter.lifeSpan = 0.8; emitter.speed = 0.7; emitter.mainEmitter.size = 0.04
        case .charge:
            emitter.emitterShapeSize = [1.2, 1.2, 1.2]
            emitter.mainEmitter.birthRate = 260 * scale; emitter.mainEmitter.lifeSpan = 0.5; emitter.speed = -2; emitter.mainEmitter.size = 0.04
        case .explosion:
            emitter.mainEmitter.birthRate = 1600 * scale; emitter.mainEmitter.lifeSpan = 0.6; emitter.speed = 4; emitter.mainEmitter.size = 0.09
            emitter.timing = .once(warmUp: nil, emit: .init(duration: 0.15))
        case .heal:
            emitter.emitterShapeSize = [0.8, 0.1, 0.8]
            emitter.mainEmitter.birthRate = 160 * scale; emitter.mainEmitter.lifeSpan = 1.2; emitter.speed = 0.6; emitter.mainEmitter.size = 0.05; emitter.mainEmitter.acceleration = [0, 1.2, 0]
        }
        emitter.isEmitting = true
        return emitter
    }

    // MARK: Per-frame visuals

    /// Shows this frame's projectiles and beams, starts bursts, and lets
    /// old bursts go.
    func show(_ visuals: [SkillVisual], clock: Double, quality: RPGGlassQuality, renderer: Glass3DRenderer) {
        var projectiles = 0, beams = 0
        for visual in visuals {
            switch visual {
            case .particles(let preset, let point, let seconds): burst(preset, at: point, seconds: seconds, clock: clock, quality: quality)
            case .projectile(_, let point, let preset, let radius):
                let entity = pooled(&projectilePool, index: projectiles) { ModelEntity(mesh: .generateSphere(radius: 1), materials: [Self.glow(.white)]) }
                entity.position = Glass3DRenderer.position(point); entity.scale = SIMD3(repeating: Float(radius))
                entity.model?.materials = [Self.glow(UIColor(rpgHex: preset.hex))]
                projectiles += 1
            case .beam(let from, let to, let width, let preset):
                let entity = pooled(&beamPool, index: beams) { ModelEntity(mesh: .generateBox(size: 1), materials: [Self.glow(.white)]) }
                let a = Glass3DRenderer.position(from), b = Glass3DRenderer.position(to)
                let length = simd_length(b - a)
                entity.position = (a + b) / 2
                entity.orientation = simd_quatf(from: [0, 0, 1], to: simd_normalize(b - a))
                entity.scale = [Float(width), Float(width), length]
                entity.model?.materials = [Self.glow(UIColor(rpgHex: preset.hex).withAlphaComponent(0.75))]
                beams += 1
            case .telegraph(let center, let radius, let seconds): renderer.telegraph(id: "skill-\(center.x)-\(center.y)-\(clock)", at: center, radius: radius, seconds: seconds)
            case .shake(let amount): shake = max(shake, amount)
            case .action, .dash: break
            }
        }
        for (i, entity) in projectilePool.enumerated() { entity.isEnabled = i < projectiles }
        for (i, entity) in beamPool.enumerated() { entity.isEnabled = i < beams }
        while let first = bursts.first, first.until < clock { first.entity.removeFromParent(); bursts.removeFirst() }
    }

    /// Camera shake fades out over a few frames.
    func shakeOffset(dt: Double) -> SpatialVector {
        guard shake > 0.01 else { shake = 0; return .zero }
        let amount = shake * 0.25
        shake = max(0, shake - dt * 1.5)
        return SpatialVector(Double.random(in: -amount...amount), Double.random(in: -amount...amount), Double.random(in: -amount...amount) * 0.5)
    }

    private func pooled(_ pool: inout [ModelEntity], index: Int, make: () -> ModelEntity) -> ModelEntity {
        if index < pool.count { return pool[index] }
        let entity = make(); pool.append(entity); root.addChild(entity)
        return entity
    }

    static func glow(_ color: UIColor) -> RealityKit.Material {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        return material
    }
}

/// Media characters: one appearance entity per body, rebuilt only when its
/// action or direction picture changes.
@available(iOS 18.0, *)
@MainActor final class Glass3DCharacters {
    private struct Shown { var key: String; var entity: Entity }
    private var shown: [String: Shown] = [:]
    private var models: [String: Entity] = [:]
    private var loading: Set<String> = []
    var media: Glass3DMedia?
    /// AI-generated models (v1.69), animated when rigged.
    let generated = Glass3DGeneratedLooks()
    /// v1.91: every rigged character (base-body characters and rigged AI models).
    let runtime = CharacterRuntime()
    /// Directory of imported USDZ models.
    static var modelsFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Glass3DModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Puts the template's look on `holder` (the player or a creature). Returns
    /// false when there is no usable look, so the default body stays.
    @discardableResult
    func apply(_ template: CharacterTemplate?, to holder: Entity, ownerID: String, action: CharacterAction, direction: Int) -> Bool {
        guard let template else { remove(ownerID); return false }
        if let shown = applyRuntime(template, to: holder, ownerID: ownerID) { return shown }
        let actionKey = template.mode == .generated ? RigClip.id(for: action) + (generated.isReady(template) ? "" : "-loading") : action.rawValue
        let key = "\(template.id)|\(template.mode.rawValue)|\(actionKey)|\(direction)|\(template.height)|\(template.aspect)|\(template.footAnchor)|\(template.opacity)"
        if let current = shown[ownerID], current.key == key, current.entity.parent === holder { return true }
        remove(ownerID)
        let entity: Entity?
        switch template.mode {
        case .model: entity = model(template)
        case .generated: entity = generated.entity(template, action: action)
        case .layered: entity = layered(template, action: action)
        default: entity = billboard(template, action: action, direction: direction)
        }
        guard let entity else { return false }
        holder.addChild(entity)
        shown[ownerID] = Shown(key: key, entity: entity)
        return true
    }

    func remove(_ ownerID: String) { shown[ownerID]?.entity.removeFromParent(); shown[ownerID] = nil; runtime.remove(ownerID) }

    /// v1.91: base-body characters and rigged AI models go through the
    /// CharacterRuntime (real 3D bodies with their own animation). Nil:
    /// not a runtime character, use the older paths.
    private var lastBuild = 0.0
    private func mayBuild() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastBuild >= 0.25 else { return false }
        lastBuild = now
        return true
    }

    private func applyRuntime(_ template: CharacterTemplate, to holder: Entity, ownerID: String) -> Bool? {
        switch template.mode {
        case .standard:
            guard let id = template.characterID, let package = CharacterLibrary.shared.package(id) else { remove(ownerID); return false }
            let look = package.appearance
            let key = "\(template.id)|standard|\(id)|\(CharacterRuntime.key(look.shape))|\(look.outfit.joined(separator: ","))|\(look.equipment.joined(separator: ","))|\(look.skin.baseColor)|\(look.skin.style.rawValue)|\(look.base ?? "")|\(look.painted?.atlas ?? "-")|\(look.garmentList.map { CharacterRuntime.garmentKey($0, look: look) }.joined(separator: ","))"
            if let current = shown[ownerID], current.key == key, current.entity.parent === holder { return true }
            // v1.93: building a body (shape, outfit, garments) takes the main thread for a while;
            // at most one every quarter second (the player first), so a world that comes back
            // with several new characters stays responsive. Until then the old look stays.
            if ownerID != SpatialBattle.playerID, !mayBuild() { return shown[ownerID]?.entity.parent === holder ? true : false }
            remove(ownerID)
            if let base = look.base, base.hasPrefix("model."), !runtime.hasModelBase(base) {
                // v1.92: a model base loads in the background; the default body shows meanwhile.
                Task { @MainActor [runtime] in await runtime.prepareModelBase(base) }
                return false
            }
            // v1.93: fitted garments' meshes come with the package; textures load off the frame.
            for garment in look.garmentList where !runtime.hasGarment(garment.id) {
                if let mesh = package.garments[garment.mesh].flatMap({ GeneratedMeshCodec.decode($0) }) { runtime.registerGarment(garment.id, mesh: mesh) }
                if garment.texture != nil {
                    let g = garment
                    Task { @MainActor [runtime] in
                        if let material = await CharacterShading.garment(package: id, g) { runtime.applyGarmentMaterial(g.id, material) }
                    }
                }
            }
            guard let entity = runtime.entity(owner: ownerID, source: .humanBase(look)) else { return false }
            if let skin = look.painted {
                // v1.92: the painted skin's texture, loaded off the frame.
                Task { @MainActor [runtime] in
                    if let material = await CharacterShading.skin(package: id, skin) { runtime.applySkinMaterial(ownerID, material) }
                }
            }
            let wrapper = Entity(); wrapper.addChild(entity)
            if template.shadow { wrapper.addChild(Self.shadow(radius: look.shape.height * 0.16)) }
            holder.addChild(wrapper)
            shown[ownerID] = Shown(key: key, entity: wrapper)
            return true
        case .generated:
            guard let found = generated.runtimeSource(template) else { return nil }
            let key = "\(template.id)|rigged|\(template.generatedModelID ?? "")|\(template.height)"
            if let current = shown[ownerID], current.key == key, current.entity.parent === holder { return true }
            remove(ownerID)
            guard let entity = runtime.entity(owner: ownerID, source: found.source) else { return nil }
            runtime.applyMaterial(ownerID, found.material)
            let scale = Float(template.height) / max(0.01, found.height)
            let wrapper = Entity()
            let sized = Entity(); sized.scale = SIMD3(repeating: scale); sized.position = [0, -found.minY * scale, 0]
            sized.addChild(entity); wrapper.addChild(sized)
            if found.relief {
                // A relief has no back: it keeps facing the camera, as before.
                sized.components.set(BillboardComponent())
                entity.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
                runtime.setFacesCamera(ownerID)
            }
            if template.shadow { wrapper.addChild(Self.shadow(radius: Float(template.height) * 0.25)) }
            holder.addChild(wrapper)
            shown[ownerID] = Shown(key: key, entity: wrapper)
            return true
        default:
            return nil
        }
    }

    private func billboard(_ template: CharacterTemplate, action: CharacterAction, direction: Int) -> Entity? {
        guard let clip = template.clip(action), !clip.bindingIDs.isEmpty,
              let material = media?.material(forBinding: clip.bindingIDs[direction % clip.bindingIDs.count], opacity: template.opacity) else { return nil }
        let height = Float(template.height), width = height * Float(template.aspect)
        let plane = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
        plane.position = [0, height / 2 - Float(template.footAnchor) * height, 0]
        // Direction pictures stay upright and face the camera.
        plane.components.set(BillboardComponent())
        let holder = Entity(); holder.addChild(plane)
        if template.shadow { holder.addChild(Self.shadow(radius: width * 0.45)) }
        return holder
    }

    private func layered(_ template: CharacterTemplate, action: CharacterAction) -> Entity? {
        guard let clip = template.clip(action), !clip.bindingIDs.isEmpty else { return nil }
        let holder = Entity()
        let height = Float(template.height), width = height * Float(template.aspect)
        for (i, id) in clip.bindingIDs.prefix(6).enumerated() {
            guard let material = media?.material(forBinding: id, opacity: template.opacity) else { continue }
            let layer = ModelEntity(mesh: .generatePlane(width: width, height: height), materials: [material])
            layer.position = [0, height / 2, Float(i) * -Float(template.layerDepth)]
            holder.addChild(layer)
        }
        // Layers turn together toward the camera.
        holder.components.set(BillboardComponent())
        return holder.children.isEmpty ? nil : holder
    }

    private func model(_ template: CharacterTemplate) -> Entity? {
        guard let file = template.modelMediaID else { return nil }
        if let loaded = models[file] {
            let copy = loaded.clone(recursive: true)
            // v1.76: models with their own animations loop the first one.
            if let first = copy.availableAnimations.first { copy.playAnimation(first.repeat()) }
            return Self.fitted(copy, height: template.height)
        }
        guard !loading.contains(file) else { return nil }
        loading.insert(file)
        let url = Self.modelsFolder.appendingPathComponent(file)
        Task { @MainActor [weak self] in
            if let entity = try? await Entity(contentsOf: url) { self?.models[file] = entity }
            self?.loading.remove(file)
        }
        return nil
    }

    /// Scales a model so its height matches the template, feet on the ground.
    static func fitted(_ entity: Entity, height: Double) -> Entity {
        let bounds = entity.visualBounds(relativeTo: nil)
        let size = bounds.extents.y
        if size > 0 { entity.scale = SIMD3(repeating: Float(height) / size) }
        let holder = Entity(); holder.addChild(entity)
        entity.position = [0, -bounds.min.y * entity.scale.y, 0]
        return holder
    }

    static func shadow(radius: Float) -> ModelEntity {
        var material = UnlitMaterial(color: .black)
        material.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: radius), materials: [material])
        disc.position = [0, 0.012, 0]
        return disc
    }
}
