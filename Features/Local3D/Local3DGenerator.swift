import Foundation
import RealityKit

@available(iOS 17.0, *)
@MainActor
private final class ObjectCaptureControl {
    let session: PhotogrammetrySession
    init(_ session: PhotogrammetrySession) { self.session = session }
    func cancel() { session.cancel() }
}

/// Single isolated worker for decoding, Vision, inference, mesh generation and disk IO.
actor Local3DGenerator {
    static let shared = Local3DGenerator()
    private var running = false

    func image(source: URL, title: String, libraryID: String?, progress: GenerationProgress) async throws -> GeneratedModelManifest {
        guard !running else { throw GenerationError.busy }
        running = true
        defer { running = false }
        let start = Date()
        let result = try await ImageGenerationPipeline.generate(source: source, progress: progress)
        try await GenerationResources.checkpoint()
        await progress("写入纹理、真实网格与离线资产", nil)
        return try await GeneratedAssetStore.shared.saveImage(result, source: source, title: title, libraryID: libraryID,
                                                              elapsed: Date().timeIntervalSince(start))
    }

    func video(source: URL, progress: GenerationProgress) async throws -> VideoReconstructionInput {
        guard !running else { throw GenerationError.busy }
        running = true
        defer { running = false }
        return try await VideoReconstructionPipeline.extract(source: source, progress: progress)
    }
}

/// Apple's iOS support is isolated from the iOS 16 base app.
/// Main actor owns the session and its cancellation/thermal monitor.
@MainActor
enum LocalObjectCapture {
    static var supported: Bool {
        if #available(iOS 17.0, *) { return PhotogrammetrySession.isSupported }
        return false
    }

    @available(iOS 17.0, *)
    static func reconstruct(input: VideoReconstructionInput, progress: GenerationProgress) async throws -> URL {
        guard supported else { throw GenerationError.unsupported("该设备不支持本地 Object Capture。可从清晰单帧生成深度立体模型。") }
        guard input.report.canAttemptObjectCapture else { throw GenerationError.invalidInput(input.report.guidance) }
        try await GenerationResources.checkpoint(minimumMemory: 1_200 << 20)
        let output = input.directory.appendingPathComponent("reconstruction.usdz")
        // Output is outside the input images folder to prevent accidental ingestion.
        let images = input.directory.appendingPathComponent("capture-input")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for frame in input.frames {
            let target = images.appendingPathComponent(frame.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.linkItem(at: frame, to: target) }
        }
        defer { try? FileManager.default.removeItem(at: images) }
        let session = try PhotogrammetrySession(input: images)
        let control = ObjectCaptureControl(session)
        var thermalFailure = false
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
                    thermalFailure = true; session.cancel(); return
                }
                if GenerationResources.availableBytes < 240 << 20 { session.cancel(); return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        defer { monitor.cancel(); session.cancel() }
        return try await withTaskCancellationHandler {
            try session.process(requests: [.modelFile(url: output, detail: .reduced)])
            for try await event in session.outputs {
                try Task.checkCancellation()
                switch event {
                case .requestProgress(_, let fraction): await progress("本地摄影测量", fraction)
                case .requestError(_, let error): throw error
                case .processingCancelled: throw thermalFailure ? GenerationError.thermal : GenerationError.memory
                case .requestComplete(_, let result):
                    if case .modelFile(let url) = result, FileManager.default.fileExists(atPath: url.path) { return url }
                default: break
                }
            }
            throw GenerationError.invalidInput("摄影测量未生成模型。请增加静止物体的环绕视角后重试。")
        } onCancel: {
            Task { @MainActor in control.cancel() }
        }
    }
}
