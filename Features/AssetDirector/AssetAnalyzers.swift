import AVFoundation
import Foundation
import ImageIO
import SoundAnalysis
import UniformTypeIdentifiers
import Vision

// v1.87 AI Asset Director — measuring files on the device. Every analyzer
// returns `AssetSignals`; deciding what they mean is AssetClassifier's job.
// Pictures are read as small thumbnails made by ImageIO (no EXIF, location
// or other metadata is kept); faces and bodies are only counted.

/// Blocking work (Vision, ImageIO, audio and model reading) runs on its own
/// GCD queue, never on Swift's cooperative pool: blocking pool threads with
/// Vision (which itself needs the pool on iOS 18+) while video analysis
/// awaited AVFoundation deadlocked the pipeline on a 3-core simulator.
enum AssetWork {
    static let queue = DispatchQueue(label: "com.moonlight.asset-analysis", qos: .utility, attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }
}

enum AssetAnalyzerError: Error, LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let why): L10n.t("无法读取：", "Cannot read: ") + why }
    }
}

// MARK: Images, GIFs and video frames

enum VisualSemanticAnalyzer {
    static let id = "moonlight.visual"
    static let version = 1
    /// Side of the thumbnail the pixels and Vision see.
    static let thumbnailSide = 256
    static let maxVideoFrames = 12

