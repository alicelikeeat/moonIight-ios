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
    @State private var selectedMedia: PhotosPickerItem?
    @State private var selectedImage: Image?
    @State private var selectedPlayer: MediaEntry?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(uiColor: .systemBackground), MoonStyle.background], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch model.selectedTab {
                    case .home: refreshable(.home) { HomeView(onSelect: { selectedPlayer = $0 }) }
                    case .discover: refreshable(.discover) { DiscoverView(onSelect: { selectedPlayer = $0 }) }
                    case .camera: CameraView()
                    case .moments: MomentsView()
                    case .me: MeView(selectedImage: selectedImage, selection: $selectedMedia, onSelect: { selectedPlayer = $0 })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                tabBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selectedPlayer) { MediaPlayerView(entry: $0) }
        .task { await model.mediaStore.refreshDiscover() }
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
        glassTabContainer {
            HStack(spacing: 10) {
                ForEach(AppTab.allCases) { tab in
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { model.selectedTab = tab }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.symbol).font(.system(size: 18, weight: .semibold))
                            Text(tab.title).font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(model.selectedTab == tab ? MoonStyle.accent : .secondary)
                        .frame(width: 56, height: 56)
                        .moonGlassCircle()
                    }
                    .buttonStyle(.plain).accessibilityLabel(tab.title)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .padding(.horizontal, 14).padding(.bottom, 6)
    }
}

private struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    @State private var batchSize = 10
    private let sizes = [10, 15, 20]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "月光", subtitle: "为你留一段安静的时间", symbol: "moon.stars.fill")
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
            sectionHeading("最近内容", action: "筛选")
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
            Slider(value: $bannerScale, in: 0.75...1.35) { Text("横幅大小") }
            HStack {
                Text(query.isEmpty ? "推荐内容" : "搜索结果").font(.title3.bold())
                Spacer()
                Button { Task { await model.mediaStore.searchYouTube(query) } } label: {
                    Label("搜索", systemImage: "magnifyingglass").font(.subheadline.weight(.medium))
                }.buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
            }
            let results = query.isEmpty ? model.mediaStore.discoverItems : model.mediaStore.searchResults
            if results.isEmpty {
                EmptyPanel(title: query.isEmpty ? "还没有推荐内容" : "没有搜索结果", detail: model.mediaStore.notice ?? "下拉刷新内容源，或在设置中配置 YouTube API Key。", symbol: "safari")
            } else {
                LazyVGrid(columns: columns == 1 ? [GridItem(.flexible())] : grid, spacing: 14) {
                    ForEach(results) { entry in MediaEntryCard(entry: entry, height: CGFloat(columns == 1 ? 220 : 155) * bannerScale, onSelect: { onSelect(entry) }) }
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
    let entry: MediaEntry
    let height: CGFloat
    var isSelected = false
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    thumbnail
                        .frame(maxWidth: .infinity).frame(height: height).clipped()
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
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(isSelected ? MoonStyle.accent : .white.opacity(0.55), lineWidth: isSelected ? 2 : 1))
            .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if entry.kind == .image, let url = entry.remoteURL, url.isFileURL,
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
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

private struct MediaPlayerView: View {
    let entry: MediaEntry
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
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

private struct MomentsView: View {
    @AppStorage("moonlight.moments.v1") private var storedMoments = Data()
    @State private var draft = ""
    @State private var showingComposer = false
    @State private var likedIDs = Set<String>()

    private var moments: [LocalMoment] {
        (try? JSONDecoder().decode([LocalMoment].self, from: storedMoments)) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 38)).foregroundStyle(MoonStyle.accent)
                    Spacer()
                    Text("朋友圈").font(.title2.bold())
                    Spacer()
                    Button { showingComposer = true } label: { Image(systemName: "square.and.pencil").font(.title3).frame(width: 42, height: 42).moonGlassCircle() }
                        .accessibilityLabel("发布动态")
                }.padding(.vertical, 6)
                HStack {
                    sectionHeading("最近动态", action: "")
                    Spacer()
                    Button("发布") { showingComposer = true }.foregroundStyle(MoonStyle.accent)
                }
                if moments.isEmpty {
                    EmptyPanel(title: "还没有动态", detail: "写下近况，发布后会保存在本机朋友圈。", symbol: "person.2")
                } else {
                    ForEach(moments) { moment in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 36)).foregroundStyle(MoonStyle.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("我").font(.subheadline.weight(.semibold))
                                    Text(moment.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(moment.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 8) {
                                Button { toggleLike(moment.id) } label: {
                                    Label(likedIDs.contains(moment.id) ? "已赞" : "赞", systemImage: likedIDs.contains(moment.id) ? "heart.fill" : "heart")
                                }
                                .foregroundStyle(likedIDs.contains(moment.id) ? .pink : MoonStyle.accent)
                            }.font(.subheadline)
                        }
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                        .transition(.opacity)
                    }
                }
            }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 24)
        }.scrollIndicators(.hidden)
            .alert("发布动态", isPresented: $showingComposer) {
                TextField("分享此刻…", text: $draft, axis: .vertical)
                Button("取消", role: .cancel) { draft = "" }
                Button("发布") { publish() }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { Text("动态保存在本机。") }
    }

    private func publish() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = moments
        updated.insert(LocalMoment(text: text), at: 0)
        if let encoded = try? JSONEncoder().encode(updated) { storedMoments = encoded }
        draft = ""
    }

    private func toggleLike(_ id: String) {
        if likedIDs.contains(id) { likedIDs.remove(id) } else { likedIDs.insert(id) }
    }
}

