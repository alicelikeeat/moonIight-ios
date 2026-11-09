import Foundation
import CoreGraphics
import ImageIO

// v1.93: the character-sheet check and missing-view completion for the
// base-body card. Each picked view is measured with Vision and checked
// against ConceptSheetSpec. A missing back or side is proposed by making an
// AI 3D model of the front picture (on the user's computer, or with TripoSR
// on the phone) and drawing it from the missing side. Without an AI model
// the base body painted from the front is drawn instead, as a preview only:
// it adds no information, so it cannot be adopted. Nothing is used until
// the user adopts it.

enum ConceptSheetCheck {
    /// Measures and checks the given views (JPEG / PNG data per view).
    static func report(_ views: [PhotoView: Data], origins: [PhotoView: ConceptOrigin]) -> ConceptSheetReport {
        var inputs: [ConceptViewInput] = []
        for (view, data) in views {
            guard let image = BaseBodySkinPipeline.image(data) else { continue }
            let size = pixelSize(data) ?? (image.width, image.height)
            let photo = BaseBodyCharacterPipeline.measure(image, back: view == .back)
            let small = PixelReader.scaled(image, maxSide: 256).flatMap { ModelAnimationExport.raster($0) }
            inputs.append(ConceptViewInput(view: view, photo: photo, width: size.0, height: size.1,
                                           plainBorder: small.map { ConceptSheetSpec.plainBorder($0) } ?? 0, origin: origins[view] ?? .user))
        }
        return ConceptSheetSpec.check(inputs)
    }

    /// The picture's own size (the measuring uses a smaller copy).
    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let turned = ((p[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return turned ? (h, w) : (w, h)
    }
}

enum ConceptViewCompletion {
    enum Route: String, Sendable {
        case computer, phone, estimate
        var title: String {
            switch self {
            case .computer: L10n.t("电脑 AI 3D", "Computer AI 3D")
            case .phone: L10n.t("本机 AI 3D（TripoSR）", "On-device AI 3D (TripoSR)")
            case .estimate: L10n.t("底模估计（没有 AI）", "Base estimate (no AI)")
            }
        }
        var origin: ConceptOrigin { self == .estimate ? .estimate : .ai }
    }

    struct Proposal: @unchecked Sendable, Identifiable {
        var view: PhotoView
        var image: CGImage
        var jpeg: Data
        var origin: ConceptOrigin
        var id: PhotoView { view }
    }

    struct Result: @unchecked Sendable, Identifiable {
        let id = UUID()
        var proposals: [Proposal]
        var route: Route
        var notes: [String]
    }

    /// The best way available now: the computer when one is set up, then TripoSR on the phone.
    static var route: Route {
        if LocalServerClient.config != nil { return .computer }
        if TripoSROnDevice.installed && TripoSROnDevice.deviceSupported { return .phone }
        return .estimate
    }

    static func propose(front: CGImage, base: BaseBodyEntry, views: [PhotoView],
                        progress: @escaping @Sendable (String, Double) -> Void) async throws -> Result {
        let route = route
        var notes: [String] = []
        let mesh: GeneratedMesh, texture: RasterImage?
        switch route {
        case .computer:
            guard let config = LocalServerClient.config, let jpeg = PixelReader.jpeg(PixelReader.scaled(front, maxSide: 1536) ?? front, quality: 0.92) else { throw CloudRigError.notConfigured }
            let glb = try await LocalServerClient.generate(config, image: jpeg, progress: progress)
            let model = try Image3DServerProtocol.model(fromGLB: glb)
            mesh = model.mesh
            texture = model.texture ?? model.encodedTexture.flatMap { BaseBodySkinPipeline.image($0) }.flatMap { ModelAnimationExport.raster($0) }
            notes.append(L10n.t("在你的电脑上由 AI 从正面图推测出 3D 形体（\(config.baseURL.host ?? "")），再从缺少的方向画出来。", "An AI on your computer (\(config.baseURL.host ?? "")) inferred a 3D shape from the front picture; it is drawn from the missing sides."))
        case .phone:
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            guard let jpeg = PixelReader.jpeg(front, quality: 0.92) else { throw Generate3DError.unreadableImage }
            try jpeg.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try await TripoSROnDevice.run(url, resolution: 128, progress: progress)
            mesh = result.mesh; texture = result.texture
            notes.append(L10n.t("由 TripoSR 在本机从正面图推测出 3D 形体，再从缺少的方向画出来。", "TripoSR inferred a 3D shape from the front picture on this phone; it is drawn from the missing sides."))
        case .estimate:
            progress(L10n.t("识别人物", "Finding the person"), 0.2)
            guard let photo = BaseBodyCharacterPipeline.measure(front, back: false), photo.mid(.leftShoulder, .rightShoulder) != nil,
                  photo.mid(.leftHip, .rightHip) != nil else { throw BaseBodySkinPipeline.Failure.noPerson }
            guard let body = HumanBase.build(base.shape ?? .standard, lod: 1), let atlas = BaseBodyCharacterPipeline.atlas(front: front, back: nil) else { throw BaseBodySkinPipeline.Failure.unreadable }
            mesh = BaseBodyPaint.paint(body.model, front: photo, back: nil).mesh; texture = atlas
            notes.append(L10n.t("没有可用的 AI 3D：下面是只有正面图时底模的样子，只能预览，不能采用。要让 AI 补全，请在「AI 生成 3D → AI 图片转完整 3D」里设置电脑生成，或在本机安装 TripoSR。",
                                "No AI 3D is available: below is how the base looks with the front picture only. It is a preview and cannot be adopted. For AI proposals, set up computer generation or install TripoSR under AI 3D → Picture to full 3D."))
        }
        try Task.checkCancellation()
        progress(L10n.t("从缺少的方向画出视角", "Drawing the missing views"), 0.95)
        var offset: Float = 0
        if route != .estimate, let target = ModelAnimationExport.raster(PixelReader.scaled(front, maxSide: 256) ?? front) {
            offset = ConceptViewRender.facing(mesh, texture: texture, front: target)
            if offset != 0 { notes.append(L10n.t("AI 模型生成时没有朝正面，已按正面图自动转正。", "The AI model did not face forward; it was turned to match the front picture.")) }
        }
        var proposals: [Proposal] = []
        for view in views {
            guard let raster = ConceptViewRender.render(mesh, texture: texture, view: view, facing: offset), let cg = ModelAnimationExport.cgImage(raster),
                  let jpeg = PixelReader.jpeg(cg, quality: 0.9) else { continue }
            proposals.append(Proposal(view: view, image: cg, jpeg: jpeg, origin: route.origin))
        }
        if route != .estimate {
            notes.append(L10n.t("AI 看不到背面和侧面，这些是它的推测：头发、背后图案、配饰可能和你的设定不同。只采用你确认一致的视角。", "The AI cannot see the back or side; these are guesses. Hair, back details and accessories may differ from your design. Adopt only views you confirm match."))
        }
        return Result(proposals: proposals, route: route, notes: notes)
    }
}
