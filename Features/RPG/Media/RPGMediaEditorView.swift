import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

private struct RPGPickedFile:Transferable,Sendable {
    let url:URL
    static var transferRepresentation:some TransferRepresentation {
        FileRepresentation(importedContentType:.movie){received in try copy(received.file)}
        FileRepresentation(importedContentType:.image){received in try copy(received.file)}
    }
    private static func copy(_ source:URL)throws->RPGPickedFile {
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at:source,to:destination)
        return .init(url:destination)
    }
}
struct RPGMediaEditorView:View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session:RPGSession
    @ObservedObject var store:MediaStore
    let owner:RPGMediaOwner
    @State private var picked:PhotosPickerItem?
    @State private var importing=false
    @State private var importNotice=""
    var body:some View {
        List {
            Section {
                PhotosPicker(selection:$picked,matching:.any(of:[.images,.videos])) { Label("导入图片或视频",systemImage:"square.and.arrow.down") }
                    .accessibilityIdentifier("rpg-import-media").disabled(importing)
                if !importNotice.isEmpty {Text(importNotice).font(.caption)}
                Text("素材会保存到原媒体库。图片或视频的显示大小与角色碰撞范围独立；失效时使用默认外观。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let binding=session.mediaBinding(for:owner) {
                Section("当前显示") {
                    Slider(value:Binding(get:{binding.scale},set:{session.changeBinding(binding.id,scale:$0)}),in:0.25...4,step:0.25){Text("缩放")}
                    Text("缩放 \(String(format:"%.2f",binding.scale))").font(.caption)
                    Slider(value:Binding(get:{binding.anchorX},set:{session.changeBinding(binding.id,anchorX:$0)}),in:0...1){Text("水平锚点")}
                    Slider(value:Binding(get:{binding.anchorY},set:{session.changeBinding(binding.id,anchorY:$0)}),in:0...1){Text("垂直锚点")}
                    Slider(value:Binding(get:{binding.cropWidth},set:{session.changeBinding(binding.id,cropWidth:$0)}),in:0.25...1,step:0.05){Text("裁切宽度")}
                    HStack { Text("循环");Spacer();Toggle("循环",isOn:Binding(get:{binding.loop},set:{session.changeBinding(binding.id,loop:$0)})).labelsHidden().frame(width:51,height:44).accessibilityIdentifier("rpg-binding-loop") }
                    HStack { Text("静音");Spacer();Toggle("静音",isOn:Binding(get:{binding.muted},set:{session.changeBinding(binding.id,muted:$0)})).labelsHidden().frame(width:51,height:44).accessibilityIdentifier("rpg-binding-muted") }
                    Button("恢复默认外观"){session.clearMedia(owner)}.accessibilityIdentifier("rpg-clear-binding")
                }
            }
            Section("素材库") {
                ForEach(store.items.filter{$0.kind != .embed}){entry in
                    Button{session.assignMedia(entry,to:owner)}label:{
                        HStack {
                            Image(systemName:entry.kind == .video ? "video" : "photo")
                            VStack(alignment:.leading){Text(entry.title).lineLimit(2);if entry.remoteURL?.isFileURL != true{Text("远程素材，离线使用默认外观").font(.caption).foregroundStyle(.secondary)}}
                            Spacer()
                            if session.mediaBinding(for:owner)?.mediaID==entry.id{Image(systemName:"checkmark")}
                        }.frame(minHeight:44)
                    }.disabled(session.working).accessibilityIdentifier("rpg-pick-"+entry.id).accessibilityValue(session.mediaBinding(for:owner)?.mediaID==entry.id ? "已选" : "未选")
                }
            }
        }.navigationTitle("媒体外观").buttonStyle(MoonGlassButtonStyle())
            .safeAreaInset(edge:.bottom) {
                Text("当前："+(store.items.first{$0.id==session.mediaBinding(for:owner)?.mediaID}?.title ?? "默认外观"))
                    .font(.caption).padding(10).moonSingleGlass(radius:12).accessibilityIdentifier("rpg-current-media")
            }
            .toolbar { ToolbarItem(placement:.topBarTrailing){Button("返回工具"){dismiss()}.accessibilityIdentifier("rpg-media-back")} }
            .onChange(of:picked){value in
                guard let value else{return};importing=true
                Task {
                    do {
                        guard let file=try await value.loadTransferable(type:RPGPickedFile.self) else{importNotice="无法读取所选素材。";importing=false;return}
                        defer{try? FileManager.default.removeItem(at:file.url)}
                        let video=value.supportedContentTypes.contains{$0.conforms(to:.movie)}
                        if let entry=await store.importLocalFile(file.url,title:video ? "沙盒视频" : "沙盒图片",kind:video ? .video : .image){session.assignMedia(entry,to:owner);importNotice="已导入并绑定。"}
                        else{importNotice=store.notice ?? "导入失败。"}
                    }catch{importNotice=error.localizedDescription}
                    importing=false;picked=nil
                }
            }
    }
}
