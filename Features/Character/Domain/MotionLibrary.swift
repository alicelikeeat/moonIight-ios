import Foundation

// v1.91: the standard humanoid motion library, authored for the HumanBase
// T-pose bind (right side −x, facing +z, rest rotations identity). Every
// motion is real keyframe data: loops are sampled from a cycle function,
// one-shots from key poses, so they play on any standard rig through
// MotionRetargeter. Axis conventions in the T-pose frame:
//   arm down:      rz(+a) right / rz(−a) left (mirror)
//   arm sweep:     ry(+θ) swings the right arm toward the front
//   elbow bend:    ry(+b) right forearm toward the front
//   leg forward:   rx(−θ) on the thigh; knee bend rx(+b) on the shin
//   lean forward:  rx(+θ) on spine / chest; twist ry; side bend rz

enum MotionLibrary {
    // MARK: Pose helpers

    static func rx(_ d: Float) -> Quat { Quat(axis: SIMD3(1, 0, 0), angle: d * .pi / 180) }
    static func ry(_ d: Float) -> Quat { Quat(axis: SIMD3(0, 1, 0), angle: d * .pi / 180) }
    static func rz(_ d: Float) -> Quat { Quat(axis: SIMD3(0, 0, 1), angle: d * .pi / 180) }
    /// The same rotation for the other side of the body (reflection in x).
    static func mirror(_ q: Quat) -> Quat { Quat(x: q.x, y: -q.y, z: -q.z, w: q.w) }

    struct Pose {
        var r: [String: Quat] = [:]
        /// Leg lengths.
        var root = SIMD3<Float>.zero
        mutating func set(_ joint: String, _ q: Quat) { r[joint] = q }
        /// Right side as given, left side mirrored.
        mutating func both(_ part: String, _ q: Quat) { r["right" + part] = q; r["left" + part] = MotionLibrary.mirror(q) }
        mutating func right(_ part: String, _ q: Quat) { r["right" + part] = q }
        mutating func left(_ part: String, _ rightEquivalent: Quat) { r["left" + part] = MotionLibrary.mirror(rightEquivalent) }
        /// Curls all fingers of one side (degrees per joint), thumb half.
        mutating func fingers(_ side: String, curl: Float) {
            for f in 1...5 { for s in 1...3 {
                let amount = f == 1 ? curl * 0.5 : curl
                let q = MotionLibrary.rz(amount)
                r["ext.\(side)Finger\(f).\(s)"] = side == "right" ? q : MotionLibrary.mirror(q)
            } }
        }
    }

    /// Arms hanging relaxed at the sides.
    static func stand(_ p: inout Pose, armDown: Float = 72, elbow: Float = 12) {
        p.both("UpperArm", rz(armDown))
        p.both("Forearm", ry(elbow))
        p.fingers("right", curl: 14); p.fingers("left", curl: 14)
    }
    /// A hanging arm swung forward (+) or back (−), lowered by `down`.
    static func swingArm(_ forward: Float, down: Float = 72) -> Quat { rx(-forward) * rz(down) }

    static func build(_ id: String, _ name: String, duration: Float, loop: Bool, keys: Int, mask: MotionMask = .fullBody, interrupt: UniversalMotion.Interrupt = .anytime,
                      priority: Int = 0, tags: [String], phases: MotionPhases? = nil, events: [MotionEvent] = [], rootMotion: SIMD3<Float>? = nil,
                      _ f: (Float) -> Pose) -> UniversalMotion {
        let count = max(2, keys)
        let times = (0..<count).map { Float($0) / Float(count - 1) * duration }
        let poses = times.map { f($0 / duration) }
        var joints = Set<String>()
        for p in poses { joints.formUnion(p.r.keys) }
        var motion = UniversalMotion(id: id, name: name, tags: tags, bind: .tPose, duration: duration, loop: loop, source: .authored)
        motion.tracks = joints.sorted().map { j in JointTrack(joint: j, times: times, rotations: poses.map { $0.r[j] ?? .identity }) }
        if poses.contains(where: { $0.root != .zero }) { motion.root = RootTrack(times: times, offsets: poses.map(\.root)) }
        motion.mask = mask; motion.interrupt = interrupt; motion.priority = priority
        motion.phases = phases; motion.events = events; motion.rootMotion = rootMotion
        return motion
    }

