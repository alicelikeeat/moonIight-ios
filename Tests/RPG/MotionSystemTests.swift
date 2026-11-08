import Foundation

/// Unified motion: the library, adapters, retargeting, the controller, IK.
func motionSystemTests() {
    let library = MotionLibrary.standard
    let required = ["idle", "walk", "walkBack", "run", "strafeLeft", "strafeRight", "turn", "jumpStart", "jumpAir", "land", "dodge", "roll", "hurt", "stagger",
                    "knockdown", "death", "attack1", "attack2", "attack3", "charge", "cast", "skillRelease", "weaponHold", "equip"]
    check(required.allSatisfy { id in library.contains { $0.id == id } }, "motion: the library has every standard motion (\(library.count))")
    check(library.allSatisfy(\.valid) && Set(library.map(\.id)).count == library.count, "motion: every motion is valid and has its own id")
    check(library.allSatisfy { m in m.tracks.allSatisfy { $0.times.count >= 2 } } && library.filter { !$0.tracks.isEmpty }.count == library.count,
          "motion: every motion is keyframe data, not a name")
    let eventIDs = library.flatMap { $0.events.map(\.id) }
    check(Set(eventIDs).count == eventIDs.count, "motion: event ids are unique across the library")
    for id in ["attack1", "attack2", "attack3", "cast", "skillRelease"] {
        guard let m = MotionLibrary.motion(id), let ph = m.phases else { check(false, "motion: \(id) has combat phases"); continue }
        check(ph.valid && ph.phase(at: 0) == .windup && ph.phase(at: ph.hit) == .active && ph.phase(at: ph.end) == .done && m.events.contains { $0.kind == .hit && abs($0.time - ph.hit) < 1e-4 },
              "motion: \(id) has wind-up, active, recovery phases and its hit event at the hit moment")
    }

    // On the real body: arms hang at idle, the walk alternates the feet, the slash goes across the front.
    guard let body = HumanBase.build(.standard) else { check(false, "motion: HumanBase available"); return }
    let sk = body.skeleton
    func at(_ id: String, _ t: Float) -> [SIMD3<Float>] { MotionPose.positions(MotionLibrary.motion(id)!.sample(at: t, legLength: MotionPose.legLength(sk)), skeleton: sk) }
    let r = { (tag: JointTag) in sk.index(tag)! }
    let idle = at("idle", 0.5)
    check(idle[r(.rightHand)].y < idle[r(.rightUpperArm)].y - 0.35 && idle[r(.leftHand)].y < idle[r(.leftUpperArm)].y - 0.35, "motion: idle arms hang at the sides")
    let walkA = at("walk", 0.26), walkB = at("walk", 0.79)
    check(walkA[r(.rightFoot)].z - walkA[r(.leftFoot)].z > 0.15 && walkB[r(.leftFoot)].z - walkB[r(.rightFoot)].z > 0.15,
          "motion: the walk puts the right foot ahead, then the left (\(walkA[r(.rightFoot)].z - walkA[r(.leftFoot)].z))")
    let windup = at("attack1", 0.12), hit = at("attack1", 0.21)
    check(hit[r(.rightHand)].z > windup[r(.rightHand)].z + 0.3, "motion: the first slash sweeps the hand to the front by the hit")
    let slam = at("attack3", 0.45)
    check(slam[r(.rightHand)].z > 0.3 && slam[r(.rightHand)].y < slam[r(.head)].y, "motion: the third hit brings both hands down in front")
    let dead = at("death", 1.3)
    check(dead[r(.pelvis)].y < 0.35 && dead[r(.head)].y < 0.5, "motion: death ends lying on the ground (pelvis \(dead[r(.pelvis)].y) m)")
    let rolled = at("roll", 0.62), rollMid = at("roll", 0.31)
    check(rolled[r(.head)].y > 1.4 && rollMid[r(.head)].y < 1.0, "motion: the roll tucks low and comes back upright")
    var finite = true
    for m in library { for t in stride(from: Float(0), through: m.duration, by: m.duration / 6) {
        let mats = MotionPose.skinning(m.sample(at: t, legLength: 0.9), skeleton: sk)
        let moved = SkinWeightSolver.deform(body.mesh, skin: body.skin, matrices: mats)
        if !moved.positions.allSatisfy(\.isFinite) { finite = false }
    } }
    check(finite, "motion: every library motion deforms the HumanBase body to finite positions")

    // The same motions on three different bodies.
    for shape in [HumanShape.tall, .chibi] {
        guard let other = HumanBase.build(shape) else { continue }
        let p = MotionPose.positions(MotionLibrary.motion("idle")!.sample(at: 0.5), skeleton: other.skeleton)
        let s = other.skeleton
        check(p[s.index(.rightHand)!].y < p[s.index(.rightUpperArm)!].y - 0.15, "motion: idle arms hang on the \(shape.height) m body too")
    }

    // Retargeting T-pose motions onto an A-pose 27-joint rig (the older base body).
    let aBody = BaseBody.build(.standard)
    if let idleMotion = MotionLibrary.motion("idle"), let walkMotion = MotionLibrary.motion("walk") {
        let (onA, report) = MotionRetargeter.retarget(idleMotion, from: sk, to: aBody.skeleton)
        let pa = MotionPose.positions(onA.sample(at: 0.5), skeleton: aBody.skeleton)
        let s = aBody.skeleton
        let handDown = cUnit(pa[s.index(.rightHand)!] - pa[s.index(.rightUpperArm)!])
        let srcDown = cUnit(idle[r(.rightHand)] - idle[r(.rightUpperArm)])
        check(cDot(handDown, srcDown) > 0.95, "motion: retargeted idle hangs the A-pose rig's arms the same way (cos \(cDot(handDown, srcDown)))")
        check(report.bindCorrection > 30 && report.missingInTarget.contains { $0.hasPrefix("ext.") } && report.coverage < 1 && report.coverage > 0,
              "motion: the report names the bind difference (\(Int(report.bindCorrection))°) and the joints the rig lacks")
        let (walkOnA, _) = MotionRetargeter.retarget(walkMotion, from: sk, to: s)
        let w = MotionPose.positions(walkOnA.sample(at: 0.26, legLength: MotionPose.legLength(s)), skeleton: s)
        check(w[s.index(.rightFoot)!].z - w[s.index(.leftFoot)!].z > 0.1, "motion: the retargeted walk still steps right foot forward")
        // Same bind: retargeting changes nothing.
        let (same, _) = MotionRetargeter.retarget(walkMotion, from: sk, to: sk)
        let a = MotionPose.positions(walkMotion.sample(at: 0.4), skeleton: sk), b = MotionPose.positions(same.sample(at: 0.4), skeleton: sk)
        check(zip(a, b).allSatisfy { cLength($0 - $1) < 0.005 }, "motion: retargeting onto the same skeleton keeps the motion")
    }

    // Adapters: the older sine clips and the 10-bone rig clips play through the same interface.
    if let oldWalk = MotionClip.standard("walk") {
        let converted = MotionAdapters.from(oldWalk)
        let s = aBody.skeleton
        let viaOld = s.worldTransforms(local: { () -> [RigXform] in
            let pose = oldWalk.pose(s, at: 0.3)
            return s.joints.indices.map { s.joints[$0].rest * RigXform.euler(pose.rotations[$0] * (.pi / 180)) }
        }()).map(\.origin)
        let viaNew = MotionPose.positions(converted.sample(at: 0.3, legLength: 0), skeleton: s)
        check(zip(viaOld, viaNew).allSatisfy { cLength($0 - $1) < 0.01 }, "motion: a converted MotionClip poses the rig exactly like the original")
    }
    let rigWave = RigClip(id: "wave", name: "Wave", period: 1.2, channels: [.init(bone: .rightUpperArm, axis: [0, 0, 1], amplitude: 0.4), .init(bone: .torso, axis: [0, 1, 0], amplitude: 0.1)])
    let fromRig = MotionAdapters.from(rigWave)
    check(fromRig.valid && Set(fromRig.tracks.map(\.joint)) == ["rightUpperArm", "spine1"] && fromRig.source == .rig10, "motion: a 10-bone RigClip maps onto the standard joints")
    let picture = MotionAdapters.timing(of: ActionClip(bindingIDs: ["a"], speed: 2, loop: false, eventTime: 0.4, length: 0.8), action: .attack)
    check(abs(picture.duration - 0.4) < 1e-4 && picture.events.first?.kind == .hit && abs((picture.phases?.hit ?? 0) - 0.2) < 1e-4, "motion: picture clip timing becomes phases and a hit event")

    // Controller: events once, whatever the frame rate.
    func play(fps: Double, seconds: Double, combo: Int = 1) -> [String] {
        var c = CharacterAnimationController(legLength: 0.9)
        var keys: [String] = []
        var t = 0.0
        while t <= seconds {
            let out = c.update(AnimationInput(speed: 0, action: t < 0.5 ? .attack : .idle, actionStarted: 0, combo: combo, clock: t))
            keys += out.events.map(\.key)
            // Re-evaluating the same moment adds nothing.
            keys += c.update(AnimationInput(speed: 0, action: t < 0.5 ? .attack : .idle, actionStarted: 0, combo: combo, clock: t)).events.map(\.key)
            t += 1 / fps
        }
        return keys
    }
    let fast = play(fps: 60, seconds: 0.6), slow = play(fps: 7, seconds: 0.6)
    check(fast == slow && fast.filter { $0.hasSuffix("#attack1.hit") }.count == 1, "motion: the hit fires exactly once at 60 and at 7 updates a second (\(fast), \(slow))")
    check(play(fps: 30, seconds: 0.8, combo: 3).contains { $0.hasSuffix("#attack3.hit") }, "motion: combo step 3 plays the third attack")
    // Upper-body attack while running keeps the legs running.
    var c = CharacterAnimationController(legLength: MotionPose.legLength(sk))
    var lastFeet: Float = 0, legsMoved = false
    for i in 0..<30 {
        let pose = c.update(AnimationInput(speed: c.runSpeed, action: .attack, actionStarted: 0, combo: 1, clock: Double(i) / 60)).pose
        let p = MotionPose.positions(pose, skeleton: sk)
        let feet = p[r(.rightFoot)].z - p[r(.leftFoot)].z
        if i > 0 && abs(feet - lastFeet) > 0.004 { legsMoved = true }
        lastFeet = feet
    }
    check(legsMoved, "motion: attacking while running keeps the legs running (upper-body layer)")
    let w0 = c.locomotionWeights(0), w1 = c.locomotionWeights(c.walkSpeed), w2 = c.locomotionWeights(c.runSpeed * 2)
    check(w0.idle == 1 && abs(w1.walk - 1) < 1e-3 && w2.run == 1, "motion: idle, walk and run weights by speed")
    // Death holds its last pose.
    var d = CharacterAnimationController(legLength: 0.9)
    let late = d.update(AnimationInput(action: .death, actionStarted: 0, clock: 5)).pose
    let lateP = MotionPose.positions(late, skeleton: sk)
    check(lateP[r(.pelvis)].y < 0.4, "motion: a dead character stays down")

    // Combo state machine: chaining inside the window, back to one outside.
    var state = CharacterAnimationState()
    CharacterAnimator.request(&state, .attack, clock: 0, length: 0.5)
    CharacterAnimator.request(&state, .attack, clock: 0.35, length: 0.5)
    let second = state.combo
    CharacterAnimator.request(&state, .attack, clock: 0.7, length: 0.5)
    let third = state.combo
    CharacterAnimator.request(&state, .attack, clock: 1.1, length: 0.75)
    let wrapped = state.combo
    _ = CharacterAnimator.step(&state, clock: 3, eventTime: 0.2)
    CharacterAnimator.request(&state, .attack, clock: 3.1, length: 0.5)
    check(second == 2 && third == 3 && wrapped == 1 && state.combo == 1, "motion: the combo goes 1 → 2 → 3 → 1 and resets after a pause (\(second), \(third), \(wrapped), \(state.combo))")
    check(ComboRules.damageFactor(3) > ComboRules.damageFactor(1), "motion: the third hit is the strong one")

    // IK: reachable targets are reached; feet go onto a raised floor.
    if let (q1, q2) = CharacterIK.twoBone(root: SIMD3(0, 1, 0), mid: SIMD3(0, 0.5, 0.02), end: SIMD3(0, 0, 0), target: SIMD3(0.2, 0.3, 0.3), pole: SIMD3(0, 0.5, 1)) {
        let mid = SIMD3<Float>(0, 1, 0) + q1.rotate(SIMD3(0, -0.5, 0.02))
        let end = mid + q2.rotate(q1.rotate(SIMD3(0, -0.5, -0.02)))
        check(cLength(end - SIMD3(0.2, 0.3, 0.3)) < 0.01, "motion: two-bone IK reaches its target (\(end))")
    } else { check(false, "motion: two-bone IK solves") }
    let standing = MotionLibrary.motion("idle")!.sample(at: 0, legLength: MotionPose.legLength(sk))
    let raised = CharacterIK.plantFeet(standing, skeleton: sk, ground: { _ in 0.08 })
    let before = MotionPose.positions(standing, skeleton: sk), after = MotionPose.positions(raised, skeleton: sk)
    check(after[r(.rightFoot)].y > before[r(.rightFoot)].y + 0.06 && abs(after[r(.pelvis)].y - before[r(.pelvis)].y) < 1e-4,
          "motion: foot IK lifts the feet onto a step without moving the hips")
    let tooHigh = CharacterIK.plantFeet(standing, skeleton: sk, ground: { _ in 0.9 })
    check(MotionPose.positions(tooHigh, skeleton: sk)[r(.rightFoot)] == before[r(.rightFoot)], "motion: an unreachable floor leaves the pose as animated")
    print("RPG motion: \(library.count) motions, retargeting, controller, combo and IK checked")
}
