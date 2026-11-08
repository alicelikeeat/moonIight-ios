import Foundation
import Vision
import ImageIO
import CoreGraphics

// v1.90: a photo of a whole person → the universal base body, fitted to
// their proportions and painted with the photo (and their back photo when
// there is one). The result is a full 360° character with the base body's
// own skeleton and weights, so it animates like every other base body.
// Photos without a whole person keep the depth-relief route.

struct BaseBodyCharacterOutput: Sendable {
    var mesh: GeneratedMesh
    var skin: SkinInfluences
    var skeleton: SkeletonDefinition
    var atlas: RasterImage
    var fit: BodyFitResult
    var backPhoto: Bool
    var notes: [String]
}

enum BaseBodyCharacterPipeline {
    typealias Progress = @Sendable (String, Double?) -> Void
    static let maxSide = 1024

    /// nil: no whole person in the front photo (the caller falls back).
    static func run(front: URL, back: URL?, progress: @escaping Progress) async throws -> BaseBodyCharacterOutput? {
        try await Generate3DGuard.checkpoint(needsMemory: 120_000_000, progress: progress)
        progress(L10n.t("寻找人物", "Looking for a person"), 0.1)
        guard let frontImage = load(front), let frontPhoto = measure(frontImage, back: false) else { return nil }
        let fit = BodyPhotoFit.shape(frontPhoto)
        guard fit.usable else { return nil }
        try Task.checkCancellation()
        var backImage: CGImage?, backPhoto: BodyPhoto?
        if let back, let image = load(back), let photo = measure(image, back: true), photo.mid(.leftShoulder, .rightShoulder) != nil, photo.mid(.leftHip, .rightHip) != nil {
            backImage = image; backPhoto = photo
        }
        progress(L10n.t("套用通用底模", "Fitting the universal base body"), 0.45)
        let model = BaseBody.build(fit.shape)
        let painted = BaseBodyPaint.paint(model, front: frontPhoto, back: backPhoto)
        try Task.checkCancellation()
        progress(L10n.t("制作贴图", "Making the texture"), 0.7)
        guard let atlas = atlas(front: frontImage, back: backImage) else { throw Generate3DError.saveFailed("texture") }

        var notes = [L10n.t("识别到完整人物，已套用通用底模（\(model.mesh.vertexCount) 顶点、27 关节，权重由底模直接给出）。",
                            "A whole person was found, so the universal base body was used (\(model.mesh.vertexCount) vertices, 27 joints, weights given by the base body).")]
        notes.append(L10n.t(String(format: "按照片估计的体型：腿长占身高 %.0f%%，肩宽 %.0f%%，头部 %.0f%%（身高按 1.7 米设定）。", fit.shape.legRatio * 100, fit.shape.shoulderWidth * 100, fit.shape.headRatio * 100),
                            String(format: "Proportions from the photo: legs %.0f%% of the height, shoulders %.0f%%, head %.0f%% (height set to 1.7 m).", fit.shape.legRatio * 100, fit.shape.shoulderWidth * 100, fit.shape.headRatio * 100)))
        if !fit.defaulted.isEmpty {
            notes.append(L10n.t("照片里看不清的部分用了标准值：", "Standard values where the photo was unclear: ") + fit.defaulted.joined(separator: ", "))
        }
        if backImage == nil {
            notes.append(back == nil
                ? L10n.t("背面没有照片，只用正面的模糊颜色推测（头发、背后图案不会出现）。在「多张照片」里加一张背面照可以补全。",
                         "No back photo: the back uses blurred colours from the front (no hair or back details). Add a back photo under Several photos to fill it in.")
                : L10n.t("背面照片里没有认出人物，背面改用正面的模糊颜色。", "No person found in the back photo; the back uses blurred colours from the front."))
        }
        if painted.unpainted > 0 { notes.append(L10n.t("\(painted.unpainted) 个顶点没有对应到照片，使用默认颜色。", "\(painted.unpainted) vertices had no spot in the photos and use a default colour.")) }
        notes.append(L10n.t("脸部和衣服是照片投影上去的贴图，不是雕刻出来的形状；宽松衣服、裙子和长发会贴在身体上。",
                            "The face and clothes are the photo projected as a texture, not sculpted shape; loose clothes, skirts and long hair lie on the body."))
        return BaseBodyCharacterOutput(mesh: painted.mesh, skin: painted.skin, skeleton: model.skeleton, atlas: atlas, fit: fit, backPhoto: backImage != nil, notes: notes)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), image.width >= 64, image.height >= 64 else { return nil }
        return image
    }

    private static let names: [(VNHumanBodyPoseObservation.JointName, PhotoJoint)] = [
        (.nose, .nose), (.leftEye, .leftEye), (.rightEye, .rightEye), (.leftEar, .leftEar), (.rightEar, .rightEar), (.neck, .neck),
        (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder), (.leftElbow, .leftElbow), (.rightElbow, .rightElbow),
        (.leftWrist, .leftWrist), (.rightWrist, .rightWrist), (.root, .root), (.leftHip, .leftHip), (.rightHip, .rightHip),
        (.leftKnee, .leftKnee), (.rightKnee, .rightKnee), (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle),
    ]

    /// Vision's body points and person outline, in BodyPhoto units.
    static func measure(_ image: CGImage, back: Bool) -> BodyPhoto? {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let pose = VNDetectHumanBodyPoseRequest()
        let people = VNGeneratePersonSegmentationRequest()
        people.qualityLevel = .accurate
        people.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([pose, people])) != nil else { return nil }
        // The most clearly seen person.
        let bodies = (pose.results ?? []).compactMap { try? $0.recognizedPoints(.all) }
        guard let found = bodies.max(by: { $0.values.filter { $0.confidence > 0.3 }.count < $1.values.filter { $0.confidence > 0.3 }.count }) else { return nil }
        let aspect = Float(image.width) / Float(image.height)
        var points: [PhotoJoint: BodyPhoto.Point] = [:]
        for (name, joint) in names {
            guard let p = found[name], p.confidence > 0 else { continue }
            // Vision: normalised, origin bottom-left (y up) — the BodyPhoto convention, x scaled by the aspect.
            points[joint] = .init(x: Float(p.location.x) * aspect, y: Float(p.location.y), confidence: Float(p.confidence))
        }
        var rows: [BodyPhoto.Row] = []
        if let buffer = people.results?.first?.pixelBuffer, let mask = PixelReader.floats(buffer), mask.width > 0, mask.height > 0 {
            let step = max(1, mask.height / 240)
            for row in stride(from: 0, to: mask.height, by: step) {
                var spans: [SIMD2<Float>] = []
                var start: Int?
                for col in 0...mask.width {
                    let inside = col < mask.width && mask.values[row * mask.width + col] >= 0.5
                    if inside, start == nil { start = col }
                    if !inside, let s = start {
                        spans.append(SIMD2(Float(s) / Float(mask.width) * aspect, Float(col) / Float(mask.width) * aspect)); start = nil
                    }
                }
                // Mask rows run top-down; BodyPhoto's y runs up.
                rows.append(.init(y: 1 - (Float(row) + 0.5) / Float(mask.height), spans: spans))
            }
        }
        return BodyPhoto(points: points, outline: rows, aspect: aspect, back: back)
    }

    /// Front photo on the left half; the back photo (or a blurred,
    /// colour-only copy of the front) on the right half.
    static func atlas(front: CGImage, back: CGImage?) -> RasterImage? {
        let w = front.width, h = front.height
        var pixels = [UInt8](repeating: 255, count: w * 2 * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w * 2, height: h, bitsPerComponent: 8, bytesPerRow: w * 8,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(front, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let back { context.draw(back, in: CGRect(x: w, y: 0, width: w, height: h)) }
            else if let tiny = PixelReader.scaled(front, maxSide: 24) { context.draw(tiny, in: CGRect(x: w, y: 0, width: w, height: h)) }
            return true
        }
        guard drawn else { return nil }
        for i in 0..<(w * 2 * h) { pixels[i * 4 + 3] = 255 }
        return RasterImage(width: w * 2, height: h, rgba: pixels)
    }
}

