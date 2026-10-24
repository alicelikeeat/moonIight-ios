import PhotosUI
import SwiftUI
import UIKit

struct DiscoverView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors
    @State private var query = ""
    @State private var link = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("公开影像来自 Archive.org、NASA、维基共享资源。YouTube 用官方播放器，频道用 RSS。哔哩哔哩只用官方嵌入页。PeerTube 走实例自己的公开接口。")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textDim)
                        .accessibilityIdentifier("discover.root")
                    HStack {
                        TextField("搜索月亮、海洋、城市…", text: $query)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .moonGlass(colors, radius: 14)
                        Button("搜索") { Task { await app.discover(query: query) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12)
                            .accessibilityIdentifier("discover.search")
                    }
                    HStack {
                        TextField("粘贴直链或官方页面", text: $link)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .moonGlass(colors, radius: 14)
                        Button("加入") { addLink() }
                            .font(.system(size: 15, weight: .semibold))
                        Button("订阅") { app.subscribe(link); link = "" }
                            .font(.system(size: 15, weight: .semibold))
                            .accessibilityIdentifier("discover.follow")
                    }
                    if !app.settings.follows.isEmpty {
                        Text("订阅").font(.system(size: 13, weight: .semibold))
                        ForEach(app.settings.follows) { source in
                            HStack {
                                Text(source.title).lineLimit(1)
                                Spacer()
                                Button("移除") { app.removeFollow(source.id) }
                            }
                            .font(.system(size: 13))
                        }
                        Button("刷新订阅") { Task { await app.refreshFollows() } }
                            .accessibilityIdentifier("discover.refreshFollows")
                    }
                    if app.discoverBusy {
                        ProgressView("正在找公开影像…").tint(colors.accent)
                            .accessibilityIdentifier("discover.busy")
                    }
                    if let error = app.discoverError {
                        Text(error).font(.system(size: 13)).foregroundColor(colors.textDim)
                            .accessibilityIdentifier("discover.error")
                    }
                    if !app.refreshCache.isEmpty {
                        Text("后台带到 \(app.refreshCache.count) 条公开影像")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityIdentifier("discover.refresh")
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(app.discoverResults) { entry in
                            Button { app.addRemote(entry) } label: {
                                ZStack(alignment: .bottomLeading) {
                                    RemoteOrLocalImage(url: entry.imageURL, art: entry.coverURL, mode: .fill)
                                        .frame(height: 180)
                                        .clipped()
                                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.platformLabel()).font(.system(size: 10, weight: .bold))
                                        Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    }
                                    .foregroundColor(.white)
                                    .padding(8)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 90)
            }
            .background { SystemGlassFill(dark: colors.dark) }
            .navigationTitle("发现")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await app.discover(query: query) }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .task { if app.discoverResults.isEmpty { await app.discover(query: "") } }
    }

    private func addLink() {
        let result = LinkResolver.resolve(link)
        if let entry = result.entry {
            if entry.platform == PlatformID.archive, let remote = entry.remoteURL,
               let id = remote.split(separator: "/").dropFirst().first.map(String.init),
               remote.contains("archive.org") {
                app.addRemote(entry)
            } else {
                app.addRemote(entry)
            }
            link = ""
            if let message = result.message { app.showToast(message) }
        } else {
            app.showToast(result.message ?? "无法识别这个链接")
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var filter = 0
    @State private var picking = false
    @State private var picked = Set<String>()

    var body: some View {
        let items = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("筛选", selection: $filter) {
                    Text("全部").tag(0)
                    Text("收藏").tag(1)
                    Text("下载").tag(2)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("library.filters")
                if filter == 2 {
                    Text("我的下载")
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityIdentifier("library.downloads")
                    if app.library.downloads.isEmpty {
                        Text("还没有主动下载").font(.system(size: 13)).foregroundColor(colors.textDim)
                    }
                    Text("自动缓存不会出现在这里").font(.caption).foregroundColor(colors.textDim)
                    ForEach(app.library.downloads) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).lineLimit(1)
                                if task.done { Text("已完成").font(.caption).foregroundColor(colors.textDim) }
                                else if let error = task.error { Text(error).font(.caption).foregroundColor(colors.danger) }
                                else { ProgressView(value: task.progress).tint(colors.accent) }
                            }
                            Spacer()
                        }
                        .padding(12)
                        .moonGlass(colors, radius: 14)
                    }
                }
                if picking {
                    Text(items.isEmpty ? "先导入内容，再多选" : "已选 \(picked.count) 项")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textDim)
                        .accessibilityIdentifier("library.picking")
                    if !picked.isEmpty {
                        HStack {
                            Button("收藏") { for id in picked { app.favoriteOnly(id) } }
                            Button("删除") { for id in picked { app.deleteEntry(id) }; picked.removeAll() }
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(items) { entry in
                        Button {
                            if picking {
                                if picked.contains(entry.id) { picked.remove(entry.id) } else { picked.insert(entry.id) }
                            } else {
                                app.focus(id: entry.id)
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                RemoteOrLocalImage(url: entry.imageURL, art: entry.coverURL, mode: .fill)
                                    .frame(height: 120)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                if entry.favorite {
                                    Image(systemName: "heart.fill").font(.system(size: 11)).foregroundColor(colors.heart).padding(6)
                                }
                                if picking {
                                    Image(systemName: picked.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                        .allowsHitTesting(false)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                            let origin = CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY)
                            ring.present(origin: origin, items: libraryRing(entry), groups: libraryGroups(entry), settings: app.settings)
                        })
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background { SystemGlassFill(dark: colors.dark) }
        .navigationTitle("库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(picking ? "完成选择" : "多选") {
                    picking.toggle()
                    if !picking { picked.removeAll() }
                }
                .accessibilityIdentifier("library.multi")
            }
        }
    }

    private var filtered: [MediaEntry] {
        switch filter {
        case 1: return app.library.entries.filter(\.favorite)
        case 2: return app.library.entries.filter { $0.source == "download" }
        default: return app.library.entries
        }
    }

    private func share(_ entry: MediaEntry) {
        var items: [Any] = [entry.title]
        if let path = entry.localPath { items = [URL(fileURLWithPath: path)] }
        else if let remote = entry.remoteURL, let url = URL(string: remote) { items = [url] }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(av, animated: true)
    }

    private func libraryRing(_ entry: MediaEntry) -> [RingItem] {
        [
            RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: "heart") { app.toggleFavorite(entry.id) },
            RingItem(title: "发朋友圈", systemImage: "person.2") {
                app.composer = ComposerDraft(authorId: app.social.selfId, attachments: [app.attachment(from: entry)])
            },
            RingItem(title: "分享", systemImage: "square.and.arrow.up") { share(entry) },
            RingItem(title: "多选", systemImage: "checkmark.circle") { picking = true },
        ]
    }

    private func libraryGroups(_ entry: MediaEntry) -> [MenuGroup] {
        [
            MenuGroup(title: "播放", items: [RingItem(title: "打开", systemImage: "play") { app.focus(id: entry.id) }]),
            MenuGroup(title: "整理", items: [RingItem(title: entry.hidden ? "取消隐藏" : "隐藏", systemImage: "eye.slash") { app.setHidden(entry.id, !entry.hidden) }]),
            MenuGroup(title: "危险", danger: true, items: [RingItem(title: "删除", systemImage: "trash") { app.deleteEntry(entry.id) }]),
        ]
    }
}

