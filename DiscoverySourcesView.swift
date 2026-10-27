import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct DiscoverySourcePanel: View {
    @EnvironmentObject private var model: AppModel
    @Binding var query: String
    var onClose: () -> Void
    @State private var editingSource: MediaSource?
    @State private var addingSource = false
    @State private var addingLinks = false
    @State private var importedMedia: [PhotosPickerItem] = []
    private let accent = Color(red: 0.48, green: 0.45, blue: 0.30)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("内容源").font(.title2.bold())
                    Text("已启用 \(model.mediaStore.enabledSources.filter(\.enabled).count) 个来源")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36).background(.thinMaterial, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("收起内容源")
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索月亮、海洋、城市…", text: $query)
                            .submitLabel(.search).onSubmit(search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    VStack(spacing: 0) {
                        panelAction("搜索所选来源", symbol: "magnifyingglass", color: .blue, action: search)
                        Divider().padding(.leading, 54)
                        panelAction("加入链接", symbol: "link.badge.plus", color: .green) { addingLinks = true }
                        Divider().padding(.leading, 54)
                        panelAction("订阅 / 添加内容源", symbol: "dot.radiowaves.left.and.right", color: .purple) { addingSource = true }
                        Divider().padding(.leading, 54)
                        PhotosPicker(selection: $importedMedia, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                            actionLabel("从相册导入", symbol: "square.and.arrow.down", color: .orange)
                        }.buttonStyle(.plain)
                        Divider().padding(.leading, 54)
                        panelAction("刷新", symbol: "arrow.clockwise", color: .gray) {
                            Task {
                                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await model.mediaStore.refreshDiscover() }
                                else { await model.mediaStore.searchDiscover(query) }
                            }
                            onClose()
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                    HStack {
                        Text("分类").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("点名称配置").font(.caption).foregroundStyle(.tertiary)
                    }
                    VStack(spacing: 0) {
                        ForEach(model.mediaStore.enabledSources) { source in
                            HStack(spacing: 10) {
                                Button { editingSource = source } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: source.symbol).font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(.white).frame(width: 34, height: 34)
                                            .background(sourceColor(source.kind).gradient, in: Circle())
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(source.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                            if source.enabled, let status = model.mediaStore.sourceStatuses[source.id] {
                                                Text(status).font(.caption2).lineLimit(2)
                                                    .foregroundStyle(model.mediaStore.failedSourceIDs.contains(source.id) ? Color.orange : Color.secondary)
                                            } else if let url = source.url, !url.isEmpty {
                                                Text(URL(string: url)?.host ?? url).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain).accessibilityLabel("配置 \(source.name)")
                                Toggle(source.name, isOn: Binding(
                                    get: { model.mediaStore.enabledSources.first(where: { $0.id == source.id })?.enabled ?? false },
                                    set: { model.mediaStore.setSourceEnabled(source.id, enabled: $0) }
                                )).labelsHidden().tint(accent).accessibilityIdentifier("source-toggle-\(source.id)")
                            }.padding(.vertical, 13).padding(.horizontal, 12)
                            if source.id != model.mediaStore.enabledSources.last?.id { Divider().padding(.leading, 56) }
                        }
                    }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                    Text("开关会保存。搜索只查询已启用的来源；需要密钥或地址的来源可点名称配置。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(16)
            }.scrollIndicators(.hidden).accessibilityIdentifier("source-sidebar-scroll")
        }
        .background(.regularMaterial)
        .sheet(item: $editingSource) { SourceConfigurationView(source: $0) }
        .sheet(isPresented: $addingSource) { AddDiscoverySourceView() }
        .sheet(isPresented: $addingLinks) { AddDiscoveryLinksView() }
        .task(id: importedMedia) {
            guard !importedMedia.isEmpty else { return }
            for item in importedMedia {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                let video = type?.conforms(to: .movie) == true
                model.mediaStore.importMedia(data, title: video ? "导入的视频" : "导入的照片", kind: video ? .video : .image,
                                            fileExtension: type?.preferredFilenameExtension ?? (video ? "mov" : "jpg"))
            }
            importedMedia = []
        }
    }

    private func search() {
        Task { await model.mediaStore.searchDiscover(query) }
        onClose()
    }

    private func panelAction(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, symbol: symbol, color: color) }.buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(color.gradient, in: Circle())
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 12)
    }

    private func sourceColor(_ kind: String) -> Color {
        switch kind {
        case "bili": .pink
        case "youtube", "vimeo", "dailymotion": .red
        case "nasa": .blue
        case "peertube": .orange
        case "commons", "pexels", "pixabay": .green
        case "twitch": .purple
        default: .gray
        }
    }
}

