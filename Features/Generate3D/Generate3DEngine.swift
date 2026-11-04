import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreML
import AVFoundation
import RealityKit
import ModelIO
import os

// Local 3D generation engine (v1.67). Everything runs on the iPhone: no
// network, no uploads. Heavy work runs off the main thread in a cancellable
// task; every stage checks cancellation, temperature and memory first.

// MARK: Errors

enum Generate3DError: LocalizedError, Equatable {
    case unreadableImage, noSubject, depthUnavailable(String), lowMemory, tooHot, cancelled
    case unreadableVideo, noVideoTrack, reconstructionUnsupported, reconstructionFailed(String), saveFailed(String), meshFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: L10n.t("无法读取这张图片（支持 JPG、PNG、HEIC）。", "Could not read this picture (JPG, PNG and HEIC are supported).")
        case .noSubject: L10n.t("没有识别到主体。请换一张主体清楚、和背景分得开的图片。", "No subject found. Try a picture where the subject stands out from the background.")
        case .depthUnavailable(let reason): reason
        case .lowMemory: L10n.t("可用内存不足，已停止。请关闭其他 App 后重试，或在设置里选「省电」精度。", "Not enough free memory. Close other apps and try again, or choose the Light quality.")
        case .tooHot: L10n.t("设备温度过高，已停止生成以保护设备。请等手机降温后再试。", "The device is too hot; generation stopped to protect it. Try again when it has cooled down.")
        case .cancelled: L10n.t("已取消。", "Cancelled.")
        case .unreadableVideo: L10n.t("无法读取这个视频。", "Could not read this video.")
        case .noVideoTrack: L10n.t("这个文件里没有视频画面。", "This file has no video picture.")
        case .reconstructionUnsupported: L10n.t("这台设备或系统不支持本地多视角重建（RealityKit Object Capture 需要 iOS 17 及以上的支持机型）。", "This device or system cannot do on-device multi-view reconstruction (RealityKit Object Capture needs a supported device on iOS 17 or later).")
        case .reconstructionFailed(let reason): L10n.t("多视角重建失败：", "Multi-view reconstruction failed: ") + reason
        case .saveFailed(let reason): L10n.t("保存失败：", "Could not save: ") + reason
        case .meshFailed: L10n.t("没能从深度生成有效的网格。", "Could not build a valid mesh from the depth.")
        }
    }
}

// MARK: Device

/// What this device can do, checked at run time (no raised minimum iOS).
struct Generate3DCapabilities: Sendable {
    var depthModelBundled: Bool
    var depthModelOS: Bool
    var foregroundSegmentation: Bool
    var objectCapture: Bool
    var usdzExport: Bool
    var physicalMemory: UInt64
    var thermal: Int

    var depthModelReady: Bool { depthModelBundled && depthModelOS }
    var recommended: GenerationQuality { GenerationQuality.recommended(memory: physicalMemory, thermal: thermal) }

    static func current() -> Generate3DCapabilities {
        var os17 = false, capture = false
        if #available(iOS 17.0, *) {
            os17 = true
            capture = PhotogrammetrySession.isSupported
        }
        return Generate3DCapabilities(depthModelBundled: DepthAnythingModel.bundled, depthModelOS: os17, foregroundSegmentation: os17,
                                      objectCapture: capture, usdzExport: MDLAsset.canExportFileExtension("usdz"),
                                      physicalMemory: ProcessInfo.processInfo.physicalMemory, thermal: Generate3DGuard.thermalLevel)
    }
}

/// Cancellation, temperature and memory checks between stages.
enum Generate3DGuard {
    static var thermalLevel: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0; case .fair: 1; case .serious: 2; case .critical: 3; @unknown default: 1
        }
    }
    /// Free memory this app may still use, in bytes.
    static var availableMemory: UInt64 { UInt64(os_proc_available_memory()) }

    /// Throws on cancel or critical heat; waits (up to a minute) while the
    /// device is hot, reporting the pause; checks the memory budget.
    static func checkpoint(needsMemory: UInt64 = 0, progress: @Sendable (String, Double?) -> Void) async throws {
        if Task.isCancelled { throw Generate3DError.cancelled }
        var waited = 0
        while thermalLevel >= 2 {
            if thermalLevel >= 3 || waited >= 30 { throw Generate3DError.tooHot }
            progress(L10n.t("设备温度较高，已暂停，等待降温…", "The device is warm; paused while it cools…"), nil)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { throw Generate3DError.cancelled }
            waited += 1
        }
        if needsMemory > 0 && availableMemory > 0 && availableMemory < needsMemory { throw Generate3DError.lowMemory }
    }
}

// MARK: Depth model

