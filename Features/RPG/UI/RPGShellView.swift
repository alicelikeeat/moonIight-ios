import SwiftUI
import SpriteKit

struct RPGShellView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = RPGSession()
    @State private var tools = false
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
            .onAppear { session.activate() }
            .onDisappear { session.shutdown() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
            .sheet(isPresented: $tools) { toolPanel }
            .onChange(of: tools) { visible in session.setOverlay(visible) }
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