private struct LocalMoment: Codable, Identifiable {
    var id = UUID().uuidString
    var text: String
    var date = Date.now
}

private struct MeView: View {
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
                    NavigationLink { ProfileEditView() } label: {
                        HStack(spacing: 14) {
                            if let selectedImage {
                                selectedImage.resizable().scaledToFill().frame(width: 58, height: 58).clipShape(Circle())
                            } else {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 58)).foregroundStyle(MoonStyle.accent)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text("我的主页").font(.title3.bold()).foregroundStyle(.primary)
                                Text("编辑头像、封面与个人资料").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain)
                    HStack(spacing: 10) {
                        StatCard(value: "—", label: "动态")
                        StatCard(value: "—", label: "好友")
                        StatCard(value: "—", label: "库")
                        StatCard(value: "—", label: "收藏")
                    }
                    VStack(spacing: 0) {
                        NavigationLink { LibraryView(selectedImage: selectedImage, selection: $selection, onPlay: onSelect) } label: { MenuRow(symbol: "square.grid.2x2.fill", title: "库", color: .orange) }
                        Divider().padding(.leading, 56)
                        NavigationLink { EmptyPanel(title: "好友", detail: "好友列表将在这里显示。", symbol: "person.2") } label: { MenuRow(symbol: "person.2.fill", title: "朋友", color: .green) }
                        Divider().padding(.leading, 56)
                        NavigationLink { EmptyPanel(title: "消息", detail: "聊天与消息将在这里显示。", symbol: "bubble.left.and.bubble.right") } label: { MenuRow(symbol: "bubble.left.and.bubble.right.fill", title: "消息", color: .purple) }
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

private struct ProfileEditView: View {
    @State private var avatar: PhotosPickerItem?
    @State private var cover: PhotosPickerItem?
    var body: some View {
        Form {
            Section("头像与封面") {
                PhotosPicker(selection: $avatar, matching: .any(of: [.images, .videos])) {
                    Label("选择头像照片或视频", systemImage: "person.crop.circle")
                }
                PhotosPicker(selection: $cover, matching: .any(of: [.images, .videos])) {
                    Label("选择顶部封面照片或视频", systemImage: "rectangle.fill")
                }
                Text("媒体预览与资料保存将在社交功能移植阶段接入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("编辑资料")
    }
}

private struct CameraView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCamera = false
    @State private var showPicker = false
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
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { cameraError = "当前设备没有可用的相机，请从照片图库导入。" }
                    } label: {
                        Label("打开相机", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(.borderedProminent).tint(MoonStyle.accent)
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
                CameraCaptureView { image in capturedImage = image }
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
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, dismiss: dismiss) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
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
        case "下载": []
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
                Section("播放") { Toggle("视频保持竖屏", isOn: $model.portraitPlaybackOnly) }
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
                Section("手势说明") {
                    Label("点按：播放或打开", systemImage: "hand.tap")
                    Label("双击：首页喜欢；朋友圈点赞", systemImage: "hand.tap")
                    Label("长按：打开对象菜单", systemImage: "hand.point.up.left")
                    Label("下拉：刷新首页或发现", systemImage: "arrow.down")
                    Label("上下滑：切换内容；左滑：查看详情", systemImage: "hand.draw")
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

private func sectionHeading(_ title: String, action: String) -> some View {
    HStack {
        Text(title).font(.title3.bold())
        Spacer()
        Button(action) {}.font(.subheadline.weight(.medium)).foregroundStyle(MoonStyle.accent)
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