private struct SourceConfigurationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: MediaSource
    @State private var url = ""
    @State private var key = ""
    @State private var clientID = ""
    @State private var error: String?
    private var hasURL: Bool { ["youtube", "vimeo", "rss", "web"].contains(source.kind) }
    private var hasKey: Bool { ["youtube", "vimeo", "pexels", "pixabay", "twitch"].contains(source.kind) }

    var body: some View {
        NavigationStack {
            Form {
                Section("来源说明") { Text(explanation).font(.subheadline) }
                if hasURL {
                    Section(source.kind == "youtube" ? "频道 / 播放列表（可选）" : "订阅或媒体地址") {
                        TextField(source.kind == "youtube" ? "UC… 或 https://…" : "https://…", text: $url, axis: .vertical)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                if hasKey {
                    Section(source.kind == "youtube" ? "关键词搜索（可选）" : "接口凭据") {
                        if source.kind == "twitch" {
                            TextField("Client ID", text: $clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        SecureField(["vimeo", "twitch"].contains(source.kind) ? "Access Token" : "API Key", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("凭据保存在本机钥匙串中。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status = model.mediaStore.sourceStatuses[source.id] {
                    Section("最近状态") { Text(status).font(.subheadline) }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if source.id.hasPrefix("custom-") {
                    Button("删除此内容源", role: .destructive) { model.mediaStore.removeCustomSource(source.id); dismiss() }
                }
            }
            .navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty, !(source.kind == "youtube" && value.hasPrefix("UC")),
                           !["http", "https"].contains(URL(string: value)?.scheme?.lowercased() ?? "") {
                            error = "请输入完整的 HTTP / HTTPS 地址。"; return
                        }
                        model.mediaStore.configureSource(source.id, url: value, key: key, clientID: clientID)
                        dismiss()
                    }
                }
            }
            .onAppear { url = source.url ?? ""; key = model.mediaStore.sourceKey(source.kind); clientID = model.mediaStore.sourceKey("twitch-client") }
        }
    }

    private var explanation: String {
        switch source.kind {
        case "bili": "从哔哩哔哩公开推荐或热榜加载视频。原版未接入需要平台签名的关键词搜索。"
        case "youtube": "推荐使用频道 RSS，无需 API Key。关键词搜索使用 YouTube Data API；填写自己的 API Key 后启用。可指定频道或播放列表。"
        case "vimeo": "可加入 Vimeo 视频链接或 RSS。关键词搜索需要 Vimeo Access Token，与原版公开搜索的限制一致。"
        case "dailymotion": "使用 Dailymotion 公开视频列表、趋势和关键词搜索。"
        case "archive": "搜索 Internet Archive 的 MPEG4 影像，优先提供可直接播放的视频文件。"
        case "nasa": "使用 NASA Image and Video Library 检索视频和封面，无需 API Key。"
        case "peertube": "使用 Sepia Search 聚合 PeerTube 实例，播放使用视频所在实例的官方播放器。"
        case "commons": "搜索维基共享资源的视频文件；非原生格式使用官方媒体页面播放。"
        case "rss": "填写 RSS / Atom 订阅地址。读取公开的视频、音频附件和媒体封面；关键词会在订阅内容中筛选。"
        case "web": "填写网站、公开视频页面或媒体直链。读取页面公开的 video、source、img 和 Open Graph 媒体信息。"
        case "pexels": "使用 Pexels 视频搜索，需要配置自己的 Pexels API Key。"
        case "pixabay": "使用 Pixabay 视频搜索，需要配置自己的 Pixabay API Key。"
        case "twitch": "检索 Twitch 直播频道，需要 Client ID 和 Access Token；播放使用官方频道页面。"
        default: "只查询已启用的内容源。"
        }
    }
}

private struct AddDiscoverySourceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var kind = "rss"
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) { Text("RSS / Atom").tag("rss"); Text("网页 / 媒体地址").tag("web") }
                TextField("名称（可选）", text: $name)
                TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("添加内容源").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("添加") {
                    let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard ["http", "https"].contains(URL(string: value)?.scheme?.lowercased() ?? "") else { error = "请输入完整的订阅或网站地址。"; return }
                    model.mediaStore.addCustomSource(name: name, url: value, kind: kind); dismiss()
                }.disabled(url.isEmpty) }
            }
        }
    }
}

private struct AddDiscoveryLinksView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    var body: some View {
        NavigationStack {
            Form {
                Section("每行一条链接") {
                    TextEditor(text: $text).frame(minHeight: 180).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("支持官方视频页面、图片及视频直链。导入后可在首页和库中查看。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if working { ProgressView("正在解析链接…") }
            }
            .navigationTitle("加入链接").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) { Button("加入") {
                    working = true
                    Task { await model.mediaStore.addRemoteLinks(text); working = false; dismiss() }
                }.disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}
