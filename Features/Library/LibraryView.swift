import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    let selectedImage: Image?
    @Binding var selection: PhotosPickerItem?
    let onPlay: (MediaEntry) -> Void
    var initialAction: AppCommand? = nil
    @EnvironmentObject private var model: AppModel
    @State private var selectionMode = false
    @State private var selectedIDs = Set<String>()
    @State private var filter = "全部"
    @State private var selectedFolderID: String?
    @State private var folderName = ""
    @State private var showingCreateFolder = false
    @State private var showingRenameFolder = false
    @State private var showingDeleteFolder = false
    @State private var reelsFolder: LibraryFolder?
    @State private var reelsQueue = false
    @State private var reelsSmartPlaylist: SmartPlaylistKind?
    @State private var folderImportSelection: PhotosPickerItem?

    private var selectedFolder: LibraryFolder? {
        model.mediaStore.folders.first { $0.id == selectedFolderID }
    }

    private var visibleItems: [MediaEntry] {
        if let selectedFolderID {
            return model.mediaStore.items.filter { model.mediaStore.folderAssignments[$0.id] == selectedFolderID }
        }
        switch filter {
        case "收藏": return model.mediaStore.items.filter(\.isFavorite)
        case "下载": return model.mediaStore.items.filter { $0.source == "download" }
        case "继续观看": return model.mediaStore.continueWatching
        case "未观看": return model.mediaStore.unwatchedItems
        default: return model.mediaStore.items
        }
    }

    private var canDownloadSelection: Bool {
        visibleItems.contains { entry in
            guard selectedIDs.contains(entry.id), entry.kind != .embed,
                  let scheme = entry.remoteURL?.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
    }

    var body: some View {
        ScrollView { libraryContent.padding(.top, 24) }.scrollIndicators(.hidden).pageBackground(.library)
            .navigationTitle("库")
            .alert("新建文件夹", isPresented: $showingCreateFolder) {
                TextField("文件夹名称", text: $folderName)
                Button("创建") {
                    if let folder = model.mediaStore.createFolder(named: folderName) { selectedFolderID = folder.id }
                    folderName = ""
                }
                Button("取消", role: .cancel) { folderName = "" }
            } message: { Text("把想看的内容归纳在一起。") }
            .alert("重命名文件夹", isPresented: $showingRenameFolder) {
                TextField("文件夹名称", text: $folderName)
                Button("保存") {
                    if let selectedFolder { model.mediaStore.renameFolder(selectedFolder, to: folderName) }
                }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("删除文件夹？", isPresented: $showingDeleteFolder) {
                Button("删除文件夹", role: .destructive) {
                    if let selectedFolder { model.mediaStore.deleteFolder(selectedFolder) }
                    selectedFolderID = nil
                }
            } message: { Text("媒体仍保留在库中，只取消文件夹分类。") }
            .fullScreenCover(item: $reelsFolder) { folder in
                ReelsView(source: .folder(folder.id)).environmentObject(model)
            }
            .fullScreenCover(isPresented: $reelsQueue) {
                ReelsView(source: .queue).environmentObject(model)
            }
            .fullScreenCover(item: $reelsSmartPlaylist) { playlist in
                ReelsView(source: .smart(playlist)).environmentObject(model)
            }
            .task(id: model.command?.id) {
                switch initialAction ?? model.command?.action {
                case .selectAll: selectionMode = true; selectedIDs = Set(visibleItems.map(\.id))
                case .favorites: filter = "收藏"
                case .downloads: filter = "下载"
                default: break
                }
            }
            .task(id: folderImportSelection) {
                await importIntoCurrentFolder()
            }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(selectionMode ? "取消" : "选择") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectionMode.toggle()
                        selectedIDs.removeAll()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MoonStyle.accent)
                if selectionMode {
                    Button("全选") { selectedIDs = Set(visibleItems.map(\.id)) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MoonStyle.accent)
                }
                Spacer()
                Text("库").font(.title2.bold())
                Spacer()
                Menu {
                    Button("将当前列表加入队列") { model.mediaStore.enqueue(visibleItems) }
                    Button("替换播放队列") { model.mediaStore.enqueue(visibleItems, replacing: true) }
                    if !model.mediaStore.queueItems.isEmpty {
                        Button("播放队列") { reelsQueue = true }
                        Button("清空播放队列", role: .destructive) { model.mediaStore.clearQueue() }
                    }
                } label: {
                    Image(systemName: "text.badge.play").font(.subheadline.weight(.semibold))
                }.buttonStyle(MoonGlassButtonStyle()).foregroundStyle(MoonStyle.accent)
                PhotosPicker(selection: $folderImportSelection, matching: .any(of: [.images, .videos])) {
                    Label(selectedFolder == nil ? "导入" : "导入到文件夹", systemImage: "plus").font(.subheadline.weight(.semibold))
                }.buttonStyle(MoonGlassButtonStyle()).foregroundStyle(MoonStyle.accent)
            }

            folderSection
            if let selectedFolder {
                HStack(spacing: 10) {
                    Button { selectedFolderID = nil; selectedIDs.removeAll(); selectionMode = false } label: {
                        Label("全部内容", systemImage: "chevron.left")
                    }
                    Spacer()
                    Button { reelsFolder = selectedFolder } label: {
                        Label("播放此文件夹", systemImage: "play.rectangle.fill")
                    }.disabled(visibleItems.isEmpty)
                    Menu {
                        Button("重命名") { folderName = selectedFolder.name; showingRenameFolder = true }
                        Button("删除文件夹", role: .destructive) { showingDeleteFolder = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }.font(.subheadline.weight(.medium)).buttonStyle(MoonGlassButtonStyle()).foregroundStyle(MoonStyle.accent)
            } else {
                Menu {
                    ForEach(["全部", "继续观看", "未观看", "收藏", "下载"], id: \.self) { choice in
                        Button(choice) { filter = choice }
                    }
                } label: {
                    Label(filter, systemImage: "line.3.horizontal.decrease.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-filter-menu")
            }
            if selectionMode {
                VStack(spacing: 10) {
                    HStack {
                        Text("已选 \(selectedIDs.count) 项").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(model.mediaStore.folders) { folder in
                                Button(folder.name) { moveSelection(to: folder) }
                            }
                            if selectedFolderID != nil { Button("移出文件夹") { moveSelection(to: nil) } }
                        } label: { Label("移至文件夹", systemImage: "folder") }
                        .disabled(selectedIDs.isEmpty || model.mediaStore.folders.isEmpty)
                    }
                    HStack {
                        Button(filter == "收藏" && selectedFolderID == nil ? "取消收藏" : "收藏") {
                            withAnimation(.easeOut(duration: 0.2)) {
                                for entry in visibleItems where selectedIDs.contains(entry.id) {
                                    let shouldRemove = filter == "收藏" && selectedFolderID == nil
                                    if entry.isFavorite == shouldRemove { model.mediaStore.toggleFavorite(entry) }
                                }
                                selectedIDs.removeAll()
                            }
                        }
                        Button("下载") {
                            let chosen = visibleItems.filter { selectedIDs.contains($0.id) }
                            selectedIDs.removeAll()
                            Task { for entry in chosen { await model.mediaStore.downloadDirectFile(entry) } }
                        }
                        .disabled(!canDownloadSelection)
                        Spacer()
                        Button("删除", role: .destructive) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                for entry in visibleItems where selectedIDs.contains(entry.id) { model.mediaStore.delete(entry) }
                                selectedIDs.removeAll()
                            }
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                }.font(.subheadline.weight(.medium))
            }
            if visibleItems.isEmpty {
                if let selectedImage {
                    selectedImage.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    EmptyPanel(title: selectedFolder != nil ? "文件夹还是空的" : filter == "下载" ? "还没有下载内容" : "媒体会显示在这里", detail: selectedFolder != nil ? "返回全部内容，选择条目后移入此文件夹。" : "导入照片或视频，或从首页随机添加内容。", symbol: "photo.on.rectangle.angled")
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(visibleItems) { entry in
                        MediaEntryCard(entry: entry, height: 120, isSelected: selectedIDs.contains(entry.id)) {
                            if selectionMode {
                                if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) }
                                else { selectedIDs.insert(entry.id) }
                            } else { onPlay(entry) }
                        }
                        .transition(.opacity)
                        .overlay(alignment: .topLeading) {
                            if let progress = model.mediaStore.progress(for: entry), progress.position > 0, !progress.isFinished {
                                Text("继续 \(timeLabel(progress.position))")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(7)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
        .padding(.bottom, 72)
        .animation(.easeOut(duration: 0.22), value: visibleItems.map(\.id))
    }

    private func timeLabel(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件夹").font(.headline)
                Spacer()
                Button { folderName = ""; showingCreateFolder = true } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.semibold))
                }.buttonStyle(MoonGlassButtonStyle()).foregroundStyle(MoonStyle.accent)
            }
            if model.mediaStore.folders.isEmpty {
                Text("新建文件夹，将喜欢的内容放在一起。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(model.mediaStore.folders) { folder in
                        Button {
                            selectedFolderID = folder.id
                            selectionMode = false
                            selectedIDs.removeAll()
                        } label: {
                            folderCard(folder)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library-folder-\(folder.id)")
                    }
                }
            }
        }
    }

    private var smartPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("智能片单").font(.headline)
                Spacer()
                Text("自动更新").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SmartPlaylistKind.allCases) { playlist in
                        let count = model.mediaStore.items(for: playlist).count
                        Button { reelsSmartPlaylist = playlist } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Image(systemName: playlist.symbol).font(.headline)
                                    Spacer()
                                    Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                                }
                                Text(playlist.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(playlist.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(width: 142, height: 100, alignment: .leading)
                            .padding(12)
                            .foregroundStyle(.primary)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.32)))
                        }
                        .buttonStyle(.plain)
                        .disabled(count == 0)
                        .opacity(count == 0 ? 0.58 : 1)
                        .accessibilityIdentifier("smart-playlist-\(playlist.id)")
                    }
                }
            }
        }
    }

    private func folderCard(_ folder: LibraryFolder) -> some View {
        let contents = Array(model.mediaStore.items(in: folder).prefix(2))
        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { index in
                    Group {
                        if contents.indices.contains(index) {
                            folderThumbnail(contents[index])
                        } else {
                            LinearGradient(colors: [MoonStyle.accent.opacity(0.75), .indigo.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            }
            .frame(height: 118).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(model.mediaStore.items(in: folder).count) 项").font(.caption2).opacity(0.83)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white).padding(12)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selectedFolderID == folder.id ? MoonStyle.accent : .white.opacity(0.3), lineWidth: selectedFolderID == folder.id ? 2 : 0.7))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .accessibilityLabel("\(folder.name)，\(model.mediaStore.items(in: folder).count) 项")
    }

    @ViewBuilder
    private func folderThumbnail(_ entry: MediaEntry) -> some View {
        if let url = entry.coverURL ?? (entry.kind == .image ? entry.remoteURL : nil) {
            if url.isFileURL { LocalMediaImage(url: url, fill: true) }
            else {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                    placeholder: { Color.gray.opacity(0.4) }
            }
        } else {
            LinearGradient(colors: [.indigo.opacity(0.65), MoonStyle.accent.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func moveSelection(to folder: LibraryFolder?) {
        model.mediaStore.moveItems(selectedIDs, to: folder)
        selectedIDs.removeAll()
        selectionMode = false
    }

    @MainActor private func importIntoCurrentFolder() async {
        guard let picker = folderImportSelection,
              let data = try? await picker.loadTransferable(type: Data.self) else { return }
        let type = picker.supportedContentTypes.first
        let kind: MediaKind = type?.conforms(to: .movie) == true ? .video : .image
        let name = kind == .video ? "导入的视频" : "导入的照片"
        let ext = type?.preferredFilenameExtension ?? (kind == .video ? "mov" : "jpg")
        guard let entry = model.mediaStore.importMedia(data, title: name, kind: kind, fileExtension: ext) else { return }
        if let selectedFolder { model.mediaStore.moveItems([entry.id], to: selectedFolder) }
        folderImportSelection = nil
    }
}