    /// A thumbnail without metadata (ImageIO draws a new bitmap).
    static func thumbnail(_ source: CGImageSource, index: Int = 0, side: Int = thumbnailSide) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// Vision's built-in classifier, people count and feature print on one image.
    /// The simulator's Vision returns the same labels for every picture
    /// ("outdoor / night_sky / sky" in CI), so it is not used there.
    static var visionUsable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    static func vision(_ image: CGImage) -> (labels: [AssetTag], people: Int, print: [Float]?) {
        guard visionUsable else { return ([], 0, nil) }
        let classify = VNClassifyImageRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let feature = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classify, humans, feature])
        let labels = (classify.results ?? []).filter { $0.confidence >= 0.05 }.prefix(24)
            .map { AssetTag(name: $0.identifier, score: Double($0.confidence), source: .vision) }
        let people = (humans.results ?? []).filter { $0.confidence >= 0.5 }.count
        return (Array(labels), people, (feature.results?.first).flatMap(compactPrint))
    }

    /// Feature print reduced to 128 averaged dimensions (enough for "looks alike").
    static func compactPrint(_ observation: VNFeaturePrintObservation) -> [Float]? {
        let count = observation.elementCount
        guard count > 0, observation.elementType == .float else { return nil }
        let values: [Float] = observation.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(count)) }
        let buckets = 128, per = max(1, values.count / buckets)
        return (0..<min(buckets, values.count)).map { b in
            let slice = values[(b * per)..<min(values.count, (b + 1) * per)]
            return slice.reduce(0, +) / Float(max(1, slice.count))
        }
    }

    static func image(_ url: URL, fileBytes: Int) throws -> AssetSignals {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AssetAnalyzerError.unreadable(L10n.t("不是可识别的图片", "not a readable picture"))
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let width = props?[kCGImagePropertyPixelWidth] as? Int, let height = props?[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              let thumb = thumbnail(source) else {
            throw AssetAnalyzerError.unreadable(L10n.t("图片已损坏或尺寸为 0", "damaged picture or zero size"))
        }
        var s = AssetSignals(mediaType: .image)
        s.visionSkipped = visionUsable ? nil : true
        s.technical.fileBytes = fileBytes
        s.technical.uniformType = CGImageSourceGetType(source) as String?
        s.technical.pixelWidth = width; s.technical.pixelHeight = height
        s.technical.gpuBytesEstimate = min(width, 4096) * min(height, 4096) * 4
        if let raster = ModelAnimationExport.raster(thumb) {
            s.pixel = AssetPixelStats.measure(raster)
            s.dominantColors = AssetAnalyzer.dominantColors(raster)
            s.technical.transparentShare = s.pixel?.transparentShare
        }
        let v = vision(thumb)
        s.labels = v.labels; s.peopleCount = v.people; s.featurePrint = v.print
        return s
    }

    static func gif(_ url: URL, fileBytes: Int) throws -> AssetSignals {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AssetAnalyzerError.unreadable("GIF")
        }
        let frames = CGImageSourceGetCount(source)
        guard frames > 0, let first = thumbnail(source, index: 0) else { throw AssetAnalyzerError.unreadable(L10n.t("GIF 没有可读的帧", "no readable GIF frames")) }
        var s = try image(url, fileBytes: fileBytes)
        s.mediaType = .gif
        var duration = 0.0
        for i in 0..<frames {
            let p = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(0.02, delay)
        }
        s.technical.frameCount = frames
        s.technical.duration = duration
        s.technical.frameRate = duration > 0 ? Double(frames) / duration : nil
        // Up to 8 evenly spread frames for motion and looping.
        let picks = Array(Set((0..<min(8, frames)).map { $0 * max(1, frames - 1) / max(1, min(8, frames) - 1) })).sorted()
        let rasters = picks.compactMap { thumbnail(source, index: $0, side: 64).flatMap(ModelAnimationExport.raster) }
        s.motionEnergy = AssetFrameMath.meanChange(rasters)
        if let a = rasters.first, let b = rasters.last, rasters.count >= 2 { s.loopSimilarity = 1 - AssetFrameMath.change(a, b) }
        s.technical.loops = (s.loopSimilarity ?? 0) > 0.85
        s.technical.sampledTimes = picks.map { Double($0) / max(1, Double(frames)) * duration }
        _ = first
        return s
    }

    /// Video: a cheap uniform pass picks where the picture changes; Vision
    /// then looks at up to 12 frames (never just one).
    static func video(_ url: URL, fileBytes: Int) async throws -> AssetSignals {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AssetAnalyzerError.unreadable(L10n.t("没有视频画面", "no video track"))
        }
        let (size, rate, transform) = try await track.load(.naturalSize, .nominalFrameRate, .preferredTransform)
        let shown = size.applying(transform)
        var s = AssetSignals(mediaType: .video)
        s.visionSkipped = visionUsable ? nil : true
        s.technical.fileBytes = fileBytes
        s.technical.pixelWidth = Int(abs(shown.width)); s.technical.pixelHeight = Int(abs(shown.height))
        s.technical.duration = duration; s.technical.frameRate = Double(rate)
        s.technical.gpuBytesEstimate = min(s.technical.pixelWidth ?? 0, 1920) * min(s.technical.pixelHeight ?? 0, 1080) * 4 * 3
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        // Pass 1: small frames spread over the whole clip.
        let probes = max(4, min(maxVideoFrames, Int(duration / 2) + 3))
        let probeTimes = (0..<probes).map { duration * (Double($0) + 0.5) / Double(probes) }
        generator.maximumSize = CGSize(width: 64, height: 64)
        var small: [(Double, RasterImage)] = []
        for t in probeTimes {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image, let r = ModelAnimationExport.raster(image) { small.append((t, r)) }
        }
        guard !small.isEmpty else { throw AssetAnalyzerError.unreadable(L10n.t("读不出视频帧", "no readable frames")) }
        s.motionEnergy = AssetFrameMath.meanChange(small.map(\.1))
        // Pass 2: where consecutive probes differ most, look between them too.
        var times = small.map(\.0)
        let changes = zip(small, small.dropFirst()).map { (($0.0 + $1.0) / 2, AssetFrameMath.change($0.1, $1.1)) }.sorted { $0.1 > $1.1 }
        for (t, change) in changes where times.count < maxVideoFrames && change > 0.08 { times.append(t) }
        times.sort()
        generator.maximumSize = CGSize(width: thumbnailSide, height: thumbnailSide)
        var labelSums: [String: Double] = [:], analysed = 0, colours: [String] = []
        var personTimes: [(Double, Double)] = []
        for t in times {
            try Task.checkCancellation()
            guard let frame = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            analysed += 1
            let v = await AssetWork.run { vision(frame) }
            for l in v.labels { labelSums[l.name, default: 0] += l.score }
            if s.featurePrint == nil { s.featurePrint = v.print }
            if colours.isEmpty, let r = ModelAnimationExport.raster(frame) { colours = AssetAnalyzer.dominantColors(r); s.pixel = AssetPixelStats.measure(r) }
            s.peopleCount = max(s.peopleCount, v.people)
            let share: Double? = await AssetWork.run {
                let pose = VNDetectHumanBodyPoseRequest()
                try? VNImageRequestHandler(cgImage: frame, options: [:]).perform([pose])
                guard let body = pose.results?.first, let points = try? body.recognizedPoints(.all) else { return nil }
                let good = points.values.filter { $0.confidence > 0.3 }
                return good.count >= 8 ? Double(good.count) / Double(max(1, points.count)) : nil
            }
            if let share { personTimes.append((t, share)) }
        }
        // Average over the analysed frames (a label seen once scores low).
        s.labels = labelSums.map { AssetTag(name: $0.key, score: $0.value / Double(max(1, analysed)), source: .vision) }
            .sorted { $0.score > $1.score }.prefix(24).map { $0 }
        s.dominantColors = colours
        s.motionSegments = AssetFrameMath.segments(personTimes, gap: max(1.5, duration / Double(max(1, times.count)) * 1.5))
        s.technical.sampledTimes = times
        return s
    }
}

