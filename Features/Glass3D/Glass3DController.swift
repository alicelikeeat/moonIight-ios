import RealityKit
import UIKit
import Combine

enum Glass3DMode: String, CaseIterable { case play, edit
    var title: String { self == .play ? L10n.t("游玩", "Play") : L10n.t("设计", "Design") }
}

enum Glass3DTool: String, CaseIterable {
    case select, place, draw, area, erase, dig, building, media, creature, player, maze, track
    var title: String {
        switch self {
        case .select: L10n.t("选择", "Select"); case .place: L10n.t("放置", "Place"); case .draw: L10n.t("连续绘制", "Draw")
        case .area: L10n.t("区域", "Area"); case .erase: L10n.t("橡皮擦", "Erase"); case .dig: L10n.t("挖地下", "Dig"); case .building: L10n.t("建筑", "Building")
        case .media: L10n.t("媒体", "Media"); case .creature: L10n.t("生物", "Creature"); case .player: L10n.t("主角", "Player"); case .maze: L10n.t("迷宫", "Maze"); case .track: L10n.t("轨道", "Track")
        }
    }
    var symbol: String {
        switch self {
        case .select: "hand.point.up.left"; case .place: "plus.square"; case .draw: "scribble"; case .area: "rectangle.dashed"; case .erase: "eraser"; case .dig: "arrow.down.to.line"
        case .building: "building.2"; case .media: "photo.on.rectangle"; case .creature: "pawprint"; case .player: "figure.stand"; case .maze: "square.grid.3x3.middle.filled"; case .track: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }
}

/// An edit waiting for confirmation (draw strokes, areas, buildings,
/// generation): preview, conflicts, then one undoable commit.
struct Glass3DChoice: Identifiable, Equatable { let id: String; let title: String }
struct Glass3DHotbarSlot: Identifiable, Equatable { let index: Int; let id: String; let name: String; let symbol: String; let cooldown: Double; var identity: Int { index } }

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
@available(iOS 18.0, *)
@MainActor final class Glass3DController: NSObject, ObservableObject {
    let session: RPGSession
    let renderer = Glass3DRenderer()
    /// Size of the 3D view in points (for projection, picking, aspect).
    var viewSize: CGSize = .zero
    /// Native iOS glass on blocks (iOS 26+), drawn by the SwiftUI layer.
    let nativeGlass = Glass3DNativeGlass()
    @Published var nativeGlassEnabled = UserDefaults.standard.object(forKey: "moonlight.glass3d.native") as? Bool ?? true {
        didSet { UserDefaults.standard.set(nativeGlassEnabled, forKey: "moonlight.glass3d.native"); applyQuality(); rebuildAll() }
    }
    static var nativeGlassAvailable: Bool { if #available(iOS 26.0, *) { return true }; return false }
    private var glassFade = NativeGlassFade()
    private var visibleBlockCache: [SpatialBlock] = []

    /// The world changes every frame (clock, positions); SwiftUI only
    /// redraws on edits (`revision`), never 60 times a second.
    private(set) var world: SpatialWorld
    @Published private(set) var revision = 0
    @Published var mode = Glass3DMode.play { didSet { modeChanged() } }
    @Published var tool = Glass3DTool.select { didSet { pending = nil; trackPoints = [] } }
    /// Moves every frame while following the player, so not published.
    var camera = SpatialCameraState()
    @Published var pending: Glass3DPending? { didSet { renderer.showPreview(pending?.preview ?? [], conflicts: pending?.conflicts ?? []) } }
    @Published var selection: [String] = [] { didSet { renderer.showSelection(selectedBlocks) } }
    @Published var notice = ""
    @Published var pickChoices: [Glass3DChoice] = []
    @Published private(set) var health = 100
    @Published private(set) var stamina = 100
    @Published private(set) var cooldowns: [Double] = [0, 0, 0]
    @Published private(set) var bossBar: (name: String, health: Int, maxHealth: Int, phase: Int)?
    @Published private(set) var stats = (visibleCells: 0, blocks: 0, creatures: 0, activeAI: 0, videos: 0, fps: 0.0)
    @Published var quality: RPGGlassQuality { didSet { applyQuality(); rebuildAll() } }
    // Builder settings.
    @Published var buildHeight = 0.0
    @Published var buildThickness = 1.0
    @Published var buildCollision = SpatialCollision.solid
    @Published var buildTint: String?
    @Published var stackOnTop = true
    @Published var heightSnap = 0.25
    @Published var buildingKind = BuildingKind.hut
    @Published var creatureKind = CreatureKind.enemy
    /// Look for the next placed creature (a character template id; nil = default body).
    @Published var creatureLook: String?

    /// Character template showing a generated model: the existing one, or a
    /// new one (one undo step) — models can be picked without adding them first.
    func characterID(forGenerated model: Generated3DManifest) -> String {
        if let existing = (world.characters ?? []).first(where: { $0.generatedModelID == model.id || ($0.mode == .model && $0.name == model.name && model.meshFile == nil) }) { return existing.id }
        var template = CharacterTemplate(id: "char:" + UUID().uuidString, name: String(model.name.prefix(60)))
        if model.meshFile != nil {
            template.mode = .generated
            template.generatedModelID = model.id
        } else if let usdz = Generated3DStore.shared.usdzURL(model) {
            let file = UUID().uuidString + ".usdz"
            guard (try? FileManager.default.copyItem(at: usdz, to: Glass3DCharacters.modelsFolder.appendingPathComponent(file))) != nil else { return creatureLook ?? "" }
            template.mode = .model
            template.modelMediaID = file
        }
        saveCharacter(template, bindings: [])
        return template.id
    }

    /// Generated model behind the selected look (for highlighting its card).
    var selectedLookModelID: String? {
        creatureLook.flatMap { id in (world.characters ?? []).first { $0.id == id }?.generatedModelID }
    }
    @Published var trackPoints: [SpatialVector] = []
    @Published var trackSmooth = true
    @Published var trackClosed = false

    private var link: CADisplayLink?
    /// Xbox / PlayStation / MFi controller, read once per frame.
    let gamepad = Glass3DGamepad()
    private var padMoving = false, padLooking = false
    private var driven = false
    /// RealityKit frame-update subscription (kept alive with the controller).
    var updates: EventSubscription?
    /// Right stick (look): turns and tilts the camera while held.
    private var look = (x: 0.0, y: 0.0)
    // v1.60 battle, characters, camera.
    private var battle = SpatialBattle()
    let effects = Glass3DEffects()
    let characters = Glass3DCharacters()
    private var animations: [String: CharacterAnimationState] = [:]
    private var creatureSpeed: [String: Double] = [:]
    @Published var lockedTarget: String?
    @Published var thirdPerson = true
    @Published private(set) var hotbarSlots: [Glass3DHotbarSlot] = []
    @Published var buildLayers = 1
    private var manualCameraUntil = 0.0
    private var preferredDistance = ThirdPersonCamera.distance
    private var activeAI = 0
    private var staminaBuffer = 0.0
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
        applyQuality()
        renderer.media.binding = { [weak session] id in session?.world.mediaBindings.first { $0.id == id } }
        renderer.root.addChild(effects.root)
        characters.media = renderer.media
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
        updates?.cancel(); updates = nil; driven = false
        persist(force: true)
        renderer.media.stop()
    }

