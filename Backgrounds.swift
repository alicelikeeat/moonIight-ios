import AVFoundation
import CoreTransferable
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MoonGlassButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 12).padding(.vertical, 8)
            .background { GlassCapsule(prominent: prominent) }
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct GlassCapsule: View {
    let prominent: Bool
    var body: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular.tint(prominent ? .accentColor.opacity(0.2) : .clear).interactive(), in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial).overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 0.7))
        }
    }
}

// Weak, live frames keep long-press context aligned with buttons after scrolling
// and navigation. No full-screen hit-test layer is installed.
@MainActor final class BackgroundHitRegistry {
    static var markers = NSHashTable<BackgroundTargetMarker>.weakObjects()
    static func target(at point: CGPoint, in window: UIWindow) -> BackgroundTarget? {
        markers.allObjects.filter { $0.window === window && !$0.isHidden && $0.convert($0.bounds, to: window).contains(point) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.target
    }
}

final class BackgroundTargetMarker: UIView {
    var target: BackgroundTarget = .allButtons
    init() { super.init(frame: .zero); isUserInteractionEnabled = false; BackgroundHitRegistry.markers.add(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct BackgroundTargetAnchor: UIViewRepresentable {
    let target: BackgroundTarget
    func makeUIView(context: Context) -> BackgroundTargetMarker { BackgroundTargetMarker() }
    func updateUIView(_ view: BackgroundTargetMarker, context: Context) { view.target = target }
}

enum BackgroundTarget: String, Codable, CaseIterable, Identifiable {
    case allPages = "page.all", home = "page.home", discover = "page.discover", camera = "page.camera"
    case moments = "page.moments", me = "page.me", library = "page.library", settings = "page.settings"
    case friends = "page.friends", messages = "page.messages", profile = "page.profile", composer = "page.composer"
    case allButtons = "button.all", tabHome = "button.home", tabDiscover = "button.discover", tabCamera = "button.camera"
    case tabMoments = "button.moments", tabMe = "button.me", discoverSources = "button.sources", discoverLayout = "button.layout"
    case allRingButtons = "ring.all", ringCenter = "ring.center", ringPlay = "ring.play", ringFavorite = "ring.favorite"
    case ringLibrary = "ring.library", ringShare = "ring.share"
    case allPanels = "panel.all", sourcePanel = "panel.sources", actionsPanel = "panel.actions"
    case avatar = "profile.avatar", cover = "profile.cover"

    var id: String { rawValue }
    var section: String {
        if rawValue.hasPrefix("page.") { return "页面背景" }
        if rawValue.hasPrefix("button.") { return "按键背景" }
        if rawValue.hasPrefix("ring.") { return "长按菜单" }
        if rawValue.hasPrefix("panel.") { return "面板背景" }
        return "个人资料"
    }
    static let sections = ["页面背景", "按键背景", "长按菜单", "面板背景", "个人资料"]
    var isButton: Bool { rawValue.hasPrefix("button.") || rawValue.hasPrefix("ring.") }
    var title: String {
        switch self {
        case .allPages: "通用页面背景"
        case .home, .tabHome: "首页"
        case .discover, .tabDiscover: "发现"
        case .camera, .tabCamera: "拍摄"
        case .moments, .tabMoments: "朋友圈"
        case .me, .tabMe: "我"
        case .library: "库"
        case .settings: "设置"
        case .friends: "朋友和个人主页"
        case .messages: "消息"
        case .profile: "编辑资料"
        case .composer: "发布动态"
        case .allButtons: "通用玻璃按键"
        case .discoverSources: "发现 · 内容源"
        case .discoverLayout: "发现 · 布局切换"
        case .allRingButtons: "圆环通用背景"
        case .ringCenter: "圆环中心 · 更多"
        case .ringPlay: "圆环 · 打开"
        case .ringFavorite: "圆环 · 收藏"
        case .ringLibrary: "圆环 · 加入库"
        case .ringShare: "圆环 · 分享"
        case .allPanels: "通用面板背景"
        case .sourcePanel: "内容源侧栏"
        case .actionsPanel: "更多操作面板"
        case .avatar: "个人头像"
        case .cover: "个人顶部横幅"
        }
    }
    var fallback: BackgroundTarget? {
        if rawValue.hasPrefix("page."), self != .allPages { return .allPages }
        if rawValue.hasPrefix("button."), self != .allButtons { return .allButtons }
        if rawValue.hasPrefix("ring."), self != .allRingButtons { return .allRingButtons }
        if self == .allRingButtons { return .allButtons }
        if rawValue.hasPrefix("panel."), self != .allPanels { return .allPanels }
        return nil
    }
    static func page(for tab: AppTab) -> BackgroundTarget {
        switch tab { case .home: .home; case .discover: .discover; case .camera: .camera; case .moments: .moments; case .me: .me }
    }
    static func button(for tab: AppTab) -> BackgroundTarget {
        switch tab { case .home: .tabHome; case .discover: .tabDiscover; case .camera: .tabCamera; case .moments: .tabMoments; case .me: .tabMe }
    }
    static func ring(for action: QuickActionID) -> BackgroundTarget {
        switch action { case .play: .ringPlay; case .favorite: .ringFavorite; case .library: .ringLibrary; case .share: .ringShare }
    }
}

enum BackgroundVeil: String, Codable, CaseIterable, Identifiable {
    case theme, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .theme: "跟随外观"; case .light: "浅色"; case .dark: "深色" } }
    var color: Color { switch self { case .theme: Color(uiColor: .systemBackground); case .light: .white; case .dark: .black } }
    var foreground: Color { switch self { case .theme: .primary; case .light: .black; case .dark: .white } }
}

struct BackgroundAsset: Codable, Identifiable, Equatable {
    var id: String
    var fileName: String
    var posterName: String?
    var isVideo: Bool
    var createdAt: Date
}

struct BackgroundConfiguration: Codable, Equatable {
    var assetID: String
    var scale = 1.0
    var x = 0.0
    var y = 0.0
    var veil = BackgroundVeil.theme
    var opacity = 0.4
    mutating func clamp() {
        scale = min(4, max(1, scale))
        let limit = (scale - 1) / 2
        x = min(limit, max(-limit, x)); y = min(limit, max(-limit, y))
        opacity = min(0.95, max(0, opacity))
    }
}

private struct BackgroundLibraryState: Codable {
    var assets: [BackgroundAsset]
    var configurations: [String: BackgroundConfiguration]
    var playlists: [String: ButtonBackgroundPlaylist]? = nil
}

enum BackgroundPlaybackMode: String, Codable, CaseIterable, Identifiable {
    case fixed, sequence, random, shuffle
    var id: String { rawValue }
    var title: String { switch self { case .fixed: "固定"; case .sequence: "顺序循环"; case .random: "随机"; case .shuffle: "洗牌循环" } }
}
struct ButtonBackgroundPlaylist: Codable, Equatable {
    var assetIDs: [String] = []
    var mode = BackgroundPlaybackMode.fixed
    var interval = 12.0
}

private struct BackgroundMovieTransfer: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("background-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return BackgroundMovieTransfer(url: copy)
        }
    }
}