/// Depth Anything V2 Small (Apple's Core ML conversion, Apache-2.0), shipped
/// in Resources/DepthModel. Compiled on first use and cached; loaded only
/// for one generation and released afterwards.
enum DepthAnythingModel {
    static let name = "DepthAnythingV2SmallF16"
    static let version = "2.0-small-f16"
    static var packageURL: URL? { Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "DepthModel") }
    static var bundled: Bool {
        packageURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin").path) } ?? false
    }
    static var compiledURL: URL { Generated3DStore.folder("Engines").appendingPathComponent(name + ".mlmodelc", isDirectory: true) }

    static func compiled() async throws -> URL {
        let target = compiledURL
        let marker = target.appendingPathComponent(".moonlight-\(version)")
        if FileManager.default.fileExists(atPath: marker.path) { return target }
        guard let package = packageURL, bundled else {
            throw Generate3DError.depthUnavailable(L10n.t("这个安装包里没有本地深度模型。", "This build does not include the on-device depth model."))
        }
        let temporary = try await MLModel.compileModel(at: package)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: target)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        return target
    }
}

// MARK: Pixels

enum PixelReader {
    /// Single-channel pixel buffer → floats (8-bit, 16-bit, half and float
    /// formats, including depth and disparity).
    static func floats(_ buffer: CVPixelBuffer) -> (width: Int, height: Int, values: [Float])? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let line = base.advanced(by: y * row)
            for x in 0..<width {
                let value: Float
                switch format {
                case kCVPixelFormatType_OneComponent8:
                    value = Float(line.load(fromByteOffset: x, as: UInt8.self)) / 255
                case kCVPixelFormatType_OneComponent16:
                    value = Float(line.load(fromByteOffset: x * 2, as: UInt16.self)) / 65535
                case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DepthFloat16:
                    value = PixelMath.half(line.load(fromByteOffset: x * 2, as: UInt16.self))
                case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DisparityFloat32, kCVPixelFormatType_DepthFloat32:
                    value = line.load(fromByteOffset: x * 4, as: Float.self)
                case kCVPixelFormatType_32BGRA:
                    value = Float(line.load(fromByteOffset: x * 4 + 2, as: UInt8.self)) / 255
                default:
                    return nil
                }
                out[y * width + x] = value.isFinite ? value : 0
            }
        }
        return (width, height, out)
    }

    /// 8-bit greyscale copy of an image at the given size.
    static func gray(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Image scaled so its longer side is at most `maxSide`.
    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longer = max(image.width, image.height)
        guard longer > maxSide else { return image }
        let k = Double(maxSide) / Double(longer)
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}

// MARK: Image pipeline

/// Result of the image pipeline, ready to save.
struct ImageGenerationOutput: Sendable {
    var mesh: GeneratedMesh
    var texture: Data
    var textureWidth: Int
    var textureHeight: Int
    var thumbnail: Data?
    var depthSource: Generated3DManifest.DepthSource
    var humanoid: Bool
    var notes: [String]
    var back: DepthMeshBuilder.BackStyle = .flat
}

/// Picture → subject mask → depth → closed depth-relief mesh + texture.
enum ImageGenerationPipeline {
    typealias Progress = @Sendable (String, Double?) -> Void

    static func run(_ url: URL, quality: GenerationQuality, back: DepthMeshBuilder.BackStyle = .inflated, progress: @escaping Progress) async throws -> ImageGenerationOutput {
        var notes: [String] = []
        try await Generate3DGuard.checkpoint(progress: progress)
        progress(L10n.t("读取图片", "Reading the picture"), 0.05)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { throw Generate3DError.unreadableImage }
        let thumbOptions: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                             kCGImageSourceThumbnailMaxPixelSize: quality.textureSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary), image.width >= 64, image.height >= 64 else {
            throw Generate3DError.unreadableImage
        }
        if image.width < 256 || image.height < 256 { notes.append(L10n.t("图片分辨率较低，细节有限。", "Low-resolution picture: limited detail.")) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up

        // Depth: the camera's own depth when the photo has it, else the AI model.
        try await Generate3DGuard.checkpoint(progress: progress)
        progress(L10n.t("估计深度", "Estimating depth"), 0.2)
        var depth: (width: Int, height: Int, values: [Float])?
        var depthSource = Generated3DManifest.DepthSource.depthAnythingV2
        if let camera = cameraDepth(source, orientation: orientation) {
            depth = camera; depthSource = .cameraDepth
        } else {
            guard #available(iOS 17.0, *) else {
                throw Generate3DError.depthUnavailable(L10n.t("本地 AI 深度估计需要 iOS 17 或更高版本；这张照片也没有自带相机深度（可用 iPhone「人像」模式拍摄的照片）。",
                                                               "On-device AI depth needs iOS 17 or later, and this photo has no stored camera depth (Portrait mode photos have it)."))
            }
            try await Generate3DGuard.checkpoint(needsMemory: 300_000_000, progress: progress)
            depth = try await aiDepth(image)
        }
        guard let depth else { throw Generate3DError.depthUnavailable(L10n.t("没有得到深度数据。", "No depth data.")) }

        try await Generate3DGuard.checkpoint(progress: progress)
        progress(L10n.t("识别主体", "Finding the subject"), 0.5)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        var mask = subjectMask(handler)
        if mask == nil { notes.append(L10n.t("系统没有分出主体，改用深度区分前景。", "No subject from Vision; the nearer part of the depth was used.")) }
        let humanoid = detectsHuman(handler)

