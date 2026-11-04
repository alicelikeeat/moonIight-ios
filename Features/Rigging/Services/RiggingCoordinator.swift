import Foundation
import UIKit

// v1.73: runs rigging jobs for the workbench. Heavy work runs off the main
// thread with progress, cancel and retry; overheating, memory warnings and
// leaving the app stop the job and keep a checkpoint (the skeleton) so the
// next run resumes. Cloud rigging only starts after the user confirms the
// upload in the UI, uses the user's own service and token, and its result
// goes through the same local checks. Saving never touches the source mesh.

/// Thread-safe cancel flag polled by the pipeline.
final class RigCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

@available(iOS 18.0, *)
@MainActor final class RiggingCoordinator: ObservableObject {
    let manifest: Generated3DManifest
    let assets = RiggingAssetStore(folder: Generated3DStore.folder("Rigs"))

    /// Mesh the rig belongs to (source, or the optimised copy).
    @Published private(set) var mesh: GeneratedMesh?
    @Published private(set) var textureURL: URL?
    @Published private(set) var analysis: MeshAnalysis?
    @Published private(set) var estimate: JointEstimate?
    @Published private(set) var route: RiggingRoute?
    @Published private(set) var skeleton: SkeletonDefinition?
    @Published private(set) var skin: SkinInfluences?
    @Published private(set) var diagnostics: RiggingDiagnostics?
    @Published private(set) var sockets: [AttachmentSocket] = []
    @Published private(set) var optimized = false
    @Published private(set) var engineRoute = "local"
    @Published private(set) var timings: [String: Double] = [:]

    @Published private(set) var stage: RiggingStage?
    @Published private(set) var progress = 0.0
    @Published private(set) var running = false
    @Published var message: String?
    /// Edits since the last save.
    @Published private(set) var dirty = false
    @Published private(set) var savedOnce = false
    /// The skeleton changed; weights need recomputing.
    @Published private(set) var needsReskin = false
    @Published var options = SkinSolverOptions()
    @Published var selectedJoint: Int?
    @Published private(set) var undoDepth = 0
    @Published private(set) var cloudJob: CloudRigJob?

    private var history: [(SkeletonDefinition, SkinInfluences)] = []
    private var task: Task<Void, Never>?
    private let flag = RigCancelFlag()
    private var observers: [NSObjectProtocol] = []

    init(manifest: Generated3DManifest) {
        self.manifest = manifest
    }

