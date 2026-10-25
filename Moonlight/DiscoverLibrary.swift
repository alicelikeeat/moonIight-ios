import PhotosUI
import SwiftUI
import UIKit

struct DiscoverView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var theme
    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var link = ""
    @State private var tools = false

    private var colors: MoonColors { app.settings.showsBackdrop(.discover) ? .media : theme }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear.frame(height: 36)
                        .accessibilityIdentifier("discover.root")
                    Text("公开影像。哔哩哔哩只用官方嵌入页。")
                        .font(.system(size: 13))
                        .foregroundColor(colors.textDim)
                    if app.discoverBusy {
                        ProgressView("正在找公开影像…").tint(colors.accent)
                            .accessibilityIdentifier("discover.busy")
                    }
                    if let error = app.discoverError {
                        Text(error).font(.system(size: 13)).foregroundColor(colors.textDim)
                            .accessibilityIdentifier("discover.error")
                    }
                    if let hot = app.hotError {
                        Text(hot).font(.system(size: 13)).foregroundColor(colors.textDim)
                            .accessibilityIdentifier("discover.hot")
                    }
                    if !app.hotItems.isEmpty {
                        Text("热榜").font(.system(size: 13, weight: .semibold)).foregroundColor(colors.text)
                        resultGrid(app.hotItems)
                    }
                    if !app.refreshCache.isEmpty {
                        Text("后台带到 \(app.refreshCache.count) 条公开影像")
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityIdentifier("discover.refresh")
                        resultGrid(app.refreshCache)
                    }
                    resultGrid(app.discoverResults)
                }
                .padding(16)
                .padding(.bottom, 110)
            }
            .background {
                ZStack {
                    SystemGlassFill(dark: colors.dark)
                    PageBackdrop(page: .discover)
                }
            }
            Button { tools = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(colors.text)
                    .frame(width: 40, height: 40)
                    .moonDisc(overMedia: false)
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.top, 8)
            .accessibilityIdentifier("discover.tools")
            if tools { toolsPanel }
        }
        .environment(\.colorScheme, app.settings.showsBackdrop(.discover) ? .dark : scheme)
        .task {
            if app.discoverResults.isEmpty { await app.discover(query: "") }
        }
    }

    private var toolsPanel: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("发现").font(.system(size: 18, weight: .bold)).foregroundColor(colors.text)
                    TextField("搜索月亮、海洋、城市…", text: $query)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .moonGlass(colors, radius: 14)
                    Button("搜索") { Task { await app.discover(query: query) } }
                        .accessibilityIdentifier("discover.search")
                    TextField("粘贴直链或官方页面", text: $link)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .moonGlass(colors, radius: 14)
                    HStack {
                        Button("加入") { addLink() }.accessibilityIdentifier("discover.add")
                        Button("订阅") { app.subscribe(link); link = "" }.accessibilityIdentifier("discover.follow")
                        Button("导入") { app.presentImporter() }.accessibilityIdentifier("discover.import")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    Button("刷新") { Task { await app.discover(query: query); await app.refreshFollows() } }
                        .accessibilityIdentifier("discover.refreshFollows")
                    Text("分类").font(.system(size: 13, weight: .semibold)).foregroundColor(colors.textDim)
                    ForEach(SourceCatalog.rows, id: \.key) { row in
                        Toggle(row.title, isOn: Binding(
                            get: { app.settings.sourceOn(row.key) },
                            set: { app.settings.setSource(row.key, $0); app.saveSettings() }
                        ))
                        .font(.system(size: 14))
                    }
                    if !app.settings.follows.isEmpty {
                        ForEach(app.settings.follows) { source in
                            HStack {
                                Text(source.title).lineLimit(1)
                                Spacer()
                                Button("移除") { app.removeFollow(source.id) }
                            }
                            .font(.system(size: 13))
                        }
                    }
                }
                .padding(16)
            }
            .frame(width: min(320, UIScreen.main.bounds.width * 0.82))
            .frame(maxHeight: .infinity)
            .background { SystemGlassFill(dark: colors.dark) }
            Color.black.opacity(0.28)
                .onTapGesture { tools = false }
                .accessibilityIdentifier("discover.tools.dim")
        }
        .ignoresSafeArea()
    }

    private func resultGrid(_ entries: [MediaEntry]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(entries) { entry in
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
                .accessibilityIdentifier("discover.card.\(entry.id)")
            }
        }
    }

    private func addLink() {
        let raw = link
        link = ""
        Task { await app.addPasted(raw) }
    }
}

struct LibraryView: View {
    var startFilter: Int = 0
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
        .onAppear { filter = startFilter }
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

