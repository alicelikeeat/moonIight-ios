import Foundation
import CoreGraphics
import ImageIO

// v1.92: skins for base bodies from the AI 3D page's sources. A person in a
// photo (optionally with a back photo), the frames of a video, or the front
// and back figures of a character sheet are measured with Vision and turned
// into a CharacterSkin (the measurements) plus a texture atlas; the chosen
// base body is repainted from them and can take the photo's proportions.

enum BaseBodySkinPipeline {
    struct Output: Sendable {
        var appearance: CharacterAppearance
        var atlas: Data
        var notes: [String]
    }

    enum Failure: Error, LocalizedError, Equatable {
        case noPerson, unreadable, noFrames
        var errorDescription: String? {
            switch self {
            case .noPerson: L10n.t("没有在图片里认出人物的肩和胯，无法贴到底模上。请换一张能看到整个人的图片。", "No person's shoulders and hips were found, so the picture cannot be painted onto the base. Try one that shows the whole person.")
            case .unreadable: L10n.t("图片无法读取", "The picture could not be read")
            case .noFrames: L10n.t("视频里没有找到清楚的人物画面", "No clear frame of a person was found in the video")
            }
        }
    }

    /// Paints `base` with a front picture (and a back one when given).
    static func make(base: BaseBodyEntry, keeping look: CharacterAppearance = CharacterAppearance(), front: CGImage, back: CGImage?,
                     source: CharacterSkin.Source, fitShape: Bool) throws -> Output {
        guard let frontPhoto = BaseBodyCharacterPipeline.measure(front, back: false),
              frontPhoto.mid(.leftShoulder, .rightShoulder) != nil, frontPhoto.mid(.leftHip, .rightHip) != nil else { throw Failure.noPerson }
        var backPhoto: BodyPhoto?, backImage: CGImage?
        if let back, let p = BaseBodyCharacterPipeline.measure(back, back: true), p.mid(.leftShoulder, .rightShoulder) != nil, p.mid(.leftHip, .rightHip) != nil {
            backPhoto = p; backImage = back
        }
        var appearance = look
        appearance.use(base)
        var notes = [L10n.t("底模：\(base.name)；皮肤来自\(source.title)。", "Base: \(base.name); skin from a \(source.title.lowercased()).")]
        let fit = BodyPhotoFit.shape(frontPhoto)
        if fitShape, fit.usable {
            // The photo's proportions on top of the base's own character (gender, age, size stay the base's).
            let f = HumanShape.fitting(fit.shape, measured: Set(fit.measured))
            appearance.shape.legLength = f.legLength; appearance.shape.armLength = f.armLength
            appearance.shape.headSize = appearance.shape.headSize * f.headSize
            appearance.shape.shoulders = f.shoulders; appearance.shape.hips = f.hips; appearance.shape.build = f.build
            appearance.shape = appearance.shape.clamped
            notes.append(L10n.t("体型按照片调整了腿长、手臂、头身比、肩宽和胖瘦。", "Leg and arm length, head ratio, shoulders and build follow the photo."))
        } else if fitShape {
            notes.append(L10n.t("照片里看不到整个人，体型保留底模原样，只贴皮肤。", "The whole person is not visible; the base keeps its shape and only gets the skin."))
        }
        appearance.painted = CharacterSkin(source: source, front: frontPhoto, back: backPhoto)
        if backPhoto == nil {
            notes.append(L10n.t("没有背面图：背面用正面颜色模糊推测，头发和背后图案不会出现。", "No back picture: the back uses blurred colours from the front; hair and back details will not show."))
        }
        notes.append(L10n.t("贴图是投影上去的，不是雕刻的形状；宽松衣服和长发会贴在身体上。", "The picture is projected, not sculpted; loose clothes and long hair lie on the body."))
        guard let atlas = BaseBodyCharacterPipeline.atlas(front: front, back: backImage), let cg = ModelAnimationExport.cgImage(atlas),
              let jpeg = PixelReader.jpeg(cg, quality: 0.88) else { throw Failure.unreadable }
        return Output(appearance: appearance, atlas: jpeg, notes: notes)
    }

    static func image(_ url: URL) -> CGImage? { BaseBodyCharacterPipeline.load(url) }
    static func image(_ data: Data) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: BaseBodyCharacterPipeline.maxSide]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The video's best front frame (face and whole body seen) and, if the
    /// person turns, its best back frame (shoulders and hips, no face).
    static func frames(_ analysis: VideoAnalysis) throws -> (front: CGImage, back: CGImage?) {
        let ordered = analysis.kept.sorted { $0.sharpness > $1.sharpness }.prefix(16)
        var front: (CGImage, Float)?, back: (CGImage, Float)?
        for stat in ordered {
            let url = analysis.framesFolder.appendingPathComponent(String(format: "frame_%03d.jpg", stat.index))
            guard let image = BaseBodyCharacterPipeline.load(url), let p = BaseBodyCharacterPipeline.measure(image, back: false),
                  p.mid(.leftShoulder, .rightShoulder) != nil, p.mid(.leftHip, .rightHip) != nil else { continue }
            let seen = Float(p.points.values.filter { $0.confidence > 0.3 }.count)
            let face = max(p.points[.nose]?.confidence ?? 0, p.points[.leftEye]?.confidence ?? 0, p.points[.rightEye]?.confidence ?? 0)
            if face > 0.4 { if seen > (front?.1 ?? -1) { front = (image, seen) } }
            else if face < 0.1 { if seen > (back?.1 ?? -1) { back = (image, seen) } }
        }
        guard let front else { throw Failure.noFrames }
        return (front.0, back?.0)
    }

    /// The front, back and side figures of a character sheet.
    static func sheet(_ data: Data) throws -> (front: CGImage, back: CGImage?, side: CGImage?) {
        let analysis = try SheetPipeline.analyze(data)
        func crop(_ view: PhotoView) -> CGImage? {
            guard let panel = analysis.panels.first(where: { $0.view == view }) else { return nil }
            let pad = Int(Double(max(panel.w, panel.h)) * 0.06)
            let rect = CGRect(x: panel.x0 - pad, y: panel.y0 - pad, width: panel.w + 2 * pad, height: panel.h + 2 * pad)
                .intersection(CGRect(x: 0, y: 0, width: analysis.image.width, height: analysis.image.height))
            return analysis.image.cropping(to: rect)
        }
        guard let front = crop(.front) ?? analysis.panels.first.flatMap({ p in analysis.image.cropping(to: CGRect(x: p.x0, y: p.y0, width: p.w, height: p.h)) }) else { throw Failure.noPerson }
        return (front, crop(.back), crop(.left) ?? crop(.right))
    }
}