@MainActor
final class BackgroundStore: ObservableObject {
    static let shared = BackgroundStore()
    @Published private(set) var assets: [BackgroundAsset] = []
    @Published private(set) var configurations: [String: BackgroundConfiguration] = [:]
    @Published private(set) var playlists: [String: ButtonBackgroundPlaylist] = [:]
    private let directory: URL
    private let manifest: URL
    private let imageCache = NSCache<NSString, UIImage>()
    #if DEBUG
    @Published private(set) var uiTestReady = false
    #endif

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("backgrounds", isDirectory: true)
        manifest = directory.appendingPathComponent("backgrounds.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        imageCache.totalCostLimit = 64 * 1024 * 1024
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode(BackgroundLibraryState.self, from: data) {
            assets = saved.assets; configurations = saved.configurations; playlists = saved.playlists ?? [:]
        }
        for target in [BackgroundTarget.avatar, .cover] where configurations[target.rawValue] == nil {
            let key = target == .avatar ? "moonlight.profile.avatarPath" : "moonlight.profile.coverPath"
            if let path = UserDefaults.standard.string(forKey: key), FileManager.default.fileExists(atPath: path) {
                let asset = BackgroundAsset(id: UUID().uuidString, fileName: path, isVideo: ["mov", "mp4", "m4v"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()), createdAt: .now)
                assets.append(asset)
                var config = BackgroundConfiguration(assetID: asset.id); config.opacity = 0
                configurations[target.rawValue] = config
            }
        }
    }

    func resolved(_ target: BackgroundTarget) -> BackgroundConfiguration? {
        if let config = configurations[target.rawValue], assets.contains(where: { $0.id == config.assetID }) { return config }
        if let fallback = target.fallback { return resolved(fallback) }
        return nil
    }

    func asset(_ config: BackgroundConfiguration?) -> BackgroundAsset? {
        guard let config else { return nil }
        return assets.first { $0.id == config.assetID }
    }

