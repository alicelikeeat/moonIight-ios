import SwiftUI
import RealityKit

// v1.91: the Character Workbench, in the 3D world's ⋯ menu. One live 3D
// preview (drag to turn, pinch to zoom) and seven pages: characters,
// base body, appearance, motions, equipment, tests, export. Every change can
// be undone; nothing replaces a saved character without a confirmation.

@available(iOS 18.0, *)
@MainActor final class WorkbenchScene: ObservableObject {
    let root = Entity()
    private let pivot = Entity()
    private let camera = PerspectiveCamera()
    let runtime = CharacterRuntime()
    static let owner = "workbench"
    @Published var yaw: Float = 0.5 { didSet { turn() } }
    @Published var distance: Float = 3.2 { didSet { place() } }
    @Published var motion: UniversalMotion?
    @Published var bindPose = false
    @Published var showSkeleton = false { didSet { runtime.showSkeleton = showSkeleton; needsPose = true; refreshLook() } }
    /// The base body alone: no outfit or gear, a plain mannequin material
    /// (see-through while the joints are shown).
    @Published var bare = false { didSet { if bare != oldValue { refreshLook() } } }
    /// Level of detail held in the preview (0 full, 1, 2).
    @Published var lod = 0 { didSet { runtime.useLOD(Self.owner, lod); needsPose = true } }
    @Published var highlighted: Set<String> = [] { didSet { runtime.highlightedJoints = highlighted; needsPose = true } }
    private var look = CharacterAppearance()
    @Published private(set) var lastDeformMilliseconds: Double = 0
    private var height: Float = 1.75
    private var time: Float = 0
    private var needsPose = true
    var updates: EventSubscription?

    init() {
        root.addChild(pivot); root.addChild(camera)
        camera.camera.fieldOfViewInDegrees = 35
        let backdrop = ModelEntity(mesh: .generateSphere(radius: 30))
        var sky = UnlitMaterial(color: UIColor(red: 0.1, green: 0.11, blue: 0.16, alpha: 1)); sky.faceCulling = .front
        backdrop.model?.materials = [sky]
        root.addChild(backdrop)
        let floor = ModelEntity(mesh: .generateCylinder(height: 0.01, radius: 0.9), materials: [UnlitMaterial(color: UIColor(white: 0.22, alpha: 1))])
        pivot.addChild(floor)
        let key = DirectionalLight(); key.light.intensity = 3000; key.look(at: .zero, from: [1.5, 3, 3], relativeTo: nil)
        let fill = DirectionalLight(); fill.light.intensity = 900; fill.look(at: .zero, from: [-2, 1, -1], relativeTo: nil)
        root.addChild(key); root.addChild(fill)
        place(); turn()
    }

    private func place() { camera.look(at: [0, height * 0.5, 0], from: [0, height * 0.55, max(1, min(8, distance))], relativeTo: nil) }
    private func turn() { pivot.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) }

    /// Shows (or reshapes) the character.
    func show(_ look: CharacterAppearance) {
        self.look = look
        let shown = displayed(look)
        height = shown.shape.clamped.height
        if runtime.has(Self.owner) { runtime.setAppearance(Self.owner, shown) }
        else if let entity = runtime.entity(owner: Self.owner, source: .humanBase(shown)) {
            // The runtime turns bodies to face +x (the world's forward); face the camera here.
            entity.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
            pivot.addChild(entity)
        }
        runtime.useLOD(Self.owner, lod)
        place()
        needsPose = true
    }

    private func refreshLook() { if runtime.has(Self.owner) { show(look) } }

    static let mannequinColor = SIMD3<Float>(0.78, 0.76, 0.72)
    private func displayed(_ look: CharacterAppearance) -> CharacterAppearance {
        guard bare else { return look }
        return CharacterAppearance(shape: look.shape, skin: .preset(showSkeleton ? .glass : .pbr, color: Self.mannequinColor))
    }

    func tick(_ dt: Float) {
        if let motion, !bindPose { time += dt; needsPose = true; _ = motion }
        guard needsPose, runtime.has(Self.owner) else { return }
        needsPose = false
        let start = Date()
        runtime.pose(Self.owner, motion: bindPose ? nil : motion ?? MotionLibrary.motion("idle"), time: time)
        lastDeformMilliseconds = Date().timeIntervalSince(start) * 1000
    }
    func restart() { time = 0; needsPose = true }
}