        // Work grid at up to 512 px: the depth is raised to it with the
        // picture as a guide (depth edges land on picture edges), the mask
        // is sampled from its own, finer resolution.
        let longest = min(512, max(quality.gridResolution * 2, 256))
        let k = Double(longest) / Double(max(image.width, image.height))
        let gw = max(16, Int(Double(image.width) * k)), gh = max(16, Int(Double(image.height) * k))
        var depthValues = DepthField(width: depth.width, height: depth.height, nearness: depth.values, mask: depth.values).resampled(width: gw, height: gh).nearness
        if let guidePixels = PixelReader.gray(image, width: gw, height: gh) {
            let guide = guidePixels.map { Float($0) / 255 }
            let refined = DepthRefine.guidedUpsample(depth.values, width: depth.width, height: depth.height, guide: guide, guideWidth: gw, guideHeight: gh)
            if refined.count == gw * gh { depthValues = refined }
        }
        let maskValues: [Float]
        if let mask {
            maskValues = DepthField(width: mask.width, height: mask.height, nearness: mask.values, mask: mask.values).resampled(width: gw, height: gh).nearness
        } else {
            maskValues = PixelMath.otsuMask(depthValues)
        }
        var field = DepthField(width: gw, height: gh, nearness: depthValues, mask: maskValues)
        let coverage = field.subjectCoverage()
        if coverage < 0.02 { throw Generate3DError.noSubject }
        if coverage > 0.97 {
            notes.append(L10n.t("主体几乎占满画面，整张图片被立体化。", "The subject fills the picture; the whole picture was turned into relief."))
            field.mask = field.mask.map { _ in 1 }
        }

        try await Generate3DGuard.checkpoint(needsMemory: 150_000_000, progress: progress)
        progress(L10n.t("生成三维网格", "Building the 3D mesh"), 0.7)
        var options = DepthMeshBuilder.Options()
        options.resolution = quality.gridResolution
        options.back = back
        options.snapEdges = true
        options.smoothingPasses = 1
        options.backAtlas = back == .inflated
        var mesh: GeneratedMesh
        do { mesh = try DepthMeshBuilder.build(field, aspect: Double(image.width) / Double(image.height), options: options) }
        catch DepthMeshBuilder.Failure.noSubject, DepthMeshBuilder.Failure.tooSmall { throw Generate3DError.noSubject }
        catch { throw Generate3DError.meshFailed }
        mesh.normalize(size: 1)
        guard mesh.valid, mesh.depthExtent > 0.01 else { throw Generate3DError.meshFailed }

