import SwiftUI
import SceneKit
import UIKit

/// The 2.5D glass world screen: the SceneKit world, the glass HUD for
/// play, and the design tools. Opened from the sandbox; shares its save.
struct Glass3DScreen: View {
    @StateObject private var controller: Glass3DController
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void
    @State private var generator = false
    @State private var panel = true
    @State private var templates = false

    init(session: RPGSession, onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: Glass3DController(session: session))
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Glass3DSceneView(controller: controller).ignoresSafeArea()
                VStack(spacing: 8) {
                    topBar
                    if !controller.notice.isEmpty {
                        Text(controller.notice).font(.caption).lineLimit(2).padding(.horizontal, 12).padding(.vertical, 5).hudGlass(.light, radius: 12)
                            .frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false).accessibilityIdentifier("glass3d-notice")
                    }
                    if let boss = controller.bossBar { bossBar(boss) }
                    Spacer(minLength: 0)
                    if controller.mode == .play { playHUD } else { designBars(width: geometry.size.width) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                if controller.mode == .edit, panel, !controller.selection.isEmpty || controller.tool == .track {
                    HStack { Spacer(); Glass3DPanel(controller: controller, store: model.mediaStore).frame(width: min(330, geometry.size.width * 0.42)) }
                        .padding(.top, 60).padding(.bottom, 120).padding(.trailing, 10)
                }
            }
        }
        .environment(\.rpgHUDState, RPGHUDState(inCombat: controller.bossBar != nil, editing: controller.mode == .edit))
        .onAppear {
            MoonlightOrientationDelegate.setSandboxLandscape(true)
            controller.renderer.media.resolve = { [weak store = model.mediaStore] id in
                guard let item = store?.items.first(where: { $0.id == id }), let url = item.remoteURL, url.isFileURL else { return nil }
                return (url, RPGMediaCatalogKind.kind(for: item))
            }
            controller.start()
        }
        .onDisappear { controller.stop() }
        .sheet(isPresented: $generator) { Glass3DGeneratorSheet(controller: controller) }
        .confirmationDialog(L10n.t("选择对象", "Choose Object"), isPresented: Binding(get: { !controller.pickChoices.isEmpty }, set: { if !$0 { controller.pickChoices = [] } }), titleVisibility: .visible) {
            ForEach(controller.pickChoices) { choice in Button(choice.title) { controller.selection = [choice.id]; controller.pickChoices = [] } }
            Button(L10n.t("取消", "Cancel"), role: .cancel) { controller.pickChoices = [] }
        }
        .statusBarHidden()
        .accessibilityIdentifier("glass3d-screen")
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            icon("chevron.backward", L10n.t("返回沙盒", "Back to Sandbox"), id: "glass3d-close") { controller.stop(); onClose() }
            Picker(L10n.t("模式", "Mode"), selection: $controller.mode) { ForEach(Glass3DMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).frame(width: 150).accessibilityIdentifier("glass3d-mode")
            Spacer(minLength: 4)
            Text(L10n.t("可见 \(controller.stats.visibleCells) 格 · 方块 \(controller.stats.blocks) · AI \(controller.stats.activeAI) · \(Int(controller.stats.fps)) FPS",
                        "\(controller.stats.visibleCells) cells · \(controller.stats.blocks) blocks · AI \(controller.stats.activeAI) · \(Int(controller.stats.fps)) FPS"))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).accessibilityIdentifier("glass3d-stats")
            if controller.mode == .edit {
                icon("arrow.uturn.backward", L10n.t("撤销", "Undo"), id: "glass3d-undo") { controller.undo() }.disabled(!controller.canUndo)
                icon("arrow.uturn.forward", L10n.t("重做", "Redo"), id: "glass3d-redo") { controller.redo() }.disabled(!controller.canRedo)
                icon("wand.and.stars", L10n.t("一键随机生成世界", "Generate World"), id: "glass3d-generate") { generator = true }
            }
            icon("scope", L10n.t("恢复默认视角", "Reset View"), id: "glass3d-reset-camera") { controller.resetCamera() }
            Menu {
                Picker(L10n.t("玻璃画质", "Glass Quality"), selection: $controller.quality) { ForEach(RPGGlassQuality.allCases, id: \.self) { Text($0.title).tag($0) } }
                Button(L10n.t("保存世界", "Save World")) { controller.persist(force: true) }
                Toggle(L10n.t("显示渲染统计", "Show Render Stats"), isOn: Binding(get: { controller.view?.showsStatistics ?? false }, set: { controller.view?.showsStatistics = $0 }))
            } label: { Image(systemName: "gearshape").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34) }
                .accessibilityLabel(L10n.t("设置", "Settings")).accessibilityIdentifier("glass3d-settings")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .hudGlass(.panel, radius: 18)
        .buttonStyle(.borderless)
    }

    private func icon(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34).contentShape(Rectangle()) }
            .buttonStyle(.borderless).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    private func bossBar(_ boss: (name: String, health: Int, maxHealth: Int, phase: Int)) -> some View {
        VStack(spacing: 3) {
            Text(boss.name + (boss.phase > 1 ? L10n.t(" · 第二阶段", " · Phase 2") : "")).font(.caption.weight(.semibold))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color.red.opacity(0.85)).frame(width: 260 * CGFloat(boss.health) / CGFloat(max(1, boss.maxHealth)))
            }.frame(width: 260, height: 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 6).hudGlass(.light, radius: 12)
        .accessibilityElement(children: .ignore).accessibilityLabel(boss.name + " \(boss.health)/\(boss.maxHealth)").accessibilityIdentifier("glass3d-boss-bar")
    }

    // MARK: Play HUD

    private var playHUD: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                vitals
                Glass3DStick { x, y in controller.setStick(x, y) }
            }
            Spacer()
            if controller.health == 0 {
                Button { controller.revive() } label: { Label(L10n.t("复苏", "Revive"), systemImage: "heart.fill").padding(.horizontal, 18).padding(.vertical, 12) }
                    .buttonStyle(RPGPressStyle()).hudGlass(.interactive, radius: 24).accessibilityIdentifier("glass3d-revive")
            } else {
                RPGGlassGroup(spacing: 10) {
                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(spacing: 10) {
                            round("sparkles", L10n.t("技能", "Skill"), 52, cooldown: controller.cooldowns[1], id: "glass3d-skill") { controller.attack(.skill) }
                            round("arrow.triangle.2.circlepath", L10n.t("闪避", "Dodge"), 48, cooldown: controller.cooldowns[2], id: "glass3d-roll") { controller.roll() }
                        }
                        VStack(spacing: 10) {
                            round("arrow.up.circle", L10n.t("跳跃", "Jump"), 52, cooldown: 0, id: "glass3d-jump") { controller.jump() }
                            round("bolt.fill", L10n.t("攻击", "Attack"), 72, cooldown: controller.cooldowns[0], id: "glass3d-attack") { controller.attack(.strike) }
                        }
                    }
                }
            }
        }
    }

    private var vitals: some View {
        VStack(alignment: .leading, spacing: 4) {
            bar(controller.health, .red, "heart.fill")
            bar(controller.stamina, .green, "bolt.fill")
        }
        .padding(.horizontal, 10).padding(.vertical, 7).hudGlass(.light, radius: 12)
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.t("生命 \(controller.health)，耐力 \(controller.stamina)", "Health \(controller.health), stamina \(controller.stamina)"))
        .accessibilityIdentifier("glass3d-vitals")
    }
    private func bar(_ value: Int, _ tint: Color, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            ZStack(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.15)); Capsule().fill(tint.opacity(0.85)).frame(width: CGFloat(max(0, min(100, value))) * 0.96) }.frame(width: 96, height: 5)
        }
    }

    private func round(_ symbol: String, _ title: String, _ size: CGFloat, cooldown: Double, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: size * 0.32, weight: .bold))
                if size >= 60 { Text(title).font(.system(size: 10, weight: .semibold)) }
            }.frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(RPGPressStyle()).hudGlass(.interactive, in: Circle())
        .overlay(Circle().trim(from: 0, to: cooldown).stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)).padding(2).allowsHitTesting(false))
        .accessibilityLabel(title).accessibilityIdentifier(id)
    }

    // MARK: Design bars

    private func designBars(width: CGFloat) -> some View {
        VStack(spacing: 6) {
            if let pending = controller.pending {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("预览 · ", "Preview · ") + pending.title).font(.caption.weight(.semibold))
                        Text(pending.detail).font(.caption2).foregroundStyle(pending.conflicts.isEmpty ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    Button(L10n.t("取消", "Cancel")) { controller.pending = nil }.accessibilityIdentifier("glass3d-pending-cancel")
                    Button(L10n.t("确认", "Confirm")) { controller.confirmPending() }.fontWeight(.semibold).accessibilityIdentifier("glass3d-pending-confirm")
                }
                .padding(.horizontal, 12).padding(.vertical, 8).hudGlass(.panel, radius: 16)
            }
            optionsBar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Glass3DTool.allCases, id: \.self) { tool in
                        Button { controller.tool = tool } label: {
                            VStack(spacing: 2) { Image(systemName: tool.symbol).font(.system(size: 16, weight: .semibold)); Text(tool.title).font(.system(size: 10)).lineLimit(1).fixedSize() }
                                .frame(minWidth: 46, minHeight: 44).padding(.horizontal, 2)
                                .foregroundStyle(controller.tool == tool ? Color.accentColor : Color.primary)
                                .background(controller.tool == tool ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("glass3d-tool-" + tool.rawValue)
                    }
                    Button { panel.toggle() } label: { Image(systemName: "sidebar.right").frame(width: 40, height: 44) }.buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("属性面板", "Properties"))
                }.padding(.horizontal, 6).padding(.vertical, 4)
            }
            .hudGlass(.panel, radius: 16)
        }
        .frame(maxWidth: min(720, width - 24))
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var optionsBar: some View {
        switch controller.tool {
        case .place, .draw, .area:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Toggle(L10n.t("叠放在最高处", "Stack on Top"), isOn: $controller.stackOnTop).fixedSize()
                    Stepper(L10n.t("高度 \(String(format: "%.2f", controller.buildHeight))", "Height \(String(format: "%.2f", controller.buildHeight))"), value: $controller.buildHeight, in: -1...SpatialBlock.maximumHeight, step: controller.heightSnap).fixedSize()
                    Stepper(L10n.t("厚度 \(String(format: "%.2f", controller.buildThickness))", "Thickness \(String(format: "%.2f", controller.buildThickness))"), value: $controller.buildThickness, in: 0.05...16, step: 0.05).fixedSize()
                    Picker(L10n.t("吸附", "Snap"), selection: $controller.heightSnap) { Text("0.05").tag(0.05); Text("0.25").tag(0.25); Text("1").tag(1.0) }.fixedSize()
                    Picker(L10n.t("碰撞", "Collision"), selection: $controller.buildCollision) { ForEach(SpatialCollision.allCases, id: \.self) { Text($0.title).tag($0) } }.fixedSize()
                    tintMenu
                }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
            }.hudGlass(.panel, radius: 14)
        case .building:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Picker(L10n.t("建筑", "Building"), selection: $controller.buildingKind) { ForEach(BuildingKind.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) } }.fixedSize()
                    Stepper(L10n.t("底面高度 \(String(format: "%.2f", controller.buildHeight))", "Base \(String(format: "%.2f", controller.buildHeight))"), value: $controller.buildHeight, in: -1...SpatialBlock.maximumHeight, step: 0.5).fixedSize()
                    if !controller.world.templates.isEmpty {
                        Menu(L10n.t("我的模板", "My Templates")) {
                            ForEach(controller.world.templates) { template in Button(template.name) { controller.stampTemplate(template, at: SurfacePoint(x: Int(controller.camera.target.x), z: Int(controller.camera.target.y))) } }
                        }
                    }
                    Text(L10n.t("轻点地图放置，确认后写入", "Tap the map to place, then confirm")).foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
            }.hudGlass(.panel, radius: 14)
        case .creature:
            HStack(spacing: 12) {
                Picker(L10n.t("生物", "Creature"), selection: $controller.creatureKind) { ForEach(CreatureKind.allCases, id: \.self) { Text($0.title).tag($0) } }.fixedSize()
                Text(L10n.t("轻点地面或方块放置", "Tap ground or a block to place")).foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6).hudGlass(.panel, radius: 14)
        case .track:
            HStack(spacing: 12) {
                Text(L10n.t("路径点 \(controller.trackPoints.count)", "Waypoints \(controller.trackPoints.count)"))
                Stepper(L10n.t("高度 \(String(format: "%.1f", controller.buildHeight))", "Height \(String(format: "%.1f", controller.buildHeight))"), value: $controller.buildHeight, in: 0...SpatialBlock.maximumHeight, step: 0.5).fixedSize()
                Toggle(L10n.t("平滑", "Smooth"), isOn: $controller.trackSmooth).fixedSize()
                Toggle(L10n.t("闭合", "Closed"), isOn: $controller.trackClosed).fixedSize()
                Button(L10n.t("清空", "Clear")) { controller.trackPoints = [] }
            }.font(.caption).padding(.horizontal, 10).padding(.vertical, 6).hudGlass(.panel, radius: 14)
        case .media:
            Text(L10n.t("轻点方块多选，再在右侧面板选择媒体；多个方块自动切格", "Tap blocks to pick several, then choose media in the panel; several blocks split it"))
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6).hudGlass(.panel, radius: 14)
        case .maze:
            Text(L10n.t("轻点地图放置 13×13 玻璃迷宫（入口在南侧），确认后写入", "Tap the map for a 13×13 glass maze (entrance south), then confirm"))
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 6).hudGlass(.panel, radius: 14)
        case .select, .erase:
            EmptyView()
        }
    }

    private var tintMenu: some View {
        Menu {
            Button(L10n.t("透明", "Clear")) { controller.buildTint = nil }
            ForEach(["8FD3FF", "7FE3C8", "FFD27A", "FF8FB1", "B9A6FF", "C9C2B8"], id: \.self) { hex in Button(hex) { controller.buildTint = hex } }
        } label: { Label(controller.buildTint ?? L10n.t("透明", "Clear"), systemImage: "drop.halffull") }
    }
}

