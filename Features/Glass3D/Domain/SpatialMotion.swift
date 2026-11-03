import Foundation

// Dynamic buildings: one controller for slides, lifts, rotation, tracks
// and elevators, all driven by the world clock.

enum MotionRepeat: String, Codable, CaseIterable, Sendable {
    case loop, pingPong, once
    var title: String {
        switch self { case .loop: L10n.t("循环", "Loop"); case .pingPong: L10n.t("往返", "Back and Forth"); case .once: L10n.t("单次", "Once") }
    }
}

enum MotionEasing: String, Codable, CaseIterable, Sendable {
    case linear, smooth
    func apply(_ t: Double) -> Double { self == .linear ? t : t * t * (3 - 2 * t) }
}

enum MotionTrigger: String, Codable, CaseIterable, Sendable {
    /// Runs all the time.
    case always
    /// Starts when the player comes within `triggerRadius`.
    case proximity
    /// Started by a button block or the editor.
    case button
    /// Starts every `interval` seconds.
    case timer
    var title: String {
        switch self {
        case .always: L10n.t("始终运行", "Always"); case .proximity: L10n.t("角色接近", "Player Nearby")
        case .button: L10n.t("按钮触发", "Button"); case .timer: L10n.t("定时", "Timer")
        }
    }
}

enum MotionKind: String, Codable, CaseIterable, Sendable {
    case slide, lift, rotate, track, elevator
    var title: String {
        switch self {
        case .slide: L10n.t("水平平移", "Slide"); case .lift: L10n.t("垂直升降", "Lift"); case .rotate: L10n.t("旋转", "Rotate")
        case .track: L10n.t("轨道", "Track"); case .elevator: L10n.t("电梯", "Elevator")
        }
    }
}

/// A point on a motion path: offset from the group's rest position.
struct MotionKeyframe: Codable, Equatable, Sendable {
    var offset: SpatialVector
    /// Degrees around the vertical axis.
    var yaw = 0.0
    /// Seconds to wait here (stops, elevator floors).
    var dwell = 0.0
}

/// How media on moving blocks plays.
enum MotionMediaSync: String, Codable, CaseIterable, Sendable {
    case independent, whileMoving
    var title: String { self == .independent ? L10n.t("独立播放", "Independent") : L10n.t("随运动播放", "Plays While Moving") }
}

struct SpatialMotion: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: MotionKind
    /// Rest position is keyframe 0 (usually zero offset).
    var keyframes: [MotionKeyframe]
    /// Seconds per segment.
    var segmentDuration = 3.0
    var easing = MotionEasing.smooth
    var repeatMode = MotionRepeat.pingPong
    var trigger = MotionTrigger.always
    var triggerRadius = 3.0
    var interval = 10.0
    var smoothPath = false
    var closed = false
    var mediaSync = MotionMediaSync.independent
    /// Runtime: when the current run started (nil: idle at `restIndex`).
    var startedAt: Double?
    var restIndex = 0
    /// Elevator: the floor asked for.
    var targetIndex: Int?
    var lastTrigger = -1_000.0

    static let maximumKeyframes = 32
    var valid: Bool {
        !id.isEmpty && id.count <= 128 && (2...Self.maximumKeyframes).contains(keyframes.count) &&
            keyframes.allSatisfy { $0.offset.finite && $0.yaw.isFinite && $0.dwell.isFinite && (0...60).contains($0.dwell) } &&
            segmentDuration.isFinite && (0.2...120).contains(segmentDuration) && triggerRadius.isFinite && (0.5...32).contains(triggerRadius) &&
            interval.isFinite && (1...600).contains(interval) && (0..<keyframes.count).contains(restIndex)
    }

    var segments: Int { closed ? keyframes.count : keyframes.count - 1 }
    var runsAlways: Bool { trigger == .always }

    // MARK: Presets

    static func slide(id: String, dx: Double, dy: Double) -> SpatialMotion {
        SpatialMotion(id: id, kind: .slide, keyframes: [MotionKeyframe(offset: .zero, dwell: 1), MotionKeyframe(offset: SpatialVector(dx, dy, 0), dwell: 1)])
    }
    static func lift(id: String, height: Double) -> SpatialMotion {
        SpatialMotion(id: id, kind: .lift, keyframes: [MotionKeyframe(offset: .zero, dwell: 1.5), MotionKeyframe(offset: SpatialVector(0, 0, height), dwell: 1.5)])
    }
    static func rotate(id: String, degrees: Double = 360) -> SpatialMotion {
        SpatialMotion(id: id, kind: .rotate, keyframes: [MotionKeyframe(offset: .zero), MotionKeyframe(offset: .zero, yaw: degrees)],
                      segmentDuration: 8, easing: .linear, repeatMode: .loop)
    }
    static func elevator(id: String, floors: [Double]) -> SpatialMotion {
        SpatialMotion(id: id, kind: .elevator, keyframes: floors.map { MotionKeyframe(offset: SpatialVector(0, 0, $0), dwell: 2) },
                      segmentDuration: 2.5, repeatMode: .once, trigger: .proximity, triggerRadius: 1.5)
    }
    static func track(id: String, points: [SpatialVector], smooth: Bool, closed: Bool) -> SpatialMotion {
        SpatialMotion(id: id, kind: .track, keyframes: points.map { MotionKeyframe(offset: $0, dwell: 0.5) },
                      segmentDuration: 2, easing: .linear, repeatMode: closed ? .loop : .pingPong, smoothPath: smooth, closed: closed)
    }
}