    static func smooth(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
    /// 0 → 1 → 0 bump over [a, b].
    static func bump(_ x: Float, _ a: Float, _ b: Float) -> Float { x <= a || x >= b ? 0 : sin(.pi * (x - a) / (b - a)) }
    /// Piecewise-linear through (x, y) keys.
    static func keys(_ x: Float, _ pts: [(Float, Float)]) -> Float {
        guard let first = pts.first, let last = pts.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for (a, b) in zip(pts, pts.dropFirst()) where x <= b.0 { return a.1 + (b.1 - a.1) * smooth((x - a.0) / max(1e-5, b.0 - a.0)) }
        return last.1
    }

    // MARK: Locomotion

    static func gait(_ phase: Float, stride: Float, knee: Float, arm: Float, elbow: Float, lean: Float, bob: Float, backward: Bool = false) -> Pose {
        var p = Pose()
        stand(&p, elbow: elbow)
        let ph = backward ? 1 - phase : phase
        let s = sin(2 * .pi * ph)
        p.right("Thigh", rx(-stride * s - lean * 0.3)); p.left("Thigh", mirror(rx(stride * s - lean * 0.3)))
        // The knee bends while that leg swings forward.
        let kneeR = 6 + knee * max(0, sin(2 * .pi * (ph + 0.15))), kneeL = 6 + knee * max(0, sin(2 * .pi * (ph + 0.65)))
        p.right("Shin", rx(kneeR)); p.left("Shin", mirror(rx(kneeL)))
        p.right("Foot", rx(-0.3 * kneeR + 4 * s)); p.left("Foot", mirror(rx(-0.3 * kneeL - 4 * s)))
        // Arms opposite to the legs.
        p.right("UpperArm", swingArm(-arm * s)); p.left("UpperArm", swingArm(arm * s))
        p.set("spine", rx(lean) * ry(5 * s)); p.set("chest", ry(-6 * s)); p.set("head", ry(2 * s))
        p.root = SIMD3(0, -bob + bob * cos(4 * .pi * ph), 0)
        return p
    }

    static func strafe(_ phase: Float, toRight: Bool) -> Pose {
        var p = Pose()
        stand(&p)
        let s = sin(2 * .pi * phase), lead: Float = toRight ? 1 : -1
        // Legs open and close sideways; rz(−) takes the right leg out to −x.
        p.right("Thigh", rz(-lead * (6 + 12 * max(0, s)))); p.left("Thigh", mirror(rz(lead * (6 + 12 * max(0, -s)))))
        p.right("Shin", rx(8 + 22 * max(0, s))); p.left("Shin", mirror(rx(8 + 22 * max(0, -s))))
        p.set("spine", rz(-lead * 3)); p.set("chest", ry(lead * 8))
        p.root = SIMD3(0, -0.02 + 0.015 * cos(4 * .pi * phase), 0)
        return p
    }

    // MARK: The library

    static let standard: [UniversalMotion] = {
        var all: [UniversalMotion] = []
        all.append(build("idle", L10n.t("待机", "Idle"), duration: 3, loop: true, keys: 25, tags: ["base"]) { x in
            var p = Pose(); stand(&p, armDown: 72 + 2 * sin(2 * .pi * x))
            p.set("chest", rx(1.5 * sin(2 * .pi * x))); p.set("head", rz(2 * sin(2 * .pi * x + 0.6)))
            p.root = SIMD3(0, 0.004 * sin(4 * .pi * x), 0)
            return p
        })
        all.append(build("walk", L10n.t("行走", "Walk"), duration: 1.05, loop: true, keys: 25, tags: ["base", "locomotion"], rootMotion: SIMD3(0, 0, 1.7)) {
            gait($0, stride: 26, knee: 34, arm: 18, elbow: 14, lean: 3, bob: 0.018)
        })
        all.append(build("walkBack", L10n.t("后退", "Walk Back"), duration: 1.15, loop: true, keys: 25, tags: ["locomotion"], rootMotion: SIMD3(0, 0, -1.3)) {
            gait($0, stride: 20, knee: 28, arm: 12, elbow: 14, lean: -2, bob: 0.015, backward: true)
        })
        all.append(build("run", L10n.t("奔跑", "Run"), duration: 0.68, loop: true, keys: 25, tags: ["base", "locomotion"], rootMotion: SIMD3(0, 0, 3.6)) {
            gait($0, stride: 42, knee: 78, arm: 38, elbow: 85, lean: 12, bob: 0.045)
        })
        all.append(build("strafeRight", L10n.t("右侧移", "Strafe Right"), duration: 0.9, loop: true, keys: 21, tags: ["locomotion"], rootMotion: SIMD3(-1.4, 0, 0)) { strafe($0, toRight: true) })
        all.append(build("strafeLeft", L10n.t("左侧移", "Strafe Left"), duration: 0.9, loop: true, keys: 21, tags: ["locomotion"], rootMotion: SIMD3(1.4, 0, 0)) { strafe($0, toRight: false) })
        all.append(build("turn", L10n.t("原地转身", "Turn"), duration: 0.8, loop: true, keys: 17, tags: ["locomotion"]) { x in
            var p = gait(x, stride: 8, knee: 18, arm: 4, elbow: 12, lean: 0, bob: 0.008)
            p.set("spine", ry(10 * sin(2 * .pi * x)))
            return p
        })
        all.append(build("jumpStart", L10n.t("起跳", "Jump Start"), duration: 0.24, loop: false, keys: 9, interrupt: .afterCancel, priority: 1, tags: ["air"],
                         phases: MotionPhases(activeStart: 0.16, hit: 0.16, activeEnd: 0.24, cancelFrom: 0.16, end: 0.24)) { x in
            var p = Pose(); stand(&p)
            let c = keys(x, [(0, 0), (0.6, 1), (1, 0.3)])
            p.both("Thigh", rx(-35 * c)); p.both("Shin", rx(60 * c)); p.both("Foot", rx(-25 * c))
            p.right("UpperArm", swingArm(-35 * c)); p.left("UpperArm", swingArm(-35 * c))
            p.set("spine", rx(18 * c)); p.root = SIMD3(0, -0.16 * c, 0)
            return p
        })
        all.append(build("jumpAir", L10n.t("空中", "In the Air"), duration: 0.8, loop: true, keys: 13, tags: ["air"]) { x in
            var p = Pose(); stand(&p, armDown: 45, elbow: 30)
            let k = 0.85 + 0.15 * sin(2 * .pi * x)
            p.right("Thigh", rx(-30 * k)); p.left("Thigh", mirror(rx(-12 * k)))
            p.right("Shin", rx(55 * k)); p.left("Shin", mirror(rx(30 * k)))
            p.set("spine", rx(4))
            return p
        })
        all.append(build("land", L10n.t("落地", "Land"), duration: 0.32, loop: false, keys: 9, interrupt: .afterCancel, priority: 1, tags: ["air"],
                         phases: MotionPhases(activeStart: 0, hit: 0.05, activeEnd: 0.12, cancelFrom: 0.15, end: 0.32)) { x in
            var p = Pose(); stand(&p, armDown: keys(x, [(0, 45), (1, 72)]))
            let c = keys(x, [(0, 0.4), (0.25, 1), (1, 0)])
            p.both("Thigh", rx(-30 * c)); p.both("Shin", rx(55 * c)); p.both("Foot", rx(-22 * c))
            p.set("spine", rx(15 * c)); p.root = SIMD3(0, -0.14 * c, 0)
            return p
        })
        all.append(build("dodge", L10n.t("闪避", "Dodge"), duration: 0.42, loop: false, keys: 11, interrupt: .afterCancel, priority: 2, tags: ["defense"],
                         phases: MotionPhases(activeStart: 0, hit: 0.05, activeEnd: 0.35, cancelFrom: 0.3, end: 0.42),
                         events: [MotionEvent(id: "dodge.invulnerableStart", time: 0, kind: .activeStart), MotionEvent(id: "dodge.invulnerableEnd", time: 0.35, kind: .activeEnd)]) { x in
            var p = Pose(); stand(&p, armDown: 50, elbow: 40)
            let c = keys(x, [(0, 0), (0.25, 1), (0.8, 0.8), (1, 0)])
            p.set("spine", rx(25 * c) * rz(-10 * c)); p.set("chest", rx(10 * c))
            p.both("Thigh", rx(-40 * c)); p.both("Shin", rx(70 * c))
            p.root = SIMD3(0, -0.25 * c, 0)
            return p
        })
        all.append(build("roll", L10n.t("翻滚", "Roll"), duration: 0.62, loop: false, keys: 17, interrupt: .afterCancel, priority: 2, tags: ["defense"],
                         phases: MotionPhases(activeStart: 0, hit: 0.05, activeEnd: 0.5, cancelFrom: 0.5, end: 0.62),
                         events: [MotionEvent(id: "roll.invulnerableStart", time: 0, kind: .activeStart), MotionEvent(id: "roll.invulnerableEnd", time: 0.5, kind: .activeEnd)]) { x in
            var p = Pose(); stand(&p, armDown: 30, elbow: 90)
            let tuck = bump(x, 0, 1)
            // A full forward turn about the hips, tucked tight in the middle.
            p.set("pelvis", rx(360 * smooth(x)))
            p.both("Thigh", rx(-100 * tuck)); p.both("Shin", rx(125 * tuck))
            p.set("spine", rx(45 * tuck)); p.set("chest", rx(25 * tuck)); p.set("neck", rx(30 * tuck))
            p.root = SIMD3(0, -0.55 * tuck, 0)
            return p
        })
        all.append(build("hurt", L10n.t("受击", "Hurt"), duration: 0.36, loop: false, keys: 9, interrupt: .afterCancel, priority: 3, tags: ["state"],
                         phases: MotionPhases(activeStart: 0, hit: 0, activeEnd: 0.2, cancelFrom: 0.22, end: 0.36)) { x in
            var p = Pose(); stand(&p, armDown: keys(x, [(0, 72), (0.3, 45), (1, 72)]), elbow: 30)
            let c = keys(x, [(0, 0), (0.2, 1), (1, 0)])
            p.set("spine", rx(-12 * c)); p.set("chest", rx(-8 * c)); p.set("head", rx(-14 * c))
            p.both("Shin", rx(15 * c)); p.root = SIMD3(0, -0.04 * c, 0)
            return p
        })
        all.append(build("stagger", L10n.t("硬直", "Stagger"), duration: 0.65, loop: false, keys: 13, interrupt: .afterCancel, priority: 3, tags: ["state"],
                         phases: MotionPhases(activeStart: 0, hit: 0, activeEnd: 0.5, cancelFrom: 0.55, end: 0.65)) { x in
            var p = Pose(); stand(&p, armDown: 40, elbow: 35)
            let c = keys(x, [(0, 0), (0.25, 1), (0.6, 0.8), (1, 0)])
            p.set("spine", rx(-18 * c) * rz(8 * c * sin(6 * x))); p.set("head", rx(-20 * c))
            p.right("Thigh", rx(15 * c)); p.both("Shin", rx(25 * c)); p.root = SIMD3(0, -0.08 * c, 0)
            return p
        })
        func fall(_ id: String, _ name: String, duration: Float, interrupt: UniversalMotion.Interrupt, priority: Int, tags: [String]) -> UniversalMotion {
            build(id, name, duration: duration, loop: false, keys: 17, interrupt: interrupt, priority: priority, tags: tags,
                  phases: MotionPhases(activeStart: 0, hit: 0, activeEnd: duration * 0.7, cancelFrom: duration, end: duration),
                  events: [MotionEvent(id: id + ".ground", time: duration * 0.62, kind: .effect)]) { x in
                var p = Pose(); stand(&p, armDown: keys(x, [(0, 72), (0.5, 30), (1, 10)]), elbow: 20)
                let c = keys(x, [(0, 0), (0.62, 1), (1, 1)])
                // Falls backward onto the back; the legs end along the ground.
                p.set("pelvis", rx(-85 * c)); p.both("Thigh", rx(-10 * c)); p.both("Shin", rx(30 * bump(x, 0, 0.7)))
                p.set("spine", rx(-5 * c)); p.set("head", rx(15 * c))
                p.root = SIMD3(0, -0.78 * c, -0.1 * c)
                return p
            }
        }
        all.append(fall("knockdown", L10n.t("倒地", "Knocked Down"), duration: 1.1, interrupt: .afterCancel, priority: 4, tags: ["state"]))
        all.append(fall("death", L10n.t("死亡", "Death"), duration: 1.3, interrupt: .never, priority: 9, tags: ["state"]))

        // Three-hit combo, right hand. Hit moments are the damage moments.
        all.append(build("attack1", L10n.t("普攻一段", "Attack 1"), duration: 0.5, loop: false, keys: 13, mask: .upperBody, interrupt: .afterCancel, priority: 2, tags: ["combat", "combo"],
                         phases: MotionPhases(activeStart: 0.14, hit: 0.2, activeEnd: 0.28, cancelFrom: 0.3, end: 0.5),
                         events: [MotionEvent(id: "attack1.hit", time: 0.2, kind: .hit), MotionEvent(id: "attack1.cancel", time: 0.3, kind: .cancelOpen)]) { x in
            var p = Pose(); stand(&p)
            let sweep = keys(x, [(0, -10), (0.28, -35), (0.42, 105), (1, 40)])
            p.right("UpperArm", ry(sweep) * rz(15)); p.right("Forearm", ry(keys(x, [(0, 40), (0.3, 70), (0.45, 10), (1, 25)])))
            p.fingers("right", curl: 70)
            p.set("chest", ry(keys(x, [(0, 0), (0.28, -20), (0.45, 25), (1, 5)])))
            return p
        })
        all.append(build("attack2", L10n.t("普攻二段", "Attack 2"), duration: 0.5, loop: false, keys: 13, mask: .upperBody, interrupt: .afterCancel, priority: 2, tags: ["combat", "combo"],
                         phases: MotionPhases(activeStart: 0.12, hit: 0.18, activeEnd: 0.27, cancelFrom: 0.3, end: 0.5),
                         events: [MotionEvent(id: "attack2.hit", time: 0.18, kind: .hit), MotionEvent(id: "attack2.cancel", time: 0.3, kind: .cancelOpen)]) { x in
            var p = Pose(); stand(&p)
            let sweep = keys(x, [(0, 40), (0.24, 115), (0.4, -30), (1, -5)])
            p.right("UpperArm", ry(sweep) * rz(keys(x, [(0, 15), (0.24, -5), (0.4, 10), (1, 25)]))); p.right("Forearm", ry(keys(x, [(0, 25), (0.24, 60), (0.4, 8), (1, 20)])))
            p.fingers("right", curl: 70)
            p.set("chest", ry(keys(x, [(0, 5), (0.24, 25), (0.4, -25), (1, 0)])))
            return p
        })
        all.append(build("attack3", L10n.t("普攻三段", "Attack 3"), duration: 0.75, loop: false, keys: 17, interrupt: .afterCancel, priority: 2, tags: ["combat", "combo"],
                         phases: MotionPhases(activeStart: 0.34, hit: 0.42, activeEnd: 0.5, cancelFrom: 0.55, end: 0.75),
                         events: [MotionEvent(id: "attack3.hit", time: 0.42, kind: .hit), MotionEvent(id: "attack3.cancel", time: 0.55, kind: .cancelOpen)]) { x in
            var p = Pose(); stand(&p)
            // Both hands raised overhead, then brought down in front.
            let raise = keys(x, [(0, 0), (0.35, 1), (0.56, 1), (1, 0)])
            let chop = keys(x, [(0, 0), (0.35, 0), (0.52, 1), (0.75, 1), (1, 0)])
            let arm = rx(110 * chop) * rz(72 - 150 * raise)
            p.right("UpperArm", arm); p.left("UpperArm", arm)
            p.both("Forearm", ry(keys(x, [(0, 12), (0.35, 35), (0.5, 5), (1, 12)])))
            p.fingers("right", curl: 70); p.fingers("left", curl: 70)
            p.set("spine", rx(keys(x, [(0, 0), (0.35, -12), (0.52, 22), (1, 0)])))
            p.both("Thigh", rx(-18 * chop)); p.both("Shin", rx(32 * chop)); p.root = SIMD3(0, -0.09 * chop, 0)
            return p
        })
        all.append(build("charge", L10n.t("蓄力", "Charge"), duration: 0.8, loop: true, keys: 17, priority: 1, tags: ["skill"]) { x in
            var p = Pose(); stand(&p)
            let tremble = 1.5 * sin(2 * .pi * 6 * x)
            p.right("UpperArm", ry(-30) * rz(55 + tremble)); p.left("UpperArm", ry(-30) * rz(55 - tremble))
            p.both("Forearm", ry(80)); p.fingers("right", curl: 50); p.fingers("left", curl: 50)
            p.both("Thigh", rx(-20)); p.both("Shin", rx(35)); p.set("spine", rx(14)); p.root = SIMD3(0, -0.07, 0)
            return p
        })
        all.append(build("cast", L10n.t("施法", "Cast"), duration: 0.7, loop: false, keys: 15, mask: .upperBody, interrupt: .afterCancel, priority: 2, tags: ["skill"],
                         phases: MotionPhases(activeStart: 0.25, hit: 0.34, activeEnd: 0.45, cancelFrom: 0.5, end: 0.7),
                         events: [MotionEvent(id: "cast.release", time: 0.34, kind: .hit)]) { x in
            var p = Pose(); stand(&p)
            let push = keys(x, [(0, 0), (0.25, 0.4), (0.38, 1), (0.7, 1), (1, 0)])
            let bend = keys(x, [(0, 12), (0.25, 95), (0.38, 5), (1, 12)])
            p.both("UpperArm", ry(90 * push) * rz(72 * (1 - push) + 5 * push)); p.both("Forearm", ry(bend))
            p.fingers("right", curl: 5); p.fingers("left", curl: 5)
            p.set("spine", rx(keys(x, [(0, 0), (0.25, -6), (0.38, 8), (1, 0)])))
            return p
        })
        all.append(build("skillRelease", L10n.t("技能释放", "Skill Release"), duration: 0.6, loop: false, keys: 15, interrupt: .afterCancel, priority: 2, tags: ["skill"],
                         phases: MotionPhases(activeStart: 0.2, hit: 0.3, activeEnd: 0.4, cancelFrom: 0.45, end: 0.6),
                         events: [MotionEvent(id: "skill.release", time: 0.3, kind: .hit)]) { x in
            var p = Pose(); stand(&p)
            let up = keys(x, [(0, 0), (0.25, 1), (0.4, 0.2), (1, 0)])
            p.both("UpperArm", rz(72 - 160 * up)); p.both("Forearm", ry(10))
            p.fingers("right", curl: 0); p.fingers("left", curl: 0)
            p.set("spine", rx(keys(x, [(0, 0), (0.25, -10), (0.45, 15), (1, 0)])))
            p.both("Thigh", rx(-15 * (1 - up) * bump(x, 0.3, 1))); p.both("Shin", rx(28 * bump(x, 0.3, 1)))
            p.root = SIMD3(0, 0.05 * bump(x, 0.1, 0.35) - 0.07 * bump(x, 0.35, 1), 0)
            return p
        })
        all.append(build("weaponHold", L10n.t("持握武器", "Weapon Ready"), duration: 2, loop: true, keys: 17, mask: .upperBody, tags: ["equipment"]) { x in
            var p = Pose(); stand(&p)
            p.right("UpperArm", ry(25) * rz(62 + 2 * sin(2 * .pi * x))); p.right("Forearm", ry(68)); p.fingers("right", curl: 72)
            p.set("chest", rx(1.5 * sin(2 * .pi * x)))
            return p
        })
        all.append(build("equip", L10n.t("装备切换", "Equip"), duration: 0.6, loop: false, keys: 13, mask: .upperBody, interrupt: .afterCancel, priority: 1, tags: ["equipment"],
                         phases: MotionPhases(activeStart: 0.2, hit: 0.3, activeEnd: 0.35, cancelFrom: 0.45, end: 0.6),
                         events: [MotionEvent(id: "equip.swap", time: 0.3, kind: .effect)]) { x in
            var p = Pose(); stand(&p)
            let reach = keys(x, [(0, 0), (0.3, 1), (0.6, 0.4), (1, 0)])
            p.right("UpperArm", ry(25 * (1 - reach) - 20 * reach) * rz(62 - 120 * reach)); p.right("Forearm", ry(68 + 60 * reach))
            p.fingers("right", curl: 30 + 40 * reach)
            p.set("chest", ry(-15 * reach)); p.set("head", ry(-20 * reach))
            return p
        })
        all.append(build("interact", L10n.t("互动", "Interact"), duration: 0.8, loop: false, keys: 13, mask: .upperBody, interrupt: .afterCancel, priority: 1, tags: ["base"],
                         phases: MotionPhases(activeStart: 0.3, hit: 0.4, activeEnd: 0.5, cancelFrom: 0.5, end: 0.8),
                         events: [MotionEvent(id: "interact.touch", time: 0.4, kind: .hit)]) { x in
            var p = Pose(); stand(&p)
            let reach = bump(x, 0.1, 0.95)
            p.right("UpperArm", ry(80 * reach) * rz(72 - 40 * reach)); p.right("Forearm", ry(12 + 10 * reach)); p.set("spine", rx(10 * reach))
            return p
        })
        return all
    }()

    static func motion(_ id: String) -> UniversalMotion? { standard.first { $0.id == id } }

    /// The motion a world action plays (the combo step picks the attack).
    static func id(for action: CharacterAction, combo: Int = 1, moving: Bool = false) -> String {
        switch action {
        case .idle: "idle"
        case .walk: "walk"
        case .run: "run"
        case .jump: "jumpStart"
        case .fall: "jumpAir"
        case .attack: "attack\(min(3, max(1, combo)))"
        case .skill: "cast"
        case .dodge: moving ? "roll" : "dodge"
        case .hurt: "hurt"
        case .death: "death"
        case .interact: "interact"
        case .transform: "skillRelease"
        }
    }
}