/// Analog stick for the 2.5D world (the same rules as the sandbox stick).
struct Glass3DStick: View {
    let onVector: (Double, Double) -> Void
    var size: CGFloat = 124
    @State private var knob: CGSize = .zero
    @GestureState private var touching = false

    var body: some View {
        let reach = size / 2 - 24
        ZStack {
            Color.clear.frame(width: size, height: size).hudGlass(.interactive, in: Circle())
            Color.clear.frame(width: 48, height: 48).hudGlass(.interactive, in: Circle())
                .overlay(Circle().fill(Color.white.opacity(touching ? 0.28 : 0.12))).offset(knob)
        }
        .frame(width: size, height: size).contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).updating($touching) { _, state, _ in state = true }.onChanged { value in
            let vector = RPGStickRules.vector(dx: value.location.x - size / 2, dy: value.location.y - size / 2, radius: reach)
            let magnitude = RPGStickRules.magnitude(vector)
            knob = CGSize(width: vector.x * reach, height: vector.y * reach)
            // Continuous: direction and speed follow the finger (dead zone only).
            if magnitude <= RPGStickRules.deadZone { onVector(0, 0) } else { onVector(vector.x, vector.y) }
        })
        .onChange(of: touching) { active in if !active { knob = .zero; onVector(0, 0) } }
        .onDisappear { onVector(0, 0) }
        .accessibilityElement().accessibilityLabel(L10n.t("移动摇杆", "Movement Stick")).accessibilityIdentifier("glass3d-stick")
    }
}

