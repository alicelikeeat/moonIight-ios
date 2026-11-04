import Foundation

// v1.73: the local rigging pipeline, independent of UI and RealityKit.
// analyse → (optimise) → joints → skeleton → skin → motion tests →
// automatic repair. Runs synchronously with progress and cancellation
// hooks; the coordinator runs it off the main thread. The skeleton is
// returned in the model's own coordinates, so the saved weights and
// joints match the mesh file exactly.

enum RiggingStage: String, Codable, CaseIterable, Sendable {
    case analyze, optimize, joints, skeleton, skin, motionTest, repair, done
    var title: String {
        switch self {
        case .analyze: L10n.t("分析网格", "Analysing mesh"); case .optimize: L10n.t("优化网格", "Optimising mesh")
        case .joints: L10n.t("识别关节", "Finding joints"); case .skeleton: L10n.t("生成骨骼", "Building skeleton")
        case .skin: L10n.t("计算蒙皮权重", "Computing skin weights"); case .motionTest: L10n.t("动作测试", "Motion tests")
        case .repair: L10n.t("自动修正", "Automatic repair"); case .done: L10n.t("完成", "Done")
        }
    }
}

enum RiggingRoute: Equatable, Sendable {
    case local
    /// Local rigging is unlikely to work well; the reasons are shown before
    /// asking the user whether to upload.
    case suggestCloud([String])
}

enum RiggingError: Error, Equatable, LocalizedError {
    case cancelled, emptyMesh, skeleton(String), skin
    var errorDescription: String? {
        switch self {
        case .cancelled: L10n.t("已取消", "Cancelled")
        case .emptyMesh: L10n.t("模型没有可用的三角面", "The model has no usable triangles")
        case .skeleton(let why): L10n.t("骨骼检查未通过：", "Skeleton check failed: ") + why
        case .skin: L10n.t("蒙皮权重不合法", "Skin weights are invalid")
        }
    }
}

extension SkeletonDefinition {
    /// The same skeleton after p ↦ p × scale + offset (model frames).
    func transformed(scale: Float, offset: SIMD3<Float>) -> SkeletonDefinition {
        var s = self
        for i in s.joints.indices {
            var t = s.joints[i].rest.origin * scale
            if s.joints[i].parentID == nil { t += offset }
            s.joints[i].restTransform = RigXform.translation(t).matrix
        }
        s.refreshBindMatrices()
        return s
    }
    /// Height of the skeleton (head top to toes).
    var height: Float {
        let ys = worldRest.map(\.origin.y)
        return max(0.001, (ys.max() ?? 1) - (ys.min() ?? 0))
    }
}

struct RiggingResult: Sendable {
    var analysis: MeshAnalysis
    var estimate: JointEstimate
    var route: RiggingRoute
    /// Mesh the weights belong to (source, or optimised copy).
    var mesh: GeneratedMesh
    var optimized: Bool
    /// Model frame (the mesh's own coordinates).
    var skeleton: SkeletonDefinition
    var skin: SkinInfluences
    var diagnostics: RiggingDiagnostics
    var sockets: [AttachmentSocket]
    var frameScale: Float
    var frameOffset: SIMD3<Float>
    var timings: [String: Double]
}

enum RiggingPipeline {
    /// Whether local rigging is a good idea (spec: cloud only when local
    /// recognition fails, the model is too complex, or the user asks).
    static func route(analysis: MeshAnalysis, estimate: JointEstimate?) -> RiggingRoute {
        var reasons: [String] = []
        if analysis.triangles > MeshAnalyzer.triangleLimit * 3 { reasons.append(L10n.t("模型面数过高", "Very dense model")) }
        if let e = estimate {
            if e.humanoid < 0.6 { reasons.append(L10n.t("没有可靠地识别出人形结构", "No reliable humanoid structure found")) }
            if e.pose == .unknown { reasons.append(L10n.t("姿势不标准", "Non-standard pose")) }
        }
        if analysis.symmetry < 0.6 { reasons.append(L10n.t("左右不对称", "Not left / right symmetric")) }
        return reasons.isEmpty ? .local : .suggestCloud(reasons)
    }

