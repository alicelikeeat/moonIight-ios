import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit

// v1.87 AI Asset Director — the app-side coordinator. It owns the library
// state (records, links, queue, settings) in its own versioned file,
// stores each original exactly once in the store that already owns that
// kind of file (media library, 3D model store, or its own folder for
// audio), runs analysis through a bounded queue, and executes confirmed
// operations through Moonlight's existing pipelines.

@available(iOS 18.0, *)
@MainActor
final class AIAssetDirector: ObservableObject {
    static let shared = AIAssetDirector()

    @Published private(set) var state = AssetLibraryState()
    @Published private(set) var message: String?
    @Published private(set) var loadProblem: String?
    @Published private(set) var evaluating = false
    /// Assets the user sent to the World Director from the library.
    @Published var directorPicks: Set<String> = []

    private let file: VersionedJSONFile<AssetLibraryState>
    private let writer: VersionedJSONWriter<AssetLibraryState>
    private var sequence = 0
    private var saveTask: Task<Void, Never>?
    private var running: [String: Task<Void, Never>] = [:]
    /// Facts read from a model file before it went into the 3D store.
    private var fileSignals: [String: AssetSignals] = [:]
    private var memoryPressureUntil: Date?
    private var inBackground = false

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("AssetDirector", isDirectory: true)
    }
    static var filesFolder: URL { folder.appendingPathComponent("Files", isDirectory: true) }

    private init() {
        file = VersionedJSONFile(directory: Self.folder, name: "library", schemaVersion: AssetLibraryState.schemaVersion)
        var loaded = AssetLibraryState(), revision = 0, blocked = false
        do {
            if let snapshot = try file.load() { loaded = snapshot.payload; revision = snapshot.revision }
        } catch VersionedFileError.futureSchema(let v) {
            blocked = true; loadProblem = L10n.t("素材库由更新版本（\(v)）保存，此版本只读", "Saved by a newer version (\(v)); read-only here")
        } catch {
            loadProblem = error.localizedDescription
        }
        writer = VersionedJSONWriter(file: file, loadedRevision: revision, blocked: blocked)
        sequence = revision
        // Interrupted analyses wait again; links to missing records go.
        AssetQueuePolicy.recover(&loaded.queue)
        _ = SemanticAssetLibrary.repair(&loaded)
        for id in loaded.records.keys where loaded.records[id]?.status == .analysing { loaded.records[id]?.status = .queued }
        state = loaded
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.memoryPressureUntil = Date().addingTimeInterval(30) }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.inBackground = true; self.saveNow() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.inBackground = false; self.pump() }
        }
        pump()
    }

    // MARK: Saving

    private func changed() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        sequence += 1
        let snapshot = state, seq = sequence, writer = writer
        Task.detached(priority: .utility) { _ = try? await writer.save(snapshot, sequence: seq) }
    }

    private func mutate(_ body: (inout AssetLibraryState) -> Void) {
        var s = state; body(&s); state = s; changed()
    }

    // MARK: Capabilities

    var capabilities: AssetCapabilities {
        AssetCapabilities(depthModelBundled: DepthAnythingModel.bundled, cloudKeyPresent: SecureSettings.read(ClaudeMotion.keyAccount)?.isEmpty == false,
                          cloudConsent: state.settings.cloudVision)
    }

    func updateSettings(_ change: (inout AssetDirectorSettings) -> Void) { mutate { change(&$0.settings) } }

    // MARK: Ingestion

    /// Files from Files / Photos: checked, hashed, stored once, queued.
    func importFiles(_ urls: [URL], origin: AssetSourceType, store: MediaStore) async {
        var added = 0, duplicates = 0, refused: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            switch await ingest(url, name: name, origin: origin, store: store) {
            case .added: added += 1
            case .duplicate: duplicates += 1
            case .refused(let why): refused.append("\(name)：\(why)")
            }
        }
        var parts = [L10n.t("新增 \(added) 个", "\(added) added")]
        if duplicates > 0 { parts.append(L10n.t("\(duplicates) 个重复（已复用分析结果）", "\(duplicates) duplicates (analysis reused)")) }
        if !refused.isEmpty { parts.append(L10n.t("拒绝 \(refused.count) 个：", "\(refused.count) refused: ") + refused.prefix(3).joined(separator: "；")) }
        message = parts.joined(separator: " · ")
        pump()
    }

    enum IngestResult { case added, duplicate, refused(String) }

    private func ingest(_ url: URL, name: String, origin: AssetSourceType, store: MediaStore, license: String? = nil, author: String? = nil, proof: String? = nil) async -> IngestResult {
        let probe = await Task.detached(priority: .userInitiated) { () -> (size: Int, head: [UInt8], hash: String?) in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            let head = (try? FileHandle(forReadingFrom: url)).map { h -> [UInt8] in defer { try? h.close() }; return [UInt8]((try? h.read(upToCount: 64)) ?? Data()) } ?? []
            return (size, head, size > 0 ? try? MediaImportIndex.sha256(of: url) : nil)
        }.value
        let type: AssetMediaType
        switch AssetFileSafety.check(fileName: name, size: probe.size, head: probe.head) {
        case .failure(let rejection): return .refused(rejection.message)
        case .success(let t): type = t
        }
        guard let hash = probe.hash else { return .refused(AssetImportRejection.damaged(L10n.t("无法计算内容哈希", "no content hash")).message) }
        if SemanticAssetLibrary.record(forHash: hash, in: state) != nil { return .duplicate }
        let id = "asset:" + String(hash.prefix(24))
        let storage: AssetStorageReference
        switch type {
        case .image, .gif, .video:
            guard let entry = await store.importLocalFile(url, title: (name as NSString).deletingPathExtension, kind: type == .video ? .video : .image) else {
                return .refused(L10n.t("无法保存到素材库", "could not be saved to the library"))
            }
            storage = .library(entry.id)
        case .model:
            let ext = url.pathExtension.lowercased()
            let data: Data
            do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { return .refused(error.localizedDescription) }
            let unsafe = AssetFileSafety.externalReferences(modelExtension: ext, data: data)
            if let first = unsafe.first { return .refused(AssetImportRejection.externalReference(first).message) }
            if let pre = try? await Task.detached(priority: .userInitiated, operation: { try ModelInspector.file(url, fileBytes: probe.size, companions: [:]) }).value {
                if let problem = pre.parseError { return .refused(AssetImportRejection.damaged(problem).message) }
                fileSignals[id] = pre
            }
            do {
                let manifest = try await Generated3DStore.shared.storeImported(files: [(name: name, data: data)])
                storage = .generatedModel(manifest.id)
            } catch { return .refused(error.localizedDescription) }
        case .audio:
            let target = UUID().uuidString + "." + url.pathExtension.lowercased()
            do {
                try FileManager.default.createDirectory(at: Self.filesFolder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: Self.filesFolder.appendingPathComponent(target))
            } catch { return .refused(error.localizedDescription) }
            storage = .directorFile(target)
        }
        add(id: id, hash: hash, type: type, storage: storage, title: (name as NSString).deletingPathExtension,
            provenance: .initial(origin: origin, license: license, author: author, proof: proof))
        return .added
    }

    private func add(id: String, hash: String, type: AssetMediaType, storage: AssetStorageReference, title: String, provenance: AssetProvenance) {
        let now = Date()
        let record = AssetIntelligenceRecord(assetID: id, contentHash: hash, mediaType: type, storage: storage, title: String(title.prefix(120)),
                                             createdAt: now, updatedAt: now, provenance: provenance)
        mutate {
            SemanticAssetLibrary.upsert(record, into: &$0)
            AssetQueuePolicy.enqueue([id], into: &$0.queue, now: now)
        }
    }

    /// Pictures, videos and GIFs already in the Moonlight library.
    func importLibrary(_ items: [Glass3DMediaItem]) async {
        var added = 0
        let attributions = Glass3DAttributions.shared.byMedia
        for item in items {
            let hash = (try? await Task.detached { try MediaImportIndex.sha256(of: item.url) }.value) ?? ("library:" + item.id)
            guard SemanticAssetLibrary.record(forHash: hash, in: state) == nil else { continue }
            let type: AssetMediaType = item.kind == .video ? .video : item.kind == .gif ? .gif : .image
            let credit = attributions[item.id]
            let origin: AssetSourceType = credit == nil ? .library : (credit!.provider.contains("Kenney") || credit!.provider.contains("Poly") ? .builtin : .internet)
            add(id: "asset:" + String(hash.prefix(24)), hash: hash, type: type, storage: .library(item.id), title: item.title,
                provenance: .initial(origin: origin, license: credit?.license, author: credit?.author, proof: credit?.licenseURL))
            added += 1
        }
        message = L10n.t("从素材库加入 \(added) 个", "\(added) added from the library")
        pump()
    }

    /// 3D models already in the model store (AI-made or imported).
    func importModels(_ manifests: [Generated3DManifest]) {
        var added = 0
        for m in manifests where m.valid {
            let hash = m.sourceHash.isEmpty ? "model:" + m.id : "model:" + m.sourceHash
            guard SemanticAssetLibrary.record(forHash: hash, in: state) == nil else { continue }
            let origin: AssetSourceType = m.geometry == .imported ? .files : .generatedModel
            add(id: "asset:model:" + m.id, hash: hash, type: .model, storage: .generatedModel(m.id), title: m.name,
                provenance: .initial(origin: origin, license: nil, author: nil, proof: nil))
            added += 1
        }
        message = L10n.t("加入 \(added) 个 3D 模型", "\(added) 3D models added")
        pump()
    }

    // MARK: Queue

    private var conditions: AssetDeviceConditions {
        AssetDeviceConditions(thermal: ProcessInfo.processInfo.thermalState.rawValue, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                              memoryMB: Int(ProcessInfo.processInfo.physicalMemory >> 20), background: inBackground)
    }

    /// Starts as many waiting analyses as the device allows right now.
    func pump() {
        var limit = AssetQueuePolicy.concurrency(conditions)
        if let until = memoryPressureUntil, until > Date() { limit = min(limit, 1) }
        let ids = AssetQueuePolicy.next(state.queue, limit: limit)
        guard !ids.isEmpty else { return }
        mutate { s in for id in ids { AssetQueuePolicy.start(id, in: &s.queue); s.records[id]?.status = .analysing } }
        for id in ids { running[id] = Task { [weak self] in await self?.analyse(id) } }
    }

    func pause(_ paused: Bool) { mutate { $0.queue.paused = paused }; if !paused { pump() } }

    func cancelAll() {
        for task in running.values { task.cancel() }
        running.removeAll()
        mutate { s in
            AssetQueuePolicy.cancel(in: &s.queue)
            for (id, r) in s.records where r.status == .queued || r.status == .analysing { s.records[id]?.status = .cancelled }
        }
    }

    func retryFailed() {
        mutate { s in
            AssetQueuePolicy.retryFailed(in: &s.queue)
            for job in s.queue.jobs where job.state == .waiting { s.records[job.assetID]?.status = .queued }
        }
        pump()
    }

    /// Analyse again (e.g. after enabling cloud analysis); locked fields stay.
    func reanalyse(_ ids: [String]) {
        mutate { s in
            for id in ids { s.records[id]?.analysis = nil; s.records[id]?.status = .queued }
            AssetQueuePolicy.enqueue(ids, into: &s.queue, now: Date())
        }
        pump()
    }

    private func cacheKey(_ r: AssetIntelligenceRecord, cloud: Bool) -> AssetCacheKey {
        let analyzer: (String, Int) = switch r.mediaType {
        case .image, .gif, .video: (VisualSemanticAnalyzer.id, VisualSemanticAnalyzer.version)
        case .audio: (AudioAssetAnalyzer.id, AudioAssetAnalyzer.version)
        case .model: (ModelInspector.id, ModelInspector.version)
        }
        return AssetCacheKey(contentHash: r.contentHash, analyzerID: analyzer.0 + "+" + AssetClassifier.id,
                             analyzerVersion: analyzer.1 * 100 + AssetClassifier.version, configurationVersion: cloud ? 2 : 1)
    }

    private func analyse(_ id: String) async {
        defer { running[id] = nil; pump() }
        guard let record = state.records[id] else { mutate { AssetQueuePolicy.finish(id, in: &$0.queue) }; return }
        let cloudWanted = state.settings.cloudVision && (record.mediaType == .image || record.mediaType == .gif)
        let key = cacheKey(record, cloud: cloudWanted)
        let started = Date()
        do {
            var signals: AssetSignals
            // Same content, same analyzer and configuration: reuse the measured
            // signals and only re-decide (cheap, keeps user locks).
            if let cached = record.signals, let a = record.analysis,
               AssetCacheKey(contentHash: record.contentHash, analyzerID: a.analyzerID, analyzerVersion: a.analyzerVersion, configurationVersion: a.configurationVersion) == key {
                signals = cached
            } else if let other = state.records.values.first(where: { $0.assetID != id && $0.contentHash == record.contentHash && $0.signals != nil }), let s = other.signals {
                signals = s
            } else {
                signals = try await measure(record)
                if cloudWanted, let enriched = await cloudLabels(record) { signals.labels += enriched.labels }
            }
            try Task.checkCancellation()
            let classification = AssetClassifier.classify(signals, calibration: state.calibration)
            let info = AssetAnalysisInfo(analyzerID: key.analyzerID, analyzerVersion: key.analyzerVersion, configurationVersion: key.configurationVersion,
                                         analyzedAt: Date(), cloud: cloudWanted, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
            mutate { s in
                guard var r = s.records[id] else { return }
                AssetClassifier.apply(classification, to: &r, signals: signals, analysis: info, now: Date())
                s.records[id] = r
                AssetQueuePolicy.finish(id, in: &s.queue)
                SemanticAssetLibrary.suggestRelationships(in: &s)
            }
        } catch is CancellationError {
            mutate { s in s.records[id]?.status = .cancelled; AssetQueuePolicy.cancel([id], in: &s.queue) }
        } catch {
            let retryable = !(error is AssetAnalyzerError)
            mutate { s in
                AssetQueuePolicy.fail(id, error: error.localizedDescription, retryable: retryable, in: &s.queue)
                let failed = s.queue.jobs.first { $0.assetID == id }?.state == .failed
                s.records[id]?.failures.append(AssetFailure(stage: "analyse", message: String(error.localizedDescription.prefix(300)), at: Date()))
                s.records[id]?.status = failed ? .failed : .queued
            }
        }
    }

    /// The one stored copy of the file, resolved by the store that owns it.
    func fileURL(_ storage: AssetStorageReference) -> URL? {
        switch storage {
        case .library(let id): return AppModelBridge.store?.items.first { $0.id == id }?.remoteURL
        case .generatedModel(let id):
            guard let m = Generated3DStore.shared.models.first(where: { $0.id == id }) else { return nil }
            return Generated3DStore.shared.meshURL(m)
        case .builtin(let name):
            return Glass3DStarterPack.manifest?.items.first { $0.file == name }.flatMap(Glass3DStarterPack.url)
        case .directorFile(let name):
            guard !name.contains("/"), !name.contains("..") else { return nil }
            return Self.filesFolder.appendingPathComponent(name)
        }
    }

    private func measure(_ r: AssetIntelligenceRecord) async throws -> AssetSignals {
        if case .generatedModel(let mid) = r.storage {
            guard let manifest = Generated3DStore.shared.models.first(where: { $0.id == mid }) else { throw AssetAnalyzerError.unreadable(L10n.t("模型已不在模型库", "model no longer in the model store")) }
            var s = await ModelInspector.inspect(manifest)
            if let pre = fileSignals[r.assetID] {
                // Bounds and the file's own clip names come from the original file.
                s.technical.bounds = pre.technical.bounds
                if s.technical.animationNames?.isEmpty ?? true { s.technical.animationNames = pre.technical.animationNames }
                s.humanoidShape = s.humanoidShape ?? pre.humanoidShape
            }
            return s
        }
        guard let url = fileURL(r.storage), FileManager.default.fileExists(atPath: url.path) else {
            throw AssetAnalyzerError.unreadable(L10n.t("原文件不存在", "the original file is missing"))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        switch r.mediaType {
        case .image: return try await Task.detached(priority: .utility) { try VisualSemanticAnalyzer.image(url, fileBytes: size) }.value
        case .gif: return try await Task.detached(priority: .utility) { try VisualSemanticAnalyzer.gif(url, fileBytes: size) }.value
        case .video: return try await Task.detached(priority: .utility) { try await VisualSemanticAnalyzer.video(url, fileBytes: size) }.value
        case .audio: return try await Task.detached(priority: .utility) { try AudioAssetAnalyzer.analyze(url, fileBytes: size) }.value
        case .model: return try await Task.detached(priority: .utility) { try ModelInspector.file(url, fileBytes: size, companions: [:]) }.value
        }
    }

    // MARK: Cloud (only with its own consent)

    private func cloudLabels(_ r: AssetIntelligenceRecord) async -> AssetAIOutputValidator.Answer? {
        guard let key = SecureSettings.read(ClaudeMotion.keyAccount), !key.isEmpty,
              AssetCloudPolicy.may(upload: 1, settings: state.settings, keyPresent: true, now: Date()) == .allowed,
              let url = fileURL(r.storage) else { return nil }
        let jpeg: Data? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = VisualSemanticAnalyzer.thumbnail(source, side: AssetCloudPolicy.maxImageSide) else { return nil }
            return PixelReader.jpeg(thumb, quality: 0.75)
        }.value
        guard let jpeg, jpeg.count <= AssetCloudPolicy.maxUploadBytes else { return nil }
        updateSettings { AssetCloudPolicy.record(1, in: &$0, now: Date()) }
        return try? await ClaudeVisionAnalyzer.analyze(jpeg: jpeg, apiKey: key)
    }

    // MARK: Corrections (UI)

    func setCategory(_ id: String, primary: AssetCategory, secondary: [AssetCategory]) {
        mutate { SemanticAssetLibrary.setCategory(id, primary: primary, secondary: secondary, in: &$0, now: Date()) }
    }
    func setCategory(_ ids: [String], primary: AssetCategory) {
        mutate { SemanticAssetLibrary.setCategory(ids, primary: primary, in: &$0, now: Date()) }
    }
    func addTag(_ id: String, _ tag: String) { mutate { SemanticAssetLibrary.addTag(id, tag: tag, in: &$0, now: Date()) } }
    func removeTag(_ id: String, _ tag: String) { mutate { SemanticAssetLibrary.removeTag(id, tag: tag, in: &$0, now: Date()) } }
    func setLock(_ id: String, _ field: AssetLockField, _ locked: Bool) { mutate { SemanticAssetLibrary.setLock(id, field: field, locked: locked, in: &$0) } }
    func setProvenance(_ id: String, _ p: AssetProvenance) { mutate { SemanticAssetLibrary.setProvenance(id, p, in: &$0, now: Date()) } }
    func confirmRelation(_ rel: AssetRelationship, accept: Bool) { mutate { SemanticAssetLibrary.confirm(rel.from, rel.to, kind: rel.kind, accept: accept, in: &$0) } }

    /// Where a record is used in the saved world (2D and 3D share it):
    /// any media binding showing the library file, any character built
    /// from the model. Empty means it can be removed safely.
    func references(_ id: String) -> [String] {
        let world = WorldHost.shared.session.world
        let media = Set(world.mediaBindings.map(\.mediaID))
        let models = Set((world.spatial?.characters ?? []).compactMap(\.generatedModelID))
        return SemanticAssetLibrary.references(to: id, in: state, worldMediaIDs: media, worldModelIDs: models)
    }

    /// Removes the analysis record only. The media / model file stays in its own store.
    func removeRecord(_ id: String) {
        running[id]?.cancel()
        mutate { s in SemanticAssetLibrary.removeRecord(id, in: &s); s.queue.jobs.removeAll { $0.assetID == id } }
    }

    // MARK: Evaluation on the bundled, labelled starter pack

    /// Classifies every starter-pack file (Kenney characters, Poly Haven
    /// textures: real CC0 files with their group as the label), fits the
    /// thresholds and keeps the result. Nothing is added to the library.
    func evaluateStarterPack() async {
        guard !evaluating, let items = Glass3DStarterPack.manifest?.items else { return }
        evaluating = true; defer { evaluating = false }
        var results: [(name: String, scores: [AssetScoredCategory], truth: AssetCategory)] = []
        for item in items {
            guard let truth: AssetCategory = item.group == "characters" ? .character : item.group == "textures" ? .material : nil,
                  let url = Glass3DStarterPack.url(item) else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            let gif = item.kind == "gif"
            guard let signals = try? await Task.detached(priority: .utility, operation: { gif ? try VisualSemanticAnalyzer.gif(url, fileBytes: size) : try VisualSemanticAnalyzer.image(url, fileBytes: size) }).value else { continue }
            results.append((item.file, AssetClassifier.classify(signals).scores, truth))
        }
        let evaluation = AssetEvaluation.measure(results)
        let calibration = AssetCalibration.fit(results.map { ($0.scores, $0.truth) })
        mutate { $0.lastEvaluation = evaluation; $0.calibration = calibration }
        message = L10n.t("评测 \(evaluation.samples) 个内置素材：Top-1 \(Int(evaluation.top1 * 100))%，Top-3 \(Int(evaluation.top3 * 100))%",
                         "Evaluated \(evaluation.samples) bundled assets: top-1 \(Int(evaluation.top1 * 100))%, top-3 \(Int(evaluation.top3 * 100))%")
    }

    // MARK: Operations (after the user confirms)

    func run(_ task: AssetTaskSuggestion, controller: AnyObject?) async -> String {
        guard task.state.usable else {
            if case .needsSetup(let why) = task.state { return why }
            if case .unavailable(let why) = task.state { return why }
            return ""
        }
        guard let id = task.inputIDs.first, let r = state.records[id] else { return L10n.t("素材不存在", "Asset not found") }
        switch task.operation {
        case .generateModelFromImage:
            guard let url = fileURL(r.storage) else { return L10n.t("原图不存在", "The picture is missing") }
            let manager = GenerationTaskManager()
            manager.generate(image: url, name: r.title, quality: .medium, store: Generated3DStore.shared, removeAfter: false)
            while manager.running { try? await Task.sleep(nanoseconds: 300_000_000) }
            switch manager.phase {
            case .finished(let modelID):
                importModels(Generated3DStore.shared.models.filter { $0.id == modelID })
                if let newID = state.records.values.first(where: { $0.storage == .generatedModel(modelID) })?.assetID {
                    mutate { SemanticAssetLibrary.relate(AssetRelationship(from: id, to: newID, kind: .derivedFrom, origin: .pipeline, confirmed: true, note: nil), in: &$0) }
                }
                return L10n.t("已生成 3D 模型，并记录为由这张图片派生", "Made a 3D model and recorded it as derived from this picture")
            case .failed(let why): return why
            default: return L10n.t("生成已取消", "Generation cancelled")
            }
        case .autoRig:
            guard case .generatedModel(let mid) = r.storage, let m = Generated3DStore.shared.models.first(where: { $0.id == mid }) else { return L10n.t("模型不存在", "Model not found") }
            do {
                _ = try await Generate3DRigging.rig(m, store: Generated3DStore.shared)
                reanalyse([id])
                return L10n.t("已自动绑定骨骼和蒙皮（原网格保留）", "Rigged and skinned (the mesh is kept)")
            } catch { return error.localizedDescription }
        case .generateMotion:
            guard case .generatedModel(let mid) = r.storage, let m = Generated3DStore.shared.models.first(where: { $0.id == mid }),
                  let key = SecureSettings.read(ClaudeMotion.keyAccount), let (package, _) = await Generate3DRigging.load(m) else { return L10n.t("模型还没有骨骼", "The model is not rigged") }
            var made: [String] = []
            for (name, text) in [("idle", "calm idle, breathing"), ("walk", "steady walk cycle"), ("attack", "one quick sword swing")] {
                guard let clip = try? await ClaudeMotionClient.design(description: text, skeleton: package.skeleton, model: ClaudeMotion.models[1], apiKey: key),
                      (try? await Generate3DRigging.addClip(clip, to: m, store: Generated3DStore.shared)) != nil else { continue }
                made.append(name)
            }
            reanalyse([id])
            return made.isEmpty ? L10n.t("没有生成可用的动作（未通过本机检查或请求失败）", "No usable motion (failed the check or the request)")
                : L10n.t("已加入动作：", "Added motion: ") + made.joined(separator: "、")
        case .useAsStyleReference:
            directorPicks.insert(id)
            return L10n.t("已加入世界导演的素材清单（只作风格参考）", "Added to the World Director's assets (style reference only)")
        case .buildStyleGroup:
            let name = L10n.t("风格组", "Style group") + " \(Set(state.records.values.flatMap(\.userTags).filter { $0.hasPrefix(L10n.t("风格组", "Style group")) }).count + 1)"
            mutate { s in
                for other in task.inputIDs { SemanticAssetLibrary.addTag(other, tag: name, in: &s, now: Date()) }
                for other in task.inputIDs.dropFirst() {
                    SemanticAssetLibrary.relate(AssetRelationship(from: task.inputIDs[0], to: other, kind: .sameStyle, origin: .user, confirmed: true, note: name), in: &s)
                }
            }
            return L10n.t("已建立「\(name)」", "Created “\(name)”")
        case .placeSprite, .placeModel, .adaptEffect, .configureMaterial:
            if #available(iOS 18.0, *), let controller = controller as? Glass3DController {
                return await controller.placeDirectorAsset(r, operation: task.operation, director: self)
            }
            directorPicks.insert(id)
            return L10n.t("请在 3D 世界里打开智能素材库来放置；已加入世界导演的素材清单", "Open the Asset Director from the 3D world to place it; added to the World Director's assets")
        case .sliceSpriteSheet, .terrainFromPhoto:
            return L10n.t("这个能力尚未接入", "This capability is not built yet")
        }
    }

    /// Analysed records chosen for a World Director run.
    func worldSelection(_ ids: Set<String>, theme: WorldTheme) -> AssetWorldSelection {
        AssetWorldMatcher.select(ids.compactMap { state.records[$0] }, theme: theme)
    }
}

