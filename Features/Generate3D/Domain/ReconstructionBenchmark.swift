import Foundation

// v1.92: a scored benchmark for photo → 3D. The subjects are HumanBase
// bodies with known shapes, so the true 3D answer exists. Each subject is
// "photographed" with the software rasteriser (masks and colours, like a
// segmented photo), every method rebuilds a body from those pictures, and
// the result is compared with the truth:
//   - silhouette IoU from angles that were never photographed,
//   - chamfer distance between the surfaces (in body sizes),
//   - joint error (body-based methods: mean distance of the 27 standard
//     joints from the true ones, pelvis-aligned, in body heights).
// Everything is normalised by size, so a method is not rewarded or punished
// for guessing the absolute height. Pure Swift (runs in the domain tests).

enum ReconstructionMethod: String, CaseIterable, Sendable {
    /// The standard body whatever the photo shows: the floor any method must beat.
    case neutral
    /// One front photo → body points and outline → HumanBase shape (the app's person path).
    case photoFit
    /// Silhouette carving from front and back photos.
    case carve2
    /// Silhouette carving from front, back, left and right photos.
    case carve4
}

struct ReconstructionScore: Sendable {
    var subject: String
    var method: ReconstructionMethod
    /// Mean silhouette IoU over unseen views (1 = identical outline).
    var iou: Float
    /// Symmetric chamfer distance, in units of the body's largest extent.
    var chamfer: Float
    /// Mean joint error in body heights (nil for meshes without a skeleton).
    var jointError: Float?
    var seconds: Double
    var failure: String?
}

enum ReconstructionBenchmark {
    struct Subject: Sendable { var name: String; var shape: HumanShape }

    /// Varied bodies: proportions, build and head ratio all differ.
    static var subjects: [Subject] {
        func make(_ name: String, _ edit: (inout HumanShape) -> Void) -> Subject { var s = HumanShape.standard; edit(&s); return Subject(name: name, shape: s.clamped) }
        return [
            Subject(name: "standard", shape: .standard),
            Subject(name: "tall", shape: HumanShape.tall.clamped),
            make("chibi") { $0.height = 1.1; $0.headSize = 1.7; $0.legLength = 0.75; $0.armLength = 0.85 },
            make("heavy") { $0.height = 1.7; $0.build = 0.9; $0.waist = 0.7; $0.hips = 0.5 },
            make("slim-long-legs") { $0.height = 1.85; $0.build = -0.7; $0.legLength = 1.25; $0.shoulders = -0.4 },
            make("broad-short") { $0.height = 1.55; $0.muscle = 0.8; $0.shoulders = 0.9; $0.legLength = 0.85; $0.gender = 0.8 },
            make("feminine") { $0.height = 1.65; $0.gender = -0.9; $0.hips = 0.6; $0.waist = -0.4; $0.shoulders = -0.5 },
            make("long-arms") { $0.height = 1.8; $0.armLength = 1.25; $0.torsoLength = 1.15 },
        ]
    }

    // MARK: Pictures

    static let photoSize = 192
    /// Narrow field of view: close to the orthographic photos the carver assumes.
    static func camera(yaw: Float, pitch: Float = 0) -> RasterCamera { RasterCamera(yaw: yaw, pitch: pitch, fieldOfView: 10, margin: 1.1, lighting: true) }

    /// A mesh moved and scaled into the unit cube (the rasteriser's frame).
    struct Frame { var centre: SIMD3<Float>; var scale: Float }
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

    static func photo(_ mesh: GeneratedMesh, positions: [Float], view: PhotoView) -> ViewPhoto {
        let image = ModelRasterizer.render(mesh, positions: positions, texture: nil, colors: nil, camera: camera(yaw: yaw(view)),
                                           width: photoSize, height: photoSize, supersample: 2)
        let mask = stride(from: 3, to: image.rgba.count, by: 4).map { Float(image.rgba[$0]) / 255 }
        return ViewPhoto(width: image.width, height: image.height, mask: mask, image: image)
    }