        progress(L10n.t("制作贴图", "Making the texture"), 0.85)
        let textureImage = back == .inflated ? (backAtlas(image, mask: field) ?? image) : image
        guard let texture = PixelReader.jpeg(textureImage) else { throw Generate3DError.saveFailed("texture") }
        if back == .inflated { notes.append(L10n.t("形体按轮廓推测：每处厚度随该处宽度变化；背面用正面整体颜色推测，不是 AI 重建的真实背面。", "Shape guessed from the outline (thickness follows local width); the back uses the front's overall colours, not a reconstructed back.")) }
        let thumbnail = subjectThumbnail(image, mask: field)
        return ImageGenerationOutput(mesh: mesh, texture: texture, textureWidth: image.width, textureHeight: image.height, thumbnail: thumbnail,
                                     depthSource: depthSource, humanoid: humanoid, notes: notes, back: back)
    }

    /// Texture with the picture on the left and a colour-only back on the
    /// right: the picture heavily blurred, mixed with the subject's average
    /// colour (no face or details on the back).
    static func backAtlas(_ image: CGImage, mask: DepthField) -> CGImage? {
        let w = image.width, h = image.height
        guard let small = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        small.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        if let data = small.data?.assumingMemoryBound(to: UInt8.self) {
            for y in 0..<64 { for x in 0..<64 {
                // Bitmap context memory starts with the top row, like the mask.
                let inside = mask.sample(mask.mask, u: Double(x) / 63, v: Double(y) / 63) >= 0.5
                guard inside else { continue }
                let o = (y * 64 + x) * 4
                r += Double(data[o]); g += Double(data[o + 1]); b += Double(data[o + 2]); n += 1
            } }
        }
        guard let atlas = CGContext(data: nil, width: w * 2, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let tiny = PixelReader.scaled(image, maxSide: 12) else { return nil }
        atlas.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        atlas.interpolationQuality = .high
        atlas.draw(tiny, in: CGRect(x: w, y: 0, width: w, height: h))
        if n > 0 {
            atlas.setFillColor(red: r / n / 255, green: g / n / 255, blue: b / n / 255, alpha: 0.6)
            atlas.fill(CGRect(x: w, y: 0, width: w, height: h))
        }
        return atlas.makeImage()
    }

    /// Disparity stored by the camera (Portrait mode, dual cameras, LiDAR).
    static func cameraDepth(_ source: CGImageSource, orientation: CGImagePropertyOrientation) -> (width: Int, height: Int, values: [Float])? {
        for type in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth] {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [AnyHashable: Any],
                  var data = try? AVDepthData(fromDictionaryRepresentation: info) else { continue }
            data = data.applyingExifOrientation(orientation)
            if data.depthDataType != kCVPixelFormatType_DisparityFloat32 { data = data.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32) }
            if let read = PixelReader.floats(data.depthDataMap), read.width >= 16, read.height >= 16 { return read }
        }
        return nil
    }

    @available(iOS 17.0, *)
    static func aiDepth(_ image: CGImage) async throws -> (width: Int, height: Int, values: [Float]) {
        let compiled = try await DepthAnythingModel.compiled()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        // Loaded for this picture only; released when this function returns.
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        if let observation = request.results?.first as? VNPixelBufferObservation, let read = PixelReader.floats(observation.pixelBuffer) { return read }
        if let feature = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.imageBufferValue, let read = PixelReader.floats(feature) { return read }
        throw Generate3DError.depthUnavailable(L10n.t("深度模型没有输出结果。", "The depth model returned nothing."))
    }

    /// Subject mask: any foreground subject (iOS 17), else people (iOS 15).
    static func subjectMask(_ handler: VNImageRequestHandler) -> (width: Int, height: Int, values: [Float])? {
        if #available(iOS 17.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            if (try? handler.perform([request])) != nil, let observation = request.results?.first,
               let buffer = try? observation.generateMask(forInstances: observation.allInstances), let read = PixelReader.floats(buffer) {
                return read
            }
        }
        let people = VNGeneratePersonSegmentationRequest()
        people.qualityLevel = .balanced
        people.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if (try? handler.perform([people])) != nil, let buffer = people.results?.first?.pixelBuffer, let read = PixelReader.floats(buffer),
           read.values.contains(where: { $0 > 0.5 }) {
            return read
        }
        return nil
    }

    static func detectsHuman(_ handler: VNImageRequestHandler) -> Bool {
        let request = VNDetectHumanBodyPoseRequest()
        guard (try? handler.perform([request])) != nil, let body = request.results?.first,
              let points = try? body.recognizedPoints(.all) else { return false }
        return points.values.filter { $0.confidence > 0.3 }.count >= 8
    }

    /// Square crop around the subject, 256 px.
    static func subjectThumbnail(_ image: CGImage, mask: DepthField) -> Data? {
        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
        for y in 0..<mask.height { for x in 0..<mask.width where mask.mask[y * mask.width + x] >= 0.5 {
            let u = Double(x) / Double(max(1, mask.width - 1)), v = Double(y) / Double(max(1, mask.height - 1))
            minX = min(minX, u); maxX = max(maxX, u); minY = min(minY, v); maxY = max(maxY, v)
        } }
        guard maxX > minX, maxY > minY else { return PixelReader.scaled(image, maxSide: 256).flatMap { PixelReader.jpeg($0, quality: 0.8) } }
        let side = max(maxX - minX, (maxY - minY) * Double(image.height) / Double(image.width)) * 1.1
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        let w = side * Double(image.width), h = side * Double(image.width)
        let rect = CGRect(x: cx * Double(image.width) - w / 2, y: cy * Double(image.height) - h / 2, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: rect.integral) else { return nil }
        return PixelReader.scaled(crop, maxSide: 256).flatMap { PixelReader.jpeg($0, quality: 0.8) }
    }
}

// MARK: Video pipeline

/// Sampled, checked frames of a video and what they can be used for.
struct VideoAnalysis: Sendable {
    var sampled: Int
    var kept: [FrameStat]
    var blurry: Int
    var duplicates: Int
    var assessment: VideoAssessment
    /// JPEG frames kept for reconstruction (deleted with the analysis).
    var framesFolder: URL
    /// Sharpest kept frame (for the basic depth model).
    var bestFrame: URL?
    var analysedSeconds: Double
    var totalSeconds: Double
}

enum VideoReconstructionPipeline {
    typealias Progress = @Sendable (String, Double?) -> Void
    static let maxFrames = 90
    static let maxSeconds = 180.0

