import SwiftUI

// v1.65: built-in CC0 starter pack, online libraries (Poly Haven textures,
// Openverse images) and the credits page. Imported files land in the normal
// media library, so they can be reused and deleted like any other.

/// Licence and source of library files that came from an open library.
@MainActor final class Glass3DAttributions: ObservableObject {
    static let shared = Glass3DAttributions()
    private static let key = "moonlight.glass3d.attributions"
    @Published private(set) var byMedia: [String: AssetAttribution] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([String: AssetAttribution].self, from: data) { byMedia = saved }
    }
    func record(_ attribution: AssetAttribution, for mediaID: String) {
        byMedia[mediaID] = attribution
        if let data = try? JSONEncoder().encode(byMedia) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
    struct Entry: Identifiable { let id: String; let attribution: AssetAttribution }
    /// Entries whose media is still in the library.
    func current(in store: MediaStore) -> [Entry] {
        let ids = Set(store.items.map(\.id))
        return byMedia.filter { ids.contains($0.key) }.sorted { $0.value.title < $1.value.title }.map { Entry(id: $0.key, attribution: $0.value) }
    }
}

/// The CC0 pack shipped in the app (Resources/Glass3DStarter).
enum Glass3DStarterPack {
    static let folder = "Glass3DStarter"
    static let manifest: StarterManifest? = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: folder)
        .flatMap { try? Data(contentsOf: $0) }.flatMap(StarterManifest.decode)

    static func url(_ asset: StarterAsset) -> URL? {
        let name = asset.file as NSString
        return Bundle.main.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension, subdirectory: folder)
    }
    static func kind(_ asset: StarterAsset) -> RPGMediaKind { asset.kind == "gif" ? .gif : .image }
    static func title(_ asset: StarterAsset) -> String { L10n.t(asset.title, asset.titleEn) }
    static func characterName(_ id: String) -> String {
        switch id {
        case "adventurer": L10n.t("冒险家", "Adventurer"); case "female": L10n.t("少女", "Girl"); case "player": L10n.t("玩家", "Player")
        case "soldier": L10n.t("士兵", "Soldier"); case "zombie": L10n.t("僵尸", "Zombie"); default: id
        }
    }

    /// Copies a starter file into the media library (same file is reused).
    @MainActor static func importAsset(_ asset: StarterAsset, store: MediaStore) async -> MediaEntry? {
        guard let url = url(asset), let entry = await store.importLocalFile(url, title: title(asset), kind: .image) else { return nil }
        Glass3DAttributions.shared.record(asset.attribution, for: entry.id)
        return entry
    }

    /// Imports a starter character's poses and saves a ready character.
    @available(iOS 18.0, *)
    @MainActor static func createCharacter(_ id: String, poses: [String: StarterAsset], controller: Glass3DController, store: MediaStore) async -> CharacterTemplate? {
        var bindings: [MediaBinding] = []
        var byPose: [String: String] = [:]
        for (pose, asset) in poses.sorted(by: { $0.key < $1.key }) {
            guard let entry = await importAsset(asset, store: store) else { continue }
            let binding = MediaBinding(id: "cb:" + UUID().uuidString, mediaID: entry.id, kind: kind(asset), fit: .fit)
            bindings.append(binding); byPose[pose] = binding.id
        }
        guard !byPose.isEmpty else { return nil }
        let template = StarterCharacterRecipe.template(id: "char:" + UUID().uuidString, name: characterName(id), bindings: byPose)
        controller.saveCharacter(template, bindings: bindings)
        return template
    }
}

/// Network access to the online libraries. Requests carry the app's own
/// user agent (Poly Haven API terms 2.4).
enum Glass3DOnlineClient {
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        return "Moonlight-iOS/\(version) (github.com/alicelikeeat/moonIight-ios)"
    }
    static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    @MainActor private static var polyHavenCache: [OnlineAsset]?
    @MainActor static func polyHavenTextures() async throws -> [OnlineAsset] {
        if let cached = polyHavenCache { return cached }
        guard let url = URL(string: "https://api.polyhaven.com/assets?t=textures") else { return [] }
        let data = try await get(url)
        let assets = await Task.detached(priority: .userInitiated) { OnlineAssetParsing.polyHaven(data) }.value
        polyHavenCache = assets
        return assets
    }
    static func openverse(query: String, page: Int, cc0Only: Bool) async throws -> [OnlineAsset] {
        guard let url = OnlineAssetParsing.openverseURL(query: query, page: page, cc0Only: cc0Only) else { return [] }
        let data = try await get(url)
        return OnlineAssetParsing.openverse(data)
    }

    /// Downloads the file and adds it to the media library with its licence.
    @MainActor static func importAsset(_ asset: OnlineAsset, store: MediaStore) async throws -> MediaEntry? {
        var download = asset.download
        if download == nil, let url = URL(string: "https://api.polyhaven.com/files/" + asset.id) {
            download = OnlineAssetParsing.polyHavenDiffuse(try await get(url))
        }
        guard let download else { throw URLError(.fileDoesNotExist) }
        let data = try await get(download)
        let ext = download.pathExtension.isEmpty ? asset.fileExtension : download.pathExtension.lowercased()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let entry = await store.importLocalFile(temp, title: asset.title, kind: .image) else { return nil }
        Glass3DAttributions.shared.record(asset.attribution, for: entry.id)
        return entry
    }
}