struct CaptureView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors
    @State private var cameraPhoto = false
    @State private var cameraVideo = false
    @State private var item: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("把此刻留下来").font(.system(size: 26, weight: .semibold))
            Text("拍照、录像，或从相册导入。")
                .foregroundColor(colors.textDim)
            VStack(spacing: 12) {
                captureButton("拍照", "camera") { cameraPhoto = true }
                captureButton("录像", "video") { cameraVideo = true }
                PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                    rowLabel("导入", "photo.on.rectangle")
                }
                Button {
                    app.composer = ComposerDraft(authorId: app.social.selfId)
                    app.tab = .moments
                } label: { rowLabel("发朋友圈", "square.and.pencil") }
                .accessibilityIdentifier("capture.compose")
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
        .foregroundColor(colors.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { SystemGlassFill(dark: colors.dark) }
        .sheet(isPresented: $cameraPhoto) {
            CameraPicker(video: false, onImage: { image in
                cameraPhoto = false
                if let data = image.jpegData(compressionQuality: 0.9) {
                    app.importImageData(data, title: "拍摄", source: "camera")
                }
            }, onVideo: { _ in cameraPhoto = false }, onCancel: { cameraPhoto = false })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $cameraVideo) {
            CameraPicker(video: true, onImage: { _ in cameraVideo = false }, onVideo: { url in
                cameraVideo = false
                app.importFile(at: url, kind: .video, title: "录像", source: "camera")
            }, onCancel: { cameraVideo = false })
            .ignoresSafeArea()
        }
        .moonOnChange(of: item) { newItem in
            guard let newItem else { return }
            Task { await app.importPicker(newItem); item = nil }
        }
    }

    private func captureButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(title, symbol) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ title: String, _ symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 28)
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
        }
        .padding(16)
        .moonGlass(colors, radius: 18)
    }
}
