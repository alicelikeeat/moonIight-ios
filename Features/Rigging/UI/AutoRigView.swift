import SwiftUI
import RealityKit

// v1.73 M01: the auto-rig workbench inside the 3D model editor. Four
// pages share one preview and one coordinator, so switching pages keeps
// the model and all edits. The main action is one "Auto Rig" button;
// everything else sits in Advanced. Joint editing uses buttons and
// sliders (never drags on the preview), so turning the view always works.

@available(iOS 18.0, *)
struct AutoRigView: View {
    enum Page: String, CaseIterable, Identifiable {
        case analyze, skeleton, skin, motion
        var id: Self { self }
        var title: String {
            switch self {
            case .analyze: L10n.t("模型分析", "Analysis"); case .skeleton: L10n.t("骨骼生成", "Skeleton")
            case .skin: L10n.t("蒙皮修正", "Skinning"); case .motion: L10n.t("动作测试", "Motion Test")
            }
        }
    }

    @ObservedObject var store: Generated3DStore
    @StateObject private var rig: RiggingCoordinator
    @StateObject private var scene = RigPreviewScene()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = Page.analyze
    @State private var dragStart: (Float, Float)?
    @State private var zoomStart: Float?
    @State private var advanced = false
    @State private var confirmCloud = false
    @State private var confirmDelete = false
    @State private var cloudURL = UserDefaults.standard.string(forKey: RiggingCoordinator.cloudURLKey) ?? ""
    @State private var cloudToken = ""
    @State private var heatYaw: Float = 0.3
    @State private var heatmap: UIImage?
    @State private var rotation: SIMD3<Float> = .zero
    @State private var dragJoints = false

