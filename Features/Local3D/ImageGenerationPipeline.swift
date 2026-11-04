import Foundation
@preconcurrency import Vision
@preconcurrency import CoreML
@preconcurrency import CoreImage
import ImageIO
import UniformTypeIdentifiers

struct GeneratedImage: Sendable {
    let mesh: DepthMesh
    let texture: Data
    let width: Int
    let height: Int
    let quality: String
}

/// Owns all decoded images and inference objects on the generator actor.
/// No global model cache: the model is released when estimateDepth returns.
enum ImageGenerationPipeline {
    static func generate(source: URL, progress: GenerationProgress) async throws -> GeneratedImage {
        guard #available(iOS 17.0, *) else {
            throw GenerationError.unsupported("任意图片主体分割与捆绑深度模型需要 iOS 17 或更高版本；现有功能仍可使用。")
        }
        try await GenerationResources.checkpoint(minimumMemory: 650 << 20)
        await progress("读取并缩小图片", nil)
        let image = try decode(source, edge: GenerationResources.textureEdge)
        try await GenerationResources.checkpoint(minimumMemory: 650 << 20)
        await progress("本地主体分割", nil)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw GenerationError.noSubject }
        let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        try await GenerationResources.checkpoint(minimumMemory: 650 << 20)
        await progress("本地深度估计（首次加载可能较慢）", nil)
        let field = try autoreleasepool { try estimateDepth(image) }
        try await GenerationResources.checkpoint()
        let context = CIContext(options: [.cacheIntermediates: false])
        let maskImage = CIImage(cvPixelBuffer: maskBuffer)
        let scaledMask = maskImage.transformed(by: .init(scaleX: CGFloat(field.width) / maskImage.extent.width,
                                                        y: CGFloat(field.height) / maskImage.extent.height))
        var mask = [UInt8](repeating: 0, count: field.width * field.height)
        mask.withUnsafeMutableBytes { bytes in
            context.render(scaledMask, toBitmap: bytes.baseAddress!, rowBytes: field.width,
                           bounds: CGRect(x: 0, y: 0, width: field.width, height: field.height), format: .L8, colorSpace: nil)
        }
        await progress("根据深度构建三维顶点和三角网格", nil)
        let edge = GenerationResources.gridEdge
        let mesh = try ModelOptimizationService.depthMesh(width: field.width, height: field.height,
            inverseDepth: field.values, mask: mask, imageAspect: Float(image.width) / Float(image.height), maximumEdge: edge)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw GenerationError.invalidInput("无法编码模型纹理。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GenerationError.invalidInput("纹理编码失败。") }
        return GeneratedImage(mesh: mesh, texture: data as Data, width: image.width, height: image.height, quality: "relativeDepth-grid\(edge)")
    }

    static func decode(_ url: URL, edge: Int) throws -> CGImage {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), let ut = UTType(type as String),
              [UTType.jpeg, .png, .heic, .heif].contains(where: { ut.conforms(to: $0) }) else {
            throw GenerationError.invalidInput("请选择 JPG、PNG 或 HEIC 图片；动图请先导出静帧。")
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width >= 128, image.height >= 128 else { throw GenerationError.invalidInput("图片损坏或分辨率过低（至少 128 × 128）。") }
        return image
    }

    @available(iOS 17.0, *)
    private static func estimateDepth(_ image: CGImage) throws -> (width: Int, height: Int, values: [Float]) {
        let url = try compiledModelURL()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model: MLModel
        do { model = try MLModel(contentsOf: url, configuration: configuration) }
        catch {
            // A cache eviction or interrupted compile must not permanently
            // disable inference. The next retry recompiles the bundled source.
            try? FileManager.default.removeItem(at: url)
            throw GenerationError.modelMissing
        }
        guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw GenerationError.modelMissing }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, input.pixelsWide, input.pixelsHigh,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw GenerationError.memory }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: input.pixelsWide, height: input.pixelsHigh,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw GenerationError.memory }
        context.draw(image, in: CGRect(x: 0, y: 0, width: input.pixelsWide, height: input.pixelsHigh))
        try Task.checkCancellation()
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: provider)
        try Task.checkCancellation()
        guard let depth = output.featureValue(for: "depth")?.imageBufferValue else { throw GenerationError.modelMissing }
        CVPixelBufferLockBaseAddress(depth, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
        let width = CVPixelBufferGetWidth(depth), height = CVPixelBufferGetHeight(depth)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let bytes = CVPixelBufferGetBaseAddress(depth) else { throw GenerationError.invalidInput("深度输出无效。") }
        let format = CVPixelBufferGetPixelFormatType(depth), stride = CVPixelBufferGetBytesPerRow(depth)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                switch format {
                case kCVPixelFormatType_OneComponent16Half:
                    values[y * width + x] = Float(bytes.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)[x])
                case kCVPixelFormatType_OneComponent32Float:
                    values[y * width + x] = bytes.advanced(by: y * stride).assumingMemoryBound(to: Float.self)[x]
                default: throw GenerationError.invalidInput("深度模型像素格式不受支持。")
                }
            }
        }
        return (width, height, values)
    }

    /// The raw iOS-17 package is compiled offline on the worker on first use;
    /// keeping it as a resource preserves the base app's iOS-16 target.
    @available(iOS 17.0, *)
    private static func compiledModelURL() throws -> URL {
        let fm = FileManager.default
        let directory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Local3DCompiled")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("depth-v2-small-cfef6f6.mlmodelc")
        if fm.fileExists(atPath: target.path) { return target }
        guard let package = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlpackage", subdirectory: "Local3D") else {
            throw GenerationError.modelMissing
        }
        let compiled = try MLModel.compileModel(at: package)
        defer { try? fm.removeItem(at: compiled) }
        try Task.checkCancellation()
        try fm.moveItem(at: compiled, to: target)
        return target
    }
}
