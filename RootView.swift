import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum MoonStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let accent = Color(red: 0.48, green: 0.45, blue: 0.30)
    static let muted = Color.secondary
    static let cardRadius: CGFloat = 24
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedMedia: PhotosPickerItem?
    @State private var selectedImage: Image?
    @State private var activeSheet: RootSheet?
    @State private var activePlayer: MediaEntry?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(uiColor: .systemBackground), MoonStyle.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch model.selectedTab {
                    case .home: refreshable(.home) { HomeView(onSelect: { activePlayer = $0 }) }
                    case .discover: refreshable(.discover) { DiscoverView(onSelect: { activePlayer = $0 }) }
                    case .camera: CameraView()
                    case .moments: MomentsView(onSelect: { activePlayer = $0 }, onCompose: { activeSheet = .composer(nil) })
                    case .me: MeView(selectedImage: selectedImage, selection: $selectedMedia, onSelect: { activePlayer = $0 })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                tabBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(item: $activePlayer) { entry in
            MediaPlayerView(entry: entry) {
                activePlayer = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    activeSheet = .composer(entry)
                }
            }
        }
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .composer(let entry):
                MomentComposerView(initialAttachment: entry) { text, attachment in
                    model.publishMoment(text: text, attachment: attachment)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .task { await model.mediaStore.refreshDiscover() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.runVirtualActivityLoop()
        }
        .task(id: selectedMedia) {
            guard let selectedMedia,
                  let data = try? await selectedMedia.loadTransferable(type: Data.self) else { return }
            if let image = UIImage(data: data) {
                selectedImage = Image(uiImage: image)
                model.mediaStore.importImage(data, title: "导入的照片")
            } else if let type = selectedMedia.supportedContentTypes.first, type.conforms(to: .movie) {
                model.mediaStore.importMedia(data, title: "导入的视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
            }
        }
    }

    private func refreshable<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        ScrollView { content().frame(maxWidth: .infinity) }
            .scrollIndicators(.hidden)
            .refreshable { await model.refresh(tab) }
    }

    private var tabBar: some View {
        GeometryReader { geometry in
            let diameter = min(62, max(48, (geometry.size.width - 24) / 5))
            HStack(spacing: 6) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { model.selectedTab = tab }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.symbol).font(.system(size: 18, weight: .semibold))
                            Text(tab.title).font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(model.selectedTab == tab ? MoonStyle.accent : .secondary)
                        .frame(width: diameter, height: diameter)
                        .moonGlassCircle()
                    }
                    .buttonStyle(.plain).accessibilityLabel(tab.title)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 66).padding(.horizontal, 14).padding(.bottom, 6)
    }
}

private enum RootSheet: Identifiable {
    case composer(MediaEntry?)
    var id: String {
        switch self {
        case .composer(let entry): "composer-\(entry?.id ?? "new")"
        }
    }
}

private struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    @State private var batchSize = 10
    private let sizes = [10, 15, 20]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "月淡", subtitle: "为你留一段安静的时间", symbol: "moon.stars.fill")
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("随便看看").font(.title3.bold())
                        Text("从已启用的内容源随机加入内容").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "shuffle").font(.title3.weight(.semibold)).foregroundStyle(MoonStyle.accent)
                        .frame(width: 44, height: 44).background(MoonStyle.accent.opacity(0.1), in: Circle())
                }
                Picker("加入数量", selection: $batchSize) {
                    ForEach(sizes, id: \.self) { Text("\($0) 条").tag($0) }
                }.pickerStyle(.segmented)
                Button { Task { await model.mediaStore.addRandom(count: batchSize) } } label: {
                    Label("随机添加 \(batchSize) 条", systemImage: "sparkles")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).tint(MoonStyle.accent)
            }
            .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: MoonStyle.cardRadius))
            Text("最近内容").font(.title3.bold())
            if model.mediaStore.items.isEmpty {
                EmptyPanel(title: "内容会出现在这里", detail: "下拉刷新，或从内容源随机添加内容。", symbol: "play.rectangle")
            } else {
                ForEach(model.mediaStore.items) { entry in MediaEntryCard(entry: entry, height: 210, onSelect: { onSelect(entry) }) }
            }
            if let notice = model.mediaStore.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
    }
}

private struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    @State private var query = ""
    @AppStorage("discover_columns") private var columns = 2
    @AppStorage("discover_banner_scale") private var bannerScale = 1.0
    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let cardGradients: [[Color]] = [
        [.indigo.opacity(0.72), .purple.opacity(0.35)], [.orange.opacity(0.68), .pink.opacity(0.3)],
        [.teal.opacity(0.7), .blue.opacity(0.32)], [.brown.opacity(0.58), .orange.opacity(0.3)]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "发现", subtitle: "探索新的内容源", symbol: "safari") {
                Button { columns = columns == 1 ? 2 : 1 } label: {
                    Image(systemName: columns == 1 ? "rectangle.grid.2x2" : "rectangle.grid.1x2")
                        .font(.headline).frame(width: 42, height: 42).moonGlassCircle()
                }.buttonStyle(.plain).accessibilityLabel("切换单双列")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 YouTube 视频或粘贴链接", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await model.mediaStore.searchYouTube(query) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 15).frame(height: 50)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("横幅大小").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(bannerScale * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $bannerScale, in: 0.75...1.35)
            }
            HStack {
                Text(query.isEmpty ? "推荐内容" : "搜索结果").font(.title3.bold())
                Spacer()
                Button { Task { await model.mediaStore.searchYouTube(query) } } label: {
                    Label("搜索", systemImage: "magnifyingglass").font(.subheadline.weight(.medium))
                }.buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
            }
            let results = query.isEmpty ? model.mediaStore.discoverItems : model.mediaStore.searchResults
            if results.isEmpty {
                if !query.isEmpty && !model.mediaStore.youtubeKeyConfigured {
                    YouTubeSearchFallback(query: query)
                } else {
                    EmptyPanel(title: query.isEmpty ? "还没有推荐内容" : "没有搜索结果", detail: model.mediaStore.notice ?? "下拉刷新内容源，或在设置中配置 YouTube API Key。", symbol: "safari")
                }
            } else {
                LazyVGrid(columns: columns == 1 ? [GridItem(.flexible())] : grid, spacing: 14) {
                    ForEach(results) { entry in
                        MediaEntryCard(entry: entry, height: CGFloat(columns == 1 ? 220 : 155) * bannerScale, onSelect: { onSelect(entry) })
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if !query.isEmpty && model.mediaStore.hasMoreYouTubeResults {
                Button("加载更多") { Task { await model.mediaStore.searchYouTube(query, nextPage: true) } }.buttonStyle(.bordered)
            }
            if model.mediaStore.isSearching { ProgressView().frame(maxWidth: .infinity) }
            if let notice = model.mediaStore.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
    }
}

private struct DiscoverTile: View {
    let gradient: [Color]
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle()).padding(12)
            }
            .frame(height: compact ? 155 : 220)
            VStack(alignment: .leading, spacing: 5) {
                Text("精选内容源").font(.caption.weight(.semibold)).foregroundStyle(MoonStyle.accent)
                Text("发现值得收藏的新内容")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(2)
            }.padding(13)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }
}

private struct MediaEntryCard: View {
    @EnvironmentObject private var model: AppModel
    let entry: MediaEntry
    let height: CGFloat
    var isSelected = false
    let onSelect: () -> Void
    @State private var suppressNextTap = false
    @State private var showPopover = false
    @State private var showGlassMenu = false
    @State private var longPressActivated = false
    @State private var fingerPoint: CGPoint = .zero
    @State private var dropletScale: CGFloat = 1
    @State private var lastFingerPoint: CGPoint?
    @State private var lastFingerTime: TimeInterval?

