import SwiftUI
import PhotosUI
@preconcurrency import Combine
@preconcurrency import RealityKit
import CoreTransferable
import UniformTypeIdentifiers

struct Local3DSource: Sendable {
    let url: URL
    let title: String
    let isVideo: Bool
    var libraryID: String? = nil
    var owned = false
}

/// Photos transfers files, including videos, without loading them as Data.
struct Local3DPhotoFile: Transferable, Sendable {
    let source: Local3DSource
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Local3DPhotoFile(source: try stage(received.file, video: false))
        }
        FileRepresentation(importedContentType: .movie) { received in
            Local3DPhotoFile(source: try stage(received.file, video: true))
        }
    }

    static func stage(_ url: URL, video: Bool) throws -> Local3DSource {
        let fm = FileManager.default
        let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= (video ? 2 << 30 : 100 << 20) else {
            throw GenerationError.invalidInput("素材为空或过大（图片最多 100 MB，视频最多 2 GB）。")
        }
        let directory = fm.temporaryDirectory.appendingPathComponent("local3d-import-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? fm.removeItem(at: directory) } }
        try GenerationResources.checkDisk(at: directory, bytes: size)
        let ext = url.pathExtension.lowercased()
        let safeExtension = ext.count <= 12 && !ext.isEmpty && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? ext : (video ? "mov" : "jpg")
        let target = directory.appendingPathComponent("input").appendingPathExtension(safeExtension)
        fm.createFile(atPath: target.path, contents: nil)
        let input = try FileHandle(forReadingFrom: url), output = try FileHandle(forWritingTo: target)
        defer { try? input.close(); try? output.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try GenerationResources.check(minimumMemory: 100 << 20)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        complete = true
        return Local3DSource(url: target, title: url.lastPathComponent, isVideo: video, owned: true)
    }
}

/// Cancellable async RealityKit loader. Owned and used only on the main actor.
@MainActor
final class GeneratedModelLoader {
    private var subscription: AnyCancellable?
    private var continuation: CheckedContinuation<Entity, Error>?

    func load(_ url: URL) async throws -> Entity {
        cancel()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                subscription = Entity.loadAsync(contentsOf: url).sink { [weak self] completion in
                    if case .failure(let error) = completion { self?.finish(.failure(error)) }
                } receiveValue: { [weak self] entity in self?.finish(.success(entity)) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func finish(_ result: Result<Entity, Error>) {
        let pending = continuation
        continuation = nil; subscription = nil
        pending?.resume(with: result)
    }

    func cancel() {
        subscription?.cancel()
        finish(.failure(CancellationError()))
    }
}

@MainActor
final class GenerationTaskManager: ObservableObject {
    static let shared = GenerationTaskManager()
    @Published private(set) var busy = false
    @Published private(set) var stage = ""
    @Published private(set) var fraction: Double?
    @Published var error: String?
    @Published private(set) var models: [GeneratedModelManifest] = []
    @Published private(set) var video: VideoReconstructionInput?
    @Published private(set) var selection: GeneratedModelManifest?
    @Published private(set) var entity: Entity?
    @Published var preset: ModelSkinPreset?
    private var task: Task<Void, Never>?
    private var source: Local3DSource?
    private let loader = GeneratedModelLoader()
    private var cancellationReason: GenerationError?

    private var progress: GenerationProgress {
        { [weak self] label, fraction in
            await self?.updateProgress(label, fraction)
        }
    }

    private func updateProgress(_ label: String, _ value: Double?) { stage = label; fraction = value }

    func refresh() async {
        do { models = try await GeneratedAssetStore.shared.list() }
        catch { self.error = "资产库读取失败：\(error.localizedDescription)" }
    }

    func importFile(_ url: URL) {
        run {
            let copying = Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let video = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
                return try Local3DPhotoFile.stage(url, video: video)
            }
            let staged = try await withTaskCancellationHandler { try await copying.value } onCancel: { copying.cancel() }
            // A detached copy checks its own cancellation; ownership is cleaned if
            // the surrounding task was cancelled while the copy was in flight.
            if Task.isCancelled { self.dispose(staged); throw CancellationError() }
            self.setSource(staged)
            try await self.process(staged)
        }
    }

    func importPhotos(_ item: PhotosPickerItem) {
        run {
            guard let file = try await item.loadTransferable(type: Local3DPhotoFile.self) else {
                throw GenerationError.invalidInput("相册无法提供本地文件。飞行模式下，请选择已下载到此 iPhone 的原片。")
            }
            if Task.isCancelled { self.dispose(file.source); throw CancellationError() }
            self.setSource(file.source)
            try await self.process(file.source)
        }
    }

    func reuse(_ item: Glass3DMediaItem) {
        run {
            let source = Local3DSource(url: item.url, title: item.title, isVideo: item.kind == .video, libraryID: item.id)
            self.setSource(source)
            try await self.process(source)
        }
    }

    func retry() {
        guard let source else { return }
        run { try await self.process(source) }
    }

    func generateFrame(_ frame: URL) {
        guard let video, video.frames.contains(frame) else { return }
        run {
            let title = (self.source?.title ?? "视频") + " · " + frame.lastPathComponent
            try await self.generateImage(Local3DSource(url: frame, title: title, isVideo: false))
        }
    }

    func reconstruct() {
        guard let input = video, let source else { return }
        run {
            guard #available(iOS 17.0, *) else { throw GenerationError.unsupported("Object Capture 需要 iOS 17 及兼容硬件。") }
            let start = Date()
            let url = try await LocalObjectCapture.reconstruct(input: input, progress: self.progress)
            let manifest = try await GeneratedAssetStore.shared.saveReconstruction(model: url, source: source.url,
                title: source.title, elapsed: Date().timeIntervalSince(start))
            try await self.validateAndOpen(manifest, rollback: true)
        }
    }

    func open(_ manifest: GeneratedModelManifest) {
        run { try await self.validateAndOpen(manifest, rollback: false) }
    }

    func delete(_ manifest: GeneratedModelManifest) {
        run {
            if self.selection?.id == manifest.id { self.entity = nil; self.selection = nil; self.preset = nil }
            try await GeneratedAssetStore.shared.delete(manifest.id)
            await self.refresh()
        }
    }

    func savePreset() {
        guard let preset else { return }
        run {
            try await GeneratedAssetStore.shared.savePreset(preset)
            self.stage = "整体材质预设已保存；没有识别独立服装或骨骼。"
        }
    }

    func cancel(reason: GenerationError = .cancelled) {
        guard busy else { return }
        cancellationReason = reason
        task?.cancel(); loader.cancel()
        stage = "正在取消并释放资源…"
    }

    func releasePreview() {
        if !busy { entity = nil; selection = nil; preset = nil }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; fraction = nil; cancellationReason = nil
        stage = "准备本地任务"
        task = Task { @MainActor in
            defer { busy = false; task = nil; fraction = nil; if Task.isCancelled { entity = nil; selection = nil; preset = nil } }
            do {
                try await operation()
                try Task.checkCancellation()
            } catch {
                self.error = cancellationReason?.localizedDescription ?? (error is CancellationError ? GenerationError.cancelled.localizedDescription : error.localizedDescription)
                stage = "任务未完成"
                // Failed transactions may leave content-addressed files; reclaim
                // only when every committed manifest can be read safely.
                try? await GeneratedAssetStore.shared.removeUnreferencedContent()
            }
        }
    }

    private func process(_ source: Local3DSource) async throws {
        if source.isVideo {
            if let video { try? FileManager.default.removeItem(at: video.directory) }
            video = nil
            let result = try await Local3DGenerator.shared.video(source: source.url, progress: progress)
            if Task.isCancelled { try? FileManager.default.removeItem(at: result.directory); throw CancellationError() }
            video = result; stage = "视频质量检查完成，尚未重建"
        } else { try await generateImage(source) }
    }

    private func generateImage(_ source: Local3DSource) async throws {
        entity = nil; selection = nil; preset = nil
        let manifest = try await Local3DGenerator.shared.image(source: source.url, title: source.title,
            libraryID: source.libraryID, progress: progress)
        try await validateAndOpen(manifest, rollback: true)
    }

    private func validateAndOpen(_ manifest: GeneratedModelManifest, rollback: Bool) async throws {
        do {
            try Task.checkCancellation()
            stage = "RealityKit 正在加载已保存的 USDZ"
            entity = nil; selection = nil; preset = nil
            let loaded = try await loader.load(GeneratedAssetStore.shared.modelURL(manifest.id))
            try Task.checkCancellation()
            let bounds = loaded.visualBounds(relativeTo: nil)
            let extent = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
            guard extent.isFinite, extent > 0.00001 else { throw GenerationError.corruptAsset }
            let skin = try await GeneratedAssetStore.shared.preset(manifest.id)
            let confirmed = try await GeneratedAssetStore.shared.confirmRealityKit(manifest.id)
            try Task.checkCancellation()
            entity = loaded; selection = confirmed; preset = skin
            stage = manifest.kind == .depthSurface ? "深度立体模型已保存并通过 RealityKit 加载；背面未恢复。" : "摄影测量模型已保存并通过 RealityKit 加载；请旋转检查几何质量。"
            await refresh()
        } catch {
            if rollback { try? await GeneratedAssetStore.shared.delete(manifest.id) }
            throw error
        }
    }

    private func setSource(_ newSource: Local3DSource) {
        if let source { dispose(source) }
        if let video { try? FileManager.default.removeItem(at: video.directory) }
        video = nil; source = newSource
    }

    private func dispose(_ source: Local3DSource) {
        if source.owned { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }
    }
}
