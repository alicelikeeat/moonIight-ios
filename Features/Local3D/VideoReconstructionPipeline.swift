import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Vision
import ImageIO
import UniformTypeIdentifiers

struct VideoReconstructionInput: Sendable {
    let id: UUID
    let directory: URL
    let frames: [URL]
    let report: VideoQualityReport
}

enum VideoReconstructionPipeline {
    /// One decoded frame at a time; at most 96 JPEGs and 96 small feature prints.
    /// Sampling is bounded regardless of video file length or frame rate.
    static func extract(source: URL, progress: GenerationProgress) async throws -> VideoReconstructionInput {
        guard source.isFileURL else { throw GenerationError.invalidInput("视频必须先导入本机。") }
        try await GenerationResources.checkpoint()
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 2, duration <= 600 else {
            throw GenerationError.invalidInput("请选择 2 秒至 10 分钟的视频；长视频请先裁剪为环绕片段。")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw GenerationError.invalidInput("文件中没有可解码的视频轨道。") }
        let id = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("local3d-frames-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        try GenerationResources.checkDisk(at: directory, bytes: 150 << 20)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        defer { generator.cancelAllCGImageGeneration() }
        let count = min(96, max(12, Int(duration * 3)))
        var frames: [URL] = [], prints: [VNFeaturePrintObservation] = []
        var report = VideoQualityReport(sampled: 0, accepted: 0, blurry: 0, duplicates: 0, humanFrames: 0,
                                        durationSeconds: duration, diverseTransitions: 0)
        for index in 0..<count {
            try await GenerationResources.checkpoint()
            await progress("抽帧并检查画面 \(index + 1)/\(count)", Double(index) / Double(count))
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            try Task.checkCancellation()
            try autoreleasepool {
                report.sampled += 1
                let people = VNDetectHumanRectanglesRequest()
                let features = VNGenerateImageFeaturePrintRequest()
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([people, features])
                if people.results?.contains(where: { $0.confidence > 0.5 }) == true { report.humanFrames += 1 }
                guard try sharpness(image) >= 55 else { report.blurry += 1; return }
                guard let feature = features.results?.first as? VNFeaturePrintObservation else {
                    throw GenerationError.invalidInput("视频画面特征分析失败。")
                }
                var minimum = Float.greatestFiniteMagnitude
                for previous in prints {
                    var distance: Float = 0
                    try feature.computeDistance(&distance, to: previous)
                    minimum = min(minimum, distance)
                }
                if minimum < 0.08 { report.duplicates += 1; return }
                if let previous = prints.last {
                    var distance: Float = 0
                    try feature.computeDistance(&distance, to: previous)
                    if distance >= 0.20 { report.diverseTransitions += 1 }
                }
                let url = directory.appendingPathComponent(String(format: "frame-%03d.jpg", index))
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw GenerationError.storage
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw GenerationError.storage }
                frames.append(url); prints.append(feature); report.accepted += 1
            }
        }
        completed = true
        return VideoReconstructionInput(id: id, directory: directory, frames: frames, report: report)
    }

    /// Variance of a 128px grayscale Laplacian. A heuristic, not a universal quality score.
    private static func sharpness(_ image: CGImage) throws -> Double {
        let edge = 128
        var pixels = [UInt8](repeating: 0, count: edge * edge)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: edge, height: edge, bitsPerComponent: 8,
                bytesPerRow: edge, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard rendered else { throw GenerationError.memory }
        var sum = 0.0, squares = 0.0
        for y in 1..<(edge - 1) {
            for x in 1..<(edge - 1) {
                let i = y * edge + x
                let value = Double(Int(pixels[i - 1]) + Int(pixels[i + 1]) + Int(pixels[i - edge]) + Int(pixels[i + edge]) - 4 * Int(pixels[i]))
                sum += value; squares += value * value
            }
        }
        let n = Double((edge - 2) * (edge - 2))
        return squares / n - (sum / n) * (sum / n)
    }
}