@available(iOS 18.0, *)
struct CharacterWorkbenchView: View {
    enum Page: String, CaseIterable, Identifiable {
        case character, base, look, motion, equipment, tests, export
        var id: String { rawValue }
        var title: String {
            switch self {
            case .character: L10n.t("角色", "Character"); case .base: L10n.t("底模", "Base"); case .look: L10n.t("外观", "Look")
            case .motion: L10n.t("动作", "Motion"); case .equipment: L10n.t("装备", "Gear"); case .tests: L10n.t("测试", "Tests"); case .export: L10n.t("导出", "Export")
            }
        }
    }

    @ObservedObject var controller: Glass3DController
    @ObservedObject private var library = CharacterLibrary.shared
    @StateObject private var scene = WorkbenchScene()
    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.character
    @State private var draft = CharacterAppearance.presets[0].1
    @State private var name = CharacterAppearance.presets[0].0
    @State private var packageID: String?
    @State private var undo: [CharacterAppearance] = []
    @State private var validation: CharacterValidation?
    @State private var motionTest: String?
    @State private var message: String?
    @State private var confirmOverwrite = false

    var body: some View {
        VStack(spacing: 0) {
            CharacterPreview(scene: scene, status: statusLine)
            Picker(L10n.t("页面", "Page"), selection: $page) { ForEach(Page.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
                .accessibilityIdentifier("workbench-pages")
            // Results stay visible whichever page is open (not at the bottom of a long form).
            if let message {
                Text(message).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
                    .accessibilityIdentifier("workbench-message")
            }
            Form { pageContent }
        }
        .navigationTitle(L10n.t("角色工作台", "Character Workbench"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.t("关闭", "Close")) { dismiss() }.accessibilityIdentifier("workbench-close") }
            ToolbarItem(placement: .primaryAction) {
                Button { applyUndo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(undo.isEmpty).accessibilityLabel(L10n.t("撤销", "Undo")).accessibilityIdentifier("workbench-undo")
            }
        }
        .onAppear { scene.show(draft) }
        .onChange(of: page) { _, now in
            // The base page shows the bare base body; other pages the dressed character at full detail.
            scene.bare = now == .base
            if now != .base { scene.lod = 0; scene.highlighted = [] }
        }
        .confirmationDialog(L10n.t("覆盖已保存的角色？", "Replace the saved character?"), isPresented: $confirmOverwrite, titleVisibility: .visible) {
            Button(L10n.t("覆盖保存", "Replace"), role: .destructive) { save(force: true) }.accessibilityIdentifier("workbench-confirm-overwrite")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("character-workbench")
    }

    // MARK: Preview

    private var statusLine: String {
        let m = scene.bindPose ? L10n.t("绑定姿态", "Bind pose") : (scene.motion?.name ?? L10n.t("待机", "Idle"))
        let detail = page == .base ? " · " + HumanBasePanel.lodLabel(scene.lod) : ""
        return "\(name) · \(m) · \(String(format: "%.1f", scene.lastDeformMilliseconds)) ms" + detail
    }

    // MARK: Pages

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .character: characterPage
        case .base: basePage
        case .look: lookPage
        case .motion: motionPage
        case .equipment: equipmentPage
        case .tests: testsPage
        case .export: exportPage
        }
    }

    @ViewBuilder private var characterPage: some View {
        Section(L10n.t("从预设开始", "Start from a preset")) {
            ForEach(Array(CharacterAppearance.presets.enumerated()), id: \.offset) { index, preset in
                Button { change { $0 = preset.1 }; name = preset.0; packageID = nil } label: {
                    LabeledContent(preset.0, value: String(format: "%.2f m", preset.1.shape.height))
                }
                .accessibilityIdentifier("workbench-preset-\(index)")
            }
        }
        Section(L10n.t("已保存的角色", "Saved characters")) {
            if library.packages.isEmpty { Text(L10n.t("还没有保存的角色", "No saved characters yet")).foregroundStyle(.secondary) }
            ForEach(library.packages, id: \.manifest.id) { p in
                Button { change { $0 = p.appearance }; name = p.manifest.name; packageID = p.manifest.id } label: {
                    LabeledContent(p.manifest.name, value: p.manifest.quality.rawValue)
                }
            }
            if !library.damaged.isEmpty {
                Text(L10n.t("\(library.damaged.count) 个角色文件损坏，已跳过（其他角色不受影响）", "\(library.damaged.count) damaged character files skipped (the others are fine)")).font(.caption).foregroundStyle(.orange)
            }
        }
        Section(L10n.t("从 AI 3D 模型或导入的模型创建", "From an AI 3D model or an imported model")) {
            let models = Generated3DStore.shared.models.filter { $0.humanoidDetected || $0.geometry == .imported }
            if models.isEmpty { Text(L10n.t("还没有人形模型（可在「AI 生成 3D 模型」里生成或导入）", "No humanoid models yet (make or import one in AI 3D Models)")).foregroundStyle(.secondary) }
            ForEach(models.prefix(12), id: \.id) { m in
                Button { Task { message = await controller.placeModelCharacter(m); page = .export } } label: {
                    LabeledContent(m.name, value: m.geometry.title).lineLimit(1)
                }
                .accessibilityIdentifier("workbench-model-" + m.id)
            }
        }
    }

    /// The base body itself (the same panel as the ⋯ menu's base-body page),
    /// shown bare, plus this character's shape.
    @ViewBuilder private var basePage: some View {
        HumanBasePanel(scene: scene)
        Section(L10n.t("这个角色的体型", "This character's shape")) {
            LabeledContent(L10n.t("身高", "Height"), value: String(format: "%.2f m", draft.shape.height))
            Button(L10n.t("体型恢复中性（可撤销）", "Reset to the neutral shape (undoable)")) { change { $0.shape = .standard } }
                .disabled(draft.shape == .standard)
                .accessibilityIdentifier("workbench-shape-reset")
            Text(L10n.t("底模页只显示人台，服装、装备和皮肤在其他页面里仍然保留。体型在「外观」页调整。", "This page shows only the mannequin; the outfit, gear and skin are kept on the other pages. Adjust the shape on the Look page."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, _ path: WritableKeyPath<HumanShape, Float> & Sendable, _ range: ClosedRange<Float>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title)  \(String(format: "%.2f", draft.shape[keyPath: path]))").font(.caption)
            Slider(value: Binding(get: { draft.shape[keyPath: path] }, set: { v in change(merge: true) { $0.shape[keyPath: path] = v } }), in: range)
                .accessibilityIdentifier("workbench-shape-" + id)
        }
    }

    @ViewBuilder private var lookPage: some View {
        Section(L10n.t("体型", "Body")) {
            slider(L10n.t("身高（米）", "Height (m)"), \.height, 0.8...2.4, id: "height")
            slider(L10n.t("胖瘦", "Build"), \.build, -1...1, id: "build")
            slider(L10n.t("肌肉", "Muscle"), \.muscle, -1...1, id: "muscle")
            slider(L10n.t("性别特征", "Gender"), \.gender, -1...1, id: "gender")
            slider(L10n.t("肩宽", "Shoulders"), \.shoulders, -1...1, id: "shoulders")
            slider(L10n.t("腰围", "Waist"), \.waist, -1...1, id: "waist")
            slider(L10n.t("臀宽", "Hips"), \.hips, -1...1, id: "hips")
        }
        Section(L10n.t("比例", "Proportions")) {
            slider(L10n.t("腿长", "Legs"), \.legLength, 0.55...1.35, id: "legs")
            slider(L10n.t("手臂", "Arms"), \.armLength, 0.6...1.3, id: "arms")
            slider(L10n.t("上半身", "Torso"), \.torsoLength, 0.7...1.3, id: "torso")
            slider(L10n.t("头部（Q 版）", "Head (chibi)"), \.headSize, 0.8...1.9, id: "head")
            slider(L10n.t("手", "Hands"), \.hands, -1...1, id: "hands")
            slider(L10n.t("脚", "Feet"), \.feet, -1...1, id: "feet")
        }
        Section(L10n.t("脸型", "Face")) {
            slider(L10n.t("鹅蛋脸", "Oval"), \.faceOval, 0...1, id: "oval")
            slider(L10n.t("圆脸", "Round"), \.faceRound, 0...1, id: "round")
            slider(L10n.t("方脸", "Square"), \.faceSquare, 0...1, id: "square")
        }
        Section(L10n.t("皮肤材质", "Skin material")) {
            Picker(L10n.t("风格", "Style"), selection: Binding(get: { draft.skin.style }, set: { s in change { $0.skin = .preset(s, color: $0.skin.baseColor) } })) {
                ForEach(CharacterMaterialProfile.Style.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("workbench-skin-style")
            if draft.skin.style == .glass { Text(L10n.t("玻璃角色是透明的 3D 材质（需要透明排序，GPU 成本更高），不是系统的 Liquid Glass 控件。", "A glass character is a transparent 3D material (sorted, costs more GPU), not the system's Liquid Glass controls.")).font(.caption).foregroundStyle(.secondary) }
        }
        Section(L10n.t("服装（真实网格，随身体变形）", "Outfit (real meshes that bend with the body)")) {
            ForEach(OutfitPiece.catalog) { piece in
                let worn = draft.outfit.contains(piece.id)
                Button { change { worn ? $0.remove(piece.id) : $0.wear(piece.id) } } label: {
                    Label("\(piece.slot.title) · \(piece.name)", systemImage: worn ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityIdentifier("workbench-outfit-" + piece.id)
            }
        }
    }

    @ViewBuilder private var motionPage: some View {
        Section(L10n.t("动作库（\(MotionLibrary.standard.count) 个，所有体型共用）", "Motion library (\(MotionLibrary.standard.count), shared by every body)")) {
            ForEach(MotionLibrary.standard) { m in
                Button { scene.motion = m; scene.bindPose = false; scene.restart() } label: {
                    HStack {
                        Text(m.name)
                        Spacer()
                        Text(m.phases.map { String(format: L10n.t("命中 %.2fs", "hit %.2fs"), $0.hit) } ?? (m.loop ? L10n.t("循环", "loop") : "")).font(.caption).foregroundStyle(.secondary)
                        if scene.motion?.id == m.id { Image(systemName: "play.fill") }
                    }
                }
                .accessibilityIdentifier("workbench-motion-" + m.id)
            }
        }
    }

    @ViewBuilder private var equipmentPage: some View {
        Section(L10n.t("挂在骨骼挂点上的装备", "Gear on skeleton sockets")) {
            ForEach(EquipmentItem.catalog) { item in
                let on = draft.equipment.contains(item.id)
                Button { change { on ? $0.remove(item.id) : $0.equip(item.id) } } label: {
                    Label("\(item.slot.title) · \(item.name)", systemImage: on ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityIdentifier("workbench-gear-" + item.id)
            }
        }
        Section { Button(L10n.t("预览装备切换动作", "Preview the equip motion")) { scene.motion = MotionLibrary.motion("equip"); scene.restart() } }
    }

    @ViewBuilder private var testsPage: some View {
        Section {
            Button(L10n.t("检查模型、骨骼、权重和动作", "Check mesh, skeleton, weights and motions")) { runChecks() }.accessibilityIdentifier("workbench-validate")
            if let validation {
                Text(validation.ok ? L10n.t("通过：可以进入世界", "Passed: ready for the world") : L10n.t("未通过：\(validation.errors.count) 个错误", "Failed: \(validation.errors.count) errors"))
                    .font(.headline).foregroundStyle(validation.ok ? .green : .red)
                    .accessibilityIdentifier("workbench-validation-result")
                ForEach(Array(validation.issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle").font(.caption)
                }
            }
            if let motionTest { Text(motionTest).font(.caption).accessibilityIdentifier("workbench-motion-test") }
        }
        Section(L10n.t("运行情况", "Runtime")) {
            LabeledContent(L10n.t("最近一次变形", "Last deformation"), value: String(format: "%.1f ms", scene.lastDeformMilliseconds))
            LabeledContent(L10n.t("异常记录", "Incidents"), value: "\(scene.runtime.incidents.count)")
        }
    }

    @ViewBuilder private var exportPage: some View {
        Section(L10n.t("名字", "Name")) { TextField(L10n.t("角色名字", "Character name"), text: $name).accessibilityIdentifier("workbench-name") }
        Section {
            Button(packageID == nil ? L10n.t("保存为新角色", "Save as a new character") : L10n.t("保存修改", "Save changes")) { save(force: false) }
                .accessibilityIdentifier("workbench-save")
            Button(L10n.t("设为玩家角色", "Use as the player")) { use(asPlayer: true) }.accessibilityIdentifier("workbench-use-as-player")
            Button(L10n.t("放到世界里（NPC）", "Place in the world (NPC)")) { use(asPlayer: false) }.accessibilityIdentifier("workbench-place-npc")
            Button(L10n.t("放入三位演示角色", "Place the three demo characters")) { message = controller.placeDemoCharacters() }.accessibilityIdentifier("workbench-place-demo")
            if let packageID {
                Button(L10n.t("删除这个角色", "Delete this character"), role: .destructive) { library.delete(packageID); self.packageID = nil }
            }
        }
        Section(L10n.t("角色包", "Character package")) {
            Text(L10n.t("角色以 CharacterPackage 保存（Manifest、骨骼、动作、材质、挂点、检查报告）。底模角色不重复保存网格，由通用底模和体型参数重建。",
                        "Characters are saved as a CharacterPackage (manifest, skeleton, motions, materials, sockets, check report). Base-body characters store no mesh of their own; it is rebuilt from the base body and the shape.")).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    /// One undoable change; slider drags merge into one step.
    private func change(merge: Bool = false, _ edit: (inout CharacterAppearance) -> Void) {
        if !merge || undo.last == nil || !mergeWindowOpen { undo.append(draft); if undo.count > 50 { undo.removeFirst() } }
        lastChange = Date()
        edit(&draft)
        draft.shape = draft.shape.clamped
        validation = nil
        scene.show(draft)
    }
    @State private var lastChange = Date.distantPast
    private var mergeWindowOpen: Bool { Date().timeIntervalSince(lastChange) < 0.6 }
    private func applyUndo() { guard let last = undo.popLast() else { return }; draft = last; validation = nil; scene.show(draft) }

    private func package() -> CharacterPackage? {
        let id = packageID ?? UUID().uuidString
        guard var p = CharacterPackage.humanBase(id: id, name: name.isEmpty ? L10n.t("角色", "Character") : String(name.prefix(64)), appearance: draft) else { return nil }
        if let old = library.package(id) { p.manifest.history = old.manifest.history + [.init(date: Date(), what: "edited")] }
        return p
    }

    private func runChecks() {
        guard let p = package() else { validation = CharacterValidation(issues: [CharacterIssue(severity: .error, code: "base.missing", message: L10n.t("没有找到通用底模文件", "The base body file is missing"))]); return }
        validation = p.validation
        // Every motion on this body, every half second: finite and on the ground.
        guard let body = HumanBase.build(draft.shape) else { return }
        var bad: [String] = []
        for m in MotionLibrary.standard {
            for t in stride(from: Float(0), through: m.duration, by: 0.5) {
                let mats = RigPoser.skinning(m.sample(at: t, legLength: RigPoser.legLength(body.skeleton)), skeleton: body.skeleton)
                if !mats.allSatisfy(\.finite) { bad.append(m.id); break }
            }
        }
        motionTest = bad.isEmpty ? L10n.t("\(MotionLibrary.standard.count) 个动作全部可以播放", "All \(MotionLibrary.standard.count) motions play") : L10n.t("有问题的动作：", "Motions with problems: ") + bad.joined(separator: ", ")
    }

    private func save(force: Bool) {
        if let id = packageID, library.package(id) != nil, !force { confirmOverwrite = true; return }
        guard let p = package() else { message = L10n.t("没有找到通用底模文件", "The base body file is missing"); return }
        if let error = library.save(p) { message = error; return }
        packageID = p.manifest.id
        validation = p.validation
        message = L10n.t("已保存：\(p.manifest.name)", "Saved: \(p.manifest.name)")
    }

    private func use(asPlayer: Bool) {
        if packageID == nil || library.package(packageID!) == nil { save(force: true) }
        guard let id = packageID, let p = library.package(id) else { return }
        if asPlayer { controller.useStandardCharacter(p, asPlayer: true); message = L10n.t("玩家现在使用「\(p.manifest.name)」", "The player now uses “\(p.manifest.name)”") }
        else { controller.placeStandardCharacter(p); message = L10n.t("「\(p.manifest.name)」已放在玩家前面", "“\(p.manifest.name)” stands in front of the player") }
    }
}