    var body: some View {
        Button {
            if suppressNextTap { suppressNextTap = false }
            else { onSelect() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    GeometryReader { proxy in
                        thumbnail
                            .frame(width: proxy.size.width, height: height)
                            .clipped()
                    }
                    .frame(height: height)
                    .clipped()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, MoonStyle.accent)
                            .padding(9)
                    }
                    Text(entry.platform == "bili" ? "哔哩" : entry.platform == "youtube" ? "YouTube" : entry.platform)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                    Text(entry.author.isEmpty ? entry.platform : entry.author)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(isSelected ? MoonStyle.accent : .white.opacity(0.55), lineWidth: isSelected ? 2 : 1))
            .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onChanged { value in
                    guard case .second(true, let dragValue) = value else { return }
                    if let dragValue { updateLongPressLocation(dragValue.location) }
                    if !longPressActivated { activateLongPress() }
                }
                .onEnded { _ in
                    longPressActivated = false
                    lastFingerPoint = nil
                    lastFingerTime = nil
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { dropletScale = 1 }
                }
        )
        .overlay {
            GeometryReader { geometry in
                if showGlassMenu {
                    let x = min(max(fingerPoint.x, 104), max(104, geometry.size.width - 104))
                    let y = min(max(fingerPoint.y, 38), max(38, geometry.size.height - 38))
                    ZStack {
                        Color.clear.contentShape(Rectangle()).onTapGesture { showGlassMenu = false }
                        glassTabContainer {
                            HStack(spacing: 4) {
                                quickAction("play.fill", title: "打开") { onSelect() }
                                quickAction(entry.isFavorite ? "heart.slash" : "heart", title: entry.isFavorite ? "取消收藏" : "收藏") {
                                    model.mediaStore.toggleFavorite(entry)
                                }
                                quickAction("plus", title: "加入库") { model.mediaStore.appendToLibrary([entry]) }
                                Button { showGlassMenu = false } label: {
                                    Image(systemName: "xmark").font(.caption.bold()).frame(width: 38, height: 38).moonGlassCircle()
                                }.buttonStyle(.plain).accessibilityLabel("关闭快捷菜单")
                            }.padding(7)
                        }
                        .scaleEffect(model.longPressStyle == .droplet ? dropletScale : 1)
                        .position(x: x, y: y)
                    }
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: showGlassMenu)
        }
        .confirmationDialog("快捷操作", isPresented: $showPopover, titleVisibility: .visible) {
            Button("打开") { onSelect() }
            Button(entry.isFavorite ? "取消收藏" : "收藏") { model.mediaStore.toggleFavorite(entry) }
            Button("加入库") { model.mediaStore.appendToLibrary([entry]) }
            Button("删除", role: .destructive) { model.mediaStore.delete(entry) }
            Button("取消", role: .cancel) { }
        }
    }

    private func activateLongPress() {
        longPressActivated = true
        suppressNextTap = true
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            switch model.longPressStyle {
            case .popover: showPopover = true
            case .trackingGlass, .droplet: showGlassMenu = true
            }
        }
    }

    private func updateLongPressLocation(_ location: CGPoint) {
        let now = Date.timeIntervalSinceReferenceDate
        fingerPoint = location
        if model.longPressStyle == .droplet, let previous = lastFingerPoint, let previousTime = lastFingerTime {
            let elapsed = max(0.01, now - previousTime)
            let speed = hypot(location.x - previous.x, location.y - previous.y) / elapsed
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.58)) {
                dropletScale = min(1.32, max(0.78, 1 + speed / 1500))
            }
        }
        lastFingerPoint = location
        lastFingerTime = now
    }

    private func quickAction(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showGlassMenu = false
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }.frame(width: 48, height: 38).moonGlassCircle()
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if entry.kind == .image, let url = entry.remoteURL, url.isFileURL,
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if entry.kind == .video, let url = entry.remoteURL, url.isFileURL {
            LocalVideoPoster(url: url)
        } else if let url = entry.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: fallback
                case .empty: ZStack { fallback; ProgressView().tint(.white) }
                @unknown default: fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        LinearGradient(colors: [MoonStyle.accent.opacity(0.72), Color.indigo.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "play.rectangle.fill").font(.system(size: 32)).foregroundStyle(.white.opacity(0.75)))
    }
}

private struct LocalVideoPoster: View {
    let url: URL
    @State private var poster: UIImage?
    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [MoonStyle.accent.opacity(0.65), .indigo.opacity(0.36)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            if let result = try? await generator.image(at: .zero) { poster = UIImage(cgImage: result.image) }
        }
    }
}

private struct MediaPlayerView: View {
    let entry: MediaEntry
    let onShareToMoments: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if entry.kind == .embed, let url = entry.embedURL {
                    WebEmbedView(url: url)
                } else if entry.kind == .video, let url = entry.remoteURL {
                    VideoPlayer(player: player ?? AVPlayer(url: url))
                        .onAppear { player = AVPlayer(url: url); player?.play() }
                        .onDisappear { player?.pause() }
                } else if entry.kind == .image, let url = entry.remoteURL, url.isFileURL,
                          let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if let url = entry.remoteURL ?? entry.coverURL {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                } else {
                    EmptyPanel(title: "无法打开内容", detail: "这个条目没有可用的媒体地址。", symbol: "exclamationmark.triangle")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .navigationTitle(entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if entry.kind != .embed, let url = entry.remoteURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await model.mediaStore.downloadDirectFile(entry) }
                        } label: {
                            if model.mediaStore.downloadingIDs.contains(entry.id) { ProgressView() }
                            else { Image(systemName: "arrow.down.to.line") }
                        }.accessibilityLabel("下载")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onShareToMoments(); dismiss() } label: { Label("朋友圈", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onAppear {
            MoonlightOrientationDelegate.playerAllowsLandscape = !model.portraitPlaybackOnly
        }
        .onDisappear {
            MoonlightOrientationDelegate.playerAllowsLandscape = false
        }
    }
}

private struct WebEmbedView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.scrollView.isScrollEnabled = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if view.url != url { view.load(URLRequest(url: url)) }
    }
}

private struct YouTubeSearchFallback: View {
    let query: String
    private var searchURL: URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components?.url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("YouTube 网页搜索", systemImage: "globe")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let searchURL {
                WebEmbedView(url: searchURL).frame(height: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            } else {
                EmptyPanel(title: "搜索链接无效", detail: "请检查搜索词后重试。", symbol: "exclamationmark.triangle")
            }
        }
    }
}