/// SceneKit view with the camera and editing gestures. Two fingers always
/// drive the camera (pinch zoom, twist turn, vertical drag tilt); one
/// finger pans in design-select, draws with draw/area, and does nothing on
/// the map in play (the stick and buttons are separate SwiftUI controls).
struct Glass3DSceneView: UIViewRepresentable {
    let controller: Glass3DController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero, options: nil)
        view.scene = controller.renderer.scene
        view.pointOfView = controller.renderer.cameraNode
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        view.isJitteringEnabled = false
        controller.view = view
        let coordinator = context.coordinator
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.rotate(_:)))
        let twoFinger = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.twoFinger(_:)))
        twoFinger.minimumNumberOfTouches = 2; twoFinger.maximumNumberOfTouches = 2
        let oneFinger = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.oneFinger(_:)))
        oneFinger.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.45
        for recognizer in [pinch, rotate, twoFinger, oneFinger, tap, hold] as [UIGestureRecognizer] { recognizer.delegate = coordinator; view.addGestureRecognizer(recognizer) }
        tap.require(toFail: hold)
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let controller: Glass3DController
        private var lastScale: CGFloat = 1, lastRotation: CGFloat = 0
        init(controller: Glass3DController) { self.controller = controller }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            // Camera gestures combine; one-finger work stays on its own.
            func camera(_ g: UIGestureRecognizer) -> Bool { g is UIPinchGestureRecognizer || g is UIRotationGestureRecognizer || ((g as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2) }
            return camera(a) && camera(b)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { lastScale = 1 }
            controller.zoom(by: Double(g.scale / lastScale)); lastScale = g.scale
        }
        @objc func rotate(_ g: UIRotationGestureRecognizer) {
            if g.state == .began { lastRotation = 0 }
            controller.turn(by: Double(-(g.rotation - lastRotation)) * 180 / .pi); lastRotation = g.rotation
        }
        @objc func twoFinger(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view); g.setTranslation(.zero, in: g.view)
            controller.tilt(by: Double(-t.y) * 0.25)
            if controller.mode == .edit { controller.pan(screenDX: Double(t.x), screenDY: 0) }
        }
        @objc func oneFinger(_ g: UIPanGestureRecognizer) {
            guard controller.mode == .edit else { return }
            if controller.tool == .draw || controller.tool == .area {
                controller.drawStroke(at: g.location(in: g.view), ended: g.state == .ended || g.state == .cancelled)
            } else {
                let t = g.translation(in: g.view); g.setTranslation(.zero, in: g.view)
                controller.pan(screenDX: Double(t.x), screenDY: Double(t.y))
            }
        }
        @objc func tap(_ g: UITapGestureRecognizer) { controller.tap(g.location(in: g.view)) }
        @objc func hold(_ g: UILongPressGestureRecognizer) { if g.state == .began { controller.longPress(g.location(in: g.view)) } }
    }
}

