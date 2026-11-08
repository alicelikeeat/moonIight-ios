import Foundation

/// Borrowing the base body's weights: a different body, held in a T-pose,
/// gets back (almost) the weights it was authored with.
func baseBodyTransferTests() {
    // Proportions back from joints.
    let truth = BodyShape(height: 1.75, headRatio: 0.14, shoulderWidth: 0.26, hipWidth: 0.2, legRatio: 0.5, armRatio: 0.45)
    if let back = BaseBodyTransfer.shape(from: BaseBody.joints(truth)) {
        check(abs(back.height - truth.height) < 0.02 && abs(back.shoulderWidth - truth.shoulderWidth) < 0.005 && abs(back.hipWidth - truth.hipWidth) < 0.005
              && abs(back.legRatio - truth.legRatio) < 0.01 && abs(back.armRatio - truth.armRatio) < 0.005 && abs(back.headRatio - truth.headRatio) < 0.01,
              "transfer: a body's proportions come back from its joints (\(back))")
    } else { check(false, "transfer: proportions from joints") }
    check(BaseBodyTransfer.shape(from: [:]) == nil, "transfer: no joints, no body")

    // Turns.
    let quarter = Rot3.between(SIMD3(1, 0, 0), SIMD3(0, 1, 0)).apply(SIMD3(1, 0, 0))
    let flip = Rot3.between(SIMD3(0, 0, 1), SIMD3(0, 0, -1)).apply(SIMD3(0, 0, 1))
    check(abs(quarter.x) < 1e-5 && abs(quarter.y - 1) < 1e-5 && abs(flip.z + 1) < 1e-5 && Rot3.between(.zero, SIMD3(1, 0, 0)) == .identity,
          "transfer: the shortest turn between two directions, opposite ones and zero ones included")

    // The target: the same body with its arms raised to a T-pose.
    let source = BaseBody.build(truth)
    var pose = SkeletonPose.rest(source.skeleton)
    guard let r = source.skeleton.index(.rightUpperArm), let l = source.skeleton.index(.leftUpperArm), let hand = source.skeleton.index(.rightHand) else {
        check(false, "transfer: arm joints exist"); return
    }
    var best: (Float, Float) = (-.infinity, 0)
    for sign: Float in [1, -1] {
        var trial = pose; trial.rotations[r].z = .pi / 4 * sign; trial.rotations[l].z = -.pi / 4 * sign
        let y = trial.world(source.skeleton)[hand].origin.y
        if y > best.0 { best = (y, sign) }
    }
    pose.rotations[r].z = .pi / 4 * best.1; pose.rotations[l].z = -.pi / 4 * best.1
    let world = pose.world(source.skeleton)
    let posed = SkinWeightSolver.deform(source.mesh, skin: source.skin, matrices: pose.skinning(source.skeleton))
    var target = GeneratedMesh(positions: posed.positions, normals: posed.normals, uvs: source.mesh.uvs, indices: source.mesh.indices)
    var positions: [JointTag: SIMD3<Float>] = [:]
    for (i, joint) in source.skeleton.joints.enumerated() { positions[joint.semanticTag] = world[i].origin }
    check(abs((positions[.rightHand]?.y ?? 0) - (positions[.rightUpperArm]?.y ?? 9)) < 0.05 * truth.height, "transfer: the target holds its arms level (T-pose)")
    let targetSkeleton = SkeletonBuilder.build(JointEstimate(positions: positions, confidence: positions.mapValues { _ in 1 }, pose: .tPose, humanoid: 1, notes: []))

    func agreement(_ mesh: GeneratedMesh, _ skeleton: SkeletonDefinition) -> (all: Float, arms: Float, skin: SkinInfluences?) {
        guard let skin = BaseBodyTransfer.weights(for: mesh, skeleton: skeleton) else { return (0, 0, nil) }
        func main(_ s: SkinInfluences, _ v: Int) -> UInt8 { (0..<4).max { s.weights[v * 4 + $0] < s.weights[v * 4 + $1] }.map { s.joints[v * 4 + $0] } ?? 255 }
        var same = 0, armSame = 0, armTotal = 0
        for v in 0..<mesh.vertexCount {
            let match = main(skin, v) == main(source.skin, v)
            if match { same += 1 }
            if [.rightUpperArm, .leftUpperArm, .rightHand, .leftHand].contains(source.vertices[v].from) { armTotal += 1; if match { armSame += 1 } }
        }
        return (Float(same) / Float(mesh.vertexCount), Float(armSame) / Float(max(1, armTotal)), skin)
    }
    let result = agreement(target, targetSkeleton)
    check(result.all > 0.85 && result.arms > 0.85, "transfer: a T-posed body gets its own weights back (\(result.all) overall, \(result.arms) arms)")
    if let skin = result.skin {
        check(skin.valid(jointCount: targetSkeleton.joints.count, vertexCount: target.vertexCount), "transfer: the borrowed weights are a valid skin")
        var finite = true
        for clip in MotionClip.library {
            let moved = SkinWeightSolver.deform(target, skin: skin, matrices: clip.pose(targetSkeleton, at: clip.period * 0.4).skinning(targetSkeleton))
            if !moved.positions.allSatisfy(\.isFinite) { finite = false }
        }
        check(finite, "transfer: every library motion plays on the borrowed weights")
    }

    // Units do not matter: the same mesh a tenth the size.
    for i in target.positions.indices { target.positions[i] *= 0.1 }
    let small = SkeletonBuilder.build(JointEstimate(positions: positions.mapValues { $0 * 0.1 }, confidence: positions.mapValues { _ in 1 }, pose: .tPose, humanoid: 1, notes: []))
    let scaled = agreement(target, small)
    check(scaled.all > 0.85, "transfer: a mesh in other units (a tenth the size) gets the same weights (\(scaled.all))")
    print("RPG base body transfer: \(Int(result.all * 100))% of vertices, \(Int(result.arms * 100))% of arm vertices keep their joint in a T-pose")
}
