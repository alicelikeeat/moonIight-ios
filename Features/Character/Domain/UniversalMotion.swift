import Foundation

// v1.91: one motion format for every character. Keyframed joint rotations
// (quaternions, relative to the bind pose, in the parent's bind frame — the
// convention of every Moonlight rig, whose rest rotations are identity),
// an optional root track in leg lengths (so it scales with the body),
// phases for combat (wind-up, active, recovery, cancel), events with stable
// ids, a body mask, an interrupt rule and a version. The four older formats
// (MotionClip sine channels, the 10-bone RigClip, KeyframeClip from model
// files, and picture ActionClip timings) convert into it; KeyframeClip keeps
// its full local transforms as a pass-through. Pure Swift (tested on Linux).

/// A point in a motion where something happens. `id` is stable across
/// frame rates and views; the controller fires each one once per play.
struct MotionEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case activeStart, hit, activeEnd, cancelOpen, end, footstep, effect, custom }
    var id: String
    var time: Float
    var kind: Kind
}

/// Combat timing of a one-shot, seconds from its start.
struct MotionPhases: Codable, Equatable, Sendable {
    /// Wind-up ends / the move becomes active.
    var activeStart: Float
    /// The hit lands (damage is applied here by the game rules).
    var hit: Float
    var activeEnd: Float
    /// From here the move may be cancelled into the next (combo window).
    var cancelFrom: Float
    var end: Float

    enum Phase: String, Sendable { case windup, active, recovery, cancellable, done }
    func phase(at t: Float) -> Phase {
        if t >= end { return .done }
        if t >= cancelFrom { return .cancellable }
        if t >= activeEnd { return .recovery }
        if t >= activeStart { return .active }
        return .windup
    }
    var valid: Bool { [activeStart, hit, activeEnd, cancelFrom, end].allSatisfy(\.isFinite) && 0 <= activeStart && activeStart <= hit && hit <= activeEnd && activeEnd <= end && cancelFrom <= end && cancelFrom >= 0 }
}

/// Which joints a motion layer drives.
enum MotionMask: String, Codable, Sendable {
    case fullBody, upperBody, lowerBody
    func covers(_ jointID: String) -> Bool {
        switch self {
        case .fullBody: true
        case .upperBody: MotionMask.upper(jointID)
        case .lowerBody: !MotionMask.upper(jointID)
        }
    }
    /// Spine1 and above (chest, neck, head, arms, hands, fingers, jaw, eyes).
    static func upper(_ id: String) -> Bool {
        let lower: Set<String> = ["pelvis", "spine", "rightThigh", "rightShin", "rightFoot", "rightToe", "rightToeEnd", "leftThigh", "leftShin", "leftFoot", "leftToe", "leftToeEnd"]
        return !lower.contains(id)
    }
}

struct JointTrack: Codable, Equatable, Sendable {
    /// Joint id: a standard tag ("rightUpperArm") or an extension ("ext.jaw").
    var joint: String
    var times: [Float]
    var rotations: [Quat]

    func sample(_ t: Float, step: Bool) -> Quat {
        let n = min(times.count, rotations.count)
        guard n > 0 else { return .identity }
        if n == 1 || t <= times[0] { return rotations[0] }
        if t >= times[n - 1] { return rotations[n - 1] }
        var lo = 0, hi = n - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if times[mid] <= t { lo = mid } else { hi = mid } }
        if step { return rotations[lo] }
        let span = times[hi] - times[lo]
        return Quat.slerp(rotations[lo], rotations[hi], span > 0 ? (t - times[lo]) / span : 0)
    }
}

/// Root offset keys, in leg lengths (hip height of the bind pose).
struct RootTrack: Codable, Equatable, Sendable {
    var times: [Float]
    var offsets: [SIMD3<Float>]
    func sample(_ t: Float) -> SIMD3<Float> {
        let n = min(times.count, offsets.count)
        guard n > 0 else { return .zero }
        if n == 1 || t <= times[0] { return offsets[0] }
        if t >= times[n - 1] { return offsets[n - 1] }
        var i = 0
        while i + 1 < n && times[i + 1] < t { i += 1 }
        let span = times[i + 1] - times[i], f = span > 0 ? (t - times[i]) / span : 0
        return offsets[i] + (offsets[i + 1] - offsets[i]) * f
    }
}

/// A sampled pose: rotation per joint id and the root offset in metres.
struct MotionSample: Equatable, Sendable {
    var rotations: [String: Quat] = [:]
    var root: SIMD3<Float> = .zero
    /// Full local transforms from a model file's own animation (pass-through).
    var locals: [RigXform]? = nil
}

struct UniversalMotion: Codable, Equatable, Identifiable, Sendable {
    enum Bind: String, Codable, Sendable { case tPose, aPose, own }
    enum Interpolation: String, Codable, Sendable { case linear, step }
    enum Interrupt: String, Codable, Sendable {
        /// Anything may replace it (loops).
        case anytime
        /// Only after its cancel window opens, or by a higher priority.
        case afterCancel
        /// Plays out (death).
        case never
    }
    enum Source: String, Codable, Sendable { case authored, motionClip, rig10, keyframeFile, retargeted }

