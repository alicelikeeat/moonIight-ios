import Foundation

// v1.91: one animation controller for every model character. It reads the
// authoritative game state (action, when it started, combo step, speed,
// ground) and the world clock, and only PRESENTS it: it never decides
// whether an attack hits. It blends idle → walk → run on one shared cycle,
// strafing and walking backwards by direction, an air pose, a landing,
// and one-shot actions on top (upper body only while moving, full body
// otherwise, hurt and death above everything), with short crossfades.
// Events (hits, footsteps, invulnerability) fire once per play, keyed by a
// stable id, however often or rarely the controller is updated — so a lower
// frame rate, a view switch or re-evaluating the same moment never doubles
// them. Pure Swift (tested on Linux).

struct AnimationInput: Equatable, Sendable {
    /// Ground speed, metres per second.
    var speed: Float = 0
    /// Movement direction relative to facing: x right, y forward (unit or zero).
    var direction = SIMD2<Float>(0, 1)
    var grounded = true
    var action = CharacterAction.idle
    /// Authoritative world clock when the action started.
    var actionStarted: Double = 0
    var combo = 1
    var weaponReady = false
    var clock: Double = 0
}

struct FiredMotionEvent: Equatable, Sendable {
    /// "<motion>@<start>#<event id>": unique per play of a motion.
    var key: String
    var motion: String
    var event: MotionEvent
}

struct CharacterAnimationController: Sendable {
    let library: [String: UniversalMotion]
    /// Reference speeds of the walk and run cycles, m/s, for a body with legs `legLength` long.
    var legLength: Float
    private(set) var cyclePhase: Float = 0
    private var lastClock: Double?
    private var airSince: Double?
    private var landedAt: Double?
    private var wasGrounded = true
    private var current: (id: String, start: Double)?
    private var previous: (id: String, start: Double, until: Double)?
    private var fired: [String] = []
    private var lastEventTime: Float = -1

    static let fadeIn: Float = 0.08
    static let fadeOut: Float = 0.14

    init(library: [UniversalMotion] = MotionLibrary.standard, legLength: Float = 0.85) {
        var map: [String: UniversalMotion] = [:]
        for m in library { map[m.id] = m }
        self.library = map
        self.legLength = max(0.1, legLength)
    }

    /// Walk / run speeds this body moves at when its feet do not slide.
    var walkSpeed: Float { (library["walk"]?.rootMotion?.z ?? 1.7) * legLength / (library["walk"]?.duration ?? 1.05) }
    var runSpeed: Float { (library["run"]?.rootMotion?.z ?? 3.6) * legLength / (library["run"]?.duration ?? 0.68) }

    /// Locomotion weights for a speed: idle, walk, run (sum 1).
    func locomotionWeights(_ speed: Float) -> (idle: Float, walk: Float, run: Float) {
        let s = max(0, speed.isFinite ? speed : 0)
        let w = walkSpeed, r = runSpeed
        if s <= 0.15 { return (1, 0, 0) }
        if s < w { let f = (s - 0.15) / max(0.01, w - 0.15); return (1 - f, f, 0) }
        if s < r { let f = (s - w) / max(0.01, r - w); return (0, 1 - f, f) }
        return (0, 0, 1)
    }

    /// The one-shot motion for an action (nil: the action is a movement state).
    func actionMotion(_ input: AnimationInput) -> UniversalMotion? {
        guard input.action.oneShot || input.action == .death else { return nil }
        let moving = input.speed > 0.5
        return library[MotionLibrary.id(for: input.action, combo: input.combo, moving: moving)]
    }

    private func blend(_ a: MotionSample, _ b: MotionSample, _ w: Float, mask: MotionMask) -> MotionSample {
        guard w > 0 else { return a }
        var out = a
        let keys = Set(a.rotations.keys).union(b.rotations.keys)
        for k in keys where mask.covers(k) {
            out.rotations[k] = Quat.slerp(a.rotations[k] ?? .identity, b.rotations[k] ?? .identity, min(1, w))
        }
        if mask == .fullBody { out.root = a.root + (b.root - a.root) * min(1, w) }
        return out
    }

    private func sample(_ id: String, at t: Float) -> MotionSample {
        library[id]?.sample(at: t, legLength: legLength) ?? MotionSample()
    }

