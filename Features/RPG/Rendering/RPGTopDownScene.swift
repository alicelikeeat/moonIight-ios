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
    private var glassMaps: [ChunkCoordinate: SKTileMapNode] = [:]
    /// Glass lab option A: show the glass-look tile over every loaded cell.
    var glassTextureVisible = false { didSet { glassMaps.values.forEach { $0.isHidden = !glassTextureVisible } } }
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
        for key in Array(maps.keys) where !wanted.contains(key) { maps.removeValue(forKey: key)?.removeFromParent(); glassMaps.removeValue(forKey: key)?.removeFromParent(); appliedTerrain[key] = nil }
        let set = SKTileSet(tileGroups: RPGTerrain.allCases.compactMap { groups[$0] })
        for chunk in chunks where maps[chunk.coordinate] == nil {
            let map = SKTileMapNode(tileSet: set, columns: 32, rows: 32, tileSize: CGSize(width: 24, height: 24))
            map.anchorPoint = .zero
            map.position = CGPoint(x: CGFloat(chunk.coordinate.x * 32) * Self.cell, y: CGFloat(chunk.coordinate.z * 32) * Self.cell)
            for z in 0..<32 { for x in 0..<32 { map.setTileGroup(groups[chunk.terrain[z * 32 + x]], forColumn: x, row: z) } }
            ground.addChild(map); maps[chunk.coordinate] = map; appliedTerrain[chunk.coordinate] = [:]
        }
        applyTerrain(world.terrainOverrides ?? [:], chunks: chunks)
        for chunk in chunks where glassMaps[chunk.coordinate] == nil {
            let glass = RPGGlassTexture.map(columns: 32, rows: 32)
            glass.position = CGPoint(x: CGFloat(chunk.coordinate.x * 32) * Self.cell, y: CGFloat(chunk.coordinate.z * 32) * Self.cell)
            glass.isHidden = !glassTextureVisible
            addChild(glass); glassMaps[chunk.coordinate] = glass
        }
        objects.removeAllChildren(); sharedIDs = []
        avatar.children.filter { $0.name?.hasPrefix("media:") == true }.forEach { $0.removeFromParent() }
        mediaTargets = RPGMediaSprites.backgrounds(world: world, camera: worldCamera, size: size, topDown: true)
        if let target = RPGMediaSprites.attach(ownerID: "player", bindingID: world.player.mediaBindingID, role: .player, parent: avatar, world: world, size: CGSize(width: 24, height: 32)) { mediaTargets.append(target) }
        for entity in chunks.flatMap({ RPGWorldEditing.entities(in: $0, world: world) }) {
            guard let point = entity.surface, wanted.contains(point.chunk ?? .init(x: -1, z: -1)) else { continue }
            let node = SKShapeNode(rectOf: CGSize(width: 16, height: 18), cornerRadius: 4)
            let display = entity.definitionID == RPGWorldEditing.displayDefinition
            node.fillColor = display ? .clear : entity.definitionID == "wood" ? .systemBrown : .systemGray
            node.strokeColor = .white.withAlphaComponent(display ? 0.25 : 0.5); node.position = Self.position(point); node.name = entity.id
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
    func movePlayer(_ point: SurfacePoint) { avatar.position = Self.position(point); if cameraFollowsPlayer { worldCamera.position = avatar.position } }

    // MARK: Map editor terrain, preview and touches (task E)

    /// Terrain overrides currently drawn per chunk, so edits and undo only
    /// repaint the tiles that changed.
    private var appliedTerrain: [ChunkCoordinate: [String: RPGTerrain]] = [:]
    private func applyTerrain(_ overrides: [String: RPGTerrain], chunks: [RPGChunk]) {
        var wanted: [ChunkCoordinate: [String: RPGTerrain]] = [:]
        for (key, terrain) in overrides { if let chunk = RPGWorldTerrain.point(key)?.chunk, maps[chunk] != nil { wanted[chunk, default: [:]][key] = terrain } }
        for chunk in chunks {
            guard let map = maps[chunk.coordinate] else { continue }
            let applied = appliedTerrain[chunk.coordinate] ?? [:], desired = wanted[chunk.coordinate] ?? [:]
            guard applied != desired else { continue }
            let origin = (chunk.coordinate.x * 32, chunk.coordinate.z * 32)
            for (key, _) in applied where desired[key] == nil {
                if let p = RPGWorldTerrain.point(key), let base = chunk.tile(localX: p.x - origin.0, localZ: p.z - origin.1) { map.setTileGroup(groups[base], forColumn: p.x - origin.0, row: p.z - origin.1) }
            }
            for (key, terrain) in desired where applied[key] != terrain {
                if let p = RPGWorldTerrain.point(key) { map.setTileGroup(groups[terrain], forColumn: p.x - origin.0, row: p.z - origin.1) }
            }
            appliedTerrain[chunk.coordinate] = desired
        }
    }

    /// How a touch is read in the map editor. Decided at touch-down; a
    /// touch never pans, draws and selects at once.
    enum EditorTouch { case legacy, panSelect, stroke, rectangle, tapOnly }
    var editorTouch = EditorTouch.legacy { didSet { cancelPan() } }
    var onEditorStroke: ((SurfacePoint, SurfacePoint) -> Void)?
    var onEditorRectangle: ((SurfacePoint, SurfacePoint, Bool) -> Void)?
    var onEditorTap: ((SurfacePoint) -> Void)?
    var onLongPressCell: ((SurfacePoint) -> Void)?
    var editorLongPressEnabled = false { didSet { longPress?.isEnabled = editorLongPressEnabled } }
    private var longPress: UILongPressGestureRecognizer?
    private var editorAnchor: SurfacePoint?
    private var editorLast: SurfacePoint?

    /// Draft preview: light tinted squares, separate from real cells. No
    /// media is created for previewed cells.
    private let previewLayer = SKNode()
    private var previewSprites: [SKSpriteNode] = []
    private let areaOutline = SKShapeNode()
    func showPreview(_ cells: [SurfacePoint], tint: UIColor) {
        if previewLayer.parent == nil { previewLayer.zPosition = 9; addChild(previewLayer) }
        while previewSprites.count < cells.count {
            let sprite = SKSpriteNode(color: .white, size: CGSize(width: 22, height: 22)); sprite.alpha = 0.38
            previewLayer.addChild(sprite); previewSprites.append(sprite)
        }
        for (index, sprite) in previewSprites.enumerated() {
            if index < cells.count { sprite.isHidden = false; sprite.color = tint; sprite.position = Self.position(cells[index]) } else { sprite.isHidden = true }
        }
    }
    /// Multi-select area outline, or nil to hide it.
    func showArea(_ area: (SurfacePoint, SurfacePoint)?) {
        if areaOutline.parent == nil { areaOutline.zPosition = 11; areaOutline.strokeColor = .systemCyan; areaOutline.lineWidth = 1.5; areaOutline.fillColor = .systemCyan.withAlphaComponent(0.08); addChild(areaOutline) }
        guard let (a, b) = area else { areaOutline.isHidden = true; return }
        let minX = CGFloat(min(a.x, b.x)) * Self.cell, minY = CGFloat(min(a.z, b.z)) * Self.cell
        let width = CGFloat(abs(a.x - b.x) + 1) * Self.cell, height = CGFloat(abs(a.z - b.z) + 1) * Self.cell
        areaOutline.path = CGPath(rect: CGRect(x: minX, y: minY, width: width, height: height), transform: nil); areaOutline.isHidden = false
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let view else { return }
        let point = convertPoint(fromView: gesture.location(in: view))
        if let cell = RPGCameraRules.cell(at: point) { cancelPan(); onLongPressCell?(cell) }
    }

    // MARK: Map editor camera (task E)

    /// Off in free edit: the camera stays where the user left it.
    var cameraFollowsPlayer = true
    /// Free edit with the select tool: a one-finger drag pans the map.
    var freePan: Bool { get { editorTouch == .panSelect } set { editorTouch = newValue ? .panSelect : .legacy } }
    /// Pinch zoom and two-finger pan (both editor modes).
    var cameraGesturesEnabled = false { didSet { pinch?.isEnabled = cameraGesturesEnabled; twoFingerPan?.isEnabled = cameraGesturesEnabled } }
    /// Camera centre and zoom after the user moved the camera.
    var onCameraMoved: ((CGPoint, CGFloat) -> Void)?
    var cameraCenter: CGPoint { worldCamera.position }
    var cameraZoom: CGFloat { worldCamera.xScale }
    private var pinch: UIPinchGestureRecognizer?
    private var twoFingerPan: UIPanGestureRecognizer?
    private var pinchStartZoom: CGFloat = 1
    private var panStart: CGPoint?
    private var panLast: CGPoint?
    private var panning = false

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        guard pinch == nil else { return }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPanned(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        pinch.isEnabled = cameraGesturesEnabled; pan.isEnabled = cameraGesturesEnabled
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        hold.minimumPressDuration = 0.5; hold.isEnabled = editorLongPressEnabled
        view.addGestureRecognizer(pinch); view.addGestureRecognizer(pan); view.addGestureRecognizer(hold)
        self.pinch = pinch; twoFingerPan = pan; longPress = hold
    }
    func setCamera(center: CGPoint, zoom: CGFloat) {
        worldCamera.position = RPGCameraRules.clampCenter(center); worldCamera.setScale(RPGCameraRules.clampZoom(zoom))
    }
    func recenterOnPlayer() { worldCamera.position = avatar.position }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began: pinchStartZoom = worldCamera.xScale; cancelPan()
        case .changed: worldCamera.setScale(RPGCameraRules.clampZoom(pinchStartZoom / max(0.01, gesture.scale)))
        case .ended, .cancelled: onCameraMoved?(worldCamera.position, worldCamera.xScale)
        default: break
        }
    }
    @objc private func twoFingerPanned(_ gesture: UIPanGestureRecognizer) {
        guard let view else { return }
        if gesture.state == .began { cancelPan() }
        let delta = gesture.translation(in: view); gesture.setTranslation(.zero, in: view)
        if !cameraFollowsPlayer { moveCamera(by: delta) }
        if gesture.state == .ended || gesture.state == .cancelled { onCameraMoved?(worldCamera.position, worldCamera.xScale) }
    }
    private func moveCamera(by viewDelta: CGPoint) {
        let shift = RPGCameraRules.panTranslation(viewDelta: viewDelta, zoom: worldCamera.xScale)
        worldCamera.position = RPGCameraRules.clampCenter(CGPoint(x: worldCamera.position.x + shift.x, y: worldCamera.position.y + shift.y))
    }
    private func cancelPan() { panStart = nil; panLast = nil; panning = false; strokePoints = []; editorAnchor = nil; editorLast = nil }
    /// The player's position in SpriteView coordinates (glass lab option C).
    func playerViewPoint() -> CGPoint? { view == nil ? nil : convertPoint(toView: avatar.position) }
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
        // Each touch is either a tap/pan (free edit, select tool) or a
        // selection/stroke, decided here and never both.
        if freePan && tool == .select, let touch = touches.first, let view {
            panStart = touch.location(in: view); panLast = panStart; panning = false; return
        }
        if editorTouch != .legacy && editorTouch != .panSelect {
            guard let touch = touches.first, let point = cell(touch) else { return }
            editorAnchor = point; editorLast = point
            switch editorTouch {
            case .stroke: onEditorStroke?(point, point)
            case .rectangle: onEditorRectangle?(point, point, false)
            default: break
            }
            return
        }
        strokePoints = []; if let touch = touches.first, let point = cell(touch) { strokePoints = [point]; select(point) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if freePan && tool == .select {
            guard let touch = touches.first, let view, let start = panStart, let last = panLast else { return }
            let now = touch.location(in: view)
            if !panning && hypot(now.x - start.x, now.y - start.y) < RPGCameraRules.panSlop { return }
            panning = true; moveCamera(by: CGPoint(x: now.x - last.x, y: now.y - last.y)); panLast = now; return
        }
        if editorTouch != .legacy && editorTouch != .panSelect {
            guard let touch = touches.first, let point = cell(touch), let anchor = editorAnchor, let last = editorLast, point != last else { return }
            switch editorTouch {
            case .stroke: onEditorStroke?(last, point)
            case .rectangle: onEditorRectangle?(anchor, point, false)
            default: break
            }
            editorLast = point; return
        }
        guard let touch = touches.first, let point = cell(touch), let last = strokePoints.last else { return }
        for value in RPGWorldEditing.line(last, point) where !strokePoints.contains(value) && strokePoints.count < 256 { strokePoints.append(value) }
        select(point)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if freePan && tool == .select {
            defer { cancelPan() }
            if panning { onCameraMoved?(worldCamera.position, worldCamera.xScale) }
            else if let touch = touches.first, let point = cell(touch) { select(point); onSelectCell?(point) }
            return
        }
        if editorTouch != .legacy && editorTouch != .panSelect {
            defer { editorAnchor = nil; editorLast = nil }
            let point = touches.first.flatMap { cell($0) } ?? editorLast
            switch editorTouch {
            case .rectangle: if let anchor = editorAnchor, let point { onEditorRectangle?(anchor, point, true) }
            case .tapOnly: if let point { select(point); onEditorTap?(point) }
            default: break
            }
            return
        }
        guard let touch = touches.first, let point = cell(touch) else { strokePoints = []; return }
        onSelectCell?(point)
        if tool != .select { if strokePoints.isEmpty { strokePoints = [point] }; onStroke?(strokePoints) }
        strokePoints = []
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelPan() }
    func shutdown() { enemies.removeAllChildren(); enemyNodes.removeAll(); isPaused = true; onSelectCell = nil; onStroke = nil; onFrame = nil; onCameraMoved = nil; cameraFollowsPlayer = true; editorTouch = .legacy; cameraGesturesEnabled = false; editorLongPressEnabled = false; onEditorStroke = nil; onEditorRectangle = nil; onEditorTap = nil; onLongPressCell = nil; showPreview([], tint: .clear); showArea(nil); appliedTerrain = [:]; mediaTargets = []; removeAllActions(); objects.removeAllChildren(); maps.values.forEach { $0.removeFromParent() }; maps.removeAll(); glassMaps.values.forEach { $0.removeFromParent() }; glassMaps.removeAll() }
}
