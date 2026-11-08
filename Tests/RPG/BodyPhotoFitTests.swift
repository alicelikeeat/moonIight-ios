import Foundation

/// Fitting the base body to a photo, checked on synthetic photos made from
/// known bodies: the keypoints are the body's joints and the outline is its
/// surface, both seen from the front.
func bodyPhotoFitTests() {
    func photo(of model: BaseBodyModel, back: Bool = false) -> BodyPhoto {
        let h = model.shape.height, scale: Float = 0.8 / h, origin = SIMD2<Float>(0.375, 0.1)
        func project(_ p: SIMD3<Float>) -> SIMD2<Float> { origin + SIMD2((back ? -p.x : p.x), p.y) * scale }
        let j = BaseBody.joints(model.shape)
        let map: [(PhotoJoint, JointTag)] = [
            (.leftShoulder, .leftUpperArm), (.rightShoulder, .rightUpperArm), (.leftElbow, .leftForearm), (.rightElbow, .rightForearm),
            (.leftWrist, .leftHand), (.rightWrist, .rightHand), (.leftHip, .leftThigh), (.rightHip, .rightThigh),
            (.leftKnee, .leftShin), (.rightKnee, .rightShin), (.leftAnkle, .leftFoot), (.rightAnkle, .rightFoot), (.root, .pelvis),
        ]
        var points: [PhotoJoint: BodyPhoto.Point] = [:]
        for (photoJoint, tag) in map { if let p = j[tag] { let q = project(p); points[photoJoint] = .init(x: q.x, y: q.y, confidence: 0.9) } }
        if let l = j[.leftUpperArm], let r = j[.rightUpperArm] { let q = project((l + r) / 2); points[.neck] = .init(x: q.x, y: q.y, confidence: 0.9) }
        if let head = j[.head] { let q = project(head + SIMD3(0, model.shape.headRatio * h * 0.45, 0)); points[.nose] = .init(x: q.x, y: q.y, confidence: back ? 0 : 0.9) }
        // The outline: the surface sampled densely, then cut into rows.
        var samples: [SIMD2<Float>] = []
        let m = model.mesh
        for t in 0..<m.triangleCount {
            func v(_ k: Int) -> SIMD3<Float> { let i = Int(m.indices[t * 3 + k]) * 3; return SIMD3(m.positions[i], m.positions[i + 1], m.positions[i + 2]) }
            let a = v(0), b = v(1), c = v(2)
            for u in stride(from: Float(0), through: 1, by: 0.25) { for w in stride(from: Float(0), through: 1 - u, by: 0.25) { samples.append(project(a + (b - a) * u + (c - a) * w)) } }
        }
        var rows: [BodyPhoto.Row] = []
        for y in stride(from: Float(0.08), through: 0.92, by: 0.005) {
            let xs = samples.filter { abs($0.y - y) <= 0.004 }.map(\.x).sorted()
            var spans: [SIMD2<Float>] = []
            for x in xs { if let last = spans.last, x - last.y < 0.012 { spans[spans.count - 1].y = x } else { spans.append(SIMD2(x, x)) } }
            rows.append(.init(y: y, spans: spans))
        }
        return BodyPhoto(points: points, outline: rows, aspect: 0.75, back: back)
    }

    let shapes = [BodyShape.standard,
                  BodyShape(height: 1.2, headRatio: 0.18, shoulderWidth: 0.27, hipWidth: 0.21, legRatio: 0.41, armRatio: 0.39, chest: 1.2, waist: 1.25, hips: 1.1, limbs: 1.15)]
    for truth in shapes {
        let model = BaseBody.build(truth)
        let fit = BodyPhotoFit.shape(photo(of: model), height: truth.height)
        let s = fit.shape
        check(fit.usable && fit.defaulted.isEmpty, "photo fit: a full front photo is usable and measures everything (\(fit.defaulted))")
        check(abs(s.shoulderWidth - truth.clamped.shoulderWidth) < 0.012 && abs(s.legRatio - truth.clamped.legRatio) < 0.02 && abs(s.armRatio - truth.clamped.armRatio) < 0.02,
              "photo fit: shoulders, legs and arms come back (\(s.shoulderWidth)/\(truth.shoulderWidth), \(s.legRatio)/\(truth.legRatio), \(s.armRatio)/\(truth.armRatio))")
        check(abs(s.headRatio - truth.clamped.headRatio) < 0.015, "photo fit: the head comes back (\(s.headRatio)/\(truth.headRatio))")
        check(abs(s.hipWidth - truth.clamped.hipWidth * truth.clamped.hips) / truth.clamped.hipWidth < 0.25 && abs(s.chest - truth.clamped.chest) < 0.3 && abs(s.waist - truth.clamped.waist) < 0.35,
              "photo fit: hips and girths are near (\(s.hipWidth), \(s.chest)/\(truth.chest), \(s.waist)/\(truth.waist))")
    }

    // A half-body photo still gives a body, saying what it could not see.
    var half = photo(of: BaseBody.build(.standard))
    half.points[.leftAnkle] = nil; half.points[.rightAnkle] = nil
    let partial = BodyPhotoFit.shape(half)
    check(!partial.usable && partial.defaulted.contains("legs") && partial.shape.legRatio == BodyShape.standard.legRatio, "photo fit: unseen legs keep the standard length and are listed")
    check(!BodyPhotoFit.shape(BodyPhoto(points: [:], outline: [], aspect: 1)).usable, "photo fit: nobody in the photo is not usable")

    // Paint: the front photo covers the front, the back photo the back.
    let model = BaseBody.build(.standard)
    let front = BodyPhotoFit.uvs(model, photo: photo(of: model))
    let back = BodyPhotoFit.uvs(model, photo: photo(of: model, back: true))
    check(front.count == model.mesh.vertexCount && back.count == model.mesh.vertexCount, "photo paint: one entry per vertex")
    let both = zip(front, back).filter { $0.0 != nil && $0.1 != nil }.count
    let neither = zip(front, back).filter { $0.0 == nil && $0.1 == nil }.count
    check(both == 0 && neither == 0, "photo paint: every vertex is painted by exactly one of the two photos")
    check(front.compactMap { $0 }.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }, "photo paint: UVs stay inside the photo")
    // A vertex at the right wrist lands on the right wrist in the photo.
    let wristPhoto = photo(of: model).point(.rightWrist)!
    let wristUV = SIMD2(wristPhoto.x / 0.75, 1 - wristPhoto.y)
    if let i = model.vertices.indices.first(where: { model.vertices[$0].from == .rightUpperArm && model.vertices[$0].along == 1 && front[$0] != nil }), let uv = front[i] {
        check(abs(uv.x - wristUV.x) < 0.04 && abs(uv.y - wristUV.y) < 0.04, "photo paint: the wrist ring lands on the photo's wrist (\(uv) vs \(wristUV))")
    } else { check(false, "photo paint: a front wrist vertex exists") }
    // Arms held another way in the photo: the forearm still lands on the forearm.
    var bent = photo(of: model)
    if let elbow = bent.points[.rightElbow] { bent.points[.rightWrist] = .init(x: elbow.x, y: elbow.y + 0.12, confidence: 0.9) }
    let bentUV = BodyPhotoFit.uvs(model, photo: bent)
    if let i = model.vertices.indices.first(where: { model.vertices[$0].from == .rightUpperArm && model.vertices[$0].along == 1 && bentUV[$0] != nil }), let uv = bentUV[i],
       let raised = bent.point(.rightWrist) {
        check(abs(uv.x - raised.x / 0.75) < 0.04 && abs(uv.y - (1 - raised.y)) < 0.04, "photo paint: a raised forearm in the photo still paints the forearm")
    }
    print("RPG photo fit: shapes recovered, front and back painted")
}
