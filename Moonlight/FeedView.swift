import PhotosUI
import SwiftUI
import UIKit

struct FeedView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @State private var chrome = true
    @State private var heart = false

    var body: some View {
        let items = app.feedItems
        ZStack {
            Color.black.ignoresSafeArea()
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
                        onLongBegan: { point in openRing(items[index], at: point) },
                        onLongChanged: { point in
                            ring.fingerDown = true
                            ring.finger = point
                        },
                        onLongEnded: { point in
                            ring.fingerDown = false
                            ring.finger = point
                            if app.settings.menuSelect == .drag { ring.selectDrag(at: point) }
                        }
                    )
                    .environmentObject(app)
                    .environmentObject(ring))
                }
                .ignoresSafeArea()
            }
        }
        .moonOnChange(of: app.feedIndex) { _ in
            chrome = true
            loadCurrent()
        }
        .moonOnChange(of: app.tab) { tab in
            if tab != .home { app.feedPlayer.pause() }
        }
        .onAppear { loadCurrent() }
        .sheet(isPresented: $app.jumpVisible) { jumpSheet(items) }
        .sheet(item: $app.infoEntry) { entry in InfoCard(entry: entry) }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.stars").font(.system(size: 42)).foregroundColor(MoonColors.dark.accent)
            Text("还没有内容").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
            Text("从相册导入，或去发现里找公开影像。").font(.system(size: 14)).foregroundColor(.white.opacity(0.7))
            PhotosImportButton(title: "导入照片或视频")
        }
        .padding(.bottom, 80)
    }

    private func loadCurrent() {
        let items = app.feedItems
        guard items.indices.contains(app.feedIndex) else {
            app.feedPlayer.load(url: nil, autoplay: false, muted: true)
            app.armDwell(for: nil)
            return
        }
        let entry = items[app.feedIndex]
        app.armDwell(for: entry)
        guard app.tab == .home else { return }
        if entry.kind == .video, entry.embedURL == nil, let url = entry.playbackURL {
            let rate = app.feedPlayer.speed
            app.feedPlayer.load(url: url, autoplay: true, muted: app.settings.feedMuted, rate: rate)
        } else {
            app.feedPlayer.load(url: nil, autoplay: false, muted: true)
        }
    }

    private func handleSingle(_ entry: MediaEntry) {
        let video = entry.kind == .video && entry.embedURL == nil
        switch FeedTapRule.onTap(isVideo: video, active: true, hasError: app.feedPlayer.hasError) {
        case .togglePlay:
            app.feedPlayer.toggle()
        case .toggleChrome:
            chrome.toggle()
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
    }

    private func feedRingItems(_ entry: MediaEntry) -> [RingItem] {
        if entry.kind == .embed || entry.embedURL != nil {
            return [
                RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: entry.favorite ? "heart.fill" : "heart") { app.toggleFavorite(entry.id) },
                RingItem(title: "浏览器打开", systemImage: "safari") { openExternal(entry) },
                RingItem(title: "下一个同源", systemImage: "forward.end") { nextSame(entry) },
                RingItem(title: "分享", systemImage: "square.and.arrow.up") { share(entry) },
            ]
        }
        if entry.kind == .image {
            return [
                RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: entry.favorite ? "heart.fill" : "heart") { app.toggleFavorite(entry.id) },
                RingItem(title: "停留", systemImage: "timer", children: [3, 5, 8, 0].map { sec in
                    RingItem(title: sec == 0 ? "关闭" : "\(sec) 秒", systemImage: "timer") {
                        app.updateEntry(entry.id) { $0.dwellSeconds = sec }
                    }
                }) {},
                RingItem(title: "设为背景", systemImage: "photo") {
                    app.settings.homeBackdropPath = entry.localPath ?? entry.remoteURL
                    app.saveSettings()
                    app.showToast("已设为背景")
                },
                shareSave(entry),
            ]
        }
        let speeds: [Float] = [0.5, 1, 1.5, 2]
        return [
            RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: entry.favorite ? "heart.fill" : "heart") { app.toggleFavorite(entry.id) },
            RingItem(title: "倍速", systemImage: "speedometer", children: speeds.map { s in
                RingItem(title: s == 1 ? "1×" : String(format: "%g×", s), systemImage: "speedometer") {
                    app.feedPlayer.speed = s
                    if app.feedPlayer.playWhenReady { app.feedPlayer.play() }
                }
            }) {},
            RingItem(title: app.feedPlayer.isMuted ? "打开声音" : "静音", systemImage: app.feedPlayer.isMuted ? "speaker.wave.2" : "speaker.slash") {
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
            RingItem(title: "分享", systemImage: "square.and.arrow.up") { share(entry) },
            RingItem(title: "保存到相册", systemImage: "square.and.arrow.down") { app.saveToPhotos(entry) },
        ]
        if DownloadPolicy.canDownload(entry).ok && entry.localPath == nil {
            children.append(RingItem(title: "下载", systemImage: "arrow.down.circle") { app.download(entry) })
        }
        children.append(RingItem(title: "发到朋友圈", systemImage: "person.2") {
            app.composer = ComposerDraft(authorId: app.social.selfId, attachments: [app.attachment(from: entry)])
        })
        return RingItem(title: "分享·保存", systemImage: "square.and.arrow.up", children: children) {}
    }

    private func feedGroups(_ entry: MediaEntry) -> [MenuGroup] {
        let policy = DownloadPolicy.canDownload(entry)
        var shareItems = [
            RingItem(title: "分享", systemImage: "square.and.arrow.up") { share(entry) },
            RingItem(title: "保存到相册", systemImage: "square.and.arrow.down") { app.saveToPhotos(entry) },
            RingItem(title: "下载到我的下载", systemImage: "arrow.down.circle", enabled: policy.ok) { app.download(entry) },
            RingItem(title: "发到朋友圈", systemImage: "person.2") {
                app.composer = ComposerDraft(authorId: app.social.selfId, attachments: [app.attachment(from: entry)])
            },
        ]
        if !policy.ok, let reason = policy.reason {
            shareItems[2].title = "下载（\(reason)）"
        }
        return [
            MenuGroup(title: "播放", items: [
                RingItem(title: app.feedPlayer.showsPlaying ? "暂停" : "播放", systemImage: app.feedPlayer.showsPlaying ? "pause" : "play") {
                    if entry.kind == .video { app.feedPlayer.toggle() }
                },
                RingItem(title: app.feedPlayer.loop ? "循环开" : "循环关", systemImage: "repeat") { app.feedPlayer.loop.toggle() },
                RingItem(title: app.feedPlayer.isMuted ? "取消静音" : "静音", systemImage: "speaker") {
                    app.feedPlayer.isMuted.toggle()
                    app.settings.feedMuted = app.feedPlayer.isMuted
                    app.saveSettings()
                },
                RingItem(title: "画面 · \(app.settings.videoDisplay.short)", systemImage: "crop") {
                    let order = VideoDisplay.allCases
                    let idx = order.firstIndex(of: app.settings.videoDisplay) ?? 0
                    app.settings.videoDisplay = order[(idx + 1) % order.count]
                    app.saveSettings()
                },
                RingItem(title: entry.fillOverride == true ? "这条铺满" : (entry.fillOverride == false ? "这条完整" : "这条跟随设置"), systemImage: "arrow.up.left.and.arrow.down.right") {
                    app.updateEntry(entry.id) { item in
                        if item.fillOverride == nil { item.fillOverride = true }
                        else if item.fillOverride == true { item.fillOverride = false }
                        else { item.fillOverride = nil }
                    }
                },
                RingItem(title: "信息", systemImage: "info.circle") { app.infoEntry = entry },
            ]),
            MenuGroup(title: "分享与保存", items: shareItems),
            MenuGroup(title: "整理", items: [
                RingItem(title: entry.hidden ? "取消隐藏" : "隐藏", systemImage: "eye.slash") { app.setHidden(entry.id, !entry.hidden) },
            ]),
            MenuGroup(title: "危险", danger: true, items: [
                RingItem(title: "删除", systemImage: "trash") { app.deleteEntry(entry.id) },
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
                MediaTouchLayer(onSingle: onSingle, onDouble: onDouble, onLongBegan: onLongBegan, onLongChanged: onLongChanged, onLongEnded: onLongEnded)
                if heart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 84))
                        .foregroundColor(MoonColors.media.heart)
                        .shadow(radius: 12)
                }
                if chrome { overlay(in: geo.size) }
                if active && entry.kind == .video && app.feedPlayer.playbackState == PlayToggle.buffering && app.feedPlayer.playWhenReady {
                    ProgressView().tint(.white)
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    @ViewBuilder private var backdrop: some View {
        if let path = app.settings.homeBackdropPath {
            if path.hasPrefix("http"), let url = URL(string: path) {
                RemoteOrLocalImage(url: url, mode: .fill).ignoresSafeArea()
            } else if FileManager.default.fileExists(atPath: path) {
                RemoteOrLocalImage(url: URL(fileURLWithPath: path), mode: .fill).ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private func media(in size: CGSize) -> some View {
        if entry.kind == .embed, let raw = entry.embedURL, let url = URL(string: raw), active {
            WebEmbedView(url: url).ignoresSafeArea()
        } else if entry.kind == .video && entry.embedURL == nil {
            if active {
                PlayerLayerView(
                    player: app.feedPlayer.player,
                    gravity: Gravity.choose(mode: app.settings.videoDisplay, video: app.feedPlayer.naturalSize, view: size, override: entry.fillOverride)
                )
                .ignoresSafeArea()
            } else {
                RemoteOrLocalImage(url: entry.imageURL, art: entry.coverURL, mode: .fill).ignoresSafeArea()
            }
            if active && !app.feedPlayer.showsPlaying && app.feedPlayer.errorText == nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                    .padding(22)
                    .background(.ultraThinMaterial, in: Circle())
                    .allowsHitTesting(false)
            }
            if let error = app.feedPlayer.errorText, active {
                Text(error).font(.system(size: 13)).foregroundColor(.white).padding(8).background(.black.opacity(0.45), in: Capsule())
            }
        } else {
            RemoteOrLocalImage(url: entry.imageURL, art: entry.coverURL ?? entry.remoteURL, mode: app.settings.videoDisplay == .fill ? .fill : .fit)
                .ignoresSafeArea()
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
            Spacer()
            HStack {
                Button {
                    app.jumpVisible = true
                } label: {
                    Text("\(min(app.feedIndex + 1, max(app.feedItems.count, 1)))/\(max(app.feedItems.count, 1))")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Button {
                    app.toggleFavorite(entry.id)
                } label: {
                    Image(systemName: entry.favorite ? "heart.fill" : "heart")
                        .font(.system(size: 22))
                        .foregroundColor(entry.favorite ? MoonColors.media.heart : .white)
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, ScreenInsets.bottom + 78)
        }
        .foregroundColor(.white)
        .allowsHitTesting(true)
    }
}

struct InfoCard: View {
    var entry: MediaEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moon) private var colors
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.title).font(.system(size: 20, weight: .semibold))
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
        .background(MoonBackground(colors: colors))
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
                .background(.ultraThinMaterial, in: Capsule())
        }
        .moonOnChange(of: item) { newItem in
            guard let newItem else { return }
            Task { await app.importPicker(newItem); item = nil }
        }
    }
}
