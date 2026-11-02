import SwiftUI
import SpriteKit

struct RPGShellView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = RPGSession()
    @State private var tools = false
    @State private var mediaDiagnostics = ""
    @State private var backgroundLayer = 0
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(session.world.isCreativeCopy ? "创作副本" : "自由媒体沙盒").font(.headline)
                Spacer()
                Button("工具") { tools = true }.accessibilityIdentifier("rpg-tools")
                Button("完成") { Task { if await session.saveBeforeExit() { dismiss() } } }.accessibilityIdentifier("rpg-close")
            }.frame(minHeight: 44)
            HStack {
                Text("256 × 256 · \(session.loadedChunks)/64 区块").font(.caption)
                    .accessibilityIdentifier("rpg-loaded-chunks").accessibilityValue(String(session.loadedChunks))
                Spacer()
                Text(positionLabel).font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-position")
            }
            Group {
                if session.world.player.perspective == .topDown { SpriteView(scene: session.scene, options: [.allowsTransparency]) }
                else { SpriteView(scene: session.sideScene, options: [.allowsTransparency]) }
            }.clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityLabel("世界场景")
            HStack {
                Button(session.world.player.perspective == .topDown ? "进入侧视" : "返回俯视") { session.toggleProjection() }
                    .accessibilityIdentifier("rpg-perspective")
                Spacer()
                Text(session.world.player.perspective == .topDown ? "俯视地表" : "侧视切片")
                    .font(.caption).accessibilityIdentifier("rpg-projection-evidence").accessibilityValue(session.projectionEvidence)
            }
            RPGCombatHUDView(model:session.combatHUD,session:session)
            Text(session.notice).font(.caption).accessibilityIdentifier("rpg-status")
            HStack {
                Button("放置") { session.placeSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-place")
                Button("挖掘") { session.hitSelected() }.disabled(session.selected == nil).accessibilityIdentifier("rpg-hit")
                Button("撤销") { session.undo() }.disabled(session.world.undo.isEmpty).accessibilityIdentifier("rpg-undo")
                Button("重做") { session.redo() }.disabled(session.world.redo.isEmpty).accessibilityIdentifier("rpg-redo")
            }.disabled(!session.ready || session.working)
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { moveButton("↖", -1, 1); moveButton("↑", 0, 1); moveButton("↗", 1, 1) }
                    HStack(spacing: 0) { moveButton("←", -1, 0); Button("◎") { session.returnToSpawn() }.frame(width: 44, height: 44).accessibilityLabel("回到出生地"); moveButton("→", 1, 0) }
                    HStack(spacing: 0) { moveButton("↙", -1, -1); moveButton("↓", 0, -1); moveButton("↘", 1, -1) }
                }.disabled(!session.ready || session.working)
                VStack(alignment: .leading) {
                    Button("校验世界数据") { session.validateRoundTrip() }.accessibilityIdentifier("rpg-validate").disabled(!session.ready)
                    Text("自建 \(session.world.entities.count) · Seed \(session.world.seed)").font(.caption)
                        .accessibilityIdentifier("rpg-placed-count").accessibilityValue(String(session.world.entities.count))
                    if let selected = session.selected { Text("选中 \(selected.x), \(selected.z)").font(.caption) }
                }
            }
        }.buttonStyle(MoonGlassButtonStyle()).padding(12).padding(.bottom, 82)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .onAppear { session.attachMediaStore(model.mediaStore); session.activate() }
            .onDisappear { session.shutdown() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
            .sheet(isPresented: $tools) { toolPanel }
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests") {
                    Text("媒体测试状态").font(.system(size:1)).frame(height:1).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("rpg-media-probe").accessibilityValue(mediaDiagnostics)
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
            .onChange(of: tools) { visible in session.setOverlay(visible) }
            .onChange(of: session.world.backgroundBindingIDs.count) { count in backgroundLayer=min(backgroundLayer,min(2,count)) }
    }
    private var positionLabel: String {
        if session.world.player.perspective == .side, let point = session.world.player.side { return "u \(point.horizontal) · y \(point.height)" }
        return "x \(session.world.player.surface.x) · z \(session.world.player.surface.z)"
    }
    private var toolPanel: some View {
        NavigationStack {
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
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { tools = false }.accessibilityIdentifier("rpg-tools-close") } }
        }.buttonStyle(MoonGlassButtonStyle())
    }
    private func moveButton(_ title: String, _ dx: Int, _ dz: Int) -> some View {
        Button(title) { session.move(dx: dx, dz: dz) }.frame(width: 44, height: 44)
            .accessibilityLabel("移动 \(dx), \(dz)").accessibilityIdentifier("rpg-move-\(dx)-\(dz)")
    }
}

private struct RPGCombatHUDView: View {
    @ObservedObject var model: RPGCombatHUDModel
    let session: RPGSession
    var body: some View {
        VStack(spacing:2) {
            Text(model.text).font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-combat-stats")
            HStack {
                if model.dead { Button("安全复苏") { session.revive() }.accessibilityIdentifier("rpg-revive") }
                else {
                    Button("攻击") { session.combatAction(.attack) }.accessibilityIdentifier("rpg-attack")
                    Button("范围技能") { session.combatAction(.skill) }.accessibilityIdentifier("rpg-skill")
                    Button("翻滚 / 冲刺") { session.combatAction(.roll) }.accessibilityIdentifier("rpg-roll")
                }
            }.frame(minHeight:44)
        }
    }
}