/// Where a motion is at a moment: offset and yaw from rest, whether it is
/// moving, and its progress (0…1 over one pass) for media sync.
struct MotionPose: Equatable, Sendable {
    var offset: SpatialVector
    var yaw: Double
    var moving: Bool
    var progress: Double
}

enum SpatialMotionRules {
    /// Total seconds for one pass (segments plus dwell times).
    /// One pass: dwell at each key then travel on; an open path also
    /// dwells at its last key, so back-and-forth pauses at both ends.
    static func passLength(_ motion: SpatialMotion) -> Double {
        let keys = motion.closed ? motion.keyframes.count : motion.keyframes.count
        let dwell = (0..<keys).reduce(0.0) { $0 + motion.keyframes[$1].dwell }
        return Double(motion.segments) * motion.segmentDuration + dwell
    }

    /// The pose at world time `clock`.
    static func pose(_ motion: SpatialMotion, clock: Double) -> MotionPose {
        let rest = motion.keyframes[motion.restIndex]
        let restPose = MotionPose(offset: rest.offset, yaw: rest.yaw, moving: false, progress: 0)
        let length = passLength(motion)
        guard length > 0 else { return restPose }
        // Elevators travel from the rest floor to the target floor once.
        if motion.kind == .elevator {
            guard let start = motion.startedAt, let target = motion.targetIndex, target != motion.restIndex else { return restPose }
            let floors = abs(target - motion.restIndex)
            let elapsed = max(0, clock - start), travel = Double(floors) * motion.segmentDuration
            let t = min(1, elapsed / travel)
            let from = motion.keyframes[motion.restIndex].offset, to = motion.keyframes[target].offset
            return MotionPose(offset: SpatialVector.lerp(from, to, motion.easing.apply(t)), yaw: 0, moving: t < 1, progress: t)
        }
        var elapsed: Double
        if motion.runsAlways { elapsed = clock } else {
            guard let start = motion.startedAt else { return restPose }
            elapsed = clock - start
        }
        elapsed = max(0, elapsed)
        switch motion.repeatMode {
        case .loop: elapsed = elapsed.truncatingRemainder(dividingBy: length)
        case .pingPong:
            let doubled = elapsed.truncatingRemainder(dividingBy: length * 2)
            // The way back mirrors the way out.
            elapsed = doubled >= length ? length * 2 - doubled : doubled
        case .once:
            if elapsed >= length {
                let last = motion.keyframes[motion.closed ? 0 : motion.keyframes.count - 1]
                return MotionPose(offset: last.offset, yaw: last.yaw, moving: false, progress: 1)
            }
        }
        // Walk the segments: dwell at each key first, then travel.
        var remaining = elapsed
        for segment in 0..<motion.segments {
            let a = motion.keyframes[segment % motion.keyframes.count], b = motion.keyframes[(segment + 1) % motion.keyframes.count]
            if remaining < a.dwell { return MotionPose(offset: a.offset, yaw: a.yaw, moving: false, progress: elapsed / length) }
            let dwell = a.dwell
            remaining -= dwell
            if remaining < motion.segmentDuration {
                let t = motion.easing.apply(remaining / motion.segmentDuration)
                let point = motion.smoothPath ? smooth(motion, segment: segment, t: t) : SpatialVector.lerp(a.offset, b.offset, t)
                return MotionPose(offset: point, yaw: a.yaw + (b.yaw - a.yaw) * t, moving: true, progress: elapsed / length)
            }
            remaining -= motion.segmentDuration
        }
        let last = motion.keyframes[motion.closed ? 0 : motion.keyframes.count - 1]
        return MotionPose(offset: last.offset, yaw: last.yaw, moving: false, progress: 1)
    }

