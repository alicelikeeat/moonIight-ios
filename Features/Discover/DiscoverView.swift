import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var query: String
    let onSelect: (MediaEntry) -> Void
    let onSources: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var kindFilter = "all"
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
                Button(action: onSources) {
                    Image(systemName: "line.3.horizontal.decrease").font(.headline)
                        .frame(width: 42, height: 42).moonGlassCircle(.discoverSources)
                }.buttonStyle(.moonJelly).accessibilityLabel("内容源").accessibilityIdentifier("discover-sources")
                Button { columns = columns == 1 ? 2 : 1 } label: {
                    Image(systemName: columns == 1 ? "rectangle.grid.2x2" : "rectangle.grid.1x2")
                        .font(.headline).frame(width: 42, height: 42).moonGlassCircle(.discoverLayout)
                }.buttonStyle(.moonJelly).accessibilityLabel("切换单双列").accessibilityIdentifier("discover-layout")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索所选内容源或粘贴链接", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($searchFocused)
                    .accessibilityIdentifier("discover-search-input")
                    .onReceive(NotificationCenter.default.publisher(for: .init("moonlight.focusMediaSearch"))) { note in
                        if let text = note.userInfo?["query"] as? String {
                            query = text
                            kindFilter = note.userInfo?["kind"] as? String ?? "all"
                            if !text.isEmpty { Task { await model.mediaStore.searchDiscover(text) } }
                        }
                        searchFocused = true
                    }
                    .onSubmit { Task { await model.mediaStore.searchDiscover(query) } }
                if !query.isEmpty {
                    Button { query = ""; model.mediaStore.clearDiscoverySearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 44, height: 44) }.accessibilityLabel("清除媒体搜索").accessibilityIdentifier("discover-search-clear")
                }
            }
            .padding(.horizontal, 15).frame(height: 50)
            .moonSingleGlass(radius: 17)
            Picker("媒体类型", selection: $kindFilter) {
                Text("全部").tag("all"); Text("视频").tag("video"); Text("图片").tag("image")
            }.pickerStyle(.segmented).accessibilityIdentifier("discover-kind-filter")
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
                Button {
                    Task {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await model.mediaStore.refreshDiscover() }
                        else { await model.mediaStore.searchDiscover(query) }
                    }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass").font(.subheadline.weight(.medium))
                }.buttonStyle(MoonGlassButtonStyle()).foregroundStyle(MoonStyle.accent)
            }
            let results = (query.isEmpty ? model.mediaStore.discoverItems : model.mediaStore.searchResults).filter { kindFilter == "all" || (kindFilter == "video" ? $0.kind != .image : $0.kind.rawValue == kindFilter) }
            if results.isEmpty {
                EmptyPanel(title: query.isEmpty ? "还没有推荐内容" : "没有搜索结果", detail: model.mediaStore.notice ?? "打开内容源选择分类并查看加载状态。", symbol: "safari")
                Button(action: onSources) { Label("查看内容源", systemImage: "slider.horizontal.3") }.buttonStyle(MoonGlassButtonStyle())
            } else {
                LazyVGrid(columns: columns == 1 ? [GridItem(.flexible())] : grid, spacing: 14) {
                    ForEach(results) { entry in
                        MediaEntryCard(entry: entry, height: CGFloat(columns == 1 ? 220 : 155) * bannerScale, onSelect: { onSelect(entry) })
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if !query.isEmpty && model.mediaStore.hasMoreYouTubeResults {
                Button("换一批") { Task { await model.mediaStore.searchDiscover(query, nextPage: true) } }.buttonStyle(MoonGlassButtonStyle())
            }
            if !query.isEmpty, !model.mediaStore.youtubeKeyConfigured,
               model.mediaStore.enabledSources.contains(where: { $0.kind == "youtube" && $0.enabled }) {
                YouTubeSearchFallback(query: query)
            }
            if model.mediaStore.isSearching || model.mediaStore.isRefreshing { ProgressView().frame(maxWidth: .infinity) }
            if let notice = model.mediaStore.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
        .onChange(of: query) { value in if value.isEmpty { model.mediaStore.clearDiscoverySearch() } }
    }
}

struct DiscoverTile: View {
    let gradient: [Color]
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).moonLiquidSurface(.circle).padding(12)
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