    /// Bounded frame sampling (≤ 90 frames, ≤ 1920 px, first 3 minutes),
    /// sharpness, duplicates, camera movement and people per frame.
    static func analyze(_ url: URL, progress: @escaping Progress) async throws -> VideoAnalysis {
        try await Generate3DGuard.checkpoint(progress: progress)
        progress(L10n.t("读取视频", "Reading the video"), 0.02)
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do { duration = try await asset.load(.duration) } catch { throw Generate3DError.unreadableVideo }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { throw Generate3DError.noVideoTrack }
        let total = duration.seconds.isFinite ? duration.seconds : 0
        guard total > 0.5 else { throw Generate3DError.unreadableVideo }
        let span = min(total, maxSeconds)
        let count = min(maxFrames, max(12, Int(span * 2)))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moonlight-frames-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance; generator.requestedTimeToleranceAfter = tolerance

        var stats: [FrameStat] = []
        var previous: CGImage?
        for i in 0..<count {
            try await Generate3DGuard.checkpoint(progress: progress)
            let seconds = span * (Double(i) + 0.5) / Double(count)
            progress(L10n.t("抽帧并检查画面 \(i + 1)/\(count)", "Checking frame \(i + 1)/\(count)"), 0.05 + 0.85 * Double(i) / Double(count))
            guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image,
                  let small = PixelReader.scaled(frame, maxSide: 256),
                  let gray = PixelReader.gray(small, width: small.width, height: small.height) else { continue }
            var stat = FrameStat(index: i, time: seconds, sharpness: FrameQuality.sharpness(gray, width: small.width, height: small.height),
                                 hash: FrameQuality.differenceHash(FrameQuality.downscale(gray, width: small.width, height: small.height, to: 9, 8)))
            let handler = VNImageRequestHandler(cgImage: small, orientation: .up)
            if let previous {
                let registration = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
                if (try? handler.perform([registration])) != nil, let alignment = registration.results?.first {
                    stat.shiftX = Double(alignment.alignmentTransform.tx) / Double(small.width)
                    stat.shiftY = Double(alignment.alignmentTransform.ty) / Double(small.width)
                }
            }
            let people = VNDetectHumanRectanglesRequest()
            if (try? handler.perform([people])) != nil { stat.person = !(people.results ?? []).isEmpty }
            if let data = PixelReader.jpeg(frame, quality: 0.92) {
                try? data.write(to: folder.appendingPathComponent(String(format: "frame_%03d.jpg", i)))
            }
            stats.append(stat)
            previous = small
        }
        // Shifts of dropped frames carry over to the next kept one.
        let selection = FrameQuality.select(stats)
        let keptIndices = Set(selection.kept.map(\.index))
        var kept: [FrameStat] = [], carryX = 0.0, carryY = 0.0
        for stat in stats {
            carryX += stat.shiftX; carryY += stat.shiftY
            if keptIndices.contains(stat.index) { var k = stat; k.shiftX = carryX; k.shiftY = carryY; kept.append(k); carryX = 0; carryY = 0 }
            else { try? FileManager.default.removeItem(at: folder.appendingPathComponent(String(format: "frame_%03d.jpg", stat.index))) }
        }
        let best = kept.max { $0.sharpness < $1.sharpness }.map { folder.appendingPathComponent(String(format: "frame_%03d.jpg", $0.index)) }
        progress(L10n.t("检查视角覆盖", "Checking view coverage"), 0.95)
        return VideoAnalysis(sampled: stats.count, kept: kept, blurry: selection.blurry, duplicates: selection.duplicates,
                             assessment: VideoAssessment.assess(kept), framesFolder: folder, bestFrame: best, analysedSeconds: span, totalSeconds: total)
    }

    /// RealityKit Object Capture on the kept frames → USDZ (supported devices only).
    @available(iOS 17.0, *)
    static func reconstruct(frames: URL, output: URL, progress: @escaping Progress) async throws {
        guard PhotogrammetrySession.isSupported else { throw Generate3DError.reconstructionUnsupported }
        try await Generate3DGuard.checkpoint(needsMemory: 600_000_000, progress: progress)
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .normal
        let session: PhotogrammetrySession
        do { session = try PhotogrammetrySession(input: frames, configuration: configuration) }
        catch { throw Generate3DError.reconstructionFailed(error.localizedDescription) }
        try session.process(requests: [.modelFile(url: output)])
        progress(L10n.t("多视角重建中", "Reconstructing from many views"), 0)
        events: for try await event in session.outputs {
            if Task.isCancelled || Generate3DGuard.thermalLevel >= 3 { session.cancel() }
            switch event {
            case .requestProgress(_, let fraction): progress(L10n.t("多视角重建中", "Reconstructing from many views"), fraction)
            case .requestError(_, let error): throw Generate3DError.reconstructionFailed(error.localizedDescription)
            case .processingCancelled: throw Task.isCancelled ? Generate3DError.cancelled : Generate3DError.tooHot
            case .processingComplete: break events
            default: continue
            }
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw Generate3DError.reconstructionFailed(L10n.t("没有生成模型文件。", "No model file was produced.")) }
    }
}

// MARK: Store