// MARK: Online browser

/// Search and import from Poly Haven (CC0 textures) and Openverse (openly
/// licensed images). One tap imports into the media library.
struct Glass3DOnlineAssetsView: View {
    @ObservedObject var store: MediaStore
    let onImported: (MediaEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var source: Source = .polyHaven
    @State private var query = ""
    @State private var cc0Only = false
    @State private var results: [OnlineAsset] = []
    @State private var havenAll: [OnlineAsset] = []
    @State private var page = 1
    @State private var loading = false
    @State private var failure: String?
    @State private var importing: String?
    @State private var imported: Set<String> = []

    enum Source: String, CaseIterable, Identifiable {
        case polyHaven, openverse
        var id: Self { self }
        var title: String { self == .polyHaven ? L10n.t("Poly Haven 贴图", "Poly Haven Textures") : L10n.t("Openverse 图片", "Openverse Images") }
    }

    private var chips: [(String, String)] {
        source == .polyHaven
            ? [(L10n.t("砖墙", "Brick"), "brick"), (L10n.t("木头", "Wood"), "wood"), (L10n.t("岩石", "Rock"), "rock"), (L10n.t("地面", "Floor"), "floor"),
               (L10n.t("金属", "Metal"), "metal"), (L10n.t("布料", "Fabric"), "fabric"), (L10n.t("雪", "Snow"), "snow"), (L10n.t("月面", "Moon"), "moon")]
            : [(L10n.t("月亮", "Moon"), "moon"), (L10n.t("星空", "Stars"), "night sky stars"), (L10n.t("玻璃", "Glass"), "glass"), (L10n.t("森林", "Forest"), "forest"),
               (L10n.t("海洋", "Ocean"), "ocean"), (L10n.t("城市", "City"), "city"), (L10n.t("花", "Flowers"), "flowers"), (L10n.t("图案", "Pattern"), "pattern")]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.t("来源", "Source"), selection: $source) { ForEach(Source.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips.indices, id: \.self) { index in
                                let chip = chips[index]
                                Button(chip.0) { query = chip.1; page = 1; search() }
                                    .buttonStyle(Glass3DChipStyle(tint: query == chip.1 ? .accentColor : .primary, prominent: query == chip.1))
                            }
                        }
                    }
                    if source == .openverse {
                        Toggle(L10n.t("只看 CC0 / 公有领域（无需署名）", "CC0 / public domain only (no credit needed)"), isOn: $cc0Only).font(.subheadline)
                    }
                    if let failure {
                        Label(failure, systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(.orange)
                    }
                    if source == .openverse && query.isEmpty && results.isEmpty && !loading {
                        Text(L10n.t("输入英文关键词搜索，或点上面的分类。", "Type an English keyword or tap a topic above.")).font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12)], spacing: 14) {
                        ForEach(results) { asset in cell(asset) }
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                    else if source == .openverse && !results.isEmpty && results.count % 30 == 0 {
                        Button(L10n.t("加载更多", "Load More")) { page += 1; search(append: true) }
                            .buttonStyle(Glass3DChipStyle(tint: .accentColor)).frame(maxWidth: .infinity)
                    }
                    credit
                }
                .padding(16)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(L10n.t("搜索（英文效果更好）", "Search")))
            .onSubmit(of: .search) { page = 1; search() }
            .onChange(of: query) { value in if source == .polyHaven { results = OnlineAssetParsing.filter(havenAll, query: value) } }
            .onChange(of: source) { _ in page = 1; results = []; failure = nil; search() }
            .onChange(of: cc0Only) { _ in page = 1; search() }
            .moonLiquidPage()
            .navigationTitle(L10n.t("在线素材", "Online Assets")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.t("完成", "Done")) { dismiss() } } }
            .task { search() }
        }
        .accessibilityIdentifier("glass3d-online-assets")
    }

    private func cell(_ asset: OnlineAsset) -> some View {
        let busy = importing == asset.id, done = imported.contains(asset.id)
        return Button { importAsset(asset) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Color.primary.opacity(0.06)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: asset.thumbnail) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else if phase.error != nil { Image(systemName: "photo").foregroundStyle(.tertiary) }
                            else { ProgressView() }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if busy || done {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.35))
                            if busy { ProgressView().tint(.white) } else { Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(.white) }
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(asset.attribution.license).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(asset.attribution.needsCredit ? Color.orange : Color.green, in: Capsule()).padding(5)
                    }
                Text(asset.title).font(.caption2.weight(.semibold)).lineLimit(1).foregroundStyle(.primary)
                Text(asset.attribution.author.isEmpty ? asset.attribution.provider : asset.attribution.author).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.moonJelly)
        .disabled(importing != nil)
        .contextMenu {
            Button { importAsset(asset) } label: { Label(L10n.t("导入到媒体库", "Import"), systemImage: "square.and.arrow.down") }
            if let url = URL(string: asset.attribution.source) {
                Button { openURL(url) } label: { Label(L10n.t("查看原始页面", "Open Source Page"), systemImage: "safari") }
            }
        }
        .accessibilityLabel(asset.title + " · " + asset.attribution.license)
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 4) {
            if source == .polyHaven {
                Text(L10n.t("贴图由 Poly Haven 提供（Powered by Poly Haven），全部为 CC0，可免费商用、无需署名。", "Powered by Poly Haven. All textures are CC0: free for any use, no credit needed."))
            } else {
                Text(L10n.t("图片来自 Openverse 搜索，版权归原作者；只显示允许商用和改编的授权（不含「禁止改编」「非商业」）。绿色标签无需署名，橙色标签需要署名，导入时已自动记录到「素材来源与授权」。", "Images found with Openverse; rights stay with their authors. Only licences that allow commercial use and changes are shown (no ND / NC). Green: no credit needed. Orange: credit needed, recorded under Credits when imported."))
                Text(L10n.t("授权信息由 Openverse 提供，以原始页面为准；照片中的人像、商标不在授权范围内，公开使用前请留意。长按一张图可打开原始页面。", "Licence details come from Openverse; the original page is authoritative. People and trademarks in photos are not covered by the licence. Long press an image to open its page."))
            }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
    }

    private func search(append: Bool = false) {
        failure = nil
        loading = true
        Task {
            do {
                switch source {
                case .polyHaven:
                    if havenAll.isEmpty { havenAll = try await Glass3DOnlineClient.polyHavenTextures() }
                    results = OnlineAssetParsing.filter(havenAll, query: query)
                case .openverse:
                    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !term.isEmpty else { results = []; loading = false; return }
                    let found = try await Glass3DOnlineClient.openverse(query: term, page: page, cc0Only: cc0Only)
                    results = append ? results + found.filter { new in !results.contains { $0.id == new.id } } : found
                }
            } catch {
                failure = L10n.t("连接失败，请检查网络后重试。", "Could not connect. Check the network and try again.")
            }
            loading = false
        }
    }

    private func importAsset(_ asset: OnlineAsset) {
        guard importing == nil else { return }
        importing = asset.id; failure = nil
        Task {
            do {
                if let entry = try await Glass3DOnlineClient.importAsset(asset, store: store) {
                    imported.insert(asset.id)
                    importing = nil
                    onImported(entry)
                    return
                }
                failure = store.notice ?? L10n.t("导入失败", "Import failed")
            } catch {
                failure = L10n.t("下载失败，请稍后再试。", "Download failed. Try again later.")
            }
            importing = nil
        }
    }
}

