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
    /// Closes the tools and starts a timed glass sample on the live world.
    var onRunSample:(() -> Void)?=nil
    @State private var report=""
    var body:some View {
        List { Group {
            Section {
                ForEach(RPGGlassMode.allCases,id:\.self){mode in
                    Button{session.glassMode=mode}label:{
                        HStack{Text(mode.title);Spacer();if session.glassMode==mode{Image(systemName:"checkmark")}}.frame(minHeight:44).contentShape(Rectangle())
                    }.accessibilityIdentifier("rpg-glass-mode-"+mode.rawValue).accessibilityValue(session.glassMode==mode ? "已选" : "未选")
                }
                if session.glassMode == .nativeNearest {
                    Picker("逐格数量 N",selection:$session.glassNearest){ForEach(RPGGlassPolicy.nearestChoices,id:\.self){Text("\($0)").tag($0)}}
                        .pickerStyle(.segmented).accessibilityIdentifier("rpg-glass-nearest")
                }
                Text("实际渲染：\(session.glassRender.label)"+(session.glassReason.map{"（降级：\($0)）"} ?? "")).font(.caption)
                    .accessibilityIdentifier("rpg-glass-effective")
                if let onRunSample {
                    Button("开始 \(ProcessInfo.processInfo.arguments.contains("--glass-sample-short") ? 5 : 60) 秒采样"){onRunSample()}
                        .disabled(session.glassSampleRemaining != nil).accessibilityIdentifier("rpg-glass-run")
                }
                ForEach(session.glassSamples){Text($0.line).font(.caption2.monospaced()).textSelection(.enabled)}
                if !session.glassSamples.isEmpty {
                    ShareLink(item:session.glassSamples.map(\.line).joined(separator:"\n")){Label("分享采样结果",systemImage:"square.and.arrow.up")}
                        .accessibilityIdentifier("rpg-glass-share")
                }
            } header: { Text("全格子玻璃验证（实验）") } footer: {
                Text("A 是 SpriteKit 绘制的仿玻璃纹理，不是系统 Liquid Glass。B、C 为 iOS 26 原生玻璃：镜头移动、低电量、发热严重或开启“降低透明度”时自动改用 A。采样在关闭工具后开始，期间请正常移动和操作；模拟器结果不代表 iPhone 性能，请在真机上测量并配合 Instruments。")
            }
            Section("本次运行观测") {
                Text(report).font(.caption.monospaced()).textSelection(.enabled).accessibilityIdentifier("rpg-diagnostics-report")
                Button("复制诊断"){UIPasteboard.general.string=report}
                ShareLink(item:report){Label("分享诊断文本",systemImage:"square.and.arrow.up")}
            }
            Section("验证范围") {
                Text("工具面板会暂停世界。下列帧数据来自进入工具前的可见场景，不把暂停时间计入帧率。")
                Text("模拟器数据不能证明 iPhone 性能。目标机型的 Instruments、长期内存、发热、低电量及 60 FPS 仍待真机验证。")
            }.font(.caption)
            }.listRowBackground(MoonLiquidRowBackground())
        }.moonLiquidList().navigationTitle("运行诊断").buttonStyle(MoonGlassButtonStyle())
            .navigationBarBackButtonHidden(true)
            .toolbar{ToolbarItem(placement:.navigationBarLeading){Button("返回工具"){dismiss()}.accessibilityIdentifier("rpg-diagnostics-back")}}
            .onAppear{report=session.diagnosticReport()}
    }
}
