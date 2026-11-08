import Foundation

// v1.92: synthetic photos of a known 3D body, and the photo-fit calibration
// they make possible.
//
// BodyPhotoFit measures proportions from a photo (body points + outline).
// Its definitions (head from the chin estimate, hip width from the outline
// at hip-joint height, arm length from shoulder–elbow–wrist) do not match
// the skeleton-based proportions HumanBase is fitted with, so a person
// photographed exactly as the neutral body came back with a 1.46× head,
// the narrowest hips and 0.89× arms (the reconstruction benchmark showed
// it). The calibration photographs the neutral HumanBase, measures it with
// BodyPhotoFit, and keeps truth ÷ measured for every proportion: applied to
// a real photo's measurements, it puts them in the base body's own terms.

enum SyntheticPhoto {
    static let size = 192
    /// Narrow field of view: close to the orthographic photos the carver assumes.
    static func camera(yaw: Float, pitch: Float = 0) -> RasterCamera { RasterCamera(yaw: yaw, pitch: pitch, fieldOfView: 10, margin: 1.1, lighting: true) }

    /// A mesh moved and scaled into the unit cube (the rasteriser's frame).
    struct Frame: Sendable { var centre: SIMD3<Float>; var scale: Float }
    static func frame(_ mesh: GeneratedMesh) -> Frame {
        let b = mesh.bounds
        let lo = SIMD3(b.min[0], b.min[1], b.min[2]), hi = SIMD3(b.max[0], b.max[1], b.max[2])
        let extent = hi - lo
        return Frame(centre: (lo + hi) / 2, scale: 1 / max(1e-4, max(extent.x, max(extent.y, extent.z))))
    }
    static func normalised(_ mesh: GeneratedMesh, _ f: Frame) -> [Float] {
        var p = mesh.positions
        for i in stride(from: 0, to: p.count, by: 3) {
            p[i] = (p[i] - f.centre.x) * f.scale; p[i + 1] = (p[i + 1] - f.centre.y) * f.scale; p[i + 2] = (p[i + 2] - f.centre.z) * f.scale
        }
        return p
    }

    /// Model yaw that shows each side to the camera (the camera looks down −z;
    /// the body faces +z and its left is +x).
    static func yaw(_ view: PhotoView) -> Float {
        switch view { case .front: 0; case .back: .pi; case .left: -.pi / 2; case .right: .pi / 2; case .top, .bottom: 0 }
    }

    /// A segmented photo (mask + colours) of the normalised mesh from one side.
    static func photo(_ mesh: GeneratedMesh, positions: [Float], view: PhotoView) -> ViewPhoto {
        let image = ModelRasterizer.render(mesh, positions: positions, texture: nil, colors: nil, camera: camera(yaw: yaw(view)),
                                           width: size, height: size, supersample: 2)
        let mask = stride(from: 3, to: image.rgba.count, by: 4).map { Float(image.rgba[$0]) / 255 }
        return ViewPhoto(width: image.width, height: image.height, mask: mask, image: image)
    }

    /// Where a point of the normalised model lands in a front picture, in
    /// pixels (the rasteriser's own projection, pitch 0).
    static func project(_ p: SIMD3<Float>, size: Int = size) -> SIMD2<Float> {
        let c = camera(yaw: 0)
        let f = 1 / tan(c.fieldOfView * .pi / 360)
        let distance = 0.5 * c.margin * f + 0.6
        let zc = max(0.01, distance - p.z)
        return SIMD2((p.x * f / zc * 0.5 + 0.5) * Float(size), (0.5 - p.y * f / zc * 0.5) * Float(size))
    }

