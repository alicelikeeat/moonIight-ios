import Foundation

// v1.91: motions onto other skeletons, and inverse kinematics.
//
// Retargeting is not a copy of joint angles: every bone of the target is
// turned so it points where the matching source bone points, after taking
// out the difference between the two bind poses (A-pose vs T-pose, long vs
// short limbs). Root tracks are stored in leg lengths, so a short body hops
// lower and a tall one higher. Pure Swift (tested on Linux).

struct RetargetReport: Equatable, Sendable {
    var mapped: [String] = []
    /// Source joints the target does not have (their motion is dropped).
    var missingInTarget: [String] = []
    /// Target joints the motion does not drive (they keep the bind pose).
    var undriven: [String] = []
    /// Largest bind-pose difference corrected, degrees.
    var bindCorrection: Float = 0
    var notes: [String] = []
    /// 0…1: share of the motion's joints the target could take.
    var coverage: Float = 0
}

enum MotionRetargeter {
    /// The child a joint's bone points at (standard chains first).
    static func primaryChild(_ skeleton: SkeletonDefinition, _ i: Int) -> Int? {
        let id = skeleton.joints[i].jointID
        let preferred: [String: String] = [
            "pelvis": "spine", "spine": "spine1", "spine1": "chest", "chest": "neck", "neck": "head", "head": "headEnd",
            "rightClavicle": "rightUpperArm", "rightUpperArm": "rightForearm", "rightForearm": "rightHand", "rightHand": "rightHandEnd",
            "leftClavicle": "leftUpperArm", "leftUpperArm": "leftForearm", "leftForearm": "leftHand", "leftHand": "leftHandEnd",
            "rightThigh": "rightShin", "rightShin": "rightFoot", "rightFoot": "rightToe", "rightToe": "rightToeEnd",
            "leftThigh": "leftShin", "leftShin": "leftFoot", "leftFoot": "leftToe", "leftToe": "leftToeEnd",
        ]
        let children = skeleton.children(i)
        if let want = preferred[id] ?? preferred[skeleton.joints[i].semanticTag.rawValue],
           let found = children.first(where: { skeleton.joints[$0].jointID == want || skeleton.joints[$0].semanticTag.rawValue == want }) { return found }
        return children.count == 1 ? children[0] : nil
    }

    /// Bind direction of every joint's bone (nil for joints without one).
    static func bindDirections(_ skeleton: SkeletonDefinition) -> [SIMD3<Float>?] {
        let world = skeleton.worldRest.map(\.origin)
        return skeleton.joints.indices.map { i in primaryChild(skeleton, i).map { cUnit(world[$0] - world[i]) } }
    }

    /// Key of a joint for matching across skeletons: its standard tag, else its id.
    static func key(_ joint: RigJoint) -> String { joint.semanticTag != .other ? joint.semanticTag.rawValue : joint.jointID }

    /// World rotations from local ones (rest rotations identity: W = W_parent · R).
    static func worldRotations(_ skeleton: SkeletonDefinition, _ local: [Quat]) -> [Quat] {
        var world = local
        for i in skeleton.joints.indices { if let p = skeleton.parentIndex(i), p < i { world[i] = (world[p] * local[i]).normalized } }
        return world
    }