    /// Watches temperature and memory while the workbench is open.
    func startWatching() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let state = ProcessInfo.processInfo.thermalState
                if state == .serious || state == .critical { self?.suspend(L10n.t("设备温度过高，已暂停绑定并保存进度", "The device is hot; rigging paused and progress kept")) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(L10n.t("内存不足，已暂停绑定并保存进度", "Low memory; rigging paused and progress kept")) }
        })
    }
    func stopWatching() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    var hasRig: Bool { skeleton != nil && skin != nil }

    // MARK: Loading

    func load(store: Generated3DStore) async {
        guard mesh == nil else { return }
        guard let meshURL = store.meshURL(manifest) else {
            message = L10n.t("这个模型没有可绑定的网格（多视角重建的 USDZ 模型暂不支持）", "This model has no mesh to rig (reconstructed USDZ models are not supported yet)")
            return
        }
        textureURL = store.textureURL(manifest)
        let assets = assets, id = manifest.id
        let loaded = await Task.detached(priority: .userInitiated) { () -> (GeneratedMesh?, MeshAnalysis?, (RiggedCharacter, SkinInfluences)?, GeneratedMesh?, String?) in
            guard let data = try? Data(contentsOf: meshURL), let source = GeneratedMeshCodec.decode(data) else { return (nil, nil, nil, nil, nil) }
            let analysis = MeshAnalyzer.analyze(source)
            do {
                guard let saved = try assets.load(id) else { return (source, analysis, nil, nil, nil) }
                var rigMesh: GeneratedMesh?
                if saved.0.optimizedMeshFile != nil { rigMesh = (try? Data(contentsOf: assets.optimizedMeshURL(id))).flatMap(GeneratedMeshCodec.decode) }
                return (source, analysis, saved, rigMesh, nil)
            } catch RiggedCharacter.LoadError.newerFormat(let v) {
                return (source, analysis, nil, nil, L10n.t("这个角色由更新版本的应用保存（格式 \(v)），本版本不会读取或覆盖它", "This character was saved by a newer app (format \(v)); this version will not read or overwrite it"))
            } catch {
                return (source, analysis, nil, nil, L10n.t("已保存的骨骼无法读取，可以重新绑定", "The saved rig could not be read; you can rig again"))
            }
        }.value
        guard let source = loaded.0 else { message = L10n.t("模型文件无法读取", "The model file could not be read"); return }
        analysis = loaded.1
        message = loaded.4
        if let (character, skin) = loaded.2 {
            let rigMesh = loaded.3 ?? source
            guard rigMesh.vertexCount == character.vertexCount else { mesh = source; return }
            mesh = rigMesh
            skeleton = character.skeleton; self.skin = skin; diagnostics = character.diagnostics; sockets = character.sockets
            optimized = character.optimizedMeshFile != nil; engineRoute = character.metadata.route; savedOnce = true
        } else {
            mesh = source
            if let analysis = loaded.1 { route = RiggingPipeline.route(analysis: analysis, estimate: nil) }
        }
    }

    // MARK: Local job

    func autoRig(source: Generated3DStore) {
        guard !running else { return }
        guard let meshURL = source.meshURL(manifest) else { return }
        let resume = assets.checkpoint(manifest.id)?.skeleton
        start { [options] flag, report in
            guard let data = try? Data(contentsOf: meshURL), let original = GeneratedMeshCodec.decode(data) else { throw RiggingError.emptyMesh }
            return try RiggingPipeline.run(original, options: options, skeletonOverride: resume, progress: report, cancelled: { flag.isSet })
        } done: { [weak self] result in
            guard let self else { return }
            self.apply(result, route: "local")
            if resume != nil { self.message = L10n.t("已从上次中断的位置继续", "Resumed from where it stopped") }
        }
    }

    /// Weights again for the edited skeleton, then the motion tests.
    func reskin() {
        guard let mesh, let skeleton, !running else { return }
        pushHistory()
        start { [options] _, report in
            report(.skin, 0)
            let skin = try RiggingPipeline.reskin(mesh, skeleton: skeleton, options: options)
            report(.motionTest, 0)
            return (skin, RiggingPipeline.test(mesh, skeleton: skeleton, skin: skin))
        } done: { [weak self] (value: (SkinInfluences, [DiagnosticResult])) in
            guard let self else { return }
            self.skin = value.0; self.diagnostics = RiggingDiagnostics(results: value.1); self.needsReskin = false; self.dirty = true
        }
    }

    func retest() {
        guard let mesh, let skeleton, let skin, !running else { return }
        start { _, report in report(.motionTest, 0); return RiggingPipeline.test(mesh, skeleton: skeleton, skin: skin) }
        done: { [weak self] (results: [DiagnosticResult]) in self?.diagnostics?.results = results }
    }

    func cancel() { flag.set(true) }

    /// Stops a running job (heat, memory, leaving the app) and keeps the
    /// skeleton as a checkpoint.
    func suspend(_ reason: String) {
        guard running else { return }
        flag.set(true)
        if let skeleton { assets.saveCheckpoint(.init(modelID: manifest.id, stage: stage?.rawValue ?? "", skeleton: skeleton, savedAt: Date())) }
        message = reason
    }

    private func start<T: Sendable>(_ work: @escaping @Sendable (RigCancelFlag, (RiggingStage, Double) -> Void) throws -> T, done: @escaping @MainActor @Sendable (T) -> Void) {
        flag.set(false)
        running = true; progress = 0; stage = .analyze; message = nil
        let flag = flag
        let report: @Sendable (RiggingStage, Double) -> Void = { stage, value in
            Task { @MainActor in self.stage = stage; self.progress = value }
        }
        task = Task {
            let outcome: Result<T, Error> = await Task.detached(priority: .userInitiated) { Result { try work(flag, report) } }.value
            self.running = false; self.stage = nil
            switch outcome {
            case .success(let value): done(value)
            case .failure(let error):
                if (error as? RiggingError) == .cancelled || flag.isSet {
                    if self.message == nil { self.message = L10n.t("已取消，可以重试", "Cancelled; you can retry") }
                } else {
                    self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func apply(_ result: RiggingResult, route: String) {
        mesh = result.mesh; analysis = result.analysis; estimate = result.estimate; self.route = result.route
        skeleton = result.skeleton; skin = result.skin; diagnostics = result.diagnostics; sockets = result.sockets
        optimized = result.optimized; engineRoute = route; timings = result.timings
        history = []; undoDepth = 0; dirty = true; needsReskin = false
        selectedJoint = nil; editedJoints = []
    }

    // MARK: Editing

    private func pushHistory() {
        guard let skeleton, let skin else { return }
        history.append((skeleton, skin))
        if history.count > 12 { history.removeFirst() }
        undoDepth = history.count
    }
    func undo() {
        guard let last = history.popLast() else { return }
        skeleton = last.0; skin = last.1; undoDepth = history.count; dirty = true; needsReskin = false
        retest()
    }

    /// Joints the user placed by hand (kept by AI assist).
    @Published private(set) var editedJoints: Set<JointTag> = []
    /// Edits also move the mirrored joint.
    @Published var symmetric = true
    private var dragStart: SkeletonDefinition?

    /// Moves a joint (model units); weights are recomputed on request.
    func nudge(_ joint: Int, by delta: SIMD3<Float>) {
        guard let s = skeleton, s.joints.indices.contains(joint) else { return }
        if !needsReskin { pushHistory() }
        skeleton = place(s, joint: joint, at: s.worldRest[joint].origin + delta, from: s)
        needsReskin = true; dirty = true
    }

    /// Dragging on the preview: `delta` is from where the drag began.
    func drag(_ joint: Int, by delta: SIMD3<Float>) {
        guard let s = skeleton, s.joints.indices.contains(joint) else { return }
        if dragStart == nil { dragStart = s; if !needsReskin { pushHistory() } }
        let start = dragStart!
        skeleton = place(start, joint: joint, at: start.worldRest[joint].origin + delta, from: start)
        needsReskin = true; dirty = true
    }
    func endDrag() { dragStart = nil }

    private func place(_ s: SkeletonDefinition, joint: Int, at position: SIMD3<Float>, from reference: SkeletonDefinition) -> SkeletonDefinition {
        let tag = s.joints[joint].semanticTag
        editedJoints.insert(tag)
        var out = SkeletonBuilder.moving(s, joint: joint, to: position)
        if symmetric, let m = tag.mirror, let mi = out.index(m), let centre = reference.position(.pelvis)?.x {
            out = SkeletonBuilder.moving(out, joint: mi, to: SIMD3(2 * centre - position.x, position.y, position.z))
            editedJoints.insert(m)
        }
        return out
    }

    /// AI assist: re-finds the joints the user did not place from the
    /// mesh, fits limb joints between placed ones, mirrors placed joints.
    func assist() {
        guard let mesh, let skeleton, !running else { return }
        pushHistory()
        let locked = editedJoints, mirror = symmetric
        start { _, report in
            report(.joints, 0)
            let framed = MeshAnalyzer.rigFrame(mesh)
            let a = MeshAnalyzer.analyze(mesh)
            let estimate = JointEstimator.estimate(framed.mesh, meanEdge: a.meanEdge / max(1e-6, a.height))
            let offset = SIMD3(framed.offset[0], framed.offset[1], framed.offset[2])
            let automatic = estimate.positions.mapValues { $0 * framed.scale + offset }
            return SkeletonBuilder.assisted(skeleton, automatic: automatic, locked: locked, mirror: mirror)
        } done: { [weak self] (result: SkeletonDefinition) in
            guard let self else { return }
            self.skeleton = result; self.needsReskin = true; self.dirty = true
            self.message = L10n.t("AI 已按你放好的 \(locked.count) 个关节重新推算其余关节，请检查后重算权重", "AI re-fitted the other joints around the \(locked.count) you placed; check them, then recompute the weights")
        }
    }

    /// Reach of one joint's weights (×factor), then recompute.
    func scaleInfluence(_ joint: Int, by factor: Float) {
        guard let s = skeleton else { return }
        let id = s.joints[joint].jointID
        options.influenceScale[id] = max(0.3, min(3, (options.influenceScale[id] ?? 1) * factor))
        reskin()
    }

    /// Extra smoothing around one joint (local repair).
    func smooth(around joint: Int) {
        guard let mesh, let skeleton, let skin, !running else { return }
        pushHistory()
        start { _, report in
            report(.repair, 0)
            let framed = MeshAnalyzer.rigFrame(mesh)
            let offset = SIMD3(framed.offset[0], framed.offset[1], framed.offset[2])
            let local = skeleton.transformed(scale: 1 / framed.scale, offset: -offset / framed.scale)
            let relaxed = SkinWeightSolver.relaxed(skin, mesh: framed.mesh, skeleton: local, around: [joint])
            return (relaxed, RiggingPipeline.test(mesh, skeleton: skeleton, skin: relaxed))
        } done: { [weak self] (value: (SkinInfluences, [DiagnosticResult])) in
            self?.skin = value.0; self?.diagnostics?.results = value.1; self?.dirty = true
        }
    }

    // MARK: Saving

    func save(store: Generated3DStore) {
        guard let mesh, let skeleton, let skin, let diagnostics else { return }
        guard !needsReskin else { message = L10n.t("关节已改动，请先重算权重", "Joints changed; recompute the weights first"); return }
        let id = manifest.id
        let result = RiggingResult(analysis: analysis ?? MeshAnalyzer.analyze(mesh), estimate: estimate ?? JointEstimate(positions: [:], confidence: [:], pose: .unknown, humanoid: 0, notes: []),
                                   route: route ?? .local, mesh: mesh, optimized: optimized, skeleton: skeleton, skin: skin, diagnostics: diagnostics,
                                   sockets: sockets.isEmpty ? [] : sockets, frameScale: 1, frameOffset: .zero, timings: timings)
        let character = RiggingPipeline.character(result, modelID: id, meshFile: manifest.meshFile ?? "", optimizedMeshFile: optimized ? id + ".opt.mesh" : nil,
                                                  skinFile: id + ".skin", route: engineRoute, engine: engineRoute == "cloud" ? "Cloud rig service" : "Moonlight Local Rig")
        do {
            try assets.save(character, skin: skin, optimizedMesh: optimized ? mesh : nil)
            var updated = store.models.first { $0.id == id } ?? manifest
            updated.humanoidDetected = true
            if !updated.notes.contains(where: { $0.hasPrefix("v1.73") }) {
                updated.notes.append(L10n.t("v1.73 自动骨骼：\(skeleton.joints.count) 个关节、每顶点最多 4 个权重，8 项动作测试结果见骨骼工作台。尚未经过人工真机验收。",
                                            "v1.73 auto rig: \(skeleton.joints.count) joints, up to 4 weights per vertex; the 8 motion test results are in the rig workbench. Not yet accepted on a device by a person."))
            }
            try store.save(updated)
            dirty = false; savedOnce = true
            message = L10n.t("已保存。放进 3D 世界后会用这套骨骼做动作。", "Saved. Placed in the 3D world, it moves with this rig.")
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? L10n.t("保存失败：", "Saving failed: ") + error.localizedDescription
        }
    }

    func deleteRig() {
        assets.delete(manifest.id)
        skeleton = nil; skin = nil; diagnostics = nil; sockets = []; savedOnce = false; dirty = false
        message = L10n.t("已删除这套骨骼，原模型不受影响", "Rig deleted; the model itself is unchanged")
    }

    func rollback() {
        do {
            if try assets.rollback(manifest.id), let (c, s) = try assets.load(manifest.id) {
                skeleton = c.skeleton; skin = s; diagnostics = c.diagnostics; sockets = c.sockets; dirty = false
                message = L10n.t("已恢复上一次保存的版本", "Restored the previous save")
            } else { message = L10n.t("没有可以恢复的上一版本", "No previous version to restore") }
        } catch { message = error.localizedDescription }
    }

    // MARK: Cloud (after the user confirmed the upload)

    static let cloudURLKey = "rig.cloud.url"
    static let cloudTokenAccount = "rig-cloud-token"
    static var cloudConfig: CloudRigConfig? {
        CloudRigConfig.parse(UserDefaults.standard.string(forKey: cloudURLKey) ?? "", token: SecureSettings.read(cloudTokenAccount) ?? "")
    }

    func cloudRig(store: Generated3DStore) {
        guard !running else { return }
        guard let config = Self.cloudConfig else { message = CloudRigError.notConfigured.errorDescription; return }
        guard let meshURL = store.meshURL(manifest) else { return }
        let textureURL = store.textureURL(manifest)
        flag.set(false)
        running = true; stage = .analyze; progress = 0; message = nil
        let flag = flag
        task = Task { [weak self] in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { () throws -> (Data, GeneratedMesh) in
                    guard let data = try? Data(contentsOf: meshURL), let source = GeneratedMeshCodec.decode(data) else { throw RiggingError.emptyMesh }
                    var mesh = MeshAnalyzer.cleaned(source)
                    if mesh.triangleCount > MeshAnalyzer.triangleLimit { mesh = MeshAnalyzer.simplified(mesh, targetTriangles: 100_000) }
                    let texture = textureURL.flatMap { try? Data(contentsOf: $0) }
                    let mime = textureURL?.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                    let glb = GLBCodec.write(mesh, texture: texture, textureMime: mime)
                    guard glb.count <= CloudRiggingProtocol.maxUploadBytes else { throw CloudRigError.tooLarge }
                    return (glb, mesh)
                }.value
                let (glb, mesh) = prepared
                let created = try await CloudRiggingService.send(CloudRiggingProtocol.create(config, glb: glb))
                var job = try CloudRiggingProtocol.job(created)
                self?.cloudJob = job; self?.stage = .skeleton
                let started = Date()
                var attempt = 0
                while !job.finished {
                    if flag.isSet {
                        _ = try? await CloudRiggingService.send(CloudRiggingProtocol.cancel(config, id: job.id))
                        throw RiggingError.cancelled
                    }
                    if Date().timeIntervalSince(started) > CloudRiggingProtocol.timeout { throw CloudRigError.timedOut }
                    try await Task.sleep(nanoseconds: UInt64(CloudRiggingProtocol.pollDelay(attempt: attempt) * 1e9))
                    attempt += 1
                    job = try CloudRiggingProtocol.job(try await CloudRiggingService.send(CloudRiggingProtocol.status(config, id: job.id)))
                    self?.cloudJob = job; self?.progress = job.progress ?? 0
                }
                guard job.status == .succeeded else { throw CloudRigError.rejected(job.message ?? job.status.rawValue) }
                let body = try await CloudRiggingService.send(CloudRiggingProtocol.result(config, id: job.id))
                self?.stage = .motionTest
                let checked = try await Task.detached(priority: .userInitiated) { () throws -> (SkeletonDefinition, SkinInfluences, [DiagnosticResult], [String]) in
                    let r = try CloudRiggingProtocol.decodeResult(body, vertexCount: mesh.vertexCount)
                    return (r.skeleton, r.skin, RiggingPipeline.test(mesh, skeleton: r.skeleton, skin: r.skin), r.notes)
                }.value
                guard let self else { return }
                self.mesh = mesh; self.skeleton = checked.0; self.skin = checked.1
                self.diagnostics = RiggingDiagnostics(results: checked.2, repairs: checked.3)
                self.sockets = SkeletonBuilder.sockets(checked.0); self.optimized = true; self.engineRoute = "cloud"
                self.dirty = true; self.history = []; self.undoDepth = 0
                self.message = L10n.t("云端结果已下载并通过本地格式检查，请查看动作测试后再保存", "The cloud result was downloaded and passed the local format check; review the motion tests before saving")
            } catch {
                self?.message = (error as? RiggingError) == .cancelled ? L10n.t("已取消云端任务", "Cloud job cancelled")
                    : ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.running = false; self?.stage = nil
        }
    }

    /// Deletes the job and its uploaded files on the service.
    func deleteCloudJob() {
        guard let config = Self.cloudConfig, let job = cloudJob else { return }
        Task { [weak self] in
            do {
                _ = try await CloudRiggingService.send(CloudRiggingProtocol.delete(config, id: job.id))
                self?.cloudJob = nil
                self?.message = L10n.t("已请求云端删除这个任务和上传的模型", "Asked the service to delete the job and the uploaded model")
            } catch { self?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
}

/// URLSession transport for the cloud protocol.
enum CloudRiggingService {
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudRiggingProtocol.check(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        return data
    }
}