    static let currentVersion = 1

    var id: String
    var name: String
    var tags: [String] = []
    /// Skeleton family the tracks are written for.
    var skeleton = "moonlight.humanoid"
    /// The bind pose the rotations are relative to.
    var bind = Bind.tPose
    var duration: Float
    var loop: Bool
    var speed: Float = 1
    var interpolation = Interpolation.linear
    var tracks: [JointTrack] = []
    var root: RootTrack?
    /// Distance travelled per cycle in leg lengths (locomotion speed matching);
    /// the game moves the character, the motion never does.
    var rootMotion: SIMD3<Float>?
    var mask = MotionMask.fullBody
    var events: [MotionEvent] = []
    var phases: MotionPhases?
    var interrupt = Interrupt.anytime
    var priority = 0
    var version = UniversalMotion.currentVersion
    var source = Source.authored
    /// Pass-through for animations read from a model file (exact local transforms).
    var file: KeyframeClip?

    var valid: Bool {
        duration.isFinite && duration > 0 && duration < 600 && speed.isFinite && speed > 0 && version <= Self.currentVersion &&
            tracks.allSatisfy { $0.times.count == $0.rotations.count && $0.times.allSatisfy(\.isFinite) && $0.rotations.allSatisfy(\.finite) && zip($0.times, $0.times.dropFirst()).allSatisfy { $0 <= $1 } } &&
            events.allSatisfy { $0.time.isFinite && $0.time >= 0 && $0.time <= duration + 1e-3 } && (phases?.valid ?? true) &&
            (root.map { $0.times.count == $0.offsets.count && $0.offsets.allSatisfy(cFinite) } ?? true)
    }

    /// Motion time for a play time (looping or held at the end).
    func localTime(_ t: Float) -> Float {
        guard t.isFinite, duration > 0 else { return 0 }
        let scaled = max(0, t) * speed
        if loop { let r = scaled.truncatingRemainder(dividingBy: duration); return r.isFinite ? r : 0 }
        return min(scaled, duration)
    }

    /// The pose at play time `t`; root offsets in metres for a body whose
    /// legs are `legLength` long.
    func sample(at t: Float, legLength: Float = 0.85, skeleton: SkeletonDefinition? = nil) -> MotionSample {
        let lt = localTime(t)
        if let file, let skeleton { return MotionSample(locals: file.locals(skeleton, at: lt)) }
        var out = MotionSample()
        for track in tracks { out.rotations[track.joint] = track.sample(lt, step: interpolation == .step) }
        if let root { out.root = root.sample(lt) * legLength }
        return out
    }

    /// Events crossed going from play time `a` to `b` (wrapping for loops).
    func events(from a: Float, to b: Float) -> [MotionEvent] {
        guard b > a, !events.isEmpty else { return [] }
        if !loop { let la = min(a * speed, duration), lb = min(b * speed, duration); return events.filter { $0.time > la && $0.time <= lb || (a <= 0 && $0.time == 0 && lb >= 0) } }
        var out: [MotionEvent] = []
        let start = a * speed, end = b * speed
        var cycle = (start / duration).rounded(.down)
        while cycle * duration < end {
            for e in events {
                let at = cycle * duration + e.time
                if at > start && at <= end { out.append(e) }
            }
            cycle += 1
        }
        return out
    }
}

// MARK: Skeleton application

enum RigPoser {
    /// Local joint transforms for a sample: bind rest × rotation (rest
    /// rotations are identity on Moonlight rigs, so rotations act in the
    /// parent's bind frame), the root offset on the root joint.
    static func locals(_ sample: MotionSample, skeleton: SkeletonDefinition) -> [RigXform] {
        if let locals = sample.locals, locals.count == skeleton.joints.count { return locals }
        return skeleton.joints.enumerated().map { i, joint in
            var rest = joint.rest
            if joint.parentID == nil { rest.tx += sample.root.x; rest.ty += sample.root.y; rest.tz += sample.root.z }
            guard let q = sample.rotations[joint.jointID] ?? (joint.semanticTag != .other ? sample.rotations[joint.semanticTag.rawValue] : nil) else { return rest }
            return rest * q.xform
        }
    }

    /// Skinning matrices for a sample (posed × inverse bind).
    static func skinning(_ sample: MotionSample, skeleton: SkeletonDefinition) -> [RigXform] {
        let world = skeleton.worldTransforms(local: locals(sample, skeleton: skeleton))
        return zip(world, skeleton.joints).map { $0 * (RigXform(matrix: $1.inverseBindMatrix) ?? .identity) }
    }

    /// Model-space joint positions for a sample.
    static func positions(_ sample: MotionSample, skeleton: SkeletonDefinition) -> [SIMD3<Float>] {
        skeleton.worldTransforms(local: locals(sample, skeleton: skeleton)).map(\.origin)
    }