/// Frame differences on small rasters.
enum AssetFrameMath {
    static func change(_ a: RasterImage, _ b: RasterImage) -> Double {
        guard a.width == b.width, a.height == b.height, !a.rgba.isEmpty else { return 1 }
        var sum = 0.0
        let n = a.width * a.height
        for i in 0..<n {
            let o = i * 4
            sum += (abs(Double(a.rgba[o]) - Double(b.rgba[o])) + abs(Double(a.rgba[o + 1]) - Double(b.rgba[o + 1])) + abs(Double(a.rgba[o + 2]) - Double(b.rgba[o + 2]))) / 765
        }
        return sum / Double(max(1, n))
    }

    static func meanChange(_ frames: [RasterImage]) -> Double? {
        guard frames.count >= 2 else { return nil }
        let d = zip(frames, frames.dropFirst()).map { change($0, $1) }
        return d.reduce(0, +) / Double(d.count)
    }

    /// Times with a visible body → spans, merged when closer than `gap`.
    static func segments(_ hits: [(Double, Double)], gap: Double) -> [AssetMotionSegment] {
        var out: [AssetMotionSegment] = []
        for (t, score) in hits.sorted(by: { $0.0 < $1.0 }) {
            if var last = out.last, t - last.end <= gap {
                last.end = t; last.score = max(last.score, score); out[out.count - 1] = last
            } else {
                out.append(AssetMotionSegment(start: t, end: t, label: "person", score: score))
            }
        }
        return out
    }
}

// MARK: Audio

enum AudioAssetAnalyzer {
    static let id = "moonlight.audio"
    static let version = 1
    /// Seconds of audio measured and classified at most.
    static let window = 60.0

    static func analyze(_ url: URL, fileBytes: Int) throws -> AssetSignals {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AssetAnalyzerError.unreadable(L10n.t("不是可读的音频", "not readable audio")) }
        let format = file.processingFormat
        var s = AssetSignals(mediaType: .audio)
        s.technical.fileBytes = fileBytes
        s.technical.sampleRate = format.sampleRate
        s.technical.channels = Int(format.channelCount)
        s.technical.duration = Double(file.length) / max(1, format.sampleRate)
        // Levels over the first minute, in 0.1 s blocks.
        let block = AVAudioFrameCount(max(1, format.sampleRate / 10))
        let limit = AVAudioFramePosition(min(Double(file.length), window * format.sampleRate))
        var peak: Float = 0, squares = 0.0, samples = 0, quiet = 0, blocks = 0
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) {
            while file.framePosition < limit {
                buffer.frameLength = 0
                guard (try? file.read(into: buffer, frameCount: min(block, AVAudioFrameCount(limit - file.framePosition)))) != nil, buffer.frameLength > 0,
                      let data = buffer.floatChannelData else { break }
                var blockSquares = 0.0
                for c in 0..<Int(format.channelCount) { for i in 0..<Int(buffer.frameLength) {
                    let v = data[c][i]; peak = max(peak, abs(v)); blockSquares += Double(v * v)
                } }
                let count = Int(buffer.frameLength) * Int(format.channelCount)
                squares += blockSquares; samples += count; blocks += 1
                if 10 * log10(max(1e-12, blockSquares / Double(max(1, count)))) < -50 { quiet += 1 }
            }
        }
        if samples > 0 {
            s.technical.peakDecibels = 20 * log10(Double(max(peak, 1e-9)))
            s.technical.rmsDecibels = 10 * log10(max(1e-12, squares / Double(samples)))
            s.technical.silenceShare = Double(quiet) / Double(max(1, blocks))
        }
        s.labels = classify(url)
        return s
    }

    /// Apple's built-in sound classifier (SoundAnalysis), first minute only.
    /// Empty when it is not available: then nothing about the content is claimed.
    static func classify(_ url: URL) -> [AssetTag] {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1), let analyzer = try? SNAudioFileAnalyzer(url: url) else { return [] }
        let observer = SoundObserver(window: window) { analyzer.cancelAnalysis() }
        guard (try? analyzer.add(request, withObserver: observer)) != nil else { return [] }
        analyzer.analyze()
        return observer.tags()
    }

    final class SoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var sums: [String: Double] = [:]
        private var windows = 0
        private let window: Double
        private let stop: () -> Void
        init(window: Double, stop: @escaping () -> Void) { self.window = window; self.stop = stop }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            lock.lock()
            windows += 1
            for c in result.classifications.prefix(5) where c.confidence >= 0.2 { sums[c.identifier, default: 0] += c.confidence }
            let done = result.timeRange.start.seconds >= window
            lock.unlock()
            if done { stop() }
        }

        func tags() -> [AssetTag] {
            lock.lock(); defer { lock.unlock() }
            return sums.map { AssetTag(name: $0.key, score: min(1, $0.value / Double(max(1, windows))), source: .sound) }
                .sorted { $0.score > $1.score }.prefix(12).map { $0 }
        }
    }
}

