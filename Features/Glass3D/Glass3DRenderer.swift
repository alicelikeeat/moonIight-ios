import RealityKit
import SpriteKit
import UIKit
import AVFoundation
import ImageIO
import Metal

/// Draws the 3D glass world with RealityKit (iOS 18+, RealityView with a
/// virtual camera). World cells (x, y map, z height) map to RealityKit
/// (x, z, −y), Y up. Ground glass is one plane per visible 32×32 chunk;
/// blocks share meshes and materials; media sits on its own face quad with
/// the piece's texture coordinates, so one video player or image serves
/// every piece. Native iOS glass for blocks is drawn by the SwiftUI layer
/// on top (Glass3DNativeGlass), from the same camera maths.
@available(iOS 18.0, *)
@MainActor final class Glass3DRenderer {
    let root = Entity()
    let camera = PerspectiveCamera()
    private let ground = Entity(), blocksRoot = Entity(), plantsRoot = Entity(), creaturesRoot = Entity()
    private let pickupsRoot = Entity(), effects = Entity(), previewRoot = Entity(), selectionRoot = Entity()
    let playerEntity = Entity()
    private var chunkEntities: [Int: ModelEntity] = [:]
    private var blockEntities: [String: Entity] = [:]
    private var blockVersions: [String: SpatialBlock] = [:]
    private var groupEntities: [String: Entity] = [:]
    private var plantChunks: [Int: Entity] = [:]
    private var plantSignature: [Int: Int] = [:]
    private var creatureEntities: [String: Entity] = [:]
    private var pickupEntities: [String: Entity] = [:]
    private var telegraphs: [String: (entity: Entity, start: Double, seconds: Double)] = [:]
    private var meshCache: [String: MeshResource] = [:]
    private var materialCache: [String: RealityKit.Material] = [:]
    private(set) var quality = RPGGlassQuality.standard
    private let sun = DirectionalLight()
    private let dome = ModelEntity(mesh: .generateSphere(radius: 500))
    private var shownAtmosphere: SpatialAtmosphere?
    /// v1.81: world glow strength (night worlds glow more).
    private var glowBoost: Float = 1
    /// Native glass draws the block glass; SceneKit-era glass materials
    /// then thin out to edges so the system glass carries the look.
    private(set) var nativeGlass = false
    private var clock = 0.0
    let media = Glass3DMedia()

