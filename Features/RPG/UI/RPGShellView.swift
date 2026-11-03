import SwiftUI
import SpriteKit

enum RPGEntryPage:String,Hashable {case world,story,editor,diagnostics}

extension AppCommand {
    var rpgPage:RPGEntryPage? {switch self {case .rpg:.world;case .rpgStory:.story;case .rpgEditor:.editor;case .rpgDiagnostics:.diagnostics;default:nil}}
}

struct RPGShellView: View {
    var initialPage=RPGEntryPage.world
    @State private var initialPresented=false
    @State private var toolPath:[RPGEntryPage]=[]
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var storyPlaying=false
    @StateObject private var session = RPGSession()
    @State private var tools = false
    @State private var mediaDiagnostics = ""
    @State private var backgroundLayer = 0
    @State private var cellEditor: WorldEntity?
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(session.world.isCreativeCopy ? "创作副本" : "自由媒体沙盒").font(.headline)
                Spacer()
                Button("校验") { session.validateRoundTrip() }.accessibilityIdentifier("rpg-validate").disabled(!session.ready)
                Button("工具") { toolPath=[];tools = true }.accessibilityIdentifier("rpg-tools")
                Button("完成") { Task { if await session.saveBeforeExit() { dismiss() } } }.accessibilityIdentifier("rpg-close")
            }.frame(minHeight: 44)
            HStack {
                Text("256 × 256 · \(session.loadedChunks)/64 区块").font(.caption)
                    .accessibilityIdentifier("rpg-loaded-chunks").accessibilityValue(String(session.loadedChunks))
                Text("自建 \(session.world.entities.count)").font(.caption).accessibilityIdentifier("rpg-placed-count").accessibilityValue(String(session.world.entities.count))
                Spacer()
                Text(positionLabel).font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-position")
            }
            Group {
                if !session.ready,!session.recoveryChoices.isEmpty {
                    ScrollView {VStack(spacing:12){
                        Text("选择保留的世界").font(.headline)
                        ForEach(session.recoveryChoices){choice in
                            Button((choice.creative ? "创作副本":"原世界")+" · Seed \(choice.seed) · 修订 \(choice.revision)"){session.recoverWorld(choice.id)}
                                .accessibilityIdentifier("rpg-recover-"+choice.id)
                        }
                    }.padding()}
                } else if session.world.player.perspective == .topDown { SpriteView(scene: session.scene, options: [.allowsTransparency]) }
                else { SpriteView(scene: session.sideScene, options: [.allowsTransparency]) }
            }.clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityLabel("世界场景")
                .overlay { if session.ready, let rect = session.selectionRect { RPGSelectionGlass(rect: rect) } }
                .overlay(alignment:.bottomLeading){if session.ready{movementPad.padding(6)}}
                .overlay(alignment:.bottomTrailing){if session.ready{combatButtons.padding(6)}}
            HStack {
                Button(session.world.player.perspective == .topDown ? "进入侧视" : "返回俯视") { session.toggleProjection() }
                    .accessibilityIdentifier("rpg-perspective")
                Spacer()
                Text(session.world.player.perspective == .topDown ? "俯视地表" : "侧视切片")
                    .font(.caption).accessibilityIdentifier("rpg-projection-evidence").accessibilityValue(session.projectionEvidence)
            }
            RPGCombatHUDView(model:session.combatHUD,session:session)
            Text(session.notice).font(.caption).accessibilityIdentifier("rpg-status")
            if session.selected != nil || !session.world.undo.isEmpty || !session.world.redo.isEmpty {
            HStack {
                Button("放置") { session.placeSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-place")
                Button("挖掘") { session.hitSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-hit")
                Button("内容") { cellEditor = session.selectedEntity }.disabled(session.selectedEntity == nil).accessibilityIdentifier("rpg-edit-cell")
                Button("撤销") { session.undo() }.disabled(session.world.undo.isEmpty).accessibilityIdentifier("rpg-undo")
                Button("重做") { session.redo() }.disabled(session.world.redo.isEmpty).accessibilityIdentifier("rpg-redo")
            }.disabled(!session.ready || session.working)
            }
        }.buttonStyle(MoonGlassButtonStyle()).padding(12).padding(.bottom, 82)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .onAppear { session.attachMediaStore(model.mediaStore); session.setReducedMotion(reducedMotion);session.activate() }
            .onDisappear { session.shutdown() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
            .sheet(isPresented: $tools) { toolPanel }
            .sheet(item: $cellEditor) { entity in
                NavigationStack { RPGCellEditorView(session: session, store: model.mediaStore, entity: entity) }.environmentObject(model)
            }
            .sheet(isPresented:$storyPlaying) {
                NavigationStack {RPGStoryView(session:session,travel:{anchor in storyPlaying=false;session.guideTo(anchor)},backTitle:"返回世界")}
            }
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests") {
                    Text("媒体测试状态").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-media-probe").accessibilityValue(mediaDiagnostics)
                    Text("格子内容").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-cell-content").accessibilityValue(session.selectedCellSummary)
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
            .onChange(of:session.ready){if $0{presentInitial()}}
            .onChange(of: tools) { visible in session.setOverlay(visible || storyPlaying || cellEditor != nil) }
            .onChange(of:storyPlaying){session.setOverlay($0 || tools || cellEditor != nil)}
            .onChange(of: cellEditor?.id) { id in session.setOverlay(id != nil || tools || storyPlaying) }
            .onChange(of:session.pendingStory){if $0{storyPlaying=true;session.acknowledgeStory()}}
            .onChange(of:reducedMotion){session.setReducedMotion($0)}
            .onChange(of: session.world.backgroundBindingIDs.count) { count in backgroundLayer=min(backgroundLayer,min(2,count)) }
    }
    private func presentInitial(){
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