// MARK: Credits

/// Sources and licences of every library file from an open library.
struct Glass3DCreditsView: View {
    @ObservedObject var store: MediaStore
    @ObservedObject private var attributions = Glass3DAttributions.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        let entries = attributions.current(in: store)
        NavigationStack {
            List { Group {
                Section {
                    row("Kenney · Platformer Characters", detail: L10n.t("内置角色 · CC0 1.0（kenney.nl）", "Built-in characters · CC0 1.0 (kenney.nl)"), url: "https://opengameart.org/content/platformer-characters-1-5-characters")
                    row("Poly Haven", detail: L10n.t("内置贴图与在线贴图 · CC0 1.0 · Powered by Poly Haven", "Built-in and online textures · CC0 1.0 · Powered by Poly Haven"), url: "https://polyhaven.com")
                    row("Openverse", detail: L10n.t("在线图片搜索 · 各图授权见下方", "Online image search · licences below"), url: "https://openverse.org")
                } header: { Text(L10n.t("素材库", "Libraries")) }
                Section {
                    if entries.isEmpty {
                        Text(L10n.t("还没有从素材库导入的文件。", "Nothing imported from a library yet.")).foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.attribution.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Spacer()
                                Text(entry.attribution.license).font(.caption2.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(entry.attribution.needsCredit ? Color.orange : Color.green, in: Capsule())
                            }
                            Text([entry.attribution.author, entry.attribution.provider].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            if let credit = entry.attribution.credit, entry.attribution.needsCredit {
                                Text(credit).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if let url = URL(string: entry.attribution.source) { openURL(url) } }
                    }
                } header: { Text(L10n.t("已导入的素材（\(entries.count)）", "Imported (\(entries.count))")) } footer: {
                    Text(L10n.t("橙色标签的作品需要署名：分享截图或作品时，请附上上面的署名文字。点一项可打开原始页面。", "Orange items need credit: include the credit line when you share. Tap an item to open its page."))
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }.moonLiquidList()
            .navigationTitle(L10n.t("素材来源与授权", "Credits & Licences")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() } } }
        }
    }

    private func row(_ title: String, detail: String, url: String) -> some View {
        Button { if let link = URL(string: url) { openURL(link) } } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
