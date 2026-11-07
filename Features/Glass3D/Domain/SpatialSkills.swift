import Foundation

// v1.60: media characters and their animation, the skill timeline with
// projectiles, beams and areas, status effects, Boss phase scripts and the
// third-person / combat camera. Pure and deterministic: the same inputs
// always give the same hits, and nothing here looks at video pixels.

// MARK: Characters

enum CharacterAction: String, Codable, CaseIterable, Sendable {
    case idle, walk, run, jump, fall, attack, skill, dodge, hurt, death, interact, transform
    var title: String {
        switch self {
        case .idle: L10n.t("待机", "Idle"); case .walk: L10n.t("行走", "Walk"); case .run: L10n.t("奔跑", "Run")
        case .jump: L10n.t("跳跃", "Jump"); case .fall: L10n.t("下落", "Fall"); case .attack: L10n.t("攻击", "Attack")
        case .skill: L10n.t("技能", "Skill"); case .dodge: L10n.t("闪避", "Dodge"); case .hurt: L10n.t("受伤", "Hurt")
        case .death: L10n.t("死亡", "Death"); case .interact: L10n.t("交互", "Interact"); case .transform: L10n.t("Boss 变身", "Transform")
        }
    }
    /// Higher priority interrupts lower; death is final.
    var priority: Int {
        switch self {
        case .idle: 0; case .walk, .run: 1; case .jump, .fall: 2; case .interact: 3; case .attack, .skill: 4
        case .dodge: 5; case .hurt: 6; case .transform: 7; case .death: 8
        }
    }
    /// Actions that play once and then hand back to movement.
    var oneShot: Bool { ![.idle, .walk, .run, .fall].contains(self) }
}

enum CharacterDisplayMode: String, Codable, CaseIterable, Sendable {
    /// One picture, GIF or video facing the camera.
    case billboard
    /// Four or eight pictures, one per direction the character faces.
    case directional4, directional8
    /// Several flat layers at different depths, turned with the character.
    case layered
    /// A USDZ 3D model.
    case model
    /// v1.69: a model made by "AI 3D Models" (Generated3D), animated when rigged.
    case generated
    var title: String {
        switch self {
        case .billboard: L10n.t("面向镜头的媒体", "Billboard"); case .directional4: L10n.t("四方向", "4 Directions"); case .directional8: L10n.t("八方向", "8 Directions")
        case .layered: L10n.t("立体分层", "Layered"); case .model: L10n.t("3D 模型 (USDZ)", "3D Model (USDZ)")
        case .generated: L10n.t("AI 生成 3D 模型", "AI 3D Model")
        }
    }
    var directions: Int { switch self { case .directional4: 4; case .directional8: 8; default: 1 } }
}

/// Media for one action: one binding per direction (or per layer).
struct ActionClip: Codable, Equatable, Sendable {
    var bindingIDs: [String] = []
    var speed = 1.0
    var loop = true
    /// Seconds into the clip when the action's effect fires (attack hit,
    /// skill release); purely visual timing, damage comes from skills.
    var eventTime = 0.25
    var length = 0.6
}

struct CharacterTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var mode = CharacterDisplayMode.billboard
    var clips: [String: ActionClip] = [:]
    /// Visual height in cells and width/height ratio.
    var height = 1.6
    var aspect = 0.6
    /// 0 = feet at the bottom edge of the picture, 0.1 = a little above.
    var footAnchor = 0.0
    var opacity = 1.0
    var shadow = true
    var colliderRadius = 0.3
    var colliderHeight = 1.5
    /// Hurt box size relative to the collider.
    var hurtScale = 1.0
    /// Library file of a USDZ model (model mode).
    var modelMediaID: String?
    /// Generated3D model id (generated mode, v1.69).
    var generatedModelID: String?
    var layerDepth = 0.12

    var valid: Bool {
        !id.isEmpty && id.count <= 128 && (1...64).contains(name.count) && height.isFinite && (0.3...20).contains(height) && aspect.isFinite && (0.1...5).contains(aspect) &&
            (0...0.5).contains(footAnchor) && (0.1...1).contains(opacity) && (0.1...5).contains(colliderRadius) && (0.3...20).contains(colliderHeight) &&
            (0.5...3).contains(hurtScale) && clips.count <= CharacterAction.allCases.count && clips.values.allSatisfy { $0.bindingIDs.count <= 8 && $0.speed > 0 && $0.speed <= 8 } &&
            (mode != .generated || generatedModelID?.isEmpty == false)
    }
    func clip(_ action: CharacterAction) -> ActionClip? {
        if let clip = clips[action.rawValue], !clip.bindingIDs.isEmpty { return clip }
        // Fall back: run → walk → idle; others → idle.
        switch action {
        case .run: return clips[CharacterAction.walk.rawValue].flatMap { $0.bindingIDs.isEmpty ? nil : $0 } ?? clips[CharacterAction.idle.rawValue]
        case .idle: return nil
        default: return clips[CharacterAction.idle.rawValue].flatMap { $0.bindingIDs.isEmpty ? nil : $0 }
        }
    }
}

