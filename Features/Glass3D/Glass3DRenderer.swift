import SceneKit
import SpriteKit
import UIKit
import AVFoundation
import ImageIO

/// Draws the 2.5D glass world with SceneKit: real depth, tilt, turn and
/// ray picking. World cells (x, y, height z) map to scene (x, z, −y).
/// Ground glass is one plane per visible 32×32 chunk; blocks share
/// geometry and materials; plants are flattened per chunk; media uses one
/// player or image per file with each piece's texture rectangle.
@MainActor final class Glass3DRenderer {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let ground = SCNNode(), blocksNode = SCNNode(), plantsNode = SCNNode(), creaturesNode = SCNNode()
    private let pickupsNode = SCNNode(), effects = SCNNode(), previewNode = SCNNode(), selectionNode = SCNNode()
    let playerNode = SCNNode()
    private var chunkNodes: [Int: SCNNode] = [:]
    private var blockNodes: [String: SCNNode] = [:]
    private var blockVersions: [String: SpatialBlock] = [:]
    private var groupNodes: [String: SCNNode] = [:]
    private var plantChunks: [Int: SCNNode] = [:]
    private var plantSignature: [Int: Int] = [:]
    private var creatureNodes: [String: SCNNode] = [:]
    private var pickupNodes: [String: SCNNode] = [:]
    private var telegraphs: [String: (SCNNode, Double)] = [:]
    private var geometryCache: [String: SCNGeometry] = [:]
    private var materialCache: [String: SCNMaterial] = [:]
    private(set) var quality = RPGGlassQuality.standard
    let media = Glass3DMedia()

    static func scenePoint(_ v: SpatialVector) -> SCNVector3 { SCNVector3(Float(v.x), Float(v.z), Float(-v.y)) }