    static func position(_ v: SpatialVector) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.z), Float(-v.y)) }

    init() {
        for entity in [ground, blocksRoot, movingBlocksRoot, plantsRoot, creaturesRoot, pickupsRoot, effects, previewRoot, selectionRoot, playerEntity] { root.addChild(entity) }
        camera.camera.fieldOfViewInDegrees = Float(SpatialCameraRules.fieldOfView)
        // v1.78: the glass layer projects with a vertical field of view;
        // say so explicitly so portrait and landscape both match.
        camera.camera.fieldOfViewOrientation = .vertical
        camera.camera.near = 0.1; camera.camera.far = 600
        root.addChild(camera)
        sun.light.intensity = 2600
        sun.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 5, axis: [0, 1, 0])
        root.addChild(sun)
        // Sky dome seen from inside.
        dome.model?.materials = [Self.skyMaterial(Self.skyImage)]
        dome.position = [128, 0, -128]
        root.addChild(dome)
        // Player: a glowing capsule-like body and a nose for facing.
        let body = ModelEntity(mesh: .generateBox(width: 0.6, height: 1.4, depth: 0.6, cornerRadius: 0.3), materials: [Self.solid(.systemTeal, glow: true)])
        body.position = [0, 0.7, 0]
        let nose = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [Self.solid(.white, glow: true)])
        nose.position = [0.32, 1.1, 0]
        playerEntity.addChild(body); playerEntity.addChild(nose)
    }

    // MARK: Atmosphere (v1.81)

    /// Sky gradient and sun for the world (nil: the built-in sky).
    func showAtmosphere(_ atmosphere: SpatialAtmosphere?) {
        guard atmosphere != shownAtmosphere else { return }
        shownAtmosphere = atmosphere
        if let a = atmosphere {
            dome.model?.materials = [Self.skyMaterial(Self.skyImage(top: UIColor(rpgHex: a.skyTop), horizon: UIColor(rpgHex: a.skyHorizon)))]
            sun.light.intensity = Float(400 + a.sunIntensity * 2200)
            let elevation = Float(max(5, a.sunElevation)) * .pi / 180
            sun.orientation = simd_quatf(angle: -elevation, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 5, axis: [0, 1, 0])
            glowBoost = Float(0.6 + a.glow)
        } else {
            dome.model?.materials = [Self.skyMaterial(Self.skyImage)]
            sun.light.intensity = 2600
            sun.orientation = simd_quatf(angle: -.pi / 3, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 5, axis: [0, 1, 0])
            glowBoost = 1
        }
        // Glow strength is part of the block materials.
        materialCache.removeAll()
    }

    static func skyMaterial(_ image: UIImage) -> RealityKit.Material {
        var sky = UnlitMaterial()
        if let cg = image.cgImage, let texture = try? TextureResource(image: cg, options: .init(semantic: .color)) { sky.color = .init(tint: .white, texture: .init(texture)) }
        else { sky.color = .init(tint: UIColor(red: 0.25, green: 0.35, blue: 0.6, alpha: 1)) }
        sky.faceCulling = .front
        return sky
    }

    static func skyImage(top: UIColor, horizon: UIColor) -> UIImage {
        let size = CGSize(width: 8, height: 256)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [top.cgColor, horizon.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }

    // MARK: Quality

    func setQuality(_ value: RPGGlassQuality, nativeGlass: Bool) {
        guard value != quality || nativeGlass != self.nativeGlass else { return }
        quality = value; self.nativeGlass = nativeGlass
        materialCache.removeAll()
        blockEntities.values.forEach { $0.removeFromParent() }; blockEntities.removeAll(); blockVersions.removeAll()
        chunkEntities.values.forEach { $0.removeFromParent() }; chunkEntities.removeAll()
    }

    // MARK: Camera

    func place(camera state: SpatialCameraState, eye: SpatialVector) {
        let yaw = state.yaw * .pi / 180
        // Looking straight down: "up" on screen is map-forward for this turn.
        let up: SIMD3<Float> = state.tilt < 1 ? [Float(-sin(yaw)), 0, Float(-cos(yaw))] : [0, 1, 0]
        camera.look(at: Self.position(state.target), from: Self.position(eye), upVector: up, relativeTo: nil)
    }

    // MARK: Ground

    private var chunkHoleSignature: [Int: Int] = [:]
    /// Glass ground per chunk; chunks with dug holes get a mesh without
    /// those cells, so the way underground is open.
    func showGround(chunks: Set<Int>, holes: Set<Int> = []) {
        for (key, entity) in chunkEntities where !chunks.contains(key) { entity.removeFromParent(); chunkEntities[key] = nil; chunkHoleSignature[key] = nil }
        for key in chunks {
            let cx = key % 8, cy = key / 8
            let chunkHoles = holes.filter { ($0 % 256) / 32 == cx && ($0 / 256) / 32 == cy }
            let signature = chunkHoles.sorted().hashValue
            if chunkEntities[key] != nil && chunkHoleSignature[key] == signature { continue }
            chunkEntities[key]?.removeFromParent()
            chunkHoleSignature[key] = signature
            guard let groundMesh = chunkHoles.isEmpty ? groundMesh : Self.holedGround(cx: cx, cy: cy, holes: chunkHoles) else { continue }
            let plane = ModelEntity(mesh: groundMesh, materials: [groundMaterial()])
            plane.position = [Float(cx * 32 + 16), 0, Float(-(cy * 32 + 16))]
            ground.addChild(plane); chunkEntities[key] = plane
        }
    }

    private func groundMaterial() -> RealityKit.Material {
        if let cached = materialCache["ground"] { return cached }
        var material = UnlitMaterial()
        if let texture = Self.tileTexture { material.color = .init(tint: UIColor(white: 1, alpha: 0.9), texture: .init(texture, sampler: Self.repeatSampler)) }
        material.blending = .transparent(opacity: .init(floatLiteral: 0.9))
        materialCache["ground"] = material
        return material
    }

    /// A chunk's ground as one quad per cell, leaving out dug cells.
    static func holedGround(cx: Int, cy: Int, holes: Set<Int>) -> MeshResource? {
        var positions: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        for ly in 0..<32 { for lx in 0..<32 {
            let x = cx * 32 + lx, y = cy * 32 + ly
            if holes.contains(y * 256 + x) { continue }
            let base = UInt32(positions.count)
            let x0 = Float(lx) - 16, x1 = x0 + 1, z0 = 16 - Float(ly), z1 = z0 - 1
            positions += [[x0, 0, z0], [x1, 0, z0], [x1, 0, z1], [x0, 0, z1]]
            uvs += [[0, 0], [1, 0], [1, 1], [0, 1]]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        } }
        var descriptor = MeshDescriptor(name: "groundHoles")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(Array(repeating: [0, 1, 0], count: positions.count))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// A 32 × 32 plane whose texture coordinates run 0…32, so the glass
    /// tile repeats once per cell.
    private lazy var groundMesh: MeshResource? = {
        var descriptor = MeshDescriptor(name: "groundChunk")
        descriptor.positions = MeshBuffers.Positions([[-16, 0, 16], [16, 0, 16], [16, 0, -16], [-16, 0, -16]])
        descriptor.normals = MeshBuffers.Normals([[0, 1, 0], [0, 1, 0], [0, 1, 0], [0, 1, 0]])
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([[0, 0], [32, 0], [32, 32], [0, 32]])
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3])
        return try? MeshResource.generate(from: [descriptor])
    }()

    // MARK: Blocks

    func showBlocks(_ blocks: [SpatialBlock], pivots: [String: SpatialVector]) {
        let wanted = Set(blocks.map(\.id))
        for (id, entity) in blockEntities where !wanted.contains(id) { entity.removeFromParent(); blockEntities[id] = nil; blockVersions[id] = nil }
        for block in blocks {
            if blockVersions[block.id] == block, let entity = blockEntities[block.id], entity.parent != nil {
                let moving = block.groupID.flatMap { pivots[$0] } != nil
                if moving == (entity.parent !== blocksRoot) { continue }
            }
            blockEntities[block.id]?.removeFromParent()
            let entity = makeBlock(block)
            let center = SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, block.elevation + block.thickness / 2)
            if let group = block.groupID, let pivot = pivots[group] {
                entity.position = Self.position(SpatialVector(center.x - pivot.x, center.y - pivot.y, center.z))
                groupEntity(group).addChild(entity)
            } else {
                entity.position = Self.position(center)
                blocksRoot.addChild(entity)
            }
            blockEntities[block.id] = entity; blockVersions[block.id] = block
        }
        for (group, entity) in groupEntities where entity.children.isEmpty { entity.removeFromParent(); groupEntities[group] = nil }
    }

    private func groupEntity(_ id: String) -> Entity {
        if let entity = groupEntities[id] { return entity }
        let entity = Entity(); movingBlocksRoot.addChild(entity); groupEntities[id] = entity
        return entity
    }

    /// Still blocks fade to a faint body while native glass covers them
    /// (1 = full 3D glass). Moving platforms are never covered, never faded.
    func setBlockGlassOpacity(_ value: Float) {
        guard abs(value - blockGlassOpacity) > 0.01 || (value == 1 && blockGlassOpacity != 1) else { return }
        blockGlassOpacity = value
        if value >= 1 { blocksRoot.components.remove(OpacityComponent.self) }
        else { blocksRoot.components.set(OpacityComponent(opacity: value)) }
    }
    private var blockGlassOpacity: Float = 1
    private let movingBlocksRoot = Entity()

    func place(frames: [String: GroupFrame]) {
        for (id, frame) in frames {
            guard let entity = groupEntities[id] else { continue }
            entity.position = Self.position(SpatialVector(frame.pivot.x + frame.offset.x, frame.pivot.y + frame.offset.y, frame.offset.z))
            entity.orientation = simd_quatf(angle: Float(frame.yaw * .pi / 180), axis: [0, 1, 0])
        }
    }

    private func makeBlock(_ block: SpatialBlock) -> Entity {
        let key = "box|\(block.size)|\(block.thickness)"
        let box = mesh(key) { .generateBox(width: Float(block.size) * 0.98, height: Float(block.thickness), depth: Float(block.size) * 0.98, cornerRadius: Float(min(0.06, block.thickness * 0.2))) }
        let entity = ModelEntity(mesh: box, materials: [glassMaterial(block.glass, collision: block.collision)])
        entity.orientation = simd_quatf(angle: Float(block.yaw * .pi / 180), axis: [0, 1, 0])
        if let reference = block.media, let face = media.face(for: reference, block: block) { entity.addChild(face) }
        return entity
    }

    func glassMaterial(_ glass: SpatialGlass, collision: SpatialCollision) -> RealityKit.Material {
        let key = "glass|\(glass.tintHex ?? "-")|\(glass.density)|\(glass.frosted)|\(glass.glow)|\(collision == .trigger)|\(glass.surface?.rawValue ?? "g")"
        if let cached = materialCache[key] { return cached }
        let tint = glass.tintHex.map { UIColor(rpgHex: $0) } ?? UIColor(white: 0.94, alpha: 1)
        // v1.81: stone and metal are opaque structure; crystal is bright glass.
        if let surface = glass.surface, surface == .stone || surface == .metal {
            let solid: RealityKit.Material
            if quality == .performance {
                solid = UnlitMaterial(color: tint)
            } else {
                var material = PhysicallyBasedMaterial()
                material.baseColor = .init(tint: tint)
                material.roughness = .init(floatLiteral: surface == .stone ? 0.85 : 0.3)
                material.metallic = .init(floatLiteral: surface == .metal ? 0.85 : 0)
                if glass.glow { material.emissiveColor = .init(color: tint); material.emissiveIntensity = 0.6 * glowBoost }
                solid = material
            }
            materialCache[key] = solid
            return solid
        }
        // With native glass shown, `setBlockGlassOpacity` thins these out
        // (edges and a faint body); while the camera moves they carry the
        // full look on their own.
        var opacity = Float(collision == .trigger ? 0.18 : 0.3 + glass.density * 0.5)
        let result: RealityKit.Material
        switch quality {
        case .performance:
            var material = UnlitMaterial()
            if let texture = Self.tileTexture { material.color = .init(tint: tint, texture: .init(texture)) } else { material.color = .init(tint: tint) }
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            result = material
        case .standard, .high:
            var material = PhysicallyBasedMaterial()
            if let texture = Self.tileTexture { material.baseColor = .init(tint: tint, texture: .init(texture)) } else { material.baseColor = .init(tint: tint) }
            material.roughness = .init(floatLiteral: glass.frosted ? 0.6 : 0.08)
            material.metallic = .init(floatLiteral: quality == .high ? 0.15 : 0.02)
            material.clearcoat = .init(floatLiteral: quality == .high ? 1 : 0.4)
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            if glass.glow || glass.surface == .crystal { material.emissiveColor = .init(color: tint); material.emissiveIntensity = (glass.glow ? 0.8 : 0.35) * glowBoost }
            result = material
        }
        materialCache[key] = result
        return result
    }

    // MARK: Plants

    func showPlants(_ plants: [PlantEntity], chunks: Set<Int>) {
        var byChunk: [Int: [PlantEntity]] = [:]
        for plant in plants { let key = (plant.y / 32) * 8 + plant.x / 32; if chunks.contains(key) { byChunk[key, default: []].append(plant) } }
        for (key, entity) in plantChunks where byChunk[key] == nil { entity.removeFromParent(); plantChunks[key] = nil; plantSignature[key] = nil }
        for (key, list) in byChunk {
            var hasher = Hasher(); for plant in list { hasher.combine(plant.id); hasher.combine(plant.x); hasher.combine(plant.y); hasher.combine(plant.z); hasher.combine(plant.kind) }
            let signature = hasher.finalize()
            if plantSignature[key] == signature { continue }
            plantChunks[key]?.removeFromParent()
            let holder = Entity()
            for plant in list { holder.addChild(plantEntity(plant)) }
            plantsRoot.addChild(holder); plantChunks[key] = holder; plantSignature[key] = signature
        }
    }

    private func plantEntity(_ plant: PlantEntity) -> Entity {
        let entity = Entity()
        entity.position = Self.position(SpatialVector(Double(plant.x) + 0.5, Double(plant.y) + 0.5, plant.z))
        entity.scale = SIMD3(repeating: Float(plant.scale))
        let green = UIColor(hue: CGFloat(0.25 + plant.hue * 0.12), saturation: 0.6, brightness: 0.75, alpha: 1)
        func part(_ key: String, _ make: () -> MeshResource, _ color: UIColor, glow: Bool = false, at y: Float, x: Float = 0, z: Float = 0) {
            let model = ModelEntity(mesh: mesh("plant|" + key, make), materials: [material("plant|\(key)|\(color.hashValue)", color: color, glow: glow)])
            model.position = [x, y, z]; entity.addChild(model)
        }
        switch plant.kind {
        case .grass:
            for i in 0..<3 { part("grass", { .generateCone(height: 0.35, radius: 0.05) }, green, at: 0.17, x: Float(i - 1) * 0.1, z: Float(i % 2) * 0.08) }
        case .flower:
            part("stem", { .generateCylinder(height: 0.4, radius: 0.02) }, green, at: 0.2)
            part("flower", { .generateSphere(radius: 0.1) }, UIColor(hue: CGFloat(plant.hue), saturation: 0.7, brightness: 1, alpha: 1), at: 0.42)
        case .bush:
            part("bush", { .generateSphere(radius: 0.42) }, green, at: 0.38)
        case .tree:
            part("trunk", { .generateCylinder(height: 1.0, radius: 0.1) }, .brown, at: 0.5)
            part("crown", { .generateCone(height: 1.5, radius: 0.55) }, green, at: 1.6)
        case .glow:
            part("glowstem", { .generateCylinder(height: 0.3, radius: 0.02) }, .systemTeal, at: 0.15)
            part("glow", { .generateSphere(radius: 0.16) }, .cyan, glow: true, at: 0.35)
        }
        return entity
    }

    // MARK: Creatures, chests, effects

    func showCreatures(_ creatures: [CreatureEntity], near center: SpatialVector, radius: Double) {
        var seen = Set<String>()
        for creature in creatures where (creature.position - center).flatLength <= radius {
            seen.insert(creature.id)
            let entity = creatureEntities[creature.id] ?? makeCreature(creature)
            entity.position = Self.position(creature.position)
            entity.isEnabled = creature.alive || creature.kind.isBoss
            entity.scale = creature.alive ? (creature.state == .hurt ? [1.1, 0.9, 1.1] : [1, 1, 1]) : [1, 0.3, 1]
        }
        for (id, entity) in creatureEntities where !seen.contains(id) { entity.removeFromParent(); creatureEntities[id] = nil }
    }

    private func makeCreature(_ creature: CreatureEntity) -> Entity {
        let entity = Entity()
        let model: ModelEntity
        switch creature.kind {
        case .neutral: model = ModelEntity(mesh: mesh("c-neutral") { .generateSphere(radius: 0.3) }, materials: [material("c-neutral", color: .systemGreen)]); model.position = [0, 0.3, 0]
        case .enemy: model = ModelEntity(mesh: mesh("c-enemy") { .generateCone(height: 1.0, radius: 0.38) }, materials: [material("c-enemy", color: .systemRed)]); model.position = [0, 0.5, 0]
        case .guardian: model = ModelEntity(mesh: mesh("c-guard") { .generateBox(width: 0.7, height: 1.2, depth: 0.7, cornerRadius: 0.1) }, materials: [material("c-guard", color: .systemPurple)]); model.position = [0, 0.6, 0]
        case .miniBoss: model = ModelEntity(mesh: mesh("c-mini") { .generateSphere(radius: 0.7) }, materials: [material("c-mini", color: .systemOrange, glow: true)]); model.position = [0, 0.7, 0]
        case .boss: model = ModelEntity(mesh: mesh("c-boss") { .generateCone(height: 2.8, radius: 1.1) }, materials: [material("c-boss", color: UIColor(red: 0.6, green: 0.05, blue: 0.2, alpha: 1), glow: true)]); model.position = [0, 1.4, 0]
        }
        entity.addChild(model)
        creaturesRoot.addChild(entity); creatureEntities[creature.id] = entity
        return entity
    }

    func showPickups(_ pickups: [PickupEntity], near center: SpatialVector, radius: Double) {
        var seen = Set<String>()
        for pickup in pickups where !pickup.collected && (pickup.position - center).flatLength <= radius {
            seen.insert(pickup.id)
            if pickupEntities[pickup.id] == nil {
                let chest = ModelEntity(mesh: mesh("chest") { .generateBox(width: 0.5, height: 0.35, depth: 0.35, cornerRadius: 0.05) }, materials: [material("chest", color: .systemYellow, glow: true)])
                chest.position = Self.position(pickup.position + SpatialVector(0, 0, 0.2))
                pickupsRoot.addChild(chest); pickupEntities[pickup.id] = chest
            }
        }
        for (id, entity) in pickupEntities where !seen.contains(id) { entity.removeFromParent(); pickupEntities[id] = nil }
    }

    /// A red disc growing while a boss attack winds up.
    func telegraph(id: String, at point: SpatialVector, radius: Double, seconds: Double) {
        telegraphs[id]?.entity.removeFromParent()
        var red = UnlitMaterial(color: .systemRed)
        red.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        let disc = ModelEntity(mesh: .generateCylinder(height: 0.04, radius: Float(radius)), materials: [red])
        disc.position = Self.position(point + SpatialVector(0, 0, 0.05)); disc.scale = [0.2, 1, 0.2]
        effects.addChild(disc); telegraphs[id] = (disc, clock, seconds)
    }

    /// Per-frame effects: telegraph growth, chest spin.
    func animate(clock: Double) {
        self.clock = clock
        for (id, entry) in telegraphs {
            let t = (clock - entry.start) / max(0.05, entry.seconds)
            if t >= 1.15 { entry.entity.removeFromParent(); telegraphs[id] = nil; continue }
            let s = Float(0.2 + 0.8 * min(1, t)); entry.entity.scale = [s, 1, s]
        }
        let spin = simd_quatf(angle: Float(clock.truncatingRemainder(dividingBy: 2 * .pi)), axis: [0, 1, 0])
        for entity in pickupEntities.values { entity.orientation = spin }
    }

    private var punchStart = -10.0, punchLunge = true
    func placePlayer(_ player: SpatialPlayer) {
        playerEntity.position = Self.position(player.position)
        // RealityKit turns counter-clockwise around +Y; map facing is the same sense.
        playerEntity.orientation = simd_quatf(angle: Float(player.facing * .pi / 180), axis: [0, 1, 0])
        // A short squash and lean so every action button visibly does something.
        let t = clock - punchStart
        if t < 0.25 {
            let k = Float(sin(t / 0.25 * .pi))
            playerEntity.scale = punchLunge ? [1 + 0.25 * k, 1 - 0.15 * k, 1] : [1 + 0.2 * k, 1 + 0.2 * k, 1 + 0.2 * k]
        } else if playerEntity.scale != [1, 1, 1] { playerEntity.scale = [1, 1, 1] }
    }
    func punch(lunge: Bool) { punchStart = clock; punchLunge = lunge }

    // MARK: Preview and selection

    func showPreview(_ blocks: [SpatialBlock], conflicts: Set<String>) {
        previewRoot.children.removeAll()
        for block in blocks.prefix(1500) {
            var tint = UnlitMaterial(color: conflicts.contains(block.id) ? .systemRed : .systemCyan)
            tint.blending = .transparent(opacity: .init(floatLiteral: 0.45))
            let box = ModelEntity(mesh: mesh("box|\(block.size)|\(block.thickness)") { .generateBox(width: Float(block.size) * 0.98, height: Float(block.thickness), depth: Float(block.size) * 0.98) }, materials: [tint])
            box.position = Self.position(SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, block.elevation + block.thickness / 2))
            previewRoot.addChild(box)
        }
    }

    /// v1.78: a light tint plus a crisp edge outline that turns with the
    /// block (the tint alone, unturned, sat crooked on rotated blocks).
    /// Edges are drawn for the first `outlinedLimit` blocks to bound cost.
    static let outlinedLimit = 60
    func showSelection(_ blocks: [SpatialBlock]) {
        selectionRoot.children.removeAll()
        var tint = UnlitMaterial(color: .systemYellow)
        tint.blending = .transparent(opacity: .init(floatLiteral: 0.18))
        let edge = UnlitMaterial(color: .systemYellow)
        for (index, block) in blocks.prefix(400).enumerated() {
            let w = Float(block.size) + 0.08, h = Float(block.thickness) + 0.08
            let holder = Entity()
            holder.position = Self.position(SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, block.elevation + block.thickness / 2))
            holder.orientation = simd_quatf(angle: Float(block.yaw * .pi / 180), axis: [0, 1, 0])
            holder.addChild(ModelEntity(mesh: mesh("sel-fill-\(w)-\(h)") { .generateBox(width: w, height: h, depth: w) }, materials: [tint]))
            if index < Self.outlinedLimit {
                let t: Float = 0.045
                let along = mesh("sel-x-\(w)") { .generateBox(width: w + t, height: t, depth: t) }
                let across = mesh("sel-z-\(w)") { .generateBox(width: t, height: t, depth: w + t) }
                let up = mesh("sel-y-\(h)") { .generateBox(width: t, height: h + t, depth: t) }
                for sy in [-h / 2, h / 2] {
                    for sz in [-w / 2, w / 2] { let e = ModelEntity(mesh: along, materials: [edge]); e.position = [0, sy, sz]; holder.addChild(e) }
                    for sx in [-w / 2, w / 2] { let e = ModelEntity(mesh: across, materials: [edge]); e.position = [sx, sy, 0]; holder.addChild(e) }
                }
                for sx in [-w / 2, w / 2] { for sz in [-w / 2, w / 2] { let e = ModelEntity(mesh: up, materials: [edge]); e.position = [sx, 0, sz]; holder.addChild(e) } }
            }
            selectionRoot.addChild(holder)
        }
    }

    var blockNodeCount: Int { blockEntities.count }

    /// The default player body hides while a media character is shown.
    var playerBodyVisible = true {
        didSet { guard playerBodyVisible != oldValue else { return }; for child in playerEntity.children.prefix(2) { child.isEnabled = playerBodyVisible } }
    }
    func creatureEntity(_ id: String) -> Entity? { creatureEntities[id] }
    func setCreatureBodyVisible(_ id: String, _ visible: Bool) { creatureEntities[id]?.children.first?.isEnabled = visible }
    var creatureNodeCount: Int { creatureEntities.count }

    // MARK: Shared resources

    private func mesh(_ key: String, _ make: () -> MeshResource) -> MeshResource {
        if let cached = meshCache[key] { return cached }
        let value = make(); meshCache[key] = value; return value
    }
    private func material(_ key: String, color: UIColor, glow: Bool = false) -> RealityKit.Material {
        if let cached = materialCache[key] { return cached }
        let value = Self.solid(color, glow: glow); materialCache[key] = value; return value
    }

    static func solid(_ color: UIColor, glow: Bool = false) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: 0.5)
        if glow { material.emissiveColor = .init(color: color); material.emissiveIntensity = 0.6 }
        return material
    }

    static let repeatSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat; descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear; descriptor.magFilter = .linear; descriptor.mipFilter = .linear
        return MaterialParameters.Texture.Sampler(descriptor)
    }()

    static let tileTexture: TextureResource? = {
        guard let image = tileImage.cgImage else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color))
    }()

    /// One glass cell: faint fill, bright edge, soft lower shade.
    static let tileImage: UIImage = {
        let side: CGFloat = 64
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let rect = CGRect(x: 2, y: 2, width: side - 4, height: side - 4)
            let shape = UIBezierPath(roundedRect: rect, cornerRadius: 9)
            UIColor(white: 1, alpha: 0.16).setFill(); shape.fill()
            context.cgContext.saveGState(); shape.addClip()
            let colors = [UIColor(white: 1, alpha: 0.45).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.midY), options: [])
            }
            context.cgContext.restoreGState()
            UIColor(white: 1, alpha: 0.75).setStroke(); shape.lineWidth = 1.5; shape.stroke()
        }
    }()

    static let skyImage: UIImage = {
        let size = CGSize(width: 8, height: 256)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.12, green: 0.16, blue: 0.32, alpha: 1).cgColor, UIColor(red: 0.42, green: 0.55, blue: 0.78, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }()
}