/// What a character shows: the action from its state with priority and
/// interruption rules, and the direction picture from where it faces.
struct CharacterAnimationState: Equatable, Sendable {
    var action = CharacterAction.idle
    var started = 0.0
    /// This action's own length: a one-shot ends after it (v1.88; before,
    /// the length of whichever request came next decided).
    var length = 0.6
    /// A one-shot asked for while the current one could not be cut short,
    /// played as soon as it ends (one input remembered, like a game pad buffer).
    var queued: CharacterAction?
    var queuedLength = 0.6
    var effectFired = false
}

/// What the state machine reports while stepping: the clip's effect moment
/// (attack hit, skill release, at `ActionClip.eventTime`) and the end of a one-shot.
enum AnimationEvent: Equatable, Sendable {
    case effect(CharacterAction)
    case finished(CharacterAction)
}

enum CharacterAnimator {
    /// The action a moving body wants (movement layer).
    static func movement(speed: Double, grounded: Bool, verticalSpeed: Double) -> CharacterAction {
        if !grounded { return verticalSpeed > 0 ? .jump : .fall }
        return speed > 3 ? .run : speed > 0.2 ? .walk : .idle
    }
    /// The action for a creature's AI state.
    static func action(for state: CreatureState, moving: Bool) -> CharacterAction {
        switch state {
        case .dead: .death; case .hurt: .hurt; case .attack: .attack
        case .chase, .returning, .wander, .patrol: moving ? .walk : .idle
        case .idle, .alert: .idle
        }
    }
    /// Share of a one-shot after which the same action may start over (a
    /// combo); before it, pressing again does nothing.
    static let cancelFraction = 0.6

    /// Applies a requested action: higher or equal priority interrupts; a
    /// one-shot keeps playing until its own length is over; the same
    /// one-shot restarts once its cancel window opens; a lower one-shot
    /// asked for meanwhile is remembered and plays next. Death is final.
    static func request(_ state: inout CharacterAnimationState, _ action: CharacterAction, clock: Double, length: Double) {
        if state.action == .death { return }
        let current = state.action
        let elapsed = clock - state.started
        if action == current {
            if current.oneShot && elapsed >= state.length * cancelFraction { start(&state, action, clock: clock, length: length) }
            return
        }
        let finished = !current.oneShot || elapsed >= state.length
        if action.priority >= current.priority || finished { start(&state, action, clock: clock, length: length); return }
        if action.oneShot { state.queued = action; state.queuedLength = length }
    }
    private static func start(_ state: inout CharacterAnimationState, _ action: CharacterAction, clock: Double, length: Double) {
        state.action = action; state.started = clock; state.length = max(0.05, length.isFinite ? length : 0.6); state.effectFired = false
        if state.queued == action { state.queued = nil }
    }
    /// Advances a one-shot: its effect moment once (at `eventTime`, capped
    /// at its length), then its end, then the remembered action or idle
    /// (movement takes over on the next request).
    static func step(_ state: inout CharacterAnimationState, clock: Double, eventTime: Double) -> [AnimationEvent] {
        guard state.action.oneShot, state.action != .death else { return [] }
        var events: [AnimationEvent] = []
        let elapsed = clock - state.started
        if !state.effectFired && elapsed >= min(max(0, eventTime), state.length) { state.effectFired = true; events.append(.effect(state.action)) }
        if elapsed >= state.length {
            events.append(.finished(state.action))
            if let next = state.queued { state.queued = nil; start(&state, next, clock: clock, length: state.queuedLength) }
            else { state.action = .idle; state.started = clock; state.length = 0.6; state.effectFired = false }
        }
        return events
    }
    /// Which direction picture to show (0 = facing the camera, counting
    /// clockwise), from the facing angle and the camera turn.
    static func direction(facing: Double, cameraYaw: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        // The camera looks along yaw + 90°; facing the opposite way means
        // facing the camera (index 0). Indices go clockwise seen from above.
        var relative = (facing - (cameraYaw + 270)).truncatingRemainder(dividingBy: 360); if relative < 0 { relative += 360 }
        let step = 360.0 / Double(count)
        return Int(((360 - relative).truncatingRemainder(dividingBy: 360) / step).rounded()) % count
    }
    /// Frame time within a clip (looping or held on the last frame).
    static func clipTime(_ state: CharacterAnimationState, clip: ActionClip, clock: Double) -> Double {
        let t = max(0, clock - state.started) * clip.speed
        return clip.loop ? t.truncatingRemainder(dividingBy: max(0.05, clip.length)) : min(t, clip.length)
    }
}