    static func retarget(_ motion: UniversalMotion, from source: SkeletonDefinition, to target: SkeletonDefinition) -> (UniversalMotion, RetargetReport) {
        var report = RetargetReport()
        if motion.file != nil {
            report.notes.append(L10n.t("模型文件自带的动画按原骨骼播放，不重定向。", "Animations from a model file play on their own skeleton and are not retargeted."))
            return (motion, report)
        }
        let sourceDirs = bindDirections(source), targetDirs = bindDirections(target)
        var sourceIndex: [String: Int] = [:]
        for (i, j) in source.joints.enumerated() { sourceIndex[key(j)] = i }
        let tracked = Set(motion.tracks.map(\.joint))
        // Per target joint: the matching source joint and the bind correction Δ (target bind dir → source bind dir).
        var match: [Int?] = [], delta: [Quat] = []
        for (i, j) in target.joints.enumerated() {
            let s = sourceIndex[key(j)]
            match.append(s)
            var d = Quat.identity
            if let s, let a = targetDirs[i], let b = sourceDirs[s] { d = Quat.between(a, b) }
            delta.append(d)
            report.bindCorrection = max(report.bindCorrection, d.angle * 180 / .pi)
            if let s, tracked.contains(source.joints[s].jointID) || tracked.contains(key(source.joints[s])) { report.mapped.append(j.jointID) }
            else { report.undriven.append(j.jointID) }
        }
        let targetKeys = Set(target.joints.map(key))
        report.missingInTarget = motion.tracks.map(\.joint).filter { id in
            let k = source.joints.first { $0.jointID == id }.map(key) ?? id
            return !targetKeys.contains(k)
        }.sorted()
        report.coverage = motion.tracks.isEmpty ? 1 : Float(motion.tracks.count - report.missingInTarget.count) / Float(motion.tracks.count)

        var times = Set<Float>()
        for t in motion.tracks { times.formUnion(t.times) }
        if times.isEmpty { times = [0] }
        let sorted = times.sorted()
        var out = motion
        out.bind = .own; out.source = .retargeted; out.tracks = []
        var rotations = [[Quat]](repeating: [], count: target.joints.count)
        for t in sorted {
            let sample = motion.sample(at: t / max(1e-6, motion.speed), legLength: 1)
            let sourceLocal = source.joints.map { j in sample.rotations[j.jointID] ?? sample.rotations[key(j)] ?? .identity }
            let sourceWorld = worldRotations(source, sourceLocal)
            var targetWorld = [Quat](repeating: .identity, count: target.joints.count)
            for i in target.joints.indices {
                let parentWorld = target.parentIndex(i).map { targetWorld[$0] } ?? .identity
                if let s = match[i] { targetWorld[i] = (sourceWorld[s] * delta[i]).normalized }
                else { targetWorld[i] = parentWorld }
                // Local = parent⁻¹ · own: the parent's correction is not applied twice.
                let local = (parentWorld.conjugate * targetWorld[i]).normalized
                rotations[i].append(local)
            }
        }
        // Store only joints that move (or that the motion drove); identity tracks are dropped.
        for (i, j) in target.joints.enumerated() {
            let keys = rotations[i]
            guard keys.contains(where: { $0.angle > 1e-4 }) || report.mapped.contains(j.jointID) else { continue }
            out.tracks.append(JointTrack(joint: j.jointID, times: sorted, rotations: keys))
        }
        // Bind corrections at time zero are the A/T-pose difference; say so.
        if report.bindCorrection > 20 {
            report.notes.append(L10n.t("两套骨骼的绑定姿态不同（最大相差 \(Int(report.bindCorrection))°），已按骨骼方向换算。",
                                       "The two bind poses differ (up to \(Int(report.bindCorrection))°); bones were matched by direction."))
        }
        if !report.missingInTarget.isEmpty {
            report.notes.append(L10n.t("目标骨骼缺少 \(report.missingInTarget.count) 个关节，这些关节的动作被略过。", "The target has no \(report.missingInTarget.count) of the joints; their motion is skipped."))
        }
        return (out, report)
    }
}

// MARK: Inverse kinematics

enum CharacterIK {
    /// Two-bone IK (hip–knee–ankle, shoulder–elbow–wrist). World positions in;
    /// world-space deltas out, applied in order: `root` turns the whole chain,
    /// then `mid` turns the lower bone (already moved by `root`). The middle
    /// joint bends toward `pole`. Nil when the chain is degenerate.
    static func twoBone(root a: SIMD3<Float>, mid b: SIMD3<Float>, end c: SIMD3<Float>, target t: SIMD3<Float>, pole: SIMD3<Float>) -> (root: Quat, mid: Quat)? {
        let l1 = cLength(b - a), l2 = cLength(c - b)
        guard l1 > 1e-5, l2 > 1e-5, cFinite(t), cFinite(pole) else { return nil }
        let toTarget = t - a
        let distance = cLength(toTarget)
        guard distance > 1e-5 else { return nil }
        let reach = min(max(distance, abs(l1 - l2) + 1e-4), l1 + l2 - 1e-4)
        let d = toTarget / distance
        // The bend plane: target direction and the pole, made perpendicular.
        var side = (pole - a) - d * cDot(pole - a, d)
        if cLength(side) < 1e-5 { side = (b - a) - d * cDot(b - a, d) }
        if cLength(side) < 1e-5 { return nil }
        side = cUnit(side)
        let cosA = min(1, max(-1, (l1 * l1 + reach * reach - l2 * l2) / (2 * l1 * reach)))
        let knee = a + d * (l1 * cosA) + side * (l1 * (1 - cosA * cosA).squareRoot())
        let end = a + d * reach
        let rootDelta = Quat.between(b - a, knee - a)
        // The upper bone may also twist; the lower bone is aimed from where root left it.
        let lowerNow = rootDelta.rotate(c - b)
        let midDelta = Quat.between(lowerNow, end - knee)
        guard rootDelta.finite, midDelta.finite else { return nil }
        return (rootDelta, midDelta)
    }