/// Media for block faces: one image texture, one looping video player or
/// one set of GIF frame textures per file, shared by every face showing
/// it. A face is its own quad whose texture coordinates pick the piece.
@available(iOS 18.0, *)
@MainActor final class Glass3DMedia {
    private var images: [String: TextureResource] = [:]
    private var imageSizes: [String: CGSize] = [:]
    private var players: [String: (AVQueuePlayer, AVPlayerLooper)] = [:]
    private var gifs: [String: (frames: [TextureResource], delays: [Double], total: Double, size: CGSize)] = [:]
    private var gifFaces: [String: [ModelEntity]] = [:]
    private var shownGIFFrame: [String: Int] = [:]
    var resolve: ((String) -> (URL, RPGMediaKind)?)?
    var binding: ((String) -> MediaBinding?)?

    var decoderCount: Int { players.values.filter { $0.0.rate > 0 }.count }

    /// A quad just outside the block face, showing the binding's piece.
    func face(for reference: SpatialMedia, block: SpatialBlock) -> ModelEntity? {
        guard let binding = binding?(reference.bindingID) else { return nil }
        var material: RealityKit.Material?
        var pixels = CGSize(width: 1, height: 1)
        var gifID: String?
        switch binding.kind {
        case .image, .video, .gif:
            guard let (url, kind) = resolve?(binding.mediaID) else { return nil }
            switch kind {
            case .video:
                let player = videoPlayer(binding.mediaID, url: url)
                material = VideoMaterial(avPlayer: player)
                pixels = player.currentItem?.presentationSize ?? CGSize(width: 16, height: 9)
            case .gif:
                guard let gif = gif(binding.mediaID, url: url), let first = gif.frames.first else { return nil }
                var unlit = UnlitMaterial(); unlit.color = .init(tint: .white, texture: .init(first)); material = unlit
                pixels = gif.size; gifID = binding.mediaID
            default:
                guard let texture = image(binding.mediaID, url: url) else { return nil }
                var unlit = UnlitMaterial(); unlit.color = .init(tint: .white, texture: .init(texture)); material = unlit
                pixels = imageSizes[binding.mediaID] ?? pixels
            }
        case .icon, .number, .text:
            let image = RPGCellRenderer.image(kind: binding.kind, style: binding.style ?? RPGCellStyle())
            if let cg = image.cgImage, let texture = try? TextureResource(image: cg, options: .init(semantic: .color)) {
                var unlit = UnlitMaterial(); unlit.color = .init(tint: .white, texture: .init(texture)); unlit.blending = .transparent(opacity: .init(floatLiteral: 1)); material = unlit
            }
        }
        guard let material else { return nil }
        let rect = Self.textureRect(binding: binding, region: reference.region, pixels: pixels)
        guard let mesh = Self.quad(face: reference.face, block: block, uv: rect) else { return nil }
        let entity = ModelEntity(mesh: mesh, materials: [material])
        if let gifID { gifFaces[gifID, default: []].append(entity) }
        return entity
    }