// MARK: Particles

enum ParticlePreset: String, Codable, CaseIterable, Sendable {
    case fire, ice, lightning, spark, smoke, magic, charge, explosion, heal
    var title: String {
        switch self {
        case .fire: L10n.t("火焰", "Fire"); case .ice: L10n.t("冰晶", "Ice"); case .lightning: L10n.t("雷电", "Lightning"); case .spark: L10n.t("火花", "Sparks")
        case .smoke: L10n.t("烟雾", "Smoke"); case .magic: L10n.t("魔法粒子", "Magic"); case .charge: L10n.t("能量聚集", "Charge"); case .explosion: L10n.t("爆炸", "Explosion"); case .heal: L10n.t("治疗光效", "Heal")
        }
    }
    var hex: String {
        switch self {
        case .fire: "FF7A1A"; case .ice: "9FE6FF"; case .lightning: "C9B6FF"; case .spark: "FFD54A"; case .smoke: "8A8F99"
        case .magic: "D07CFF"; case .charge: "7CF2FF"; case .explosion: "FF4D2E"; case .heal: "7DFFAE"
        }
    }
}

// MARK: Skills

enum StatusKind: String, Codable, CaseIterable, Sendable {
    case burn, slow, freeze, heal
    var title: String { switch self { case .burn: L10n.t("灼烧", "Burn"); case .slow: L10n.t("减速", "Slow"); case .freeze: L10n.t("冰冻", "Freeze"); case .heal: L10n.t("治疗", "Heal") } }
}
struct StatusSpec: Codable, Equatable, Sendable { var kind: StatusKind; var perSecond = 4.0; var duration = 3.0 }
struct StatusEffect: Codable, Equatable, Sendable { var kind: StatusKind; var perSecond: Double; var remaining: Double }

struct ProjectileSpec: Codable, Equatable, Sendable {
    var speed = 12.0
    var radius = 0.3
    var lifetime = 2.5
    var damage = 15
    /// Degrees per second it turns toward its target (0: straight).
    var homing = 0.0
    /// Extra targets it passes through.
    var pierce = 0
    var gravity = 0.0
    /// Explodes on hit or at the end (0: no explosion).
    var explosionRadius = 0.0
    var explosionDamage = 0
    var count = 1
    /// Fan spread between several projectiles, degrees.
    var spread = 0.0
    var knockback = 0.0
    var particle = ParticlePreset.magic
    var status: StatusSpec?
}

struct BeamSpec: Codable, Equatable, Sendable {
    var length = 9.0
    var width = 0.8
    var duration = 1.2
    var tickDamage = 6
    var interval = 0.2
    var particle = ParticlePreset.lightning
}

enum AreaShape: String, Codable, CaseIterable, Sendable {
    case sphere, cone, ring
    var title: String { switch self { case .sphere: L10n.t("球形范围", "Sphere"); case .cone: L10n.t("扇形", "Cone"); case .ring: L10n.t("冲击波", "Shockwave") } }
}
struct AreaSpec: Codable, Equatable, Sendable {
    var shape = AreaShape.sphere
    var radius = 3.0
    /// Cone half-angle, degrees.
    var angle = 45.0
    /// Distance in front of the caster where it lands.
    var forward = 0.0
    var damage = 20
    /// Telegraph seconds before it hits (shown as a warning).
    var delay = 0.0
    var knockback = 0.0
    /// Stays and damages every `interval` for `duration` (0: hits once).
    var duration = 0.0
    var interval = 0.5
    var particle = ParticlePreset.explosion
    var status: StatusSpec?
}

enum SkillEventKind: Codable, Equatable, Sendable {
    case action(CharacterAction)
    case particles(ParticlePreset, seconds: Double)
    case projectile(ProjectileSpec)
    case beam(BeamSpec)
    case area(AreaSpec)
    case dash(distance: Double)
    case shake(Double)
    var title: String {
        switch self {
        case .action(let a): L10n.t("动作 · ", "Action · ") + a.title
        case .particles(let p, _): L10n.t("粒子 · ", "Particles · ") + p.title
        case .projectile(let p): (p.homing > 0 ? L10n.t("追踪弹", "Homing shot") : L10n.t("飞行弹", "Projectile")) + (p.count > 1 ? " ×\(p.count)" : "")
        case .beam: L10n.t("光束", "Beam")
        case .area(let a): a.shape.title + (a.delay > 0 ? L10n.t("（预警）", " (telegraphed)") : "")
        case .dash: L10n.t("冲刺", "Dash")
        case .shake: L10n.t("镜头震动", "Camera Shake")
        }
    }
}

