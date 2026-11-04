import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// A library file the 3D world can show (image, GIF or video).
struct Glass3DMediaItem: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: RPGMediaKind
    let url: URL
}

@MainActor func glass3DMediaItems(_ store: MediaStore) -> [Glass3DMediaItem] {
    store.items.compactMap { item in
        guard item.kind != .embed, let url = item.remoteURL, url.isFileURL else { return nil }
        let kind = RPGMediaCatalogKind.kind(for: item)
        return kind.usesLibraryFile ? Glass3DMediaItem(id: item.id, title: item.title, kind: kind, url: url) : nil
    }
}

/// Small preview images for library files, made off the main thread and
/// kept in memory (first frame for GIFs and videos).
enum Glass3DThumbnails {
    private final class Cache: @unchecked Sendable {
        let images = NSCache<NSString, UIImage>()
        init() { images.countLimit = 300 }
    }
    private static let cache = Cache()

    static func cached(_ url: URL, pixels: Int) -> UIImage? {
        cache.images.object(forKey: key(url, pixels))
    }
    static func load(_ url: URL, kind: RPGMediaKind, pixels: Int) async -> UIImage? {
        if let hit = cached(url, pixels: pixels) { return hit }
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            if kind == .video { return await videoFrame(url, pixels: pixels) }
            return stillImage(url, pixels: pixels)
        }.value
        if let image { cache.images.setObject(image, forKey: key(url, pixels)) }
        return image
    }

    private static func key(_ url: URL, _ pixels: Int) -> NSString { "\(pixels)|\(url.path)" as NSString }

    private static func stillImage(_ url: URL, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func videoFrame(_ url: URL, pixels: Int) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: frame)
    }
}

