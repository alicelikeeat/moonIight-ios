import SwiftUI
import RealityKit
import UIKit

/// Opening the 3D world in design mode once per app launch (on by default;
/// switch in the 3D world's gear menu).
enum Glass3DLaunch {
    static let key = "moonlight.glass3d.openAtLaunch"
    @MainActor static var opened = false
    @MainActor static var shouldOpen: Bool { !opened && (UserDefaults.standard.object(forKey: key) as? Bool ?? true) }
}

/// The 3D glass world screen: the RealityKit world, native iOS glass on
/// its blocks, the glass HUD for play, and the design tools. Lays out for
/// portrait and landscape. Shares the sandbox save. Needs iOS 18.
@available(iOS 18.0, *)
struct Glass3DScreen: View {
    @StateObject private var controller: Glass3DController
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void
    @State private var generator = false
    @State private var panel = true
    @State private var editor: Glass3DEditorKind?
    @State private var credits = false
    @State private var generate3D = false
    @AppStorage(Glass3DLaunch.key) private var openAtLaunch = true
    @Namespace private var modeNamespace

    init(session: RPGSession, startInDesign: Bool = false, onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: {
            let controller = Glass3DController(session: session)
            if startInDesign { controller.mode = .edit; controller.designOverview() }
            return controller
        }())
        self.onClose = onClose
    }

    private var showsPanel: Bool {
        controller.mode == .edit && panel && (!controller.selection.isEmpty || controller.tool == .track)
    }

    var body: some View {
        GeometryReader { geometry in
            let portrait = geometry.size.height > geometry.size.width
            ZStack {
                Glass3DWorldView(controller: controller).ignoresSafeArea()
                Glass3DNativeGlassLayer(glass: controller.nativeGlass).ignoresSafeArea()
                Glass3DGestureLayer(controller: controller).ignoresSafeArea()
                Glass3DOverlay(glass: controller.nativeGlass, controller: controller).ignoresSafeArea()
                if controller.mode == .edit {
                    cameraRail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: portrait ? .topTrailing : .leading)
                        .padding(.top, portrait ? 112 : 0).padding(.horizontal, 10)
                        .transition(.move(edge: portrait ? .trailing : .leading).combined(with: .opacity))
                }
                VStack(spacing: 8) {
                    topBar(portrait: portrait)
                    notices
                    Spacer(minLength: 0)
                    if controller.mode == .play {
                        Group { if portrait { playHUDPortrait } else { playHUD } }.transition(.opacity)
                    } else {
                        if portrait, showsPanel {
                            Glass3DPanel(controller: controller, store: model.mediaStore, onClose: { controller.selection = [] })
                                .frame(maxHeight: geometry.size.height * 0.42)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        designBars(portrait: portrait).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, portrait ? 10 : 14).padding(.vertical, 8)
                if !portrait, showsPanel {
                    HStack {
                        Spacer()
                        Glass3DPanel(controller: controller, store: model.mediaStore, onClose: { controller.selection = [] })
                            .frame(width: min(340, geometry.size.width * 0.4))
                    }
                    .padding(.top, 66).padding(.bottom, 170).padding(.trailing, 14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: controller.mode)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: showsPanel)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: portrait)
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
        .sheet(isPresented: $credits) { Glass3DCreditsView(store: model.mediaStore) }
        .fullScreenCover(isPresented: $generate3D) { Generate3DScreen(controller: controller) }
        .sheet(item: $editor) { kind in
            switch kind {
            case .characters: Glass3DCharacterEditor(controller: controller, store: model.mediaStore)
            case .skills: Glass3DSkillEditor(controller: controller)
            case .bosses: Glass3DBossEditor(controller: controller)
            }
        }
        .confirmationDialog(L10n.t("选择对象", "Choose Object"), isPresented: Binding(get: { !controller.pickChoices.isEmpty }, set: { if !$0 { controller.pickChoices = [] } }), titleVisibility: .visible) {
            ForEach(controller.pickChoices) { choice in Button(choice.title) { controller.selection = [choice.id]; controller.pickChoices = [] } }
            Button(L10n.t("取消", "Cancel"), role: .cancel) { controller.pickChoices = [] }
        }
        .statusBarHidden()
        .accessibilityIdentifier("glass3d-screen")
    }

    // MARK: Top bar

    private func topBar(portrait: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                icon("chevron.backward", L10n.t("返回沙盒", "Back to Sandbox"), id: "glass3d-close") { controller.stop(); onClose() }
                modeSwitch(compact: portrait)
                Spacer(minLength: 4)
                if !portrait { stats.padding(.horizontal, 6) }
                Glass3DGamepadBadge(gamepad: controller.gamepad, compact: portrait)
                if controller.mode == .edit {
                    icon("arrow.uturn.backward", L10n.t("撤销", "Undo"), id: "glass3d-undo") { controller.undo() }.disabled(!controller.canUndo)
                    icon("arrow.uturn.forward", L10n.t("重做", "Redo"), id: "glass3d-redo") { controller.redo() }.disabled(!controller.canRedo)
                }
                // Available in both modes: preview first, one undo step.
                Button { generator = true } label: {
                    Group {
                        if portrait { Image(systemName: "wand.and.stars").frame(width: 34) }
                        else { Label(L10n.t("一键生成", "Generate"), systemImage: "wand.and.stars").padding(.horizontal, 10) }
                    }
                    .font(.caption.weight(.semibold)).frame(height: 32)
                    .foregroundStyle(.white).background(Color.accentColor.gradient, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(RPGPressStyle()).accessibilityLabel(L10n.t("一键生成", "Generate")).accessibilityIdentifier("glass3d-generate")
                moreMenu
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .hudGlass(.panel, radius: 24)
            if portrait { stats.padding(.horizontal, 10).padding(.vertical, 5).hudGlass(.light, radius: 12) }
        }
        .buttonStyle(.borderless)
    }

    private func modeSwitch(compact: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Glass3DMode.allCases, id: \.self) { mode in
                let on = controller.mode == mode
                Button { controller.mode = mode } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .play ? "gamecontroller.fill" : "hammer.fill").font(.system(size: 11, weight: .bold))
                        Text(mode.title)
                    }
                    .font(.caption.weight(.semibold)).padding(.horizontal, compact ? 10 : 13).frame(height: 32)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background { if on { Capsule().fill(Color.accentColor.gradient).matchedGeometryEffect(id: "mode", in: modeNamespace) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityIdentifier("glass3d-mode-" + mode.rawValue)
            }
        }
        .padding(3).background(Color.primary.opacity(0.08), in: Capsule())
    }

    /// Blocks, native glass state, active AI and frame rate.
    private var stats: some View {
        let fps = Int(controller.stats.fps)
        return HStack(spacing: 10) {
            Label("\(controller.stats.blocks)", systemImage: "cube")
            Label(controller.nativeGlassStatus, systemImage: "sparkles")
            Label("\(controller.stats.activeAI)", systemImage: "brain")
            HStack(spacing: 3) {
                Circle().fill(fps >= 50 ? Color.green : fps >= 30 ? Color.orange : Color.red).frame(width: 6, height: 6)
                Text("\(fps) FPS")
            }
        }
        .labelStyle(Glass3DCompactLabel())
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("方块 \(controller.stats.blocks) · \(controller.nativeGlassStatus) · AI \(controller.stats.activeAI) · \(fps) FPS",
                                   "\(controller.stats.blocks) blocks · \(controller.nativeGlassStatus) · AI \(controller.stats.activeAI) · \(fps) FPS"))
        .accessibilityIdentifier("glass3d-stats")
    }

    private var moreMenu: some View {
        Menu {
            Button { controller.resetCamera() } label: { Label(L10n.t("恢复默认视角", "Reset View"), systemImage: "scope") }
            Button { controller.persist(force: true) } label: { Label(L10n.t("保存世界", "Save World"), systemImage: "square.and.arrow.down") }
            Section(L10n.t("编辑器", "Editors")) {
                Button { editor = .characters } label: { Label(L10n.t("角色编辑器", "Character Editor"), systemImage: "person.crop.square") }
                Button { editor = .skills } label: { Label(L10n.t("技能编辑器", "Skill Editor"), systemImage: "wand.and.rays") }
                Button { editor = .bosses } label: { Label(L10n.t("Boss 阶段编辑器", "Boss Phase Editor"), systemImage: "crown") }
            }
            Button { generate3D = true } label: { Label(L10n.t("AI 生成 3D 模型", "AI 3D Models"), systemImage: "cube.transparent") }
            Button { credits = true } label: { Label(L10n.t("素材来源与授权", "Credits & Licences"), systemImage: "checkmark.seal") }
            Section(L10n.t("显示", "Display")) {
                Picker(L10n.t("玻璃画质", "Glass Quality"), selection: $controller.quality) { ForEach(RPGGlassQuality.allCases, id: \.self) { Text($0.title).tag($0) } }
                Toggle(L10n.t("第三人称镜头", "Third-Person Camera"), isOn: $controller.thirdPerson)
                if Glass3DController.nativeGlassAvailable {
                    Toggle(L10n.t("方块使用 iOS 原生玻璃", "Native iOS Glass on Blocks"), isOn: $controller.nativeGlassEnabled)
                }
                Toggle(L10n.t("启动时进入 3D 设计模式", "Open in 3D Design at Launch"), isOn: $openAtLaunch)
            }
        } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17, weight: .semibold)).frame(width: 34, height: 34).contentShape(Rectangle()) }
            .accessibilityLabel(L10n.t("设置", "Settings")).accessibilityIdentifier("glass3d-settings")
    }

    private func icon(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34).contentShape(Rectangle()) }
            .buttonStyle(.borderless).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    @ViewBuilder private var notices: some View {
        if !controller.notice.isEmpty {
            Label(controller.notice, systemImage: "info.circle").font(.caption).lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 6).hudGlass(.light, radius: 14)
                .frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false).accessibilityIdentifier("glass3d-notice")
                .transition(.opacity)
        }
        if let boss = controller.bossBar { bossBar(boss) }
        if controller.world.blocks.isEmpty && controller.world.creatures.isEmpty {
            Button { generator = true } label: {
                Label(L10n.t("这是一片空白玻璃世界 · 点这里一键生成", "A blank glass world · tap to generate one"), systemImage: "wand.and.stars")
                    .font(.callout.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(RPGPressStyle()).hudGlass(.interactive, radius: 20).accessibilityIdentifier("glass3d-generate-blank")
        }
    }

    private func bossBar(_ boss: (name: String, health: Int, maxHealth: Int, phase: Int)) -> some View {
        VStack(spacing: 3) {
            Text(boss.name + (boss.phase > 1 ? L10n.t(" · 第 \(boss.phase) 阶段", " · Phase \(boss.phase)") : "")).font(.caption.weight(.semibold))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(Color.red.gradient).frame(width: 240 * CGFloat(boss.health) / CGFloat(max(1, boss.maxHealth)))
            }.frame(width: 240, height: 8)
        }
        .padding(.horizontal, 14).padding(.vertical, 6).hudGlass(.light, radius: 12)
        .accessibilityElement(children: .ignore).accessibilityLabel(boss.name + " \(boss.health)/\(boss.maxHealth)").accessibilityIdentifier("glass3d-boss-bar")
    }

    // MARK: Play HUD

    /// Landscape: move stick left; hotbar, actions and look stick right.
    private var playHUD: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                vitals
                Glass3DStick { x, y in controller.setStick(x, y) }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                if controller.health == 0 { reviveButton } else {
                    RPGGlassGroup(spacing: 10) {
                        HStack(alignment: .bottom, spacing: 10) {
                            VStack(spacing: 8) { lockButton; ForEach(controller.hotbarSlots) { slot in hotbarButton(slot) } }
                            actionCluster
                        }
                    }
                }
                lookStick(size: 112)
            }
        }
    }

    /// Portrait: vitals and hotbar row above; move stick, actions and look
    /// stick along the bottom within thumb reach.
    private var playHUDPortrait: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                vitals
                Spacer(minLength: 4)
                if controller.health > 0 {
                    RPGGlassGroup(spacing: 6) { HStack(spacing: 6) { lockButton; ForEach(controller.hotbarSlots) { slot in hotbarButton(slot) } } }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Glass3DStick(onVector: { x, y in controller.setStick(x, y) }, size: 112)
                Spacer(minLength: 0)
                if controller.health == 0 { reviveButton } else { RPGGlassGroup(spacing: 8) { actionCluster } }
                lookStick(size: 92)
            }
        }
    }

    private var actionCluster: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 8) {
                round("sparkles", L10n.t("技能", "Skill"), 50, cooldown: controller.cooldowns[1], id: "glass3d-skill") { controller.attack(.skill) }
                round("arrow.triangle.2.circlepath", L10n.t("闪避", "Dodge"), 46, cooldown: controller.cooldowns[2], id: "glass3d-roll") { controller.roll() }
            }
            VStack(spacing: 8) {
                round("arrow.up.circle", L10n.t("跳跃", "Jump"), 50, cooldown: 0, id: "glass3d-jump") { controller.jump() }
                round("bolt.fill", L10n.t("攻击", "Attack"), 68, cooldown: controller.cooldowns[0], id: "glass3d-attack") { controller.attack(.strike) }
            }
        }
    }
    private var lockButton: some View {
        round(controller.lockedTarget == nil ? "scope" : "xmark.circle", controller.lockedTarget == nil ? L10n.t("锁定", "Lock") : L10n.t("解除锁定", "Unlock"), 42, cooldown: 0, id: "glass3d-lock") { controller.toggleLock() }
    }
    private func hotbarButton(_ slot: Glass3DHotbarSlot) -> some View {
        round(slot.symbol, slot.name, 42, cooldown: slot.cooldown, id: "glass3d-hotbar-\(slot.index)") { controller.castHotbar(slot.index) }
    }
    private func lookStick(size: CGFloat) -> some View {
        Glass3DStick(onVector: { x, y in controller.setLook(x, y) }, size: size, symbol: "eye", label: L10n.t("视角摇杆", "Look Stick"), identifier: "glass3d-look-stick")
    }
    private var reviveButton: some View {
        Button { controller.revive() } label: {
            Label(L10n.t("复苏", "Revive"), systemImage: "heart.fill").font(.headline).foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 14).background(Color.pink.gradient, in: Capsule())
        }
        .buttonStyle(RPGPressStyle()).accessibilityIdentifier("glass3d-revive")
    }

    private var vitals: some View {
        VStack(alignment: .leading, spacing: 5) {
            bar(controller.health, .red, "heart.fill")
            bar(controller.stamina, .green, "bolt.fill")
        }
        .padding(.horizontal, 10).padding(.vertical, 8).hudGlass(.light, radius: 14)
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.t("生命 \(controller.health)，耐力 \(controller.stamina)", "Health \(controller.health), stamina \(controller.stamina)"))
        .accessibilityIdentifier("glass3d-vitals")
    }
    private func bar(_ value: Int, _ tint: Color, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            ZStack(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.15)); Capsule().fill(tint.gradient).frame(width: CGFloat(max(0, min(100, value))) * 0.96) }.frame(width: 96, height: 6)
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

    // MARK: Design

    /// Free camera: fly up / down, look at the selection, straight down, back to the character.
    private var cameraRail: some View {
        VStack(spacing: 0) {
            icon("arrow.up.to.line", L10n.t("镜头上升", "Fly Up"), id: "glass3d-fly-up") { controller.fly(2) }
            icon("arrow.down.to.line", L10n.t("镜头下降", "Fly Down"), id: "glass3d-fly-down") { controller.fly(-2) }
            Divider().frame(width: 22).padding(.vertical, 2)
            icon("viewfinder", L10n.t("聚焦选中", "Focus Selection"), id: "glass3d-focus") { controller.focusSelection() }.disabled(controller.selection.isEmpty)
            icon("square.grid.3x3", L10n.t("快速俯视", "Straight Down"), id: "glass3d-top-down") { controller.lookStraightDown() }
            icon("figure.stand", L10n.t("回到角色", "Back to Character"), id: "glass3d-back-to-character") { controller.backToCharacter() }
        }
        .padding(.vertical, 6).padding(.horizontal, 3)
        .hudGlass(.panel, in: Capsule())
    }

    private func designBars(portrait: Bool) -> some View {
        VStack(spacing: 8) {
            if let pending = controller.pending { pendingCard(pending) }
            toolCard
            toolDock
        }
        .frame(maxWidth: portrait ? .infinity : 760)
        .buttonStyle(.borderless)
    }

    private func pendingCard(_ pending: Glass3DPending) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32).background(Color.accentColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("预览 · ", "Preview · ") + pending.title).font(.caption.weight(.semibold))
                Text(pending.detail).font(.caption2).foregroundStyle(pending.conflicts.isEmpty ? Color.secondary : Color.orange).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(L10n.t("取消", "Cancel")) { controller.pending = nil }.buttonStyle(Glass3DChipStyle()).accessibilityIdentifier("glass3d-pending-cancel")
            Button(L10n.t("确认", "Confirm")) { controller.confirmPending() }.buttonStyle(Glass3DChipStyle(tint: .accentColor, prominent: true)).accessibilityIdentifier("glass3d-pending-confirm")
        }
        .padding(.horizontal, 12).padding(.vertical, 9).hudGlass(.panel, radius: 18)
    }

    /// The current tool: what it does, then its options.
    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: controller.tool.symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(controller.tool.title).font(.caption.weight(.semibold))
                Text(Self.hint(controller.tool)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            toolOptions
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudGlass(.panel, radius: 18)
    }

    static func hint(_ tool: Glass3DTool) -> String {
        switch tool {
        case .select: L10n.t("轻点选中，单指拖动平移，双指缩放和旋转", "Tap to select, drag to pan, pinch and twist the camera")
        case .place: L10n.t("轻点地面或方块放一块玻璃", "Tap ground or a block to place glass")
        case .draw: L10n.t("单指拖动连续绘制，松手后确认", "Drag to draw, confirm when you lift")
        case .area: L10n.t("拖出一片区域，松手后确认", "Drag out an area, confirm when you lift")
        case .erase: L10n.t("轻点方块把它删掉", "Tap a block to remove it")
        case .dig: L10n.t("轻点地面挖开（再点填回），方块最低到 -16", "Tap the ground to dig (again to fill); blocks down to -16")
        case .building: L10n.t("轻点地图放置，确认后写入", "Tap the map to place, then confirm")
        case .media: L10n.t("轻点方块多选，再在属性面板选择媒体；多个方块自动切格", "Tap blocks to pick several, then choose media in the panel; several blocks split it")
        case .creature: L10n.t("轻点地面或方块放置生物", "Tap ground or a block to place a creature")
        case .maze: L10n.t("轻点地图放置 13×13 玻璃迷宫（入口在南侧）", "Tap the map for a 13×13 glass maze (entrance south)")
        case .track: L10n.t("依次点路径点，再选中建筑并选择「轨道」运动", "Tap waypoints, then select a building and choose Track motion")
        }
    }

    @ViewBuilder private var toolOptions: some View {
        switch controller.tool {
        case .place, .draw, .area:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Toggle(L10n.t("叠放在最高处", "Stack on Top"), isOn: $controller.stackOnTop).fixedSize()
                    if controller.tool == .area {
                        Stepper(L10n.t("层数 \(controller.buildLayers)", "Layers \(controller.buildLayers)"), value: $controller.buildLayers, in: 1...12).fixedSize()
                    }
                    Stepper(L10n.t("高度 \(String(format: "%.2f", controller.buildHeight))", "Height \(String(format: "%.2f", controller.buildHeight))"), value: $controller.buildHeight, in: -1...SpatialBlock.maximumHeight, step: controller.heightSnap).fixedSize()
                    Stepper(L10n.t("厚度 \(String(format: "%.2f", controller.buildThickness))", "Thickness \(String(format: "%.2f", controller.buildThickness))"), value: $controller.buildThickness, in: 0.05...16, step: 0.05).fixedSize()
                    Picker(L10n.t("吸附", "Snap"), selection: $controller.heightSnap) { Text("0.05").tag(0.05); Text("0.25").tag(0.25); Text("1").tag(1.0) }.fixedSize()
                    Picker(L10n.t("碰撞", "Collision"), selection: $controller.buildCollision) { ForEach(SpatialCollision.allCases, id: \.self) { Text($0.title).tag($0) } }.fixedSize()
                    tintPicker
                }.font(.caption)
            }
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
                }.font(.caption)
            }
        case .creature:
            VStack(alignment: .leading, spacing: 6) {
                Picker(L10n.t("生物", "Creature"), selection: $controller.creatureKind) { ForEach(CreatureKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                HStack {
                    Text(L10n.t("外观", "Look"))
                    Picker(L10n.t("外观", "Look"), selection: $controller.creatureLook) {
                        Text(L10n.t("默认外观", "Default")).tag(String?.none)
                        ForEach(controller.world.characters ?? []) { Text($0.name).tag(String?.some($0.id)) }
                    }
                    .accessibilityIdentifier("glass3d-creature-look")
                    Spacer(minLength: 0)
                }
            }
            .font(.caption)
        case .track:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Text(L10n.t("路径点 \(controller.trackPoints.count)", "Waypoints \(controller.trackPoints.count)")).monospacedDigit()
                    Stepper(L10n.t("高度 \(String(format: "%.1f", controller.buildHeight))", "Height \(String(format: "%.1f", controller.buildHeight))"), value: $controller.buildHeight, in: 0...SpatialBlock.maximumHeight, step: 0.5).fixedSize()
                    Toggle(L10n.t("平滑", "Smooth"), isOn: $controller.trackSmooth).fixedSize()
                    Toggle(L10n.t("闭合", "Closed"), isOn: $controller.trackClosed).fixedSize()
                    Button(L10n.t("清空", "Clear")) { controller.trackPoints = [] }.buttonStyle(Glass3DChipStyle(tint: .red))
                }.font(.caption)
            }
        case .select, .erase, .media, .maze, .dig:
            EmptyView()
        }
    }

    /// Glass tint swatches.
    private var tintPicker: some View {
        HStack(spacing: 6) {
            swatch(nil)
            ForEach(["8FD3FF", "7FE3C8", "FFD27A", "FF8FB1", "B9A6FF", "C9C2B8"], id: \.self) { swatch($0) }
        }
    }
    private func swatch(_ hex: String?) -> some View {
        let on = controller.buildTint == hex
        return Button { controller.buildTint = hex } label: {
            Circle().fill(hex.map { Color(UIColor(rpgHex: $0)) } ?? Color.white.opacity(0.35))
                .overlay { if hex == nil { Image(systemName: "drop").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) } }
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(on ? Color.accentColor : Color.white.opacity(0.5), lineWidth: on ? 2.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex ?? L10n.t("透明", "Clear"))
    }

    private var toolDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Glass3DTool.allCases, id: \.self) { tool in
                    dockButton(tool.symbol, tool.title, on: controller.tool == tool, id: "glass3d-tool-" + tool.rawValue) { controller.tool = tool }
                }
                Divider().frame(height: 34).padding(.horizontal, 2)
                dockButton("slider.horizontal.3", L10n.t("属性", "Properties"), on: panel, id: "glass3d-panel-toggle") { panel.toggle() }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .hudGlass(.panel, radius: 22)
    }
    private func dockButton(_ symbol: String, _ title: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 32)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(title).font(.system(size: 10, weight: on ? .semibold : .regular)).foregroundStyle(on ? Color.accentColor : Color.secondary).lineLimit(1).fixedSize()
            }
            .frame(minWidth: 50).contentShape(Rectangle())
        }
        .buttonStyle(RPGPressStyle()).accessibilityLabel(title).accessibilityIdentifier(id)
    }
}

