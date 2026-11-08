import SwiftUI
import Darwin

@MainActor enum RPGMemoryMetrics {
    static var footprintMB: Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }
}

/// What the 3D world measures about itself right now: frame rate, what is
/// on screen, memory and heat. Read on the phone; simulator numbers say
/// nothing about an iPhone.
struct Glass3DDiagnosticsView: View {
    @ObservedObject var controller: Glass3DController
    @ObservedObject var live: Glass3DLive
    @Environment(\.dismiss) private var dismiss
    @State private var report = ""

    init(controller: Glass3DController) {
        self.controller = controller
        self.live = controller.live
    }

    var body: some View {
        List { Group {
            Section(L10n.t("本次运行", "This Run")) {
                Text(report).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("rpg-diagnostics-report")
                Button(L10n.t("刷新", "Refresh")) { report = Self.report(controller: controller, live: live) }.accessibilityIdentifier("glass3d-diagnostics-refresh")
                Button(L10n.t("复制诊断", "Copy Diagnostics")) { UIPasteboard.general.string = report }
                ShareLink(item: report) { Label(L10n.t("分享诊断文本", "Share Diagnostics"), systemImage: "square.and.arrow.up") }
            }
            Section(L10n.t("验证范围", "What This Shows")) {
                Text(L10n.t("帧率是进入本页前最近 120 帧的平均值；打开本页时世界会暂停。模拟器数据不能代表 iPhone，帧率、发热和长时间内存请在真机上测量。", "The frame rate averages the last 120 frames before this page opened; the world pauses while it is open. Simulator numbers do not represent an iPhone; measure frame rate, heat and long-run memory on the phone."))
                    .font(.caption)
            }
        }.listRowBackground(MoonLiquidRowBackground()) }
        .moonLiquidList()
        .navigationTitle(L10n.t("运行诊断", "Diagnostics"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() }.accessibilityIdentifier("rpg-diagnostics-back") } }
        .onAppear { report = Self.report(controller: controller, live: live) }
    }

    static func report(controller: Glass3DController, live: Glass3DLive) -> String {
        let s = live.stats
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = L10n.t("正常", "nominal")
        case .fair: thermal = L10n.t("偏热", "fair")
        case .serious: thermal = L10n.t("很热", "serious")
        case .critical: thermal = L10n.t("过热", "critical")
        @unknown default: thermal = "?"
        }
        var lines = [
            "fps=\(Int(s.fps.rounded())) visibleCells=\(s.visibleCells) blocks=\(s.blocks) creatures=\(s.creatures) activeAI=\(s.activeAI) videos=\(s.videos)",
            "glass=\(live.glassStatus) quality=\(controller.quality.rawValue) powerSaver=\(controller.powerSaver) view=\(controller.viewMode.rawValue)",
            "memoryMB=" + (RPGMemoryMetrics.footprintMB.map { String(format: "%.0f", $0) } ?? "?") + " thermal=\(thermal) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)",
            "region=\(controller.regionTitle)",
        ]
        // v1.91: the character runtime (instances, deformations so far, LOD switches, cached bodies, incidents).
        let c = controller.characters.runtime.stats
        lines.append("characters=\(c.instances) deformations=\(c.deformations) skipped=\(c.skipped) lod0/1/2=\(c.lodCounts.map(String.init).joined(separator: "/")) cachedBodies=\(c.cachedBodies) incidents=\(controller.characters.runtime.incidents.count)")
        for incident in controller.characters.runtime.incidents.suffix(3) { lines.append("incident \(incident.owner) \(incident.motion): \(incident.reason)") }
        #if targetEnvironment(simulator)
        lines.append(L10n.t("运行在模拟器上：数据不代表 iPhone", "Running in the simulator: not representative of an iPhone"))
        #endif
        return lines.joined(separator: "\n")
    }
}
