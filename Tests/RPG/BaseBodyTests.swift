import Foundation

/// The universal base body: one topology for every shape, authored weights,
/// and every library motion plays on every shape without tearing.
func baseBodyTests() throws {
    let shapes: [BodyShape] = [
        .standard,
        BodyShape(height: 1.2, headRatio: 0.19, shoulderWidth: 0.26, hipWidth: 0.22, legRatio: 0.4, armRatio: 0.38, chest: 1.2, waist: 1.3, hips: 1.2, limbs: 1.2),
        BodyShape(height: 2.1, headRatio: 0.115, shoulderWidth: 0.27, hipWidth: 0.17, legRatio: 0.53, armRatio: 0.47, chest: 1.4, waist: 0.8, hips: 0.9, limbs: 0.8),
    ]
    let models = shapes.map(BaseBody.build)
    let base = models[0]
    check(models.allSatisfy { $0.mesh.vertexCount == base.mesh.vertexCount && $0.mesh.indices == base.mesh.indices && $0.skin.joints == base.skin.joints },
          "base body: every shape has the same vertices, triangles and weight joints (\(base.mesh.vertexCount) vertices)")
    check(models.allSatisfy { $0.mesh.valid && $0.vertices.count == $0.mesh.vertexCount && $0.mesh.normals.allSatisfy(\.isFinite) }, "base body: valid finite meshes with a part record per vertex")
    for model in models {
        do { try model.skeleton.validate() } catch { check(false, "base body: the skeleton validates (\(error))") }
    }
    check(base.skeleton.joints.count == 27, "base body: the standard 27-joint skeleton")

    // Size, sides, facing.
    for (shape, model) in zip(shapes, models) {
        let b = model.mesh.bounds
        check(abs(b.max[1] - shape.height) < shape.height * 0.03 && b.min[1] > -0.005 && b.min[1] < 0.01, "base body: stands on the ground, \(shape.height) m tall (\(b.min[1])…\(b.max[1]))")
        check(abs(b.min[0] + b.max[0]) < 0.002 * shape.height, "base body: left and right mirror each other")
    }
    let joints = BaseBody.joints(.standard)
    check((joints[.rightHand]?.x ?? 0) < 0 && (joints[.leftHand]?.x ?? 0) > 0 && (joints[.rightToeEnd]?.z ?? 0) > (joints[.rightFoot]?.z ?? 0),
          "base body: right side is −x and the toes point +z, like the automatic rig")

    // Weights: up to four joints, each vertex sums to 1, all real joints.
    var weightsOK = true
    for v in 0..<base.skin.count {
        var sum: Float = 0
        for k in 0..<4 { let j = base.skin.joints[v * 4 + k]; if j != 255 { sum += base.skin.weights[v * 4 + k]; if Int(j) >= 27 { weightsOK = false } } }
        if abs(sum - 1) > 1e-4 { weightsOK = false }
    }
    check(weightsOK, "base body: every vertex's weights sum to 1 on real joints")

    // Normals point out of the torso.
    var outward = 0, torso = 0
    for (i, info) in base.vertices.enumerated() where info.from == .pelvis && info.along > 0.1 && info.along < 0.9 {
        torso += 1
        let x = base.mesh.positions[i * 3], z = base.mesh.positions[i * 3 + 2]
        if base.mesh.normals[i * 3] * x + base.mesh.normals[i * 3 + 2] * z > 0 { outward += 1 }
    }
    check(torso > 0 && outward * 100 >= torso * 95, "base body: torso normals face outward (\(outward)/\(torso))")

    // Every library motion on every shape: finite, nothing flies away.
    var worst: Float = 0
    for model in models {
        for clip in MotionClip.library {
            for t: Float in [0, 0.25, 0.5, 0.75] {
                let matrices = clip.pose(model.skeleton, at: t * clip.period).skinning(model.skeleton)
                let posed = SkinWeightSolver.deform(model.mesh, skin: model.skin, matrices: matrices)
                guard posed.positions.allSatisfy(\.isFinite), posed.normals.allSatisfy(\.isFinite) else {
                    check(false, "base body: \(clip.id) stays finite on a \(model.shape.height) m body"); continue
                }
                for v in 0..<model.mesh.vertexCount {
                    let dx = posed.positions[v * 3], dy = posed.positions[v * 3 + 1] - model.shape.height / 2, dz = posed.positions[v * 3 + 2]
                    worst = max(worst, (dx * dx + dy * dy + dz * dz).squareRoot() / model.shape.height)
                }
            }
        }
    }
    check(worst < 1.6, "base body: every motion keeps the body together (farthest vertex \(worst) heights from the middle)")

    // Raising the arms moves the hands a lot and the hips hardly at all.
    if let raise = MotionClip.library.first(where: { $0.id == "raiseArms" }) {
        var handMove: Float = 0, hipMove: Float = 0
        for t: Float in stride(from: 0, through: 1, by: 0.125) {
            let posed = SkinWeightSolver.deform(base.mesh, skin: base.skin, matrices: raise.pose(base.skeleton, at: t * raise.period).skinning(base.skeleton))
            for (i, info) in base.vertices.enumerated() {
                let d = ((posed.positions[i * 3] - base.mesh.positions[i * 3]) * (posed.positions[i * 3] - base.mesh.positions[i * 3])
                         + (posed.positions[i * 3 + 1] - base.mesh.positions[i * 3 + 1]) * (posed.positions[i * 3 + 1] - base.mesh.positions[i * 3 + 1])).squareRoot()
                if info.from == .rightHand { handMove = max(handMove, d) }
                if info.from == .pelvis && info.along < 0.2 { hipMove = max(hipMove, d) }
            }
        }
        check(handMove > 0.2 && hipMove < 0.01, "base body: raising the arms moves the hands (\(handMove) m), not the hips (\(hipMove) m)")
    }

    let wild = BodyShape(height: .nan, headRatio: 9, shoulderWidth: -1, hipWidth: 0, legRatio: .infinity, armRatio: 0.1, chest: 0, waist: 99, hips: .nan, limbs: -3).clamped
    check(wild.height == 1.7 && wild.headRatio == 0.2 && wild.shoulderWidth == 0.17 && wild.legRatio == 0.48 && wild.waist == 1.5 && wild.hips == 1,
          "base body: impossible proportions are clamped to a body")
    check(BaseBody.build(wild).mesh.vertexCount == base.mesh.vertexCount, "base body: a clamped wild shape still builds the same topology")
    print("RPG base body: \(base.mesh.vertexCount) vertices, \(base.mesh.triangleCount) triangles, 27 joints, \(MotionClip.library.count) motions on \(shapes.count) shapes")
}