    /// Applies world-space deltas to a sample's local rotations (rest rotations identity).
    static func applying(_ sample: MotionSample, skeleton: SkeletonDefinition, deltas: [(joint: Int, world: Quat)]) -> MotionSample {
        var out = sample
        var local = skeleton.joints.map { sample.rotations[$0.jointID] ?? sample.rotations[MotionRetargeter.key($0)] ?? .identity }
        for (j, d) in deltas {
            let world = MotionRetargeter.worldRotations(skeleton, local)
            let parent = skeleton.parentIndex(j).map { world[$0] } ?? .identity
            local[j] = (parent.conjugate * d * world[j]).normalized
        }
        for (i, joint) in skeleton.joints.enumerated() where local[i] != .identity || out.rotations[joint.jointID] != nil { out.rotations[joint.jointID] = local[i] }
        return out
    }

    /// Feet on the ground: each foot whose ankle is within `reach` of where the
    /// ground wants it is moved there by two-bone IK. Returns the sample
    /// unchanged when a leg cannot do it within its joint limits.
    static func plantFeet(_ sample: MotionSample, skeleton: SkeletonDefinition, ground: (SIMD3<Float>) -> Float?, reach: Float = 0.25) -> MotionSample {
        var out = sample
        let bindAnkle = skeleton.position(.rightFoot)?.y ?? 0.08
        for side in ["right", "left"] {
            guard let hip = skeleton.index(JointTag(rawValue: side + "Thigh") ?? .other), let knee = skeleton.index(JointTag(rawValue: side + "Shin") ?? .other),
                  let ankle = skeleton.index(JointTag(rawValue: side + "Foot") ?? .other) else { continue }
            let p = MotionPose.positions(out, skeleton: skeleton)
            guard let g = ground(p[ankle]) else { continue }
            let want = SIMD3(p[ankle].x, g + bindAnkle, p[ankle].z)
            let gap = want.y - p[ankle].y
            guard abs(gap) > 0.005, abs(gap) < reach else { continue }
            guard let (rootDelta, midDelta) = twoBone(root: p[hip], mid: p[knee], end: p[ankle], target: want, pole: p[knee] + SIMD3(0, 0, 0.3)) else { continue }
            let trial = applying(out, skeleton: skeleton, deltas: [(hip, rootDelta), (knee, midDelta)])
            if withinLimits(trial, skeleton: skeleton, joints: [hip, knee]) { out = trial }
        }
        return out
    }

    /// Head (and a little of the chest) turned toward a point, within limits.
    static func lookAt(_ sample: MotionSample, skeleton: SkeletonDefinition, target: SIMD3<Float>, weight: Float = 1) -> MotionSample {
        guard let head = skeleton.index(.head) else { return sample }
        let p = MotionPose.positions(sample, skeleton: skeleton)
        let world = skeleton.worldTransforms(local: MotionPose.locals(sample, skeleton: skeleton))
        let forward = cUnit(world[head].direction(SIMD3(0, 0, 1)), fallback: SIMD3(0, 0, 1))
        let want = cUnit(target - p[head], fallback: forward)
        let full = Quat.between(forward, want)
        let limited = Quat.slerp(.identity, full, min(1, weight * min(1, (70 * .pi / 180) / max(1e-4, full.angle))))
        let trial = applying(sample, skeleton: skeleton, deltas: [(head, limited)])
        return withinLimits(trial, skeleton: skeleton, joints: [head]) ? trial : sample
    }

    /// Every listed joint's local rotation within its limits (a little slack).
    static func withinLimits(_ sample: MotionSample, skeleton: SkeletonDefinition, joints: [Int], slack: Float = 15) -> Bool {
        for j in joints {
            let q = sample.rotations[skeleton.joints[j].jointID] ?? .identity
            guard q.finite else { return false }
            let limit = skeleton.joints[j].jointLimit
            let reach = (0..<3).map { max(abs(limit.min[$0]), abs(limit.max[$0])) }.max() ?? 180
            if q.angle * 180 / .pi > reach + slack { return false }
        }
        return true
    }
}
