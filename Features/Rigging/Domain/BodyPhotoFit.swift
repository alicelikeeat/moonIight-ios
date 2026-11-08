import Foundation

// v1.90: a photo of a person → the base body's shape and paint. Input is
// what Vision finds (19 body points and the person's outline, both in the
// photo); output is a BodyShape and, for every base-body vertex, the spot of
// the photo it shows. Pure Swift (tested on Linux): the Vision calls live in
// the app layer.

/// The 19 body points Vision reports. Left / right are the PERSON's sides.
enum PhotoJoint: String, CaseIterable, Codable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

/// One photo, measured. Coordinates: x right, y UP, both in units of the
/// photo's height (x already multiplied by width / height), so distances
/// are true proportions.
struct BodyPhoto: Equatable, Sendable {
    struct Point: Equatable, Sendable { var x: Float; var y: Float; var confidence: Float }
    /// The outline: per sampled row, the filled spans [x0, x1].
    struct Row: Equatable, Sendable { var y: Float; var spans: [SIMD2<Float>] }
    var points: [PhotoJoint: Point]
    var outline: [Row]
    /// Width / height of the photo (to turn coordinates back into texture UVs).
    var aspect: Float
    /// The person shows their back (the back photo of a pair).
    var back = false

    func point(_ j: PhotoJoint, minimum: Float = 0.3) -> SIMD2<Float>? {
        guard let p = points[j], p.confidence >= minimum, p.x.isFinite, p.y.isFinite else { return nil }
        return SIMD2(p.x, p.y)
    }
    func mid(_ a: PhotoJoint, _ b: PhotoJoint) -> SIMD2<Float>? {
        guard let p = point(a), let q = point(b) else { return point(a) ?? point(b) }
        return (p + q) / 2
    }
    /// Width of the outline span that contains x at height y (arms held
    /// apart from the body are other spans and do not count).
    func width(at y: Float, around x: Float) -> Float? {
        guard let row = outline.min(by: { abs($0.y - y) < abs($1.y - y) }), abs(row.y - y) < 0.03 else { return nil }
        return row.spans.first { $0.x <= x && x <= $0.y }.map { $0.y - $0.x }
    }
    var top: Float? { outline.filter { !$0.spans.isEmpty }.map(\.y).max() }
    var bottom: Float? { outline.filter { !$0.spans.isEmpty }.map(\.y).min() }
}

struct BodyFitResult: Equatable, Sendable {
    var shape: BodyShape
    /// What was measured from the photo, and what fell back to the standard body.
    var measured: [String]
    var defaulted: [String]
    /// Enough of the body was seen to trust the fit (shoulders, hips, head and feet).
    var usable: Bool
}

enum BodyPhotoFit {
    // MARK: Shape