    init(manifest: Generated3DManifest, store: Generated3DStore) {
        self.store = store
        _rig = StateObject(wrappedValue: RiggingCoordinator(manifest: manifest))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                preview
                Picker("", selection: $page) { ForEach(Page.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                    .accessibilityIdentifier("autorig-pages")
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let message = rig.message { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                        switch page {
                        case .analyze: analyzePage
                        case .skeleton: skeletonPage
                        case .skin: skinPage
                        case .motion: motionPage
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 24)
                }
            }
            .navigationTitle(L10n.t("自动骨骼", "Auto Rig")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("完成", "Done")) { rig.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存", "Save")) { rig.save(store: store) }.disabled(!rig.hasRig || !rig.dirty || rig.running)
                        .accessibilityIdentifier("autorig-save")
                }
            }
            .overlay(alignment: .bottom) { if rig.running { jobCard } }
        }
        .task { await rig.load(store: store); await refreshScene() }
        .onAppear { rig.startWatching() }
        .onDisappear { rig.stopWatching(); rig.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { rig.suspend(L10n.t("已离开应用，绑定已暂停并保存进度", "You left the app; rigging paused and progress kept")) }
        }
        .onChange(of: rig.skeleton) { _, now in
            if rig.needsReskin, let now { scene.showEdited(now) } else { scene.setRig(rig.skeleton, skin: rig.skin) }
        }
        .onChange(of: rig.skin) { _, _ in scene.setRig(rig.skeleton, skin: rig.skin); renderHeatmap() }
        .onChange(of: page) { _, now in if now == .skin { renderHeatmap() } }
        .onChange(of: rig.selectedJoint) { _, joint in scene.select(joint); rotation = joint.map { scene.rotation($0) } ?? .zero; renderHeatmap() }
        .confirmationDialog(L10n.t("上传到云端绑定？", "Upload for cloud rigging?"), isPresented: $confirmCloud, titleVisibility: .visible) {
            Button(L10n.t("上传并绑定", "Upload and Rig")) { saveCloudSettings(); rig.cloudRig(store: store) }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("将把这个模型的网格和贴图（GLB）上传到你填写的服务：\(cloudURL)。结果下载后会在本机检查。上传后可以在这里请求删除云端文件。", "The model's mesh and texture (GLB) are uploaded to the service you entered: \(cloudURL). The result is checked on this iPhone. You can ask the service to delete the files here afterwards."))
        }
        .confirmationDialog(L10n.t("删除这套骨骼？", "Delete this rig?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L10n.t("删除骨骼", "Delete Rig"), role: .destructive) { rig.deleteRig(); scene.setRig(nil, skin: nil) }
        }
        .accessibilityIdentifier("autorig-screen")
    }

    private func refreshScene() async {
        if let mesh = rig.mesh { await scene.setModel(mesh, textureURL: rig.textureURL) }
        scene.setRig(rig.skeleton, skin: rig.skin)
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        if scenePhase == .active {
            RealityView { content in
                content.camera = .virtual
                content.add(scene.root)
                let scene = scene
                scene.updates = content.subscribe(to: SceneEvents.Update.self) { event in
                    MainActor.assumeIsolated { scene.tick(Float(event.deltaTime)) }
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .overlay(alignment: .topTrailing) {
                Toggle(L10n.t("骨骼透视", "X-ray"), isOn: $scene.showSkeleton).toggleStyle(.button).font(.caption).padding(22)
            }
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                // Joint drag only in the explicit edit mode; otherwise the
                // preview always turns.
                if dragJoints, page == .skeleton, let joint = rig.selectedJoint {
                    let axes = scene.screenAxes, k = scene.unitsPerPoint
                    rig.drag(joint, by: axes.right * Float(value.translation.width) * k - axes.up * Float(value.translation.height) * k)
                    return
                }
                let start = dragStart ?? (scene.yaw, scene.pitch)
                dragStart = start
                scene.yaw = start.0 + Float(value.translation.width) * 0.01
                scene.pitch = max(-1.4, min(1.4, start.1 + Float(value.translation.height) * 0.01))
            }.onEnded { _ in dragStart = nil; rig.endDrag() })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                let start = zoomStart ?? scene.distance
                zoomStart = start
                scene.distance = max(0.6, min(6, start / Float(value.magnification)))
            }.onEnded { _ in zoomStart = nil })
            .onChange(of: rig.mesh) { _, _ in Task { await refreshScene() } }
            .accessibilityLabel(L10n.t("骨骼预览：拖动旋转，双指缩放", "Rig preview: drag to turn, pinch to zoom"))
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black).frame(height: 300).padding(.horizontal, 16)
        }
    }

    private var jobCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                Text(rig.stage?.title ?? L10n.t("处理中", "Working")).font(.subheadline.weight(.semibold))
                Spacer()
                Button(L10n.t("取消", "Cancel")) { rig.cancel() }.buttonStyle(.bordered).accessibilityIdentifier("autorig-cancel")
            }
            if let job = rig.cloudJob { Text(L10n.t("云端任务 \(job.id)：\(job.status.rawValue)", "Cloud job \(job.id): \(job.status.rawValue)")).font(.caption2).foregroundStyle(.secondary) }
            ProgressView(value: stageFraction).progressViewStyle(.linear)
        }
        .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).padding(16)
    }
    private var stageFraction: Double {
        guard let stage = rig.stage, let i = RiggingStage.allCases.firstIndex(of: stage) else { return 0 }
        return (Double(i) + rig.progress) / Double(RiggingStage.allCases.count)
    }

    // MARK: Page 1: analysis

    @ViewBuilder private var analyzePage: some View {
        Button { rig.autoRig(source: store) } label: {
            Label(rig.hasRig ? L10n.t("重新自动绑定", "Auto Rig Again") : L10n.t("自动绑定", "Auto Rig"), systemImage: "figure.arms.open")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent).disabled(rig.running || rig.mesh == nil).accessibilityIdentifier("autorig-run")
        Text(L10n.t("在本机识别身体结构、生成 27 个关节、计算蒙皮权重，并用 8 个动作实际变形检查。断网也能完成。", "Finds the body on this iPhone, builds 27 joints, computes skin weights and really deforms the model through 8 test motions. Works offline."))
            .font(.caption).foregroundStyle(.secondary)
        if let analysis = rig.analysis { analysisCard(analysis) }
        if let estimate = rig.estimate {
            card {
                row(L10n.t("姿势", "Pose"), estimate.pose.title)
                row(L10n.t("人形置信度", "Humanoid confidence"), String(format: "%.0f%%", estimate.humanoid * 100))
                ForEach(estimate.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
            }
        }
        if case .suggestCloud(let reasons)? = rig.route {
            card {
                Label(L10n.t("本地绑定可能效果不好", "Local rigging may not work well"), systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                ForEach(reasons, id: \.self) { Text("· " + $0).font(.caption) }
                Text(L10n.t("仍然可以在本机绑定；也可以在高级设置里使用你自己的云端服务（需要你确认后才会上传）。", "You can still rig on this iPhone, or use your own cloud service in Advanced (nothing is uploaded until you confirm)."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        DisclosureGroup(L10n.t("高级设置", "Advanced"), isExpanded: $advanced) { advancedSettings }.font(.subheadline)
    }

    private func analysisCard(_ a: MeshAnalysis) -> some View {
        card {
            Text(L10n.t("网格诊断", "Mesh check")).font(.subheadline.weight(.semibold))
            row(L10n.t("顶点 / 三角面", "Vertices / triangles"), "\(a.vertices) / \(a.triangles)")
            row(L10n.t("独立部分", "Separate pieces"), "\(a.components)")
            row(L10n.t("左右对称", "Symmetry"), String(format: "%.0f%%", a.symmetry * 100))
            row(L10n.t("封闭网格", "Closed mesh"), a.watertight ? L10n.t("是", "Yes") : L10n.t("否（\(a.boundaryEdges) 条开放边）", "No (\(a.boundaryEdges) open edges)"))
            if a.triangles > MeshAnalyzer.triangleLimit {
                Text(L10n.t("面数超过 150,000，绑定时会使用优化后的副本（原模型不变）。", "Over 150,000 triangles: rigging uses an optimised copy (the original stays as is)."))
                    .font(.caption2).foregroundStyle(.orange)
            }
            ForEach(a.issues, id: \.self) { Text("· " + $0).font(.caption2).foregroundStyle(.secondary) }
            Text(L10n.t("头发、衣服、武器与身体连在一起时无法分开；单独的小部件会按刚体跟随最近的关节。", "Hair, clothes and weapons fused with the body cannot be separated; small separate pieces follow the nearest joint rigidly."))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(L10n.t("关节过渡宽度", "Joint blend width")).font(.caption); Slider(value: $rig.options.falloff, in: 0.015...0.06) }
            Stepper(L10n.t("平滑次数 \(rig.options.smoothingPasses)", "Smoothing passes \(rig.options.smoothingPasses)"), value: $rig.options.smoothingPasses, in: 0...6).font(.caption)
            Toggle(L10n.t("小部件按刚体绑定", "Small pieces follow rigidly"), isOn: $rig.options.rigidAccessories).font(.caption)
            Divider()
            Text(L10n.t("云端增强（可选）", "Cloud (optional)")).font(.caption.weight(.semibold))
            Text(L10n.t("需要你自己部署或订阅的绑定服务（例如基于 UniRig）。应用不内置任何服务地址或密钥。", "Needs a rigging service you run or subscribe to (e.g. based on UniRig). The app has no built-in service address or key."))
                .font(.caption2).foregroundStyle(.secondary)
            TextField("https://…", text: $cloudURL).textFieldStyle(.roundedBorder).font(.caption).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField(L10n.t("访问令牌（存于钥匙串）", "Access token (kept in the keychain)"), text: $cloudToken).textFieldStyle(.roundedBorder).font(.caption)
            HStack {
                Button(L10n.t("云端绑定…", "Cloud Rig…")) { confirmCloud = true }
                    .disabled(CloudRigConfig.parse(cloudURL, token: cloudToken) == nil || rig.running)
                if rig.cloudJob != nil { Button(L10n.t("删除云端文件", "Delete Cloud Files"), role: .destructive) { rig.deleteCloudJob() } }
            }.font(.caption).buttonStyle(.bordered)
            Divider()
            HStack {
                Button(L10n.t("恢复上次保存", "Restore Previous Save")) { rig.rollback() }
                Button(L10n.t("删除骨骼", "Delete Rig"), role: .destructive) { confirmDelete = true }.disabled(!rig.savedOnce)
            }.font(.caption).buttonStyle(.bordered)
        }
        .padding(.top, 6)
    }

    private func saveCloudSettings() {
        UserDefaults.standard.set(cloudURL, forKey: RiggingCoordinator.cloudURLKey)
        if !cloudToken.isEmpty { SecureSettings.write(cloudToken, account: RiggingCoordinator.cloudTokenAccount) }
    }

    // MARK: Page 2: skeleton

    @ViewBuilder private var skeletonPage: some View {
        if let skeleton = rig.skeleton {
            Text(L10n.t("点关节选中；长按关节可打开菜单。绿色=可信，黄色=一般，红色=请检查。", "Tap a joint to select it; long-press for its menu. Green = confident, yellow = fair, red = please check."))
                .font(.caption).foregroundStyle(.secondary)
            card {
                Toggle(isOn: $dragJoints) { Label(L10n.t("在预览上拖动选中的关节", "Drag the selected joint on the preview"), systemImage: "hand.draw") }.font(.caption)
                Text(dragJoints ? L10n.t("拖动预览会移动关节（沿屏幕方向）；关掉后拖动恢复为旋转视角。", "Dragging the preview moves the joint (in the screen plane); turn this off to rotate the view again.")
                     : L10n.t("拖动预览只会旋转视角。", "Dragging the preview only turns the view."))
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle(isOn: $rig.symmetric) { Label(L10n.t("左右对称编辑", "Mirror edits left / right"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.font(.caption)
                Button { rig.assist() } label: {
                    Label(L10n.t("AI 协助：保留我放好的关节，重新推算其余关节", "AI assist: keep my joints, re-fit the others"), systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).font(.caption).disabled(rig.running)
                if !rig.editedJoints.isEmpty {
                    Text(L10n.t("已手动放置：", "Placed by hand: ") + rig.editedJoints.map(\.title).sorted().joined(separator: "、")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ForEach(0..<4, id: \.self) { region in jointGroup(skeleton, region: region) }
            if let j = rig.selectedJoint, skeleton.joints.indices.contains(j) { jointEditor(skeleton, j) }
            if rig.needsReskin {
                Button { rig.reskin() } label: { Label(L10n.t("关节已改动：重算权重", "Joints changed: Recompute Weights"), systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent).disabled(rig.running)
            }
        } else {
            emptyRig
        }
    }

    private static let regionTitles = [L10n.t("头颈", "Head"), L10n.t("躯干", "Torso"), L10n.t("手臂", "Arms"), L10n.t("腿脚", "Legs")]

    private func jointGroup(_ skeleton: SkeletonDefinition, region: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.regionTitles[region]).font(.caption.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(skeleton.joints.indices.filter { skeleton.joints[$0].semanticTag.region == region }, id: \.self) { i in
                        jointChip(skeleton, i)
                    }
                }
            }
        }
    }

    private func jointChip(_ skeleton: SkeletonDefinition, _ i: Int) -> some View {
        let joint = skeleton.joints[i]
        let color: Color = joint.confidence >= 0.8 ? .green : joint.confidence >= 0.5 ? .yellow : .red
        let selected = rig.selectedJoint == i
        return Button { rig.selectedJoint = selected ? nil : i } label: {
            HStack(spacing: 4) { Circle().fill(color).frame(width: 7, height: 7); Text(joint.semanticTag.title).font(.caption) }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { rig.selectedJoint = i; page = .skeleton } label: { Label(L10n.t("移动 / 旋转", "Move / Rotate"), systemImage: "move.3d") }
            Button { rig.selectedJoint = i; page = .skin } label: { Label(L10n.t("查看权重", "Show Weights"), systemImage: "paintbrush") }
            Button { scene.rotate(i, to: .zero); rotation = .zero } label: { Label(L10n.t("重置旋转", "Reset Rotation"), systemImage: "arrow.uturn.backward") }
        }
        .accessibilityLabel(joint.semanticTag.title)
    }

    private func jointEditor(_ skeleton: SkeletonDefinition, _ j: Int) -> some View {
        let joint = skeleton.joints[j]
        let step = skeleton.height * 0.01
        return card {
            HStack {
                Text(joint.semanticTag.title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(L10n.t("置信度 \(Int(joint.confidence * 100))%", "Confidence \(Int(joint.confidence * 100))%")).font(.caption2).foregroundStyle(.secondary)
            }
            Text(L10n.t("调整位置（每次 1% 身高）", "Move (1% of height per tap)")).font(.caption)
            HStack(spacing: 6) {
                nudge("←", [-step, 0, 0], j); nudge("→", [step, 0, 0], j)
                nudge("↑", [0, step, 0], j); nudge("↓", [0, -step, 0], j)
                nudge(L10n.t("前", "Fwd"), [0, 0, step], j); nudge(L10n.t("后", "Back"), [0, 0, -step], j)
            }
            Text(L10n.t("试转动（只预览，不改骨骼）", "Try a rotation (preview only)")).font(.caption)
            angleSlider("X", 0, joint.jointLimit, j)
            angleSlider("Y", 1, joint.jointLimit, j)
            angleSlider("Z", 2, joint.jointLimit, j)
            Button(L10n.t("恢复绑定姿态", "Back to Bind Pose")) { scene.restPose(); rotation = .zero }.font(.caption).buttonStyle(.bordered)
        }
    }

    private func nudge(_ title: String, _ delta: SIMD3<Float>, _ j: Int) -> some View {
        Button(title) { rig.nudge(j, by: delta) }.buttonStyle(.bordered).font(.caption).disabled(rig.running)
    }

    private func angleSlider(_ axis: String, _ k: Int, _ limit: JointLimit, _ j: Int) -> some View {
        let lo = Double(min(limit.min[k], 0)), hi = Double(max(limit.max[k], 0))
        return HStack {
            Text(axis).font(.caption.monospaced()).frame(width: 14)
            Slider(value: Binding(get: { Double(rotation[k]) }, set: { rotation[k] = Float($0); scene.rotate(j, to: rotation) }), in: lo...max(lo + 1, hi))
                .disabled(hi - lo < 1)
            Text("\(Int(rotation[k]))°").font(.caption2.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Page 3: skinning

    @ViewBuilder private var skinPage: some View {
        if let skeleton = rig.skeleton {
            if let j = rig.selectedJoint, skeleton.joints.indices.contains(j) {
                Text(L10n.t("「\(skeleton.joints[j].semanticTag.title)」的权重：红色=影响大，蓝色=无影响", "Weights of \(skeleton.joints[j].semanticTag.title): red = strong, blue = none"))
                    .font(.caption)
                if let heatmap {
                    Image(uiImage: heatmap).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 240)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                }
                HStack { Image(systemName: "rotate.3d").font(.caption); Slider(value: $heatYaw, in: -3.14...3.14, onEditingChanged: { editing in if !editing { renderHeatmap() } }) }
                HStack(spacing: 8) {
                    Button(L10n.t("扩大影响", "Wider")) { rig.scaleInfluence(j, by: 1.25) }
                    Button(L10n.t("缩小影响", "Narrower")) { rig.scaleInfluence(j, by: 0.8) }
                    Button(L10n.t("局部平滑", "Smooth Here")) { rig.smooth(around: j) }
                }.buttonStyle(.bordered).font(.caption).disabled(rig.running)
            } else {
                Text(L10n.t("先在「骨骼生成」里选一个关节，这里会显示它的权重热力图。", "Select a joint on the Skeleton page to see its weight heatmap here.")).font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(skeleton.joints.indices.filter { !skeleton.joints[$0].semanticTag.isEnd }, id: \.self) { jointChip(skeleton, $0) } }
                }
            }
            HStack(spacing: 8) {
                Button(L10n.t("全部重算", "Recompute All")) { rig.reskin() }
                Button(L10n.t("撤销（\(rig.undoDepth)）", "Undo (\(rig.undoDepth))")) { rig.undo() }.disabled(rig.undoDepth == 0)
            }.buttonStyle(.bordered).font(.caption).disabled(rig.running)
            Text(L10n.t("每个顶点最多受 4 个关节影响，权重非负且总和为 1。修改会在保存前保留撤销记录。", "Each vertex follows at most 4 joints; weights are non-negative and sum to 1. Changes can be undone until you save."))
                .font(.caption2).foregroundStyle(.secondary)
        } else {
            emptyRig
        }
    }

    private func renderHeatmap() {
        guard let mesh = rig.mesh, let skin = rig.skin, let j = rig.selectedJoint else { heatmap = nil; return }
        let yaw = heatYaw
        Task {
            let raster = await Task.detached(priority: .userInitiated) { () -> RasterImage in
                var colors = [UInt8](repeating: 0, count: mesh.vertexCount * 3)
                for v in 0..<min(mesh.vertexCount, skin.count) {
                    var w: Float = 0
                    for entry in skin.influences(v) where entry.joint == j { w = entry.weight }
                    colors[v * 3] = UInt8(40 + 215 * w)
                    colors[v * 3 + 1] = UInt8(30 + 60 * (1 - abs(w - 0.5) * 2))
                    colors[v * 3 + 2] = UInt8(30 + 200 * (1 - w))
                }
                var framed = mesh
                framed.normalize(size: 1)
                return ModelRasterizer.render(framed, texture: nil, colors: colors, camera: RasterCamera(yaw: yaw, lighting: true), width: 320, height: 320, background: [12, 12, 16, 255])
            }.value
            heatmap = ModelAnimationExport.cgImage(raster).map { UIImage(cgImage: $0) }
        }
    }

    // MARK: Page 4: motion tests

    @ViewBuilder private var motionPage: some View {
        if !rig.fileClips.isEmpty {
            card {
                Text(L10n.t("模型文件自带的动作（\(rig.fileClips.count) 个）", "Animations from the model file (\(rig.fileClips.count))")).font(.caption.weight(.semibold))
                ForEach(rig.fileClips) { clip in
                    let playing = scene.playing?.id == clip.id
                    Button { scene.play(playing ? nil : clip) } label: {
                        HStack {
                            Text(clip.name).font(.subheadline)
                            Spacer()
                            Text(String(format: "%.1fs", clip.period)).font(.caption2).foregroundStyle(.secondary)
                            Image(systemName: playing ? "stop.fill" : "play.fill").font(.caption)
                        }
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("autorig-file-clip-" + clip.id)
                }
                Text(L10n.t("放进 3D 世界后，名字含 idle / walk / run / jump / attack 的动作会对应角色的待机、行走、奔跑、跳跃、攻击；其余动作用第一个。",
                            "In the 3D world, clips named idle / walk / run / jump / attack drive those actions; other actions use the first clip."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if let diagnostics = rig.diagnostics {
            let fails = diagnostics.results.filter { $0.status == .fail }.count, warns = diagnostics.results.filter { $0.status == .warning }.count
            Text(L10n.t("\(diagnostics.results.count) 项测试：\(diagnostics.results.count - fails - warns) 通过、\(warns) 警告、\(fails) 失败。自动检测不能代替人工判断画面效果。",
                        "\(diagnostics.results.count) tests: \(diagnostics.results.count - fails - warns) passed, \(warns) warnings, \(fails) failed. Automatic checks cannot judge how it looks."))
                .font(.caption)
            ForEach(diagnostics.results) { result in testRow(result) }
            ForEach(diagnostics.repairs, id: \.self) { Label($0, systemImage: "wrench.adjustable").font(.caption2).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                Button(L10n.t("停止播放", "Stop")) { scene.play(nil) }
                Button(L10n.t("重新测试", "Test Again")) { rig.retest() }.disabled(rig.running)
            }.buttonStyle(.bordered).font(.caption)
            if !rig.sockets.isEmpty {
                card {
                    Text(L10n.t("挂点（供技能编辑器使用）", "Sockets (for the skill editor)")).font(.caption.weight(.semibold))
                    ForEach(rig.sockets) { socket in row(socket.title, socket.jointID) }
                }
            }
            Button { rig.save(store: store) } label: {
                Label(rig.dirty ? L10n.t("保存角色", "Save Character") : L10n.t("已保存", "Saved"), systemImage: "tray.and.arrow.down").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).disabled(!rig.dirty || rig.running || rig.needsReskin)
        } else {
            emptyRig
        }
    }

    private func testRow(_ result: DiagnosticResult) -> some View {
        let icon: (String, Color) = switch result.status {
        case .pass: ("checkmark.circle.fill", .green)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .fail: ("xmark.octagon.fill", .red)
        }
        let playing = scene.playing?.id == result.id
        return Button { scene.play(playing ? nil : MotionClip.standard(result.id)) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon.0).foregroundStyle(icon.1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.subheadline)
                    ForEach(result.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
                    if let stretch = result.metrics["maxStretch"] { Text(String(format: L10n.t("最大拉伸 %.1f×", "Max stretch %.1f×"), stretch)).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: playing ? "stop.fill" : "play.fill").font(.caption)
            }
            .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).accessibilityIdentifier("autorig-test-" + result.id)
    }

    // MARK: Helpers

    private var emptyRig: some View {
        Text(L10n.t("还没有骨骼。先在「模型分析」里点「自动绑定」。", "No rig yet. Tap Auto Rig on the Analysis page first.")).font(.caption).foregroundStyle(.secondary)
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(); Text(value).font(.caption) }
    }
}