@available(iOS 18.0, *)
extension Generated3DStore {
    /// Saves a base-body character with its exact rig (ready to animate).
    func storeBaseBody(_ built: BaseBodyCharacterOutput, name: String, sourceName: String, hash: String) async throws -> Generated3DManifest {
        let id = UUID().uuidString
        let meshFile = id + ".m3dg", textureFile = id + ".jpg"
        let mesh = built.mesh, atlas = built.atlas
        let meshURL = Self.folder("Models").appendingPathComponent(meshFile)
        let textureURL = Self.folder("Textures").appendingPathComponent(textureFile)
        let thumbURL = Self.folder("Thumbnails").appendingPathComponent(id + ".jpg")
        try await Task.detached(priority: .userInitiated) {
            try GeneratedMeshCodec.encode(mesh).write(to: meshURL, options: .atomic)
            guard let image = ModelAnimationExport.cgImage(atlas), let jpeg = PixelReader.jpeg(image, quality: 0.9) else { throw Generate3DError.saveFailed("texture") }
            try jpeg.write(to: textureURL, options: .atomic)
            var framed = mesh; framed.normalize(size: 1)
            let thumb = ModelRasterizer.render(framed, texture: atlas, camera: RasterCamera(yaw: 0.35, lighting: true), width: 256, height: 256, background: [40, 44, 56, 255])
            if let cg = ModelAnimationExport.cgImage(thumb), let data = PixelReader.jpeg(cg, quality: 0.85) { try? data.write(to: thumbURL, options: .atomic) }
        }.value
        let skeleton = built.skeleton, skin = built.skin
        let results = await Task.detached(priority: .userInitiated) { RiggingPipeline.test(mesh, skeleton: skeleton, skin: skin) }.value
        let character = RiggedCharacter(modelID: id, meshFile: meshFile, optimizedMeshFile: nil, skinFile: id + ".skin", vertexCount: mesh.vertexCount,
                                        skeleton: skeleton, clips: MotionClip.library, sockets: SkeletonBuilder.sockets(skeleton),
                                        diagnostics: RiggingDiagnostics(results: results),
                                        metadata: RiggedCharacterMetadata(engine: "Moonlight Base Body", engineVersion: "1.90.0", route: "baseBody",
                                                                          createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), poseType: "aPose"))
        try RiggingAssetStore(folder: Self.folder("Rigs")).save(character, skin: skin, optimizedMesh: nil)
        let passed = results.filter { $0.status == .pass }.count
        let manifest = Generated3DManifest(
            id: id, name: name, createdAt: Date(), source: .image, sourceName: sourceName, sourceHash: hash,
            engine: "Moonlight Base Body", engineVersion: "1.90", depthSource: .none, geometry: .baseBody, quality: .medium,
            vertexCount: mesh.vertexCount, triangleCount: mesh.triangleCount, textureWidth: atlas.width, textureHeight: atlas.height,
            meshFile: meshFile, textureFile: textureFile, usdzFile: nil, thumbnailFile: id + ".jpg",
            humanoidDetected: true, rigging: .experimentalVerified, animation: .experimentalVerified, separableParts: .notAvailable,
            notes: built.notes + [L10n.t("动作测试 \(results.count) 项通过 \(passed) 项。尚未经过人工真机验收。",
                                         "\(passed) of \(results.count) motion tests passed. Not yet accepted on a device by a person.")])
        try save(manifest)
        return manifest
    }
}