    /// Full local run. `progress(stage, 0…1)`; `cancelled()` is polled.
    static func run(_ source: GeneratedMesh, options: SkinSolverOptions = SkinSolverOptions(), skeletonOverride: SkeletonDefinition? = nil,
                    progress: (RiggingStage, Double) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws -> RiggingResult {
        func check() throws { if cancelled() { throw RiggingError.cancelled } }
        var timings: [String: Double] = [:]
        var clock = Date()
        func lap(_ name: String) { timings[name] = Date().timeIntervalSince(clock); clock = Date() }

        progress(.analyze, 0)
        guard source.triangleCount > 0, source.valid else { throw RiggingError.emptyMesh }
        let analysis = MeshAnalyzer.analyze(source)
        lap("analyze"); try check()

        var mesh = MeshAnalyzer.cleaned(source)
        var optimized = false
        if mesh.triangleCount > MeshAnalyzer.triangleLimit {
            progress(.optimize, 0)
            mesh = MeshAnalyzer.simplified(mesh, targetTriangles: 60_000)
            optimized = true
            lap("optimize"); try check()
        }
        let framed = MeshAnalyzer.rigFrame(mesh)
        let scale = framed.scale, offset = SIMD3(framed.offset[0], framed.offset[1], framed.offset[2])

        progress(.joints, 0)
        let estimate = JointEstimator.estimate(framed.mesh, meanEdge: analysis.meanEdge / max(1e-6, analysis.height))
        lap("joints"); try check()

        progress(.skeleton, 0)
        let skeleton = skeletonOverride.map { $0.transformed(scale: 1 / scale, offset: -offset / scale) } ?? SkeletonBuilder.build(estimate)
        do { try skeleton.validate() } catch { throw RiggingError.skeleton("\(error)") }
        lap("skeleton"); try check()

        progress(.skin, 0)
        var skin: SkinInfluences
        do { skin = try SkinWeightSolver.solve(framed.mesh, skeleton: skeleton, options: options, cancelled: cancelled) } catch { throw RiggingError.cancelled }
        guard skin.valid(jointCount: skeleton.joints.count, vertexCount: framed.mesh.vertexCount) else { throw RiggingError.skin }
        lap("skin"); try check()

        progress(.motionTest, 0)
        let clips = MotionClip.testIDs.compactMap(MotionClip.standard)
        var context = MotionValidator.context(framed.mesh, skeleton: skeleton, skin: skin)
        var results = MotionValidator.run(context, clips: clips)
        lap("motionTest"); try check()

        // Automatic repair: relax weights around the joints that stretch
        // most in failing motions; keep only if the results improve.
        var repairs: [String] = []
        progress(.repair, 0)
        for (index, clip) in clips.enumerated() where results[index].status == .fail && (results[index].metrics["tearShare"] ?? 0) > 0.002 {
            try check()
            let joints = MotionValidator.stretchedJoints(context, clip: clip)
            guard !joints.isEmpty else { continue }
            let candidate = SkinWeightSolver.relaxed(skin, mesh: framed.mesh, skeleton: skeleton, around: joints)
            let trial = MotionValidator.context(framed.mesh, skeleton: skeleton, skin: candidate)
            let retest = MotionValidator.run(trial, clips: clips)
            let before = results.map { $0.metrics["tearShare"] ?? 0 }.reduce(0, +), after = retest.map { $0.metrics["tearShare"] ?? 0 }.reduce(0, +)
            if after < before && retest.map(\.status).max()! <= results.map(\.status).max()! {
                let names = joints.map { skeleton.joints[$0].semanticTag.title }.joined(separator: "、")
                repairs.append(L10n.t("「\(clip.name)」：放松 \(names) 附近的权重，撕裂从 \(MotionValidator.pct(before)) 降到 \(MotionValidator.pct(after))",
                                      "\(clip.name): relaxed weights near \(names); tearing \(MotionValidator.pct(before)) → \(MotionValidator.pct(after))"))
                skin = candidate; context = trial; results = retest
            }
        }
        lap("repair")

        let model = skeleton.transformed(scale: scale, offset: offset)
        var sockets = SkeletonBuilder.sockets(skeleton)
        for i in sockets.indices { sockets[i].offset = sockets[i].offset.map { $0 * scale } }
        progress(.done, 1)
        return RiggingResult(analysis: analysis, estimate: estimate, route: route(analysis: analysis, estimate: estimate), mesh: mesh, optimized: optimized,
                             skeleton: model, skin: skin, diagnostics: RiggingDiagnostics(results: results, repairs: repairs), sockets: sockets,
                             frameScale: scale, frameOffset: offset, timings: timings)
    }

    /// Re-runs the motion tests for a saved / edited rig (model frame).
    static func test(_ mesh: GeneratedMesh, skeleton: SkeletonDefinition, skin: SkinInfluences) -> [DiagnosticResult] {
        let framed = MeshAnalyzer.rigFrame(mesh)
        let offset = SIMD3(framed.offset[0], framed.offset[1], framed.offset[2])
        let local = skeleton.transformed(scale: 1 / framed.scale, offset: -offset / framed.scale)
        return MotionValidator.run(MotionValidator.context(framed.mesh, skeleton: local, skin: skin), clips: MotionClip.testIDs.compactMap(MotionClip.standard))
    }

    /// Skin weights for an edited skeleton (model frame).
    static func reskin(_ mesh: GeneratedMesh, skeleton: SkeletonDefinition, options: SkinSolverOptions = SkinSolverOptions()) throws -> SkinInfluences {
        let framed = MeshAnalyzer.rigFrame(mesh)
        let offset = SIMD3(framed.offset[0], framed.offset[1], framed.offset[2])
        let local = skeleton.transformed(scale: 1 / framed.scale, offset: -offset / framed.scale)
        return try SkinWeightSolver.solve(framed.mesh, skeleton: local, options: options)
    }

    /// Assembles the saved character.
    static func character(_ result: RiggingResult, modelID: String, meshFile: String, optimizedMeshFile: String?, skinFile: String,
                          route: String = "local", engine: String = "Moonlight Local Rig") -> RiggedCharacter {
        RiggedCharacter(modelID: modelID, meshFile: optimizedMeshFile ?? meshFile, optimizedMeshFile: optimizedMeshFile, skinFile: skinFile,
                        vertexCount: result.mesh.vertexCount, skeleton: result.skeleton, clips: MotionClip.library, sockets: result.sockets,
                        diagnostics: result.diagnostics,
                        metadata: RiggedCharacterMetadata(engine: engine, engineVersion: "1.73.0", route: route, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                                                          poseType: result.estimate.pose.rawValue, notes: result.estimate.notes))
    }
}

extension MotionClip {
    /// Pose in a frame where the body is `height` tall (root channels are
    /// stored in body heights).
    func pose(_ skeleton: SkeletonDefinition, at t: Float, height: Float) -> SkeletonPose {
        var p = pose(skeleton, at: t)
        p.rootOffset *= height
        return p
    }
}