private struct MomentsView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    let onCompose: () -> Void
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    @State private var avatarSelection: PhotosPickerItem?
    @State private var coverSelection: PhotosPickerItem?
    @State private var commentTargetID: String?
    @State private var commentDraft = ""
    @State private var showingCommentPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    PhotosPicker(selection: $coverSelection, matching: .any(of: [.images, .videos])) {
                        Group {
                            if isMoviePath(coverPath), !coverPath.isEmpty {
                                LocalVideoPoster(url: URL(fileURLWithPath: coverPath))
                            } else if !coverPath.isEmpty, let image = UIImage(contentsOfFile: coverPath) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                LinearGradient(colors: [Color.indigo.opacity(0.72), MoonStyle.accent.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                        .frame(height: 190).frame(maxWidth: .infinity).clipped()
                        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom))
                        .overlay(alignment: .topLeading) {
                            HStack {
                                Text("朋友圈").font(.title2.bold())
                                Spacer()
                                Image(systemName: "photo").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                            }.foregroundStyle(.white).padding(14)
                        }
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $avatarSelection, matching: .any(of: [.images, .videos])) {
                            Group {
                                if !avatarPath.isEmpty, let image = UIImage(contentsOfFile: avatarPath) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                } else {
                                    Image(systemName: isMoviePath(avatarPath) ? "play.fill" : "person.crop.circle.fill")
                                        .font(.system(size: 36)).foregroundStyle(.white).frame(width: 60, height: 60)
                                        .background(MoonStyle.accent.gradient, in: Circle())
                                }
                            }
                            .frame(width: 60, height: 60).clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel("更换朋友圈头像")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName).font(.headline).foregroundStyle(.white)
                            Text("点击头像或横幅更换媒体").font(.caption).foregroundStyle(.white.opacity(0.82))
                        }
                        Spacer()
                        Button(action: onCompose) {
                            Image(systemName: "square.and.pencil").font(.title3).frame(width: 42, height: 42).moonGlassCircle()
                        }.accessibilityLabel("发布动态")
                    }.padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                HStack {
                    Text("最近动态").font(.title3.bold())
                    Spacer()
                }
                if model.moments.isEmpty {
                    EmptyPanel(title: "还没有动态", detail: "写下近况，发布后会保存在本机朋友圈。", symbol: "person.2")
                } else {
                    ForEach(model.moments) { moment in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Group {
                                    if moment.isVirtual {
                                        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                                            .foregroundStyle(MoonStyle.accent)
                                    } else if isMoviePath(avatarPath), !avatarPath.isEmpty {
                                        Image(systemName: "play.circle.fill").resizable().scaledToFit()
                                            .foregroundStyle(MoonStyle.accent)
                                    } else if !avatarPath.isEmpty, let avatar = UIImage(contentsOfFile: avatarPath) {
                                        Image(uiImage: avatar).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                                            .foregroundStyle(MoonStyle.accent)
                                    }
                                }
                                .frame(width: 38, height: 38).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(moment.authorName).font(.subheadline.weight(.semibold))
                                    HStack(spacing: 6) {
                                        Text(moment.date.formatted(date: .abbreviated, time: .shortened))
                                        if moment.isVirtual { Text("虚拟好友") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if !moment.text.isEmpty {
                                Text(moment.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let attachment = moment.attachment {
                                Button { onSelect(attachment) } label: { MomentAttachmentPreview(entry: attachment) }
                                    .buttonStyle(.plain)
                            }
                            HStack(spacing: 8) {
                                Button { model.toggleMomentLike(moment.id) } label: {
                                    Label("\(moment.likes)", systemImage: moment.likedByMe ? "heart.fill" : "heart")
                                }
                                .foregroundStyle(moment.likedByMe ? .pink : MoonStyle.accent)
                                if !moment.comments.isEmpty {
                                    Button {
                                        commentTargetID = moment.id
                                        showingCommentPrompt = true
                                    } label: {
                                        Label("\(moment.comments.count)", systemImage: "bubble.right")
                                    }.foregroundStyle(.secondary)
                                } else {
                                    Button {
                                        commentTargetID = moment.id
                                        showingCommentPrompt = true
                                    } label: { Label("评论", systemImage: "bubble.right") }
                                        .foregroundStyle(.secondary)
                                }
                                if moment.reposts > 0 {
                                    Label("\(moment.reposts)", systemImage: "arrow.2.squarepath")
                                        .foregroundStyle(.secondary)
                                }
                                Button { model.repostMoment(moment.id) } label: {
                                    Image(systemName: "arrow.2.squarepath")
                                }.foregroundStyle(.secondary).accessibilityLabel("转发动态")
                            }.font(.subheadline)
                            if let comment = moment.comments.last {
                                Text("\(moment.isVirtual ? "好友评论" : "评论")：\(comment)")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                        .transition(.opacity)
                    }
                }
            }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 24)
        }.scrollIndicators(.hidden)
            .task(id: avatarSelection) {
                if let path = await saveProfileMedia(avatarSelection, name: "avatar") { avatarPath = path }
            }
            .task(id: coverSelection) {
                if let path = await saveProfileMedia(coverSelection, name: "cover") { coverPath = path }
            }
            .alert("评论动态", isPresented: $showingCommentPrompt) {
                TextField("写下评论…", text: $commentDraft)
                Button("取消", role: .cancel) { commentDraft = "" }
                Button("发送") {
                    if let commentTargetID { model.addMomentComment(commentTargetID, text: commentDraft) }
                    commentDraft = ""
                }.disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
    }
}

@MainActor
private func saveProfileMedia(_ item: PhotosPickerItem?, name: String) async -> String? {
    guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return nil }
    let type = item.supportedContentTypes.first
    let ext = type?.preferredFilenameExtension ?? (type?.conforms(to: .movie) == true ? "mov" : "jpg")
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("profile", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .atomic)
        return url.path
    } catch { return nil }
}