    init() {
        for node in [ground, blocksNode, plantsNode, creaturesNode, pickupsNode, effects, previewNode, selectionNode, playerNode] { scene.rootNode.addChildNode(node) }
        scene.background.contents = Self.skyImage
        let camera = SCNCamera(); camera.fieldOfView = CGFloat(SpatialCameraRules.fieldOfView); camera.zNear = 0.1; camera.zFar = 600
        camera.projectionDirection = .vertical
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 650
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0); sun.name = "sun"
        scene.rootNode.addChildNode(ambient); scene.rootNode.addChildNode(sun)
        let capsule = SCNCapsule(capRadius: 0.3, height: 1.4)
        capsule.firstMaterial = Self.solidMaterial(UIColor.systemTeal, glow: true)
        let body = SCNNode(geometry: capsule); body.position = SCNVector3(0, 0.7, 0); body.name = "player"
        let nose = SCNNode(geometry: SCNSphere(radius: 0.12)); nose.geometry?.firstMaterial = Self.solidMaterial(.white, glow: true); nose.position = SCNVector3(0.32, 1.1, 0)
        playerNode.addChildNode(body); playerNode.addChildNode(nose)
        previewNode.opacity = 0.55
    }

    // MARK: Quality

    func setQuality(_ value: RPGGlassQuality) {
        guard value != quality else { return }
        quality = value
        materialCache.removeAll(); geometryCache.removeAll()
        blockNodes.values.forEach { $0.removeFromParentNode() }; blockNodes.removeAll(); blockVersions.removeAll()
        chunkNodes.values.forEach { $0.removeFromParentNode() }; chunkNodes.removeAll()
        scene.rootNode.childNode(withName: "sun", recursively: false)?.light?.castsShadow = value == .high
    }

    // MARK: Camera

    func place(camera: SpatialCameraState) {
        let eye = SpatialCameraRules.position(camera)
        cameraNode.position = Self.scenePoint(eye)
        let yaw = camera.yaw * .pi / 180
        // "Up" on screen is map-forward for this turn, which also works when
        // looking straight down.
        let up = SCNVector3(Float(-sin(yaw)), 0, Float(-cos(yaw)))
        cameraNode.look(at: Self.scenePoint(camera.target), up: camera.tilt < 1 ? up : SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
    }

    // MARK: Ground

    /// Glass ground for the chunks around the camera; full chunks, so the
    /// view never shows missing ground.
    func showGround(chunks: Set<Int>) {
        for (key, node) in chunkNodes where !chunks.contains(key) { node.removeFromParentNode(); chunkNodes[key] = nil }
        for key in chunks where chunkNodes[key] == nil {
            let cx = key % 8, cy = key / 8
            let plane = SCNPlane(width: 32, height: 32)
            plane.firstMaterial = groundMaterial()
            let node = SCNNode(geometry: plane)
            node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            node.position = SCNVector3(Float(cx * 32 + 16), 0, Float(-(cy * 32 + 16)))
            node.name = "ground"; node.renderingOrder = -10
            ground.addChildNode(node); chunkNodes[key] = node
        }
    }

    private func groundMaterial() -> SCNMaterial {
        if let cached = materialCache["ground"] { return cached }
        let material = SCNMaterial()
        material.diffuse.contents = Self.tileImage
        material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(32, 32, 1)
        material.lightingModel = quality == .performance ? .constant : .blinn
        material.transparency = 0.9
        material.isDoubleSided = true
        material.writesToDepthBuffer = true
        materialCache["ground"] = material
        return material
    }

    // MARK: Blocks

    /// Shows `blocks` (only those in loaded chunks are passed in). Moving
    /// groups get a parent node turned and moved every frame.
    func showBlocks(_ blocks: [SpatialBlock], pivots: [String: SpatialVector]) {
        let wanted = Set(blocks.map(\.id))
        for (id, node) in blockNodes where !wanted.contains(id) { node.removeFromParentNode(); blockNodes[id] = nil; blockVersions[id] = nil }
        for block in blocks {
            if blockVersions[block.id] == block, let node = blockNodes[block.id], node.parent != nil {
                let moving = block.groupID.flatMap { pivots[$0] } != nil
                if moving == (node.parent !== blocksNode) { continue }
            }
            blockNodes[block.id]?.removeFromParentNode()
            let node = SCNNode(geometry: geometry(for: block))
            node.name = "block:" + block.id
            node.eulerAngles = SCNVector3(0, Float(block.yaw * .pi / 180), 0)
            let center = SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, block.elevation + block.thickness / 2)
            if let group = block.groupID, let pivot = pivots[group] {
                let parent = groupNode(group)
                node.position = Self.scenePoint(SpatialVector(center.x - pivot.x, center.y - pivot.y, center.z))
                parent.addChildNode(node)
            } else {
                node.position = Self.scenePoint(center)
                blocksNode.addChildNode(node)
            }
            blockNodes[block.id] = node; blockVersions[block.id] = block
        }
        for (group, node) in groupNodes where node.childNodes.isEmpty { node.removeFromParentNode(); groupNodes[group] = nil }
    }

    private func groupNode(_ id: String) -> SCNNode {
        if let node = groupNodes[id] { return node }
        let node = SCNNode(); node.name = "group:" + id
        blocksNode.addChildNode(node); groupNodes[id] = node
        return node
    }

    /// Moves and turns the moving groups for this frame.
    func place(frames: [String: GroupFrame]) {
        for (id, frame) in frames {
            guard let node = groupNodes[id] else { continue }
            node.position = Self.scenePoint(SpatialVector(frame.pivot.x + frame.offset.x, frame.pivot.y + frame.offset.y, frame.offset.z))
            node.eulerAngles = SCNVector3(0, Float(frame.yaw * .pi / 180), 0)
        }
    }

    private func geometry(for block: SpatialBlock) -> SCNGeometry {
        let key = "\(block.thickness)|\(block.size)|\(block.glass.tintHex ?? "-")|\(block.glass.density)|\(block.glass.frosted)|\(block.glass.glow)|\(block.collision.rawValue)"
        let base: SCNGeometry
        if let cached = geometryCache[key] { base = cached } else {
            let box = SCNBox(width: CGFloat(block.size) * 0.98, height: CGFloat(block.thickness), length: CGFloat(block.size) * 0.98, chamferRadius: CGFloat(min(0.06, block.thickness * 0.2)))
            box.materials = [glassMaterial(block.glass, collision: block.collision)]
            geometryCache[key] = box; base = box
        }
        guard let mediaRef = block.media, let mediaMaterial = media.material(for: mediaRef, quality: quality) else { return base }
        // Media blocks get their own copy with the media on one face.
        let copy = base.copy() as! SCNGeometry
        let glass = base.firstMaterial!
        var faces = [glass, glass, glass, glass, glass, glass]
        switch mediaRef.face { case .top: faces[4] = mediaMaterial; case .front: faces[0] = mediaMaterial; case .side: faces[1] = mediaMaterial }
        copy.materials = faces
        return copy
    }

    func glassMaterial(_ glass: SpatialGlass, collision: SpatialCollision) -> SCNMaterial {
        let key = "glass|\(glass.tintHex ?? "-")|\(glass.density)|\(glass.frosted)|\(glass.glow)|\(collision == .trigger)"
        if let cached = materialCache[key] { return cached }
        let tint = glass.tintHex.map { UIColor(rpgHex: $0) } ?? UIColor(white: 0.92, alpha: 1)
        let material = SCNMaterial()
        material.diffuse.contents = Self.tileImage
        material.multiply.contents = tint
        // Every quality keeps the glass translucent; only lighting changes.
        material.transparency = CGFloat(collision == .trigger ? 0.18 : 0.35 + glass.density * 0.5)
        switch quality {
        case .high:
            material.lightingModel = .physicallyBased
            material.metalness.contents = 0.15; material.roughness.contents = glass.frosted ? 0.65 : 0.08
            material.transparencyMode = .dualLayer
        case .standard:
            material.lightingModel = .blinn
            material.specular.contents = UIColor(white: 1, alpha: 0.9); material.shininess = 60
            material.fresnelExponent = 1.4
        case .performance:
            material.lightingModel = .constant
        }
        if glass.glow { material.emission.contents = tint.withAlphaComponent(0.6) }
        material.isDoubleSided = false
        materialCache[key] = material
        return material
    }

    // MARK: Plants

    /// Plants grouped and flattened per chunk: few draw calls for many plants.
    func showPlants(_ plants: [PlantEntity], chunks: Set<Int>) {
        var byChunk: [Int: [PlantEntity]] = [:]
        for plant in plants { let key = (plant.y / 32) * 8 + plant.x / 32; if chunks.contains(key) { byChunk[key, default: []].append(plant) } }
        for (key, node) in plantChunks where byChunk[key] == nil { node.removeFromParentNode(); plantChunks[key] = nil; plantSignature[key] = nil }
        for (key, list) in byChunk {
            var hasher = Hasher(); for plant in list { hasher.combine(plant.id); hasher.combine(plant.x); hasher.combine(plant.y); hasher.combine(plant.z); hasher.combine(plant.kind) }
            let signature = hasher.finalize()
            if plantSignature[key] == signature { continue }
            plantChunks[key]?.removeFromParentNode()
            let holder = SCNNode()
            for plant in list { holder.addChildNode(plantNode(plant)) }
            let flat = holder.flattenedClone(); flat.name = "plants:\(key)"
            plantsNode.addChildNode(flat); plantChunks[key] = flat; plantSignature[key] = signature
        }
    }

    private func plantNode(_ plant: PlantEntity) -> SCNNode {
        let node = SCNNode()
        node.position = Self.scenePoint(SpatialVector(Double(plant.x) + 0.5, Double(plant.y) + 0.5, plant.z))
        node.scale = SCNVector3(Float(plant.scale), Float(plant.scale), Float(plant.scale))
        let green = UIColor(hue: CGFloat(0.25 + plant.hue * 0.12), saturation: 0.6, brightness: 0.75, alpha: 1)
        switch plant.kind {
        case .grass:
            for i in 0..<3 { let blade = SCNNode(geometry: shared("grass", SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.35), color: green))
                blade.position = SCNVector3(Float(i - 1) * 0.1, 0.17, Float(i % 2) * 0.08); node.addChildNode(blade) }
        case .flower:
            let stem = SCNNode(geometry: shared("stem", SCNCylinder(radius: 0.02, height: 0.4), color: green)); stem.position = SCNVector3(0, 0.2, 0)
            let petal = UIColor(hue: CGFloat(plant.hue), saturation: 0.7, brightness: 1, alpha: 1)
            let head = SCNNode(geometry: shared("flower\(Int(plant.hue * 8))", SCNSphere(radius: 0.1), color: petal)); head.position = SCNVector3(0, 0.42, 0)
            node.addChildNode(stem); node.addChildNode(head)
        case .bush:
            let bush = SCNNode(geometry: shared("bush", SCNSphere(radius: 0.42), color: green)); bush.position = SCNVector3(0, 0.38, 0); node.addChildNode(bush)
        case .tree:
            let trunk = SCNNode(geometry: shared("trunk", SCNCylinder(radius: 0.1, height: 1.0), color: UIColor.brown)); trunk.position = SCNVector3(0, 0.5, 0)
            let crown = SCNNode(geometry: shared("crown", SCNCone(topRadius: 0, bottomRadius: 0.55, height: 1.5), color: green.withAlphaComponent(0.85))); crown.position = SCNVector3(0, 1.6, 0)
            node.addChildNode(trunk); node.addChildNode(crown)
        case .glow:
            let orb = SCNNode(geometry: shared("glow", SCNSphere(radius: 0.16), color: UIColor.cyan, glow: true)); orb.position = SCNVector3(0, 0.35, 0)
            let stem = SCNNode(geometry: shared("glowstem", SCNCylinder(radius: 0.02, height: 0.3), color: UIColor.systemTeal)); stem.position = SCNVector3(0, 0.15, 0)
            node.addChildNode(stem); node.addChildNode(orb)
        }
        node.name = "plant:" + plant.id
        return node
    }

    private func shared(_ key: String, _ make: @autoclosure () -> SCNGeometry, color: UIColor, glow: Bool = false) -> SCNGeometry {
        let cacheKey = "plant|" + key
        if let cached = geometryCache[cacheKey] { return cached }
        let geometry = make(); geometry.firstMaterial = Self.solidMaterial(color, glow: glow)
        geometryCache[cacheKey] = geometry
        return geometry
    }

    // MARK: Creatures, chests, effects

    func showCreatures(_ creatures: [CreatureEntity], near center: SpatialVector, radius: Double) {
        var seen = Set<String>()
        for creature in creatures where (creature.position - center).flatLength <= radius {
            seen.insert(creature.id)
            let node = creatureNodes[creature.id] ?? makeCreature(creature)
            node.position = Self.scenePoint(creature.position)
            node.opacity = creature.alive ? (creature.state == .hurt ? 0.6 : 1) : 0.25
            node.isHidden = !creature.alive && creature.kind != .boss && creature.kind != .miniBoss
        }
        for (id, node) in creatureNodes where !seen.contains(id) { node.removeFromParentNode(); creatureNodes[id] = nil }
    }

    private func makeCreature(_ creature: CreatureEntity) -> SCNNode {
        let node = SCNNode(); node.name = "creature:" + creature.id
        let body: SCNNode
        switch creature.kind {
        case .neutral: body = SCNNode(geometry: shared("c-neutral", SCNSphere(radius: 0.3), color: UIColor.systemGreen)); body.position = SCNVector3(0, 0.3, 0)
        case .enemy: body = SCNNode(geometry: shared("c-enemy", SCNCone(topRadius: 0.05, bottomRadius: 0.38, height: 1.0), color: UIColor.systemRed)); body.position = SCNVector3(0, 0.5, 0)
        case .guardian: body = SCNNode(geometry: shared("c-guard", SCNBox(width: 0.7, height: 1.2, length: 0.7, chamferRadius: 0.1), color: UIColor.systemPurple)); body.position = SCNVector3(0, 0.6, 0)
        case .miniBoss: body = SCNNode(geometry: shared("c-mini", SCNSphere(radius: 0.7), color: UIColor.systemOrange, glow: true)); body.position = SCNVector3(0, 0.7, 0)
        case .boss: body = SCNNode(geometry: shared("c-boss", SCNPyramid(width: 2.2, height: 2.8, length: 2.2), color: UIColor(red: 0.6, green: 0.05, blue: 0.2, alpha: 1), glow: true))
        }
        body.name = node.name
        node.addChildNode(body)
        creaturesNode.addChildNode(node); creatureNodes[creature.id] = node
        return node
    }

    func showPickups(_ pickups: [PickupEntity], near center: SpatialVector, radius: Double) {
        var seen = Set<String>()
        for pickup in pickups where !pickup.collected && (pickup.position - center).flatLength <= radius {
            seen.insert(pickup.id)
            if pickupNodes[pickup.id] == nil {
                let chest = SCNNode(geometry: shared("chest", SCNBox(width: 0.5, height: 0.35, length: 0.35, chamferRadius: 0.05), color: UIColor.systemYellow, glow: true))
                chest.position = Self.scenePoint(pickup.position + SpatialVector(0, 0, 0.2)); chest.name = "chest:" + pickup.id
                chest.runAction(.repeatForever(.rotateBy(x: 0, y: .pi, z: 0, duration: 2)))
                pickupsNode.addChildNode(chest); pickupNodes[pickup.id] = chest
            }
        }
        for (id, node) in pickupNodes where !seen.contains(id) { node.removeFromParentNode(); pickupNodes[id] = nil }
    }

    /// A red ring that grows while a boss attack winds up.
    func telegraph(id: String, at point: SpatialVector, radius: Double, seconds: Double) {
        telegraphs[id]?.0.removeFromParentNode()
        let ring = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: 0.04))
        let material = SCNMaterial(); material.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.35); material.lightingModel = .constant; material.writesToDepthBuffer = false
        ring.geometry?.firstMaterial = material
        ring.position = Self.scenePoint(point + SpatialVector(0, 0, 0.05)); ring.scale = SCNVector3(0.2, 1, 0.2)
        ring.runAction(.sequence([.scale(to: 1, duration: seconds), .fadeOut(duration: 0.15), .removeFromParentNode()]))
        effects.addChildNode(ring); telegraphs[id] = (ring, seconds)
    }

    func placePlayer(_ player: SpatialPlayer) {
        playerNode.position = Self.scenePoint(player.position)
        playerNode.eulerAngles = SCNVector3(0, Float(player.facing * .pi / 180), 0)
    }

    // MARK: Preview and selection

    func showPreview(_ blocks: [SpatialBlock], conflicts: Set<String>) {
        previewNode.childNodes.forEach { $0.removeFromParentNode() }
        for block in blocks.prefix(1500) {
            let box = SCNBox(width: CGFloat(block.size), height: CGFloat(block.thickness), length: CGFloat(block.size), chamferRadius: 0.04)
            let material = SCNMaterial(); material.diffuse.contents = conflicts.contains(block.id) ? UIColor.systemRed : UIColor.systemCyan
            material.transparency = 0.5; material.lightingModel = .constant
            box.firstMaterial = material
            let node = SCNNode(geometry: box)
            node.position = Self.scenePoint(SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, block.elevation + block.thickness / 2))
            previewNode.addChildNode(node)
        }
    }

    func showSelection(_ boxes: [SpatialBlock]) {
        selectionNode.childNodes.forEach { $0.removeFromParentNode() }
        for block in boxes.prefix(400) {
            let box = SCNBox(width: CGFloat(block.size) + 0.06, height: CGFloat(block.thickness) + 0.06, length: CGFloat(block.size) + 0.06, chamferRadius: 0.05)
            let material = SCNMaterial(); material.diffuse.contents = UIColor.systemYellow; material.fillMode = .lines; material.lightingModel = .constant
            box.firstMaterial = material
            let node = SCNNode(geometry: box)
            node.position = Self.scenePoint(SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, block.elevation + block.thickness / 2))
            selectionNode.addChildNode(node)
        }
    }

    // MARK: Stats

    var blockNodeCount: Int { blockNodes.count }
    var creatureNodeCount: Int { creatureNodes.count }

    // MARK: Shared images

    static func solidMaterial(_ color: UIColor, glow: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .blinn
        if glow { material.emission.contents = color.withAlphaComponent(0.45) }
        return material
    }

    /// One glass cell: faint fill, bright top edge, soft lower shade.
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