struct SkillEvent: Codable, Equatable, Sendable {
    var time: Double
    var kind: SkillEventKind
}

struct SkillDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var cooldown = 3.0
    var staminaCost = 20
    var symbol = "sparkles"
    var events: [SkillEvent] = []
    static let maximumEvents = 48
    var valid: Bool {
        !id.isEmpty && id.count <= 128 && (1...64).contains(name.count) && cooldown.isFinite && (0...120).contains(cooldown) && (0...100).contains(staminaCost) &&
            events.count <= Self.maximumEvents && events.allSatisfy { $0.time.isFinite && (0...10).contains($0.time) }
    }
    /// Seconds until the last event has done its work.
    var length: Double { events.map { event -> Double in
        switch event.kind {
        case .projectile(let p): event.time + p.lifetime
        case .beam(let b): event.time + b.duration
        case .area(let a): event.time + a.delay + a.duration
        case .particles(_, let seconds): event.time + seconds
        default: event.time
        }
    }.max() ?? 0 }
}

enum Faction: String, Codable, Sendable { case player, enemy }

/// Something that can be hit.
struct SkillTarget: Equatable, Sendable {
    var id: String
    var position: SpatialVector
    var radius: Double
    var height: Double
    var faction: Faction
    var invulnerable = false
}

struct SkillHit: Equatable, Sendable {
    var targetID: String
    var damage: Int
    var knockback: SpatialVector
    var status: StatusSpec?
}

/// A visual thing to show this frame (positions for the renderer).
enum SkillVisual: Equatable, Sendable {
    case particles(ParticlePreset, at: SpatialVector, seconds: Double)
    case projectile(id: Int, at: SpatialVector, preset: ParticlePreset, radius: Double)
    case beam(from: SpatialVector, to: SpatialVector, width: Double, preset: ParticlePreset)
    case telegraph(center: SpatialVector, radius: Double, seconds: Double)
    case action(CharacterAction)
    case shake(Double)
    case dash(SpatialVector)
}

/// One cast of a skill, stepped by the world clock. Deterministic: events
/// fire in time order, each hitbox hits a target once (areas and beams
/// tick on their interval), factions filter friends, walls block.
struct SkillCast: Sendable {
    static let projectileLimit = 64
    static let lifetimeLimit = 15.0

    struct Projectile: Sendable { var id: Int; var spec: ProjectileSpec; var position: SpatialVector; var velocity: SpatialVector; var age = 0.0; var hits: Set<String> = []; var alive = true }
    struct Beam: Sendable { var spec: BeamSpec; var age = 0.0; var lastTick = -1.0 }
    struct Area: Sendable { var spec: AreaSpec; var center: SpatialVector; var facing: Double; var age = 0.0; var lastTick = -1.0; var landed = false }

    let skill: SkillDefinition
    let faction: Faction
    var origin: SpatialVector
    var facing: Double
    var target: String?
    private(set) var time = 0.0
    private var nextEvent = 0
    private(set) var projectiles: [Projectile] = []
    private var beams: [Beam] = []
    private var areas: [Area] = []
    private var serial = 0

    init(skill: SkillDefinition, faction: Faction, origin: SpatialVector, facing: Double, target: String? = nil) {
        self.skill = skill; self.faction = faction; self.origin = origin; self.facing = facing; self.target = target
        var sorted = skill
        sorted.events = skill.events.sorted { $0.time < $1.time }
        self.skillSorted = sorted.events
    }
    private let skillSorted: [SkillEvent]

    var finished: Bool { time >= min(Self.lifetimeLimit, skill.length + 0.05) && projectiles.allSatisfy { !$0.alive } }

    private var forward: SpatialVector { SpatialVector(cos(facing * .pi / 180), sin(facing * .pi / 180), 0) }