private struct MomentAttachmentPreview: View {
    let entry: MediaEntry
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if entry.kind == .image, let url = entry.remoteURL, url.isFileURL,
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill().frame(height: 210).frame(maxWidth: .infinity).clipped()
            } else if entry.kind == .video, let url = entry.remoteURL, url.isFileURL {
                LocalVideoPoster(url: url).frame(height: 210).frame(maxWidth: .infinity).clipped()
            } else if let cover = entry.coverURL {
                AsyncImage(url: cover) { image in image.resizable().scaledToFill() } placeholder: { attachmentFallback }
                    .frame(height: 210).frame(maxWidth: .infinity).clipped()
            } else { attachmentFallback.frame(height: 210) }
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.platform == "bili" ? "哔哩哔哩" : entry.platform == "youtube" ? "YouTube" : "月淡库")
                    .font(.caption.weight(.semibold))
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }.foregroundStyle(.white).padding(12)
            Image(systemName: entry.kind == .image ? "photo" : "play.fill")
                .font(.title3.weight(.bold)).foregroundStyle(.white)
                .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    private var attachmentFallback: some View {
        LinearGradient(colors: [MoonStyle.accent.opacity(0.72), .indigo.opacity(0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.82)))
    }
}

private struct MomentComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var attachment: MediaEntry?
    let initialAttachment: MediaEntry?
    let onPublish: (String, MediaEntry?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("此刻") { TextField("分享此刻…", text: $text, axis: .vertical).lineLimit(3...7) }
                Section("照片或视频") {
                    if let attachment {
                        MomentAttachmentPreview(entry: attachment).frame(height: 180)
                        Button("移除附件", role: .destructive) { self.attachment = nil }
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .any(of: [.images, .videos])) {
                        Label("选择照片或视频", systemImage: "photo.badge.plus")
                    }
                }
                if initialAttachment != nil {
                    Section { Text("来自内容流的条目会以可打开的链接预览显示在动态中。").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("发布动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") {
                        onPublish(text.trimmingCharacters(in: .whitespacesAndNewlines), attachment)
                        dismiss()
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil)
                }
            }
            .task { if attachment == nil { attachment = initialAttachment } }
            .task(id: photoPickerItem) { await loadAttachment() }
        }
    }

    @MainActor private func loadAttachment() async {
        guard let photoPickerItem, let data = try? await photoPickerItem.loadTransferable(type: Data.self) else { return }
        if let image = UIImage(data: data) {
            attachment = model.mediaStore.importMedia(data, title: "朋友圈照片", kind: .image, fileExtension: photoPickerItem.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")
            _ = image
        } else if let type = photoPickerItem.supportedContentTypes.first, type.conforms(to: .movie) {
            attachment = model.mediaStore.importMedia(data, title: "朋友圈视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
        }
    }
}

private struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.bio") private var profileBio = "分享生活里的灵感"
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    let selectedImage: Image?
    @Binding var selection: PhotosPickerItem?
    let onSelect: (MediaEntry) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: "我", subtitle: "个人空间", symbol: "person.crop.circle") {
                        NavigationLink { SettingsView() } label: {
                            Image(systemName: "gearshape").font(.title3).frame(width: 42, height: 42).moonGlassCircle()
                        }
                    }
                    if !coverPath.isEmpty, let cover = UIImage(contentsOfFile: coverPath) {
                        Image(uiImage: cover).resizable().scaledToFill()
                            .frame(height: 150).frame(maxWidth: .infinity).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    } else if isMoviePath(coverPath), !coverPath.isEmpty {
                        let url = URL(fileURLWithPath: coverPath)
                        VideoPlayer(player: AVPlayer(url: url)).frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                    NavigationLink { ProfileEditView() } label: {
                        HStack(spacing: 14) {
                            if !avatarPath.isEmpty, let avatar = UIImage(contentsOfFile: avatarPath) {
                                Image(uiImage: avatar).resizable().scaledToFill().frame(width: 58, height: 58).clipShape(Circle())
                            } else if isMoviePath(avatarPath) {
                                Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundStyle(MoonStyle.accent)
                            } else if let selectedImage {
                                selectedImage.resizable().scaledToFill().frame(width: 58, height: 58).clipShape(Circle())
                            } else {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 58)).foregroundStyle(MoonStyle.accent)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayName).font(.title3.bold()).foregroundStyle(.primary)
                                Text(profileBio).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain)
                    HStack(spacing: 10) {
                        StatCard(value: "\(model.moments.count)", label: "动态")
                        StatCard(value: "\(VirtualFriendRoster.names.count)", label: "好友")
                        StatCard(value: "\(model.mediaStore.items.count)", label: "库")
                        StatCard(value: "\(model.mediaStore.items.filter(\.isFavorite).count)", label: "收藏")
                    }
                    VStack(spacing: 0) {
                        NavigationLink { LibraryView(selectedImage: selectedImage, selection: $selection, onPlay: onSelect) } label: { MenuRow(symbol: "square.grid.2x2.fill", title: "库", color: .orange) }
                        Divider().padding(.leading, 56)
                        NavigationLink { VirtualFriendsView(onSelect: onSelect) } label: { MenuRow(symbol: "person.2.fill", title: "朋友", color: .green) }
                        Divider().padding(.leading, 56)
                        NavigationLink { VirtualMessagesView() } label: { MenuRow(symbol: "bubble.left.and.bubble.right.fill", title: "消息", color: .purple) }
                    }
                    .buttonStyle(.plain).padding(.horizontal, 14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct VirtualFriendsView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    var body: some View {
        List {
            Section("虚拟好友 · 本机") {
                ForEach(Array(VirtualFriendRoster.names.enumerated()), id: \.offset) { item in
                    let index = item.offset
                    let name = item.element
                    NavigationLink {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(model.moments.filter { $0.authorName == name }) { post in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(post.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                        if let entry = post.attachment {
                                            Button { onSelect(entry) } label: { MomentAttachmentPreview(entry: entry) }.buttonStyle(.plain)
                                        }
                                        Label("\(post.likes) 赞 · \(post.comments.count) 评论 · \(post.reposts) 转发", systemImage: "heart")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                                }
                                if model.moments.allSatisfy({ $0.authorName != name }) {
                                    EmptyPanel(title: "还没有动态", detail: "开启虚拟好友自动动态后，这里会显示其分享。", symbol: "person.crop.circle")
                                }
                            }.padding(16)
                        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 38))
                                .foregroundStyle([Color.blue, .orange, .purple, .pink, .teal, .green][index % 6])
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.body.weight(.semibold))
                                Text(model.moments.first(where: { $0.authorName == name })?.date.formatted(.relative(presentation: .named)) ?? "等待分享")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.navigationTitle("朋友").navigationBarTitleDisplayMode(.inline)
    }
}

private struct VirtualMessagesView: View {
    @EnvironmentObject private var model: AppModel
    private var recentInteractions: [MomentPost] { model.moments.filter { $0.isVirtual && !$0.comments.isEmpty } }
    var body: some View {
        List {
            if recentInteractions.isEmpty {
                EmptyPanel(title: "还没有新消息", detail: "虚拟好友发布动态或评论后，互动摘要会显示在这里。", symbol: "bubble.left.and.bubble.right")
            } else {
                ForEach(recentInteractions) { post in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(post.authorName).font(.subheadline.weight(.semibold))
                        Text(post.comments.last ?? post.text).font(.body).lineLimit(2)
                        Text(post.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle("消息").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfileEditView: View {
    @State private var avatar: PhotosPickerItem?
    @State private var cover: PhotosPickerItem?
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.bio") private var profileBio = "分享生活里的灵感"

    var body: some View {
        Form {
            Section("个人资料") {
                TextField("昵称", text: $displayName).textInputAutocapitalization(.never)
                TextField("签名", text: $profileBio, axis: .vertical).lineLimit(1...3)
            }
            Section("个人头像") {
                if !avatarPath.isEmpty, let image = UIImage(contentsOfFile: avatarPath) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 88, height: 88).clipShape(Circle())
                }
                PhotosPicker(selection: $avatar, matching: .any(of: [.images, .videos])) {
                    Label("选择头像照片或视频", systemImage: "person.crop.circle")
                }
            }
            Section("顶部封面") {
                if !coverPath.isEmpty, let image = UIImage(contentsOfFile: coverPath) {
                    Image(uiImage: image).resizable().scaledToFill().frame(height: 130).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                } else if isMoviePath(coverPath), !coverPath.isEmpty {
                    let url = URL(fileURLWithPath: coverPath)
                    VideoPlayer(player: AVPlayer(url: url)).frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                PhotosPicker(selection: $cover, matching: .any(of: [.images, .videos])) {
                    Label("选择顶部封面照片或视频", systemImage: "rectangle.fill")
                }
            }
        }.navigationTitle("编辑资料")
            .task(id: avatar) { await save(avatar, key: "avatar") }
            .task(id: cover) { await save(cover, key: "cover") }
    }

    @MainActor
    private func save(_ item: PhotosPickerItem?, key: String) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let isVideo = type?.conforms(to: .movie) == true
        let ext = type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(key)-\(UUID().uuidString).\(ext)")
            try data.write(to: url, options: .atomic)
            if key == "avatar" { avatarPath = url.path } else { coverPath = url.path }
        } catch { }
    }
}

private func isMoviePath(_ path: String) -> Bool {
    ["mov", "mp4", "m4v", "mpeg", "mpg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
}

private struct CameraView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var captureVideo = false
    @State private var capturedImage: UIImage?
    @State private var cameraError: String?
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                PageHeader(title: "拍摄", subtitle: "捕捉此刻", symbol: "camera")
                if let capturedImage {
                    Image(uiImage: capturedImage).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .frame(maxHeight: 420)
                    Button {
                        if let data = capturedImage.jpegData(compressionQuality: 0.92) {
                            model.mediaStore.importImage(data, title: "拍摄的照片")
                        }
                        self.capturedImage = nil
                    } label: {
                        Label("保存到库", systemImage: "square.and.arrow.down")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(.borderedProminent).tint(MoonStyle.accent)
                } else {
                    EmptyPanel(title: "准备好记录此刻了吗？", detail: "拍摄或从照片图库导入，内容会保存到库。", symbol: "camera")
                    Button {
                        captureVideo = false
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { cameraError = "当前设备没有可用的相机，请从照片图库导入。" }
                    } label: {
                        Label("打开相机", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(.borderedProminent).tint(MoonStyle.accent)
                    Button {
                        captureVideo = true
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { cameraError = "当前设备没有可用的相机，请从照片图库导入视频。" }
                    } label: {
                        Label("录制视频", systemImage: "video.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered)
                    Button { showPicker = true } label: {
                        Label("从照片图库导入", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 18).padding(.top, 12)
            .alert("提示", isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
                Button("好", role: .cancel) { cameraError = nil }
            } message: { Text(cameraError ?? "") }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(captureVideo: captureVideo, onCapture: { image in
                    capturedImage = image
                }, onCaptureVideo: { url in
                    model.mediaStore.importVideoFile(url, title: "拍摄的视频")
                })
                    .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPicker, selection: $selectedPhoto, matching: .any(of: [.images, .videos]))
            .task(id: selectedPhoto) {
                guard let selectedPhoto,
                      let data = try? await selectedPhoto.loadTransferable(type: Data.self) else { return }
                if let image = UIImage(data: data) { capturedImage = image }
                else if let type = selectedPhoto.supportedContentTypes.first, type.conforms(to: .movie) {
                    model.mediaStore.importMedia(data, title: "导入的视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
                }
            }
        }
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let captureVideo: Bool
    let onCapture: (UIImage) -> Void
    let onCaptureVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCaptureVideo: onCaptureVideo, dismiss: dismiss) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [captureVideo ? UTType.movie.identifier : UTType.image.identifier]
        picker.cameraCaptureMode = captureVideo ? .video : .photo
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 300
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCaptureVideo: (URL) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (UIImage) -> Void, onCaptureVideo: @escaping (URL) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture; self.onCaptureVideo = onCaptureVideo; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
            if let url = info[.mediaURL] as? URL { onCaptureVideo(url) }
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}

private struct LibraryView: View {
    let selectedImage: Image?
    @Binding var selection: PhotosPickerItem?
    let onPlay: (MediaEntry) -> Void
    @EnvironmentObject private var model: AppModel
    @State private var selectionMode = false
    @State private var selectedIDs = Set<String>()
    @State private var filter = "全部"

    private var visibleItems: [MediaEntry] {
        switch filter {
        case "收藏": model.mediaStore.items.filter(\.isFavorite)
        case "下载": model.mediaStore.items.filter { $0.source == "download" }
        default: model.mediaStore.items
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(selectionMode ? "取消" : "全选") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectionMode.toggle()
                        selectedIDs = selectionMode ? Set(visibleItems.map(\.id)) : []
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MoonStyle.accent)
                Spacer()
                Text("库").font(.title2.bold())
                Spacer()
                PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos])) {
                    Label("导入", systemImage: "plus").font(.subheadline.weight(.semibold))
                }.buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
            }
            Picker("分类", selection: $filter) {
                ForEach(["全部", "收藏", "下载"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            if selectionMode {
                HStack {
                    Text("已选 \(selectedIDs.count) 项").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("收藏") {
                        withAnimation(.easeOut(duration: 0.2)) {
                            for entry in visibleItems where selectedIDs.contains(entry.id) {
                                if !entry.isFavorite { model.mediaStore.toggleFavorite(entry) }
                            }
                        }
                    }
                    Button("删除", role: .destructive) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            for entry in visibleItems where selectedIDs.contains(entry.id) { model.mediaStore.delete(entry) }
                            selectedIDs.removeAll()
                        }
                    }
                    .disabled(selectedIDs.isEmpty)
                }.font(.subheadline.weight(.medium))
            }
            if visibleItems.isEmpty {
                if let selectedImage {
                    selectedImage.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    EmptyPanel(title: filter == "下载" ? "还没有下载内容" : "媒体会显示在这里", detail: "导入照片或视频，或从首页随机添加内容。", symbol: "photo.on.rectangle.angled")
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
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
        .animation(.easeOut(duration: 0.22), value: visibleItems.map(\.id))
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Toggle("视频保持竖屏", isOn: $model.portraitPlaybackOnly)
                    Text(model.portraitPlaybackOnly ? "关闭后，视频播放页可跟随设备方向横屏。" : "横屏仅在视频播放页启用，其他页面保持竖屏。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("内容源") {
                    ForEach(model.mediaStore.enabledSources) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { model.mediaStore.enabledSources.first(where: { $0.id == source.id })?.enabled ?? false },
                            set: { model.mediaStore.setSourceEnabled(source.id, enabled: $0) }
                        ))
                    }
                }
                Section("YouTube 搜索") {
                    SecureField("YouTube API Key", text: $model.mediaStore.youtubeAPIKeyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("安全保存 API Key") {
                        model.mediaStore.setYouTubeAPIKey(model.mediaStore.youtubeAPIKeyDraft)
                    }
                    Text("频道推荐不需 API Key；关键词搜索需要 YouTube Data API v3。密钥保存在本机 Keychain。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("长按菜单") {
                    Picker("交互方式", selection: $model.longPressStyle) {
                        ForEach(LongPressStyle.allCases) { style in Text(style.title).tag(style) }
                    }
                }
                Section("虚拟好友") {
                    Toggle("自动生成朋友圈动态", isOn: $model.virtualActivityEnabled)
                    Picker("发布间隔", selection: $model.virtualIntervalMinutes) {
                        ForEach([15, 30, 60, 240], id: \.self) { minutes in
                            Text(minutes < 60 ? "每 \(minutes) 分钟" : "每 \(minutes / 60) 小时").tag(minutes)
                        }
                    }.disabled(!model.virtualActivityEnabled)
                    Text("开启后会从已启用的内容源读取推荐条目，在应用前台按间隔生成本机动态，并模拟点赞、评论和转发。不会发布到外部社交平台。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("AI 文案服务", selection: $model.virtualAIProvider) {
                        ForEach(VirtualAIProvider.allCases) { provider in Text(provider.title).tag(provider) }
                    }
                    SecureField("\(model.virtualAIProvider.title) API Key（可选）", text: $model.virtualAIKeyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("安全保存 API Key") { model.saveVirtualAIKey() }
                    Text("密钥保存在本机钥匙串。启用后，仅把内容标题和作者发送给所选服务生成文案；未配置时使用本地模板。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("手势说明") {
                    Label("点按媒体卡片：打开播放或预览", systemImage: "hand.tap")
                    Label("长按媒体卡片：按上方设置显示快捷菜单", systemImage: "hand.point.up.left")
                    Label("快捷菜单：打开、收藏、加入库；弹出菜单还可删除", systemImage: "circle.grid.2x2")
                    Label("下拉首页或发现：刷新内容源", systemImage: "arrow.down")
                    Label("播放方向：可在播放设置中开启横屏", systemImage: "rectangle.landscape")
                }
            }
            .scrollContentBackground(.hidden)
            .background(MoonStyle.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

private struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    init(title: String, subtitle: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold()).tracking(-0.5)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyPanel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(MoonStyle.accent)
                .frame(width: 66, height: 66).background(MoonStyle.accent.opacity(0.1), in: Circle())
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 5) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct MenuRow: View {
    let symbol: String
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(color.gradient, in: Circle())
            Text(title).font(.body.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 13)
    }
}






@MainActor
@ViewBuilder
private func glassTabContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: 10) { content() }
    } else {
        content()
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1))
    }
}

private extension View {
    @ViewBuilder
    func moonGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
        }
    }
}