    /// Where a point of the normalised model lands in a front picture, in
    /// pixels (the rasteriser's own projection, pitch 0).
    static func project(_ p: SIMD3<Float>, size: Int = photoSize) -> SIMD2<Float> {
        let c = camera(yaw: 0)
        let f = 1 / tan(c.fieldOfView * .pi / 360)
        let distance = 0.5 * c.margin * f + 0.6
        let zc = max(0.01, distance - p.z)
        return SIMD2((p.x * f / zc * 0.5 + 0.5) * Float(size), (0.5 - p.y * f / zc * 0.5) * Float(size))
    }

    /// What Vision would report for the front picture: 19 body points (from
    /// the true joints) and the outline (from the mask). Units: picture
    /// heights, y up.
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

    // MARK: Scores

    /// Silhouette IoU over views no method was given (three-quarter, oblique and from above).
    static let unseenViews: [RasterCamera] = [0.6, 1.0, 2.3, 2.9, -0.8].map { camera(yaw: $0) } + [camera(yaw: 0.7, pitch: 0.6)]

    static func iou(_ a: GeneratedMesh, _ b: GeneratedMesh, size: Int = 96) -> Float {
        let pa = normalised(a, frame(a)), pb = normalised(b, frame(b))
        var total: Float = 0
        for camera in unseenViews {
            var c = camera; c.lighting = false
            let ma = ModelRasterizer.render(a, positions: pa, texture: nil, camera: c, width: size, height: size, supersample: 1)
            let mb = ModelRasterizer.render(b, positions: pb, texture: nil, camera: c, width: size, height: size, supersample: 1)
            var both = 0, either = 0
            for i in stride(from: 3, to: ma.rgba.count, by: 4) {
                let x = ma.rgba[i] > 127, y = mb.rgba[i] > 127
                if x && y { both += 1 }
                if x || y { either += 1 }
            }
            total += either > 0 ? Float(both) / Float(either) : 0
        }
        return total / Float(unseenViews.count)
    }

