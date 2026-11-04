import SwiftUI
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

/// Grid of library media with previews and a kind filter.
struct Glass3DMediaPicker: View {
    let items: [Glass3DMediaItem]
    var title = L10n.t("选择媒体", "Choose Media")
    var current: String?
    let onPick: (Glass3DMediaItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all

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
        NavigationStack {
            let shown = items.filter { filter.matches($0.kind) }
            ScrollView {
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text(L10n.t("媒体库里还没有图片或视频", "No images or videos in the library yet")).font(.headline)
                        Text(L10n.t("先在「我 → 库」里导入相册里的图片、GIF 或视频。", "Import photos, GIFs or videos in Me → Library first.")).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.top, 80).padding(.horizontal, 24)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 98, maximum: 140), spacing: 12)], spacing: 14) {
                        ForEach(shown) { item in
                            Button { onPick(item); dismiss() } label: {
                                VStack(spacing: 6) {
                                    GeometryReader { geo in Glass3DMediaThumbnail(url: item.url, kind: item.kind, side: geo.size.width, corner: 14) }
                                        .aspectRatio(1, contentMode: .fit)
                                        .overlay(alignment: .topTrailing) {
                                            if item.id == current {
                                                Image(systemName: "checkmark.circle.fill").font(.title3).symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, Color.accentColor).padding(6)
                                            }
                                        }
                                    Text(item.title).font(.caption2).lineLimit(1).foregroundStyle(.primary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.kind.title + " " + item.title)
                            .accessibilityIdentifier("glass3d-media-\(item.id)")
                        }
                    }
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .top) {
                if !items.isEmpty {
                    Picker(L10n.t("类型", "Kind"), selection: $filter) { ForEach(Filter.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.t("取消", "Cancel")) { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("glass3d-media-picker")
    }
}
