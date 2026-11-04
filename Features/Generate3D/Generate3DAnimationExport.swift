import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

// v1.72: generated 3D models as GIFs and videos. Frames come from
// `ModelRasterizer` (the real mesh, deformed by its rig for motion clips),
// written frame by frame (bounded memory), checked for heat and cancel.

enum ModelAnimationExport {
    enum Content: Hashable, Sendable {
        case turntable
        case clip(String)
        var title: String {
            switch self {
            case .turntable: L10n.t("360° 转台", "360° Turntable")
            case .clip(let id): RigClip.standard.first { $0.id == id }?.name ?? id
            }
        }
    }
    enum Format: String, CaseIterable, Sendable { case gif, mp4
        var title: String { self == .gif ? "GIF" : L10n.t("视频 MP4", "Video MP4") }
    }
    enum Background: String, CaseIterable, Sendable { case clear, dark, light
        var title: String { switch self { case .clear: L10n.t("透明", "Clear"); case .dark: L10n.t("深色", "Dark"); case .light: L10n.t("浅色", "Light") } }
        var rgba: [UInt8] { switch self { case .clear: [0, 0, 0, 0]; case .dark: [24, 26, 34, 255]; case .light: [236, 238, 244, 255] } }
    }
    struct Options: Sendable {
        var content = Content.turntable
        var format = Format.gif
        var background = Background.clear
        var size = 360
        var lighting = true
    }

    /// Everything a frame needs, loaded once.
    struct Source: Sendable {
        var mesh: GeneratedMesh
        var texture: RasterImage?
        var rig: (package: RigPackage, skin: SkinWeights)?
    }