    /// Advances by `dt`. `origin` and `facing` follow the caster (beams
    /// and areas are anchored to it); targets are everyone in the world.
    mutating func step(_ dt: Double, targets: [SkillTarget], geometry: SpatialGeometry?) -> (hits: [SkillHit], visuals: [SkillVisual]) {
        guard dt > 0, time < Self.lifetimeLimit else { return ([], []) }
        time += dt
        var hits: [SkillHit] = [], visuals: [SkillVisual] = []
        let enemies = targets.filter { $0.faction != faction && !$0.invulnerable }
        // Fire the events that are due.
        while nextEvent < skillSorted.count && skillSorted[nextEvent].time <= time {
            let event = skillSorted[nextEvent]; nextEvent += 1
            switch event.kind {
            case .action(let action): visuals.append(.action(action))
            case .particles(let preset, let seconds): visuals.append(.particles(preset, at: origin + SpatialVector(0, 0, 1) + forward * 0.6, seconds: seconds))
            case .shake(let amount): visuals.append(.shake(amount))
            case .dash(let distance): visuals.append(.dash(forward * distance))
            case .projectile(let spec):
                let count = max(1, min(12, spec.count))
                for index in 0..<count where projectiles.count < Self.projectileLimit {
                    let offset = count == 1 ? 0 : (Double(index) - Double(count - 1) / 2) * spec.spread
                    let angle = (facing + offset) * .pi / 180
                    serial += 1
                    projectiles.append(Projectile(id: serial, spec: spec, position: origin + SpatialVector(0, 0, 1) + SpatialVector(cos(angle), sin(angle), 0) * 0.5,
                                                  velocity: SpatialVector(cos(angle), sin(angle), 0) * spec.speed))
                }
            case .beam(let spec): beams.append(Beam(spec: spec))
            case .area(let spec):
                let center = origin + forward * spec.forward
                areas.append(Area(spec: spec, center: center, facing: facing))
                if spec.delay > 0 { visuals.append(.telegraph(center: center, radius: spec.radius, seconds: spec.delay)) }
            }
        }
        // Projectiles: move, home, collide.
        for i in projectiles.indices where projectiles[i].alive {
            var p = projectiles[i]
            p.age += dt
            if p.spec.homing > 0, let goal = (target.flatMap { id in enemies.first { $0.id == id } } ?? enemies.min { ($0.position - p.position).flatLength < ($1.position - p.position).flatLength }) {
                let want = atan2(goal.position.y - p.position.y, goal.position.x - p.position.x)
                let have = atan2(p.velocity.y, p.velocity.x)
                var turn = want - have
                while turn > .pi { turn -= 2 * .pi }; while turn < -.pi { turn += 2 * .pi }
                let limit = p.spec.homing * .pi / 180 * dt
                let angle = have + max(-limit, min(limit, turn)), speed = p.velocity.flatLength
                p.velocity = SpatialVector(cos(angle) * speed, sin(angle) * speed, p.velocity.z)
            }
            p.velocity.z -= p.spec.gravity * dt
            let next = p.position + p.velocity * dt
            var ended = p.age >= p.spec.lifetime || next.z < -1
            if let geometry, SpatialCombat.occluded(p.position - SpatialVector(0, 0, 0.8), next - SpatialVector(0, 0, 0.8), geometry: geometry) { ended = true }
            p.position = next
            if !ended {
                for target in enemies where !p.hits.contains(target.id) && Self.touches(point: p.position, radius: p.spec.radius, target: target) {
                    p.hits.insert(target.id)
                    let push = Self.normalized(SpatialVector(p.velocity.x, p.velocity.y, 0)) * p.spec.knockback
                    hits.append(SkillHit(targetID: target.id, damage: p.spec.damage, knockback: push, status: p.spec.status))
                    if p.hits.count > p.spec.pierce { ended = true; break }
                }
            }
            if ended {
                p.alive = false
                if p.spec.explosionRadius > 0 {
                    visuals.append(.particles(.explosion, at: p.position, seconds: 0.6))
                    for target in enemies where Self.within(sphere: p.position, radius: p.spec.explosionRadius, target: target) {
                        let push = Self.normalized(target.position - p.position) * p.spec.knockback
                        hits.append(SkillHit(targetID: target.id, damage: p.spec.explosionDamage, knockback: push, status: p.spec.status))
                    }
                }
            } else { visuals.append(.projectile(id: p.id, at: p.position, preset: p.spec.particle, radius: p.spec.radius)) }
            projectiles[i] = p
        }
        // Beams: a line from the caster, ticking damage.
        for i in beams.indices {
            beams[i].age += dt
            let spec = beams[i].spec
            guard beams[i].age <= spec.duration else { continue }
            let start = origin + SpatialVector(0, 0, 1), end = start + forward * spec.length
            visuals.append(.beam(from: start, to: end, width: spec.width, preset: spec.particle))
            if beams[i].age - beams[i].lastTick >= spec.interval || beams[i].lastTick < 0 {
                beams[i].lastTick = beams[i].age
                for target in enemies where Self.distanceToSegment(target.position + SpatialVector(0, 0, target.height / 2), start, end) <= spec.width / 2 + target.radius {
                    if let geometry, SpatialCombat.occluded(start - SpatialVector(0, 0, 0.8), target.position, geometry: geometry) { continue }
                    hits.append(SkillHit(targetID: target.id, damage: spec.tickDamage, knockback: .zero, status: nil))
                }
            }
        }
        // Areas: land after the warning, then hit once or tick.
        for i in areas.indices {
            areas[i].age += dt
            let area = areas[i], spec = area.spec
            guard area.age >= spec.delay else { continue }
            let active = area.age - spec.delay
            let due = !area.landed || (spec.duration > 0 && active <= spec.duration && active - area.lastTick >= spec.interval)
            guard due, active <= max(spec.duration, 0) + dt else { continue }
            if !area.landed { visuals.append(.particles(spec.particle, at: area.center, seconds: max(0.5, spec.duration))) }
            areas[i].landed = true; areas[i].lastTick = active
            for target in enemies where Self.inArea(spec, center: area.center, facing: area.facing, target: target) {
                if let geometry, SpatialCombat.occluded(area.center, target.position, geometry: geometry), spec.shape != .ring { continue }
                let push = Self.normalized(SpatialVector(target.position.x - area.center.x, target.position.y - area.center.y, 0)) * spec.knockback
                hits.append(SkillHit(targetID: target.id, damage: spec.damage, knockback: push, status: spec.status))
            }
        }
        return (hits, visuals)
    }