/// Media for blocks: one image, one looping player or one GIF timeline per
/// file, shared by every block face that shows it. Pieces of a media grid
/// show their part through the texture transform.
@MainActor final class Glass3DMedia {
    private var images: [String: UIImage] = [:]
    private var players: [String: (AVQueuePlayer, AVPlayerLooper)] = [:]
    private var gifs: [String: (frames: [CGImage], delays: [Double], total: Double)] = [:]
    private var gifMaterials: [String: [SCNMaterial]] = [:]
    private(set) var visibleVideos: Set<String> = []
    /// mediaID → file URL and kind, from the media library.
    var resolve: ((String) -> (URL, RPGMediaKind)?)?
    /// bindingID → binding, from the world.
    var binding: ((String) -> MediaBinding?)?

    var decoderCount: Int { players.values.filter { $0.0.rate > 0 }.count }

    func material(for reference: SpatialMedia, quality: RPGGlassQuality) -> SCNMaterial? {
        guard let binding = binding?(reference.bindingID) else { return nil }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        switch binding.kind {
        case .image, .video, .gif:
            guard let (url, kind) = resolve?(binding.mediaID) else { return placeholder() }
            var size = CGSize(width: 1, height: 1)
            switch kind {
            case .video:
                let player = videoPlayer(binding.mediaID, url: url)
                material.diffuse.contents = player
                size = player.currentItem?.presentationSize ?? CGSize(width: 16, height: 9)
            case .gif:
                guard let gif = gif(binding.mediaID, url: url), let first = gif.frames.first else { return placeholder() }
                material.diffuse.contents = first
                size = CGSize(width: first.width, height: first.height)
                gifMaterials[binding.mediaID, default: []].append(material)
            default:
                guard let image = image(binding.mediaID, url: url) else { return placeholder() }
                material.diffuse.contents = image; size = image.size
            }
            material.diffuse.contentsTransform = Self.transform(binding: binding, region: reference.region, pixels: size)
            material.diffuse.wrapS = .clamp; material.diffuse.wrapT = .clamp
        case .icon, .number, .text:
            material.diffuse.contents = RPGCellRenderer.image(kind: binding.kind, style: binding.style ?? RPGCellStyle())
        }
        return material
    }

