import Combine
import Foundation
import Security

enum MediaKind: String, Codable, Sendable {
    case image
    case video
    case embed
}

struct MediaEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var kind: MediaKind
    var title: String
    var remoteURL: URL?
    var coverURL: URL?
    var embedURL: URL?
    var author: String
    var platform: String
    var source: String
    var createdAt: Date
    var isFavorite: Bool

    init(
        id: String = UUID().uuidString,
        kind: MediaKind,
        title: String,
        remoteURL: URL? = nil,
        coverURL: URL? = nil,
        embedURL: URL? = nil,
        author: String = "",
        platform: String,
        source: String,
        createdAt: Date = .now,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.remoteURL = remoteURL
        self.coverURL = coverURL
        self.embedURL = embedURL
        self.author = author
        self.platform = platform
        self.source = source
        self.createdAt = createdAt
        self.isFavorite = isFavorite
    }

    var identity: String {
        if platform == "youtube", let url = remoteURL, let id = PlatformResolver.youtubeID(in: url.absoluteString) {
            return "youtube:\(id)"
        }
        if platform == "bili", let id = PlatformResolver.bilibiliID(in: remoteURL?.absoluteString ?? embedURL?.absoluteString ?? "") {
            return "bili:\(id)"
        }
        guard var components = URLComponents(url: remoteURL ?? embedURL ?? URL(fileURLWithPath: id), resolvingAgainstBaseURL: false) else {
            return id
        }
        components.fragment = nil
        components.host = components.host?.lowercased()
        return components.string ?? id
    }
}

struct MediaSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: String
    var enabled: Bool

    static let defaults = [
        MediaSource(id: "bili-popular", name: "哔哩哔哩", kind: "bili", enabled: true),
        MediaSource(id: "youtube-rss", name: "YouTube", kind: "youtube", enabled: true)
    ]
}

enum PlatformResolver {
    static func youtubeID(in text: String) -> String? {
        let patterns = [
            #"(?:youtube(?:-nocookie)?\.com/(?:embed/|shorts/|watch\?v=)|youtu\.be/)([A-Za-z0-9_-]{11})"#,
            #"[?&]v=([A-Za-z0-9_-]{11})"#
        ]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[range])
                if let idRange = match.range(of: #"[A-Za-z0-9_-]{11}"#, options: .regularExpression) {
                    return String(match[idRange])
                }
            }
        }
        return nil
    }

    static func bilibiliID(in text: String) -> String? {
        guard let range = text.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    static func youtubeEmbedURL(videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/embed/\(videoID)?playsinline=1&rel=0")
    }

    static func resolve(_ text: String) -> MediaEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let videoID = youtubeID(in: trimmed) {
            return MediaEntry(
                kind: .embed,
                title: "YouTube \(videoID)",
                remoteURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
                coverURL: URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
                embedURL: youtubeEmbedURL(videoID: videoID),
                author: "YouTube",
                platform: "youtube",
                source: "youtube"
            )
        }
        if let bvid = bilibiliID(in: trimmed) {
            return MediaEntry(
                kind: .embed,
                title: bvid,
                remoteURL: URL(string: "https://www.bilibili.com/video/\(bvid)"),
                coverURL: nil,
                embedURL: URL(string: "https://player.bilibili.com/player.html?bvid=\(bvid)&page=1&high_quality=1&danmaku=0"),
                author: "哔哩哔哩",
                platform: "bili",
                source: "bili"
            )
        }
        return nil
    }
}

enum MediaServiceError: LocalizedError {
    case invalidResponse
    case http(Int, String?)
    case missingYouTubeKey
    case noResults

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务器返回的数据无法识别。"
        case let .http(code, message): message ?? "请求失败（HTTP \(code)）。"
        case .missingYouTubeKey: "YouTube 关键词搜索需要 API Key。可在设置中添加；YouTube 频道推荐无需 Key。"
        case .noResults: "没有找到内容。"
        }
    }
}

enum MediaAPI {
    static let youtubeChannels = [
        "UC_x5XG1OV2P6uZZ5FSM9Ttw",
        "UCEAKeXNzKuCMLACSp1mvY4A",
        "UCKWaEZ-_VkcN4HnlCf2QaLQ",
        "UC6nSFpj9HTCZ5t-N3Rm-3-HA",
        "UCHnyfMqiRRG1u-2MsSQLbXA"
    ]