    static func touches(point: SpatialVector, radius: Double, target: SkillTarget) -> Bool {
        let flat = SpatialVector(point.x - target.position.x, point.y - target.position.y, 0).flatLength
        return flat <= radius + target.radius && point.z >= target.position.z - radius && point.z <= target.position.z + target.height + radius
    }
    static func within(sphere center: SpatialVector, radius: Double, target: SkillTarget) -> Bool {
        let middle = target.position + SpatialVector(0, 0, target.height / 2)
        let d = middle - center
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() <= radius + target.radius
    }
    static func inArea(_ spec: AreaSpec, center: SpatialVector, facing: Double, target: SkillTarget) -> Bool {
        let offset = target.position - center
        guard abs(offset.z) <= max(1.5, spec.radius * 0.6) else { return false }
        let distance = offset.flatLength
        switch spec.shape {
        case .sphere: return distance <= spec.radius + target.radius
        case .ring: return distance <= spec.radius + target.radius && distance >= spec.radius * 0.5 - target.radius
        case .cone:
            guard distance <= spec.radius + target.radius else { return false }
            if distance < 0.3 { return true }
            var difference = abs(atan2(offset.y, offset.x) * 180 / .pi - facing).truncatingRemainder(dividingBy: 360)
            if difference > 180 { difference = 360 - difference }
            return difference <= spec.angle
        }
    }
    static func distanceToSegment(_ p: SpatialVector, _ a: SpatialVector, _ b: SpatialVector) -> Double {
        let ab = b - a, ap = p - a
        let length = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z
        let t = length > 0 ? max(0, min(1, (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / length)) : 0
        let closest = a + ab * t, d = p - closest
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }
    static func normalized(_ v: SpatialVector) -> SpatialVector {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return length > 1e-9 ? v * (1 / length) : .zero
    }
}

/// Status effects on a body: burn damages, heal restores, slow and freeze
/// change speed. Returns the health change for this step.
enum StatusRules {
    static func step(_ effects: inout [StatusEffect], dt: Double) -> (health: Double, speed: Double) {
        var health = 0.0, speed = 1.0
        for i in effects.indices {
            let used = min(dt, effects[i].remaining)
            effects[i].remaining -= dt
            switch effects[i].kind {
            case .burn: health -= effects[i].perSecond * used
            case .heal: health += effects[i].perSecond * used
            case .slow: speed = min(speed, 0.5)
            case .freeze: speed = 0
            }
        }
        effects.removeAll { $0.remaining <= 0 }
        return (health, speed)
    }
    /// The same kind refreshes instead of stacking without limit.
    static func apply(_ spec: StatusSpec, to effects: inout [StatusEffect]) {
        if let i = effects.firstIndex(where: { $0.kind == spec.kind }) { effects[i].remaining = max(effects[i].remaining, spec.duration); effects[i].perSecond = max(effects[i].perSecond, spec.perSecond) }
        else if effects.count < 6 { effects.append(StatusEffect(kind: spec.kind, perSecond: spec.perSecond, remaining: spec.duration)) }
    }
}

/// Ready-made skills (editable copies are made when chosen).
enum SkillLibrary {
    static func templates() -> [SkillDefinition] {
        [
            SkillDefinition(id: "tpl.fireball", name: L10n.t("火球术", "Fireball"), cooldown: 2.5, staminaCost: 18, symbol: "flame", events: [
                SkillEvent(time: 0, kind: .action(.skill)), SkillEvent(time: 0, kind: .particles(.charge, seconds: 0.3)),
                SkillEvent(time: 0.3, kind: .projectile(ProjectileSpec(speed: 13, radius: 0.35, lifetime: 2, damage: 14, explosionRadius: 2, explosionDamage: 12, knockback: 2, particle: .fire, status: StatusSpec(kind: .burn, perSecond: 4, duration: 2)))),
            ]),
            SkillDefinition(id: "tpl.homing", name: L10n.t("追踪光球", "Homing Orbs"), cooldown: 4, staminaCost: 22, symbol: "circle.hexagongrid", events: [
                SkillEvent(time: 0, kind: .action(.skill)),
                SkillEvent(time: 0.2, kind: .projectile(ProjectileSpec(speed: 8, radius: 0.25, lifetime: 3.5, damage: 8, homing: 220, count: 3, spread: 30, particle: .magic))),
            ]),
            SkillDefinition(id: "tpl.ice", name: L10n.t("冰霜扇击", "Frost Cone"), cooldown: 3.5, staminaCost: 20, symbol: "snowflake", events: [
                SkillEvent(time: 0, kind: .action(.attack)),
                SkillEvent(time: 0.15, kind: .area(AreaSpec(shape: .cone, radius: 4, angle: 40, damage: 16, particle: .ice, status: StatusSpec(kind: .slow, perSecond: 0, duration: 2.5)))),
            ]),
            SkillDefinition(id: "tpl.beam", name: L10n.t("雷光束", "Lightning Beam"), cooldown: 6, staminaCost: 30, symbol: "bolt.horizontal", events: [
                SkillEvent(time: 0, kind: .particles(.charge, seconds: 0.5)), SkillEvent(time: 0, kind: .action(.skill)),
                SkillEvent(time: 0.5, kind: .beam(BeamSpec(length: 10, width: 0.9, duration: 1.4, tickDamage: 6, interval: 0.2))), SkillEvent(time: 0.5, kind: .shake(0.3)),
            ]),
            SkillDefinition(id: "tpl.meteor", name: L10n.t("陨星爆裂", "Meteor Burst"), cooldown: 8, staminaCost: 35, symbol: "sparkle", events: [
                SkillEvent(time: 0, kind: .action(.skill)),
                SkillEvent(time: 0.1, kind: .area(AreaSpec(shape: .sphere, radius: 3, forward: 4, damage: 30, delay: 1, knockback: 3, particle: .explosion))),
                SkillEvent(time: 1.1, kind: .shake(0.6)),
            ]),
            SkillDefinition(id: "tpl.shockwave", name: L10n.t("震地冲击", "Ground Shockwave"), cooldown: 5, staminaCost: 25, symbol: "dot.radiowaves.left.and.right", events: [
                SkillEvent(time: 0, kind: .action(.attack)), SkillEvent(time: 0.25, kind: .area(AreaSpec(shape: .ring, radius: 4.5, damage: 18, knockback: 4, particle: .smoke))), SkillEvent(time: 0.25, kind: .shake(0.4)),
            ]),
            SkillDefinition(id: "tpl.dash", name: L10n.t("疾风突进", "Gale Dash"), cooldown: 3, staminaCost: 15, symbol: "wind", events: [
                SkillEvent(time: 0, kind: .action(.dodge)), SkillEvent(time: 0, kind: .dash(distance: 4)), SkillEvent(time: 0.15, kind: .area(AreaSpec(shape: .sphere, radius: 1.6, forward: 0, damage: 10, particle: .spark))),
            ]),
            SkillDefinition(id: "tpl.heal", name: L10n.t("治愈之光", "Healing Light"), cooldown: 10, staminaCost: 30, symbol: "cross.case", events: [
                SkillEvent(time: 0, kind: .action(.skill)), SkillEvent(time: 0, kind: .particles(.heal, seconds: 2)),
            ]),
        ]
    }
    /// Heal skills restore the caster instead of hitting anyone.
    static func healAmount(_ skill: SkillDefinition) -> Int { skill.events.contains { if case .particles(.heal, _) = $0.kind { return true }; return false } ? 35 : 0 }
}

// MARK: Boss scripts

struct WeightedSkill: Codable, Equatable, Sendable { var skillID: String; var weight = 1.0 }
struct SummonSpec: Codable, Equatable, Sendable { var kind = CreatureKind.enemy; var count = 2; var cap = 6 }

struct BossPhase: Codable, Equatable, Sendable {
    /// The phase starts when health falls to this fraction (first: 1).
    var threshold: Double
    var skills: [WeightedSkill] = []
    /// Character template shown from this phase on (Boss transform).
    var appearanceID: String?
    var summon: SummonSpec?
    var speed = 1.0
    /// Seconds between skill casts.
    var castInterval = 4.0
}

struct BossScript: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var phases: [BossPhase]
    var rewardShards = 25
    var valid: Bool {
        !id.isEmpty && (1...6).contains(phases.count) && phases.allSatisfy { (0...1).contains($0.threshold) && $0.skills.count <= 8 && $0.skills.allSatisfy { $0.weight > 0 } && (0.5...60).contains($0.castInterval) } &&
            phases.first?.threshold == 1
    }
}