    /// What Vision would report for a front picture of the body: 19 body
    /// points (from the true joints) and the outline (from the mask). Units:
    /// picture heights, y up.
    static func bodyPhoto(_ body: HumanBody, frame: Frame, front: ViewPhoto) -> BodyPhoto {
        let world = body.skeleton.worldRest
        func joint(_ id: String) -> SIMD3<Float>? {
            guard let i = body.skeleton.joints.firstIndex(where: { $0.jointID == id }) else { return nil }
            return (world[i].origin - frame.centre) * frame.scale
        }
        let size = Float(front.height)
        func point(_ p: SIMD3<Float>?) -> BodyPhoto.Point? {
            guard let p else { return nil }
            let px = project(p, size: front.height)
            return BodyPhoto.Point(x: px.x / size, y: (size - px.y) / size, confidence: 1)
        }
        var points: [PhotoJoint: BodyPhoto.Point] = [:]
        let pairs: [(PhotoJoint, String)] = [
            (.leftEye, "ext.leftEye"), (.rightEye, "ext.rightEye"),
            (.leftShoulder, "leftUpperArm"), (.rightShoulder, "rightUpperArm"), (.leftElbow, "leftForearm"), (.rightElbow, "rightForearm"),
            (.leftWrist, "leftHand"), (.rightWrist, "rightHand"), (.root, "pelvis"), (.leftHip, "leftThigh"), (.rightHip, "rightThigh"),
            (.leftKnee, "leftShin"), (.rightKnee, "rightShin"), (.leftAnkle, "leftFoot"), (.rightAnkle, "rightFoot"),
        ]
        for (photoJoint, id) in pairs { points[photoJoint] = point(joint(id)) }
        // Vision's neck sits on the shoulder line; the nose half way up the head, in front.
        if let l = joint("leftUpperArm"), let r = joint("rightUpperArm") { points[.neck] = point((l + r) / 2) }
        if let head = joint("head"), let top = joint("headEnd") { points[.nose] = point((head + top) / 2 + SIMD3(0, 0, 0.05)) }
        var outline: [BodyPhoto.Row] = []
        for y in 0..<front.height {
            var spans: [SIMD2<Float>] = []
            var start: Int?
            for x in 0...front.width {
                let on = x < front.width && front.mask[y * front.width + x] >= 0.5
                if on, start == nil { start = x }
                if !on, let s = start { spans.append(SIMD2(Float(s) / size, Float(x) / size)); start = nil }
            }
            outline.append(BodyPhoto.Row(y: (size - Float(y) - 0.5) / size, spans: spans))
        }
        return BodyPhoto(points: points, outline: outline, aspect: Float(front.width) / Float(front.height))
    }

    /// The front body photo of a HumanBase body (what the calibration and the benchmark measure).
    static func frontBodyPhoto(_ body: HumanBody) -> BodyPhoto {
        let f = frame(body.mesh)
        return bodyPhoto(body, frame: f, front: photo(body.mesh, positions: normalised(body.mesh, f), view: .front))
    }
}

enum PhotoFitCalibration {
    /// truth ÷ measured for each proportion, from the neutral HumanBase.
    /// Nil without the base body file (measurements are then used as they are).
    static let factors: BodyShape? = compute()

    static func compute(asset: HumanBaseAsset? = HumanBaseAsset.shared) -> BodyShape? {
        guard let body = asset.flatMap({ HumanBase.build(.standard, lod: 0, asset: $0) }) else { return nil }
        let measured = BodyPhotoFit.shape(SyntheticPhoto.frontBodyPhoto(body), height: body.shape.height)
        guard measured.usable else { return nil }
        let t = body.bodyShape, m = measured.shape
        func r(_ a: Float, _ b: Float) -> Float { b > 1e-4 && a.isFinite && b.isFinite ? a / b : 1 }
        var f = BodyShape()
        f.headRatio = r(t.headRatio, m.headRatio); f.shoulderWidth = r(t.shoulderWidth, m.shoulderWidth)
        f.hipWidth = r(t.hipWidth, m.hipWidth); f.legRatio = r(t.legRatio, m.legRatio); f.armRatio = r(t.armRatio, m.armRatio)
        f.chest = r(t.chest, m.chest); f.waist = r(t.waist, m.waist); f.hips = r(t.hips, m.hips); f.limbs = r(t.limbs, m.limbs)
        return f
    }

    /// A photo's measurements in the base body's terms (unmeasured values are left alone).
    static func apply(_ fit: BodyFitResult, factors: BodyShape? = factors) -> BodyFitResult {
        guard let f = factors else { return fit }
        var s = fit.shape
        let m = Set(fit.measured)
        if m.contains("head") { s.headRatio *= f.headRatio }
        if m.contains("shoulders") { s.shoulderWidth *= f.shoulderWidth }
        if m.contains("hips") { s.hipWidth *= f.hipWidth }
        if m.contains("legs") { s.legRatio *= f.legRatio }
        if m.contains("arms") { s.armRatio *= f.armRatio }
        if m.contains("chest") { s.chest *= f.chest }
        if m.contains("waist") { s.waist *= f.waist }
        if m.contains("limbs") { s.limbs *= f.limbs }
        var out = fit
        out.shape = s.clamped
        return out
    }
}

extension HumanShape {
    /// The HumanBase shape for a person photo: calibrated proportions, then the fit.
    static func fromPhoto(_ fit: BodyFitResult) -> HumanShape {
        let calibrated = PhotoFitCalibration.apply(fit)
        return fitting(calibrated.shape, measured: Set(calibrated.measured))
    }
}