    /// A material for a whole binding (characters): image, first GIF frame
    /// or the shared video player; icons, numbers and text are drawn.
    func material(forBinding id: String, opacity: Double) -> RealityKit.Material? {
        guard let binding = binding?(id) else { return nil }
        if binding.kind == .icon || binding.kind == .number || binding.kind == .text {
            let image = RPGCellRenderer.image(kind: binding.kind, style: binding.style ?? RPGCellStyle())
            guard let cg = image.cgImage, let texture = try? TextureResource(image: cg, options: .init(semantic: .color)) else { return nil }
            var unlit = UnlitMaterial(); unlit.color = .init(tint: .white, texture: .init(texture)); unlit.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return unlit
        }
        guard let (url, kind) = resolve?(binding.mediaID) else { return nil }
        switch kind {
        case .video: return VideoMaterial(avPlayer: videoPlayer(binding.mediaID, url: url))
        case .gif:
            guard let first = gif(binding.mediaID, url: url)?.frames.first else { return nil }
            var unlit = UnlitMaterial(); unlit.color = .init(tint: .white, texture: .init(first)); unlit.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return unlit
        default:
            guard let texture = image(binding.mediaID, url: url) else { return nil }
            var unlit = UnlitMaterial(); unlit.color = .init(tint: .white, texture: .init(texture)); unlit.blending = .transparent(opacity: .init(floatLiteral: Float(opacity)))
            return unlit
        }
    }