    /// Mean nearest-point distance both ways, on up to `samples` vertices each.
    static func chamfer(_ a: GeneratedMesh, _ b: GeneratedMesh, samples: Int = 1200) -> Float {
        func points(_ m: GeneratedMesh) -> [SIMD3<Float>] {
            let p = normalised(m, frame(m)), n = p.count / 3
            let step = max(1, n / samples)
            return stride(from: 0, to: n, by: step).map { SIMD3(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }
        }
        let x = points(a), y = points(b)
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        func oneWay(_ from: [SIMD3<Float>], _ to: [SIMD3<Float>]) -> Float {
            var sum: Float = 0
            for p in from {
                var best = Float.infinity
                for q in to { let d = p - q; best = min(best, (d * d).sum()) }
                sum += best.squareRoot()
            }
            return sum / Float(from.count)
        }
        return (oneWay(x, y) + oneWay(y, x)) / 2
    }

    /// Mean distance of the standard joints, pelvis-aligned, in body heights.
    static func jointError(_ truth: HumanBody, _ guess: HumanBody) -> Float? {
        func positions(_ b: HumanBody) -> [String: SIMD3<Float>] {
            let world = b.skeleton.worldRest
            var out: [String: SIMD3<Float>] = [:]
            for (i, j) in b.skeleton.joints.enumerated() where !j.isExtension { out[j.jointID] = world[i].origin }
            guard let pelvis = out["pelvis"] else { return [:] }
            let h = max(0.1, b.shape.height)
            return out.mapValues { ($0 - pelvis) / h }
        }
        let t = positions(truth), g = positions(guess)
        let shared = t.keys.filter { g[$0] != nil }
        guard !shared.isEmpty else { return nil }
        let sum = shared.reduce(Float(0)) { acc, id in let d = t[id]! - g[id]!; return acc + (d * d).sum().squareRoot() }
        return sum / Float(shared.count)
    }

    // MARK: Running

    static func run(_ subjects: [Subject] = subjects, methods: [ReconstructionMethod] = ReconstructionMethod.allCases) -> [ReconstructionScore] {
        var scores: [ReconstructionScore] = []
        for subject in subjects {
            guard let truth = HumanBase.build(subject.shape, lod: 0) else {
                scores += methods.map { ReconstructionScore(subject: subject.name, method: $0, iou: 0, chamfer: 1, seconds: 0, failure: "no base body") }
                continue
            }
            let truthFrame = frame(truth.mesh)
            let truthPositions = normalised(truth.mesh, truthFrame)
            var photos: [PhotoView: ViewPhoto] = [:]
            for view in [PhotoView.front, .back, .left, .right] { photos[view] = photo(truth.mesh, positions: truthPositions, view: view) }
            for method in methods {
                let start = Date()
                var mesh: GeneratedMesh?
                var body: HumanBody?
                var failure: String?
                switch method {
                case .neutral:
                    var shape = HumanShape.standard; shape.height = subject.shape.height
                    body = HumanBase.build(shape, lod: 1)
                case .photoFit:
                    let fit = BodyPhotoFit.shape(bodyPhoto(truth, frame: truthFrame, front: photos[.front]!), height: subject.shape.height)
                    if !fit.usable { failure = "fit not usable: " + fit.defaulted.joined(separator: ",") }
                    body = HumanBase.build(HumanShape.fitting(fit.shape, measured: Set(fit.measured)), lod: 1)
                case .carve2, .carve4:
                    let views: [PhotoView] = method == .carve2 ? [.front, .back] : [.front, .back, .left, .right]
                    do { mesh = try MultiViewCarver.build(photos.filter { views.contains($0.key) }).mesh } catch { failure = "\(error)" }
                }
                if let body { mesh = body.mesh }
                let seconds = Date().timeIntervalSince(start)
                guard let mesh, mesh.triangleCount > 0 else {
                    scores.append(ReconstructionScore(subject: subject.name, method: method, iou: 0, chamfer: 1, seconds: seconds, failure: failure ?? "no mesh"))
                    continue
                }
                scores.append(ReconstructionScore(subject: subject.name, method: method, iou: iou(truth.mesh, mesh), chamfer: chamfer(truth.mesh, mesh),
                                                  jointError: body.flatMap { jointError(truth, $0) }, seconds: seconds, failure: failure))
            }
        }
        return scores
    }

    struct Summary: Sendable { var method: ReconstructionMethod; var iou: Float; var chamfer: Float; var jointError: Float?; var seconds: Double; var failures: Int }

    static func summary(_ scores: [ReconstructionScore]) -> [Summary] {
        ReconstructionMethod.allCases.compactMap { m in
            let s = scores.filter { $0.method == m }
            guard !s.isEmpty else { return nil }
            let n = Float(s.count)
            let joints = s.compactMap(\.jointError)
            return Summary(method: m, iou: s.map(\.iou).reduce(0, +) / n, chamfer: s.map(\.chamfer).reduce(0, +) / n,
                           jointError: joints.isEmpty ? nil : joints.reduce(0, +) / Float(joints.count),
                           seconds: s.map(\.seconds).reduce(0, +) / Double(s.count), failures: s.filter { $0.failure != nil }.count)
        }
    }

    /// A Markdown table: one row per subject and method, then the means.
    static func report(_ scores: [ReconstructionScore]) -> String {
        func f(_ v: Float?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
        var lines = ["| subject | method | IoU ↑ | chamfer ↓ | joints ↓ | s | note |", "|---|---|---|---|---|---|---|"]
        for s in scores {
            lines.append("| \(s.subject) | \(s.method.rawValue) | \(f(s.iou)) | \(f(s.chamfer)) | \(f(s.jointError)) | \(String(format: "%.2f", s.seconds)) | \(s.failure ?? "") |")
        }
        lines.append("")
        lines.append("| method | mean IoU ↑ | mean chamfer ↓ | mean joints ↓ | s | failures |")
        lines.append("|---|---|---|---|---|---|")
        for m in summary(scores) {
            lines.append("| \(m.method.rawValue) | \(f(m.iou)) | \(f(m.chamfer)) | \(f(m.jointError)) | \(String(format: "%.2f", m.seconds)) | \(m.failures) |")
        }
        return lines.joined(separator: "\n")
    }
}
