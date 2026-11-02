import SwiftUI
import SpriteKit

struct RPGShellView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = RPGSession()
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("自由媒体沙盒").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.accessibilityIdentifier("rpg-close")
            }.frame(minHeight: 44)
            HStack {
                Text("256 × 256 · \(session.loadedChunks)/64 区块").font(.caption).accessibilityIdentifier("rpg-loaded-chunks").accessibilityValue(String(session.loadedChunks))
                Spacer()
                Text("x \(session.world.player.surface.x) · z \(session.world.player.surface.z)").font(.caption.monospacedDigit()).accessibilityIdentifier("rpg-position")
            }
            SpriteView(scene: session.scene, options: [.allowsTransparency])
                .clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityLabel("世界场景")
            Text(session.notice).font(.caption).accessibilityIdentifier("rpg-status")
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) { moveButton("↖", -1, 1); moveButton("↑", 0, 1); moveButton("↗", 1, 1) }
                    HStack(spacing: 0) { moveButton("←", -1, 0); Button("◎") { session.returnToSpawn() }.frame(width: 44, height: 44).accessibilityLabel("回到出生地"); moveButton("→", 1, 0) }
                    HStack(spacing: 0) { moveButton("↙", -1, -1); moveButton("↓", 0, -1); moveButton("↘", 1, -1) }
                }
                VStack(alignment: .leading) {
                    Button("校验世界数据") { session.validateRoundTrip() }.accessibilityIdentifier("rpg-validate")
                    Text("Seed：\(session.world.seed)").font(.caption)
                    if let selected = session.selected { Text("选中 \(selected.x), \(selected.z)").font(.caption) }
                }
            }
        }.buttonStyle(MoonGlassButtonStyle()).padding(12).padding(.bottom, 82)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .onAppear { session.activate() }
            .onDisappear { session.shutdown() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
    }
    private func moveButton(_ title: String, _ dx: Int, _ dz: Int) -> some View {
        Button(title) { session.move(dx: dx, dz: dz) }.frame(width: 44, height: 44)
            .accessibilityLabel("移动 \(dx), \(dz)").accessibilityIdentifier("rpg-move-\(dx)-\(dz)")
    }
}