/// Icon and short value, tight spacing (status line).
struct Glass3DCompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.font(.system(size: 9, weight: .semibold)); configuration.title }
    }
}

/// Capsule chip button used across the design panels.
struct Glass3DChipStyle: ButtonStyle {
    var tint: Color = .primary
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.white : tint)
            .background(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.12)), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Analog stick for the 3D world (the same rules as the sandbox stick).
struct Glass3DStick: View {
    let onVector: (Double, Double) -> Void
    var size: CGFloat = 124
    var symbol: String? = nil
    var label = L10n.t("移动摇杆", "Movement Stick")
    var identifier = "glass3d-stick"
    @State private var knob: CGSize = .zero
    @GestureState private var touching = false

    var body: some View {
        let reach = size / 2 - 24
        ZStack {
            Color.clear.frame(width: size, height: size).hudGlass(.interactive, in: Circle())
            Color.clear.frame(width: 48, height: 48).hudGlass(.interactive, in: Circle())
                .overlay(Circle().fill(Color.white.opacity(touching ? 0.28 : 0.12)))
                .overlay { if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary) } }
                .offset(knob)
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
        .accessibilityElement().accessibilityLabel(label).accessibilityIdentifier(identifier)
    }
}

/// The RealityKit world with a virtual camera (no AR).
@available(iOS 18.0, *)
struct Glass3DWorldView: View {
    let controller: Glass3DController
    var body: some View {
        GeometryReader { geometry in
            RealityView { content in
                content.camera = .virtual
                content.add(controller.renderer.root)
                // Drive the game from RealityKit's own frame updates (in step with rendering).
                controller.updates = content.subscribe(to: SceneEvents.Update.self) { event in
                    MainActor.assumeIsolated { controller.renderedFrame(event.deltaTime) }
                }
            }
            .onAppear { controller.viewSize = geometry.size }
            .onChange(of: geometry.size) { _, size in controller.viewSize = size }
        }
    }
}