/// Generated3D/ in Application Support: Models, Textures, Skeletons,
/// Animations, Thumbnails, Presets, Manifests (spec section 9).
@MainActor final class Generated3DStore: ObservableObject {
    static let shared = Generated3DStore()
    @Published private(set) var models: [Generated3DManifest] = []

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Generated3D", isDirectory: true)
    }
    nonisolated static let folders = ["Models", "Textures", "Skeletons", "Animations", "Thumbnails", "Presets", "Manifests", "Engines", "Exports"]
    nonisolated static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    init() {
        for name in Self.folders { _ = Self.folder(name) }
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder("Manifests"), includingPropertiesForKeys: nil)) ?? []
        models = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Generated3DManifest.self, from: Data(contentsOf: $0)) }
            .filter(\.valid).sorted { $0.createdAt > $1.createdAt }
    }

    func existing(hash: String, quality: GenerationQuality, back: DepthMeshBuilder.BackStyle = .flat) -> Generated3DManifest? {
        models.first { $0.sourceHash == hash && $0.quality == quality && $0.geometry == .depthRelief && ($0.backStyle ?? .flat) == back }
    }

    func url(_ folder: String, _ file: String?) -> URL? { file.map { Self.folder(folder).appendingPathComponent($0) } }
    func meshURL(_ m: Generated3DManifest) -> URL? { url("Models", m.meshFile) }
    func textureURL(_ m: Generated3DManifest) -> URL? { url("Textures", m.textureFile) }
    func usdzURL(_ m: Generated3DManifest) -> URL? { url("Models", m.usdzFile) }
    func thumbnailURL(_ m: Generated3DManifest) -> URL? { url("Thumbnails", m.thumbnailFile) }

    /// Bytes on disk for a model (all its files).
    func size(_ m: Generated3DManifest) -> Int64 {
        var urls = [meshURL(m), textureURL(m), usdzURL(m), thumbnailURL(m)].compactMap { $0 }
        urls += m.skinPresets.compactMap { url("Presets", $0.textureFile) }
        return urls.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) }
    }

    func save(_ manifest: Generated3DManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: Self.folder("Manifests").appendingPathComponent(manifest.id + ".json"), options: .atomic)
        reload()
    }

    /// Writes a depth-relief result; USDZ export is tried and verified by
    /// loading it back with RealityKit (kept only when that works).
    @available(iOS 18.0, *)
    func store(_ output: ImageGenerationOutput, name: String, source: Generated3DManifest.Source, sourceName: String, hash: String, quality: GenerationQuality) async throws -> Generated3DManifest {
        let id = UUID().uuidString
        let meshFile = id + ".m3dg", textureFile = id + ".jpg", thumbnailFile = id + ".jpg"
        let meshURL = Self.folder("Models").appendingPathComponent(meshFile), textureURL = Self.folder("Textures").appendingPathComponent(textureFile)
        let mesh = output.mesh
        do {
            try await Task.detached(priority: .userInitiated) { try GeneratedMeshCodec.encode(mesh).write(to: meshURL, options: .atomic) }.value
            try output.texture.write(to: textureURL, options: .atomic)
            if let thumb = output.thumbnail { try thumb.write(to: Self.folder("Thumbnails").appendingPathComponent(thumbnailFile), options: .atomic) }
        } catch { throw Generate3DError.saveFailed(error.localizedDescription) }

        var notes = output.notes
        var usdzFile: String?
        let usdzURL = Self.folder("Models").appendingPathComponent(id + ".usdz")
        if MDLAsset.canExportFileExtension("usdz") {
            let exported = await Task.detached(priority: .utility) { Generate3DExport.usdz(mesh, texture: textureURL, to: usdzURL) }.value
            if exported, (try? await Entity(contentsOf: usdzURL)) != nil { usdzFile = id + ".usdz" }
            else { try? FileManager.default.removeItem(at: usdzURL); notes.append(L10n.t("USDZ 导出未通过加载检查，模型以内部格式保存。", "USDZ export did not load back; the model is kept in the internal format.")) }
        } else {
            notes.append(L10n.t("本系统不支持导出 USDZ，模型以内部格式保存，可导出 OBJ。", "This system cannot export USDZ; the model is kept in the internal format and can be exported as OBJ."))
        }
        let manifest = Generated3DManifest(
            id: id, name: name, createdAt: Date(), source: source, sourceName: sourceName, sourceHash: hash,
            engine: "Moonlight DepthMesh" + (output.depthSource == .depthAnythingV2 ? " + " + DepthAnythingModel.name : ""),
            engineVersion: "1.0" + (output.depthSource == .depthAnythingV2 ? " / " + DepthAnythingModel.version : ""),
            depthSource: output.depthSource, geometry: .depthRelief, quality: quality,
            vertexCount: mesh.vertexCount, triangleCount: mesh.triangleCount, textureWidth: output.textureWidth, textureHeight: output.textureHeight,
            meshFile: meshFile, textureFile: textureFile, usdzFile: usdzFile, thumbnailFile: output.thumbnail == nil ? nil : thumbnailFile,
            humanoidDetected: output.humanoid, rigging: .experimentalNotImplemented, animation: .experimentalNotImplemented,
            separableParts: .notAvailable, notes: notes, backStyle: output.back, textureAtlas: output.back == .inflated ? true : nil)
        try save(manifest)
        return manifest
    }

    /// Saves a reconstructed USDZ (Object Capture).
    @available(iOS 18.0, *)
    func storeReconstruction(_ usdz: URL, thumbnail: URL?, name: String, sourceName: String, hash: String) async throws -> Generated3DManifest {
        let id = UUID().uuidString
        let target = Self.folder("Models").appendingPathComponent(id + ".usdz")
        do { try FileManager.default.moveItem(at: usdz, to: target) } catch { throw Generate3DError.saveFailed(error.localizedDescription) }
        guard let entity = try? await Entity(contentsOf: target) else {
            try? FileManager.default.removeItem(at: target)
            throw Generate3DError.reconstructionFailed(L10n.t("生成的模型无法用 RealityKit 加载。", "The model could not be loaded with RealityKit."))
        }
        let triangles = Self.triangles(in: entity)
        var thumbFile: String?
        if let thumbnail, let image = CGImageSourceCreateWithURL(thumbnail as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
           let small = PixelReader.scaled(image, maxSide: 256), let data = PixelReader.jpeg(small, quality: 0.8) {
            thumbFile = id + ".jpg"
            try? data.write(to: Self.folder("Thumbnails").appendingPathComponent(id + ".jpg"))
        }
        let manifest = Generated3DManifest(
            id: id, name: name, createdAt: Date(), source: .video, sourceName: sourceName, sourceHash: hash,
            engine: "RealityKit Object Capture", engineVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            depthSource: .objectCapture, geometry: .photogrammetry, quality: .medium, vertexCount: 0, triangleCount: triangles,
            textureWidth: 0, textureHeight: 0, meshFile: nil, textureFile: nil, usdzFile: id + ".usdz", thumbnailFile: thumbFile,
            humanoidDetected: false, rigging: .experimentalNotImplemented, animation: .experimentalNotImplemented, separableParts: .notAvailable)
        try save(manifest)
        return manifest
    }

    /// Triangles of every model in an entity tree.
    static func triangles(in entity: Entity) -> Int {
        var count = 0
        if let model = entity.components[ModelComponent.self] {
            for item in model.mesh.contents.models { for part in item.parts { count += (part.triangleIndices?.count ?? 0) / 3 } }
        }
        for child in entity.children { count += triangles(in: child) }
        return count
    }

    func delete(_ m: Generated3DManifest) {
        var urls = [meshURL(m), textureURL(m), usdzURL(m), thumbnailURL(m)].compactMap { $0 }
        urls += m.skinPresets.compactMap { url("Presets", $0.textureFile) }
        urls.append(Self.folder("Manifests").appendingPathComponent(m.id + ".json"))
        if let rig = m.rigFile {
            urls += [Self.folder("Skeletons").appendingPathComponent(rig + ".json"), Self.folder("Skeletons").appendingPathComponent(rig + ".skin"),
                     Self.folder("Animations").appendingPathComponent(rig + ".json")]
        }
        urls.append(Self.folder("Exports").appendingPathComponent(m.id, isDirectory: true))
        for url in urls { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    /// Files to share: OBJ + MTL + texture for depth models, plus USDZ when there is one.
    func exportFiles(_ m: Generated3DManifest) async -> [URL] {
        var files: [URL] = []
        let folder = Self.folder("Exports").appendingPathComponent(m.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let meshURL = meshURL(m), let textureURL = textureURL(m) {
            let objURL = folder.appendingPathComponent("model.obj"), mtlURL = folder.appendingPathComponent("model.mtl"), texURL = folder.appendingPathComponent("texture.jpg")
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                guard let data = try? Data(contentsOf: meshURL), let mesh = GeneratedMeshCodec.decode(data) else { return false }
                do {
                    try OBJWriter.obj(mesh, materialFile: "model.mtl").write(to: objURL, atomically: true, encoding: .utf8)
                    try OBJWriter.mtl(texture: "texture.jpg").write(to: mtlURL, atomically: true, encoding: .utf8)
                    try? FileManager.default.removeItem(at: texURL)
                    try FileManager.default.copyItem(at: textureURL, to: texURL)
                    return true
                } catch { return false }
            }.value
            if ok { files += [objURL, mtlURL, texURL] }
        }
        if let usdz = usdzURL(m), FileManager.default.fileExists(atPath: usdz.path) { files.append(usdz) }
        return files
    }
}

/// USDZ export with Model I/O (geometry, normals, UVs, colour texture).
enum Generate3DExport {
    static func usdz(_ mesh: GeneratedMesh, texture: URL, to url: URL) -> Bool {
        let allocator = MDLMeshBufferDataAllocator()
        func buffer(_ floats: [Float]) -> MDLMeshBuffer { floats.withUnsafeBufferPointer { allocator.newBuffer(with: Data(buffer: $0), type: .vertex) } }
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 0, bufferIndex: 1)
        descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 0, bufferIndex: 2)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 12)
        descriptor.layouts[1] = MDLVertexBufferLayout(stride: 12)
        descriptor.layouts[2] = MDLVertexBufferLayout(stride: 8)
        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let material = MDLMaterial(name: "moonlight", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, url: texture))
        let submesh = MDLSubmesh(indexBuffer: allocator.newBuffer(with: indexData, type: .index), indexCount: mesh.indices.count,
                                 indexType: .uInt32, geometryType: .triangles, material: material)
        let model = MDLMesh(vertexBuffers: [buffer(mesh.positions), buffer(mesh.normals), buffer(mesh.uvs)], vertexCount: mesh.vertexCount,
                            descriptor: descriptor, submeshes: [submesh])
        let asset = MDLAsset()
        asset.add(model)
        do { try asset.export(to: url); return FileManager.default.fileExists(atPath: url.path) } catch { return false }
    }
}