    private func modeChanged() {
        glide = nil; stick = (0, 0); look = (0, 0); padMoving = false; padLooking = false
        pending = nil; selection = []; trackPoints = []
        if mode == .edit { designOverview(); return }
        camera.tilt = SpatialCameraRules.playTilt
        camera.target = world.player.position; if thirdPerson { cameraBehindPlayer() }
        clampCamera()
    }

    // MARK: Frame

    @objc private func tick(_ link: CADisplayLink) {
        // Fallback only: once RealityKit's own update event drives frames
        // (in step with rendering, no judder) the display link is idle.
        guard !driven else { return }
        let now = link.timestamp
        let dt = min(0.05, max(0, now - (lastTime ?? now)))
        lastTime = now
        frame(dt)
    }

    /// RealityKit calls this once per rendered frame.
    func renderedFrame(_ dt: Double) {
        driven = true
        frame(min(0.05, max(0, dt)))
    }

    /// Hidden (app in the background, another app in front, or a full-screen
    /// page over the world): no simulation, no rendering work, videos paused —
    /// keeps the phone cool. Saved on the way out.
    private(set) var suspended = false
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        if value {
            renderer.media.pauseAll()
            persist(force: true)
            updates?.cancel(); updates = nil; driven = false
            stick = (0, 0); look = (0, 0)
            link?.isPaused = true
        } else {
            lastTime = nil
            link?.isPaused = false
            // Everything edited while hidden (looks, tools) is shown again.
            rebuildAll(); renderer.showSelection(selectedBlocks)
        }
    }