/// The media store, reachable without a view (set by RootView).
@MainActor enum AppModelBridge {
    static weak var store: MediaStore?
}

// MARK: Cloud vision client

/// Optional cloud labels for one small thumbnail (Claude, the user's key).
/// The answer is untrusted: only whitelisted fields survive.
enum ClaudeVisionAnalyzer {
    static var schema: [String: Any] {
        [
            "type": "object", "additionalProperties": false, "required": ["category", "labels", "styles"],
            "properties": [
                "category": ["type": "string", "enum": AssetCategory.allCases.map(\.rawValue) + ["unknown"]],
                "labels": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["name", "score"],
                                                      "properties": ["name": ["type": "string"], "score": ["type": "number"]] as [String: Any]] as [String: Any]],
                "styles": ["type": "array", "items": ["type": "string", "enum": AssetAIOutputValidator.allowedStyles.sorted()]],
            ] as [String: Any],
        ]
    }

    static func analyze(jpeg: Data, apiKey: String) async throws -> AssetAIOutputValidator.Answer {
        let model = ClaudeMotion.models[1]
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
            ["type": "text", "text": "Classify this game asset for a world builder. Pick the main category, up to 10 short English labels with a 0-1 score for what is visible, and art styles. Use \"unknown\" when unsure."],
        ]
        var body: [String: Any] = ["model": model.id, "max_tokens": 800, "messages": [["role": "user", "content": content]],
                                   "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]] as [String: Any]]
        if model.fallbacks { body["fallbacks"] = "default" }
        var request = URLRequest(url: ClaudeMotion.endpoint, timeoutInterval: 40)
        request.httpMethod = "POST"
        for (k, v) in ClaudeMotion.headers(apiKey: apiKey, model: model) { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = try ClaudeMotion.answerText(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        guard let answer = AssetAIOutputValidator.parse(Data(text.utf8)) else { throw ClaudeMotionError.badReply("labels did not match the schema") }
        return answer
    }
}