    static func loadSource(mesh meshURL: URL, texture textureURL: URL?, rig: (RigPackage, SkinWeights)?) throws -> Source {
        guard let data = try? Data(contentsOf: meshURL), let mesh = GeneratedMeshCodec.decode(data) else { throw Generate3DError.meshFailed }
        var texture: RasterImage?
        if let textureURL, let source = CGImageSourceCreateWithURL(textureURL as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024] as [CFString: Any] as CFDictionary) {
            texture = raster(image)
        }
        return Source(mesh: mesh, texture: texture, rig: rig.flatMap { $0.1.count == mesh.vertexCount ? (package: $0.0, skin: $0.1) : nil })
    }

    /// CGImage → RGBA rows top to bottom (bitmap contexts store the top row first).
    static func raster(_ image: CGImage) -> RasterImage? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RasterImage(width: w, height: h, rgba: pixels) : nil
    }

    static func cgImage(_ image: RasterImage) -> CGImage? {
        let data = Data(image.rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Frames for the content: turntable views or one loop of a clip.
    static func frames(_ source: Source, content: Content, fps: Float, baseYaw: Float = 0.35) -> [(camera: RasterCamera, clip: RigClip?, time: Float)] {
        switch content {
        case .turntable:
            return ModelExportPlan.turntable(frames: Int(fps * 2.4)).map { ($0, nil, 0) }
        case .clip(let id):
            guard let clip = source.rig?.package.clips.first(where: { $0.id == id }) else { return [(RasterCamera(yaw: baseYaw), nil, 0)] }
            return ModelExportPlan.times(period: clip.period, fps: fps).map { (RasterCamera(yaw: baseYaw), clip, $0) }
        }
    }

    static func render(_ source: Source, camera: RasterCamera, clip: RigClip?, time: Float, size: Int, background: [UInt8], lighting: Bool) -> RasterImage {
        var shot = camera; shot.lighting = lighting
        if let clip, let rig = source.rig {
            let posed = RigPose.deform(source.mesh, skin: rig.skin, matrices: RigPose.matrices(rig.package.skeleton, clip: clip, time: time))
            return ModelRasterizer.render(source.mesh, positions: posed.positions, normals: posed.normals, texture: source.texture, camera: shot, width: size, height: size, background: background)
        }
        return ModelRasterizer.render(source.mesh, texture: source.texture, camera: shot, width: size, height: size, background: background)
    }

    /// Writes a GIF or MP4 to a temporary file and returns it.
    static func export(_ source: Source, options: Options, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fps: Float = options.format == .gif ? 15 : 30
        let plan = frames(source, content: options.content, fps: fps)
        let size = options.size / 2 * 2
        let background = options.format == .mp4 && options.background == .clear ? Background.dark.rgba : options.background.rgba
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moonlight-model-" + UUID().uuidString).appendingPathExtension(options.format.rawValue)
        switch options.format {
        case .gif:
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, plan.count, nil) else { throw Generate3DError.saveFailed("GIF") }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(fps), kCGImagePropertyGIFUnclampedDelayTime: 1 / Double(fps)]] as CFDictionary
            for (i, frame) in plan.enumerated() {
                try await Generate3DGuard.checkpoint { _, _ in }
                let image = render(source, camera: frame.camera, clip: frame.clip, time: frame.time, size: size, background: background, lighting: options.lighting)
                guard let cg = cgImage(image) else { continue }
                CGImageDestinationAddImage(destination, cg, frameProperties)
                progress(Double(i + 1) / Double(plan.count))
            }
            guard CGImageDestinationFinalize(destination) else { throw Generate3DError.saveFailed("GIF") }
        case .mp4:
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size, kCVPixelBufferHeightKey as String: size])
            guard writer.canAdd(input) else { throw Generate3DError.saveFailed("MP4") }
            writer.add(input)
            guard writer.startWriting() else { throw Generate3DError.saveFailed(writer.error?.localizedDescription ?? "MP4") }
            writer.startSession(atSourceTime: .zero)
            // Two loops of a clip (one turn for the turntable) read better as video.
            let loops = options.content == .turntable ? 1 : 2
            let total = plan.count * loops
            for i in 0..<total {
                try await Generate3DGuard.checkpoint { _, _ in }
                let frame = plan[i % plan.count]
                let image = render(source, camera: frame.camera, clip: frame.clip, time: frame.time, size: size, background: background, lighting: options.lighting)
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                guard let pool = adaptor.pixelBufferPool else { throw Generate3DError.saveFailed("MP4") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw Generate3DError.saveFailed("MP4") }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let base = CVPixelBufferGetBaseAddress(buffer) {
                    let row = CVPixelBufferGetBytesPerRow(buffer)
                    for y in 0..<size { for x in 0..<size {
                        let s = (y * size + x) * 4, d = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
                        d[0] = image.rgba[s + 2]; d[1] = image.rgba[s + 1]; d[2] = image.rgba[s]; d[3] = 255
                    } }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
                progress(Double(i + 1) / Double(total))
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw Generate3DError.saveFailed(writer.error?.localizedDescription ?? "MP4") }
        }
        return url
    }

    /// Eight-direction picture character: one transparent GIF per baked clip
    /// and direction (front first, clockwise). Returns the files with their
    /// clip id and direction, plus the figure's height share and foot anchor
    /// measured from the rendered front idle frame.
    static func spriteSheets(_ source: Source, size: Int = 192, progress: @escaping @Sendable (Double) -> Void) async throws
        -> (files: [(clip: String, direction: Int, url: URL)], figure: Double, foot: Double) {
        let clips = source.rig == nil ? [ModelExportPlan.spriteClips[0]] : ModelExportPlan.spriteClips
        var files: [(String, Int, URL)] = []
        let total = clips.count * 8
        for (c, entry) in clips.enumerated() {
            for (d, yaw) in ModelExportPlan.directionYaws.enumerated() {
                try await Generate3DGuard.checkpoint { _, _ in }
                let clip = source.rig?.package.clips.first { $0.id == entry.clip }
                let times = clip.map { ModelExportPlan.times(period: $0.period, fps: 12) } ?? [0]
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("moonlight-sprite-\(entry.clip)-\(d)-" + UUID().uuidString + ".gif")
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, times.count, nil) else { throw Generate3DError.saveFailed("GIF") }
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 12, kCGImagePropertyGIFUnclampedDelayTime: 1.0 / 12]] as CFDictionary
                for t in times {
                    let image = render(source, camera: RasterCamera(yaw: yaw, pitch: 0.08), clip: clip, time: t, size: size, background: Background.clear.rgba, lighting: true)
                    if let cg = cgImage(image) { CGImageDestinationAddImage(destination, cg, frameProperties) }
                }
                guard CGImageDestinationFinalize(destination) else { throw Generate3DError.saveFailed("GIF") }
                files.append((entry.clip, d, url))
                progress(Double(c * 8 + d + 1) / Double(total))
            }
        }
        // Figure extent in the front idle frame (for size and feet).
        let front = render(source, camera: RasterCamera(yaw: 0, pitch: 0.08), clip: nil, time: 0, size: size, background: Background.clear.rgba, lighting: false)
        var top = size, bottom = -1
        for y in 0..<size { for x in 0..<size where front.rgba[(y * size + x) * 4 + 3] > 0 { top = min(top, y); bottom = max(bottom, y) } }
        let figure = bottom >= top ? Double(bottom - top + 1) / Double(size) : 1
        let foot = bottom >= 0 ? Double(size - 1 - bottom) / Double(size) : 0
        return (files, figure, foot)
    }
}
