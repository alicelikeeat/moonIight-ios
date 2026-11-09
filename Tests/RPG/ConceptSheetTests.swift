import Foundation

/// v1.93: the character-sheet standard and missing views rendered from a 3D model.
func conceptSheetTests() {
    // A measured person (BodyPhoto units: y up, picture height 1, x scaled by the 0.75 aspect).
    func person(back: Bool = false, armsOut: Bool = true, side: Bool = false, legs: Float = 0.5, face: Float = 0.9,
                top: Float = 0.95, bottom: Float = 0.05, feet: Bool = true) -> BodyPhoto {
        let tall = top - bottom, cx: Float = 0.375
        func at(_ dx: Float, _ share: Float, _ c: Float = 0.9) -> BodyPhoto.Point { .init(x: cx + dx * tall, y: bottom + share * tall, confidence: c) }
        let sh: Float = side ? 0.03 : 0.11
        let wrist: Float = armsOut ? 0.3 : sh + 0.02
        var points: [PhotoJoint: BodyPhoto.Point] = [
            .neck: at(0, 0.82), .leftShoulder: at(sh, 0.81), .rightShoulder: at(-sh, 0.81),
            .leftElbow: at(wrist * 0.6, 0.66), .rightElbow: at(-wrist * 0.6, 0.66),
            .leftWrist: at(wrist, 0.52), .rightWrist: at(-wrist, 0.52),
            .root: at(0, legs), .leftHip: at(sh * 0.8, legs), .rightHip: at(-sh * 0.8, legs),
            .leftKnee: at(0.06, legs / 2), .rightKnee: at(-0.06, legs / 2),
            .nose: at(0, 0.92, face), .leftEye: at(0.02, 0.94, face), .rightEye: at(-0.02, 0.94, face),
        ]
        if feet { points[.leftAnkle] = at(0.06, 0.03); points[.rightAnkle] = at(-0.06, 0.03) }
        let outline = stride(from: bottom, through: top, by: 0.01).map { BodyPhoto.Row(y: $0, spans: [SIMD2(cx - 0.12 * tall, cx + 0.12 * tall)]) }
        return BodyPhoto(points: points, outline: outline, aspect: 0.75, back: back)
    }
    func input(_ view: PhotoView, _ photo: BodyPhoto?, height: Int = 1000, plain: Float = 0.95, origin: ConceptOrigin = .user) -> ConceptViewInput {
        ConceptViewInput(view: view, photo: photo, width: height * 3 / 4, height: height, plainBorder: plain, origin: origin)
    }
    func codes(_ r: ConceptSheetReport, _ view: PhotoView?) -> Set<String> { Set(r.issues(view).map(\.code)) }

    let full = ConceptSheetSpec.check([input(.front, person()), input(.back, person(back: true, face: 0)), input(.left, person(side: true, face: 0))])
    check(full.grade == .complete && full.missing.isEmpty && full.issues.allSatisfy { $0.level == .tip } && full.issues.isEmpty,
          "concept sheet: a clean front + back + side set is complete with nothing to fix (\(full.issues.map(\.id)))")
    let one = ConceptSheetSpec.check([input(.front, person())])
    check(one.grade == .basic && one.canMake && one.missing == [.back, .left] && codes(one, .back) == ["missing"] && codes(one, .left) == ["missing"],
          "concept sheet: a front alone can be made (basic) and the back and side are listed as missing")
    check(ConceptSheetSpec.check([input(.front, person()), input(.back, person(back: true, face: 0))]).grade == .good, "concept sheet: front + back is good")
    check(ConceptSheetSpec.check([input(.back, person(back: true, face: 0))]).grade == .notReady
          && ConceptSheetSpec.check([input(.front, nil)]).grade == .notReady,
          "concept sheet: without a front, or with no person in it, nothing can be made")

    let armsDown = ConceptSheetSpec.check([input(.front, person(armsOut: false))])
    check(codes(armsDown, .front).contains("armsDown") && !codes(one, .front).contains("armsDown"), "concept sheet: arms against the body are flagged, an A-pose is not")
    let small = ConceptSheetSpec.check([input(.front, person(), height: 250)])
    check(codes(small, .front).contains("small") && small.canMake, "concept sheet: a tiny figure is a warning, not a stop")
    check(codes(ConceptSheetSpec.check([input(.front, person(top: 0.995))]), .front).contains("cropped"), "concept sheet: a figure touching the edge is flagged as cropped")
    check(codes(ConceptSheetSpec.check([input(.front, person(feet: false))]), .front).contains("feet"), "concept sheet: missing feet are flagged")
    check(codes(ConceptSheetSpec.check([input(.front, person(), plain: 0.3)]), .front).contains("background"), "concept sheet: a busy background is flagged")

    let wrongBack = ConceptSheetSpec.check([input(.front, person()), input(.back, person(back: true, legs: 0.6, face: 0.9))])
    check(codes(wrongBack, .back).isSuperset(of: ["face", "proportions"]), "concept sheet: a back with a face and other proportions is flagged (\(codes(wrongBack, .back)))")
    let wrongSide = ConceptSheetSpec.check([input(.front, person()), input(.right, person(face: 0))])
    check(codes(wrongSide, .left).contains("notSide") && wrongSide.present.contains(.left), "concept sheet: the right side counts as the side, and a front-on picture there is flagged")
    let sideNoPoints = ConceptSheetSpec.check([input(.front, person()), input(.left, nil)])
    check(sideNoPoints.present.contains(.left) && codes(sideNoPoints, .left) == ["noPoints"], "concept sheet: a side picture without joints still counts (Vision often misses side-on bodies)")
    let guessed = ConceptSheetSpec.check([input(.front, person()), input(.back, person(back: true, face: 0), origin: .ai)])
    check(guessed.grade == .good && codes(guessed, .back) == ["ai"], "concept sheet: an AI-proposed back counts, marked for confirmation")
    check(ConceptSheetSpec.requirements.map(\.view) == [.front, .back, .left] && ConceptSheetSpec.requirements.filter(\.required).map(\.view) == [.front],
          "concept sheet: the standard asks for front (required), back and side")

    // Plain and busy borders.
    let plain = RasterImage(width: 120, height: 160, fill: [250, 250, 250, 255])
    var noisy = plain
    var seed: UInt32 = 7
    for i in 0..<(noisy.width * noisy.height) { for k in 0..<3 { seed = seed &* 1_664_525 &+ 1_013_904_223; noisy.rgba[i * 4 + k] = UInt8(seed >> 24) } }
    check(ConceptSheetSpec.plainBorder(plain) > 0.99 && ConceptSheetSpec.plainBorder(noisy) < 0.3,
          "concept sheet: border plainness (plain \(ConceptSheetSpec.plainBorder(plain)), noisy \(ConceptSheetSpec.plainBorder(noisy)))")

    // Missing views from a 3D model: the base body coloured by which way its
    // surface faces (front red / back blue; left side green).
    guard let body = HumanBase.build(.standard, lod: 2) else { check(false, "concept views: base body builds"); return }
    let mesh = body.mesh
    var frontBack: [UInt8] = [], leftSide: [UInt8] = []
    for v in 0..<mesh.vertexCount {
        frontBack += mesh.normals[v * 3 + 2] > 0 ? [220, 40, 40] : [40, 40, 220]
        leftSide += mesh.normals[v * 3] > 0 ? [40, 200, 40] : [120, 120, 120]
    }
    func share(_ image: RasterImage?, _ channel: Int) -> Float {
        guard let image else { return 0 }
        var hit = 0, total = 0
        for i in 0..<(image.width * image.height) {
            let px = (0..<3).map { Int(image.rgba[i * 4 + $0]) }
            if abs(px[0] - 244) + abs(px[1] - 244) + abs(px[2] - 246) < 30 { continue }
            total += 1
            if px[channel] > px[(channel + 1) % 3] + 60 && px[channel] > px[(channel + 2) % 3] + 60 { hit += 1 }
        }
        return total == 0 ? 0 : Float(hit) / Float(total)
    }
    let front = ConceptViewRender.render(mesh, texture: nil, colors: frontBack, view: .front, width: 192, height: 288, supersample: 1)
    let backView = ConceptViewRender.render(mesh, texture: nil, colors: frontBack, view: .back, width: 192, height: 288, supersample: 1)
    let left = ConceptViewRender.render(mesh, texture: nil, colors: leftSide, view: .left, width: 192, height: 288, supersample: 1)
    let right = ConceptViewRender.render(mesh, texture: nil, colors: leftSide, view: .right, width: 192, height: 288, supersample: 1)
    check(share(front, 0) > 0.85 && share(backView, 2) > 0.85, "concept views: the front render shows the front, the back render the back (\(share(front, 0)), \(share(backView, 2)))")
    check(share(left, 1) > 0.8 && share(right, 1) < 0.15, "concept views: the left render shows the character's left side (\(share(left, 1)), right \(share(right, 1)))")
    if let front, let box = ConceptViewRender.figureBox(front) {
        let cx = Float(box.x0 + box.x1) / 2
        check(Float(box.y1 - box.y0) > 0.6 * Float(front.height) && abs(cx - Float(front.width) / 2) < 0.1 * Float(front.width),
              "concept views: the figure stands upright and centred (\(box))")
    } else { check(false, "concept views: the figure is found in the render") }
    check(ConceptViewRender.render(mesh, texture: nil, view: .top) == nil, "concept views: only front, back and sides are rendered")
    if let front, let backView {
        let a = ConceptViewRender.facing(mesh, texture: nil, colors: frontBack, front: front)
        let b = ConceptViewRender.facing(mesh, texture: nil, colors: frontBack, front: backView)
        check(a == 0 && abs(b - .pi) < 0.01, "concept views: a model facing away is turned round before the missing views are drawn (\(a), \(b))")
    }
    print("RPG concept sheet: grades \(one.grade.rawValue)/\(full.grade.rawValue), \(one.issues.count) notes on a front-only set")
}
