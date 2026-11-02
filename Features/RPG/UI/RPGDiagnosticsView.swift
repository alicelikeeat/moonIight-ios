import SwiftUI
import Darwin

@MainActor enum RPGMemoryMetrics {
    static var footprintMB:Double?{
        var info=task_vm_info_data_t()
        var count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info){pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}
        }
        return result==KERN_SUCCESS ? Double(info.phys_footprint)/1_048_576:nil
    }
}
struct RPGDiagnosticsView:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session:RPGSession
    @State private var report=""
    var body:some View {
        List {
            Section("本次运行观测") {
                Text(report).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("rpg-diagnostics-report")
                Button("复制诊断"){UIPasteboard.general.string=report}
                ShareLink(item:report){Label("分享诊断文本",systemImage:"square.and.arrow.up")}
            }
            Section("验证范围") {
                Text("工具面板会暂停世界。下列帧数据来自进入工具前的可见场景，不把暂停时间计入帧率。")
                Text("模拟器数据不能证明 iPhone 性能。目标机型的 Instruments、长期内存、发热、低电量及 60 FPS 仍待真机验证。")
            }.font(.caption)
        }.navigationTitle("运行诊断").buttonStyle(MoonGlassButtonStyle())
            .navigationBarBackButtonHidden(true)
            .toolbar{ToolbarItem(placement:.navigationBarLeading){Button("返回工具"){dismiss()}.accessibilityIdentifier("rpg-diagnostics-back")}}
            .onAppear{report=session.diagnosticReport()}
    }
}
