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
    @AppStorage("moonlight.globalSearch.enabled") private var globalSearchEnabled = false
    @AppStorage("moonlight.navigation.hideDelay") private var navigationHideDelay = 5.0
    var body: some View {
        List {
            Section("底部导航") {
                Picker("布局", selection: $preferences.navigationMode) {
                    ForEach(BottomNavigationMode.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("bottom-navigation-mode")
                Text("独立圆形模式保留按钮之间的滚动区域；原生滑块模式可横向拖动切换页面；智能输入栏提供 ChatGPT 风格提问入口。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("自动隐藏", selection: $navigationHideDelay) {
                    Text("关闭").tag(0.0)
                    Text("5 秒").tag(5.0)
                    Text("15 秒").tag(15.0)
                    Text("30 秒").tag(30.0)
                }
                Text("无操作后淡出；轻点屏幕底部空白区会立即显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("全局长按搜索") {
                Toggle("长按弹出智能搜索", isOn: $globalSearchEnabled)
                Text("开启后，在任意页面静止长按会弹出玻璃搜索条。输入功能名会显示直达气泡；点“问 ChatGPT”或回车进入对话页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("长按菜单") {
                Text("关闭全局搜索时，可先设置页面或按键的通用菜单，再按需覆盖具体位置。前 4 项显示在圆环，其余放进中心 … 的面板。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("媒体卡片") { ContextActionEditor(context: "media", title: "媒体卡片") }
                NavigationLink("页面长按菜单") { ContextTargetListView(section: "page.", common: .allPages) }
                NavigationLink("按键长按菜单") { ContextTargetListView(section: "button.", common: .allButtons) }
            }
            Section("玻璃样式说明") {
                Text("应用自有操作按键使用 Liquid Glass（iOS 26）或系统毛玻璃（较早系统）。媒体图片和视频本身保留清晰预览；相机、键盘、系统照片选择器、分享面板、第三方网页播放器的内部控件由系统或平台管理，应用无法统一替换。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("长按与底栏").pageBackground(.settings)
    }
}

private struct ContextTargetListView: View {
    let section: String
    let common: BackgroundTarget
    private var targets: [BackgroundTarget] {
        BackgroundTarget.allCases.filter { $0.rawValue.hasPrefix(section) && $0 != common }
    }
    var body: some View {
        List {
            Section {
                NavigationLink("通用菜单") {
                    ContextActionEditor(context: common.rawValue, title: "通用菜单")
                }
            } footer: {
                Text("具体位置未单独设置时，使用通用菜单。")
            }
            Section("单独设置") {
                ForEach(targets) { target in
                    NavigationLink(target.title) {
                        ContextActionEditor(context: target.rawValue, title: target.title)
                    }
                }
            }
        }
        .navigationTitle(section == "page." ? "页面长按菜单" : "按键长按菜单")
        .pageBackground(.settings)
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
                    let enabled = preferences.actions(context).contains(action)
                    Button {
                        var actions = preferences.actions(context)
                        if enabled { actions.removeAll { $0 == action } } else { actions.append(action) }
                        preferences.set(actions, for: context)
                    } label: {
                        HStack {
                            Label(action.title, systemImage: action.symbol)
                            Spacer()
                            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("menu-action-\(action.rawValue)")
                    .accessibilityValue(enabled ? "1" : "0")
                }
            }
            Button(context.hasSuffix(".all") ? "恢复默认通用菜单" : "清除单独设置并使用通用菜单") {
                preferences.reset(context)
            }
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

enum ReelsSource: Equatable {
    case library, sources, folder(String), queue, smart(SmartPlaylistKind)
}

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
    @AppStorage("moonlight.reels.hideChrome") private var hideChrome = true
    private var effectiveHideChrome: Bool {
        // UI automation needs visible controls to exercise playback; normal
        // app launches keep the requested automatic hiding behavior.
        !ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests") && hideChrome
    }
    @State private var chromeTemporarilyVisible = true
    private var isVideo: Bool { entries.indices.contains(index) && entries[index].kind == .video }
    private var showsChrome: Bool { !effectiveHideChrome || chromeTemporarilyVisible }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if entries.isEmpty {
                VStack(spacing: 18) {
                    if loading { ProgressView().tint(.white) }
                    Text(loading ? "正在读取内容…" : "还没有可以播放的内容").foregroundStyle(.white)
                    Text(source == .sources ? "在发现中启用内容源后重试。" : "先在库中导入图片或视频，并移入此文件夹。")
                        .foregroundStyle(.white.opacity(0.7))
                    Button("重新加载") { Task { await load() } }
                }.frame(maxHeight: .infinity)
            } else {
                VerticalReelsPager(entries: entries, favoriteIDs: Set(model.mediaStore.items.filter(\.isFavorite).map(\.id)), index: $index, scenePhase: actionEntry == nil ? scenePhase : .inactive, muted: muted, autoAdvance: autoAdvance, photoSeconds: photoSeconds, showsChrome: showsChrome,
                    onOptions: { actionEntry = $0 }, onFavorite: { model.mediaStore.toggleFavorite($0) }, onNext: next)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("vertical-reels-pager")
            }
            HStack(spacing: 10) {
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .accessibilityLabel("关闭抖音模式")
                    .accessibilityIdentifier("reels-close")
                Text(reelsTitle).font(.subheadline.bold())
                Spacer()
                Text(entries.isEmpty ? "" : "\(index + 1) / \(entries.count)").font(.caption.monospacedDigit()).accessibilityIdentifier("reels-position")
                Button { muted.toggle() } label: { Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    .accessibilityLabel("切换静音")
                    .accessibilityIdentifier("reels-mute")
                Menu {
                    Toggle("自动播放下一条", isOn: $autoAdvance)
                    Toggle("视频时隐藏全部按键", isOn: $hideChrome)
                    Picker("图片停留", selection: $photoSeconds) { ForEach([3.0, 6, 10, 15], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                } label: { Image(systemName: "slider.horizontal.3") }
                .accessibilityLabel("抖音播放选项")
                .accessibilityIdentifier("reels-options")
            }
            .foregroundStyle(.white)
            .padding(12)
            .contentShape(Rectangle())
            .zIndex(10)
            .opacity(showsChrome ? 1 : 0)
            .allowsHitTesting(showsChrome)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard effectiveHideChrome else { return }
            chromeTemporarilyVisible.toggle()
        })
        .buttonStyle(MoonGlassButtonStyle()).task { await load() }
        .onChange(of: index) { value in
            chromeTemporarilyVisible = true
            if source == .sources && value >= entries.count - 3 { Task { await load(append: true) } }
        }
        .task(id: "chrome-\(index)-\(hideChrome)-\(isVideo)") {
            guard hideChrome, isVideo else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, effectiveHideChrome, isVideo else { return }
            chromeTemporarilyVisible = false
        }
        .sheet(item: $actionEntry) { entry in
            QuickActionsPanel(entry: entry, onPlay: { actionEntry = nil }).environmentObject(model)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
    private var reelsTitle: String {
        switch source {
        case .library: "库 · 抖音模式"
        case .sources: "内容源 · 抖音模式"
        case .folder(let id): "\(model.mediaStore.folders.first(where: { $0.id == id })?.name ?? "文件夹") · 抖音模式"
        case .queue: "播放队列"
        case .smart(let kind): "\(kind.title) · 智能片单"
        }
    }
    private func next() {
        guard !entries.isEmpty else { return }
        if index < entries.count - 1 { withAnimation { index += 1 } }
        else if source != .sources { withAnimation { index = 0 } }
        else { Task { await load(append: true); if index < entries.count - 1 { index += 1 } else if !entries.isEmpty { index = 0 } } }
    }
    private func load(append: Bool = false) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        if source == .library { entries = model.mediaStore.items; index = min(index, max(0, entries.count - 1)); return }
        if source == .queue {
            entries = model.mediaStore.queueItems
            index = min(index, max(0, entries.count - 1))
            return
        }
        if case .smart(let kind) = source {
            entries = model.mediaStore.items(for: kind)
            index = min(index, max(0, entries.count - 1))
            return
        }
        if case .folder(let folderID) = source {
            entries = model.mediaStore.items.filter { model.mediaStore.folderAssignments[$0.id] == folderID }
            index = min(index, max(0, entries.count - 1))
            return
        }
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
    let showsChrome: Bool
    let onOptions: (MediaEntry) -> Void
    let onFavorite: (MediaEntry) -> Void
    let onNext: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .vertical)
        controller.dataSource = context.coordinator; controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        controller.view.subviews.compactMap { $0 as? UIScrollView }.forEach {
            $0.backgroundColor = .black
            $0.isOpaque = true
        }
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
        // UIPageViewController still owns the outgoing and pending pages while
        // its scroll animation runs. Dropping either host here can expose its
        // empty internal scroll view during a quick reverse swipe.
        if !coordinator.turning {
            coordinator.hosts = coordinator.hosts.filter {
                abs($0.key - index) <= 2 || $0.key == visible
            }
        }
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
                     muted: parent.muted, autoAdvance: parent.autoAdvance, photoSeconds: parent.photoSeconds, showsChrome: parent.showsChrome,
                     loopsCurrentPage: parent.entries.count == 1,
                     onOptions: parent.onOptions, onFavorite: parent.onFavorite, onNext: parent.onNext)
        }
        func page(_ value: Int) -> ReelHost {
            if let host = hosts[value] { host.rootView = content(value); return host }
            let host = ReelHost(rootView: content(value))
            host.pageIndex = value
            host.view.backgroundColor = .black
            host.view.isOpaque = true
            hosts[value] = host
            return host
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
    let showsChrome: Bool
    let loopsCurrentPage: Bool
    let onOptions: (MediaEntry) -> Void
    let onFavorite: (MediaEntry) -> Void
    let onNext: () -> Void
    @State private var player: AVPlayer?
    @State private var paused = false
    @State private var playbackStatus = "缓冲中"
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            Group {
                if entry.kind == .embed, let url = entry.embedURL, active {
                    WebEmbedView(url: url, scrolling: false)
                } else if entry.kind == .video, let player {
                    FillVideoPlayer(player: player)
                        .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                            playbackStatus = status == .playing ? "正在播放" : status == .waitingToPlayAtSpecifiedRate ? "缓冲中" : "已暂停"
                        }
                } else if entry.kind == .image, let url = entry.remoteURL {
                    FullBleedImage(url: url)
                } else if let cover = entry.coverURL {
                    FullBleedImage(url: cover)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
            if entry.kind != .embed {
                CardGestureSurface(onTap: toggle, onHoldBegan: { _ in onOptions(entry) }, onHoldMoved: { _ in }, onHoldEnded: {},
                    onDoubleTap: { if !entry.isFavorite { onFavorite(entry) } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showsChrome {
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
                .transition(.opacity)
            }
        }.buttonStyle(MoonGlassButtonStyle())
        .animation(.easeOut(duration: 0.18), value: showsChrome)
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
            if autoAdvance && !loopsCurrentPage { onNext() }
            else { player?.seek(to: .zero); player?.play() }
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