    /// Proportions from a front photo. Anything not seen keeps the standard
    /// body's value (and is listed), so a half-body photo still gives a body.
    static func shape(_ photo: BodyPhoto, height: Float = BodyShape.standard.height) -> BodyFitResult {
        var shape = BodyShape.standard; shape.height = height
        var measured: [String] = [], defaulted: [String] = []
        guard let top = photo.top, let bottom = photo.bottom, top - bottom > 0.05,
              let shoulders = photo.mid(.leftShoulder, .rightShoulder), let hips = photo.mid(.leftHip, .rightHip) else {
            return BodyFitResult(shape: shape.clamped, measured: [], defaulted: ["all"], usable: false)
        }
        let tall = top - bottom
        let feetSeen = photo.point(.leftAnkle) != nil || photo.point(.rightAnkle) != nil
        let centre = (shoulders.x + hips.x) / 2

        // Head: from the top of the outline to the chin (a little above the neck point).
        let neck = photo.point(.neck) ?? shoulders
        let chin = neck.y + (top - neck.y) * 0.18
        shape.headRatio = (top - chin) / tall; measured.append("head")
        if let l = photo.point(.leftShoulder), let r = photo.point(.rightShoulder) {
            shape.shoulderWidth = abs(l.x - r.x) / tall; measured.append("shoulders")
        } else { defaulted.append("shoulders") }
        if feetSeen {
            shape.legRatio = (hips.y - bottom) / tall; measured.append("legs")
        } else { defaulted.append("legs") }
        if let width = photo.width(at: hips.y, around: centre) {
            shape.hipWidth = width / tall; measured.append("hips")
        } else { defaulted.append("hips") }
        // Arms: the longer side (the other may point at the camera).
        let arms = [("right", PhotoJoint.rightShoulder, PhotoJoint.rightElbow, PhotoJoint.rightWrist), ("left", .leftShoulder, .leftElbow, .leftWrist)]
            .compactMap { _, s, e, w -> Float? in
                guard let a = photo.point(s), let b = photo.point(e), let c = photo.point(w) else { return nil }
                return (len2(b - a) + len2(c - b)) / 0.82
            }
        if let arm = arms.max() { shape.armRatio = arm / tall; measured.append("arms") } else { defaulted.append("arms") }

        // Girths: the outline's width against the standard body's at the same level.
        let clampedSoFar = shape.clamped
        let shoulderSpan = clampedSoFar.shoulderWidth * tall
        func girth(_ name: String, at y: Float, expected: Float) -> Float {
            guard expected > 0, let width = photo.width(at: y, around: centre) else { defaulted.append(name); return 1 }
            measured.append(name)
            return width / expected
        }
        // Chest a third of the way down: higher, A-pose arms still touch the body's outline.
        shape.chest = girth("chest", at: shoulders.y - (shoulders.y - hips.y) * 0.3, expected: shoulderSpan * 0.9)
        shape.waist = girth("waist", at: shoulders.y - (shoulders.y - hips.y) * 0.62, expected: shoulderSpan * 0.74)
        if let knee = photo.mid(.rightKnee, .rightHip) ?? photo.mid(.leftKnee, .leftHip),
           let width = photo.width(at: knee.y, around: knee.x) {
            shape.limbs = width / (clampedSoFar.hipWidth * tall * 0.3 * 2 * 0.88); measured.append("limbs")
        } else { defaulted.append("limbs") }
        let usable = feetSeen && photo.point(.nose) != nil && measured.contains("shoulders") && measured.contains("hips")
        return BodyFitResult(shape: shape.clamped, measured: measured, defaulted: defaulted, usable: usable)
    }

    // MARK: Paint

    /// Where in the photo each base-body vertex is: (u, v) in 0…1 with v
    /// DOWN from the top (image convention), or nil for a vertex that photo
    /// does not show (the back of the body in a front photo, and so on).
    static func uvs(_ model: BaseBodyModel, photo: BodyPhoto) -> [SIMD2<Float>?] {
        guard let mapper = Mapper(model: model, photo: photo) else { return Array(repeating: nil, count: model.mesh.vertexCount) }
        return (0..<model.mesh.vertexCount).map { i in
            let info = model.vertices[i]
            // A front photo paints what faces the camera; a back photo the rest.
            guard info.front != photo.back else { return nil }
            let p = SIMD3(model.mesh.positions[i * 3], model.mesh.positions[i * 3 + 1], model.mesh.positions[i * 3 + 2])
            guard let spot = mapper.place(p, info: info) else { return nil }
            return SIMD2(min(1, max(0, spot.x / photo.aspect)), min(1, max(0, 1 - spot.y)))
        }
    }

    /// Model → photo, segment by segment: the torso and head by one fitted
    /// scale; each limb along its own bone in the photo, so arms held
    /// differently from the A-pose still land on the arms.
    private struct Mapper {
        let joints: [JointTag: SIMD3<Float>]
        let photo: BodyPhoto
        let scale: Float
        let origin: SIMD2<Float>
        let modelOrigin: SIMD2<Float>
        let mirror: Float

        init?(model: BaseBodyModel, photo: BodyPhoto) {
            let j = BaseBody.joints(model.shape)
            guard let shoulders = photo.mid(.leftShoulder, .rightShoulder), let hips = photo.mid(.leftHip, .rightHip),
                  let ms = j[.rightUpperArm], let ml = j[.leftUpperArm], let ht = j[.rightThigh] else { return nil }
            let modelShoulders = SIMD2((ms.x + ml.x) / 2, ms.y), modelHips = SIMD2(Float(0), ht.y)
            let modelSpan = len2(modelShoulders - modelHips), photoSpan = len2(shoulders - hips)
            guard modelSpan > 1e-4, photoSpan > 1e-4 else { return nil }
            joints = j; self.photo = photo
            scale = photoSpan / modelSpan
            origin = hips; modelOrigin = modelHips
            // Front photo: the person's right (−x) is on the image's left;
            // in a back photo it is on the image's right.
            mirror = photo.back ? -1 : 1
        }

        func global(_ p: SIMD3<Float>) -> SIMD2<Float> {
            origin + SIMD2((p.x - modelOrigin.x) * mirror, p.y - modelOrigin.y) * scale
        }

