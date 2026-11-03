import SceneKit
import UIKit
import Combine

enum Glass3DMode: String, CaseIterable { case play, edit
    var title: String { self == .play ? L10n.t("游玩", "Play") : L10n.t("设计", "Design") }
}

enum Glass3DTool: String, CaseIterable {
    case select, place, draw, area, erase, building, media, creature, maze, track
    var title: String {
        switch self {
        case .select: L10n.t("选择", "Select"); case .place: L10n.t("放置", "Place"); case .draw: L10n.t("连续绘制", "Draw")
        case .area: L10n.t("区域", "Area"); case .erase: L10n.t("橡皮擦", "Erase"); case .building: L10n.t("建筑", "Building")
        case .media: L10n.t("媒体", "Media"); case .creature: L10n.t("生物", "Creature"); case .maze: L10n.t("迷宫", "Maze"); case .track: L10n.t("轨道", "Track")
        }
    }
    var symbol: String {
        switch self {
        case .select: "hand.point.up.left"; case .place: "plus.square"; case .draw: "scribble"; case .area: "rectangle.dashed"; case .erase: "eraser"
        case .building: "building.2"; case .media: "photo.on.rectangle"; case .creature: "pawprint"; case .maze: "square.grid.3x3.middle.filled"; case .track: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

/// An edit waiting for confirmation (draw strokes, areas, buildings,
/// generation): preview, conflicts, then one undoable commit.
struct Glass3DChoice: Identifiable, Equatable { let id: String; let title: String }

struct Glass3DPending {
    var title: String
    var preview: [SpatialBlock]
    var conflicts: Set<String>
    var detail: String
    var apply: (inout SpatialWorld) -> Void
}

/// Runs the 2.5D world on the main thread: one display-link step does the
/// clock, motion, events, physics, AI and rendering. Edits go through
/// `SpatialWorld.edit` (undoable) and are committed to the shared save.
@MainActor final class Glass3DController: NSObject, ObservableObject {
    let session: RPGSession
    let renderer = Glass3DRenderer()
    weak var view: SCNView?

    @Published private(set) var world: SpatialWorld
    @Published var mode = Glass3DMode.play { didSet { modeChanged() } }
    @Published var tool = Glass3DTool.select { didSet { pending = nil; trackPoints = [] } }
    @Published var camera = SpatialCameraState()
    @Published var pending: Glass3DPending? { didSet { renderer.showPreview(pending?.preview ?? [], conflicts: pending?.conflicts ?? []) } }
    @Published var selection: [String] = [] { didSet { renderer.showSelection(selectedBlocks) } }
    @Published var notice = ""
    @Published var pickChoices: [Glass3DChoice] = []
    @Published private(set) var health = 100
    @Published private(set) var stamina = 100
    @Published private(set) var cooldowns: [Double] = [0, 0, 0]
    @Published private(set) var bossBar: (name: String, health: Int, maxHealth: Int, phase: Int)?
    @Published private(set) var stats = (visibleCells: 0, blocks: 0, creatures: 0, activeAI: 0, videos: 0, fps: 0.0)
    @Published var quality: RPGGlassQuality { didSet { renderer.setQuality(quality); rebuildAll() } }
    // Builder settings.
    @Published var buildHeight = 0.0
    @Published var buildThickness = 1.0
    @Published var buildCollision = SpatialCollision.solid
    @Published var buildTint: String?
    @Published var stackOnTop = true
    @Published var heightSnap = 0.25
    @Published var buildingKind = BuildingKind.hut
    @Published var creatureKind = CreatureKind.enemy
    @Published var trackPoints: [SpatialVector] = []
    @Published var trackSmooth = true
    @Published var trackClosed = false

    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval?
    private var stick = (x: 0.0, y: 0.0)
    private var jumpRequested = false
    private var invulnerable = 0.0
    private var localCooldowns = (strike: 0.0, skill: 0.0, roll: 0.0)
    private var staticGeometry = SpatialGeometry(blocks: [])
    private var previousGeometry: SpatialGeometry?
    private var navigator: SpatialNavigator?
    private var pivots: [String: SpatialVector] = [:]
    private var brains: [String: CreatureBrain] = [:]
    private var farTimer = 0.0
    private var saveTimer = 0.0
    private var renderTimer = 0.0
    private var dirtyRuntime = false
    private var loadedChunks: Set<Int> = []
    private var frameTimes: [Double] = []
    private var random = SpatialRandom(seed: 99)
    private var drawCells: [SurfacePoint] = []
    private var areaStart: SurfacePoint?

    init(session: RPGSession) {
        self.session = session
        world = session.spatialWorld
        quality = session.glassQuality
        super.init()
        if world.player.position == SpatialVector(128.5, 128.5, 0) { world.player.position = world.spawn }
        renderer.setQuality(quality)
        renderer.media.binding = { [weak session] id in session?.world.mediaBindings.first { $0.id == id } }
        camera.target = world.player.position
        health = session.playerHealth; stamina = session.playerStamina
        geometryChanged()
    }

    // MARK: Lifecycle

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        rebuildAll()
    }
    func stop() {
        link?.invalidate(); link = nil; lastTime = nil
        persist(force: true)
        renderer.media.stop()
    }

    private func modeChanged() {
        pending = nil; selection = []; trackPoints = []
        camera.tilt = mode == .edit ? SpatialCameraRules.editTilt : SpatialCameraRules.playTilt
        if mode == .play { camera.target = world.player.position }
        clampCamera()
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = min(0.05, max(0, now - (lastTime ?? now)))
        lastTime = now
        guard dt > 0 else { return }
        frameTimes.append(dt); if frameTimes.count > 120 { frameTimes.removeFirst() }
        world.clock += dt
        let frames = world.groupFrames(pivots: pivots, clock: world.clock)
        let geometry = staticGeometry.moved(frames: frames)
        if mode == .play {
            simulate(dt: dt, geometry: geometry, frames: frames)
        }
        previousGeometry = geometry
        renderer.place(frames: frames)
        renderer.placePlayer(world.player)
        if mode == .play { follow(dt: dt) }
        renderer.place(camera: camera)
        renderTimer += dt
        if renderTimer > 0.25 { renderTimer = 0; refreshVisible() }
        renderer.media.update(visibleMedia: visibleMediaIDs, clock: world.clock, paused: pausedMedia(frames: frames))
        saveTimer += dt
        if saveTimer > 4 { saveTimer = 0; persist(force: false) }
    }

    private func simulate(dt: Double, geometry: SpatialGeometry, frames: [String: GroupFrame]) {
        // Events (proximity, timers, elevators) within the frame budget.
        let centers = frames.mapValues { $0.pivot + $0.offset }
        SpatialEventRules.step(&world, player: world.player.position, groupCenters: centers)
        // Player.
        let alive = health > 0
        if alive {
            let direction = SpatialCameraRules.worldDirection(stickX: stick.x, stickY: stick.y, yaw: camera.yaw)
            let input = SpatialInput(dx: direction.dx, dy: direction.dy, jump: jumpRequested)
            jumpRequested = false
            SpatialPhysics.step(&world.player, input: input, dt: dt, geometry: geometry, previous: previousGeometry)
            for box in geometry.touching(x: world.player.position.x, y: world.player.position.y, z: world.player.position.z) where box.buttonTarget != nil {
                if let block = world.blocks.first(where: { $0.id == box.id }), SpatialEventRules.press(&world, button: block) { notice = L10n.t("机关已触发", "Mechanism triggered") }
            }
            collectPickups()
        }
        invulnerable = max(0, invulnerable - dt)
        localCooldowns = (max(0, localCooldowns.strike - dt), max(0, localCooldowns.skill - dt), max(0, localCooldowns.roll - dt))
        cooldowns = [localCooldowns.strike / 0.35, localCooldowns.skill / 3, localCooldowns.roll / 1.2].map { ($0 * 20).rounded() / 20 }
        if alive, stamina < 100 { stamina = min(100, stamina + Int((dt * 14).rounded(.up))) }
        // Creatures: near ones every frame, far ones twice a second.
        farTimer += dt
        let far = farTimer >= 0.5
        if far { farTimer = 0 }
        var active = 0, boss: CreatureEntity?
        for index in world.creatures.indices where world.creatures[index].alive {
            let distance = (world.creatures[index].position - world.player.position).flatLength
            let near = distance < 28
            guard near || far else { continue }
            active += near ? 1 : 0
            var brain = brains[world.creatures[index].id] ?? CreatureBrain()
            let events = SpatialAI.step(&world.creatures[index], brain: &brain, player: world.player.position, playerAlive: alive,
                                        dt: near ? dt : 0.5, geometry: geometry, navigator: navigator, random: random.unit())
            brains[world.creatures[index].id] = brain
            for event in events { handle(event, from: world.creatures[index]) }
            let creature = world.creatures[index]
            if creature.kind.isBoss, creature.state == .chase || creature.state == .attack || creature.state == .alert, distance < 14 { boss = creature }
            dirtyRuntime = true
        }
        bossBar = boss.map { ($0.kind.title, $0.health, $0.maxHealth, $0.phase) }
        stats.activeAI = active
        session.applySpatialVitals(health: health, stamina: stamina)
    }

    private func handle(_ event: CreatureEvent, from creature: CreatureEntity) {
        switch event {
        case .hitPlayer(_, let damage): hurt(damage)
        case .telegraph(let id, let radius, let seconds): renderer.telegraph(id: id, at: creature.position, radius: radius, seconds: seconds)
        case .areaHit(_, let center, let radius, let damage):
            let offset = world.player.position - center
            if offset.flatLength <= radius && abs(offset.z) <= 1.6 { hurt(damage) }
        }
    }

    private func hurt(_ damage: Int) {
        guard invulnerable <= 0, health > 0 else { return }
        health = max(0, health - damage)
        if health == 0 { notice = L10n.t("生命耗尽，点「复苏」回到出生点。", "Out of health. Tap Revive to return to the spawn.") }
    }

    private func collectPickups() {
        for index in world.pickups.indices where !world.pickups[index].collected {
            let offset = world.pickups[index].position - world.player.position
            if offset.flatLength < 0.8 && abs(offset.z) < 1.3 {
                world.pickups[index].collected = true
                session.applySpatialVitals(health: health, stamina: stamina, shardDelta: world.pickups[index].shards)
                notice = L10n.t("获得月晶 ×\(world.pickups[index].shards)", "Found \(world.pickups[index].shards) moon shards"); dirtyRuntime = true
            }
        }
    }

    private func follow(dt: Double) {
        let target = world.player.position
        let k = min(1, dt * 6)
        camera.target = SpatialVector.lerp(camera.target, SpatialVector(target.x, target.y, target.z * 0.8), k)
    }

    // MARK: Input (HUD)

    func setStick(_ x: Double, _ y: Double) { stick = (x, y) }
    func jump() { jumpRequested = true }

    func attack(_ kind: SpatialCombat.Attack) {
        guard mode == .play, health > 0 else { return }
        let cost = kind == .strike ? 8 : 25
        guard stamina >= cost else { notice = L10n.t("耐力不足", "Not enough stamina"); return }
        if kind == .strike { guard localCooldowns.strike <= 0 else { return }; localCooldowns.strike = 0.35 } else { guard localCooldowns.skill <= 0 else { return }; localCooldowns.skill = 3 }
        stamina -= cost
        let damage = (kind == .strike ? 12 : 25) + (session.world.player.weapon == .moonBlade ? 8 : 0)
        let before = world.creatures
        let hits = SpatialCombat.attack(kind, from: world.player.position, facing: world.player.facing, damage: damage, creatures: &world.creatures, geometry: staticGeometry.moved(frames: world.groupFrames(pivots: pivots, clock: world.clock)))
        var shards = 0
        for id in hits {
            guard let after = world.creatures.first(where: { $0.id == id }), let was = before.first(where: { $0.id == id }), was.alive, !after.alive else { continue }
            shards += SpatialCombat.reward(after.kind)
            if after.kind == .boss { notice = L10n.t("大 Boss 已击败！获得月晶 ×\(SpatialCombat.reward(.boss))", "Boss defeated! +\(SpatialCombat.reward(.boss)) moon shards") }
            else if after.kind == .miniBoss { notice = L10n.t("小 Boss 已击败！", "Mini boss defeated!") }
        }
        if hits.isEmpty { notice = "" }
        dirtyRuntime = true
        session.applySpatialVitals(health: health, stamina: stamina, shardDelta: shards)
        if shards > 0 { persist(force: true) }
    }

    /// Dodge: a short dash with a moment of invulnerability.
    func roll() {
        guard mode == .play, health > 0, localCooldowns.roll <= 0, stamina >= 18 else { return }
        localCooldowns.roll = 1.2; stamina -= 18; invulnerable = 0.35
        let radians = world.player.facing * .pi / 180
        let geometry = staticGeometry.moved(frames: world.groupFrames(pivots: pivots, clock: world.clock))
        for _ in 0..<10 {
            let next = SpatialVector(world.player.position.x + cos(radians) * 0.22, world.player.position.y + sin(radians) * 0.22, world.player.position.z)
            if geometry.blocked(x: next.x, y: next.y, z: next.z) { break }
            world.player.position = next
        }
    }

    func revive() {
        world.player.position = world.spawn; world.player.lastSafe = world.spawn; world.player.verticalSpeed = 0
        health = 100; stamina = 100; notice = ""
        session.applySpatialVitals(health: health, stamina: stamina)
    }

    // MARK: Camera

    var aspect: Double {
        guard let size = view?.bounds.size, size.height > 0 else { return 0.46 }
        return Double(size.width / size.height)
    }
    func clampCamera() {
        camera.tilt = SpatialCameraRules.clampTilt(camera.tilt)
        camera.distance = SpatialCameraRules.clampDistance(camera, aspect: aspect)
        camera.target = SpatialVector(min(255.5, max(0.5, camera.target.x)), min(255.5, max(0.5, camera.target.y)), camera.target.z)
    }
    func zoom(by factor: Double) { camera.distance /= max(0.2, factor); clampCamera() }
    func turn(by degrees: Double) { camera.yaw = (camera.yaw + degrees).truncatingRemainder(dividingBy: 360); clampCamera() }
    func tilt(by degrees: Double) { camera.tilt += degrees; clampCamera() }
    func pan(screenDX: Double, screenDY: Double) {
        let scale = camera.distance / 400
        let direction = SpatialCameraRules.worldDirection(stickX: -screenDX, stickY: -screenDY, yaw: camera.yaw)
        camera.target = camera.target + SpatialVector(direction.dx * scale, direction.dy * scale, 0)
        clampCamera()
    }
    func resetCamera() {
        camera.yaw = 0; camera.tilt = mode == .edit ? SpatialCameraRules.editTilt : SpatialCameraRules.playTilt
        camera.distance = 14; if mode == .play { camera.target = world.player.position }
        clampCamera()
    }

    // MARK: Visible content

    private var visibleMediaIDs: Set<String> = []

    private func refreshVisible() {
        clampCamera()
        let reach = camera.distance * (1 + sin(camera.tilt * .pi / 180) * 2) + 12
        let center = camera.target
        let radius = Int((reach / 32).rounded(.up))
        let cx = Int(center.x) / 32, cy = Int(center.y) / 32
        var chunks = Set<Int>()
        for x in max(0, cx - radius)...min(7, cx + radius) { for y in max(0, cy - radius)...min(7, cy + radius) { chunks.insert(y * 8 + x) } }
        loadedChunks = chunks
        renderer.showGround(chunks: chunks)
        let all = allBlocks
        let visible = all.filter { chunks.contains(($0.y / 32) * 8 + $0.x / 32) }
        renderer.showBlocks(visible, pivots: pivots)
        renderer.showPlants(world.plants, chunks: chunks)
        renderer.showCreatures(world.creatures, near: center, radius: reach + 8)
        renderer.showPickups(world.pickups, near: center, radius: reach + 8)
        visibleMediaIDs = Set(visible.compactMap { $0.media.flatMap { session.world.mediaBindings.first(where: { b in b.id == $0.bindingID })?.mediaID } })
        let average = frameTimes.isEmpty ? 0 : frameTimes.reduce(0, +) / Double(frameTimes.count)
        stats = (SpatialCameraRules.visibleCells(camera, aspect: aspect), renderer.blockNodeCount, renderer.creatureNodeCount, stats.activeAI, renderer.media.decoderCount, average > 0 ? 1 / average : 0)
    }

    /// Media on moving blocks set to "plays while moving" pauses while the
    /// motion stands still.
    private func pausedMedia(frames: [String: GroupFrame]) -> Set<String> {
        var paused = Set<String>()
        for group in world.groups {
            guard let motionID = group.motionID, let motion = world.motions.first(where: { $0.id == motionID }), motion.mediaSync == .whileMoving else { continue }
            if SpatialMotionRules.pose(motion, clock: world.clock).moving { continue }
            for block in world.blocks where block.groupID == group.id {
                if let id = block.media.flatMap({ m in session.world.mediaBindings.first { $0.id == m.bindingID }?.mediaID }) { paused.insert(id) }
            }
        }
        return paused
    }

    /// 2.5D blocks plus the 2D sandbox's blocks on the ground.
    var allBlocks: [SpatialBlock] { world.blocks + SpatialLegacy.blocks(from: session.world.entities) }

    private func geometryChanged() {
        pivots = world.motionPivots()
        staticGeometry = SpatialGeometry(blocks: allBlocks, plants: world.plants, frames: world.groupFrames(pivots: pivots, clock: world.clock))
        navigator = SpatialNavigator(geometry: staticGeometry)
        previousGeometry = nil
    }

    private func rebuildAll() { geometryChanged(); refreshVisible() }

    // MARK: Saving

    /// Runtime state (positions, creature health, clock) is saved every few
    /// seconds and on leaving; edits are saved at once.
    func persist(force: Bool) {
        guard force || dirtyRuntime else { return }
        dirtyRuntime = false
        session.commitSpatial(world, persist: true)
    }

    /// One undoable edit, saved at once.
    func edit(_ title: String, bindings: [MediaBinding] = [], _ body: (inout SpatialWorld) -> Void) {
        var next = world
        next.edit(title, body)
        guard next != world else { return }
        guard session.commitSpatial(next, addBindings: bindings) else { notice = session.notice; return }
        world = next
        notice = L10n.t("已提交：", "Committed: ") + title
        rebuildAll(); renderer.showSelection(selectedBlocks)
    }
    func undo() {
        var next = world
        guard let title = next.undoLast(), session.commitSpatial(next) else { return }
        world = next; notice = L10n.t("已撤销：", "Undone: ") + title; selection = []; rebuildAll()
    }
    func redo() {
        var next = world
        guard let title = next.redoLast(), session.commitSpatial(next) else { return }
        world = next; notice = L10n.t("已重做：", "Redone: ") + title; selection = []; rebuildAll()
    }
    var canUndo: Bool { !world.history.undo.isEmpty }
    var canRedo: Bool { !world.history.redo.isEmpty }

    func confirmPending() {
        guard let pending else { return }
        self.pending = nil
        edit(pending.title, pending.apply)
    }

    // MARK: Picking and editing

    var selectedBlocks: [SpatialBlock] { world.blocks.filter { selection.contains($0.id) } }

    /// What is under a screen point, nearest first.
    func pick(_ point: CGPoint) -> [(kind: String, id: String, cell: SurfacePoint, height: Double)] {
        guard let view else { return [] }
        let hits = view.hitTest(point, options: [SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue, SCNHitTestOption.ignoreHiddenNodes: true])
        var result: [(String, String, SurfacePoint, Double)] = []
        for hit in hits {
            var node: SCNNode? = hit.node, name = ""
            while let current = node, current.name == nil || current.name == "" { node = current.parent }
            name = node?.name ?? ""
            let w = hit.worldCoordinates
            let cell = SurfacePoint(x: min(255, max(0, Int(Double(w.x).rounded(.down)))), z: min(255, max(0, Int(Double(-w.z).rounded(.down)))))
            if name.hasPrefix("block:") { result.append(("block", String(name.dropFirst(6)), cell, Double(w.y))) }
            else if name.hasPrefix("creature:") { result.append(("creature", String(name.dropFirst(9)), cell, Double(w.y))) }
            else if name.hasPrefix("chest:") { result.append(("chest", String(name.dropFirst(6)), cell, Double(w.y))) }
            else if name == "ground" { result.append(("ground", "", cell, 0)) }
        }
        return result
    }

    func tap(_ point: CGPoint) {
        let hits = pick(point)
        guard let first = hits.first else { return }
        guard mode == .edit else {
            // In play, tapping a creature attacks toward it.
            if first.kind == "creature", let creature = world.creatures.first(where: { $0.id == first.id }) {
                let offset = creature.position - world.player.position
                world.player.facing = atan2(offset.y, offset.x) * 180 / .pi; attack(.strike)
            }
            return
        }
        switch tool {
        case .select:
            if first.kind == "block", !first.id.hasPrefix("legacy:") { selection = [first.id] } else { selection = [] }
        case .place:
            placeBlock(at: first.cell, onTopOf: first.kind == "block" ? first.height : nil)
        case .erase:
            if first.kind == "block", !first.id.hasPrefix("legacy:") { let id = first.id; edit(L10n.t("擦除方块", "Erase Block")) { w in w.blocks.removeAll { $0.id == id } } }
            else if first.kind == "creature" { let id = first.id; edit(L10n.t("删除生物", "Remove Creature")) { w in w.creatures.removeAll { $0.id == id } } }
        case .building:
            proposeBuilding(at: first.cell)
        case .creature:
            let kind = creatureKind, cell = first.cell, height = first.kind == "block" ? first.height : 0
            let base: (Int, Int) = switch kind { case .neutral: (10, 0); case .enemy: (30, 6); case .guardian: (45, 8); case .miniBoss: (160, 12); case .boss: (420, 16) }
            let position = SpatialVector(Double(cell.x) + 0.5, Double(cell.z) + 0.5, height)
            edit(L10n.t("放置", "Place ") + kind.title) { w in
                w.creatures.append(CreatureEntity(id: "c:" + UUID().uuidString, kind: kind, position: position, home: position, health: base.0, maxHealth: base.0, damage: base.1))
            }
        case .maze:
            proposeMaze(at: first.cell)
        case .track:
            trackPoints.append(SpatialVector(Double(first.cell.x) + 0.5, Double(first.cell.z) + 0.5, buildHeight))
            notice = L10n.t("已添加路径点 \(trackPoints.count)", "Waypoint \(trackPoints.count) added")
        case .media:
            if first.kind == "block", !first.id.hasPrefix("legacy:") { if selection.contains(first.id) { selection.removeAll { $0 == first.id } } else { selection.append(first.id) } }
        case .draw, .area: break
        }
    }

    /// Long press over overlapping objects: let the user choose.
    func longPress(_ point: CGPoint) {
        guard mode == .edit else { return }
        let hits = pick(point).filter { $0.kind == "block" && !$0.id.hasPrefix("legacy:") }
        var seen = Set<String>()
        pickChoices = hits.compactMap { hit in
            guard seen.insert(hit.id).inserted, let block = world.blocks.first(where: { $0.id == hit.id }) else { return nil }
            return Glass3DChoice(id: hit.id, title: L10n.t("方块 · 高度 \(String(format: "%.2f", block.elevation)) · 厚 \(String(format: "%.2f", block.thickness))", "Block · height \(String(format: "%.2f", block.elevation)) · thick \(String(format: "%.2f", block.thickness))"))
        }
        if pickChoices.count == 1 { selection = [pickChoices[0].id]; pickChoices = [] }
    }

    private func newBlock(at cell: SurfacePoint, elevation: Double) -> SpatialBlock {
        SpatialBlock(id: "b:" + UUID().uuidString, x: cell.x, y: cell.z, elevation: SpatialBuilder.snap(elevation, step: heightSnap), thickness: buildThickness,
                     glass: buildTint.map { SpatialGlass.tinted($0) } ?? .clear, collision: buildCollision)
    }

    private func stackHeight(at cell: SurfacePoint) -> Double {
        stackOnTop ? (world.blocks.filter { $0.x == cell.x && $0.y == cell.z }.map(\.top).max() ?? buildHeight) : buildHeight
    }

    func placeBlock(at cell: SurfacePoint, onTopOf height: Double?) {
        let block = newBlock(at: cell, elevation: stackOnTop ? max(height ?? 0, stackHeight(at: cell)) : buildHeight)
        let conflicts = SpatialBuilder.conflicts([block], in: world)
        guard conflicts.isEmpty else { notice = L10n.t("与已有实体方块重叠，换个高度或改为装饰碰撞。", "Overlaps a solid block; change the height or use decor collision."); return }
        edit(L10n.t("放置方块", "Place Block")) { w in w.blocks.append(block) }
    }

    /// Continuous drawing: cells are collected, then previewed for confirm.
    func drawStroke(at point: CGPoint, ended: Bool) {
        guard mode == .edit, tool == .draw || tool == .area, let hit = pick(point).first(where: { $0.kind == "ground" || $0.kind == "block" }) else { return }
        if tool == .draw {
            if drawCells.last != hit.cell { drawCells.append(hit.cell) }
        } else {
            if areaStart == nil { areaStart = hit.cell }
            drawCells = RPGEditDraft.rectangle(areaStart!, hit.cell)
        }
        let blocks = drawCells.prefix(RPGWorldEditing.maximumBatch).map { newBlock(at: $0, elevation: stackHeight(at: $0)) }
        let conflicts = Set(SpatialBuilder.conflicts(blocks, in: world))
        let title = tool == .draw ? L10n.t("连续绘制 \(blocks.count) 格", "Draw \(blocks.count) cells") : L10n.t("区域建造 \(blocks.count) 格", "Area \(blocks.count) cells")
        let fine = blocks.filter { !conflicts.contains($0.id) }
        pending = Glass3DPending(title: title, preview: blocks, conflicts: conflicts,
                                 detail: conflicts.isEmpty ? L10n.t("将放置 \(blocks.count) 个方块", "Places \(blocks.count) blocks") : L10n.t("将放置 \(fine.count) 个，\(conflicts.count) 个与实体重叠将跳过", "Places \(fine.count); \(conflicts.count) overlapping skipped"),
                                 apply: { w in w.blocks.append(contentsOf: fine) })
        if ended { drawCells = []; areaStart = nil }
    }

    private func proposeBuilding(at cell: SurfacePoint) {
        let group = "g:" + UUID().uuidString, kind = buildingKind
        let blocks = SpatialBuilder.building(kind, x: cell.x, y: cell.z, elevation: buildHeight, groupID: group, idPrefix: group)
        let conflicts = Set(SpatialBuilder.conflicts(blocks, in: world))
        pending = Glass3DPending(title: kind.title, preview: blocks, conflicts: conflicts,
                                 detail: L10n.t("\(blocks.count) 个方块", "\(blocks.count) blocks") + (conflicts.isEmpty ? "" : L10n.t("，\(conflicts.count) 个重叠将跳过", "; \(conflicts.count) overlapping skipped")),
                                 apply: { w in
                                     w.groups.append(BuildingGroup(id: group, name: kind.title, template: kind.rawValue))
                                     w.blocks.append(contentsOf: blocks.filter { !conflicts.contains($0.id) })
                                 })
    }

    private func proposeMaze(at cell: SurfacePoint) {
        var random = SpatialRandom(seed: UInt64(cell.x * 1000 + cell.z) &+ UInt64(world.clock * 1000))
        let maze = SpatialMaze.generate(width: 6, height: 6, random: &random)
        let group = "g:" + UUID().uuidString
        let (w, h) = maze.side
        var blocks: [SpatialBlock] = []
        for ty in 0..<h { for tx in 0..<w where maze.wall(tx, ty) {
            let block = SpatialBlock(id: "\(group):\(blocks.count)", x: cell.x + tx, y: cell.z + ty, elevation: buildHeight, thickness: 2, glass: .tinted("9FB8FF", density: 0.5), groupID: group)
            if block.valid { blocks.append(block) }
        } }
        let chests = maze.deadEnds.prefix(2).map { PickupEntity(id: "chest:" + UUID().uuidString, position: SpatialVector(Double(cell.x + $0.0 * 2 + 1) + 0.5, Double(cell.z + $0.1 * 2 + 1) + 0.5, buildHeight), shards: 4) }
        let conflicts = Set(SpatialBuilder.conflicts(blocks, in: world))
        pending = Glass3DPending(title: L10n.t("玻璃迷宫", "Glass Maze"), preview: blocks, conflicts: conflicts,
                                 detail: L10n.t("\(blocks.count) 面墙，\(chests.count) 个宝箱，入口在南侧", "\(blocks.count) walls, \(chests.count) chests, entrance on the south"),
                                 apply: { world in
                                     world.groups.append(BuildingGroup(id: group, name: L10n.t("玻璃迷宫", "Glass Maze"), template: "maze"))
                                     world.blocks.append(contentsOf: blocks.filter { !conflicts.contains($0.id) }); world.pickups.append(contentsOf: chests)
                                 })
    }

    // MARK: Selection operations

    func selectGroup() {
        guard let group = selectedBlocks.first?.groupID else { return }
        selection = world.blocks.filter { $0.groupID == group }.map(\.id)
    }
    func groupSelection() {
        let ids = Set(selection); guard ids.count > 1 else { return }
        let group = "g:" + UUID().uuidString
        edit(L10n.t("组合建筑", "Group Blocks")) { w in
            w.groups.append(BuildingGroup(id: group, name: L10n.t("建筑 \(w.groups.count + 1)", "Building \(w.groups.count + 1)")))
            for i in w.blocks.indices where ids.contains(w.blocks[i].id) { w.blocks[i].groupID = group }
        }
    }
    func updateSelected(_ title: String, _ change: @escaping (inout SpatialBlock) -> Void) {
        let ids = Set(selection); guard !ids.isEmpty else { return }
        edit(title) { w in for i in w.blocks.indices where ids.contains(w.blocks[i].id) { change(&w.blocks[i]); w.blocks[i].origin = .user } }
    }
    func raiseSelection(_ dz: Double) { let ids = Set(selection); edit(L10n.t("升降", "Raise / Lower")) { w in SpatialBuilder.raise(ids, by: dz, world: &w) } }
    func alignSelection() { let ids = Set(selection), h = buildHeight; edit(L10n.t("高度对齐", "Align Heights")) { w in SpatialBuilder.align(ids, elevation: h, world: &w) } }
    func gradientSelection(to top: Double) { let ids = Set(selection), h = buildHeight; edit(L10n.t("高度渐变", "Height Gradient")) { w in SpatialBuilder.gradient(ids, from: h, to: top, world: &w) } }
    func deleteSelection() { let ids = Set(selection); edit(L10n.t("删除 \(ids.count) 个方块", "Delete \(ids.count) blocks")) { w in w.blocks.removeAll { ids.contains($0.id) } }; selection = [] }

    var selectedGroup: BuildingGroup? { selectedBlocks.first?.groupID.flatMap { id in world.groups.first { $0.id == id } } }

    func copyGroup() {
        guard let group = selectedGroup else { return }
        let new = "g:" + UUID().uuidString
        edit(L10n.t("复制建筑", "Copy Building")) { w in SpatialBuilder.copy(group: group.id, dx: 4, dy: 0, dz: 0, newGroup: new, idPrefix: new, world: &w) }
        selection = world.blocks.filter { $0.groupID == new }.map(\.id)
    }
    func moveGroup(dx: Int, dy: Int, dz: Double) { guard let group = selectedGroup else { return }; edit(L10n.t("移动建筑", "Move Building")) { w in SpatialBuilder.move(group: group.id, dx: dx, dy: dy, dz: dz, world: &w) } }
    func turnGroup() { guard let group = selectedGroup else { return }; edit(L10n.t("旋转建筑", "Turn Building")) { w in SpatialBuilder.rotateQuarter(group: group.id, world: &w) } }
    func saveTemplate() {
        guard let group = selectedGroup, let template = SpatialBuilder.template(from: group.id, name: group.name, id: "t:" + UUID().uuidString, world: world) else { return }
        edit(L10n.t("保存模板", "Save Template")) { w in w.templates.append(template) }
    }
    func stampTemplate(_ template: BuildingTemplate, at cell: SurfacePoint) {
        let group = "g:" + UUID().uuidString
        let blocks = SpatialBuilder.stamp(template, x: cell.x, y: cell.z, elevation: buildHeight, groupID: group, idPrefix: group)
        let conflicts = Set(SpatialBuilder.conflicts(blocks, in: world))
        pending = Glass3DPending(title: template.name, preview: blocks, conflicts: conflicts, detail: L10n.t("\(blocks.count) 个方块", "\(blocks.count) blocks"),
                                 apply: { w in w.groups.append(BuildingGroup(id: group, name: template.name)); w.blocks.append(contentsOf: blocks.filter { !conflicts.contains($0.id) }) })
    }

    // MARK: Motion

    func assignMotion(_ kind: MotionKind) {
        guard let group = selectedGroup ?? ensureGroup() else { notice = L10n.t("先选中方块", "Select blocks first"); return }
        let id = "m:" + UUID().uuidString
        let motion: SpatialMotion
        switch kind {
        case .slide: motion = .slide(id: id, dx: 6, dy: 0)
        case .lift: motion = .lift(id: id, height: 4)
        case .rotate: motion = .rotate(id: id)
        case .elevator: motion = .elevator(id: id, floors: [0, 4, 8])
        case .track:
            guard trackPoints.count >= 2, let pivot = world.blocks.filter({ $0.groupID == group.id }).first.map({ SpatialVector(Double($0.x) + 0.5, Double($0.y) + 0.5, $0.elevation) }) else {
                notice = L10n.t("用「轨道」工具在地图上点至少两个路径点", "Add at least two waypoints with the Track tool"); return
            }
            let points = [SpatialVector.zero] + trackPoints.map { $0 - pivot }
            motion = .track(id: id, points: Array(points.prefix(SpatialMotion.maximumKeyframes)), smooth: trackSmooth, closed: trackClosed)
        }
        edit(kind.title) { w in
            if let old = w.groups.first(where: { $0.id == group.id })?.motionID { w.motions.removeAll { $0.id == old } }
            w.motions.append(motion)
            if let i = w.groups.firstIndex(where: { $0.id == group.id }) { w.groups[i].motionID = id }
        }
        trackPoints = []
    }
    func updateMotion(_ change: @escaping (inout SpatialMotion) -> Void) {
        guard let id = selectedGroup?.motionID else { return }
        edit(L10n.t("运动设置", "Motion Settings")) { w in if let i = w.motions.firstIndex(where: { $0.id == id }) { change(&w.motions[i]) } }
    }
    func removeMotion() {
        guard let group = selectedGroup, let id = group.motionID else { return }
        edit(L10n.t("停止运动", "Remove Motion")) { w in w.motions.removeAll { $0.id == id }; if let i = w.groups.firstIndex(where: { $0.id == group.id }) { w.groups[i].motionID = nil } }
    }
    var selectedMotion: SpatialMotion? { selectedGroup?.motionID.flatMap { id in world.motions.first { $0.id == id } } }
    /// Elevator floor buttons and "start" for triggered motions.
    func runMotion(floor: Int? = nil) {
        guard let id = selectedMotion?.id, let i = world.motions.firstIndex(where: { $0.id == id }) else { return }
        if let floor { SpatialMotionRules.call(&world.motions[i], floor: floor, clock: world.clock) } else { SpatialMotionRules.start(&world.motions[i], clock: world.clock) }
        dirtyRuntime = true
    }
    /// Turns the selected block into a button for another group.
    func makeButton(for group: String?) { updateSelected(L10n.t("机关按钮", "Button")) { $0.buttonTarget = group } }

    private func ensureGroup() -> BuildingGroup? {
        guard !selection.isEmpty else { return nil }
        groupSelection()
        return selectedGroup
    }

    // MARK: Media

    /// Shows a library file on the selected blocks' face; several blocks
    /// share one binding and each shows its piece.
    func assignMedia(id mediaID: String, kind: RPGMediaKind, face: SpatialFace, stretch: Bool) {
        let ids = selection; guard !ids.isEmpty else { notice = L10n.t("先选中方块（媒体工具可多选）", "Select blocks first (the Media tool can pick several)"); return }
        let binding = MediaBinding(id: "sb:" + UUID().uuidString, mediaID: mediaID, kind: kind, fit: .fill)
        edit(L10n.t("媒体 · ", "Media · ") + kind.title, bindings: [binding]) { w in
            SpatialBuilder.mediaGrid(bindingID: binding.id, blocks: ids, face: face, stretch: stretch, world: &w)
        }
    }
    func clearMedia() { updateSelected(L10n.t("移除媒体", "Remove Media")) { $0.media = nil } }

    // MARK: Generation

    /// Works out a generated world off the main thread for the preview.
    func previewGeneration(_ configuration: WorldGenerationConfiguration) async -> (SpatialWorld, GenerationSummary) {
        let base = world
        return await Task.detached(priority: .userInitiated) { SpatialWorldGenerator.generate(configuration, keeping: base) }.value
    }
    func applyGeneration(_ generated: SpatialWorld) {
        edit(L10n.t("一键生成世界", "Generate World")) { w in
            let history = w.history, clock = w.clock
            w = generated; w.history = history; w.clock = clock
        }
        world.player.position = world.spawn; camera.target = world.spawn
        brains = [:]
        persist(force: true)
    }
}