/// Camera and editing gestures over the world. Two fingers always drive
/// the camera (pinch zoom, twist turn, vertical drag tilt); one finger pans
/// in design-select, draws with draw/area, and does nothing on the map in
/// play (the stick and buttons are separate SwiftUI controls above).
@available(iOS 18.0, *)
struct Glass3DGestureLayer: UIViewRepresentable {
    let controller: Glass3DController

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
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
    func updateUIView(_ view: UIView, context: Context) {}
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

/// Properties of the selection, as cards: height and shape, glass, media
/// (with previews), building group and motion. Right side in landscape,
/// a bottom card in portrait.
@available(iOS 18.0, *)
struct Glass3DPanel: View {
    @ObservedObject var controller: Glass3DController
    let store: MediaStore
    var onClose: () -> Void = {}
    @State private var face = SpatialFace.top
    @State private var stretch = false
    @State private var gradientTop = 4.0
    @State private var pickingMedia = false

    var body: some View {
        let blocks = controller.selectedBlocks
        VStack(spacing: 0) {
            header(blocks)
            ScrollView {
                VStack(spacing: 10) {
                    if controller.tool == .track && blocks.isEmpty {
                        card(L10n.t("轨道", "Track"), "point.topleft.down.to.point.bottomright.curvepath") {
                            Text(L10n.t("在地图上依次点路径点，然后选中要移动的建筑，在「动态建筑」里选择「轨道」。", "Tap waypoints on the map, then select the building and choose Track under Motion.")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let first = blocks.first {
                        shapeCard(first, count: blocks.count)
                        glassCard(first)
                        mediaCard(blocks)
                        groupCard(count: blocks.count)
                        motionCard
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
            }
            .scrollIndicators(.hidden)
        }
        .hudGlass(.panel, radius: 24)
        .buttonStyle(.borderless)
        .sheet(isPresented: $pickingMedia) {
            Glass3DMediaPicker(store: store, title: blocks.count > 1 ? L10n.t("选择媒体（切成 \(blocks.count) 格）", "Choose Media (split over \(blocks.count))") : L10n.t("选择媒体", "Choose Media"), current: currentMedia(blocks)?.id, used: controller.worldMediaIDs) { item in
                controller.assignMedia(id: item.id, kind: item.kind, face: face, stretch: stretch)
            }
        }
        .accessibilityIdentifier("glass3d-panel")
    }

    // MARK: Header

    private func header(_ blocks: [SpatialBlock]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: blocks.count > 1 ? "square.stack.3d.up.fill" : controller.tool == .track && blocks.isEmpty ? "point.topleft.down.to.point.bottomright.curvepath" : "cube.transparent.fill")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title(blocks)).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let first = blocks.first {
                    Text(blocks.count == 1 ? L10n.t("底面 \(f2(first.elevation)) · 顶面 \(f2(first.top))", "Bottom \(f2(first.elevation)) · top \(f2(first.top))")
                                           : controller.selectedGroup?.name ?? L10n.t("可一起调整高度、玻璃和媒体", "Adjust height, glass and media together"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !blocks.isEmpty {
                Button(role: .destructive) { controller.deleteSelection() } label: {
                    Image(systemName: "trash").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30).background(Color.red.opacity(0.14), in: Circle()).foregroundStyle(.red)
                }
                .accessibilityLabel(L10n.t("删除所选", "Delete Selection")).accessibilityIdentifier("glass3d-panel-delete")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 30, height: 30).background(Color.primary.opacity(0.1), in: Circle()).foregroundStyle(.secondary)
            }
            .accessibilityLabel(L10n.t("关闭面板", "Close Panel")).accessibilityIdentifier("glass3d-panel-close")
        }
        .padding(12)
    }

    private func title(_ blocks: [SpatialBlock]) -> String {
        guard let first = blocks.first else { return L10n.t("轨道路径", "Track Path") }
        return blocks.count == 1 ? L10n.t("方块 x \(first.x) · y \(first.y)", "Block x \(first.x) · y \(first.y)") : L10n.t("已选 \(blocks.count) 个方块", "\(blocks.count) blocks selected")
    }

    // MARK: Cards

    private func shapeCard(_ first: SpatialBlock, count: Int) -> some View {
        card(L10n.t("高度与形状", "Height & Shape"), "arrow.up.and.down.square") {
            HStack(spacing: 6) {
                ForEach([-1.0, -0.25, 0.25, 1.0], id: \.self) { step in
                    Button(step > 0 ? "+\(step == 1 ? "1" : "¼")" : "−\(step == -1 ? "1" : "¼")") { controller.raiseSelection(step) }
                        .buttonStyle(Glass3DChipStyle()).frame(maxWidth: .infinity)
                }
            }
            if count == 1 {
                CommitSlider(title: L10n.t("厚度", "Thickness"), value: first.thickness, range: 0.05...6) { value in controller.updateSelected(L10n.t("厚度", "Thickness")) { $0.thickness = (value * 20).rounded() / 20 } }
                CommitSlider(title: L10n.t("尺寸", "Size"), value: first.size, range: 0.2...1) { value in controller.updateSelected(L10n.t("尺寸", "Size")) { $0.size = (value * 20).rounded() / 20 } }
                CommitSlider(title: L10n.t("旋转", "Turn"), value: first.yaw, range: 0...359) { value in controller.updateSelected(L10n.t("旋转", "Turn")) { $0.yaw = value.rounded() } }
            } else {
                HStack(spacing: 6) {
                    Button(L10n.t("对齐到 \(f2(controller.buildHeight))", "Align at \(f2(controller.buildHeight))")) { controller.alignSelection() }.buttonStyle(Glass3DChipStyle())
                    Button(L10n.t("渐变到 \(Int(gradientTop))", "Ramp to \(Int(gradientTop))")) { controller.gradientSelection(to: gradientTop) }.buttonStyle(Glass3DChipStyle())
                    Stepper("", value: $gradientTop, in: 0...32).labelsHidden()
                }
            }
        }
    }

    private func glassCard(_ first: SpatialBlock) -> some View {
        card(L10n.t("碰撞与玻璃", "Collision & Glass"), "drop.halffull") {
            HStack {
                Text(L10n.t("碰撞", "Collision")).font(.caption)
                Spacer()
                Picker(L10n.t("碰撞", "Collision"), selection: Binding(get: { first.collision }, set: { value in controller.updateSelected(L10n.t("碰撞模式", "Collision")) { $0.collision = value } })) {
                    ForEach(SpatialCollision.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden()
            }
            HStack(spacing: 6) {
                toggleChip(L10n.t("发光", "Glow"), "sun.max.fill", on: first.glass.glow) { value in controller.updateSelected(L10n.t("发光", "Glow")) { $0.glass.glow = value } }
                toggleChip(L10n.t("磨砂", "Frosted"), "circle.dotted", on: first.glass.frosted) { value in controller.updateSelected(L10n.t("磨砂", "Frosted")) { $0.glass.frosted = value } }
                Spacer(minLength: 0)
            }
            CommitSlider(title: L10n.t("浓度", "Density"), value: first.glass.density, range: 0.1...0.9) { value in controller.updateSelected(L10n.t("玻璃浓度", "Glass Density")) { $0.glass.density = (value * 20).rounded() / 20 } }
        }
    }

    private func mediaCard(_ blocks: [SpatialBlock]) -> some View {
        let current = currentMedia(blocks)
        return card(L10n.t("媒体", "Media"), "photo.on.rectangle") {
            HStack(spacing: 12) {
                Button { pickingMedia = true } label: {
                    Glass3DMediaThumbnail(url: current?.url, kind: current?.kind ?? .image, side: 64, corner: 14)
                        .overlay { if current == nil { Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.accentColor) } }
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.t("选择媒体", "Choose Media"))
                VStack(alignment: .leading, spacing: 6) {
                    Text(current?.title ?? L10n.t("还没有媒体", "No media yet")).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(blocks.count > 1 ? L10n.t("会切成 \(blocks.count) 格铺满所选方块", "Splits over the \(blocks.count) blocks") : L10n.t("显示在方块的一个面上", "Shown on one face of the block"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        Button(current == nil ? L10n.t("选择", "Choose") : L10n.t("更换", "Replace")) { pickingMedia = true }
                            .buttonStyle(Glass3DChipStyle(tint: .accentColor, prominent: true)).accessibilityIdentifier("glass3d-choose-media")
                        if blocks.contains(where: { $0.media != nil }) {
                            Button(L10n.t("移除", "Remove"), role: .destructive) { controller.clearMedia() }.buttonStyle(Glass3DChipStyle(tint: .red))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Picker(L10n.t("显示面", "Face"), selection: $face) { ForEach(SpatialFace.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Toggle(L10n.t("拉伸（不裁切）", "Stretch (no crop)"), isOn: $stretch).font(.caption)
        }
    }

    @ViewBuilder private func groupCard(count: Int) -> some View {
        if let group = controller.selectedGroup {
            card(L10n.t("建筑组", "Building Group"), "building.2") {
                Text(group.name).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button(L10n.t("选中整组", "Select All")) { controller.selectGroup() }.buttonStyle(Glass3DChipStyle())
                    Button(L10n.t("复制", "Copy")) { controller.copyGroup() }.buttonStyle(Glass3DChipStyle())
                    Button(L10n.t("旋转 90°", "Turn 90°")) { controller.turnGroup() }.buttonStyle(Glass3DChipStyle())
                }
                HStack(spacing: 4) {
                    moveChip("arrow.left", L10n.t("左移", "Left")) { controller.moveGroup(dx: -1, dy: 0, dz: 0) }
                    moveChip("arrow.right", L10n.t("右移", "Right")) { controller.moveGroup(dx: 1, dy: 0, dz: 0) }
                    moveChip("arrow.up", L10n.t("前移", "Forward")) { controller.moveGroup(dx: 0, dy: 1, dz: 0) }
                    moveChip("arrow.down", L10n.t("后移", "Back")) { controller.moveGroup(dx: 0, dy: -1, dz: 0) }
                    moveChip("arrow.up.to.line", L10n.t("升高", "Raise")) { controller.moveGroup(dx: 0, dy: 0, dz: 1) }
                    moveChip("arrow.down.to.line", L10n.t("降低", "Lower")) { controller.moveGroup(dx: 0, dy: 0, dz: -1) }
                }
                HStack(spacing: 6) {
                    Button(L10n.t("镜像", "Mirror")) { controller.mirrorGroup() }.buttonStyle(Glass3DChipStyle())
                    Button(L10n.t("阵列 ×3", "Array ×3")) { controller.arrayGroup(count: 3, step: 6) }.buttonStyle(Glass3DChipStyle())
                    Button(L10n.t("放大", "Grow")) { controller.scaleGroup(1.25) }.buttonStyle(Glass3DChipStyle())
                    Button(L10n.t("缩小", "Shrink")) { controller.scaleGroup(0.8) }.buttonStyle(Glass3DChipStyle())
                }
                Button { controller.saveTemplate() } label: { Label(L10n.t("保存为模板", "Save as Template"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(Glass3DChipStyle(tint: .accentColor))
            }
        } else if count > 1 {
            card(L10n.t("建筑组", "Building Group"), "building.2") {
                Button { controller.groupSelection() } label: { Label(L10n.t("组合为建筑", "Group as Building"), systemImage: "square.on.square") }
                    .buttonStyle(Glass3DChipStyle(tint: .accentColor, prominent: true))
            }
        }
    }

    private var motionCard: some View {
        card(L10n.t("动态建筑", "Motion"), "arrow.triangle.turn.up.right.diamond") {
            Menu {
                ForEach(MotionKind.allCases, id: \.self) { kind in Button(kind.title) { controller.assignMotion(kind) } }
            } label: { Label(controller.selectedMotion.map { $0.kind.title } ?? L10n.t("添加运动", "Add Motion"), systemImage: "plus") }
                .buttonStyle(Glass3DChipStyle(tint: .accentColor))
            if let motion = controller.selectedMotion {
                Group {
                    Picker(L10n.t("方式", "Repeat"), selection: Binding(get: { motion.repeatMode }, set: { value in controller.updateMotion { $0.repeatMode = value } })) { ForEach(MotionRepeat.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker(L10n.t("触发", "Trigger"), selection: Binding(get: { motion.trigger }, set: { value in controller.updateMotion { $0.trigger = value; $0.startedAt = nil } })) { ForEach(MotionTrigger.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Stepper(L10n.t("每段 \(String(format: "%.1f", motion.segmentDuration)) 秒", "\(String(format: "%.1f", motion.segmentDuration)) s per leg"), value: Binding(get: { motion.segmentDuration }, set: { value in controller.updateMotion { $0.segmentDuration = value } }), in: 0.5...30, step: 0.5)
                    Picker(L10n.t("缓动", "Easing"), selection: Binding(get: { motion.easing }, set: { value in controller.updateMotion { $0.easing = value } })) { Text(L10n.t("线性", "Linear")).tag(MotionEasing.linear); Text(L10n.t("平滑", "Smooth")).tag(MotionEasing.smooth) }
                    Picker(L10n.t("媒体", "Media"), selection: Binding(get: { motion.mediaSync }, set: { value in controller.updateMotion { $0.mediaSync = value } })) { ForEach(MotionMediaSync.allCases, id: \.self) { Text($0.title).tag($0) } }
                }
                .font(.caption)
                if motion.kind == .elevator {
                    HStack(spacing: 6) { ForEach(motion.keyframes.indices, id: \.self) { floor in Button(L10n.t("\(floor + 1) 层", "Floor \(floor + 1)")) { controller.runMotion(floor: floor) }.buttonStyle(Glass3DChipStyle()) } }
                } else if motion.trigger != .always {
                    Button { controller.runMotion() } label: { Label(L10n.t("预览运动", "Preview Motion"), systemImage: "play.fill") }.buttonStyle(Glass3DChipStyle())
                }
                Button(L10n.t("停止并移除运动", "Remove Motion"), role: .destructive) { controller.removeMotion() }.buttonStyle(Glass3DChipStyle(tint: .red))
            }
            Menu {
                Button(L10n.t("不作为按钮", "Not a Button")) { controller.makeButton(for: nil) }
                ForEach(controller.world.groups.filter { $0.motionID != nil }) { group in Button(group.name) { controller.makeButton(for: group.id) } }
            } label: { Label(L10n.t("设为机关按钮…", "Make a Button for…"), systemImage: "button.programmable") }
                .buttonStyle(Glass3DChipStyle())
        }
    }

    // MARK: Pieces

    private func card<Content: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func toggleChip(_ title: String, _ symbol: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: { Label(title, systemImage: symbol) }
            .buttonStyle(Glass3DChipStyle(tint: on ? .accentColor : .primary, prominent: on))
            .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func moveChip(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(maxWidth: .infinity) }
            .buttonStyle(Glass3DChipStyle()).accessibilityLabel(label)
    }

    private func currentMedia(_ blocks: [SpatialBlock]) -> Glass3DMediaItem? {
        guard let binding = blocks.lazy.compactMap({ $0.media?.bindingID }).first, let mediaID = controller.mediaID(forBinding: binding) else { return nil }
        return glass3DMediaItems(store).first { $0.id == mediaID }
    }

    private func f2(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// One-tap world generation: settings, a preview of what it adds and
/// replaces, then confirm (one undo step).
@available(iOS 18.0, *)
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
                    amount(L10n.t("建筑数量", "Buildings"), \.buildingAmount)
                    amount(L10n.t("植物数量", "Plants"), \.plantAmount)
                    amount(L10n.t("生物数量", "Creatures"), \.creatureAmount)
                    amount(L10n.t("敌人数量", "Enemies"), \.enemyAmount)
                    Toggle(L10n.t("浮岛", "Floating Islands"), isOn: Binding(get: { configuration.floatingIslands ?? (configuration.style == .islands) }, set: { configuration.floatingIslands = $0 }))
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

    private func amount(_ title: String, _ key: WritableKeyPath<WorldGenerationConfiguration, Double?>) -> some View {
        let value = configuration[keyPath: key] ?? 1
        return Stepper(title + " ×" + String(format: "%.1f", value), value: Binding(get: { value }, set: { configuration[keyPath: key] = $0 }), in: 0...3, step: 0.5)
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

enum Glass3DEditorKind: String, Identifiable { case characters, skills, bosses; var id: String { rawValue } }

/// Native glass in the world's UI layer: the lock-on reticle and the
/// selection's move handles (drag a handle along its axis; each step moves
/// one cell, a quarter cell for height). Only this layer redraws at 30 Hz.
@available(iOS 18.0, *)
struct Glass3DOverlay: View {
    @ObservedObject var glass: Glass3DNativeGlass
    let controller: Glass3DController
    @State private var dragging: (axis: Int, steps: Int)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if let point = glass.reticle {
                Circle().strokeBorder(Color.red.opacity(0.9), lineWidth: 2.5).frame(width: 46, height: 46)
                    .overlay(Circle().fill(Color.red).frame(width: 6, height: 6))
                    .hudGlass(.interactive, in: Circle())
                    .position(point).allowsHitTesting(false).accessibilityHidden(true)
            }
            if let gizmo = glass.gizmo {
                ForEach(0..<3, id: \.self) { axis in handle(axis, gizmo: gizmo) }
            }
        }
    }

    private func handle(_ axis: Int, gizmo: Glass3DNativeGlass.Gizmo) -> some View {
        let step = gizmo.axes[axis]
        let length = max(1, (step.x * step.x + step.y * step.y).squareRoot())
        let unit = CGPoint(x: step.x / length, y: step.y / length)
        let reach: CGFloat = 70
        let tip = CGPoint(x: gizmo.center.x + unit.x * reach, y: gizmo.center.y + unit.y * reach)
        let colors: [Color] = [.red, .green, .blue]
        let labels = ["X", "Z", "Y"]
        return Text(dragging?.axis == axis ? "\(dragging!.steps > 0 ? "+" : "")\(dragging!.steps)" : labels[axis])
            .font(.caption.weight(.bold)).foregroundStyle(colors[axis])
            .frame(width: 40, height: 40)
            .hudGlass(.interactive, in: Circle())
            .overlay(Circle().strokeBorder(colors[axis].opacity(0.8), lineWidth: 2))
            .position(tip)
            .gesture(DragGesture().onChanged { value in
                let along = value.translation.width * unit.x + value.translation.height * unit.y
                dragging = (axis, Int((along / length).rounded()))
            }.onEnded { _ in
                if let drag = dragging { controller.moveSelection(axis: drag.axis, steps: drag.steps) }
                dragging = nil
            })
            .accessibilityLabel(L10n.t("沿 \(labels[axis]) 轴移动", "Move along \(labels[axis])"))
    }
}

/// Small HUD badge while a game controller is connected.
private struct Glass3DGamepadBadge: View {
    @ObservedObject var gamepad: Glass3DGamepad
    var compact = false
    var body: some View {
        if let name = gamepad.connectedName {
            Group {
                if compact { Image(systemName: "gamecontroller.fill").frame(width: 28) }
                else { Label(name, systemImage: "gamecontroller.fill").frame(maxWidth: 120) }
            }
            .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            .accessibilityLabel(L10n.t("已连接手柄 \(name)", "Controller connected: \(name)"))
            .accessibilityIdentifier("glass3d-gamepad")
        }
    }
}