        /// Photo points at the two ends of a model segment (nil: not seen).
        func ends(_ from: JointTag, _ to: JointTag) -> (SIMD2<Float>, SIMD2<Float>, SIMD3<Float>, SIMD3<Float>)? {
            func photoPoint(_ tag: JointTag) -> SIMD2<Float>? {
                switch tag {
                case .rightUpperArm: photo.point(.rightShoulder)
                case .rightForearm: photo.point(.rightElbow)
                case .rightHand: photo.point(.rightWrist)
                case .leftUpperArm: photo.point(.leftShoulder)
                case .leftForearm: photo.point(.leftElbow)
                case .leftHand: photo.point(.leftWrist)
                case .rightThigh: photo.point(.rightHip)
                case .rightShin: photo.point(.rightKnee)
                case .rightFoot: photo.point(.rightAnkle)
                case .leftThigh: photo.point(.leftHip)
                case .leftShin: photo.point(.leftKnee)
                case .leftFoot: photo.point(.leftAnkle)
                default: nil
                }
            }
            guard let a = photoPoint(from), let b = photoPoint(to), let ma = joints[from], let mb = joints[to] else { return nil }
            return (a, b, ma, mb)
        }

        func place(_ p: SIMD3<Float>, info: BaseBodyVertex) -> SIMD2<Float>? {
            // Limbs follow their bones in the photo, two segments per limb.
            let chains: [JointTag: [JointTag]] = [
                .rightUpperArm: [.rightUpperArm, .rightForearm, .rightHand], .leftUpperArm: [.leftUpperArm, .leftForearm, .leftHand],
                .rightThigh: [.rightThigh, .rightShin, .rightFoot], .leftThigh: [.leftThigh, .leftShin, .leftFoot],
            ]
            if let chain = chains[info.from] {
                // The nearer segment of the chain (by the model point).
                let candidates = [(chain[0], chain[1]), (chain[1], chain[2])].compactMap { ends($0.0, $0.1) }
                guard !candidates.isEmpty else { return global(p) }
                let best = candidates.min { distance(p, $0.2, $0.3) < distance(p, $1.2, $1.3) }!
                return along(p, best)
            }
            if info.from == .rightHand || info.from == .leftHand {
                // Hands continue past the wrist along the forearm's direction.
                let side: (JointTag, JointTag) = info.from == .rightHand ? (.rightForearm, .rightHand) : (.leftForearm, .leftHand)
                if let segment = ends(side.0, side.1) { return along(p, segment) }
            }
            return global(p)
        }

        private func distance(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let ab = b - a, t = max(0, min(1, dot3(p - a, ab) / max(1e-6, dot3(ab, ab))))
            return len3(p - (a + ab * t))
        }
        /// A point on a model segment → the same place on the photo segment:
        /// how far along, and how far to the side (scaled like the torso).
        private func along(_ p: SIMD3<Float>, _ s: (SIMD2<Float>, SIMD2<Float>, SIMD3<Float>, SIMD3<Float>)) -> SIMD2<Float> {
            let (a, b, ma, mb) = s
            let axis = mb - ma, lengthSquared = max(1e-6, dot3(axis, axis))
            let t = dot3(p - ma, axis) / lengthSquared
            let foot = ma + axis * t
            // Sideways in the picture plane (x, y), measured against the bone's direction there.
            let side2 = SIMD2(p.x - foot.x, p.y - foot.y) * SIMD2(mirror, 1)
            let bone2 = unit2(SIMD2(axis.x * mirror, axis.y))
            let normal2 = SIMD2(-bone2.y, bone2.x)
            let offset = dot2(side2, normal2)
            let photoBone = b - a, photoNormal = SIMD2(-unit2(photoBone).y, unit2(photoBone).x)
            return a + photoBone * t + photoNormal * (offset * scale)
        }
    }
}

// Small vector helpers (Linux has no simd module; distinct names so they
// never clash with simd's on Apple platforms).
fileprivate func len2(_ v: SIMD2<Float>) -> Float { (v.x * v.x + v.y * v.y).squareRoot() }
fileprivate func len3(_ v: SIMD3<Float>) -> Float { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
fileprivate func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
fileprivate func dot2(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.x + a.y * b.y }
fileprivate func unit2(_ v: SIMD2<Float>) -> SIMD2<Float> {
    let l = (v.x * v.x + v.y * v.y).squareRoot()
    return l > 1e-6 && l.isFinite ? v / l : SIMD2(0, 1)
}