// MARK: 3D models

enum ModelInspector {
    static let id = "moonlight.model"
    static let version = 1

    /// Shape test: taller than wide with human-like joints, or human proportions.
    static func humanoid(bounds: [Double]?, jointNames: [String]) -> Bool? {
        let names = jointNames.map { $0.lowercased() }
        let bodyJoints = ["head", "spine", "hip", "pelvis", "neck", "arm", "leg", "hand", "foot"].filter { key in names.contains { $0.contains(key) } }.count
        if bodyJoints >= 4 { return true }
        guard let b = bounds, b.count == 3 else { return nil }
        let footprint = max(b[0], b[2])
        guard footprint > 0 else { return nil }
        let ratio = b[1] / footprint
        return ratio > 1.8 && ratio < 6
    }

    /// A model already in the Moonlight 3D store: facts come from its
    /// manifest and rig package (no second parse of the mesh).
    @available(iOS 18.0, *)
    @MainActor static func inspect(_ manifest: Generated3DManifest) async -> AssetSignals {
        var s = AssetSignals(mediaType: .model)
        s.technical.vertexCount = manifest.vertexCount
        s.technical.triangleCount = manifest.triangleCount
        s.technical.textureCount = manifest.textureFile != nil ? 1 : 0
        s.technical.textureBytes = manifest.textureWidth * manifest.textureHeight * 4
        s.technical.gpuBytesEstimate = manifest.vertexCount * 32 + manifest.triangleCount * 12 + manifest.textureWidth * manifest.textureHeight * 4
        s.technical.materialCount = 1
        var joints: [String] = []
        if manifest.rigFile != nil, let (package, _) = await Generate3DRigging.load(manifest) {
            s.technical.hasSkeleton = true
            s.technical.hasSkin = true
            joints = package.skeleton.bones.map { "\($0.bone)" }
            s.technical.jointCount = joints.count
            s.technical.animationNames = package.clips.map(\.name)
        } else {
            s.technical.hasSkeleton = false
            s.technical.hasSkin = false
            s.technical.animationNames = []
        }
        s.humanoidShape = manifest.humanoidDetected ? true : humanoid(bounds: nil, jointNames: joints)
        s.technical.realityKitReady = manifest.valid
        s.technical.realityKitNote = manifest.valid ? L10n.t("已通过 Moonlight 导入，可放进 RealityKit 场景", "Imported by Moonlight; ready for the RealityKit scene")
            : L10n.t("模型文件缺失", "Model file missing")
        return s
    }

    /// A model file before import: structure from the shared importer.
    static func file(_ url: URL, fileBytes: Int, companions: [String: Data]) throws -> AssetSignals {
        let ext = url.pathExtension.lowercased()
        var s = AssetSignals(mediaType: .model)
        s.technical.fileBytes = fileBytes
        s.technical.uniformType = UTType(filenameExtension: ext)?.identifier
        guard ModelImport.extensions.contains(ext) else {
            // USD / USDZ: RealityKit reads them when they are imported.
            s.technical.realityKitNote = L10n.t("USD 由 RealityKit 导入时检查", "USD is checked by RealityKit on import")
            return s
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        do {
            let model = try ModelImport.read(data, fileName: url.lastPathComponent, companions: companions)
            let b = model.mesh.bounds
            s.technical.vertexCount = model.mesh.vertexCount
            s.technical.triangleCount = model.mesh.triangleCount
            s.technical.bounds = (0..<3).map { Double(b.max[$0] - b.min[$0]) }
            s.technical.hasSkeleton = model.rig != nil
            s.technical.hasSkin = model.rig != nil
            s.technical.jointCount = model.rig?.skeleton.joints.count
            s.technical.animationNames = model.rig?.clips.map(\.name) ?? []
            s.technical.textureCount = model.texture == nil ? 0 : 1
            s.technical.textureBytes = model.texture?.count
            s.technical.materialCount = 1
            s.technical.gpuBytesEstimate = model.mesh.vertexCount * 32 + model.mesh.triangleCount * 12 + (model.texture?.count ?? 0) * 4
            s.technical.realityKitReady = model.mesh.triangleCount <= AssetRules.maxPolygons
            s.technical.realityKitNote = s.technical.realityKitReady == true ? L10n.t("可导入并放进 RealityKit 场景", "Can be imported into the RealityKit scene")
                : L10n.t("面数超过 \(AssetRules.maxPolygons)", "More than \(AssetRules.maxPolygons) triangles")
            s.humanoidShape = humanoid(bounds: s.technical.bounds, jointNames: model.rig?.skeleton.joints.map(\.jointID) ?? [])
        } catch {
            s.parseError = error.localizedDescription
            s.technical.realityKitReady = false
            s.technical.realityKitNote = error.localizedDescription
        }
        return s
    }
}