enum BossDirector {
    /// Current phase index (0-based) for a health fraction.
    static func phase(_ script: BossScript, health: Int, maxHealth: Int) -> Int {
        let fraction = Double(health) / Double(max(1, maxHealth))
        return script.phases.indices.last { script.phases[$0].threshold >= fraction } ?? 0
    }
    /// Picks the next skill by weight among the ones off cooldown. `roll`
    /// is 0..<1 (seeded per boss, so fights replay the same way).
    static func pick(_ phase: BossPhase, ready: Set<String>, roll: Double) -> String? {
        let options = phase.skills.filter { ready.contains($0.skillID) }
        let total = options.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var target = roll * total
        for option in options { target -= option.weight; if target < 0 { return option.skillID } }
        return options.last?.skillID
    }
    /// How many to summon now, never exceeding the phase cap alive.
    static func summonCount(_ spec: SummonSpec, alive: Int) -> Int { max(0, min(spec.count, spec.cap - alive)) }

    /// A three-phase example script using the skill templates.
    static func example(id: String) -> BossScript {
        BossScript(id: id, name: L10n.t("玻璃巨像", "Glass Colossus"), phases: [
            BossPhase(threshold: 1, skills: [WeightedSkill(skillID: "tpl.shockwave", weight: 2), WeightedSkill(skillID: "tpl.fireball", weight: 1)], castInterval: 4.5),
            BossPhase(threshold: 0.66, skills: [WeightedSkill(skillID: "tpl.homing", weight: 2), WeightedSkill(skillID: "tpl.meteor", weight: 1)], summon: SummonSpec(kind: .enemy, count: 2, cap: 4), speed: 1.15, castInterval: 3.5),
            BossPhase(threshold: 0.33, skills: [WeightedSkill(skillID: "tpl.beam", weight: 2), WeightedSkill(skillID: "tpl.meteor", weight: 2), WeightedSkill(skillID: "tpl.shockwave", weight: 1)], speed: 1.3, castInterval: 2.6),
        ], rewardShards: 40)
    }
}