    /// Texture rectangle (top-left origin for SceneKit) for a binding piece.
    static func transform(binding: MediaBinding, region: RPGMediaRegion?, pixels: CGSize) -> SCNMatrix4 {
        let crop = CGRect(x: binding.cropX, y: binding.cropY, width: binding.cropWidth, height: binding.cropHeight)
        var rect = crop
        if let region {
            let group = RPGMediaRegion.groupRect(crop: crop, pixels: pixels, rows: region.rows, columns: region.columns, stretch: region.stretch == true)
            rect = region.subRect(of: group)
        }
        // SpriteKit-style rects are bottom-left; SceneKit images are top-left.
        let top = 1 - rect.maxY
        return SCNMatrix4Mult(SCNMatrix4MakeScale(Float(rect.width), Float(rect.height), 1), SCNMatrix4MakeTranslation(Float(rect.minX), Float(top), 0))
    }

    private func placeholder() -> SCNMaterial {
        let material = SCNMaterial(); material.diffuse.contents = RPGCellRenderer.placeholder.cgImage(); material.lightingModel = .constant
        return material
    }

    private func image(_ id: String, url: URL) -> UIImage? {
        if let cached = images[id] { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images[id] = image; return image
    }

    private func videoPlayer(_ id: String, url: URL) -> AVQueuePlayer {
        if let existing = players[id] { return existing.0 }
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        let looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        players[id] = (player, looper)
        return player
    }

    private func gif(_ id: String, url: URL) -> (frames: [CGImage], delays: [Double], total: Double)? {
        if let cached = gifs[id] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), 120)
        var frames: [CGImage] = [], delays: [Double] = []
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            frames.append(image)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            delays.append(max(0.02, delay))
        }
        guard !frames.isEmpty else { return nil }
        let value = (frames, delays, delays.reduce(0, +))
        gifs[id] = value; return value
    }

    /// Plays videos that are on screen, from the shared world clock so a
    /// video that comes back into view continues where it should be; GIFs
    /// step on the same clock, so every piece shows the same frame.
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
        visibleVideos = Set(players.keys.filter { visibleMedia.contains($0) })
        for (id, materials) in gifMaterials where visibleMedia.contains(id) {
            guard let gif = gifs[id], gif.total > 0 else { continue }
            var t = clock.truncatingRemainder(dividingBy: gif.total), index = 0
            while index < gif.delays.count - 1 && t >= gif.delays[index] { t -= gif.delays[index]; index += 1 }
            for material in materials { material.diffuse.contents = gif.frames[index] }
        }
    }

    func stop() {
        players.values.forEach { $0.0.pause() }
        players.removeAll(); gifMaterials.removeAll()
    }
}