    func playlist(for target: BackgroundTarget) -> ButtonBackgroundPlaylist? {
        guard target.isButton else { return nil }
        if let list = playlists[target.rawValue] { return list }
        if let fallback = target.fallback { return playlist(for: fallback) }
        return nil
    }
    func setPlaylist(_ playlist: ButtonBackgroundPlaylist, for target: BackgroundTarget) {
        var value = playlist
        var seen = Set<String>()
        value.assetIDs = value.assetIDs.filter { id in assets.contains { $0.id == id } && seen.insert(id).inserted }
        value.interval = min(120, max(3, value.interval))
        playlists[target.rawValue] = value; persist()
    }
    func resetPlaylist(for target: BackgroundTarget) { playlists.removeValue(forKey: target.rawValue); persist() }

    func url(for asset: BackgroundAsset) -> URL {
        if asset.fileName.hasPrefix("/") {
            let original = URL(fileURLWithPath: asset.fileName)
            if FileManager.default.fileExists(atPath: original.path) { return original }
            return directory.deletingLastPathComponent().appendingPathComponent("profile").appendingPathComponent(original.lastPathComponent)
        }
        return directory.appendingPathComponent(asset.fileName)
    }

    func image(for asset: BackgroundAsset, thumbnail: Bool = false) -> UIImage? {
        let key = "\(asset.id)-\(thumbnail)" as NSString
        if let image = imageCache.object(forKey: key) { return image }
        let imageURL = asset.isVideo ? asset.posterName.map { directory.appendingPathComponent($0) } : url(for: asset)
        guard let imageURL, let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: thumbnail ? 320 : 2560,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        imageCache.setObject(image, forKey: key, cost: cg.width * cg.height * 4)
        return image
    }

    func set(_ configuration: BackgroundConfiguration, for target: BackgroundTarget) {
        var config = configuration; config.clamp()
        configurations[target.rawValue] = config
        if target == .avatar || target == .cover, let asset = asset(config) {
            UserDefaults.standard.set(url(for: asset).path, forKey: target == .avatar ? "moonlight.profile.avatarPath" : "moonlight.profile.coverPath")
        }
        persist()
    }

    func reset(_ target: BackgroundTarget) {
        configurations.removeValue(forKey: target.rawValue)
        if target == .avatar || target == .cover { UserDefaults.standard.removeObject(forKey: target == .avatar ? "moonlight.profile.avatarPath" : "moonlight.profile.coverPath") }
        persist()
    }

    func use(_ asset: BackgroundAsset, for target: BackgroundTarget) {
        var config = BackgroundConfiguration(assetID: asset.id)
        if target.isButton { config.veil = .dark; config.opacity = 0.28 }
        if target == .avatar || target == .cover { config.opacity = 0 }
        set(config, for: target)
    }

