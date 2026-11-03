import SpriteKit
import UIKit

@MainActor final class RPGTopDownScene: SKScene {
    static let cell: CGFloat = 24
    var onSelectCell: ((SurfacePoint) -> Void)?
    var onStroke: (([SurfacePoint]) -> Void)?
    var tool = RPGTool.select
    private var strokePoints: [SurfacePoint] = []
    private let enemies = SKNode()
    private var enemyNodes: [String: SKShapeNode] = [:]
    private let ground = SKNode()
    private let objects = SKNode()
    private let avatar = SKShapeNode(circleOfRadius: 8)
    private let selection = SKShapeNode(rectOf: CGSize(width: 23, height: 23), cornerRadius: 3)
    private let worldCamera = SKCameraNode()
    var onFrame: ((TimeInterval) -> Void)?
    private(set) var mediaTargets: [RPGMediaNode] = []
    private(set) var sharedIDs: [String] = []
    private var maps: [ChunkCoordinate: SKTileMapNode] = [:]
    private var groups: [RPGTerrain: SKTileGroup] = [:]
    override init() {
        super.init(size: CGSize(width: 390, height: 500))
        scaleMode = .resizeFill; backgroundColor = .clear; physicsWorld.gravity = .zero
        objects.zPosition = 2
        enemies.zPosition = 5; addChild(enemies); addChild(ground); addChild(objects); addChild(avatar); addChild(selection); addChild(worldCamera)
        camera = worldCamera
        avatar.fillColor = .systemTeal; avatar.strokeColor = .white; avatar.zPosition = 10
        selection.strokeColor = .systemYellow; selection.fillColor = .clear; selection.zPosition = 12; selection.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show(chunks: [RPGChunk], world: WorldState) {
        prepareTiles()
        let wanted = Set(chunks.map(\.coordinate))
        for key in Array(maps.keys) where !wanted.contains(key) { maps.removeValue(forKey: key)?.removeFromParent() }
        let set = SKTileSet(tileGroups: RPGTerrain.allCases.compactMap { groups[$0] })
        for chunk in chunks where maps[chunk.coordinate] == nil {
            let map = SKTileMapNode(tileSet: set, columns: 32, rows: 32, tileSize: CGSize(width: 24, height: 24))
            map.anchorPoint = .zero
            map.position = CGPoint(x: CGFloat(chunk.coordinate.x * 32) * Self.cell, y: CGFloat(chunk.coordinate.z * 32) * Self.cell)
            for z in 0..<32 { for x in 0..<32 { map.setTileGroup(groups[chunk.terrain[z * 32 + x]], forColumn: x, row: z) } }
            ground.addChild(map); maps[chunk.coordinate] = map
        }
        objects.removeAllChildren(); sharedIDs = []
        avatar.children.filter { $0.name?.hasPrefix("media:") == true }.forEach { $0.removeFromParent() }
        mediaTargets = RPGMediaSprites.backgrounds(world: world, camera: worldCamera, size: size, topDown: true)
        if let target = RPGMediaSprites.attach(ownerID: "player", bindingID: world.player.mediaBindingID, role: .player, parent: avatar, world: world, size: CGSize(width: 24, height: 32)) { mediaTargets.append(target) }
        for entity in chunks.flatMap({ RPGWorldEditing.entities(in: $0, world: world) }) {
            guard let point = entity.surface, wanted.contains(point.chunk ?? .init(x: -1, z: -1)) else { continue }
            let node = SKShapeNode(rectOf: CGSize(width: 16, height: 18), cornerRadius: 4)
            node.fillColor = entity.definitionID == "wood" ? .systemBrown : .systemGray
            node.strokeColor = .white.withAlphaComponent(0.5); node.position = Self.position(point); node.name = entity.id
            objects.addChild(node)
            if let target = RPGMediaSprites.attach(ownerID: entity.id, bindingID: entity.mediaBindingID, role: .interactive, parent: node, world: world, size: CGSize(width: 24, height: 24)) { mediaTargets.append(target) }
            if entity.scope == .shared { sharedIDs.append(entity.id) }
        }
        let generator = RPGWorldGenerator(seed: world.seed)
        for anchor in generator.anchors where wanted.contains(anchor.point.chunk!) {
            let node = SKLabelNode(text: anchor.id.title)
            node.fontName = "HelveticaNeue-Bold"; node.fontSize = 11; node.fontColor = .white
            node.position = Self.position(anchor.point); node.position.y += 16; objects.addChild(node)
        }
        movePlayer(world.player.surface)
    }
    func movePlayer(_ point: SurfacePoint) { avatar.position = Self.position(point); worldCamera.position = avatar.position }
    /// The selected cell in SpriteView (UIKit) coordinates, or nil when
    /// nothing is selected. Used to place the SwiftUI selection glass.
    func selectionRectInView() -> CGRect? {
        guard !selection.isHidden, view != nil else { return nil }
        let half: CGFloat = 12
        let a = convertPoint(toView: CGPoint(x: selection.position.x - half, y: selection.position.y - half))
        let b = convertPoint(toView: CGPoint(x: selection.position.x + half, y: selection.position.y + half))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    /// The yellow outline is hidden when native glass marks the selection.
    var selectionOutlineVisible = true { didSet { selection.alpha = selectionOutlineVisible ? 1 : 0 } }
    func select(_ point: SurfacePoint?) { selection.isHidden = point == nil; if let point { selection.position = Self.position(point) } }
    func showCombat(_ world: WorldState) {
        let visible = world.combat.enemies.filter { enemy in
            guard enemy.health > 0, let p = enemy.surface, enemy.scope != .sideOnly else { return false }
            return abs(p.x-world.player.surface.x) < 24 && abs(p.z-world.player.surface.z) < 24
        }
        let ids = Set(visible.map(\.id))
        for id in Array(enemyNodes.keys) where !ids.contains(id) { enemyNodes.removeValue(forKey:id)?.removeFromParent() }
        for enemy in visible {
            let node: SKShapeNode
            if let existing = enemyNodes[enemy.id] { node = existing }
            else {
                node = SKShapeNode(circleOfRadius:enemy.boss ? 13:8)
                node.strokeColor = .white; node.name = enemy.id; enemies.addChild(node); enemyNodes[enemy.id] = node
                let label = SKLabelNode(); label.name = "hp"; label.fontSize = 9; label.position.y = 15; node.addChild(label)
            }
            node.fillColor = enemy.boss ? (enemy.phase == 2 ? .systemPurple:.systemOrange):.systemRed
            node.position = Self.position(enemy.surface!)
            (node.childNode(withName:"hp") as? SKLabelNode)?.text = String(enemy.health)
        }
    }
    var reducedMotion=false
    func combatEffect(_ skill: Bool) {
        guard !reducedMotion else{return}
        let effect = SKShapeNode(circleOfRadius: skill ? 90:42)
        effect.position = avatar.position; effect.strokeColor = .systemYellow; effect.lineWidth = 3; effect.zPosition = 15
        addChild(effect); effect.run(.sequence([.fadeOut(withDuration:0.25),.removeFromParent()]))
    }
    private func prepareTiles() {
        guard groups.isEmpty else { return }
        let colors: [RPGTerrain: UIColor] = [.grass: .init(red: 0.20, green: 0.43, blue: 0.32, alpha: 1), .sand: .init(red: 0.63, green: 0.53, blue: 0.32, alpha: 1),
            .water: .init(red: 0.15, green: 0.36, blue: 0.57, alpha: 1), .cliff: .darkGray, .road: .init(red: 0.45, green: 0.44, blue: 0.36, alpha: 1)]
        for terrain in RPGTerrain.allCases {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
                (colors[terrain] ?? .gray).setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
                UIColor.white.withAlphaComponent(0.05).setStroke(); context.stroke(CGRect(x: 0, y: 0, width: 24, height: 24))
            }
            let definition = SKTileDefinition(texture: SKTexture(image: image), size: CGSize(width: 24, height: 24))
            groups[terrain] = SKTileGroup(tileDefinition: definition)
        }
    }
    static func position(_ point: SurfacePoint) -> CGPoint { CGPoint(x: CGFloat(point.x) * cell + cell / 2, y: CGFloat(point.z) * cell + cell / 2) }
    override func update(_ currentTime: TimeInterval) { onFrame?(currentTime) }
    private func cell(_ touch: UITouch) -> SurfacePoint? {
        let point = touch.location(in: self)
        let cell = SurfacePoint(x: Int(floor(point.x / Self.cell)), z: Int(floor(point.y / Self.cell)))
        return cell.valid ? cell : nil
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        strokePoints = []; if let touch = touches.first, let point = cell(touch) { strokePoints = [point]; select(point) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let point = cell(touch), let last = strokePoints.last else { return }
        for value in RPGWorldEditing.line(last, point) where !strokePoints.contains(value) && strokePoints.count < 256 { strokePoints.append(value) }
        select(point)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let point = cell(touch) else { strokePoints = []; return }
        onSelectCell?(point)
        if tool != .select { if strokePoints.isEmpty { strokePoints = [point] }; onStroke?(strokePoints) }
        strokePoints = []
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { strokePoints = [] }
    func shutdown() { enemies.removeAllChildren(); enemyNodes.removeAll(); isPaused = true; onSelectCell = nil; onStroke = nil; onFrame = nil; mediaTargets = []; removeAllActions(); objects.removeAllChildren(); maps.values.forEach { $0.removeFromParent() }; maps.removeAll() }
}
