import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct QuickActionsPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: MediaEntry
    let onPlay: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List { Group {
                Section("内容信息") {
                    LabeledContent("来源", value: entry.platform)
                    if !entry.author.isEmpty { LabeledContent("作者", value: entry.author) }
                    LabeledContent("位置", value: model.mediaStore.folders.first(where: { $0.id == model.mediaStore.folderID(for: entry) })?.name ?? "未分类")
                    if let progress = model.mediaStore.progress(for: entry), progress.position > 0 {
                        LabeledContent("观看进度", value: "\(Int(progress.position / 60)):\(String(format: "%02d", Int(progress.position) % 60))")
                    }
                }
                Section("已配置的更多操作") {
                    ForEach(InteractionPreferences.shared.actions("media").filter { $0.mediaAction == nil }) { action in
                        Button {
                            if let media = action.mediaAction {
                                switch media {
                                case .play: onPlay()
                                case .favorite: model.mediaStore.toggleFavorite(entry)
                                case .library: model.mediaStore.appendToLibrary([entry])
                                case .share: model.send(.shareMedia, context: "media")
                                }
                            } else {
                                dismiss()
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 350_000_000)
                                    model.send(action, context: "media")
                                }
                            }
                        } label: { Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        .accessibilityElement(children: .ignore).accessibilityLabel(action.title)
                        .accessibilityIdentifier("configured-action-\(action.rawValue)")
                    }
                }
                Section("播放与分享") {
                    Button(action: onPlay) { Label("播放 / 打开", systemImage: "play.fill") }
                    ShareLink(item: entry.remoteURL?.absoluteString ?? entry.title, preview: SharePreview(entry.title)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                Section("保存与整理") {
                    Button {
                        model.mediaStore.toggleFavorite(entry)
                    } label: {
                        Label(entry.isFavorite ? "取消收藏" : "收藏", systemImage: entry.isFavorite ? "heart.slash" : "heart")
                    }
                    Button {
                        model.mediaStore.appendToLibrary([entry])
                    } label: {
                        Label("加入库", systemImage: "plus.rectangle.on.folder")
                    }
                    Button {
                        model.mediaStore.enqueue([entry])
                    } label: {
                        Label("加入播放队列", systemImage: "text.badge.play")
                    }
                }
                Section("危险操作") {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }
            .scrollContentBackground(.hidden)
            .pageBackground(.actionsPanel)
            .navigationTitle("更多操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }
        .confirmationDialog("从库中删除这条内容？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.mediaStore.delete(entry)
                dismiss()
            }
            Button("取消", role: .cancel) { }
        }
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