    /// The piece's texture rectangle (bottom-left origin, v up).
    static func textureRect(binding: MediaBinding, region: RPGMediaRegion?, pixels: CGSize) -> CGRect {
        let crop = CGRect(x: binding.cropX, y: binding.cropY, width: binding.cropWidth, height: binding.cropHeight)
        guard let region else { return crop }
        let group = RPGMediaRegion.groupRect(crop: crop, pixels: pixels, rows: region.rows, columns: region.columns, stretch: region.stretch == true)
        return region.subRect(of: group)
    }

    /// A quad on one face of a block (block-local coordinates, Y up).
    static func quad(face: SpatialFace, block: SpatialBlock, uv rect: CGRect) -> MeshResource? {
        let h = Float(block.size) * 0.49, t = Float(block.thickness) / 2, e: Float = 0.006
        let corners: [SIMD3<Float>]
        switch face {
        case .top: corners = [[-h, t + e, h], [h, t + e, h], [h, t + e, -h], [-h, t + e, -h]]
        case .front: corners = [[-h, -t, h + e], [h, -t, h + e], [h, t, h + e], [-h, t, h + e]]
        case .side: corners = [[h + e, -t, h], [h + e, -t, -h], [h + e, t, -h], [h + e, t, h]]
        }
        let u0 = Float(rect.minX), u1 = Float(rect.maxX), v0 = Float(rect.minY), v1 = Float(rect.maxY)
        var descriptor = MeshDescriptor(name: "mediaFace")
        descriptor.positions = MeshBuffers.Positions(corners)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([[u0, v0], [u1, v0], [u1, v1], [u0, v1]])
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3])
        return try? MeshResource.generate(from: [descriptor])
    }

    private func image(_ id: String, url: URL) -> TextureResource? {
        if let cached = images[id] { return cached }
        guard let image = UIImage(contentsOfFile: url.path), let cg = image.cgImage, let texture = try? TextureResource(image: cg, options: .init(semantic: .color)) else { return nil }
        images[id] = texture; imageSizes[id] = image.size
        return texture
    }

    private func videoPlayer(_ id: String, url: URL) -> AVQueuePlayer {
        if let existing = players[id] { return existing.0 }
        let player = AVQueuePlayer()
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = true
        players[id] = (player, looper)
        return player
    }

    private func gif(_ id: String, url: URL) -> (frames: [TextureResource], delays: [Double], total: Double, size: CGSize)? {
        if let cached = gifs[id] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), 90)
        var frames: [TextureResource] = [], delays: [Double] = [], size = CGSize(width: 1, height: 1)
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 384, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options), let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { continue }
            if frames.isEmpty { size = CGSize(width: image.width, height: image.height) }
            frames.append(texture)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append(max(0.02, (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1))
        }
        guard !frames.isEmpty else { return nil }
        let value = (frames, delays, delays.reduce(0, +), size)
        gifs[id] = value; return value
    }

    /// Plays on-screen videos from the shared world clock (so a video that
    /// comes back into view continues in time) and steps GIF pieces together.
    func update(visibleMedia: Set<String>, clock: Double, paused: Set<String>) {
        for (id, entry) in players {
            let player = entry.0
            if visibleMedia.contains(id) && !paused.contains(id) {
                if player.rate == 0 {
                    if let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 {
                        player.seek(to: CMTime(seconds: clock.truncatingRemainder(dividingBy: duration), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
                    }
                    player.play()
                }
            } else if player.rate != 0 { player.pause() }
        }
        for (id, faces) in gifFaces where visibleMedia.contains(id) {
            guard let gif = gifs[id], gif.total > 0 else { continue }
            var t = clock.truncatingRemainder(dividingBy: gif.total), index = 0
            while index < gif.delays.count - 1 && t >= gif.delays[index] { t -= gif.delays[index]; index += 1 }
            guard shownGIFFrame[id] != index else { continue }
            shownGIFFrame[id] = index
            var unlit = UnlitMaterial(); unlit.color = .init(tint: .white, texture: .init(gif.frames[index]))
            for face in faces where face.parent != nil { face.model?.materials = [unlit] }
            gifFaces[id] = faces.filter { $0.parent != nil }
        }
    }

    func stop() {
        players.values.forEach { $0.0.pause() }
        players.removeAll(); gifFaces.removeAll()
    }

    /// Pauses every video (the world is hidden); they resume from the clock.
    func pauseAll() { players.values.forEach { $0.0.pause() } }
}