    @discardableResult
    func importSelection(_ item: PhotosPickerItem, for target: BackgroundTarget, apply: Bool = true) async throws -> BackgroundAsset {
        let id = UUID().uuidString
        let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        var asset: BackgroundAsset
        if video {
            guard let movie = try await item.loadTransferable(type: BackgroundMovieTransfer.self) else { throw BackgroundImportError.unreadable }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let name = "\(id).\(movie.url.pathExtension)"
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.moveItem(at: movie.url, to: destination)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            var poster: String?
            if let result = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)),
               let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.85) {
                let name = "\(id)-poster.jpg"
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                poster = name
            }
            asset = BackgroundAsset(id: id, fileName: name, posterName: poster, isVideo: true, createdAt: .now)
        } else {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw BackgroundImportError.unreadable }
            let jpeg = try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                              kCGImageSourceThumbnailMaxPixelSize: 2560,
                                                                              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw BackgroundImportError.unreadable }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw BackgroundImportError.unreadable }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw BackgroundImportError.unreadable }
                return Data(referencing: output)
            }.value
            let name = "\(id).jpg"
            try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
            asset = BackgroundAsset(id: id, fileName: name, isVideo: false, createdAt: .now)
        }
        assets.insert(asset, at: 0)
        if apply { use(asset, for: target) } else { persist() }
        return asset
    }

    private var usedIDs: Set<String> { Set(configurations.values.map(\.assetID)).union(playlists.values.flatMap(\.assetIDs)) }
    var unusedCount: Int { assets.filter { !usedIDs.contains($0.id) }.count }
    func cleanUnused() {
        let unused = assets.filter { !usedIDs.contains($0.id) }
        let used = assets.filter { usedIDs.contains($0.id) }
        var protected = Set(used.map { url(for: $0).standardizedFileURL.path })
        protected.formUnion(used.compactMap(\.posterName).map { directory.appendingPathComponent($0).standardizedFileURL.path })
        let profileDirectory = directory.deletingLastPathComponent().appendingPathComponent("profile").standardizedFileURL.path + "/"
        for asset in unused {
            let file = url(for: asset).standardizedFileURL
            if !protected.contains(file.path), file.path.hasPrefix(directory.standardizedFileURL.path + "/") || file.path.hasPrefix(profileDirectory) {
                try? FileManager.default.removeItem(at: file)
            }
            if let poster = asset.posterName {
                let file = directory.appendingPathComponent(poster).standardizedFileURL
                if !protected.contains(file.path), file.path.hasPrefix(directory.standardizedFileURL.path + "/") { try? FileManager.default.removeItem(at: file) }
            }
        }
        let ids = Set(unused.map(\.id)); assets.removeAll { ids.contains($0.id) }
        imageCache.removeAllObjects(); persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(BackgroundLibraryState(assets: assets, configurations: configurations, playlists: playlists)) { try? data.write(to: manifest, options: .atomic) }
    }

    #if DEBUG
    func prepareUITestMedia() async {
        guard !uiTestReady else { return }
        let imageID = "ui-test-background-image", videoID = "ui-test-background-video"
        let imageName = imageID + ".jpg", videoName = videoID + ".mp4"
        if !assets.contains(where: { $0.id == imageID }) {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 640)).image { context in
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 640))
                UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 320, width: 320, height: 320))
            }
            try? image.jpegData(compressionQuality: 0.9)?.write(to: directory.appendingPathComponent(imageName))
            assets.append(BackgroundAsset(id: imageID, fileName: imageName, isVideo: false, createdAt: .now))
        }
        let videoURL = directory.appendingPathComponent(videoName)
        if !FileManager.default.fileExists(atPath: videoURL.path) {
            do {
                let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
                writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
                for index in 0..<12 {
                    while !input.isReadyForMoreMediaData, writer.status == .writing { try await Task.sleep(nanoseconds: 10_000_000) }
                    var buffer: CVPixelBuffer?
                    CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
                    guard let buffer else { continue }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(40 + index * 12), CVPixelBufferGetDataSize(buffer)) }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 6))
                }
                input.markAsFinished(); await writer.finishWriting()
                guard writer.status == .completed else { return }
            } catch { return }
        }
        if !assets.contains(where: { $0.id == videoID }) {
            assets.append(BackgroundAsset(id: videoID, fileName: videoName, posterName: imageName, isVideo: true, createdAt: .now))
        }
        if let image = assets.first(where: { $0.id == imageID }), let video = assets.first(where: { $0.id == videoID }) {
            use(image, for: .allPages); use(video, for: .allButtons)
            uiTestReady = true
        }
    }
    #endif
}

private enum BackgroundImportError: LocalizedError {
    case unreadable
    var errorDescription: String? { "无法读取所选媒体，请重新选择。" }
}