    /// Advances to `input.clock` and returns the pose and the events crossed.
    mutating func update(_ input: AnimationInput) -> (pose: MotionSample, events: [FiredMotionEvent]) {
        let dt = Float(max(0, min(0.25, input.clock - (lastClock ?? input.clock))))
        lastClock = input.clock
        var events: [FiredMotionEvent] = []

        // 1. Locomotion: one cycle phase shared by walk and run (feet stay in step).
        let weights = locomotionWeights(input.speed)
        let walk = library["walk"], run = library["run"]
        let rate = weights.walk / (walk?.duration ?? 1) + weights.run / (run?.duration ?? 0.7)
        cyclePhase = (cyclePhase + dt * rate).truncatingRemainder(dividingBy: 1)
        // Direction: forward, back or sideways cycles.
        let d = input.direction, forward = d.y, side = d.x
        let walkID: String = forward < -0.5 ? "walkBack" : abs(side) > 0.7 && abs(forward) < 0.5 ? (side > 0 ? "strafeRight" : "strafeLeft") : "walk"
        var pose = sample("idle", at: Float(input.clock))
        if weights.walk > 0 { pose = blend(pose, sample(walkID, at: cyclePhase * (library[walkID]?.duration ?? 1)), weights.walk + weights.run, mask: .fullBody) }
        if weights.run > 0 && walkID == "walk" { pose = blend(pose, sample("run", at: cyclePhase * (run?.duration ?? 0.7)), weights.run / max(0.001, weights.walk + weights.run), mask: .fullBody) }
        if input.weaponReady { pose = blend(pose, sample("weaponHold", at: Float(input.clock)), 1, mask: .upperBody) }

        // 2. Air and landing.
        if !input.grounded {
            if airSince == nil { airSince = input.clock }
            let t = Float(input.clock - (airSince ?? input.clock))
            pose = blend(pose, sample("jumpAir", at: t), min(1, t / 0.12), mask: .fullBody)
        } else {
            if !wasGrounded, let since = airSince, input.clock - since > 0.25 { landedAt = input.clock }
            airSince = nil
        }
        wasGrounded = input.grounded
        if let landed = landedAt {
            let t = Float(input.clock - landed), m = library["land"]
            if t < (m?.duration ?? 0.3) { pose = blend(pose, sample("land", at: t), 1 - max(0, t - 0.2) / 0.12, mask: input.speed > 0.5 ? .lowerBody : .fullBody) }
            else { landedAt = nil }
        }

        // 3. The action layer, timed by the authoritative start.
        if let motion = actionMotion(input) {
            let start = input.actionStarted
            if current?.id != motion.id || current?.start != start {
                if let c = current { previous = (c.id, c.start, input.clock + Double(Self.fadeOut)) }
                current = (motion.id, start)
                lastEventTime = -1
            }
            let t = Float(max(0, input.clock - start))
            let mask: MotionMask = [.hurt, .death, .dodge].contains(input.action) || input.speed <= 0.5 ? .fullBody : motion.mask
            var w = min(1, t / Self.fadeIn)
            if !motion.loop && input.action != .death { w *= min(1, max(0, (motion.duration - t * motion.speed) / Self.fadeOut)) }
            pose = blend(pose, sample(motion.id, at: t), w, mask: mask)
            // Events crossed since the last update, each once per play.
            let from = lastEventTime < 0 ? -0.0001 : lastEventTime
            for e in motion.events(from: from, to: t) {
                let key = "\(motion.id)@\(start)#\(e.id)"
                if !fired.contains(key) { fired.append(key); events.append(FiredMotionEvent(key: key, motion: motion.id, event: e)) }
            }
            lastEventTime = max(lastEventTime, t)
            if fired.count > 64 { fired.removeFirst(fired.count - 64) }
        } else if let c = current {
            // The action ended: fade out of its last pose.
            previous = (c.id, c.start, input.clock + Double(Self.fadeOut))
            current = nil
        }
        if current == nil, let p = previous, input.clock < p.until, let m = library[p.id] {
            let w = Float((p.until - input.clock) / Double(Self.fadeOut))
            pose = blend(pose, sample(p.id, at: Float(input.clock - p.start)), min(1, w), mask: m.mask)
        } else if current == nil { previous = nil }
        return (pose, events)
    }
}

// MARK: Combo rules

/// The three-hit combo: pressing attack inside the cancel window of hit N
/// starts hit N+1 (after the third, back to the first); otherwise hit 1.
/// Damage factors are a game rule here, not something the animation decides.
enum ComboRules {
    static let steps = 3
    static func next(current: Int, chained: Bool) -> Int { chained ? current % steps + 1 : 1 }
    static func damageFactor(_ step: Int) -> Double { step >= 3 ? 1.5 : step == 2 ? 1.1 : 1.0 }
}