    private func frame(_ dt: Double) {
        guard dt > 0, !suspended else { return }
        frameTimes.append(dt); if frameTimes.count > 120 { frameTimes.removeFirst() }
        world.clock += dt
        pollGamepad(dt: dt)
        let frames = world.groupFrames(pivots: pivots, clock: world.clock)
        let geometry = staticGeometry.moved(frames: frames)
        if mode == .play {
            simulate(dt: dt, geometry: geometry, frames: frames)
        }
        previousGeometry = geometry
        renderer.place(frames: frames)
        renderer.placePlayer(world.player)
        if mode == .play {
            if abs(look.x) > 0.01 || abs(look.y) > 0.01 {
                camera.yaw = (camera.yaw + look.x * 150 * dt).truncatingRemainder(dividingBy: 360)
                camera.tilt = SpatialCameraRules.clampTilt(camera.tilt - look.y * 70 * dt)
                manualCameraUntil = world.clock + 1.5
            }
            follow(dt: dt)
        } else {
            stepGlide(dt: dt)
        }
        renderer.place(camera: camera, eye: SpatialCameraRules.position(camera) + effects.shakeOffset(dt: dt))
        updateCharacters()
        characters.generated.tick(Float(dt))
        renderer.animate(clock: world.clock)
        // Native glass is its own layer over the 3D view: shown and redrawn
        // every frame while the camera is still, faded out while it moves
        // (the 3D glass blocks fade back in underneath meanwhile).
        let visibility = nativeGlassActive ? glassFade.step(camera: camera, dt: dt, shaking: effects.shake > 0.001) : 0
        nativeGlass.setOpacity(visibility)
        renderer.setBlockGlassOpacity(nativeGlassActive ? Float(1 - 0.55 * visibility) : 1)
        updateNativeGlass(frames: frames, drawFaces: visibility > 0)
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
        let rings = [localCooldowns.strike / 0.35, localCooldowns.skill / 3, localCooldowns.roll / 1.2].map { ($0 * 10).rounded() / 10 }
        if rings != cooldowns { cooldowns = rings }
        staminaBuffer += dt * 14
        if alive, stamina < 100, staminaBuffer >= 1 { stamina = min(100, stamina + Int(staminaBuffer)); staminaBuffer = 0 }
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
                                        dt: (near ? dt : 0.5) * (creatureSpeed[world.creatures[index].id] ?? 1), geometry: geometry, navigator: navigator, random: random.unit())
            brains[world.creatures[index].id] = brain
            for event in events { handle(event, from: world.creatures[index]) }
            let creature = world.creatures[index]
            if creature.kind.isBoss, creature.state == .chase || creature.state == .attack || creature.state == .alert, distance < 14 { boss = creature }
            dirtyRuntime = true
        }
        runBattle(dt: dt, geometry: geometry, alive: alive)
        if let id = lockedTarget, !(world.creatures.first { $0.id == id }.map { $0.alive && ($0.position - world.player.position).flatLength < 20 } ?? false) { lockedTarget = nil }
        let bar = boss.map { ($0.kind.title, $0.health, $0.maxHealth, (battle.bosses[$0.id]?.phase ?? 0) + 1) }
        if bar?.0 != bossBar?.name || bar?.1 != bossBar?.health || bar?.3 != bossBar?.phase { bossBar = bar }
        activeAI = active
        if health != session.playerHealth || stamina != session.playerStamina { session.applySpatialVitals(health: health, stamina: stamina) }
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
        camera.target = SpatialVector.lerp(camera.target, SpatialVector(target.x, target.y, target.z), k)
        guard thirdPerson else { return }
        let manual = world.clock < manualCameraUntil
        // Combat: keep the player and the locked target in view.
        if !manual, let id = lockedTarget, let foe = world.creatures.first(where: { $0.id == id }) {
            camera.yaw = ThirdPersonCamera.approach(camera.yaw, ThirdPersonCamera.combatYaw(player: target, target: foe.position), rate: 140, dt: dt)
        }
        if !manual { camera.tilt += (ThirdPersonCamera.tilt - camera.tilt) * min(1, dt * 3) }
        // Pull in in front of walls, ease back out when clear.
        let clear = ThirdPersonCamera.clearDistance(camera, wanted: preferredDistance, geometry: staticGeometry)
        camera.distance += (clear - camera.distance) * min(1, dt * (clear < camera.distance ? 12 : 3))
    }

    /// Puts the camera behind the player (third person) or back to the orbit view.
    func cameraBehindPlayer() {
        camera.yaw = ThirdPersonCamera.yawBehind(facing: world.player.facing); camera.tilt = ThirdPersonCamera.tilt
        preferredDistance = ThirdPersonCamera.distance; manualCameraUntil = 0
    }

    // MARK: Battle (v1.60)

    var hotbar: [String] { world.hotbar ?? SpatialBattle.defaultHotbar() }

    func castHotbar(_ slot: Int) {
        guard mode == .play, health > 0, hotbar.indices.contains(slot) else { return }
        let id = hotbar[slot]
        if let lockID = lockedTarget, let foe = world.creatures.first(where: { $0.id == lockID }) {
            world.player.facing = atan2(foe.position.y - world.player.position.y, foe.position.x - world.player.position.x) * 180 / .pi
        }
        var newStamina = stamina, newHealth = health
        switch battle.castPlayer(id, world: world, origin: world.player.position, facing: world.player.facing, target: lockedTarget, clock: world.clock, stamina: &newStamina, health: &newHealth) {
        case .cast:
            stamina = newStamina; health = newHealth
            if let skill = SpatialBattle.skill(id, in: world), let action = skill.events.compactMap({ event -> CharacterAction? in if case .action(let a) = event.kind { return a }; return nil }).first {
                requestAnimation(SpatialBattle.playerID, action, length: 0.6)
            }
        case .cooldown(let left): notice = L10n.t("冷却中 \(String(format: "%.1f", left)) 秒", "Cooling down \(String(format: "%.1f", left))s")
        case .stamina: notice = L10n.t("耐力不足", "Not enough stamina")
        case .unknown: notice = L10n.t("技能不存在", "Unknown skill")
        }
    }

    func toggleLock() {
        if lockedTarget != nil { lockedTarget = nil; return }
        lockedTarget = ThirdPersonCamera.lockTarget(player: world.player.position, facing: world.player.facing, creatures: world.creatures)
        if lockedTarget == nil { notice = L10n.t("附近没有可锁定的敌人", "No enemy nearby to lock") }
    }

    private func runBattle(dt: Double, geometry: SpatialGeometry, alive: Bool) {
        let out = battle.step(dt, world: &world, playerFacing: world.player.facing, playerInvulnerable: invulnerable > 0, playerAlive: alive,
                              geometry: geometry, clock: world.clock, roll: { id, n in
                                  var r = SpatialRandom(seed: UInt64(id.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } & 0xFFFF_FFFF) &+ UInt64(n)); return r.unit() })
        creatureSpeed = out.creatureSpeed
        if out.playerDamage > 0 { hurt(out.playerDamage) }
        if out.playerHealing > 0 { health = min(100, health + out.playerHealing) }
        if out.playerDash.flatLength > 0 {
            let steps = max(1, Int(out.playerDash.flatLength * 4))
            for _ in 0..<steps {
                let next = world.player.position + out.playerDash * (1 / Double(steps))
                if geometry.blocked(x: next.x, y: next.y, z: world.player.position.z) { break }
                world.player.position = SpatialVector(next.x, next.y, world.player.position.z)
            }
        }
        if !out.visuals.isEmpty || !battle.casts.isEmpty { effects.show(out.visuals, clock: world.clock, quality: quality, renderer: renderer) }
        var shards = 0
        for creature in out.defeated {
            shards += creature.kind == .boss ? (SpatialBattle.script(for: creature, in: world)?.rewardShards ?? 25) : SpatialCombat.reward(creature.kind)
            effects.burst(.explosion, at: creature.position + SpatialVector(0, 0, 0.8), seconds: 0.4, clock: world.clock, quality: quality)
            if creature.kind == .boss { notice = L10n.t("大 Boss 已击败！", "Boss defeated!") } else if creature.kind == .miniBoss { notice = L10n.t("小 Boss 已击败！", "Mini boss defeated!") }
        }
        for change in out.phaseChanges {
            notice = L10n.t("Boss 进入第 \(change.phase + 1) 阶段", "Boss enters phase \(change.phase + 1)")
            if let appearance = change.appearance, let i = world.creatures.firstIndex(where: { $0.id == change.id }) {
                world.creatures[i].characterID = appearance
                requestAnimation(change.id, .transform, length: 1.2)
            }
        }
        if shards > 0 { session.applySpatialVitals(health: health, stamina: stamina, shardDelta: shards); persist(force: true) }
        let slots = hotbar.enumerated().map { index, id -> Glass3DHotbarSlot in
            let skill = SpatialBattle.skill(id, in: world)
            let left = battle.cooldownLeft(id, clock: world.clock)
            return Glass3DHotbarSlot(index: index, id: id, name: skill?.name ?? id, symbol: skill?.symbol ?? "questionmark", cooldown: skill.map { $0.cooldown > 0 ? (left / $0.cooldown * 10).rounded() / 10 : 0 } ?? 0)
        }
        if slots != hotbarSlots { hotbarSlots = slots }
    }

    // MARK: Characters (v1.60)

    func requestAnimation(_ owner: String, _ action: CharacterAction, length: Double) {
        var state = animations[owner] ?? CharacterAnimationState()
        CharacterAnimator.request(&state, action, clock: world.clock, length: length)
        animations[owner] = state
    }

    private var lastPlayerPosition = SpatialVector.zero
    private func updateCharacters() {
        let templates = world.characters ?? []
        guard !templates.isEmpty else { renderer.playerBodyVisible = true; return }
        let speed = (world.player.position - lastPlayerPosition).flatLength / max(0.001, 1.0 / 60) ; lastPlayerPosition = world.player.position
        requestAnimation(SpatialBattle.playerID, health == 0 ? .death : CharacterAnimator.movement(speed: speed, grounded: world.player.grounded, verticalSpeed: world.player.verticalSpeed), length: 0.6)
        let playerTemplate = world.playerCharacterID.flatMap { id in templates.first { $0.id == id } }
        let playerState = animations[SpatialBattle.playerID] ?? CharacterAnimationState()
        let applied = characters.apply(playerTemplate, to: renderer.playerEntity, ownerID: SpatialBattle.playerID, action: playerState.action,
                                       direction: CharacterAnimator.direction(facing: world.player.facing, cameraYaw: camera.yaw, count: playerTemplate?.mode.directions ?? 1))
        renderer.playerBodyVisible = !applied
        for creature in world.creatures {
            guard let id = creature.characterID, let template = templates.first(where: { $0.id == id }), let holder = renderer.creatureEntity(creature.id) else { continue }
            requestAnimation(creature.id, CharacterAnimator.action(for: creature.state, moving: creature.state == .chase || creature.state == .wander || creature.state == .returning), length: 0.6)
            let facing = atan2(world.player.position.y - creature.position.y, world.player.position.x - creature.position.x) * 180 / .pi
            let shown = characters.apply(template, to: holder, ownerID: creature.id, action: animations[creature.id]?.action ?? .idle,
                                         direction: CharacterAnimator.direction(facing: facing, cameraYaw: camera.yaw, count: template.mode.directions))
            renderer.setCreatureBodyVisible(creature.id, !shown)
        }
    }

    // MARK: Input (HUD)

    func setStick(_ x: Double, _ y: Double) { stick = (x, y) }
    func setLook(_ x: Double, _ y: Double) { look = (x, y) }
    func jump() { jumpRequested = true }

    func attack(_ kind: SpatialCombat.Attack) {
        guard mode == .play, health > 0 else { return }
        let cost = kind == .strike ? 8 : 25
        guard stamina >= cost else { notice = L10n.t("耐力不足", "Not enough stamina"); return }
        if kind == .strike { guard localCooldowns.strike <= 0 else { return }; localCooldowns.strike = 0.35 } else { guard localCooldowns.skill <= 0 else { return }; localCooldowns.skill = 3 }
        // Always visible, hit or miss: a swing burst in front, or a ring around.
        let radians = world.player.facing * .pi / 180
        if kind == .strike {
            effects.burst(.spark, at: world.player.position + SpatialVector(cos(radians) * 0.9, sin(radians) * 0.9, 0.9), seconds: 0.2, clock: world.clock, quality: quality)
            renderer.punch(lunge: true)
        } else {
            effects.burst(.magic, at: world.player.position + SpatialVector(0, 0, 0.4), seconds: 0.5, clock: world.clock, quality: quality)
            renderer.telegraph(id: "player-skill", at: world.player.position, radius: 3.5, seconds: 0.35)
            renderer.punch(lunge: false)
        }
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
        effects.burst(.smoke, at: world.player.position + SpatialVector(0, 0, 0.3), seconds: 0.3, clock: world.clock, quality: quality)
        renderer.punch(lunge: true)
        let radians = world.player.facing * .pi / 180
        let geometry = staticGeometry.moved(frames: world.groupFrames(pivots: pivots, clock: world.clock))
        for _ in 0..<10 {
            let next = SpatialVector(world.player.position.x + cos(radians) * 0.22, world.player.position.y + sin(radians) * 0.22, world.player.position.z)
            if geometry.blocked(x: next.x, y: next.y, z: next.z) { break }
            world.player.position = next
        }
    }

    /// Back at the spawn with full health. Burns end, enemy skills in the
    /// air are dropped, nearby enemies forget the chase, and 3 seconds of
    /// protection stop an instant second death (the old revive only reset
    /// health, so a burn or a waiting enemy could kill again at once).
    func revive() {
        world.player.position = world.spawn; world.player.lastSafe = world.spawn; world.player.verticalSpeed = 0
        world.player.grounded = false
        health = 100; stamina = 100; staminaBuffer = 0
        invulnerable = 3
        battle.playerRevived()
        lockedTarget = nil
        for creature in world.creatures where (creature.position - world.spawn).flatLength < 16 { brains[creature.id] = nil }
        for index in world.creatures.indices where world.creatures[index].alive && (world.creatures[index].position - world.spawn).flatLength < 8 {
            world.creatures[index].position = world.creatures[index].home
        }
        session.applySpatialVitals(health: health, stamina: stamina)
        if mode != .play { mode = .play }
        camera.target = world.player.position
        if thirdPerson { cameraBehindPlayer() }
        renderer.punch(lunge: false)
        effects.burst(.heal, at: world.spawn + SpatialVector(0, 0, 0.6), seconds: 0.8, clock: world.clock, quality: quality)
        notice = L10n.t("已复苏 · 3 秒内不受伤害", "Revived · 3 s of protection")
    }

    // MARK: Camera

    var aspect: Double {
        guard viewSize.height > 0 else { return 2.1 }
        return Double(viewSize.width / viewSize.height)
    }
    func clampCamera() {
        camera.tilt = SpatialCameraRules.clampTilt(camera.tilt)
        // Full 3D uses real render cost, not the 2D 300-cell budget (spec 19.1).
        camera.distance = min(80, max(SpatialCameraRules.minDistance, camera.distance.isFinite ? camera.distance : 8))
        camera.target = SpatialVector(min(255.5, max(0.5, camera.target.x)), min(255.5, max(0.5, camera.target.y)), camera.target.z)
    }
    func zoom(by factor: Double) { glide = nil; camera.distance /= max(0.2, factor); preferredDistance = camera.distance; clampCamera() }
    func turn(by degrees: Double) { glide = nil; camera.yaw = (camera.yaw + degrees).truncatingRemainder(dividingBy: 360); manualCameraUntil = world.clock + 1.5; clampCamera() }
    func tilt(by degrees: Double) { glide = nil; camera.tilt += degrees; manualCameraUntil = world.clock + 1.5; clampCamera() }
    /// Free camera (design): fly up and down, look at the selection, look
    /// straight down, come back to the character.
    func fly(_ dz: Double) { glide = nil; camera.target = camera.target + SpatialVector(0, 0, dz); clampCamera() }
    func focusSelection() { glide = nil;
        let blocks = selectedBlocks
        guard !blocks.isEmpty else { return }
        let n = Double(blocks.count)
        camera.target = SpatialVector(blocks.map { Double($0.x) + 0.5 }.reduce(0, +) / n, blocks.map { Double($0.y) + 0.5 }.reduce(0, +) / n, blocks.map(\.elevation).reduce(0, +) / n)
        camera.distance = 10; clampCamera()
    }
    func lookStraightDown() { glide = nil; camera.tilt = 0; clampCamera() }
    // MARK: Game controller

    private func pollGamepad(dt: Double) {
        guard let pad = gamepad.sample() else {
            if padMoving { setStick(0, 0); padMoving = false }
            if padLooking { setLook(0, 0); padLooking = false }
            return
        }
        let previous = gamepad.previous
        gamepad.remember(pad)
        let playing = mode == .play
        for action in SpatialGamepad.actions(pad, previous: previous, playing: playing) { perform(action) }
        let move = SpatialGamepad.move(pad), look = SpatialGamepad.look(pad)
        let moving = move.x != 0 || move.y != 0, looking = look.x != 0 || look.y != 0
        if playing {
            // Only write while the pad is in use, so touch sticks keep working.
            if moving || padMoving { setStick(move.x, move.y) }
            if looking || padLooking { setLook(look.x, look.y) }
        } else {
            if moving { pan(screenDX: -move.x * 400 * dt, screenDY: -move.y * 400 * dt) }
            if looking { turn(by: look.x * 120 * dt); tilt(by: -look.y * 60 * dt) }
            let factor = SpatialGamepad.zoomFactor(pad, dt: dt)
            if factor != 1 { zoom(by: factor) }
        }
        padMoving = playing && moving; padLooking = playing && looking
    }

    private func perform(_ action: SpatialPadAction) {
        switch action {
        case .jump: if health == 0 { revive() } else { jump() }
        case .attack: attack(.strike)
        case .skill: attack(.skill)
        case .dodge: roll()
        case .lock: toggleLock()
        case .cameraBehind: cameraBehindPlayer()
        case .hotbar(let slot): if hotbar.indices.contains(slot) { castHotbar(slot) }
        case .switchMode: mode = mode == .play ? .edit : .play
        case .flyUp: fly(2)
        case .flyDown: fly(-2)
        case .backToCharacter: backToCharacter()
        case .straightDown: lookStraightDown()
        }
    }

    /// Glides to an angled close-up behind the character and pulses it,
    /// so the tap always shows a change even when it was already centred.
    func backToCharacter() {
        let p = world.player.position
        glide = SpatialCameraState(target: SpatialVector(p.x, p.y, p.z), tilt: 40,
                                   yaw: ThirdPersonCamera.yawBehind(facing: world.player.facing), distance: 9)
        renderer.punch(lunge: false)
        effects.burst(.magic, at: p + SpatialVector(0, 0, 0.4), seconds: 0.5, clock: world.clock, quality: quality)
    }
    /// Opening view for design mode: an angled look over the character's
    /// surroundings instead of straight down.
    func designOverview() {
        let p = world.player.position
        camera.target = SpatialVector(p.x, p.y, p.z)
        camera.tilt = 38; camera.distance = 18
        camera.yaw = ThirdPersonCamera.yawBehind(facing: world.player.facing)
        clampCamera()
    }
    /// Camera move in progress (design-mode buttons).
    private var glide: SpatialCameraState?
    private func stepGlide(dt: Double) {
        guard let goal = glide else { return }
        let k = min(1, dt * 7)
        camera.target = SpatialVector.lerp(camera.target, goal.target, k)
        camera.tilt += (goal.tilt - camera.tilt) * k
        camera.distance += (goal.distance - camera.distance) * k
        camera.yaw = ThirdPersonCamera.approach(camera.yaw, goal.yaw, rate: 360, dt: dt)
        clampCamera()
        let close = (camera.target - goal.target).flatLength < 0.02 && abs(camera.tilt - goal.tilt) < 0.2 && abs(camera.distance - goal.distance) < 0.05 && abs((camera.yaw - goal.yaw).remainder(dividingBy: 360)) < 0.5
        if close { glide = nil }
    }
    func pan(screenDX: Double, screenDY: Double) { glide = nil;
        let scale = camera.distance / 400
        let direction = SpatialCameraRules.worldDirection(stickX: -screenDX, stickY: -screenDY, yaw: camera.yaw)
        camera.target = camera.target + SpatialVector(direction.dx * scale, direction.dy * scale, 0)
        clampCamera()
    }
    func resetCamera() { glide = nil;
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
        renderer.showGround(chunks: chunks, holes: Set(world.groundHoles ?? []))
        let all = allBlocks
        let visible = all.filter { chunks.contains(($0.y / 32) * 8 + $0.x / 32) }
        renderer.showBlocks(visible, pivots: pivots)
        visibleBlockCache = visible
        renderer.showPlants(world.plants, chunks: chunks)
        renderer.showCreatures(world.creatures, near: center, radius: reach + 8)
        renderer.showPickups(world.pickups, near: center, radius: reach + 8)
        let bindings = Dictionary(session.world.mediaBindings.map { ($0.id, $0.mediaID) }, uniquingKeysWith: { first, _ in first })
        visibleMediaIDs = Set(visible.compactMap { block in block.media.flatMap { bindings[$0.bindingID] } })
        // Media characters play too.
        for template in world.characters ?? [] { for clip in template.clips.values { for id in clip.bindingIDs { if let media = bindings[id] { visibleMediaIDs.insert(media) } } } }
        let average = frameTimes.isEmpty ? 0 : frameTimes.reduce(0, +) / Double(frameTimes.count)
        stats = (SpatialCameraRules.visibleCells(camera, aspect: aspect), renderer.blockNodeCount, renderer.creatureNodeCount, activeAI, renderer.media.decoderCount, average > 0 ? 1 / average : 0)
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
        staticGeometry.groundHoles = Set(world.groundHoles ?? [])
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
        world = next; revision += 1
        notice = L10n.t("已提交：", "Committed: ") + title
        rebuildAll(); renderer.showSelection(selectedBlocks)
    }
    func undo() {
        var next = world
        guard let title = next.undoLast(), session.commitSpatial(next) else { return }
        world = next; revision += 1; notice = L10n.t("已撤销：", "Undone: ") + title; selection = []; rebuildAll()
    }
    func redo() {
        var next = world
        guard let title = next.redoLast(), session.commitSpatial(next) else { return }
        world = next; revision += 1; notice = L10n.t("已重做：", "Redone: ") + title; selection = []; rebuildAll()
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

    /// The camera as maths (shared by RealityKit, picking and native glass).
    var projection: SpatialProjection {
        SpatialProjection(eye: SpatialCameraRules.position(camera), target: camera.target, fieldOfView: SpatialCameraRules.fieldOfView, viewSize: viewSize, yaw: camera.yaw)
    }

    /// What is under a screen point, nearest first (ray through the world).
    func pick(_ point: CGPoint) -> [(kind: String, id: String, cell: SurfacePoint, height: Double)] {
        guard viewSize.width > 0 else { return [] }
        let ray = projection.ray(through: point)
        let frames = world.groupFrames(pivots: pivots, clock: world.clock)
        let hits = SpatialPicking.pick(origin: ray.origin, direction: ray.direction, blocks: visibleBlockCache, frames: frames,
                                       creatures: world.creatures, pickups: world.pickups)
        return hits.map { hit in
            let id = hit.kind == .block && hit.id.hasPrefix("legacy:") ? hit.id : hit.id
            return (hit.kind.rawValue, id, hit.cell, hit.point.z)
        }
    }

    // MARK: Native glass

    private func applyQuality() {
        renderer.setQuality(quality, nativeGlass: nativeGlassActive)
    }
    /// On when the system has Liquid Glass, the setting is on and the
    /// quality level gives it a budget.
    /// Short HUD text: face count when on, otherwise why it is off.
    var nativeGlassStatus: String {
        if !Self.nativeGlassAvailable { return L10n.t("原生玻璃需 iOS 26", "Native glass needs iOS 26") }
        if !nativeGlassEnabled { return L10n.t("原生玻璃已关闭", "Native glass off") }
        if SpatialFaces.budget(quality) == 0 { return L10n.t("性能优先：无原生玻璃", "Performance: no native glass") }
        return L10n.t("原生玻璃面 \(nativeGlass.faces)", "\(nativeGlass.faces) native glass faces")
    }
    var nativeGlassActive: Bool { Self.nativeGlassAvailable && nativeGlassEnabled && SpatialFaces.budget(quality) > 0 }

    private func updateNativeGlass(frames: [String: GroupFrame], drawFaces: Bool) {
        let projection = self.projection
        // Reticle and gizmo (also without native block glass).
        let reticle = lockedTarget.flatMap { id in world.creatures.first { $0.id == id } }.flatMap { projection.project($0.position + SpatialVector(0, 0, 1))?.point }
        if reticle != nativeGlass.reticle { nativeGlass.reticle = reticle }
        var gizmo: Glass3DNativeGlass.Gizmo?
        let blocks = selectedBlocks
        if mode == .edit, !blocks.isEmpty {
            let n = Double(blocks.count)
            let center = SpatialVector(blocks.map { Double($0.x) + 0.5 }.reduce(0, +) / n, blocks.map { Double($0.y) + 0.5 }.reduce(0, +) / n, blocks.map(\.top).max() ?? 0)
            if let c = projection.project(center)?.point {
                let axes = [SpatialVector(1, 0, 0), SpatialVector(0, 1, 0), SpatialVector(0, 0, 0.25)].map { axis -> CGPoint in
                    guard let p = projection.project(center + axis)?.point else { return .zero }
                    return CGPoint(x: p.x - c.x, y: p.y - c.y)
                }
                gizmo = Glass3DNativeGlass.Gizmo(center: c, axes: axes)
            }
        }
        if gizmo != nativeGlass.gizmo { nativeGlass.gizmo = gizmo }
        guard nativeGlassActive else { nativeGlass.update(projection: projection, blocks: [], frames: [:], characters: [], budget: 0); return }
        guard drawFaces else { return }
        var characters = [Glass3DNativeGlass.Character(position: world.player.position, radius: 0.35, height: 1.5)]
        for creature in world.creatures where creature.alive && (creature.position - camera.target).flatLength < camera.distance * 3 + 10 {
            let big = creature.kind == .boss ? 1.1 : creature.kind == .miniBoss ? 0.7 : 0.4
            characters.append(.init(position: creature.position, radius: big, height: creature.kind == .boss ? 2.8 : 1.4))
        }
        nativeGlass.update(projection: projection, blocks: visibleBlockCache, frames: frames, characters: characters, budget: SpatialFaces.budget(quality))
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
            let look = creatureLook.flatMap { id in (world.characters ?? []).contains { $0.id == id } ? id : nil }
            edit(L10n.t("放置", "Place ") + kind.title) { w in
                var creature = CreatureEntity(id: "c:" + UUID().uuidString, kind: kind, position: position, home: position, health: base.0, maxHealth: base.0, damage: base.1)
                creature.characterID = look
                w.creatures.append(creature)
            }
        case .player:
            // Moves the player here; it is also where revive returns.
            let spot = SpatialVector(Double(first.cell.x) + 0.5, Double(first.cell.z) + 0.5, first.kind == "block" ? first.height : 0)
            edit(L10n.t("主角位置", "Player Position")) { w in w.spawn = spot; w.player.position = spot; w.player.lastSafe = spot; w.player.verticalSpeed = 0 }
            notice = L10n.t("主角已放到这里，复活也会回到这里", "Player moved here; revive returns here too")
        case .maze:
            proposeMaze(at: first.cell)
        case .track:
            trackPoints.append(SpatialVector(Double(first.cell.x) + 0.5, Double(first.cell.z) + 0.5, buildHeight))
            notice = L10n.t("已添加路径点 \(trackPoints.count)", "Waypoint \(trackPoints.count) added")
        case .media:
            if first.kind == "block", !first.id.hasPrefix("legacy:") { if selection.contains(first.id) { selection.removeAll { $0 == first.id } } else { selection.append(first.id) } }
        case .dig:
            // Toggle a hole in the glass ground: the way to underground space.
            let key = first.cell.z * 256 + first.cell.x
            edit((world.groundHoles ?? []).contains(key) ? L10n.t("填回地面", "Fill Ground") : L10n.t("挖开地面", "Dig Ground")) { w in
                var holes = w.groundHoles ?? []
                if let i = holes.firstIndex(of: key) { holes.remove(at: i) } else { holes.append(key) }
                w.groundHoles = holes.isEmpty ? nil : holes
            }
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
        // Area with layers fills a volume (layers × thickness high).
        let layers = tool == .area ? max(1, buildLayers) : 1
        let blocks = Array(drawCells.prefix(RPGWorldEditing.maximumBatch / layers).flatMap { cell in
            (0..<layers).map { layer in newBlock(at: cell, elevation: stackHeight(at: cell) + Double(layer) * buildThickness) }
        })
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
    /// Mirror a building left-right around its middle.
    func mirrorGroup() {
        guard let group = selectedGroup else { return }
        edit(L10n.t("镜像建筑", "Mirror Building")) { w in
            let members = w.blocks.filter { $0.groupID == group.id }
            guard let minX = members.map(\.x).min(), let maxX = members.map(\.x).max() else { return }
            for i in w.blocks.indices where w.blocks[i].groupID == group.id { w.blocks[i].x = minX + maxX - w.blocks[i].x; w.blocks[i].yaw = -w.blocks[i].yaw; w.blocks[i].origin = .user }
        }
    }
    /// Array copy: `count` copies, each `step` cells further east.
    func arrayGroup(count: Int, step: Int) {
        guard let group = selectedGroup else { return }
        edit(L10n.t("阵列复制 ×\(count)", "Array Copy ×\(count)")) { w in
            for n in 1...max(1, min(16, count)) {
                let new = "g:" + UUID().uuidString
                SpatialBuilder.copy(group: group.id, dx: step * n, dy: 0, dz: 0, newGroup: new, idPrefix: new, world: &w)
            }
        }
    }
    /// Scale a building's blocks (size and thickness) by a factor.
    func scaleGroup(_ factor: Double) {
        guard let group = selectedGroup else { return }
        edit(L10n.t("缩放建筑", "Scale Building")) { w in
            let members = w.blocks.filter { $0.groupID == group.id }
            let base = members.map(\.elevation).min() ?? 0
            for i in w.blocks.indices where w.blocks[i].groupID == group.id {
                var b = w.blocks[i]
                b.size = min(1, max(0.2, b.size * factor)); b.thickness = min(16, max(0.05, b.thickness * factor))
                b.elevation = base + (b.elevation - base) * factor; b.origin = .user
                if b.valid { w.blocks[i] = b }
            }
        }
    }
    /// Move the selection along one axis (gizmo and arrows): x and y in
    /// cells, height in quarter cells.
    func moveSelection(axis: Int, steps: Int) {
        guard steps != 0, !selection.isEmpty else { return }
        let ids = Set(selection)
        edit(L10n.t("移动", "Move")) { w in
            for i in w.blocks.indices where ids.contains(w.blocks[i].id) {
                var b = w.blocks[i]
                switch axis { case 0: b.x += steps; case 1: b.y += steps; default: b.elevation += Double(steps) * 0.25 }
                b.origin = .user
                if b.valid { w.blocks[i] = b }
            }
        }
    }

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
    /// Library media this world shows, newest first (reuse row in the picker).
    var worldMediaIDs: [String] {
        var seen = Set<String>()
        return session.world.mediaBindings.reversed().compactMap { seen.insert($0.mediaID).inserted ? $0.mediaID : nil }
    }
    /// Library media behind a saved binding (previews in the editors).
    func mediaID(forBinding id: String) -> String? { session.world.mediaBindings.first { $0.id == id }?.mediaID }
    func clearMedia() { updateSelected(L10n.t("移除媒体", "Remove Media")) { $0.media = nil } }

    // MARK: Characters, skills and Boss scripts (v1.60 editors)

    func saveCharacter(_ template: CharacterTemplate, bindings: [MediaBinding]) {
        edit(L10n.t("保存角色 ", "Save Character ") + template.name, bindings: bindings) { w in
            var list = w.characters ?? []
            if let i = list.firstIndex(where: { $0.id == template.id }) { list[i] = template } else { list.append(template) }
            w.characters = list
        }
    }
    func deleteCharacter(_ id: String) {
        edit(L10n.t("删除角色", "Delete Character")) { w in
            w.characters?.removeAll { $0.id == id }
            if w.playerCharacterID == id { w.playerCharacterID = nil }
            for i in w.creatures.indices where w.creatures[i].characterID == id { w.creatures[i].characterID = nil }
            for s in (w.bossScripts ?? []).indices { for p in w.bossScripts![s].phases.indices where w.bossScripts![s].phases[p].appearanceID == id { w.bossScripts![s].phases[p].appearanceID = nil } }
        }
    }
    func setPlayerCharacter(_ id: String?) { edit(L10n.t("主角外观", "Player Look")) { w in w.playerCharacterID = id } }

    /// Clears the world in one undoable step (see `SpatialWorld.cleared`).
    func clearWorld() {
        selection = []; pending = nil; trackPoints = []; lockedTarget = nil
        edit(L10n.t("清空世界", "Clear World")) { w in w = w.cleared() }
        camera.target = world.player.position
        notice = L10n.t("世界已清空，可撤销；角色、技能和生成的模型都还在", "World cleared (undo to restore); characters, skills and generated models are kept")
    }
    /// Gives every creature of a kind this character look.
    func applyCharacter(_ id: String?, to kind: CreatureKind) {
        edit(L10n.t("外观 · ", "Look · ") + kind.title) { w in for i in w.creatures.indices where w.creatures[i].kind == kind { w.creatures[i].characterID = id } }
    }
    /// Copies a USDZ file into the app's models folder; returns its file name.
    func importModel(from url: URL) -> String? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "usdz", let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size < 200_000_000 else {
            notice = L10n.t("只支持 200 MB 以内的 USDZ 模型", "Only USDZ models under 200 MB"); return nil
        }
        let name = UUID().uuidString + ".usdz"
        do { try FileManager.default.copyItem(at: url, to: Glass3DCharacters.modelsFolder.appendingPathComponent(name)); return name }
        catch { notice = error.localizedDescription; return nil }
    }

    var allSkills: [SkillDefinition] { (world.skills ?? []) + SkillLibrary.templates().filter { t in !(world.skills ?? []).contains { $0.id == t.id } } }
    func saveSkill(_ skill: SkillDefinition) {
        guard skill.valid else { notice = L10n.t("技能设置不完整", "The skill is incomplete"); return }
        edit(L10n.t("保存技能 ", "Save Skill ") + skill.name) { w in
            var list = w.skills ?? []
            if let i = list.firstIndex(where: { $0.id == skill.id }) { list[i] = skill } else { list.append(skill) }
            w.skills = list
        }
    }
    func deleteSkill(_ id: String) {
        edit(L10n.t("删除技能", "Delete Skill")) { w in
            w.skills?.removeAll { $0.id == id }
            if let hotbar = w.hotbar { w.hotbar = hotbar.map { $0 == id ? "tpl.fireball" : $0 } }
        }
    }
    func setHotbar(_ slot: Int, skill id: String) {
        edit(L10n.t("技能栏", "Hotbar")) { w in
            var bar = w.hotbar ?? SpatialBattle.defaultHotbar()
            while bar.count < 4 { bar.append("tpl.fireball") }
            if bar.indices.contains(slot) { bar[slot] = id }
            w.hotbar = bar
        }
    }

    func saveBossScript(_ script: BossScript) {
        guard script.valid else { notice = L10n.t("Boss 阶段设置不完整（第一阶段需从满血开始）", "Phases are incomplete (the first starts at full health)"); return }
        edit(L10n.t("保存 Boss ", "Save Boss ") + script.name) { w in
            var list = w.bossScripts ?? []
            if let i = list.firstIndex(where: { $0.id == script.id }) { list[i] = script } else { list.append(script) }
            w.bossScripts = list
        }
    }
    func deleteBossScript(_ id: String) {
        edit(L10n.t("删除 Boss 阶段", "Delete Boss Script")) { w in
            w.bossScripts?.removeAll { $0.id == id }
            for i in w.creatures.indices where w.creatures[i].bossScriptID == id { w.creatures[i].bossScriptID = nil }
        }
    }
    func applyBossScript(_ id: String, to kind: CreatureKind) {
        edit(L10n.t("Boss 阶段 · ", "Boss Script · ") + kind.title) { w in for i in w.creatures.indices where w.creatures[i].kind == kind { w.creatures[i].bossScriptID = id } }
    }

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