// MARK: Tasks

/// One generation at a time: real stage progress, cancel, error recovery.
@available(iOS 18.0, *)
@MainActor final class GenerationTaskManager: ObservableObject {
    enum Phase: Equatable { case idle, running, finished(String), failed(String), cancelled, videoReady }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stage = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var video: VideoAnalysis?
    @Published private(set) var videoSource: (url: URL, name: String, hash: String)?
    private var task: Task<Void, Never>?

    var running: Bool { phase == .running }

    private func report() -> @Sendable (String, Double?) -> Void {
        { text, value in Task { @MainActor in self.stage = text; if let value { self.fraction = value } } }
    }

    func cancel() { task?.cancel() }

    func reset() {
        if let folder = video?.framesFolder { try? FileManager.default.removeItem(at: folder) }
        if let source = videoSource { try? FileManager.default.removeItem(at: source.url) }
        video = nil; videoSource = nil; phase = .idle; stage = ""; fraction = nil
    }

    /// Picture → depth model (reuses an earlier result for the same file).
    func generate(image url: URL, name: String, quality: GenerationQuality, back: DepthMeshBuilder.BackStyle = .flat, store: Generated3DStore, removeAfter: Bool) {
        guard !running else { return }
        phase = .running; stage = L10n.t("准备", "Preparing"); fraction = 0
        let progress = report()
        task = Task {
            defer { if removeAfter { try? FileManager.default.removeItem(at: url) } }
            do {
                let hash = (try? await Task.detached { try MediaImportIndex.sha256(of: url) }.value) ?? UUID().uuidString
                if let existing = store.existing(hash: hash, quality: quality, back: back) { phase = .finished(existing.id); return }
                let job = Task.detached(priority: .userInitiated) { try await ImageGenerationPipeline.run(url, quality: quality, back: back, progress: progress) }
                let output = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                progress(L10n.t("保存", "Saving"), 0.95)
                let manifest = try await store.store(output, name: name, source: .image, sourceName: name, hash: hash, quality: quality)
                phase = .finished(manifest.id)
            } catch { finish(error) }
        }
    }

