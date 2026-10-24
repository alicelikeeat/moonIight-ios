import PhotosUI
import SwiftUI
import UIKit

struct FeedView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @EnvironmentObject private var hold: HoldController
    @State private var chrome = true
    @State private var heart = false
    /// True after the viewer taps the picture open. The hide timer owns it until playback stops.
    @State private var userChrome = false
    @State private var hideToken = 0

    var body: some View {
        let items = app.feedItems
        ZStack {
            Color.black.allowsHitTesting(false)
            if items.isEmpty {
                empty
            } else {
                VerticalPager(count: items.count, index: $app.feedIndex) { index in
                    AnyView(FeedPage(
                        entry: items[index],
                        active: index == app.feedIndex,
                        chrome: chrome,
                        heart: heart && index == app.feedIndex,
                        onSingle: { handleSingle(items[index]) },
                        onDouble: { handleDouble(items[index]) },
                        onLongBegan: { point in
                            TabChrome.setSuspended(true)
                            openRing(items[index], at: point)
                        },
                        onLongChanged: { point in
                            ring.fingerDown = true
                            ring.finger = point
                            hold.move(point)
                        },
                        onLongEnded: { point in
                            let outcome = hold.lift()
                            ring.fingerDown = false
                            ring.finger = point
                            if outcome != .timed && outcome != .center {
                                if ring.session?.drop == true {
                                    ring.releaseFinger(at: point)
                                } else if ring.session?.select == .drag || ring.session?.select == .slider {
                                    ring.selectDrag(at: point)
                                }
                            }
                            TabChrome.setSuspended(false)
                            app.nudgeChrome()
                        }
                    )
                    .environmentObject(app)
                    .environmentObject(ring))
                }
            }
        }
        .moonOnChange(of: app.feedIndex) { _ in
            userChrome = false
            hideToken += 1
            // Publishing the player from inside the update that observed feedIndex cycles the graph.
            DispatchQueue.main.async { loadCurrent() }
        }
        .moonOnChange(of: app.feedChrome) { visible in
            if chrome != visible { chrome = visible }
        }
        .moonOnChange(of: app.demoEntry?.id) { _ in
            DispatchQueue.main.async { loadCurrent() }
        }
        .moonOnChange(of: app.tab) { tab in
            if tab != .home {
                app.feedPlayer.pause()
                userChrome = false
                publishChrome(true)
            }
        }
        .moonOnChange(of: app.chromeGeneration) { _ in
            if userChrome { scheduleHide() }
        }
        .onReceive(app.feedPlayer.$generation) { _ in syncChrome() }
        .onReceive(NotificationCenter.default.publisher(for: .moonResumeFeed)) { _ in
            guard app.tab == .home, FeedAutoplay.allowedNow(app.settings) else { return }
            app.feedPlayer.resumeAfterForeground()
        }
        .task(id: hideToken) {
            guard userChrome, app.settings.chromeAutoHide, nativeVideoPlaying else { return }
            let wait = ChromeTiming.seconds(app.settings.chromeHideSeconds)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, nativeVideoPlaying, app.settings.chromeAutoHide else { return }
            userChrome = false
            publishChrome(false)
        }
        .environment(\.colorScheme, .dark)
        .task(id: currentPlaybackID) {
            loadCurrent()
        }
        .onAppear {
            if chrome != app.feedChrome { chrome = app.feedChrome }
            loadCurrent()
        }
        .moonTabBarVisible(app.feedChrome)
        .sheet(isPresented: $app.jumpVisible) { jumpSheet(items) }
        .sheet(item: $app.infoEntry) { entry in InfoCard(entry: entry) }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars").font(.system(size: 42)).foregroundColor(MoonColors.dark.accent)
            Text("还没有内容").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
            Text("从相册导入，或去发现里找公开影像。").font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
            PhotosImportButton(title: "导入照片或视频")
                .accessibilityIdentifier("home.import")
            Button {
                guard !PressGate.suppressTap else { return }
                app.tab = .discover
            } label: {
                Text("去发现")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .moonCapsule(overMedia: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.discover")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 80)
    }

    /// Changes when the clip on screen changes, including the in-memory immersive demo.
    private var currentPlaybackID: String {
        guard app.feedItems.indices.contains(app.feedIndex) else { return "empty" }
        return app.feedItems[app.feedIndex].id
    }

    private func loadCurrent() {
        let items = app.feedItems
        guard items.indices.contains(app.feedIndex) else {
            // A late empty pass must not stop the in-memory demo that just started.
            if app.demoEntry == nil {
                app.feedPlayer.load(url: nil, autoplay: false, muted: true)
            }
            app.armDwell(for: nil)
            syncChrome()
            return
        }
        let entry = items[app.feedIndex]
        app.armDwell(for: entry)
        guard app.tab == .home else { return }
        if entry.kind == .video, entry.embedURL == nil, let url = entry.playbackURL {
            let rate = app.feedPlayer.speed
            let demo = entry.id == AppModel.immersiveDemoID
            let play = demo || FeedAutoplay.allowedNow(app.settings)
            app.feedPlayer.loop = demo
            app.feedPlayer.load(url: url, autoplay: play, muted: app.settings.feedMuted, rate: rate)
        } else {
            app.feedPlayer.loop = false
            app.feedPlayer.load(url: nil, autoplay: false, muted: true)
        }
        syncChrome()
    }

    private var nativeVideoPlaying: Bool {
        guard app.feedItems.indices.contains(app.feedIndex) else { return false }
        let entry = app.feedItems[app.feedIndex]
        guard entry.kind == .video, entry.embedURL == nil else { return false }
        if app.feedPlayer.errorText != nil { return false }
        if app.feedPlayer.playbackState == PlayToggle.ended { return false }
        return app.feedPlayer.playWhenReady || app.feedPlayer.showsPlaying
    }

    private func publishChrome(_ visible: Bool) {
        chrome = visible
        if app.feedChrome != visible { app.feedChrome = visible }
    }

    private func syncChrome() {
        let playing = nativeVideoPlaying
        if !playing || !app.settings.chromeAutoHide { userChrome = false }
        let shown = FeedChromeRule.shown(playing: playing, autoHide: app.settings.chromeAutoHide, revealed: userChrome)
        if chrome != shown || app.feedChrome != shown { publishChrome(shown) }
    }

    private func revealAndArm() {
        userChrome = true
        publishChrome(true)
        hideToken += 1
    }

    private func scheduleHide() {
        guard userChrome, app.settings.chromeAutoHide, nativeVideoPlaying else { return }
        hideToken += 1
    }

    private func handleSingle(_ entry: MediaEntry) {
        let video = entry.kind == .video && entry.embedURL == nil
        if video, entry.playbackURL == nil {
            Task { await app.rehydrate(entry) }
            return
        }
        switch FeedTapRule.onTap(
            isVideo: video,
            active: true,
            hasError: app.feedPlayer.hasError,
            chromeVisible: chrome,
            autoHide: app.settings.chromeAutoHide
        ) {
        case .togglePlay:
            app.feedPlayer.toggle()
            app.nudgeChrome()
        case .toggleChrome:
            userChrome = false
            publishChrome(!chrome)
        case .revealChrome:
            revealAndArm()
        }
    }

    private func handleDouble(_ entry: MediaEntry) {
        app.favoriteOnly(entry.id)
        heart = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { heart = false }
    }

    private func openRing(_ entry: MediaEntry, at point: CGPoint) {
        let items = feedRingItems(entry)
        let groups = feedGroups(entry)
        ring.fingerDown = true
        ring.finger = point
        ring.present(origin: point, items: items, groups: groups, settings: app.settings, overMedia: true)
        hold.arm(
            origin: point,
            settings: app.settings,
            catalog: RingCatalog(items: items, groups: groups, context: .feedItem, title: entry.title, overMedia: true)
        )
    }

    private func feedRingItems(_ entry: MediaEntry) -> [RingItem] {
        if entry.kind == .embed || entry.embedURL != nil {
            return [
                RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: entry.favorite ? "heart.fill" : "heart", key: "fav") { app.toggleFavorite(entry.id) },
                RingItem(title: "浏览器打开", systemImage: "safari") { openExternal(entry) },
                RingItem(title: "下一个同源", systemImage: "forward.end") { nextSame(entry) },
                RingItem(title: "分享", systemImage: "square.and.arrow.up", key: "share") { share(entry) },
            ]
        }
        if entry.kind == .image {
            return [
                RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: entry.favorite ? "heart.fill" : "heart", key: "fav") { app.toggleFavorite(entry.id) },
                RingItem(title: "停留", systemImage: "timer", children: [3, 5, 8, 0].map { sec in
                    RingItem(title: sec == 0 ? "关闭" : "\(sec) 秒", systemImage: "timer") {
                        app.updateEntry(entry.id) { $0.dwellSeconds = sec }
                    }
                }) {},
                RingItem(title: "设为背景", systemImage: "photo") {
                    app.settings.homeBackdropPath = entry.localPath ?? entry.remoteURL
                    app.settings.homeBackdropVideo = entry.kind == .video
                    app.saveSettings()
                    app.showToast(entry.kind == .video ? "已设为视频背景" : "已设为背景")
                },
                shareSave(entry),
            ]
        }
        let speeds: [Float] = [0.5, 1, 1.5, 2]
        return [
            RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: entry.favorite ? "heart.fill" : "heart", key: "fav") { app.toggleFavorite(entry.id) },
            RingItem(title: "倍速", systemImage: "speedometer", children: speeds.map { s in
                RingItem(title: s == 1 ? "1×" : String(format: "%g×", s), systemImage: "speedometer") {
                    app.feedPlayer.speed = s
                    if app.feedPlayer.playWhenReady { app.feedPlayer.play() }
                }
            }) {},
            RingItem(title: app.feedPlayer.isMuted ? "打开声音" : "静音", systemImage: app.feedPlayer.isMuted ? "speaker.wave.2" : "speaker.slash", key: "mute") {
                app.feedPlayer.isMuted.toggle()
                app.settings.feedMuted = app.feedPlayer.isMuted
                app.feedPlayer.player.isMuted = app.feedPlayer.isMuted
                app.saveSettings()
            },
            shareSave(entry),
        ]
    }

    private func shareSave(_ entry: MediaEntry) -> RingItem {
        var children = [
            RingItem(title: "分享", systemImage: "square.and.arrow.up", key: "share") { share(entry) },
            RingItem(title: "保存到相册", systemImage: "square.and.arrow.down", key: "save") { app.saveToPhotos(entry) },
        ]
        if DownloadPolicy.canDownload(entry).ok && entry.localPath == nil {
            children.append(RingItem(title: "下载", systemImage: "arrow.down.circle") { app.download(entry) })
            children.append(RingItem(title: "自动缓存", systemImage: "arrow.down.doc") { app.download(entry, lane: .auto) })
        }
        children.append(RingItem(title: "发到朋友圈", systemImage: "person.2", key: "post") {
            app.composer = ComposerDraft(authorId: app.social.selfId, attachments: [app.attachment(from: entry)])
        })
        return RingItem(title: "分享·保存", systemImage: "square.and.arrow.up", children: children) {}
    }

    private func feedGroups(_ entry: MediaEntry) -> [MenuGroup] {
        let policy = DownloadPolicy.canDownload(entry)
        let native = entry.kind == .video && entry.embedURL == nil && entry.playbackURL != nil
        var shareItems = [
            RingItem(title: "分享", systemImage: "square.and.arrow.up", key: "share") { share(entry) },
            RingItem(title: "保存到相册", systemImage: "square.and.arrow.down", key: "save") { app.saveToPhotos(entry) },
            RingItem(title: "下载到我的下载", systemImage: "arrow.down.circle", enabled: policy.ok) { app.download(entry) },
            RingItem(title: "自动缓存", systemImage: "arrow.down.doc", enabled: policy.ok) { app.download(entry, lane: .auto) },
            RingItem(title: "发到朋友圈", systemImage: "person.2", key: "post") {
                app.composer = ComposerDraft(authorId: app.social.selfId, attachments: [app.attachment(from: entry)])
            },
        ]
        if !policy.ok, let reason = policy.reason {
            shareItems[2].title = "下载（\(reason)）"
        }
        return [
            MenuGroup(title: "播放", items: [
                RingItem(title: app.feedPlayer.showsPlaying ? "暂停" : "播放", systemImage: app.feedPlayer.showsPlaying ? "pause" : "play", enabled: native, key: "play") {
                    if native { app.feedPlayer.toggle() }
                },
                RingItem(title: app.feedPlayer.loop ? "循环开" : "循环关", systemImage: "repeat", enabled: native, key: "loop") { app.feedPlayer.loop.toggle() },
                RingItem(title: app.feedPlayer.isMuted ? "取消静音" : "静音", systemImage: "speaker", enabled: native, key: "mute") {
                    app.feedPlayer.isMuted.toggle()
                    app.settings.feedMuted = app.feedPlayer.isMuted
                    app.saveSettings()
                },
                RingItem(title: "画面 · \(app.settings.videoDisplay.short)", systemImage: "crop", enabled: native) {
                    let order = VideoDisplay.allCases
                    let idx = order.firstIndex(of: app.settings.videoDisplay) ?? 0
                    app.settings.videoDisplay = order[(idx + 1) % order.count]
                    app.saveSettings()
                },
                RingItem(title: entry.fillOverride == true ? "这条铺满" : (entry.fillOverride == false ? "这条完整" : "这条跟随设置"), systemImage: "arrow.up.left.and.arrow.down.right", enabled: native) {
                    guard native else { return }
                    app.updateEntry(entry.id) { item in
                        if item.fillOverride == nil { item.fillOverride = true }
                        else if item.fillOverride == true { item.fillOverride = false }
                        else { item.fillOverride = nil }
                    }
                },
                RingItem(title: "信息", systemImage: "info.circle", key: "info") { app.infoEntry = entry },
                RingItem(title: "全屏播放", systemImage: "arrow.up.left.and.arrow.down.right", enabled: native || (entry.kind == .embed && !(entry.embedURL ?? "").isEmpty), key: "browser") { app.fullPlayer = entry },
                RingItem(title: "用哔哩哔哩打开", systemImage: "arrow.up.right.square", enabled: entry.resolvedPlatform == PlatformID.bili && !(entry.biliBvid ?? "").isEmpty) {
                    if let bvid = entry.biliBvid { BiliLinks.open(bvid: bvid) }
                },
            ]),
            MenuGroup(title: "分享与保存", items: shareItems),
            MenuGroup(title: "整理", items: [
                RingItem(title: entry.hidden ? "取消隐藏" : "隐藏", systemImage: "eye.slash") { app.setHidden(entry.id, !entry.hidden) },
            ]),
            MenuGroup(title: "危险", danger: true, items: [
                RingItem(title: "删除", systemImage: "trash", destructive: true) { app.deleteEntry(entry.id) },
            ]),
        ]
    }

    private func share(_ entry: MediaEntry) {
        var items: [Any] = [entry.title]
        if let path = entry.localPath { items = [URL(fileURLWithPath: path)] }
        else if let remote = entry.remoteURL, let url = URL(string: remote) { items = [url] }
        else if let embed = entry.embedURL, let url = URL(string: embed) { items = [url] }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(av, animated: true)
    }

    private func openExternal(_ entry: MediaEntry) {
        let raw = entry.remoteURL ?? entry.embedURL
        guard let raw, let url = URL(string: raw) else { return }
        UIApplication.shared.open(url)
    }

    private func nextSame(_ entry: MediaEntry) {
        let items = app.feedItems
        guard let i = items.firstIndex(where: { $0.id == entry.id }) else { return }
        if let next = FeedNav.nextSameSource(items.map { $0.platformLabel() }, i) {
            app.feedIndex = next
        } else {
            app.showToast("没有下一条同源")
        }
    }

    private func jumpSheet(_ items: [MediaEntry]) -> some View {
        NavigationStack {
            List(Array(items.enumerated()), id: \.element.id) { index, entry in
                Button {
                    app.feedIndex = index
                    app.jumpVisible = false
                } label: {
                    HStack {
                        Text("\(index + 1)")
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .leading)
                        VStack(alignment: .leading) {
                            Text(entry.title).lineLimit(1)
                            Text(entry.platformLabel()).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("跳转")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct FeedPage: View {
    @EnvironmentObject private var app: AppModel
    var entry: MediaEntry
    var active: Bool
    var chrome: Bool
    var heart: Bool
    var onSingle: () -> Void
    var onDouble: () -> Void
    var onLongBegan: (CGPoint) -> Void
    var onLongChanged: (CGPoint) -> Void
    var onLongEnded: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop
                media(in: geo.size)
                MediaTouchLayer(
                    identifier: active && entry.kind == .video && entry.embedURL == nil ? "home.playing" : "home.page",
                    onSingle: onSingle,
                    onDouble: onDouble,
                    onLongBegan: onLongBegan,
                    onLongChanged: onLongChanged,
                    onLongEnded: onLongEnded,
                    onSwipeLeft: { app.infoEntry = entry; app.nudgeChrome() },
                    onPinch: { fill in
                        app.updateEntry(entry.id) { $0.fillOverride = fill }
                        app.showToast(fill ? "已铺满" : "已完整")
                        app.nudgeChrome()
                    }
                )
                if heart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 84))
                        .foregroundColor(MoonColors.media.heart)
                        .shadow(radius: 12)
                        .allowsHitTesting(false)
                }
                overlay(in: geo.size)
                    .opacity(chrome ? 1 : 0)
                    .offset(y: chrome ? 0 : 18)
                    .allowsHitTesting(chrome)
                    .accessibilityHidden(!chrome)
                    .animation(.easeInOut(duration: 0.28), value: chrome)
                if active && entry.kind == .video && app.feedPlayer.playbackState == PlayToggle.buffering && app.feedPlayer.playWhenReady {
                    ProgressView().tint(.white).allowsHitTesting(false)
                }
            }
        }
        .background(Color.black.allowsHitTesting(false))
    }

    @ViewBuilder private var backdrop: some View {
        if let path = app.settings.homeBackdropPath {
            if app.settings.homeBackdropVideo {
                LoopFilm(ref: path).allowsHitTesting(false)
            } else if path.hasPrefix("http"), let url = URL(string: path) {
                RemoteOrLocalImage(url: url, mode: .fill).allowsHitTesting(false)
            } else if FileManager.default.fileExists(atPath: path) {
                RemoteOrLocalImage(url: URL(fileURLWithPath: path), mode: .fill).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private func media(in size: CGSize) -> some View {
        if entry.kind == .embed, let raw = entry.embedURL, let url = URL(string: raw), active {
            WebEmbedView(url: url)
        } else if entry.kind == .video && entry.embedURL == nil {
            if active {
                PlayerLayerView(
                    player: app.feedPlayer.player,
                    gravity: Gravity.choose(mode: app.settings.videoDisplay, video: app.feedPlayer.naturalSize, view: size, override: entry.fillOverride)
                )
                .allowsHitTesting(false)
            } else {
                RemoteOrLocalImage(url: entry.imageURL, art: entry.coverURL, mode: .fill).allowsHitTesting(false)
            }
            if active && !app.feedPlayer.showsPlaying && app.feedPlayer.errorText == nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .padding(22)
                    .moonDisc(overMedia: true)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("home.paused")
            }
            if let error = app.feedPlayer.errorText, active {
                Text(error).font(.system(size: 13)).foregroundColor(.white).padding(8).background(.black.opacity(0.45), in: Capsule())
            }
        } else {
            RemoteOrLocalImage(url: entry.imageURL, art: entry.coverURL ?? entry.remoteURL, mode: app.settings.videoDisplay == .fill ? .fill : .fit)
                .allowsHitTesting(false)
        }
    }

    private func overlay(in size: CGSize) -> some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    Text(entry.author.isEmpty ? entry.platformLabel() : "\(entry.author) · \(entry.platformLabel())")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }
                Spacer()
            }
            .padding(.top, ScreenInsets.top + 8)
            .padding(.horizontal, 16)
            .allowsHitTesting(false)
            Spacer().allowsHitTesting(false)
            HStack(alignment: .bottom) {
                Button {
                    guard !PressGate.suppressTap else { return }
                    app.nudgeChrome()
                    app.jumpVisible = true
                } label: {
                    Text("\(min(app.feedIndex + 1, max(app.feedItems.count, 1)))/\(max(app.feedItems.count, 1))")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .moonCapsule(overMedia: true)
                }
                Spacer()
                VStack(spacing: 14) {
                    if entry.kind == .video && entry.embedURL == nil {
                        Button {
                            guard !PressGate.suppressTap else { return }
                            app.nudgeChrome()
                            app.feedPlayer.isMuted.toggle()
                            app.settings.feedMuted = app.feedPlayer.isMuted
                            app.feedPlayer.player.isMuted = app.feedPlayer.isMuted
                            app.saveSettings()
                        } label: {
                            Image(systemName: app.feedPlayer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 46, height: 46)
                                .moonDisc(overMedia: true)
                        }
                        .accessibilityIdentifier("home.mute")
                        .accessibilityLabel(app.feedPlayer.isMuted ? "打开声音" : "静音")
                    }
                    Button {
                        guard !PressGate.suppressTap else { return }
                        app.nudgeChrome()
                        app.toggleFavorite(entry.id)
                    } label: {
                        Image(systemName: entry.favorite ? "heart.fill" : "heart")
                            .font(.system(size: 22))
                            .foregroundColor(entry.favorite ? MoonColors.media.heart : .white)
                            .frame(width: 46, height: 46)
                            .moonDisc(overMedia: true)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .foregroundColor(.white)
    }
}

struct InfoCard: View {
    var entry: MediaEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moon) private var colors
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title).font(.system(size: 20, weight: .semibold))
                .accessibilityIdentifier("info.card")
            Text(entry.author.isEmpty ? entry.platformLabel() : entry.author).foregroundColor(colors.textDim)
            label("来源", entry.platformLabel())
            if entry.byteSize > 0 { label("大小", byteString(entry.byteSize)) }
            label("日期", RelTime.string(entry.createdAt))
            Text(MediaInfo.tags(entry).joined(separator: "  ·  ")).font(.system(size: 13)).foregroundColor(colors.textDim)
            if let url = entry.remoteURL { Text(url).font(.system(size: 12)).foregroundColor(colors.textDim).lineLimit(3) }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { SystemGlassFill(dark: colors.dark) }
        .presentationDetents([.medium])
    }

    private func label(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundColor(colors.textDim).frame(width: 48, alignment: .leading)
            Text(v)
        }
        .font(.system(size: 15))
    }

    private func byteString(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }
}

struct PhotosImportButton: View {
    @EnvironmentObject private var app: AppModel
    var title: String
    @State private var item: PhotosPickerItem?
    var body: some View {
        PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .moonCapsule(overMedia: true)
        }
        .moonOnChange(of: item) { newItem in
            guard let newItem else { return }
            Task { await app.importPicker(newItem); item = nil }
        }
    }
}
