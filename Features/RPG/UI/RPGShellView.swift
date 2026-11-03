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
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            Group {
                if landscape { landscapeLayout } else { portraitLayout }
            }
            // The world stays visible under the control center but takes no
            // touches; the HUD fades out (see layouts).
            .allowsHitTesting(!controlCenter && prologue == nil)
            .accessibilityHidden(controlCenter)
            .overlay(alignment: .leading) { if landscape && edgeSwipe && session.ready && !controlCenter { edgeSwipeZone(height: geometry.size.height) } }
        }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .overlay { worldBackdrop }
            .overlay {
                if controlCenter {
                    WorldControlCenterView(session: session, onClose: { closeControlCenter() }, onNavigate: { tab in
                        closeControlCenter(); Task { if await session.saveBeforeExit() { onNavigate(tab) } }
                    }, onTools: { page in
                        closeControlCenter(); toolPath = page.map { [$0] } ?? []; tools = true
                    }, onAppSettings: { closeControlCenter(); appSettings = true })
                    .transition(.opacity)
                }
            }
            .overlay { if let prologue { WorldPrologueView(prologue: prologue) { self.prologue = nil } } }
            .animation(reducedMotion ? nil : .easeOut(duration: 0.3), value: controlCenter)
            .onAppear {
                session.attachMediaStore(model.mediaStore); session.setReducedMotion(reducedMotion); session.activate()
                if let page = WorldHost.shared.pendingPage { WorldHost.shared.pendingPage = nil; queuedPage = page }
                if session.ready { presentInitial() }
                showPrologueIfNeeded()
            }
            .onDisappear { controlCenter = false; session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
            .sheet(isPresented: $tools) { toolPanel }
            .sheet(isPresented:$storyPlaying) {
                NavigationStack {RPGStoryView(session:session,travel:{anchor in storyPlaying=false;session.guideTo(anchor)},backTitle:"返回世界")}
            }
            .sheet(item: $cellEditor) { entity in
                NavigationStack { RPGCellEditorView(session: session, store: model.mediaStore, entity: entity) }.environmentObject(model)
            }
            .sheet(isPresented: $appSettings) {
                NavigationStack {
                    SettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { appSettings = false }.accessibilityIdentifier("world-app-settings-close") } }
                }.environmentObject(model).environmentObject(BackgroundStore.shared)
            }
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests") {
                    Text("媒体测试状态").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-media-probe").accessibilityValue(mediaDiagnostics)
                    Text("格子内容").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-cell-content").accessibilityValue(session.selectedCellSummary)
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
            .onChange(of:session.ready){ if $0 { presentInitial(); showPrologueIfNeeded() } }
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
    private var portraitLayout: some View {
        VStack(spacing: 8) {
            header
            statusRow
            sceneView.clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment:.bottomLeading){if session.ready{movementPad.padding(6)}}
                .overlay(alignment:.bottomTrailing){if session.ready{combatButtons.padding(6)}}
            perspectiveRow
            RPGCombatHUDView(model:session.combatHUD,session:session)
            Text(session.notice).font(.caption).accessibilityIdentifier("rpg-status")
            actionRow
        }.buttonStyle(MoonGlassButtonStyle()).padding(12).padding(.bottom, 82)
            .opacity(controlCenter ? 0.35 : 1)
    }

    /// Landscape: the world fills the screen and the HUD floats over it.
    private var landscapeLayout: some View {
        ZStack {
            sceneView.ignoresSafeArea()
            VStack(spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.worldTitle).font(.subheadline.weight(.semibold))
                        statusRow
                    }.padding(.horizontal, 12).padding(.vertical, 6).moonSingleGlass(radius: 14).fixedSize()
                    Spacer(minLength: 8)
                    headerButtons
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 10) {
                    if session.ready { movementPad }
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        Text(session.notice).font(.caption).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 4)
                            .moonSingleGlass(radius: 10).accessibilityIdentifier("rpg-status")
                        RPGCombatHUDView(model:session.combatHUD,session:session)
                        actionRow
                        perspectiveRow
                    }.frame(maxWidth: 420)
                    Spacer(minLength: 0)
                    if session.ready { combatButtons }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .opacity(controlCenter ? 0 : 1)
        }.buttonStyle(MoonGlassButtonStyle())
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Text(session.world.isCreativeCopy ? "创作副本" : "自由媒体沙盒").font(.headline)
            Spacer()
            headerButtons
        }.frame(minHeight: 44)
    }

    private var headerButtons: some View {
        HStack {
            Button("校验") { session.validateRoundTrip() }.accessibilityIdentifier("rpg-validate").disabled(!session.ready)
            Button("工具") { toolPath=[];tools = true }.accessibilityIdentifier("rpg-tools")
            Button("完成") { Task { if await session.saveBeforeExit() { onExit() } } }.accessibilityIdentifier("rpg-close")
            Button { openControlCenter() } label: { Image(systemName: "square.grid.2x2").frame(width: 24, height: 24) }
                .accessibilityLabel("世界控制中心").accessibilityIdentifier("rpg-menu")
        }
    }

    private var statusRow: some View {
        HStack {
            Text("256 × 256 · \(session.loadedChunks)/64 区块").font(.caption)
                .accessibilityIdentifier("rpg-loaded-chunks").accessibilityValue(String(session.loadedChunks))
            Text("自建 \(session.world.entities.count)").font(.caption).accessibilityIdentifier("rpg-placed-count").accessibilityValue(String(session.world.entities.count))
            Spacer(minLength: 0)
            Text(positionLabel).font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-position")
        }
    }

    @ViewBuilder private var sceneView: some View {
        Group {
            if !session.ready, !session.recoveryChoices.isEmpty {
                ScrollView {VStack(spacing:12){
                    Text("选择保留的世界").font(.headline)
                    ForEach(session.recoveryChoices){choice in
                        Button((choice.creative ? "创作副本":"原世界")+" · Seed \(choice.seed) · 修订 \(choice.revision)"){session.recoverWorld(choice.id)}
                            .accessibilityIdentifier("rpg-recover-"+choice.id)
                    }
                }.padding()}
            } else if !session.ready, let error = session.loadError {
                // No blank screen: explain and offer a way forward. Creating
                // a world never deletes the unreadable one.
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("世界无法打开").font(.headline).accessibilityIdentifier("world-load-failed")
                    Text(error).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    HStack {
                        Button("重试") { session.loadWorld() }.accessibilityIdentifier("world-load-retry")
                        Button("创建新世界") { session.createWorld() }.accessibilityIdentifier("world-load-create")
                    }
                    Text("原存档文件会保留，不会被覆盖。").font(.caption2).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !session.ready {
                ProgressView("正在打开最近的世界…").frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("world-loading")
            } else if session.world.player.perspective == .topDown { SpriteView(scene: session.scene, options: [.allowsTransparency]) }
            else { SpriteView(scene: session.sideScene, options: [.allowsTransparency]) }
        }.accessibilityLabel("世界场景")
            .overlay { if session.ready, !controlCenter, let rect = session.selectionRect { RPGSelectionGlass(rect: rect) } }
    }

    private var perspectiveRow: some View {
        HStack {
            Button(session.world.player.perspective == .topDown ? "进入侧视" : "返回俯视") { session.toggleProjection() }
                .accessibilityIdentifier("rpg-perspective")
            Spacer()
            Text(session.world.player.perspective == .topDown ? "俯视地表" : "侧视切片")
                .font(.caption).accessibilityIdentifier("rpg-projection-evidence").accessibilityValue(session.projectionEvidence)
        }
    }

    @ViewBuilder private var actionRow: some View {
        if session.selected != nil || !session.world.undo.isEmpty || !session.world.redo.isEmpty {
            HStack {
                Button("放置") { session.placeSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-place")
                Button("挖掘") { session.hitSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-hit")
                Button("内容") { cellEditor = session.selectedEntity }.disabled(session.selectedEntity == nil).accessibilityIdentifier("rpg-edit-cell")
                Button("撤销") { session.undo() }.disabled(session.world.undo.isEmpty).accessibilityIdentifier("rpg-undo")
                Button("重做") { session.redo() }.disabled(session.world.redo.isEmpty).accessibilityIdentifier("rpg-redo")
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
        session.setOverlay(tools || storyPlaying || cellEditor != nil || controlCenter || appSettings)
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
        case .diagnostics:RPGDiagnosticsView(session:session)
        case .world:EmptyView()
        }
    }
    private var movementPad:some View {
        VStack(spacing:0) {
            HStack(spacing:0){moveButton("↖",-1,1);moveButton("↑",0,1);moveButton("↗",1,1)}
            HStack(spacing:0){moveButton("←",-1,0);Button("◎"){session.returnToSpawn()}.frame(width:44,height:44).accessibilityLabel("回到出生地");moveButton("→",1,0)}
            HStack(spacing:0){moveButton("↙",-1,-1);moveButton("↓",0,-1);moveButton("↘",1,-1)}
        }.disabled(!session.ready || session.working)
    }
    private var combatButtons:some View {
        VStack(spacing:2) {
            if session.world.player.health==0 {Button("安全复苏"){session.revive()}.accessibilityIdentifier("rpg-revive")}
            else {
                Button("攻击"){session.combatAction(.attack)}.accessibilityIdentifier("rpg-attack")
                Button("范围技能"){session.combatAction(.skill)}.accessibilityIdentifier("rpg-skill")
                Button(session.world.player.perspective == .side ? "冲刺":"翻滚"){session.combatAction(.roll)}.accessibilityIdentifier("rpg-roll")
            }
        }.disabled(!session.ready || session.working)
    }
    private var positionLabel: String {
        if session.world.player.perspective == .side, let point = session.world.player.side { return "u \(point.horizontal) · y \(point.height)" }
        return "x \(session.world.player.surface.x) · z \(session.world.player.surface.z)"
    }
    private var toolPanel: some View {
        NavigationStack(path:$toolPath) {
            Form {
                Picker("模式", selection: Binding(get: { session.world.player.mode }, set: { session.setMode($0) })) {
                    Text("冒险").tag(RPGGameMode.adventure); Text("创造").tag(RPGGameMode.creative)
                }.pickerStyle(.segmented).accessibilityIdentifier("rpg-mode")
                Button("前往双界入口（创造）") { session.travelToTemple() }.accessibilityIdentifier("rpg-temple")
                Button("选择映射区空格") { session.chooseMappedSite() }.accessibilityIdentifier("rpg-choose-mapped")
                Picker("方块", selection: $session.definition) { ForEach(BlockDefinition.all) { Text($0.title).tag($0.id) } }
                Picker("地表操作", selection: $session.tool) {
                    Text("选择").tag(RPGTool.select); Text("连续绘制").tag(RPGTool.paint); Text("删除").tag(RPGTool.erase)
                }
                Text("木材 \(session.world.inventory["wood",default:0]) · 石材 \(session.world.inventory["stone",default:0])").font(.caption)
                Button("选取附近空地") { session.chooseSite() }.accessibilityIdentifier("rpg-choose-site")
                Section("剧情与探索") {
                    NavigationLink("剧情与任务") { RPGStoryView(session:session,travel:{ anchor in tools = false; session.guideTo(anchor) }) }.accessibilityIdentifier("rpg-story")
                    NavigationLink("剧情编辑器") { RPGStoryEditorView(session:session) }.accessibilityIdentifier("rpg-story-editor")
                    ForEach(RPGAnchorID.allCases,id:\.self) { anchor in
                        Button("沿通路前往"+anchor.title) { tools = false; session.guideTo(anchor) }
                    }
                }
                Section("运行与辅助") {
                    NavigationLink("运行诊断") {RPGDiagnosticsView(session:session)}.accessibilityIdentifier("rpg-diagnostics")
                    Text("Seed \(session.world.seed) · 系统减少动态效果：\(reducedMotion ? "开启":"关闭")").font(.caption)
                    if let target=session.selectedEntity {
                        NavigationLink("选中方块行为") {RPGBehaviorEditorView(session:session,target:target)}.accessibilityIdentifier("rpg-behavior-editor")
                    }
                }
                Section("战斗与装备") {
                    Button("开启训练遭遇") { session.trainingEncounter() }.accessibilityIdentifier("rpg-training")
                    Button("制作 / 装备月刃（木材 4）") { session.equip(.moonBlade) }
                    Button("制作 / 装备石甲（石材 6）") { session.equip(.stoneArmor) }
                    Button("卸下装备") { session.equip(.none) }
                    Text("俯视八向攻击、范围技能与翻滚；侧视支持空中攻击和冲刺。训练会开始真实战斗，战斗期间不能切换视角。") .font(.caption)
                }
                Section("媒体外观") {
                    NavigationLink("角色图片 / 视频") { RPGMediaEditorView(session:session,store:model.mediaStore,owner:.player) }
                        .accessibilityIdentifier("rpg-media-player")
                    Picker("背景层",selection:$backgroundLayer){ForEach(0..<min(3,session.world.backgroundBindingIDs.count+1),id:\.self){Text("第 \($0+1) 层").tag($0)}}
                    NavigationLink("背景图片 / 视频") { RPGMediaEditorView(session:session,store:model.mediaStore,owner:.background(backgroundLayer)) }
                        .accessibilityIdentifier("rpg-media-background")
                    if let entity=session.selectedEntity {
                        NavigationLink("选中方块图片 / 视频") { RPGMediaEditorView(session:session,store:model.mediaStore,owner:.entity(entity.id)) }
                            .accessibilityIdentifier("rpg-media-block")
                    }
                    Stepper("同时预览：\(session.world.videoBudget) 路",value:Binding(get:{session.world.videoBudget},set:{session.setVideoBudget($0)}),in:0...2)
                    Text("默认静音。角色、背景与可见互动素材共享预算，其他显示封面或默认外观。3–4 路待实机验证后再评估。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("重新启用预览"){session.media?.retry()}.accessibilityIdentifier("rpg-media-retry")
                }
                Section("范围与复制") {
                    Button("标记起点") { session.markRange() }
                    Button("填充到选中格") { session.fillRange() }.disabled(session.rangeStart == nil || session.selected == nil)
                    Button("复制范围或单格") { session.copyRange() }.disabled(session.selected == nil)
                    Button("粘贴到选中格") { session.paste() }.disabled(!session.hasClipboard || session.selected == nil)
                    Button("删除选中方块（创造）") { session.hitSelected(force: true) }.disabled(session.world.player.mode != .creative || session.selected == nil)
                }
                Section("存档与保护") {
                    Button("保存世界") { session.save() }.accessibilityIdentifier("rpg-save")
                    Button("创建独立创作副本") { session.creativeCopy() }.accessibilityIdentifier("rpg-creative-copy")
                    if session.world.parentWorldID != nil { Button("返回原世界") { session.returnToOriginal() }.accessibilityIdentifier("rpg-return-original") }
                    Text("官方锚点与通路受保护。创造模式免资源成本，但只有独立创作副本可修改保护区。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!session.ready || session.working).navigationTitle("沙盒工具")
                .navigationDestination(for:RPGEntryPage.self){initialDestination($0)}
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { tools = false }.accessibilityIdentifier("rpg-tools-close") } }
        }.buttonStyle(MoonGlassButtonStyle())
    }
    private func moveButton(_ title: String, _ dx: Int, _ dz: Int) -> some View {
        Button(title) { session.move(dx: dx, dz: dz) }.frame(width: 44, height: 44)
            .accessibilityLabel("移动 \(dx), \(dz)").accessibilityIdentifier("rpg-move-\(dx)-\(dz)")
    }
}

private struct RPGCombatHUDView: View {
    @ObservedObject var model:RPGCombatHUDModel
    let session:RPGSession
    var body:some View {Text(model.text).font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-combat-stats")}
}