    /// Video → frames, quality and coverage report (no model yet).
    func analyze(video url: URL, name: String) {
        guard !running else { return }
        reset()
        phase = .running; stage = L10n.t("准备", "Preparing"); fraction = 0
        let progress = report()
        task = Task {
            do {
                let hash = (try? await Task.detached { try MediaImportIndex.sha256(of: url) }.value) ?? UUID().uuidString
                let job = Task.detached(priority: .userInitiated) { try await VideoReconstructionPipeline.analyze(url, progress: progress) }
                let analysis = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                video = analysis; videoSource = (url, name, hash); phase = .videoReady
            } catch { try? FileManager.default.removeItem(at: url); finish(error) }
        }
    }

    /// Multi-view reconstruction of the analysed video (supported devices only).
    func reconstruct(store: Generated3DStore) {
        guard !running, let analysis = video, let source = videoSource, analysis.assessment.canReconstruct else { return }
        guard #available(iOS 17.0, *) else { finish(Generate3DError.reconstructionUnsupported); return }
        phase = .running; stage = L10n.t("准备多视角重建", "Preparing reconstruction"); fraction = 0
        let progress = report()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".usdz")
        let frames = analysis.framesFolder
        task = Task {
            do {
                let job = Task.detached(priority: .userInitiated) { try await VideoReconstructionPipeline.reconstruct(frames: frames, output: output, progress: progress) }
                try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                let manifest = try await store.storeReconstruction(output, thumbnail: analysis.bestFrame, name: source.name, sourceName: source.name, hash: source.hash)
                reset(); phase = .finished(manifest.id)
            } catch { try? FileManager.default.removeItem(at: output); finish(error, keepVideo: true) }
        }
    }

    /// The sharpest frame of the analysed video → depth relief.
    func depthFromBestFrame(quality: GenerationQuality, back: DepthMeshBuilder.BackStyle = .flat, store: Generated3DStore) {
        guard !running, let frame = video?.bestFrame, let source = videoSource else { return }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard (try? FileManager.default.copyItem(at: frame, to: copy)) != nil else { return }
        let name = source.name
        reset()
        generate(image: copy, name: name, quality: quality, back: back, store: store, removeAfter: true)
    }

    /// Cancelled or failed. With `keepVideo` the video report stays, so the
    /// basic depth model can still be made from it.
    private func finish(_ error: Error, keepVideo: Bool = false) {
        fraction = nil
        let cancelled = (error as? Generate3DError) == .cancelled || error is CancellationError
        if cancelled { phase = keepVideo && video != nil ? .videoReady : .cancelled; return }
        phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        if !keepVideo, let folder = video?.framesFolder { try? FileManager.default.removeItem(at: folder); video = nil }
    }
}