/// Square preview with a small kind badge (GIF / video).
struct Glass3DMediaThumbnail: View {
    let url: URL?
    let kind: RPGMediaKind
    var side: CGFloat = 64
    var corner: CGFloat = 12
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.08))
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                Image(systemName: kind == .video ? "film" : "photo").font(.system(size: side * 0.28)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        .overlay(alignment: .bottomLeading) {
            if kind != .image {
                Group {
                    if kind == .video { Image(systemName: "play.fill") } else { Text("GIF") }
                }
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.45), in: Capsule()).padding(4)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let pixels = Int(side * 3)
            if let hit = Glass3DThumbnails.cached(url, pixels: pixels) { image = hit; return }
            let loaded = await Glass3DThumbnails.load(url, kind: kind, pixels: pixels)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

/// Media library sheet for the 3D world: import from Photos or Files,
/// reuse what this world already shows, pick with previews, and delete
/// (long press, or Select for several at once).
struct Glass3DMediaPicker: View {
    @ObservedObject var store: MediaStore
    var title = L10n.t("选择媒体", "Choose Media")
    var current: String?
    /// Library media this world already uses, newest first.
    var used: [String] = []
    let onPick: (Glass3DMediaItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false
    @State private var choosingPhotos = false
    @State private var progress: (done: Int, total: Int)?
    @State private var message: String?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var pendingDelete: [Glass3DMediaItem] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all, image, gif, video
        var id: Self { self }
        var title: String {
            switch self { case .all: L10n.t("全部", "All"); case .image: L10n.t("图片", "Images"); case .gif: "GIF"; case .video: L10n.t("视频", "Videos") }
        }
        func matches(_ kind: RPGMediaKind) -> Bool {
            switch self { case .all: true; case .image: kind == .image; case .gif: kind == .gif; case .video: kind == .video }
        }
    }

    var body: some View {
        let items = glass3DMediaItems(store)
        let shown = items.filter { filter.matches($0.kind) }
        let inUse = used.compactMap { id in items.first { $0.id == id } }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !selecting { importRow }
                    if let progress {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L10n.t("正在导入 \(progress.done)/\(progress.total)…", "Importing \(progress.done)/\(progress.total)…")).font(.subheadline)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else if let message {
                        Label(message, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if !selecting, !inUse.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionTitle(L10n.t("本世界在用", "Used in This World"), detail: L10n.t("点一下直接复用", "Tap to reuse"))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(inUse) { item in
                                        Button { pick(item) } label: {
                                            Glass3DMediaThumbnail(url: item.url, kind: item.kind, side: 72, corner: 14)
                                                .overlay(alignment: .topTrailing) { if item.id == current { check } }
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu { menu(item) }
                                        .accessibilityLabel(L10n.t("复用 ", "Reuse ") + item.title)
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle(L10n.t("媒体库", "Library"), detail: L10n.t("\(items.count) 项 · 长按可删除", "\(items.count) items · long press to delete"))
                        if !items.isEmpty {
                            Picker(L10n.t("类型", "Kind"), selection: $filter) { ForEach(Filter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                        }
                        if items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.stack").font(.system(size: 34)).foregroundStyle(.tertiary)
                                Text(L10n.t("还没有素材，从上面的相册或文件导入", "No media yet. Import from Photos or Files above.")).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 36)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 12)], spacing: 14) {
                                ForEach(shown) { item in cell(item, inUse: used.contains(item.id)) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(selecting ? L10n.t("已选 \(selected.count) 项", "\(selected.count) Selected") : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selecting ? L10n.t("完成", "Done") : L10n.t("关闭", "Close")) {
                        if selecting { selecting = false; selected = [] } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !items.isEmpty && !selecting {
                        Button(L10n.t("选择", "Select")) { selecting = true }.accessibilityIdentifier("glass3d-media-select")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack {
                        Button(selected.count == shown.count ? L10n.t("取消全选", "Deselect All") : L10n.t("全选", "Select All")) {
                            selected = selected.count == shown.count ? [] : Set(shown.map(\.id))
                        }
                        Spacer()
                        Button(role: .destructive) { pendingDelete = items.filter { selected.contains($0.id) } } label: {
                            Label(L10n.t("删除 \(selected.count) 项", "Delete \(selected.count)"), systemImage: "trash")
                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                                .foregroundStyle(.white).background(Color.red.gradient, in: Capsule())
                        }
                        .disabled(selected.isEmpty).opacity(selected.isEmpty ? 0.4 : 1)
                        .accessibilityIdentifier("glass3d-media-delete-selected")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
                }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }), titleVisibility: .visible) {
                Button(L10n.t("删除", "Delete"), role: .destructive) { deletePending() }
                Button(L10n.t("取消", "Cancel"), role: .cancel) { pendingDelete = [] }
            } message: { Text(deleteMessage) }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image, .gif, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onChange(of: photoItems) { picked in if !picked.isEmpty { importPhotos(picked) } }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("glass3d-media-picker")
    }

    // MARK: Pieces

    private var importRow: some View {
        HStack(spacing: 12) {
            Button { choosingPhotos = true } label: {
                importTile(L10n.t("相册", "Photos"), L10n.t("图片 · GIF · 视频", "Images · GIFs · videos"), "photo.on.rectangle.angled", [.orange, .pink])
            }
            .buttonStyle(.plain).accessibilityIdentifier("glass3d-media-photos")
            Button { importingFiles = true } label: {
                importTile(L10n.t("文件", "Files"), L10n.t("从「文件」App 导入", "From the Files app"), "folder.fill", [.blue, .cyan])
            }
            .buttonStyle(.plain).accessibilityIdentifier("glass3d-media-files")
        }
        .disabled(progress != nil)
    }

    private func importTile(_ title: String, _ detail: String, _ symbol: String, _ colors: [Color]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var check: some View {
        Image(systemName: "checkmark.circle.fill").font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor).padding(5)
    }

    private func cell(_ item: Glass3DMediaItem, inUse: Bool) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            if selecting { if isSelected { selected.remove(item.id) } else { selected.insert(item.id) } } else { pick(item) }
        } label: {
            VStack(spacing: 6) {
                GeometryReader { geo in Glass3DMediaThumbnail(url: item.url, kind: item.kind, side: geo.size.width, corner: 14) }
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        if selecting {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").font(.title3)
                                .symbolRenderingMode(.palette).foregroundStyle(.white, isSelected ? Color.red : Color.black.opacity(0.25)).padding(5)
                        } else if item.id == current { check }
                    }
                    .overlay(alignment: .topLeading) {
                        if inUse && !selecting {
                            Text(L10n.t("在用", "In use")).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor, in: Capsule()).padding(5)
                        }
                    }
                    .scaleEffect(selecting && isSelected ? 0.92 : 1)
                Text(item.title).font(.caption2).lineLimit(1).foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { if !selecting { menu(item) } }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .accessibilityLabel(item.kind.title + " " + item.title)
        .accessibilityIdentifier("glass3d-media-\(item.id)")
    }

    @ViewBuilder private func menu(_ item: Glass3DMediaItem) -> some View {
        Button { pick(item) } label: { Label(L10n.t("使用", "Use"), systemImage: "checkmark") }
        Button(role: .destructive) { pendingDelete = [item] } label: { Label(L10n.t("从库中删除", "Delete from Library"), systemImage: "trash") }
    }

    // MARK: Actions

    private func pick(_ item: Glass3DMediaItem) { onPick(item); dismiss() }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? L10n.t("删除这个素材？", "Delete this media?") : L10n.t("删除 \(pendingDelete.count) 个素材？", "Delete \(pendingDelete.count) items?")
    }
    private var deleteMessage: String {
        let inUse = pendingDelete.filter { used.contains($0.id) }.count
        let base = L10n.t("会从媒体库和本机删除，不能撤销。", "They are removed from the library and this device. This cannot be undone.")
        return inUse > 0 ? base + L10n.t("其中 \(inUse) 个正用在这个世界里，删除后那些地方会显示为普通玻璃。", " \(inUse) are used in this world; those places will show plain glass.") : base
    }
    private func deletePending() {
        let ids = Set(pendingDelete.map(\.id))
        for entry in store.items where ids.contains(entry.id) { store.delete(entry) }
        selected.subtract(ids)
        message = L10n.t("已删除 \(ids.count) 项", "Deleted \(ids.count)")
        pendingDelete = []
        if store.items.isEmpty { selecting = false }
    }

    private func importPhotos(_ picked: [PhotosPickerItem]) {
        photoItems = []
        progress = (0, picked.count); message = nil
        Task {
            var imported: [MediaEntry] = []
            for (index, item) in picked.enumerated() {
                if let file = try? await item.loadTransferable(type: RPGPickedFile.self) {
                    let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                    let title = (video ? L10n.t("相册视频 ", "Video ") : L10n.t("相册图片 ", "Photo ")) + Self.stamp()
                    if let entry = await store.importLocalFile(file.url, title: title, kind: video ? .video : .image) { imported.append(entry) }
                    try? FileManager.default.removeItem(at: file.url)
                }
                progress = (index + 1, picked.count)
            }
            finishImport(imported, of: picked.count)
        }
    }

    private func importFiles(_ urls: [URL]) {
        progress = (0, urls.count); message = nil
        Task {
            var imported: [MediaEntry] = []
            for (index, url) in urls.enumerated() {
                let access = url.startAccessingSecurityScopedResource()
                let video = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
                if let entry = await store.importLocalFile(url, title: url.deletingPathExtension().lastPathComponent, kind: video ? .video : .image) { imported.append(entry) }
                if access { url.stopAccessingSecurityScopedResource() }
                progress = (index + 1, urls.count)
            }
            finishImport(imported, of: urls.count)
        }
    }

    /// One new item is used right away; several stay in the grid to choose.
    private func finishImport(_ imported: [MediaEntry], of total: Int) {
        progress = nil
        let failed = total - imported.count
        message = L10n.t("已导入 \(imported.count) 项", "Imported \(imported.count)") + (failed > 0 ? L10n.t("，\(failed) 项失败", ", \(failed) failed") : "")
        if imported.count == 1, let entry = imported.first, let item = glass3DMediaItems(store).first(where: { $0.id == entry.id }) { pick(item) }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: .now)
    }
}