struct BackgroundMediaLayer: View {
    @EnvironmentObject private var store: BackgroundStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: BackgroundConfiguration
    var paused = false
    var body: some View {
        GeometryReader { geometry in
            if let asset = store.asset(configuration) {
                ZStack {
                    if asset.isVideo, !paused, !reduceMotion, !ProcessInfo.processInfo.isLowPowerModeEnabled, scenePhase == .active {
                        BackgroundVideoLoop(url: store.url(for: asset))
                    } else if let image = store.image(for: asset) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else { Color.black }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(configuration.scale)
                .offset(x: configuration.x * geometry.size.width, y: configuration.y * geometry.size.height)
                .overlay(configuration.veil.color.opacity(configuration.opacity))
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PageBackground: View {
    @EnvironmentObject private var store: BackgroundStore
    let target: BackgroundTarget
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            if let config = store.resolved(target) { BackgroundMediaLayer(configuration: config) }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ProfileBackgroundMedia: View {
    @EnvironmentObject private var store: BackgroundStore
    let target: BackgroundTarget
    var paused = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.7), Color(red: 0.48, green: 0.45, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let config = store.resolved(target) { BackgroundMediaLayer(configuration: config, paused: paused) }
            else if target == .avatar { Image(systemName: "person.fill").resizable().scaledToFit().foregroundStyle(.white.opacity(0.9)).padding(14) }
        }.accessibilityHidden(true)
    }
}

struct OptionalMediaBackground: View {
    @EnvironmentObject private var store: BackgroundStore
    let target: BackgroundTarget
    var body: some View {
        if let config = store.resolved(target) { BackgroundMediaLayer(configuration: config) }
    }
}

private struct BackgroundVideoLoop: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> BackgroundVideoView { BackgroundVideoView(url: url) }
    func updateUIView(_ view: BackgroundVideoView, context: Context) { view.configure(url) }
    static func dismantleUIView(_ view: BackgroundVideoView, coordinator: ()) { view.stop() }
}

private final class BackgroundVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    init(url: URL) { super.init(frame: .zero); isUserInteractionEnabled = false; configure(url) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ url: URL) {
        guard currentURL != url else { return }
        stop(); currentURL = url
        let queue = AVQueuePlayer(); queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        let loop = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        let videoLayer = layer as! AVPlayerLayer
        videoLayer.videoGravity = .resizeAspectFill; videoLayer.player = queue
        player = queue; looper = loop
        if window != nil { queue.play() }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { player?.pause() } else { player?.play() } }
    func stop() { player?.pause(); looper?.disableLooping(); looper = nil; player?.removeAllItems(); player = nil; currentURL = nil }
}

struct MediaGlassCircle: ViewModifier {
    @EnvironmentObject private var store: BackgroundStore
    let target: BackgroundTarget
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentAssetID: String?
    @State private var shuffled: [String] = []
    func body(content: Content) -> some View {
        let playlist = store.playlist(for: target)
        let configuration = resolvedConfiguration(playlist)
        let decorated = content.background {
            BackgroundTargetAnchor(target: target)
            if let configuration { BackgroundMediaLayer(configuration: configuration).clipShape(Circle()) }
        }
        if #available(iOS 26.0, *) {
            if let configuration { decorated.foregroundStyle(configuration.veil.foreground).glassEffect(.regular.interactive(), in: Circle()).modifier(BackgroundClock(list: playlist, phase: scenePhase, reduceMotion: reduceMotion, advance: advance)) }
            else { decorated.glassEffect(.regular.interactive(), in: Circle()).modifier(BackgroundClock(list: playlist, phase: scenePhase, reduceMotion: reduceMotion, advance: advance)) }
        } else {
            if let configuration {
                decorated.foregroundStyle(configuration.veil.foreground).background(.ultraThinMaterial, in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1)).modifier(BackgroundClock(list: playlist, phase: scenePhase, reduceMotion: reduceMotion, advance: advance))
            } else {
                decorated.background(.ultraThinMaterial, in: Circle()).overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1)).modifier(BackgroundClock(list: playlist, phase: scenePhase, reduceMotion: reduceMotion, advance: advance))
            }
        }
    }
    private func resolvedConfiguration(_ playlist: ButtonBackgroundPlaylist?) -> BackgroundConfiguration? {
        guard let list = playlist, let id = currentAssetID.flatMap({ list.assetIDs.contains($0) ? $0 : nil }) ?? list.assetIDs.first,
              store.assets.contains(where: { $0.id == id }) else { return store.resolved(target) }
        var configuration = store.resolved(target) ?? BackgroundConfiguration(assetID: id)
        configuration.assetID = id
        return configuration
    }
    private func advance(_ first: Bool) {
        guard let list = store.playlist(for: target), !list.assetIDs.isEmpty else { return }
        if first || list.mode == .fixed { currentAssetID = list.assetIDs.first; shuffled = []; return }
        switch list.mode {
        case .fixed: break
        case .sequence:
            let index = currentAssetID.flatMap { list.assetIDs.firstIndex(of: $0) } ?? -1
            currentAssetID = list.assetIDs[(index + 1) % list.assetIDs.count]
        case .random: currentAssetID = list.assetIDs.filter { $0 != currentAssetID }.randomElement() ?? list.assetIDs.first
        case .shuffle:
            if shuffled.isEmpty {
                shuffled = list.assetIDs.shuffled()
                if shuffled.count > 1 && shuffled.last == currentAssetID { shuffled.swapAt(0, shuffled.count - 1) }
            }
            currentAssetID = shuffled.popLast()
        }
    }
}

private struct BackgroundClock: ViewModifier {
    let list: ButtonBackgroundPlaylist?
    let phase: ScenePhase
    let reduceMotion: Bool
    let advance: (Bool) -> Void
    func body(content: Content) -> some View {
        content.task(id: "\(list.map { String(describing: $0) } ?? "none")-\(phase)-\(reduceMotion)") {
            advance(true)
            guard let list, list.mode != .fixed, list.assetIDs.count > 1, phase == .active, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(3, list.interval) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                advance(false)
            }
        }
    }
}

extension View {
    @ViewBuilder func moonGlassPanel() -> some View {
        if #available(iOS 26.0, *) { glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16)) }
        else { background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    }
    func pageBackground(_ target: BackgroundTarget) -> some View {
        background { PageBackground(target: target).ignoresSafeArea(); BackgroundTargetAnchor(target: target) }
    }
}