    static func youtubeRSS(channelID: String, limit: Int = 12) async throws -> [MediaEntry] {
        var components = URLComponents(string: "https://www.youtube.com/feeds/videos.xml")!
        components.queryItems = [URLQueryItem(name: "channel_id", value: channelID)]
        var request = URLRequest(url: components.url!)
        request.setValue("application/atom+xml,application/xml,text/xml,*/*", forHTTPHeaderField: "Accept")
        request.setValue("Moonlight iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        let parser = YouTubeAtomParser(limit: limit)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw xml.parserError ?? MediaServiceError.invalidResponse }
        return parser.entries
    }

    static func youtubeSearch(query: String, apiKey: String, pageToken: String? = nil) async throws -> YouTubeSearchPage {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaServiceError.missingYouTubeKey
        }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: apiKey)
        ]
        if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let items = json?["items"] as? [[String: Any]] else { throw MediaServiceError.invalidResponse }
        let entries = items.compactMap { item -> MediaEntry? in
            guard
                let idObject = item["id"] as? [String: Any],
                let videoID = idObject["videoId"] as? String,
                let snippet = item["snippet"] as? [String: Any]
            else { return nil }
            let thumbnails = snippet["thumbnails"] as? [String: [String: Any]]
            let cover = (thumbnails?["high"]?["url"] as? String) ?? (thumbnails?["medium"]?["url"] as? String)
            return MediaEntry(
                kind: .embed,
                title: snippet["title"] as? String ?? videoID,
                remoteURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
                coverURL: cover.flatMap(URL.init(string:)),
                embedURL: PlatformResolver.youtubeEmbedURL(videoID: videoID),
                author: snippet["channelTitle"] as? String ?? "YouTube",
                platform: "youtube",
                source: "youtube-search"
            )
        }
        let token = json?["nextPageToken"] as? String
        return YouTubeSearchPage(entries: entries, nextPageToken: token)
    }

    static func bilibiliPopular(limit: Int = 20) async throws -> [MediaEntry] {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/popular")!
        components.queryItems = [
            URLQueryItem(name: "ps", value: String(min(max(limit, 1), 50))),
            URLQueryItem(name: "pn", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Moonlight iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let dataObject = json?["data"] as? [String: Any],
              let list = dataObject["list"] as? [[String: Any]] else {
            throw MediaServiceError.invalidResponse
        }
        return list.compactMap { item in
            guard let bvid = item["bvid"] as? String, !bvid.isEmpty else { return nil }
            let owner = item["owner"] as? [String: Any]
            let stats = item["stat"] as? [String: Any]
            let coverText = (item["pic"] as? String)?.replacingOccurrences(of: "http://", with: "https://")
            return MediaEntry(
                kind: .embed,
                title: item["title"] as? String ?? bvid,
                remoteURL: URL(string: "https://www.bilibili.com/video/\(bvid)"),
                coverURL: coverText.flatMap(URL.init(string:)),
                embedURL: URL(string: "https://player.bilibili.com/player.html?bvid=\(bvid)&page=1&high_quality=1&danmaku=0"),
                author: owner?["name"] as? String ?? "哔哩哔哩",
                platform: "bili",
                source: "bili-popular"
            )
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw MediaServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = body?["error"] as? [String: Any]
            throw MediaServiceError.http(http.statusCode, error?["message"] as? String)
        }
    }
}

struct YouTubeSearchPage: Sendable {
    var entries: [MediaEntry]
    var nextPageToken: String?
}

private final class YouTubeAtomParser: NSObject, XMLParserDelegate {
    private let limit: Int
    private var inEntry = false
    private var activeField: String?
    private var fieldText = ""
    private var title = ""
    private var videoID = ""
    private var author = ""
    private var thumbnail: URL?
    private(set) var entries: [MediaEntry] = []

    init(limit: Int) { self.limit = limit }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = qName ?? elementName
        if name == "entry" {
            inEntry = true
            title = ""
            videoID = ""
            author = ""
            thumbnail = nil
        } else if inEntry {
            if name == "title" || name == "yt:videoId" || name == "name" { activeField = name; fieldText = "" }
            if name == "media:thumbnail", let text = attributeDict["url"] { thumbnail = URL(string: text) }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeField != nil { fieldText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        if name == activeField {
            switch name {
            case "title": title = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "yt:videoId": videoID = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
            case "name": if author.isEmpty { author = fieldText.trimmingCharacters(in: .whitespacesAndNewlines) }
            default: break
            }
            activeField = nil
        }
        if name == "entry" {
            inEntry = false
            guard entries.count < limit, !videoID.isEmpty else { return }
            entries.append(MediaEntry(
                kind: .embed,
                title: title.isEmpty ? videoID : title,
                remoteURL: URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
                coverURL: thumbnail ?? URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"),
                embedURL: PlatformResolver.youtubeEmbedURL(videoID: videoID),
                author: author.isEmpty ? "YouTube" : author,
                platform: "youtube",
                source: "youtube-rss"
            ))
        }
    }
}

enum SecureSettings {
    private static let service = "com.moonlight.feed.settings"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}

@MainActor
final class MediaStore: ObservableObject {
    @Published private(set) var items: [MediaEntry] = []
    @Published private(set) var discoverItems: [MediaEntry] = []
    @Published private(set) var searchResults: [MediaEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSearching = false
    @Published var notice: String?
    @Published private(set) var hasMoreYouTubeResults = false
    @Published private(set) var enabledSources: [MediaSource] = MediaSource.defaults
    @Published var youtubeAPIKeyDraft = ""

    private var searchQuery = ""
    private var nextYouTubePageToken: String?
    private var youtubeAPIKey: String
    private let defaults = UserDefaults.standard
    private let itemURL: URL

    init() {
        youtubeAPIKey = SecureSettings.read("youtube_api_key") ?? ""
        youtubeAPIKeyDraft = youtubeAPIKey
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        itemURL = directory.appendingPathComponent("moonlight-media.json")
        if let data = try? Data(contentsOf: itemURL),
           let decoded = try? JSONDecoder().decode([MediaEntry].self, from: data) {
            items = decoded
        }
        if let data = defaults.data(forKey: "moonlight-enabled-sources"),
           let saved = try? JSONDecoder().decode([MediaSource].self, from: data) {
            enabledSources = saved
        }
    }

    var youtubeKeyConfigured: Bool { !youtubeAPIKey.isEmpty }

    func setYouTubeAPIKey(_ key: String) {
        youtubeAPIKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        youtubeAPIKeyDraft = youtubeAPIKey
        if youtubeAPIKey.isEmpty { SecureSettings.delete("youtube_api_key") }
        else { SecureSettings.write(youtubeAPIKey, account: "youtube_api_key") }
    }

    func setSourceEnabled(_ id: String, enabled: Bool) {
        guard let index = enabledSources.firstIndex(where: { $0.id == id }) else { return }
        enabledSources[index].enabled = enabled
        if let data = try? JSONEncoder().encode(enabledSources) {
            defaults.set(data, forKey: "moonlight-enabled-sources")
        }
    }

    func refreshHome() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var incoming: [MediaEntry] = []
        if enabledSources.first(where: { $0.id == "bili-popular" })?.enabled == true,
           let bili = try? await MediaAPI.bilibiliPopular() {
            incoming += bili
        }
        if enabledSources.first(where: { $0.id == "youtube-rss" })?.enabled == true {
            for channel in MediaAPI.youtubeChannels {
                if let videos = try? await MediaAPI.youtubeRSS(channelID: channel, limit: 8) {
                    incoming += videos
                }
            }
        }
        merge(incoming)
        notice = incoming.isEmpty ? "暂时没有取到新内容，请稍后重试。" : "已同步 \(incoming.count) 条来源内容。"
    }

    func refreshDiscover() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var incoming: [MediaEntry] = []
        if enabledSources.first(where: { $0.id == "bili-popular" })?.enabled == true,
           let bili = try? await MediaAPI.bilibiliPopular() {
            incoming += bili
        }
        if enabledSources.first(where: { $0.id == "youtube-rss" })?.enabled == true {
            for channel in MediaAPI.youtubeChannels.prefix(3) {
                if let videos = try? await MediaAPI.youtubeRSS(channelID: channel, limit: 8) {
                    incoming += videos
                }
            }
        }
        discoverItems = unique(incoming.shuffled())
        notice = discoverItems.isEmpty ? "暂时没有取到发现内容。" : nil
    }

    func searchYouTube(_ query: String, nextPage: Bool = false) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { searchResults = []; notice = nil; return }
        if !nextPage { searchQuery = cleaned; nextYouTubePageToken = nil; hasMoreYouTubeResults = false; searchResults = [] }
        guard !isSearching else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await MediaAPI.youtubeSearch(
                query: searchQuery,
                apiKey: youtubeAPIKey,
                pageToken: nextPage ? nextYouTubePageToken : nil
            )
            nextYouTubePageToken = page.nextPageToken
            hasMoreYouTubeResults = page.nextPageToken != nil
            searchResults = unique(searchResults + page.entries)
            notice = page.entries.isEmpty && searchResults.isEmpty ? "YouTube 没有返回结果。" : nil
        } catch {
            notice = error.localizedDescription
        }
    }

    func addRandom(count: Int) async -> Int {
        await refreshHome()
        let known = Set(items.map(\.identity))
        let available = unique(discoverItems.filter { !known.contains($0.identity) }.shuffled())
        let chosen = Array(available.prefix(count))
        guard !chosen.isEmpty else {
            notice = "没有可添加的新条目，请稍后刷新内容源。"
            return 0
        }
        items.insert(contentsOf: chosen, at: 0)
        persist()
        notice = "已随机添加 \(chosen.count) 条。"
        return chosen.count
    }

    func appendToLibrary(_ entries: [MediaEntry]) {
        let known = Set(items.map(\.identity))
        let fresh = unique(entries).filter { !known.contains($0.identity) }
        guard !fresh.isEmpty else { notice = "这些内容已经在库中。"; return }
        items.insert(contentsOf: fresh, at: 0)
        persist()
        notice = "已加入库。"
    }

    func toggleFavorite(_ entry: MediaEntry) {
        guard let index = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[index].isFavorite.toggle()
        persist()
    }

    func delete(_ entry: MediaEntry) {
        items.removeAll { $0.id == entry.id }
        persist()
    }

    private func merge(_ incoming: [MediaEntry]) {
        discoverItems = unique(incoming.shuffled())
    }

    private func unique(_ entries: [MediaEntry]) -> [MediaEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.identity).inserted }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: itemURL, options: .atomic)
    }
}