// MARK: Third-person and combat camera

enum ThirdPersonCamera {
    static let tilt = 62.0
    static let distance = 6.5

    /// Camera turn that puts the camera behind a body facing `facing`.
    static func yawBehind(facing: Double) -> Double { facing - 90 }

    /// Turns `current` toward `target` by at most `rate × dt` (no jumps).
    static func approach(_ current: Double, _ target: Double, rate: Double, dt: Double) -> Double {
        var difference = (target - current).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 } else if difference < -180 { difference += 360 }
        let step = max(-rate * dt, min(rate * dt, difference))
        return current + step
    }

    /// Pulls the camera in so no solid block stands between it and the
    /// player's head (obstacle avoidance).
    static func clearDistance(_ camera: SpatialCameraState, wanted: Double, geometry: SpatialGeometry) -> Double {
        var probe = camera; probe.distance = wanted
        let eye = SpatialCameraRules.position(probe)
        let head = camera.target + SpatialVector(0, 0, 1.2)
        let steps = max(4, Int(wanted * 4))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = SpatialVector.lerp(head, eye, t)
            if geometry.boxes(x: p.x, y: p.y, radius: 0.15).contains(where: { $0.collision == .solid && $0.minZ <= p.z && $0.maxZ >= p.z }) {
                return max(SpatialCameraRules.minDistance, wanted * Double(i - 1) / Double(steps) - 0.3)
            }
        }
        return wanted
    }

    /// The camera turn that keeps the player in front and the locked
    /// target beyond it.
    static func combatYaw(player: SpatialVector, target: SpatialVector) -> Double {
        let angle = atan2(target.y - player.y, target.x - player.x) * 180 / .pi
        return yawBehind(facing: angle)
    }

    /// The best target to lock: alive, hostile, in range, nearest to the
    /// direction the player faces.
    static func lockTarget(player: SpatialVector, facing: Double, creatures: [CreatureEntity], range: Double = 14) -> String? {
        creatures.filter { $0.alive && $0.kind.hostile && ($0.position - player).flatLength <= range && abs($0.position.z - player.z) < 6 }
            .min { a, b in score(a, player, facing) < score(b, player, facing) }?.id
    }
    private static func score(_ creature: CreatureEntity, _ player: SpatialVector, _ facing: Double) -> Double {
        let offset = creature.position - player
        var difference = abs(atan2(offset.y, offset.x) * 180 / .pi - facing).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference = 360 - difference }
        return offset.flatLength + difference / 30 - (creature.kind.isBoss ? 3 : 0)
    }
}
