import SwiftUI
import SpriteKit

struct RPGShellView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = RPGSession()
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("自由媒体沙盒").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.accessibilityIdentifier("rpg-close")
            }.frame(minHeight: 44)
            Text("256 × 256 地表 · 64 个区块").font(.caption).foregroundStyle(.secondary)
            SpriteView(scene: session.scene, options: [.allowsTransparency])
                .clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityLabel("世界场景")
            Text(session.notice).font(.callout).accessibilityIdentifier("rpg-status")
            Button("校验世界数据") { session.validateRoundTrip() }.accessibilityIdentifier("rpg-validate")
            Text("骨架阶段：地图生成、建造和双视角将在后续阶段接入。").font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(MoonGlassButtonStyle()).padding(16).padding(.bottom, 82)
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .onAppear { session.activate() }
            .onDisappear { session.shutdown() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
    }
}