/// Properties of the selection: height, size, collision, glass, media,
/// group operations and motion.
struct Glass3DPanel: View {
    @ObservedObject var controller: Glass3DController
    let store: MediaStore
    @State private var face = SpatialFace.top
    @State private var stretch = false
    @State private var gradientTop = 4.0

    var body: some View {
        let blocks = controller.selectedBlocks
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if controller.tool == .track && blocks.isEmpty {
                    Text(L10n.t("轨道：在地图上依次点路径点，然后选中要移动的建筑，选择「轨道」运动。", "Track: tap waypoints on the map, then select the building and choose the Track motion.")).font(.caption)
                }
                if let first = blocks.first {
                    Text(blocks.count == 1 ? L10n.t("方块 x \(first.x) · y \(first.y)", "Block x \(first.x) · y \(first.y)") : L10n.t("已选 \(blocks.count) 个方块", "\(blocks.count) blocks selected")).font(.subheadline.weight(.semibold))
                    section(L10n.t("高度与形状", "Height & Shape")) {
                        HStack {
                            Button("−1") { controller.raiseSelection(-1) }; Button("−0.25") { controller.raiseSelection(-0.25) }
                            Button("+0.25") { controller.raiseSelection(0.25) }; Button("+1") { controller.raiseSelection(1) }
                        }.font(.caption)
                        if blocks.count == 1 {
                            Text(L10n.t("底面 \(String(format: "%.2f", first.elevation)) · 顶面 \(String(format: "%.2f", first.top))", "Bottom \(String(format: "%.2f", first.elevation)) · top \(String(format: "%.2f", first.top))")).font(.caption2).foregroundStyle(.secondary)
                            CommitSlider(title: L10n.t("厚度", "Thickness"), value: first.thickness, range: 0.05...6) { value in controller.updateSelected(L10n.t("厚度", "Thickness")) { $0.thickness = (value * 20).rounded() / 20 } }
                            CommitSlider(title: L10n.t("尺寸", "Size"), value: first.size, range: 0.2...1) { value in controller.updateSelected(L10n.t("尺寸", "Size")) { $0.size = (value * 20).rounded() / 20 } }
                            CommitSlider(title: L10n.t("旋转", "Turn"), value: first.yaw, range: 0...359) { value in controller.updateSelected(L10n.t("旋转", "Turn")) { $0.yaw = value.rounded() } }
                        } else {
                            HStack {
                                Button(L10n.t("对齐到 \(String(format: "%.2f", controller.buildHeight))", "Align at \(String(format: "%.2f", controller.buildHeight))")) { controller.alignSelection() }
                                Button(L10n.t("渐变到 \(Int(gradientTop))", "Ramp to \(Int(gradientTop))")) { controller.gradientSelection(to: gradientTop) }
                                Stepper("", value: $gradientTop, in: 0...32).labelsHidden()
                            }.font(.caption)
                        }
                    }
                    section(L10n.t("碰撞与玻璃", "Collision & Glass")) {
                        Picker(L10n.t("碰撞", "Collision"), selection: Binding(get: { first.collision }, set: { value in controller.updateSelected(L10n.t("碰撞模式", "Collision")) { $0.collision = value } })) {
                            ForEach(SpatialCollision.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Toggle(L10n.t("发光", "Glow"), isOn: Binding(get: { first.glass.glow }, set: { value in controller.updateSelected(L10n.t("发光", "Glow")) { $0.glass.glow = value } }))
                        Toggle(L10n.t("磨砂", "Frosted"), isOn: Binding(get: { first.glass.frosted }, set: { value in controller.updateSelected(L10n.t("磨砂", "Frosted")) { $0.glass.frosted = value } }))
                        CommitSlider(title: L10n.t("浓度", "Density"), value: first.glass.density, range: 0.1...0.9) { value in controller.updateSelected(L10n.t("玻璃浓度", "Glass Density")) { $0.glass.density = (value * 20).rounded() / 20 } }
                    }
                    section(L10n.t("媒体", "Media")) {
                        Picker(L10n.t("显示面", "Face"), selection: $face) { ForEach(SpatialFace.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        Toggle(L10n.t("拉伸（不裁切）", "Stretch (no crop)"), isOn: $stretch)
                        Menu {
                            ForEach(candidates, id: \.id) { item in Button(item.title) { controller.assignMedia(id: item.id, kind: item.kind, face: face, stretch: stretch) } }
                        } label: { Label(blocks.count > 1 ? L10n.t("选择媒体（切成 \(blocks.count) 格）", "Choose Media (split over \(blocks.count))") : L10n.t("选择媒体", "Choose Media"), systemImage: "photo.on.rectangle") }
                        if blocks.contains(where: { $0.media != nil }) { Button(L10n.t("移除媒体", "Remove Media"), role: .destructive) { controller.clearMedia() } }
                    }
                    section(L10n.t("建筑组", "Building Group")) {
                        if let group = controller.selectedGroup {
                            Text(group.name).font(.caption).foregroundStyle(.secondary)
                            HStack { Button(L10n.t("选中整组", "Select All")) { controller.selectGroup() }; Button(L10n.t("复制", "Copy")) { controller.copyGroup() }; Button(L10n.t("旋转 90°", "Turn 90°")) { controller.turnGroup() } }.font(.caption)
                            HStack {
                                Button("←") { controller.moveGroup(dx: -1, dy: 0, dz: 0) }; Button("→") { controller.moveGroup(dx: 1, dy: 0, dz: 0) }
                                Button("↑") { controller.moveGroup(dx: 0, dy: 1, dz: 0) }; Button("↓") { controller.moveGroup(dx: 0, dy: -1, dz: 0) }
                                Button(L10n.t("升", "Up")) { controller.moveGroup(dx: 0, dy: 0, dz: 1) }; Button(L10n.t("降", "Down")) { controller.moveGroup(dx: 0, dy: 0, dz: -1) }
                            }.font(.caption)
                            Button(L10n.t("保存为模板", "Save as Template")) { controller.saveTemplate() }.font(.caption)
                        } else if blocks.count > 1 {
                            Button(L10n.t("组合为建筑", "Group as Building")) { controller.groupSelection() }.font(.caption)
                        }
                    }
                    motionSection
                    Button(L10n.t("删除所选", "Delete Selection"), role: .destructive) { controller.deleteSelection() }.font(.caption)
                }
            }
            .padding(12)
        }
        .hudGlass(.panel, radius: 18)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("glass3d-panel")
    }

    @ViewBuilder private var motionSection: some View {
        section(L10n.t("动态建筑", "Motion")) {
            Menu {
                ForEach(MotionKind.allCases, id: \.self) { kind in Button(kind.title) { controller.assignMotion(kind) } }
            } label: { Label(controller.selectedMotion.map { $0.kind.title } ?? L10n.t("添加运动", "Add Motion"), systemImage: "arrow.triangle.turn.up.right.diamond") }
            if let motion = controller.selectedMotion {
                Picker(L10n.t("方式", "Repeat"), selection: Binding(get: { motion.repeatMode }, set: { value in controller.updateMotion { $0.repeatMode = value } })) { ForEach(MotionRepeat.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker(L10n.t("触发", "Trigger"), selection: Binding(get: { motion.trigger }, set: { value in controller.updateMotion { $0.trigger = value; $0.startedAt = nil } })) { ForEach(MotionTrigger.allCases, id: \.self) { Text($0.title).tag($0) } }
                Stepper(L10n.t("每段 \(String(format: "%.1f", motion.segmentDuration)) 秒", "\(String(format: "%.1f", motion.segmentDuration)) s per leg"), value: Binding(get: { motion.segmentDuration }, set: { value in controller.updateMotion { $0.segmentDuration = value } }), in: 0.5...30, step: 0.5)
                Picker(L10n.t("缓动", "Easing"), selection: Binding(get: { motion.easing }, set: { value in controller.updateMotion { $0.easing = value } })) { Text(L10n.t("线性", "Linear")).tag(MotionEasing.linear); Text(L10n.t("平滑", "Smooth")).tag(MotionEasing.smooth) }
                Picker(L10n.t("媒体", "Media"), selection: Binding(get: { motion.mediaSync }, set: { value in controller.updateMotion { $0.mediaSync = value } })) { ForEach(MotionMediaSync.allCases, id: \.self) { Text($0.title).tag($0) } }
                if motion.kind == .elevator {
                    HStack { ForEach(motion.keyframes.indices, id: \.self) { floor in Button(L10n.t("\(floor + 1) 层", "Floor \(floor + 1)")) { controller.runMotion(floor: floor) } } }.font(.caption)
                } else if motion.trigger != .always {
                    Button(L10n.t("预览运动", "Preview Motion")) { controller.runMotion() }.font(.caption)
                }
                Button(L10n.t("停止并移除运动", "Remove Motion"), role: .destructive) { controller.removeMotion() }.font(.caption)
            }
            Menu {
                Button(L10n.t("不作为按钮", "Not a Button")) { controller.makeButton(for: nil) }
                ForEach(controller.world.groups.filter { $0.motionID != nil }) { group in Button(group.name) { controller.makeButton(for: group.id) } }
            } label: { Label(L10n.t("设为机关按钮…", "Make a Button for…"), systemImage: "button.programmable") }.font(.caption)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private struct Candidate { let id: String; let title: String; let kind: RPGMediaKind }
    private var candidates: [Candidate] {
        store.items.compactMap { item in
            guard item.kind != .embed, item.remoteURL?.isFileURL == true else { return nil }
            let kind = RPGMediaCatalogKind.kind(for: item)
            return kind.usesLibraryFile ? Candidate(id: item.id, title: item.title, kind: kind) : nil
        }
    }
}

/// One-tap world generation: settings, a preview of what it adds and
/// replaces, then confirm (one undo step).
struct Glass3DGeneratorSheet: View {
    @ObservedObject var controller: Glass3DController
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = WorldGenerationConfiguration()
    @State private var result: (SpatialWorld, GenerationSummary)?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("世界", "World")) {
                    Picker(L10n.t("风格", "Style"), selection: $configuration.style) { ForEach(WorldStyle.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker(L10n.t("内容密度", "Density"), selection: $configuration.density) { ForEach(ContentDensity.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker(L10n.t("难度", "Difficulty"), selection: $configuration.difficulty) { ForEach(GameDifficulty.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Toggle(L10n.t("生成迷宫", "Maze"), isOn: $configuration.maze)
                    Toggle(L10n.t("生成小 Boss", "Mini Boss"), isOn: $configuration.miniBoss)
                    Toggle(L10n.t("生成大 Boss", "Boss"), isOn: $configuration.bigBoss)
                    HStack {
                        Text(L10n.t("种子 \(configuration.seed)", "Seed \(configuration.seed)")).monospacedDigit()
                        Spacer()
                        Button(L10n.t("随机", "Random")) { configuration.seed = UInt64.random(in: 1...999_999_999); result = nil }
                    }
                }
                Section(L10n.t("预览", "Preview")) {
                    if working { ProgressView(L10n.t("正在生成并检查连通性…", "Generating and checking routes…")) }
                    else if let summary = result?.1 {
                        Text(L10n.t("建筑 \(summary.buildings) · 方块 \(summary.blocks) · 植物 \(summary.plants)", "Buildings \(summary.buildings) · blocks \(summary.blocks) · plants \(summary.plants)"))
                        Text(L10n.t("中立 \(summary.neutral) · 敌人 \(summary.enemies) · 守卫 \(summary.guards) · 小 Boss \(summary.miniBosses) · 大 Boss \(summary.bosses)", "Neutral \(summary.neutral) · enemies \(summary.enemies) · guards \(summary.guards) · mini bosses \(summary.miniBosses) · bosses \(summary.bosses)"))
                        Text(L10n.t("迷宫 \(summary.mazes) · 宝箱 \(summary.pickups) · 尝试 \(summary.attempts) 次", "Mazes \(summary.mazes) · chests \(summary.pickups) · attempts \(summary.attempts)"))
                        Text(L10n.t("将替换上次生成的 \(summary.replacedGenerated) 个对象，保留你创建的 \(summary.keptUser) 个", "Replaces \(summary.replacedGenerated) generated objects; keeps your \(summary.keptUser)"))
                            .foregroundStyle(summary.replacedGenerated > 0 ? Color.orange : Color.secondary)
                        if !summary.problems.isEmpty { Text(L10n.t("检查未通过：", "Checks failed: ") + summary.problems.joined(separator: ", ")).foregroundStyle(.red) }
                    } else {
                        Button(L10n.t("预览生成结果", "Preview")) { preview() }.accessibilityIdentifier("glass3d-generate-preview")
                    }
                }
            }
            .navigationTitle(L10n.t("一键随机生成世界", "Generate World")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("生成", "Generate")) { if let world = result?.0 { controller.applyGeneration(world) }; dismiss() }
                        .disabled(result == nil || !(result?.1.problems.isEmpty ?? false)).accessibilityIdentifier("glass3d-generate-confirm")
                }
            }
            .onChange(of: configuration) { _ in result = nil }
        }
    }

    private func preview() {
        working = true
        let configuration = configuration
        Task { let value = await controller.previewGeneration(configuration); result = value; working = false }
    }
}

/// A slider that commits once when the finger lifts (one undo step and one
/// save per drag, not one per tick).
struct CommitSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var draft: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title + " " + String(format: "%.2f", draft ?? value)).font(.caption2).foregroundStyle(.secondary)
            Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: range) { editing in
                if !editing, let draft { commit(draft); self.draft = nil }
            }
        }
    }
}
