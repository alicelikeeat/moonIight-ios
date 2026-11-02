import SwiftUI

@MainActor final class RPGSession: ObservableObject {
    @Published private(set) var world = WorldState()
    @Published private(set) var notice = "世界骨架已就绪；尚未生成地形。"
    @Published private(set) var active = false
    let scene = RPGTopDownScene()
    func activate() { active = true; scene.isPaused = false }
    func pause() { active = false; scene.isPaused = true }
    func shutdown() { pause(); scene.shutdown() }
    func validateRoundTrip() {
        do {
            let decoded = try RPGWorldCodec.decode(RPGWorldCodec.encode(world))
            notice = decoded == world ? "世界数据往返校验通过。" : "世界数据校验失败。"
        } catch { notice = error.localizedDescription }
    }
}