    /// Hip height of the bind pose (the unit of root tracks).
    static func legLength(_ skeleton: SkeletonDefinition) -> Float {
        let y = skeleton.position(.rightThigh)?.y ?? skeleton.position(.pelvis)?.y ?? 0.85
        let foot = skeleton.position(.rightFoot)?.y ?? 0
        return max(0.05, y - foot * 0.5)
    }
}

// MARK: Adapters from the older formats

enum MotionAdapters {
    /// Sine-channel MotionClip (A-pose rigs, degrees): sampled into keys.
    static func from(_ clip: MotionClip, keysPerSecond: Float = 30) -> UniversalMotion {
        var motion = UniversalMotion(id: clip.id, name: clip.name, bind: .aPose, duration: max(0.04, clip.period), loop: true, source: .motionClip)
        if let keys = clip.keyframes { motion.file = keys; motion.bind = .own; motion.source = .keyframeFile; return motion }
        let count = max(2, Int((clip.period * keysPerSecond).rounded()) + 1)
        let times = (0..<count).map { Float($0) / Float(count - 1) * clip.period }
        let joints = Array(Set(clip.channels.map(\.joint)))
        for joint in joints.sorted(by: { $0.rawValue < $1.rawValue }) {
            let rotations = times.map { t -> Quat in
                var e = SIMD3<Float>.zero
                for c in clip.channels where c.joint == joint && (0..<3).contains(c.axis) {
                    e[c.axis] += clip.value(amplitude: c.amplitude, phase: c.phase, bias: c.bias, cycles: c.cycles, at: t)
                }
                return Quat(eulerDegrees: e)
            }
            motion.tracks.append(JointTrack(joint: joint.rawValue, times: times, rotations: rotations))
        }
        if !clip.root.isEmpty {
            // MotionClip roots are in model heights (the model is 1 tall); legs are about half of it.
            let offsets = times.map { t -> SIMD3<Float> in
                var o = SIMD3<Float>.zero
                for r in clip.root where (0..<3).contains(r.axis) { o[r.axis] += clip.value(amplitude: r.amplitude, phase: r.phase, bias: r.bias, cycles: r.cycles, rectified: r.rectified, at: t) }
                return o * 2
            }
            motion.root = RootTrack(times: times, offsets: offsets)
        }
        return motion
    }

    /// The 10-bone rig's semantic map onto the standard joints.
    static func joint(for bone: RigBone) -> JointTag {
        switch bone {
        // The old torso bone is the root of the 10-bone rig (legs hang from it), like the pelvis.
        case .torso: .pelvis
        case .head: .head
        case .rightUpperArm: .rightUpperArm
        case .rightForearm: .rightForearm
        case .leftUpperArm: .leftUpperArm
        case .leftForearm: .leftForearm
        case .rightThigh: .rightThigh
        case .rightShin: .rightShin
        case .leftThigh: .leftThigh
        case .leftShin: .leftShin
        }
    }

    /// 10-bone RigClip (radians about any axis, sine waves): sampled into keys.
    static func from(_ clip: RigClip, keysPerSecond: Float = 30) -> UniversalMotion {
        var motion = UniversalMotion(id: clip.id, name: clip.name, bind: .own, duration: max(0.04, clip.period), loop: true, source: .rig10)
        let count = max(2, Int((clip.period * keysPerSecond).rounded()) + 1)
        let times = (0..<count).map { Float($0) / Float(count - 1) * clip.period }
        for bone in RigBone.allCases {
            let channels = clip.channels.filter { $0.bone == bone && $0.axis.count == 3 }
            guard !channels.isEmpty else { continue }
            let rotations = times.map { t -> Quat in
                // As RigPose: channels compose in order, the phase is in radians.
                var q = Quat.identity
                for c in channels { q = q * Quat(axis: SIMD3(c.axis[0], c.axis[1], c.axis[2]), angle: clip.angle(c, at: t)) }
                return q
            }
            motion.tracks.append(JointTrack(joint: joint(for: bone).rawValue, times: times, rotations: rotations))
        }
        return motion
    }

    /// Picture ActionClip: no joints, but its timing (length, loop, effect
    /// moment) becomes phases and events so pictures and models share them.
    static func timing(of clip: ActionClip, action: CharacterAction) -> UniversalMotion {
        let speed = Float(max(0.1, clip.speed)), length = Float(max(0.05, clip.length)) / speed, hit = Float(clip.eventTime) / speed
        var motion = UniversalMotion(id: "picture." + action.rawValue, name: action.title, bind: .own, duration: length, loop: clip.loop, source: .authored)
        if action.oneShot {
            motion.phases = MotionPhases(activeStart: min(hit, length), hit: min(hit, length), activeEnd: min(length, hit + 0.1), cancelFrom: length * Float(CharacterAnimator.cancelFraction), end: length)
            motion.events = [MotionEvent(id: action.rawValue + ".hit", time: min(hit, length), kind: .hit), MotionEvent(id: action.rawValue + ".end", time: length, kind: .end)]
            motion.interrupt = .afterCancel
        }
        return motion
    }
}
