import AVKit
import PhotosUI
import SwiftUI
import UIKit
import ImageIO
import Combine

struct LocalMediaImage: View {
    let url: URL
    var fill = false
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
            else { Color.secondary.opacity(0.12).overlay(ProgressView()) }
        }.task(id: url) {
            let file = url
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { return nil }
                let bytes = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { return nil }
                return Data(referencing: bytes)
            }.value
            if !Task.isCancelled, let data { image = UIImage(data: data) }
        }
    }
}

struct ContextMenuSettingsView: View {
    @ObservedObject private var preferences = InteractionPreferences.shared
    var body: some View {
        List {
            Section("底部导航") {
                Picker("布局", selection: $preferences.navigationMode) {
                    ForEach(BottomNavigationMode.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("bottom-navigation-mode")
                Text("独立圆形模式保留按钮之间的滚动区域；原生滑块模式可横向拖动切换页面，停在拍摄位置后松手打开相机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("长按菜单") {
                Text("每个位置单独设置并保存顺序。前 4 项显示在圆环，其余放进中心 … 的面板。媒体操作需要具体媒体，系统相机和照片选择器保留系统操作。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("媒体卡片") { ContextActionEditor(context: "media", title: "媒体卡片") }
                ForEach(BackgroundTarget.allCases.filter { $0.rawValue.hasPrefix("page.") || $0.rawValue.hasPrefix("button.") }) { target in
                    NavigationLink(target.section + " · " + target.title) { ContextActionEditor(context: target.rawValue, title: target.title) }
                }
            }
            Section("玻璃样式说明") {
                Text("应用自有操作按键使用 Liquid Glass（iOS 26）或系统毛玻璃（较早系统）。媒体图片和视频本身保留清晰预览；相机、键盘、系统照片选择器、分享面板、第三方网页播放器的内部控件由系统或平台管理，应用无法统一替换。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("长按与底栏").pageBackground(.settings)
    }
}

private struct ContextActionEditor: View {
    let context: String
    let title: String
    @ObservedObject private var preferences = InteractionPreferences.shared
    var body: some View {
        List {
            Section("已选操作 · 拖动排序") {
                ForEach(Array(preferences.actions(context).enumerated()), id: \.element) { index, action in
                    Label(action.title + (index < 4 ? " · 圆环" : " · 更多"), systemImage: action.symbol)
                }.onMove { from, to in
                    var actions = preferences.actions(context); actions.move(fromOffsets: from, toOffset: to); preferences.set(actions, for: context)
                }.onDelete { offsets in
                    var actions = preferences.actions(context); actions.remove(atOffsets: offsets); preferences.set(actions, for: context)
                }
            }
            Section("应用操作目录") {
                ForEach(AppCommand.allCases) { action in
                    Toggle(isOn: Binding(get: { preferences.actions(context).contains(action) }, set: { enabled in
                        var actions = preferences.actions(context)
                        if enabled { actions.append(action) } else { actions.removeAll { $0 == action } }
                        preferences.set(actions, for: context)
                    })) { Label(action.title, systemImage: action.symbol) }
                    .accessibilityIdentifier("menu-action-\(action.rawValue)")
                }
            }
            Button("恢复当前页面默认菜单") { preferences.reset(context) }
        }.navigationTitle(title).toolbar { EditButton() }.pageBackground(.settings)
    }
}

struct GestureHelpView: View {
    var body: some View {
        List {
            Label("移动先交给滚动；静止按住才打开圆环", systemImage: "arrow.up.and.down")
            Label("长按旋转展开并提供触感反馈；默认松手后再点选", systemImage: "hand.point.up.left")
            Label("底部按钮的菜单向上避让，不与导航键重叠", systemImage: "arrow.up.left.and.arrow.down.right")
            Label("首页长按：从库或内容源进入抖音模式", systemImage: "play.rectangle")
            Label("抖音模式上下滑换条目，点按本地或直链视频暂停 / 播放，双击收藏", systemImage: "hand.tap")
            Label("拍摄点按打开系统相机，长按可拍照、录像、导入", systemImage: "camera")
            Label("系统输入、照片选择和相机保留系统交互", systemImage: "keyboard")
        }.navigationTitle("手势说明").pageBackground(.settings)
    }
}

enum ReelsSource: String { case library, sources }

struct ReelsView: View {
    let source: ReelsSource
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [MediaEntry] = []
    @State private var index = 0
    @State private var loading = false
    @State private var actionEntry: MediaEntry?
    @AppStorage("moonlight.reels.photos.seconds") private var photoSeconds = 6.0
    @AppStorage("moonlight.reels.autoAdvance") private var autoAdvance = true
    @AppStorage("moonlight.reels.muted") private var muted = false
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if entries.isEmpty {
                VStack(spacing: 18) {
                    if loading { ProgressView().tint(.white) }
                    Text(loading ? "正在读取内容…" : "还没有可以播放的内容").foregroundStyle(.white)
                    Text(source == .library ? "先在库中导入图片或视频。" : "在发现中启用内容源后重试。").foregroundStyle(.white.opacity(0.7))
                    Button("重新加载") { Task { await load() } }
                }.frame(maxHeight: .infinity)
            } else {
                VerticalReelsPager(entries: entries, favoriteIDs: Set(model.mediaStore.items.filter(\.isFavorite).map(\.id)), index: $index, scenePhase: actionEntry == nil ? scenePhase : .inactive, muted: muted, autoAdvance: autoAdvance, photoSeconds: photoSeconds,
                    onOptions: { actionEntry = $0 }, onFavorite: { model.mediaStore.toggleFavorite($0) }, onNext: next)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("vertical-reels-pager")
            }
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.accessibilityLabel("关闭抖音模式")
                Text(source == .library ? "库 · 抖音模式" : "内容源 · 抖音模式").font(.subheadline.bold())
                Spacer()
                Text(entries.isEmpty ? "" : "\(index + 1) / \(entries.count)").font(.caption.monospacedDigit()).accessibilityIdentifier("reels-position")
                Button { muted.toggle() } label: { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.accessibilityLabel("切换静音")
                Menu {
                    Toggle("自动播放下一条", isOn: $autoAdvance)
                    Picker("图片停留", selection: $photoSeconds) { ForEach([3.0, 6, 10, 15], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                } label: { Image(systemName: "slider.horizontal.3") }
            }.foregroundStyle(.white).padding(12)
        }.buttonStyle(MoonGlassButtonStyle()).task { await load() }
        .onChange(of: index) { value in if source == .sources && value >= entries.count - 3 { Task { await load(append: true) } } }
        .sheet(item: $actionEntry) { entry in
            QuickActionsPanel(entry: entry, onPlay: { actionEntry = nil }).environmentObject(model)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
    private func next() {
        guard !entries.isEmpty else { return }
        if index < entries.count - 1 { withAnimation { index += 1 } }
        else if source == .library { withAnimation { index = 0 } }
        else { Task { await load(append: true); if index < entries.count - 1 { index += 1 } else if !entries.isEmpty { index = 0 } } }
    }
    private func load(append: Bool = false) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        if source == .library { entries = model.mediaStore.items; index = min(index, max(0, entries.count - 1)); return }
        if !append && !model.mediaStore.discoverItems.isEmpty { entries = model.mediaStore.discoverItems.shuffled(); return }
        await model.mediaStore.refreshDiscover()
        let incoming = model.mediaStore.discoverItems.shuffled()
        if append {
            let seen = Set(entries.map(\.identity)); entries.append(contentsOf: incoming.filter { !seen.contains($0.identity) })
        } else { entries = incoming; index = 0 }
    }
}

private struct VerticalReelsPager: UIViewControllerRepresentable {
    let entries: [MediaEntry]
    let favoriteIDs: Set<String>
    @Binding var index: Int
    let scenePhase: ScenePhase
    let muted: Bool
    let autoAdvance: Bool
    let photoSeconds: Double
    let onOptions: (MediaEntry) -> Void
    let onFavorite: (MediaEntry) -> Void
    let onNext: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical)
        controller.dataSource = context.coordinator; controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        context.coordinator.pager = controller
        if !entries.isEmpty { controller.setViewControllers([context.coordinator.page(index)], direction: .forward, animated: false) }
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        guard !entries.isEmpty else { return }
        let visible = (controller.viewControllers?.first as? ReelHost)?.pageIndex ?? -1
        if visible != index && !coordinator.turning {
            controller.setViewControllers([coordinator.page(index)], direction: index > visible ? .forward : .reverse, animated: false)
        }
        for (key, host) in coordinator.hosts { host.rootView = coordinator.content(key) }
        // Only keep the current page and its neighbors, releasing old players.
        coordinator.hosts = coordinator.hosts.filter { abs($0.key - index) <= 1 }
    }
    final class ReelHost: UIHostingController<ReelPage> { var pageIndex = 0 }
    @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: VerticalReelsPager
        weak var pager: UIPageViewController?
        var hosts: [Int: ReelHost] = [:]
        var turning = false
        init(_ parent: VerticalReelsPager) { self.parent = parent }
        func content(_ value: Int) -> ReelPage {
            var entry = parent.entries[min(max(0, value), parent.entries.count - 1)]
            entry.isFavorite = parent.favoriteIDs.contains(entry.id)
            return ReelPage(entry: entry, active: value == parent.index, scenePhase: parent.scenePhase,
                     muted: parent.muted, autoAdvance: parent.autoAdvance, photoSeconds: parent.photoSeconds,
                     onOptions: parent.onOptions, onFavorite: parent.onFavorite, onNext: parent.onNext)
        }
        func page(_ value: Int) -> ReelHost {
            if let host = hosts[value] { host.rootView = content(value); return host }
            let host = ReelHost(rootView: content(value)); host.pageIndex = value; host.view.backgroundColor = .black; hosts[value] = host; return host
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let host = viewController as? ReelHost, host.pageIndex > 0 else { return nil }; return page(host.pageIndex - 1)
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let host = viewController as? ReelHost, host.pageIndex + 1 < parent.entries.count else { return nil }; return page(host.pageIndex + 1)
        }
        func pageViewController(_ controller: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { turning = true }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            turning = false
            if completed, let host = controller.viewControllers?.first as? ReelHost { parent.index = host.pageIndex }
        }
    }
}

private struct ReelPage: View {
    let entry: MediaEntry
    let active: Bool
    let scenePhase: ScenePhase
    let muted: Bool
    let autoAdvance: Bool
    let photoSeconds: Double
    let onOptions: (MediaEntry) -> Void
    let onFavorite: (MediaEntry) -> Void
    let onNext: () -> Void
    @State private var player: AVPlayer?
    @State private var paused = false
    @State private var playbackStatus = "缓冲中"
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            Group {
                if entry.kind == .embed, let url = entry.embedURL, active {
                    WebEmbedView(url: url, scrolling: false)
                } else if entry.kind == .video, let player {
                    VideoPlayer(player: player)
                        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                            playbackStatus = status == .playing ? "正在播放" : status == .waitingToPlayAtSpecifiedRate ? "缓冲中" : "已暂停"
                        }
                } else if entry.kind == .image, let url = entry.remoteURL {
                    if url.isFileURL { LocalMediaImage(url: url) }
                    else { AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) } }
                } else if let cover = entry.coverURL {
                    AsyncImage(url: cover) { image in image.resizable().scaledToFit() } placeholder: { ProgressView().tint(.white) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if entry.kind != .embed {
                CardGestureSurface(onTap: toggle, onHoldBegan: { _ in onOptions(entry) }, onHoldMoved: { _ in }, onHoldEnded: {},
                    onDoubleTap: { if !entry.isFavorite { onFavorite(entry) } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title).font(.headline).lineLimit(3)
                Text(entry.author.isEmpty ? entry.platform : entry.author).font(.caption)
                if entry.kind == .embed { Text("平台播放器可能需要点按开始播放，上下滑动切换内容。").font(.caption2) }
                HStack {
                    Button { onFavorite(entry) } label: { Label(entry.isFavorite ? "已收藏" : "收藏", systemImage: entry.isFavorite ? "heart.fill" : "heart") }
                    Button { onOptions(entry) } label: { Label("更多", systemImage: "ellipsis") }
                    if entry.kind != .embed {
                        Button(action: toggle) { Image(systemName: paused ? "play.fill" : "pause.fill") }
                            .accessibilityLabel("播放或暂停").accessibilityValue(entry.kind == .video ? playbackStatus : paused ? "已暂停" : "图片展示中")
                    }
                }
            }.foregroundStyle(.white).padding(18).padding(.bottom, 28)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }.buttonStyle(MoonGlassButtonStyle())
        .onChange(of: active) { _ in updatePlayer() }.onChange(of: muted) { value in player?.isMuted = value }
        .onChange(of: scenePhase) { _ in updatePlayer() }.onDisappear { player?.pause(); player = nil }
        .task(id: "\(active)-\(paused)-\(autoAdvance)-\(photoSeconds)-\(scenePhase)") {
            updatePlayer()
            if active && entry.kind == .image && autoAdvance && !paused {
                try? await Task.sleep(nanoseconds: UInt64(max(3, photoSeconds) * 1_000_000_000))
                if !Task.isCancelled && !paused && scenePhase == .active { onNext() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard active, scenePhase == .active, let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            if paused { player?.seek(to: .zero); return }
            if autoAdvance { onNext() } else { player?.seek(to: .zero); player?.play() }
        }
    }
    private func toggle() { paused.toggle(); if paused { player?.pause() } else { player?.play() } }
    private func updatePlayer() {
        guard active, scenePhase == .active else { player?.pause(); if !active { player = nil }; return }
        if entry.kind == .video, player == nil, let url = entry.remoteURL { player = AVPlayer(url: url) }
        player?.isMuted = muted
        if !paused { player?.play() }
    }
}

