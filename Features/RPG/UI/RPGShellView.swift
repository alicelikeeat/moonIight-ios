import SwiftUI
import SpriteKit

enum RPGEntryPage:String,Hashable {case world,story,editor,diagnostics}

extension AppCommand {
    var rpgPage:RPGEntryPage? {switch self {case .rpg:.world;case .rpgStory:.story;case .rpgEditor:.editor;case .rpgDiagnostics:.diagnostics;default:nil}}
}

struct RPGShellView: View {
    /// The app-wide session from WorldHost; this view never creates or
    /// destroys the world, it only activates and pauses it.
    @ObservedObject var session: RPGSession
    var initialPage=RPGEntryPage.world
    /// 完成: leave the sandbox for the previous page.
    var onExit: () -> Void = {}
    /// Control center navigation to another app page.
    var onNavigate: (AppTab) -> Void = { _ in }
    @State private var initialPresented=false
    /// A page requested from outside (search), opened once the world is ready.
    @State private var queuedPage: RPGEntryPage?
    @State private var toolPath:[RPGEntryPage]=[]
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var storyPlaying=false
    @State private var tools = false
    @State private var mediaDiagnostics = ""
    @State private var backgroundLayer = 0
    @State private var cellEditor: WorldEntity?
    @State private var controlCenter = false
    @State private var appSettings = false
    @State private var prologue: WorldPrologue?
    @AppStorage("moonlight.world.edgeSwipe") private var edgeSwipe = true
    @AppStorage("moonlight.world.autoplay") private var autoplay = true
    /// Tool the user picked while a draft was unconfirmed.
    @State private var pendingTool: RPGEditorTool?
    @State private var exitPrompt = false
    /// Glass shape editor (iOS 26+), opened from the shape tool or the control center.
    @State private var shapeEditor = false
    /// The 3D glass world on the same save (opens in design mode at launch).
    @State private var glassWorld = false
    @State private var glassWorldDesign = false
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            Group {
                if landscape { landscapeLayout(geometry.size) } else { portraitLayout(geometry.size) }
            }
            // The world stays visible under the control center but takes no
            // touches; the HUD fades out (see layouts).
            .allowsHitTesting(!controlCenter && prologue == nil)
            .accessibilityHidden(controlCenter)
            .overlay(alignment: .leading) { if landscape && edgeSwipe && session.ready && !controlCenter && !session.mapEditorActive { edgeSwipeZone(height: geometry.size.height) } }
        }
            .environment(\.rpgHUDState, RPGHUDState(inCombat: session.world.player.inCombat, editing: session.mapEditorActive))
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .overlay { worldBackdrop }
            .overlay {
                if controlCenter {
                    WorldControlCenterView(session: session, onClose: { closeControlCenter() }, onMapEditor: {
                        closeControlCenter(); session.enterMapEditor()
                    }, onNavigate: { tab in
                        closeControlCenter(); Task { if await session.saveBeforeExit() { onNavigate(tab) } }
                    }, onTools: { page in
                        closeControlCenter(); toolPath = page.map { [$0] } ?? []; tools = true
                    }, onAppSettings: { closeControlCenter(); appSettings = true },
                    onShapeEditor: GlassShapeEditorEntry.available ? { closeControlCenter(); shapeEditor = true } : nil,
                    onGlassWorld: { closeControlCenter(); glassWorld = true })
                    .transition(.opacity)
                }
            }
            .overlay { if let prologue { WorldPrologueView(prologue: prologue) { self.prologue = nil } } }
            .overlay(alignment: .top) {
                if let remaining = session.glassSampleRemaining {
                    Text(remaining > 0 ? L10n.t("玻璃采样 \(remaining) 秒 · \(session.glassMode.short) · 请正常移动与操作", "Glass sampling \(remaining)s · \(session.glassMode.short) · move and play normally") : L10n.t("玻璃采样即将开始", "Glass sampling starts soon"))
                        .font(.caption.monospacedDigit()).padding(.horizontal, 12).padding(.vertical, 6)
                        .moonSingleGlass(radius: 14).padding(.top, 52).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-glass-sample")
                }
            }
            .animation(reducedMotion ? nil : .easeOut(duration: 0.3), value: controlCenter)
            .onAppear {
                session.attachMediaStore(model.mediaStore); session.setReducedMotion(reducedMotion); session.activate()
                if let page = WorldHost.shared.pendingPage { WorldHost.shared.pendingPage = nil; queuedPage = page }
                if session.ready { presentInitial() }
                showPrologueIfNeeded()
                openGlassWorldAtLaunch()
            }
            .onDisappear { controlCenter = false; session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
            .sheet(isPresented: $tools) { toolPanel }
            .confirmationDialog(session.quickMenuCell.map { L10n.t("格子", "Cell") + " x \($0.x) · z \($0.z)" } ?? L10n.t("格子", "Cell"),
                                isPresented: Binding(get: { session.quickMenuCell != nil }, set: { if !$0 { session.quickMenuCell = nil } }), titleVisibility: .visible) {
                if let cell = session.quickMenuCell {
                    Button(L10n.t("编辑内容", "Edit Content")) { session.openPanel(cell) }
                    Button(L10n.t("复制此格", "Copy This Cell")) { session.copyCell(cell) }
                    if session.hasClipboard { Button(L10n.t("粘贴到这里（预览）", "Paste Here (Preview)")) { session.pastePreview(at: cell) } }
                    if session.entity(at: cell) != nil { Button(L10n.t("擦除（预览）", "Erase (Preview)"), role: .destructive) { session.eraseCell(cell) } }
                    Button(L10n.t("取消", "Cancel"), role: .cancel) {}
                }
            }
            .alert(L10n.t("有未确认的预览", "Unconfirmed preview"), isPresented: Binding(get: { pendingTool != nil }, set: { if !$0 { pendingTool = nil } })) {
                Button(L10n.t("确认提交", "Commit")) { session.confirmDraft(); if let tool = pendingTool { session.selectTool(tool) }; pendingTool = nil }
                Button(L10n.t("放弃预览", "Discard Preview"), role: .destructive) { session.discardDraft(); if let tool = pendingTool { session.selectTool(tool) }; pendingTool = nil }
                Button(L10n.t("继续编辑", "Keep Editing"), role: .cancel) { pendingTool = nil }
            } message: { Text(session.draftPlan?.summary ?? L10n.t("当前预览还没有写入地图。", "The preview hasn't been written to the map yet.")) }
            .alert(L10n.t("离开地图编辑？", "Leave the map editor?"), isPresented: $exitPrompt) {
                Button(L10n.t("确认提交并返回", "Commit and Leave")) { session.confirmDraft(); Task { try? await Task.sleep(nanoseconds: 400_000_000); session.exitMapEditor() } }
                Button(L10n.t("放弃预览并返回", "Discard and Leave"), role: .destructive) { session.discardDraft(); session.exitMapEditor() }
                Button(L10n.t("继续编辑", "Keep Editing"), role: .cancel) {}
            } message: { Text(L10n.t("有未确认的预览：", "Unconfirmed preview: ") + (session.draftPlan?.summary ?? "")) }
            .sheet(isPresented:$storyPlaying) {
                NavigationStack {RPGStoryView(session:session,travel:{anchor in storyPlaying=false;session.guideTo(anchor)},backTitle:L10n.t("返回世界", "Back to World"))}
            }
            .sheet(item: $cellEditor) { entity in
                NavigationStack { RPGCellEditorView(session: session, store: model.mediaStore, entity: entity) }.environmentObject(model)
            }
            .fullScreenCover(isPresented: $shapeEditor) {
                GlassShapeEditorEntry { outline in
                    // "Use on cells": the shape tool paints this outline next.
                    shapeEditor = false
                    session.shapeBrush = outline
                    if session.mapEditorActive { session.selectTool(.shape) }
                } onClose: { shapeEditor = false }
            }
            .onChange(of: shapeEditor) { _ in syncOverlay() }
            .fullScreenCover(isPresented: $glassWorld) {
                if #available(iOS 18.0, *) {
                    Glass3DScreen(session: session, startInDesign: glassWorldDesign) { glassWorld = false; glassWorldDesign = false }.environmentObject(model)
                } else {
                    VStack(spacing: 12) {
                        Text(L10n.t("3D 玻璃世界需要 iOS 18 或更高版本。", "The 3D glass world needs iOS 18 or later."))
                        Button(L10n.t("关闭", "Close")) { glassWorld = false }
                    }.padding()
                }
            }
            .onChange(of: glassWorld) { _ in syncOverlay() }
            .sheet(isPresented: $appSettings) {
                NavigationStack {
                    SettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { appSettings = false }.accessibilityIdentifier("world-app-settings-close") } }
                }.environmentObject(model).environmentObject(BackgroundStore.shared)
            }
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests") {
                    Text("媒体测试状态").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-media-probe").accessibilityValue(mediaDiagnostics)
                    Text("格子内容").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-cell-content").accessibilityValue(session.selectedCellSummary)
                    Text("玻璃实验").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-glass-state")
                        .accessibilityValue("mode=\(session.glassMode.rawValue);render=\(session.glassRender.label);samples=\(session.glassSamples.count)")
                    Text("世界格子").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-world-cells").accessibilityValue(session.cellContentSummaries)
                }
                #endif
            }
            .task {
                #if DEBUG
                guard ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests") else{return}
                while !Task.isCancelled {
                    mediaDiagnostics="players=\(session.media?.decoderCount ?? 0);frames=\(session.media?.frameCount ?? 0);advancing=\(session.media?.advancing ?? 0);posters=\(session.media?.posterCount ?? 0);muted=\(session.media?.muted == false ? 0 : 1);completed=\(session.media?.completedCount ?? 0);cache=\(session.media?.cacheBytes ?? 0);global=\(CardMediaCoordinator.ownedPlayers)"
                    try? await Task.sleep(nanoseconds:500_000_000)
                }
                #endif
            }
            .onChange(of:session.ready){ if $0 { presentInitial(); showPrologueIfNeeded(); openGlassWorldAtLaunch() } }
            .onChange(of: prologue == nil) { done in if done { openGlassWorldAtLaunch() } }
            .onChange(of:session.world.id){ _ in showPrologueIfNeeded() }
            .onChange(of: tools) { _ in syncOverlay() }
            .onChange(of:storyPlaying){ _ in syncOverlay() }
            .onChange(of: cellEditor?.id) { _ in syncOverlay() }
            .onChange(of: controlCenter) { _ in syncOverlay() }
            .onChange(of: appSettings) { _ in syncOverlay() }
            .onChange(of:session.pendingStory){if $0{storyPlaying=true;session.acknowledgeStory()}}
            .onChange(of:reducedMotion){session.setReducedMotion($0)}
            .onChange(of: session.world.backgroundBindingIDs.count) { count in backgroundLayer=min(backgroundLayer,min(2,count)) }
    }

    // MARK: Layouts

    /// Portrait: the original column layout. Used on portrait pages, when the
    /// rotation request is refused, and by the existing portrait UI tests.
    @ViewBuilder private func portraitLayout(_ size: CGSize) -> some View {
        if session.mapEditorActive { portraitEditor(size) } else { portraitPlay }
    }

    private var portraitPlay: some View {
        VStack(spacing: 8) {
            header
            statusRow
            sceneView.clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment:.bottomLeading){if session.ready && showsJoystick {stickCluster(size: 112).padding(8)}}
                .overlay(alignment:.bottomTrailing){if session.ready && !session.mapEditorActive {combatCluster.padding(8)}}
            perspectiveRow
            RPGCombatHUDView(model:session.combatHUD,session:session)
            Text(session.notice).font(.caption).accessibilityIdentifier("rpg-status")
            actionRow
        }.buttonStyle(MoonGlassButtonStyle()).padding(12).padding(.bottom, 82)
            .opacity(controlCenter ? 0.35 : 1)
    }

    /// Portrait editor: toolbar, map, then either the cell panel or the
    /// tool bars below the map, so nothing covers anything else.
    private func portraitEditor(_ size: CGSize) -> some View {
        VStack(spacing: 8) {
            editorToolbar
            editorNotice
            sceneView.clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .bottomLeading) { if session.ready && showsJoystick { stickCluster(size: 104).padding(8) } }
            if let point = session.panelPoint {
                cellPanel(point).frame(height: max(260, size.height * 0.46))
            } else {
                editorBars
            }
        }.padding(12).padding(.bottom, 82)
            .opacity(controlCenter ? 0.35 : 1)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.2), value: session.panelPoint)
    }

    /// Landscape: the world fills the screen and the HUD floats over it.
    @ViewBuilder private func landscapeLayout(_ size: CGSize) -> some View {
        if session.mapEditorActive { landscapeEditor(size) } else { landscapePlay }
    }

    /// Landscape editor: the cell panel takes its own column on the right;
    /// the top bar, notice and tool bars use only the space left of it.
    private func landscapeEditor(_ size: CGSize) -> some View {
        ZStack {
            sceneView.ignoresSafeArea()
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 6) {
                    editorToolbar
                    editorNotice
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 10) {
                        if session.ready && showsJoystick { stickCluster(size: 120) }
                        Spacer(minLength: 0)
                        editorBars.frame(maxWidth: 640)
                        Spacer(minLength: 0)
                    }
                }
                if let point = session.panelPoint {
                    cellPanel(point).frame(width: min(340, size.width * 0.4))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .opacity(controlCenter ? 0 : 1)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.2), value: session.panelPoint)
        }
    }

    private var landscapePlay: some View {
        ZStack {
            sceneView.ignoresSafeArea()
            VStack(spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.worldTitle).font(.subheadline.weight(.semibold))
                            statusRow
                        }.padding(.horizontal, 12).padding(.vertical, 6).hudGlass(.light, radius: 14).fixedSize()
                        if session.ready { RPGVitalsBar(hud: session.combatHUD) }
                    }
                    Spacer(minLength: 8)
                    headerButtons
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 10) {
                    if session.ready && showsJoystick { stickCluster(size: 128) }
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        Text(session.notice).font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 4)
                            .hudGlass(.light, radius: 10).accessibilityIdentifier("rpg-status")
                        RPGCombatHUDView(model:session.combatHUD,session:session)
                        actionRow
                        perspectiveRow
                    }.frame(maxWidth: 420)
                    Spacer(minLength: 0)
                    if session.ready { combatCluster }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .opacity(controlCenter ? 0 : 1)
        }.buttonStyle(MoonGlassButtonStyle())
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text(session.world.isCreativeCopy ? L10n.t("创作副本", "Creative Copy") : L10n.t("自由媒体沙盒", "Media Sandbox")).font(.headline)
            Spacer()
            headerButtons
        }.frame(minHeight: 44)
    }

    private var headerButtons: some View {
        HStack {
            Button(L10n.t("校验", "Check")) { session.validateRoundTrip() }.accessibilityIdentifier("rpg-validate").disabled(!session.ready)
            Button(L10n.t("编辑", "Edit")) { session.enterMapEditor() }.accessibilityIdentifier("rpg-map-editor").disabled(!session.ready)
            Button("3D") { glassWorld = true }.accessibilityIdentifier("rpg-glass-world").disabled(!session.ready)
            Button(L10n.t("工具", "Tools")) { toolPath=[];tools = true }.accessibilityIdentifier("rpg-tools")
            Button(L10n.t("完成", "Done")) { Task { if await session.saveBeforeExit() { onExit() } } }.accessibilityIdentifier("rpg-close")
            Button { openControlCenter() } label: { Image(systemName: "square.grid.2x2").frame(width: 24, height: 24) }
                .accessibilityLabel(L10n.t("世界控制中心", "World Control Center")).accessibilityIdentifier("rpg-menu")
        }
    }

    /// Draft bar, tool options and the bottom toolbar.
    private var editorBars: some View {
        VStack(spacing: 6) {
            RPGDraftBar(session: session)
            RPGEditorOptionsBar(session: session, store: model.mediaStore, openShapeEditor: GlassShapeEditorEntry.available ? { shapeEditor = true } : nil)
            RPGEditorToolBar(session: session) { tool in
                if session.draft != nil && tool != session.editorTool { pendingTool = tool } else { session.selectTool(tool) }
            }
        }
        .buttonStyle(.borderless)
    }

    /// One-line status under the top bar; it never covers the tool bars.
    private var editorNotice: some View {
        Text(session.notice).font(.caption).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .moonLiquidSurface(.capsule)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityIdentifier("rpg-status")
    }

    private func cellPanel(_ point: SurfacePoint) -> some View {
        RPGCellPanel(session: session, store: model.mediaStore, point: point) { session.panelPoint = nil }
    }

    private func editorIcon(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.borderless).accessibilityLabel(label).accessibilityIdentifier(id)
    }

    /// UI tests drive the original eight buttons; everyone else gets the stick.
    private var usesTestPad: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests")
        #else
        return false
        #endif
    }
    @ViewBuilder private func stickCluster(size: CGFloat) -> some View {
        if usesTestPad { movementPad.buttonStyle(MoonGlassButtonStyle()) } else {
            HStack(alignment: .bottom, spacing: 6) {
                RPGJoystick(session: session, size: size)
                Button { session.returnToSpawn() } label: {
                    Image(systemName: "location.circle.fill").font(.system(size: 16, weight: .semibold)).frame(width: 38, height: 38).contentShape(Circle())
                }
                .buttonStyle(RPGPressStyle()).hudGlass(.interactive, in: Circle())
                .accessibilityLabel(L10n.t("回到出生地", "Return to Spawn")).accessibilityIdentifier("rpg-spawn")
            }
        }
    }
    @ViewBuilder private var combatCluster: some View {
        if usesTestPad { combatButtons.buttonStyle(MoonGlassButtonStyle()) } else { RPGCombatPad(session: session, hud: session.combatHUD) }
    }

    /// Free edit hides the joystick; character build and play show it.
    private var showsJoystick: Bool { !session.mapEditorActive || session.editorMode == .character }

    /// Map editor top bar (task E): compact icons, no capsule buttons.
    private var editorToolbar: some View {
        HStack(spacing: 4) {
            editorIcon("chevron.backward", L10n.t("返回沙盒", "Back to Sandbox"), id: "rpg-editor-exit") {
                if session.draft != nil { exitPrompt = true } else { session.exitMapEditor() }
            }
            Picker(L10n.t("编辑模式", "Edit Mode"), selection: $session.editorMode) {
                ForEach(RPGEditorMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 220).accessibilityIdentifier("rpg-editor-mode")
            Spacer(minLength: 6)
            Text(session.editorCoordinate.map { "\($0.x), \($0.z)" } ?? "—").font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).lineLimit(1).fixedSize()
                .accessibilityLabel(session.editorCoordinate.map { "x \($0.x) · z \($0.z)" } ?? "—")
                .accessibilityIdentifier("rpg-editor-coordinate")
            editorIcon("arrow.uturn.backward", L10n.t("撤销", "Undo"), id: "rpg-editor-undo") { session.undo() }
                .disabled(session.world.undo.isEmpty || session.working)
            editorIcon("arrow.uturn.forward", L10n.t("重做", "Redo"), id: "rpg-editor-redo") { session.redo() }
                .disabled(session.world.redo.isEmpty || session.working)
            Image(systemName: saveSymbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(saveTint).frame(width: 28, height: 34)
                .accessibilityElement().accessibilityLabel(session.saveState.title).accessibilityIdentifier("rpg-editor-save-state")
            editorIcon("gearshape", L10n.t("设置", "Settings"), id: "rpg-editor-settings") { toolPath = []; tools = true }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .editorSurface(radius: 18)
    }
    private var saveSymbol: String {
        switch session.saveState { case .saved: "checkmark.icloud"; case .saving: "arrow.triangle.2.circlepath"; case .unsaved: "pencil"; case .failed: "exclamationmark.triangle" }
    }
    private var saveTint: Color {
        if case .failed = session.saveState { return .orange }
        return .secondary
    }

    private var statusRow: some View {
        HStack {
            Text(L10n.t("256 × 256 · \(session.loadedChunks)/64 区块", "256 × 256 · \(session.loadedChunks)/64 chunks")).font(.caption)
                .accessibilityIdentifier("rpg-loaded-chunks").accessibilityValue(String(session.loadedChunks))
            Text(L10n.t("可见 \(session.visibleCells) 格", "\(session.visibleCells) visible")).font(.caption).accessibilityIdentifier("rpg-visible-cells").accessibilityValue(String(session.visibleCells))
            Text(L10n.t("自建 \(session.world.entities.count)", "Built \(session.world.entities.count)")).font(.caption).accessibilityIdentifier("rpg-placed-count").accessibilityValue(String(session.world.entities.count))
            Spacer(minLength: 0)
            Text(positionLabel).font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-position")
        }
    }

    @ViewBuilder private var sceneView: some View {
        Group {
            if !session.ready, !session.recoveryChoices.isEmpty {
                ScrollView {VStack(spacing:12){
                    Text(L10n.t("选择保留的世界", "Choose a Saved World")).font(.headline)
                    ForEach(session.recoveryChoices){choice in
                        Button((choice.creative ? L10n.t("创作副本", "Creative Copy"):L10n.t("原世界", "Original World"))+" · Seed \(choice.seed) · 修订 \(choice.revision)"){session.recoverWorld(choice.id)}
                            .accessibilityIdentifier("rpg-recover-"+choice.id)
                    }
                }.padding()}
            } else if !session.ready, let error = session.loadError {
                // No blank screen: explain and offer a way forward. Creating
                // a world never deletes the unreadable one.
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(L10n.t("世界无法打开", "Can't open the world")).font(.headline).accessibilityIdentifier("world-load-failed")
                    Text(error).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.t("重试", "Retry")) { session.loadWorld() }.accessibilityIdentifier("world-load-retry")
                        Button(L10n.t("创建新世界", "Create New World")) { session.createWorld() }.accessibilityIdentifier("world-load-create")
                    }
                    Text(L10n.t("原存档文件会保留，不会被覆盖。", "The original save file is kept and never overwritten.")).font(.caption2).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !session.ready {
                ProgressView(L10n.t("正在打开最近的世界…", "Opening your latest world…")).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("world-loading")
            } else if session.world.player.perspective == .topDown { SpriteView(scene: session.scene, options: [.allowsTransparency]) }
            else { SpriteView(scene: session.sideScene, options: [.allowsTransparency]) }
        }.accessibilityLabel(L10n.t("世界场景", "World Scene"))
            .overlay { if session.ready, !controlCenter { RPGGridGlassOverlay(session: session) } }
            .overlay { if session.ready, !controlCenter, let rect = session.selectionRect { RPGSelectionGlass(rect: rect, outline: session.selectedEntity?.outline) } }
    }

    private var perspectiveRow: some View {
        HStack {
            Button(session.world.player.perspective == .topDown ? L10n.t("进入侧视", "Side View") : L10n.t("返回俯视", "Top-Down View")) { session.toggleProjection() }
                .accessibilityIdentifier("rpg-perspective")
            Spacer()
            Text(session.world.player.perspective == .topDown ? L10n.t("俯视地表", "Top-Down") : L10n.t("侧视切片", "Side Slice"))
                .font(.caption).accessibilityIdentifier("rpg-projection-evidence").accessibilityValue(session.projectionEvidence)
        }
    }

    @ViewBuilder private var actionRow: some View {
        if session.selected != nil || !session.world.undo.isEmpty || !session.world.redo.isEmpty {
            HStack {
                Button(L10n.t("放置", "Place")) { session.placeSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-place")
                Button(L10n.t("挖掘", "Dig")) { session.hitSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-hit")
                Button(L10n.t("内容", "Content")) { cellEditor = session.selectedEntity }.disabled(session.selectedEntity == nil).accessibilityIdentifier("rpg-edit-cell")
                Button(L10n.t("撤销", "Undo")) { session.undo() }.disabled(session.world.undo.isEmpty).accessibilityIdentifier("rpg-undo")
                Button(L10n.t("重做", "Redo")) { session.redo() }.disabled(session.world.redo.isEmpty).accessibilityIdentifier("rpg-redo")
            }.disabled(!session.ready || session.working)
        }
    }

    /// While the control center is open the world stays drawn behind it;
    /// a light scrim keeps text readable without hiding the world.
    @ViewBuilder private var worldBackdrop: some View {
        if controlCenter { Color.black.opacity(0.12).ignoresSafeArea().allowsHitTesting(false) }
    }

    /// Left-edge swipe opens the control center. Only the upper part of the
    /// edge listens, so the movement pad in the lower left is never touched.
    private func edgeSwipeZone(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 18, height: height * 0.55).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                    if value.translation.width > 50 && abs(value.translation.height) < 80 { openControlCenter() }
                })
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }.padding(.top, 60)
    }

    // MARK: State

    private func openControlCenter() {
        guard session.ready, !controlCenter else { return }
        controlCenter = true
    }
    private func closeControlCenter() { controlCenter = false }

    /// Game input and scene simulation stop whenever anything covers the
    /// world; they resume only when every cover is gone.
    private func syncOverlay() {
        session.setOverlay(tools || storyPlaying || cellEditor != nil || controlCenter || appSettings || shapeEditor || glassWorld)
    }

    /// Once per app launch the 3D world opens straight into design mode
    /// (setting in the 3D world's gear menu; iOS 18+).
    private func openGlassWorldAtLaunch() {
        guard #available(iOS 18.0, *), Glass3DLaunch.shouldOpen, session.ready, prologue == nil, !glassWorld, !tools else { return }
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--scroll-ui-tests") || arguments.contains("--rpg-ui-tests") { return }
        #endif
        Glass3DLaunch.opened = true
        glassWorldDesign = true
        glassWorld = true
    }

    private func showPrologueIfNeeded() {
        guard session.ready, prologue == nil, WorldHost.shared.needsPrologue(session.world.id) else { return }
        WorldHost.shared.markPrologue(session.world.id)
        #if DEBUG
        // Existing UI tests tap the world immediately; only opted-in tests see the prologue.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--scroll-ui-tests") && !arguments.contains("--prologue-ui-tests") { return }
        #endif
        prologue = WorldPrologue(title: session.worldTitle, quest: session.questSummary, mode: session.modeTitle, perspective: session.perspectiveTitle)
    }


    private func presentInitial(){
        if let page = queuedPage {
            queuedPage = nil
            if page != .world { toolPath=[page]; tools=true }
            return
        }
        guard !initialPresented,initialPage != .world else{return}
        initialPresented=true;toolPath=[initialPage];tools=true
    }
    @ViewBuilder private func initialDestination(_ page:RPGEntryPage)->some View {
        switch page {
        case .story:RPGStoryView(session:session,travel:{anchor in tools=false;session.guideTo(anchor)})
        case .editor:RPGStoryEditorView(session:session)
        case .diagnostics:RPGDiagnosticsView(session:session,onRunSample:{tools=false;session.startGlassSample()})
        case .world:EmptyView()
        }
    }
    private var movementPad:some View {
        VStack(spacing:0) {
            HStack(spacing:0){moveButton("↖",-1,1);moveButton("↑",0,1);moveButton("↗",1,1)}
            HStack(spacing:0){moveButton("←",-1,0);Button("◎"){session.returnToSpawn()}.frame(width:44,height:44).accessibilityLabel(L10n.t("回到出生地", "Return to Spawn"));moveButton("→",1,0)}
            HStack(spacing:0){moveButton("↙",-1,-1);moveButton("↓",0,-1);moveButton("↘",1,-1)}
        }.disabled(!session.ready || session.working)
    }
    private var combatButtons:some View {
        VStack(spacing:2) {
            if session.world.player.health==0 {Button(L10n.t("安全复苏", "Revive Safely")){session.revive()}.accessibilityIdentifier("rpg-revive")}
            else {
                Button(L10n.t("攻击", "Attack")){session.combatAction(.attack)}.accessibilityIdentifier("rpg-attack")
                Button(L10n.t("范围技能", "Area Skill")){session.combatAction(.skill)}.accessibilityIdentifier("rpg-skill")
                Button(session.world.player.perspective == .side ? L10n.t("冲刺", "Dash"):L10n.t("翻滚", "Roll")){session.combatAction(.roll)}.accessibilityIdentifier("rpg-roll")
            }
        }.disabled(!session.ready || session.working)
    }
    private var positionLabel: String {
        if session.world.player.perspective == .side, let point = session.world.player.side { return "u \(point.horizontal) · y \(point.height)" }
        return "x \(session.world.player.surface.x) · z \(session.world.player.surface.z)"
    }
    private var toolPanel: some View {
        NavigationStack(path:$toolPath) {
            Form { Group {
                Picker(L10n.t("模式", "Mode"), selection: Binding(get: { session.world.player.mode }, set: { session.setMode($0) })) {
                    Text(L10n.t("冒险", "Adventure")).tag(RPGGameMode.adventure); Text(L10n.t("创造", "Creative")).tag(RPGGameMode.creative)
                }.pickerStyle(.segmented).accessibilityIdentifier("rpg-mode")
                Button(L10n.t("前往双界入口（创造）", "Go to the Portal (Creative)")) { session.travelToTemple() }.accessibilityIdentifier("rpg-temple")
                Button(L10n.t("选择映射区空格", "Pick an Empty Mapped Cell")) { session.chooseMappedSite() }.accessibilityIdentifier("rpg-choose-mapped")
                Picker(L10n.t("方块", "Block"), selection: $session.definition) { ForEach(BlockDefinition.all) { Text($0.name).tag($0.id) } }
                Picker(L10n.t("地表操作", "Surface Action"), selection: $session.tool) {
                    Text(L10n.t("选择", "Select")).tag(RPGTool.select); Text(L10n.t("连续绘制", "Paint")).tag(RPGTool.paint); Text(L10n.t("删除", "Delete")).tag(RPGTool.erase)
                }
                Text(L10n.t("木材", "Wood") + " \(session.world.inventory["wood",default:0]) · " + L10n.t("石材", "Stone") + " \(session.world.inventory["stone",default:0])").font(.caption)
                Button(L10n.t("选取附近空地", "Pick a Nearby Empty Cell")) { session.chooseSite() }.accessibilityIdentifier("rpg-choose-site")
                Section(L10n.t("剧情与探索", "Story & Exploration")) {
                    NavigationLink(L10n.t("剧情与任务", "Story & Quests")) { RPGStoryView(session:session,travel:{ anchor in tools = false; session.guideTo(anchor) }) }.accessibilityIdentifier("rpg-story")
                    NavigationLink(L10n.t("剧情编辑器", "Story Editor")) { RPGStoryEditorView(session:session) }.accessibilityIdentifier("rpg-story-editor")
                    ForEach(RPGAnchorID.allCases,id:\.self) { anchor in
                        Button(L10n.t("沿通路前往", "Walk to ")+anchor.title) { tools = false; session.guideTo(anchor) }
                    }
                }
                Section(L10n.t("运行与辅助", "Runtime & Help")) {
                    NavigationLink(L10n.t("运行诊断", "Diagnostics")) {RPGDiagnosticsView(session:session,onRunSample:{tools=false;session.startGlassSample()})}.accessibilityIdentifier("rpg-diagnostics")
                    Text("Seed \(session.world.seed) · " + L10n.t("系统减少动态效果：", "Reduce Motion: ") + (reducedMotion ? L10n.t("开启", "On") : L10n.t("关闭", "Off"))).font(.caption)
                    if let target=session.selectedEntity {
                        NavigationLink(L10n.t("选中方块行为", "Selected Block Behavior")) {RPGBehaviorEditorView(session:session,target:target)}.accessibilityIdentifier("rpg-behavior-editor")
                    }
                }
                Section(L10n.t("战斗与装备", "Combat & Gear")) {
                    Button(L10n.t("开启训练遭遇", "Start Training Encounter")) { session.trainingEncounter() }.accessibilityIdentifier("rpg-training")
                    Button(L10n.t("制作 / 装备月刃（木材 4）", "Craft / Equip Moon Blade (Wood 4)")) { session.equip(.moonBlade) }
                    Button(L10n.t("制作 / 装备石甲（石材 6）", "Craft / Equip Stone Armor (Stone 6)")) { session.equip(.stoneArmor) }
                    Button(L10n.t("卸下装备", "Unequip")) { session.equip(.none) }
                    Text(L10n.t("俯视八向攻击、范围技能与翻滚；侧视支持空中攻击和冲刺。训练会开始真实战斗，战斗期间不能切换视角。", "Top-down: 8-way attacks, area skill and roll. Side view: air attacks and dash. Training starts a real fight; you can't switch views during combat.")) .font(.caption)
                }
                Section(L10n.t("画面与玻璃", "Display & Glass")) {
                    Picker(L10n.t("玻璃画质", "Glass Quality"), selection: $session.glassQuality) {
                        ForEach(RPGGlassQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("rpg-glass-quality")
                    Text(L10n.t("所有可见格子都保留基础玻璃；高质量增加流动高光。低电量模式和减少动态效果时只显示基础玻璃。当前实际：", "Every visible cell keeps its base glass; higher quality adds a moving highlight. Low Power Mode and Reduce Motion show base glass only. In use: ") + session.effectiveGlassQuality.title + L10n.t(" · 可见 \(session.visibleCells) 格（上限 \(RPGCameraRules.visibleBudget)）", " · \(session.visibleCells) cells visible (limit \(RPGCameraRules.visibleBudget))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.t("媒体外观", "Media Look")) {
                    NavigationLink(L10n.t("角色图片 / 视频", "Character Image / Video")) { RPGMediaEditorView(session:session,store:model.mediaStore,owner:.player) }
                        .accessibilityIdentifier("rpg-media-player")
                    Picker(L10n.t("背景层", "Background Layer"),selection:$backgroundLayer){ForEach(0..<min(3,session.world.backgroundBindingIDs.count+1),id:\.self){Text(L10n.t("第 \($0+1) 层", "Layer \($0+1)")).tag($0)}}
                    NavigationLink(L10n.t("背景图片 / 视频", "Background Image / Video")) { RPGMediaEditorView(session:session,store:model.mediaStore,owner:.background(backgroundLayer)) }
                        .accessibilityIdentifier("rpg-media-background")
                    if let entity=session.selectedEntity {
                        NavigationLink(L10n.t("选中方块图片 / 视频", "Selected Block Image / Video")) { RPGMediaEditorView(session:session,store:model.mediaStore,owner:.entity(entity.id)) }
                            .accessibilityIdentifier("rpg-media-block")
                    }
                    Toggle(L10n.t("可见区域自动播放", "Autoplay Visible Cells"), isOn: $autoplay).accessibilityIdentifier("rpg-autoplay")
                        .onChange(of: autoplay) { _ in session.media?.retry() }
                    Stepper(L10n.t("同时预览：\(session.world.videoBudget) 路", "Live previews: \(session.world.videoBudget)"),value:Binding(get:{session.world.videoBudget},set:{session.setVideoBudget($0)}),in:0...2)
                    Text(L10n.t("默认静音。角色、背景与可见互动素材共享预算，其他显示封面或默认外观。3–4 路待实机验证后再评估。", "Muted by default. Character, background and visible media share the budget; the rest show a poster or default look. 3–4 streams await device testing."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.t("重新启用预览", "Re-enable Previews")){session.media?.retry()}.accessibilityIdentifier("rpg-media-retry")
                }
                Section(L10n.t("范围与复制", "Range & Copy")) {
                    Button(L10n.t("标记起点", "Mark Start")) { session.markRange() }
                    Button(L10n.t("填充到选中格", "Fill to Selection")) { session.fillRange() }.disabled(session.rangeStart == nil || session.selected == nil)
                    Button(L10n.t("复制范围或单格", "Copy Range or Cell")) { session.copyRange() }.disabled(session.selected == nil)
                    Button(L10n.t("粘贴到选中格", "Paste at Selection")) { session.paste() }.disabled(!session.hasClipboard || session.selected == nil)
                    Button(L10n.t("删除选中方块（创造）", "Delete Selected Block (Creative)")) { session.hitSelected(force: true) }.disabled(session.world.player.mode != .creative || session.selected == nil)
                }
                Section(L10n.t("存档与保护", "Saves & Protection")) {
                    Button(L10n.t("保存世界", "Save World")) { session.save() }.accessibilityIdentifier("rpg-save")
                    Button(L10n.t("创建独立创作副本", "Create Creative Copy")) { session.creativeCopy() }.accessibilityIdentifier("rpg-creative-copy")
                    if session.world.parentWorldID != nil { Button(L10n.t("返回原世界", "Back to Original World")) { session.returnToOriginal() }.accessibilityIdentifier("rpg-return-original") }
                    Text(L10n.t("官方锚点与通路受保护。创造模式免资源成本，但只有独立创作副本可修改保护区。", "Official anchors and paths are protected. Creative mode costs nothing, but only a creative copy can change protected areas."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }.moonLiquidList().disabled(!session.ready || session.working).navigationTitle(L10n.t("沙盒工具", "Sandbox Tools"))
                .navigationDestination(for:RPGEntryPage.self){initialDestination($0)}
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { tools = false }.accessibilityIdentifier("rpg-tools-close") } }
        }.buttonStyle(MoonGlassButtonStyle())
    }
    private func moveButton(_ title: String, _ dx: Int, _ dz: Int) -> some View {
        Button(title) { session.move(dx: dx, dz: dz) }.frame(width: 44, height: 44)
            .accessibilityLabel("移动 \(dx), \(dz)").accessibilityIdentifier("rpg-move-\(dx)-\(dz)")
            // The world container's accessibilityHidden does not reach these.
            .accessibilityHidden(controlCenter)
    }
}

private struct RPGCombatHUDView: View {
    @ObservedObject var model:RPGCombatHUDModel
    let session:RPGSession
    var body:some View {Text(model.text).font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-combat-stats")}
}