    /// Catmull-Rom through the keyframes for smooth tracks.
    private static func smooth(_ motion: SpatialMotion, segment: Int, t: Double) -> SpatialVector {
        let keys = motion.keyframes.map(\.offset), n = keys.count
        func key(_ i: Int) -> SpatialVector {
            if motion.closed { return keys[((i % n) + n) % n] }
            return keys[max(0, min(n - 1, i))]
        }
        let p0 = key(segment - 1), p1 = key(segment), p2 = key(segment + 1), p3 = key(segment + 2)
        let t2 = t * t, t3 = t2 * t
        func blend(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return SpatialVector(blend(p0.x, p1.x, p2.x, p3.x), blend(p0.y, p1.y, p2.y, p3.y), blend(p0.z, p1.z, p2.z, p3.z))
    }

    /// Elevator: ask for a floor. Ignored while it is travelling.
    static func call(_ motion: inout SpatialMotion, floor: Int, clock: Double) {
        guard motion.kind == .elevator, motion.keyframes.indices.contains(floor) else { return }
        if let start = motion.startedAt, let target = motion.targetIndex {
            let travel = Double(abs(target - motion.restIndex)) * motion.segmentDuration
            if clock - start < travel { return }
            motion.restIndex = target
        }
        guard floor != motion.restIndex else { motion.startedAt = nil; motion.targetIndex = nil; return }
        motion.targetIndex = floor; motion.startedAt = clock
    }

    /// Settles a finished elevator ride so the next call starts from there.
    static func settle(_ motion: inout SpatialMotion, clock: Double) {
        guard motion.kind == .elevator, let start = motion.startedAt, let target = motion.targetIndex else { return }
        let travel = Double(abs(target - motion.restIndex)) * motion.segmentDuration
        if clock - start >= travel + motion.keyframes[target].dwell { motion.restIndex = target; motion.startedAt = nil; motion.targetIndex = nil }
    }

    /// Starts a triggered motion (button, proximity, timer). Re-triggering
    /// inside the cooldown is ignored, so events cannot loop.
    @discardableResult
    static func start(_ motion: inout SpatialMotion, clock: Double, cooldown: Double = 0.5) -> Bool {
        guard !motion.runsAlways, clock - motion.lastTrigger >= cooldown else { return false }
        motion.lastTrigger = clock
        if motion.kind == .elevator {
            let next = motion.restIndex + 1 < motion.keyframes.count ? motion.restIndex + 1 : 0
            call(&motion, floor: next, clock: clock); return true
        }
        if let started = motion.startedAt, motion.repeatMode == .once, clock - started < passLength(motion) { return false }
        motion.startedAt = clock; return true
    }
}

/// Events from the world in one frame, applied with a budget.
enum SpatialEventRules {
    static let actionsPerFrame = 32

    /// Fires proximity and timer triggers and settles elevators. Returns
    /// how many actions ran (never more than `actionsPerFrame`).
    @discardableResult
    static func step(_ world: inout SpatialWorld, player: SpatialVector, groupCenters: [String: SpatialVector]) -> Int {
        var actions = 0
        let motionGroups = Dictionary(world.groups.compactMap { group in group.motionID.map { ($0, group.id) } }, uniquingKeysWith: { first, _ in first })
        for index in world.motions.indices {
            guard actions < actionsPerFrame else { break }
            SpatialMotionRules.settle(&world.motions[index], clock: world.clock)
            let motion = world.motions[index]
            switch motion.trigger {
            case .proximity:
                guard let group = motionGroups[motion.id], let center = groupCenters[group] else { continue }
                let distance = (center - player).flatLength
                if distance <= motion.triggerRadius && abs(center.z - player.z) <= motion.triggerRadius + 2, motion.startedAt == nil {
                    if SpatialMotionRules.start(&world.motions[index], clock: world.clock, cooldown: 2) { actions += 1 }
                }
            case .timer:
                if world.clock - motion.lastTrigger >= motion.interval, SpatialMotionRules.start(&world.motions[index], clock: world.clock) { actions += 1 }
            case .always, .button: break
            }
        }
        return actions
    }

    /// A button block was touched: start or reverse its target group's motion.
    @discardableResult
    static func press(_ world: inout SpatialWorld, button: SpatialBlock) -> Bool {
        guard let target = button.buttonTarget, let motionID = world.groups.first(where: { $0.id == target })?.motionID,
              let index = world.motions.firstIndex(where: { $0.id == motionID }) else { return false }
        return SpatialMotionRules.start(&world.motions[index], clock: world.clock)
    }
}

extension SpatialWorld {
    /// Rest centre of every group that has a motion (turning pivot).
    func motionPivots() -> [String: SpatialVector] {
        let moving = Set(groups.filter { $0.motionID != nil }.map(\.id))
        var sums: [String: (SpatialVector, Double)] = [:]
        for block in blocks { guard let group = block.groupID, moving.contains(group) else { continue }
            let entry = sums[group] ?? (.zero, 0)
            sums[group] = (entry.0 + SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, block.elevation), entry.1 + 1)
        }
        return sums.mapValues { $0.0 * (1 / max(1, $0.1)) }
    }
    /// Where each moving group is at `clock`.
    func groupFrames(pivots: [String: SpatialVector], clock: Double) -> [String: GroupFrame] {
        let motions = Dictionary(self.motions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: GroupFrame] = [:]
        for group in groups {
            guard let motionID = group.motionID, let motion = motions[motionID], let pivot = pivots[group.id] else { continue }
            let pose = SpatialMotionRules.pose(motion, clock: clock)
            result[group.id] = GroupFrame(pivot: SpatialVector(pivot.x, pivot.y, 0), offset: pose.offset, yaw: pose.yaw)
        }
        return result
    }
}
