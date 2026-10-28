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

struct LibraryFolder: Codable, Identifiable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var createdAt: Date = .now
}

struct PlaybackProgress: Codable, Hashable, Sendable {
    var position: Double
    var duration: Double
    var updatedAt: Date = .now

    var isFinished: Bool {
        duration > 0 && position >= max(0, duration - 8)
    }
}

/// 自动片单不保存条目副本；每次打开都会从当前库和观看进度重算，避免
/// 收藏、下载、删除或移动文件夹后出现过期内容。
enum SmartPlaylistKind: String, CaseIterable, Identifiable, Sendable {
    case continueWatching, unwatched, favorites, downloads, recentlyAdded, videos

    var id: String { rawValue }
    var title: String {
        switch self {
        case .continueWatching: "继续观看"
        case .unwatched: "还没看过"
        case .favorites: "我的收藏"
        case .downloads: "离线可看"
        case .recentlyAdded: "最近加入"
        case .videos: "只看视频"
        }
    }
    var symbol: String {
        switch self {
        case .continueWatching: "play.circle.fill"
        case .unwatched: "eye.slash.fill"
        case .favorites: "heart.fill"
        case .downloads: "arrow.down.circle.fill"
        case .recentlyAdded: "clock.fill"
        case .videos: "video.fill"
        }
    }
    var detail: String {
        switch self {
        case .continueWatching: "从上次停下的地方继续"
        case .unwatched: "把还未打开的内容放在一起"
        case .favorites: "只播放你标记喜欢的内容"
        case .downloads: "无需重新寻找的离线内容"
        case .recentlyAdded: "按加入时间倒序更新"
        case .videos: "过滤图片，只连续播放视频"
        }
    }
}

private struct LibraryOrganization: Codable {
    var folders: [LibraryFolder]
    var assignments: [String: String]
    var playback: [String: PlaybackProgress] = [:]
    var queueIDs: [String] = []
}

struct MediaSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kind: String
    var enabled: Bool
    var url: String? = nil

    static let defaults = [
        MediaSource(id: "bili-popular", name: "哔哩哔哩", kind: "bili", enabled: true),
        MediaSource(id: "bili-ranking", name: "哔哩热榜", kind: "bili", enabled: false),
        MediaSource(id: "youtube-rss", name: "YouTube", kind: "youtube", enabled: true),
        MediaSource(id: "vimeo", name: "Vimeo", kind: "vimeo", enabled: false),
        MediaSource(id: "dailymotion", name: "Dailymotion", kind: "dailymotion", enabled: false),
        MediaSource(id: "archive", name: "Archive.org", kind: "archive", enabled: false),
        MediaSource(id: "nasa", name: "NASA", kind: "nasa", enabled: false),
        MediaSource(id: "peertube", name: "PeerTube", kind: "peertube", enabled: false),
        MediaSource(id: "commons", name: "维基共享资源", kind: "commons", enabled: false),
        MediaSource(id: "rss", name: "播客 / RSS", kind: "rss", enabled: false),
        MediaSource(id: "web", name: "网页视频", kind: "web", enabled: false),
        MediaSource(id: "pexels", name: "Pexels", kind: "pexels", enabled: false),
        MediaSource(id: "pixabay", name: "Pixabay", kind: "pixabay", enabled: false),
        MediaSource(id: "twitch", name: "Twitch", kind: "twitch", enabled: false)
    ]

    var symbol: String {
        switch kind {
        case "bili": id == "bili-ranking" ? "flame.fill" : "play.rectangle.fill"
        case "youtube", "dailymotion": "play.rectangle.fill"
        case "vimeo": "play.circle.fill"
        case "archive": "building.columns.fill"
        case "nasa": "sparkles"
        case "peertube": "person.3.fill"
        case "commons", "pexels", "pixabay": "photo.on.rectangle.angled"
        case "rss": "dot.radiowaves.left.and.right"
        case "twitch": "tv.fill"
        default: "globe"
        }
    }
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
        URL(string: "https://www.youtube.com/embed/\(videoID)?playsinline=1&rel=0&enablejsapi=1")
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

    static func generateVirtualFriendText(title: String, author: String, provider: VirtualAIProvider, apiKey: String) async -> (caption: String, comment: String)? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let endpoint = provider == .openAI ? "https://api.openai.com/v1/responses" : "https://api.x.ai/v1/responses"
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = provider == .openAI ? "gpt-4.1-mini" : "grok-4"
        let prompt = "为本地虚拟好友写一条自然、简短的中文朋友圈动态和一条评论。只根据标题和作者，不要编造视频事实或假装真人。返回纯 JSON：{\"caption\":\"...\",\"comment\":\"...\"}。标题：\(title.prefix(160))；作者：\(author.prefix(80))。"
        let body: [String: Any] = ["model": model, "input": prompt, "max_output_tokens": 160]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = bodyData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let output = root["output"] as? [[String: Any]] else { return nil }
            let raw = output.compactMap { $0["content"] as? [[String: Any]] }
                .flatMap { $0 }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            guard let jsonStart = raw.firstIndex(of: "{"), let jsonEnd = raw.lastIndex(of: "}"), jsonStart <= jsonEnd,
                  let parsed = try? JSONSerialization.jsonObject(with: Data(raw[jsonStart...jsonEnd].utf8)) as? [String: String],
                  let caption = parsed["caption"], let comment = parsed["comment"] else { return nil }
            return (String(caption.prefix(120)), String(comment.prefix(100)))
        } catch { return nil }
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
    @Published private(set) var folders: [LibraryFolder] = []
    @Published private(set) var folderAssignments: [String: String] = [:]
    @Published private(set) var playback: [String: PlaybackProgress] = [:]
    @Published private(set) var queueIDs: [String] = []
    @Published private(set) var discoverItems: [MediaEntry] = []
    @Published private(set) var searchResults: [MediaEntry] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSearching = false
    @Published private(set) var downloadingIDs = Set<String>()
    @Published var notice: String?
    @Published private(set) var hasMoreYouTubeResults = false
    @Published private(set) var enabledSources: [MediaSource] = MediaSource.defaults
    @Published var youtubeAPIKeyDraft = ""
    @Published private(set) var sourceStatuses: [String: String] = [:]
    @Published private(set) var failedSourceIDs = Set<String>()

    private var searchQuery = ""
    private var nextYouTubePageToken: String?
    private var sourceRefreshTask: Task<Void, Never>?
    private var discoverRequestID = UUID()
    private var searchRequestID = UUID()
    private var searchPool: [MediaEntry] = []
    private var shownSearchIDs = Set<String>()
    private var searchPage = 1
    private var searchTokens: [String: String] = [:]
    private var searchExhaustedIDs = Set<String>()
    private var youtubeAPIKey: String
    private let defaults = UserDefaults.standard
    private let itemURL: URL
    private let organizationURL: URL

    init() {
        youtubeAPIKey = SecureSettings.read("youtube_api_key") ?? ""
        youtubeAPIKeyDraft = youtubeAPIKey
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        itemURL = directory.appendingPathComponent("moonlight-media.json")
        organizationURL = directory.appendingPathComponent("moonlight-library-folders.json")
        if let data = try? Data(contentsOf: itemURL),
           let decoded = try? JSONDecoder().decode([MediaEntry].self, from: data) {
            items = decoded
        }
        if let data = defaults.data(forKey: "moonlight-discover-cache"),
           let decoded = try? JSONDecoder().decode([MediaEntry].self, from: data) {
            discoverItems = decoded
        }
        if let data = defaults.data(forKey: "moonlight-enabled-sources"),
           let saved = try? JSONDecoder().decode([MediaSource].self, from: data) {
            enabledSources = MediaSource.defaults.map { fallback in saved.first(where: { $0.id == fallback.id }) ?? fallback }
            enabledSources += saved.filter { savedSource in !MediaSource.defaults.contains(where: { $0.id == savedSource.id }) }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests") {
            let fixtures = (0..<24).map { index in
                MediaEntry(id: "scroll-fixture-\(index)", kind: .image,
                           title: "Scroll fixture \(index)", author: "Gesture verification",
                           platform: "test", source: "ui-test")
            }
            items = fixtures
            items[0].isFavorite = true
            items[1].source = "download"
            discoverItems = fixtures
        }
        #endif
        if let data = try? Data(contentsOf: organizationURL),
           let saved = try? JSONDecoder().decode(LibraryOrganization.self, from: data) {
            folders = saved.folders
            let knownFolders = Set(saved.folders.map(\.id))
            let knownItems = Set(items.map(\.id))
            folderAssignments = saved.assignments.filter { knownItems.contains($0.key) && knownFolders.contains($0.value) }
            playback = saved.playback.filter { knownItems.contains($0.key) }
            queueIDs = saved.queueIDs.filter { knownItems.contains($0) }
        }
    }

    var youtubeKeyConfigured: Bool { !youtubeAPIKey.isEmpty }

    #if DEBUG
    func insertAsyncUITestEntry() {
        discoverItems.insert(MediaEntry(id: "async-source-item", kind: .image, title: "异步到达的新内容", author: "UI verification", platform: "test", source: "ui-test"), at: 0)
    }
    func prepareReelsUITest(videoURL: URL, imageURL: URL) {
        guard items.count >= 2 else { return }
        items[0].kind = .video; items[0].remoteURL = videoURL
        items[1].kind = .image; items[1].remoteURL = imageURL
    }
    #endif

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
        discoverItems = discoverItems.filter(isFromEnabledSource)
        searchResults = searchResults.filter(isFromEnabledSource)
        scheduleSourceReload()
    }

    func sourceKey(_ kind: String) -> String {
        if kind == "youtube" { return youtubeAPIKey }
        return SecureSettings.read("discovery-\(kind)-key") ?? ""
    }

    func configureSource(_ id: String, url: String, key: String, clientID: String = "") {
        guard let index = enabledSources.firstIndex(where: { $0.id == id }) else { return }
        let kind = enabledSources[index].kind
        enabledSources[index].url = url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : url.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == "youtube" { setYouTubeAPIKey(key) }
        else if key.isEmpty { SecureSettings.delete("discovery-\(kind)-key") }
        else { SecureSettings.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: "discovery-\(kind)-key") }
        if kind == "twitch" { SecureSettings.write(clientID.trimmingCharacters(in: .whitespacesAndNewlines), account: "discovery-twitch-client-key") }
        if let data = try? JSONEncoder().encode(enabledSources) { defaults.set(data, forKey: "moonlight-enabled-sources") }
        scheduleSourceReload()
    }

    func addCustomSource(name: String, url: String, kind: String) {
        let cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = URL(string: cleaned), ["https", "http"].contains(address.scheme?.lowercased() ?? "") else {
            notice = "请输入完整的 HTTP / HTTPS 地址。"; return
        }
        if enabledSources.contains(where: { $0.url == cleaned }) { notice = "这个内容源已经存在。"; return }
        enabledSources.append(MediaSource(id: "custom-\(UUID().uuidString)", name: name.isEmpty ? address.host ?? "自定义内容源" : name, kind: kind, enabled: true, url: cleaned))
        if let data = try? JSONEncoder().encode(enabledSources) { defaults.set(data, forKey: "moonlight-enabled-sources") }
        scheduleSourceReload()
    }

    func removeCustomSource(_ id: String) {
        guard id.hasPrefix("custom-") else { return }
        enabledSources.removeAll { $0.id == id }
        discoverItems.removeAll { $0.source == id }
        if let data = try? JSONEncoder().encode(enabledSources) { defaults.set(data, forKey: "moonlight-enabled-sources") }
        scheduleSourceReload()
    }

    private func scheduleSourceReload() {
        sourceRefreshTask?.cancel()
        sourceRefreshTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            if searchQuery.isEmpty { await refreshDiscover() }
            else { await searchDiscover(searchQuery) }
        }
    }

    private func discoveryKeys() -> [String: String] {
        Dictionary(uniqueKeysWithValues: ["youtube", "vimeo", "pexels", "pixabay", "twitch", "twitch-client"].map { ($0, sourceKey($0)) })
    }

    private func isFromEnabledSource(_ entry: MediaEntry) -> Bool {
        if entry.source.hasPrefix("custom-") { return enabledSources.contains { $0.enabled && $0.id == entry.source } }
        if enabledSources.contains(where: { $0.id == entry.source }) {
            return enabledSources.contains { $0.enabled && $0.id == entry.source }
        }
        return enabledSources.contains { $0.enabled && $0.kind == entry.platform }
    }

    func refreshHome() async {
        await refreshDiscover()
    }

    func refreshDiscover() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests") { return }
        #endif
        let requestID = UUID()
        discoverRequestID = requestID
        isRefreshing = true
        defer { if discoverRequestID == requestID { isRefreshing = false } }
        let sources = enabledSources.filter(\.enabled)
        sources.forEach { sourceStatuses[$0.id] = "正在加载…" }
        guard !sources.isEmpty else { discoverItems = []; notice = "在内容源中至少启用一个来源。"; return }
        let results = await DiscoveryAPI.load(sources: sources, query: nil, page: 1, keys: discoveryKeys())
        guard discoverRequestID == requestID, !Task.isCancelled else { return }
        applySourceStatuses(results)
        let failed = Set(results.filter { $0.error != nil }.map(\.sourceID))
        let cached = discoverItems.filter { failed.contains($0.source) && isFromEnabledSource($0) }
        let incoming = results.flatMap(\.entries).filter(isFromEnabledSource)
        if !incoming.isEmpty || !cached.isEmpty {
            discoverItems = spread(unique(incoming + cached).shuffled())
        } else if failed.count == sources.count {
            discoverItems = discoverItems.filter(isFromEnabledSource)
        } else { discoverItems = [] }
        if let data = try? JSONEncoder().encode(discoverItems) { defaults.set(data, forKey: "moonlight-discover-cache") }
        notice = failed.isEmpty ? "已加载 \(discoverItems.count) 条内容。" : "\(sources.count - failed.count)/\(sources.count) 个来源已加载；详情见内容源。"
    }

    func searchYouTube(_ query: String, nextPage: Bool = false) async {
        await searchDiscover(query, nextPage: nextPage)
    }

    func searchDiscover(_ query: String, nextPage: Bool = false) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { clearDiscoverySearch(); return }
        let requestID = UUID()
        searchRequestID = requestID
        if !nextPage || searchQuery != cleaned {
            searchQuery = cleaned; searchPage = 1; searchPool = []; shownSearchIDs = []
            searchTokens = [:]; searchExhaustedIDs = []; searchResults = []
        }
        if nextPage, searchPool.filter({ !shownSearchIDs.contains($0.identity) }).count >= 10 {
            isSearching = false; showSearchBatch(); return
        }
        isSearching = true
        defer { if searchRequestID == requestID { isSearching = false } }
        if let url = URL(string: cleaned), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            do { searchResults = [try await DiscoveryAPI.resolve(url)]; notice = "点击预览；长按可加入库。" }
            catch { notice = error.localizedDescription }
            hasMoreYouTubeResults = false
            return
        }
        if nextPage { searchPage += 1 }
        let sources = enabledSources.filter { $0.enabled && !searchExhaustedIDs.contains($0.id) }
        sources.forEach { sourceStatuses[$0.id] = "正在搜索…" }
        let results = await DiscoveryAPI.load(sources: sources, query: cleaned, page: searchPage, keys: discoveryKeys(), tokens: searchTokens)
        guard searchRequestID == requestID, !Task.isCancelled else { return }
        applySourceStatuses(results)
        let knownSearchIDs = Set(searchPool.map(\.identity))
        for result in results {
            searchTokens[result.sourceID] = result.nextPageToken
            if result.entries.isEmpty || result.error != nil || result.entries.allSatisfy({ knownSearchIDs.contains($0.identity) }) || (result.sourceID == "youtube-rss" && result.nextPageToken == nil) {
                searchExhaustedIDs.insert(result.sourceID)
            }
        }
        searchPool = unique(searchPool + results.flatMap(\.entries)).filter(isFromEnabledSource)
        showSearchBatch()
        notice = searchPool.isEmpty ? "所选来源没有返回结果，打开内容源查看具体原因。" : "已汇集 \(searchPool.count) 条，当前显示 \(searchResults.count) 条。"
    }

    func clearDiscoverySearch() {
        searchRequestID = UUID()
        searchQuery = ""; searchResults = []; searchPool = []; shownSearchIDs = []
        hasMoreYouTubeResults = false; isSearching = false
    }

    private func applySourceStatuses(_ results: [DiscoverySourceResult]) {
        for result in results {
            sourceStatuses[result.sourceID] = result.error ?? "\(result.entries.count) 条内容"
            if result.error != nil { failedSourceIDs.insert(result.sourceID) }
            else { failedSourceIDs.remove(result.sourceID) }
        }
    }

    private func showSearchBatch() {
        var unseen = searchPool.filter { !shownSearchIDs.contains($0.identity) }.shuffled()
        if unseen.isEmpty, !searchPool.isEmpty {
            let current = Set(searchResults.map(\.identity))
            shownSearchIDs = []
            unseen = searchPool.filter { !current.contains($0.identity) }.shuffled()
            if unseen.isEmpty { unseen = searchPool.shuffled() }
        }
        searchResults = spread(Array(unseen.prefix(10)))
        shownSearchIDs.formUnion(searchResults.map(\.identity))
        hasMoreYouTubeResults = !searchPool.isEmpty
    }

    private func spread(_ entries: [MediaEntry]) -> [MediaEntry] {
        var groups = Dictionary(grouping: entries, by: \.platform)
        var result: [MediaEntry] = []
        while groups.values.contains(where: { !$0.isEmpty }) {
            for key in groups.keys.sorted() {
                if var values = groups[key], !values.isEmpty {
                    result.append(values.removeFirst()); groups[key] = values
                }
            }
        }
        return result
    }

    func addRemoteLinks(_ raw: String) async {
        var entries: [MediaEntry] = []
        var failures = 0
        for line in raw.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }).prefix(30) {
            guard let url = URL(string: line), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { failures += 1; continue }
            do { entries.append(try await DiscoveryAPI.resolve(url)) }
            catch { failures += 1 }
        }
        appendToLibrary(entries)
        notice = "已处理 \(entries.count) 条链接" + (failures > 0 ? "，\(failures) 条未能解析。" : "。")
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

    func folderID(for entry: MediaEntry) -> String? { folderAssignments[entry.id] }

    var queueItems: [MediaEntry] {
        queueIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }

    func progress(for entry: MediaEntry) -> PlaybackProgress? { playback[entry.id] }

    func resumePosition(for entry: MediaEntry) -> Double {
        guard let progress = playback[entry.id], !progress.isFinished else { return 0 }
        return max(0, progress.position)
    }

    func recordPlayback(_ entry: MediaEntry, position: Double, duration: Double = 0) {
        guard position.isFinite, position >= 0 else { return }
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : playback[entry.id]?.duration ?? 0
        playback[entry.id] = PlaybackProgress(position: position, duration: normalizedDuration)
        persistFolders()
    }

    func markOpened(_ entry: MediaEntry) {
        if entry.kind != .video { recordPlayback(entry, position: 1, duration: 1) }
    }

    func enqueue(_ entries: [MediaEntry], replacing: Bool = false) {
        let available = Set(items.map(\.id))
        let incoming = entries.map(\.id).filter { available.contains($0) }
        queueIDs = replacing ? incoming : queueIDs + incoming.filter { !queueIDs.contains($0) }
        persistFolders()
        notice = queueIDs.isEmpty ? "播放队列为空。" : "已加入播放队列，共 \(queueIDs.count) 项。"
    }

    func removeFromQueue(_ entry: MediaEntry) {
        queueIDs.removeAll { $0 == entry.id }
        persistFolders()
    }

    func clearQueue() {
        queueIDs.removeAll()
        persistFolders()
    }

    func nextQueued(after entry: MediaEntry) -> MediaEntry? {
        guard let current = queueIDs.firstIndex(of: entry.id) else { return queueItems.first }
        let following = queueIDs.dropFirst(current + 1)
        return following.compactMap { id in items.first(where: { $0.id == id }) }.first
    }

    var continueWatching: [MediaEntry] {
        items.filter { entry in
            guard let progress = playback[entry.id] else { return false }
            return progress.position > 3 && !progress.isFinished
        }.sorted { (playback[$0.id]?.updatedAt ?? .distantPast) > (playback[$1.id]?.updatedAt ?? .distantPast) }
    }

    var unwatchedItems: [MediaEntry] {
        items.filter { entry in
            guard let progress = playback[entry.id] else { return true }
            return !progress.isFinished && progress.position == 0
        }
    }

    func items(for playlist: SmartPlaylistKind) -> [MediaEntry] {
        switch playlist {
        case .continueWatching: continueWatching
        case .unwatched: unwatchedItems
        case .favorites: items.filter(\.isFavorite)
        case .downloads: items.filter { $0.source == "download" }
        case .recentlyAdded: items.sorted { $0.createdAt > $1.createdAt }
        case .videos: items.filter { $0.kind == .video }
        }
    }

    func items(in folder: LibraryFolder) -> [MediaEntry] {
        items.filter { folderAssignments[$0.id] == folder.id }
    }

    @discardableResult
    func createFolder(named name: String) -> LibraryFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { notice = "请输入文件夹名称。"; return nil }
        guard !folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            notice = "同名文件夹已存在。"; return nil
        }
        let folder = LibraryFolder(name: trimmed)
        folders.append(folder)
        persistFolders()
        return folder
    }

    func renameFolder(_ folder: LibraryFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        guard !folders.contains(where: { $0.id != folder.id && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            notice = "同名文件夹已存在。"; return
        }
        folders[index].name = trimmed
        persistFolders()
    }

    func deleteFolder(_ folder: LibraryFolder) {
        folders.removeAll { $0.id == folder.id }
        folderAssignments = folderAssignments.filter { $0.value != folder.id }
        persistFolders()
    }

    func moveItems(_ ids: Set<String>, to folder: LibraryFolder?) {
        guard folder == nil || folders.contains(where: { $0.id == folder?.id }) else { return }
        let known = Set(items.map(\.id))
        var assignments = folderAssignments
        for id in ids where known.contains(id) { assignments[id] = folder?.id }
        // Assign the dictionary once so SwiftUI receives one reliable published
        // update after imports and the folder card refreshes its item count.
        folderAssignments = assignments
        persistFolders()
        notice = folder.map { "已移入“\($0.name)”。" } ?? "已移出文件夹。"
    }

    func importImage(_ data: Data, title: String) {
        importMedia(data, title: title, kind: .image, fileExtension: "jpg")
    }

    @discardableResult
    func importMedia(_ data: Data, title: String, kind: MediaKind, fileExtension: String) -> MediaEntry? {
        let directory = itemURL.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeExtension = fileExtension.isEmpty ? (kind == .video ? "mov" : "jpg") : fileExtension
            let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(safeExtension)
            try data.write(to: fileURL, options: .atomic)
            let entry = MediaEntry(kind: kind, title: title, remoteURL: fileURL, platform: "local", source: "local-import")
            items.insert(entry, at: 0)
            persist()
            notice = "已保存到库。"
            return entry
        } catch {
            notice = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    func importVideoFile(_ sourceURL: URL, title: String) {
        let directory = itemURL.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            let entry = MediaEntry(kind: .video, title: title, remoteURL: destination, platform: "local", source: "camera")
            items.insert(entry, at: 0)
            persist()
            notice = "视频已保存到库。"
        } catch { notice = "视频保存失败：\(error.localizedDescription)" }
    }

    func downloadDirectFile(_ entry: MediaEntry) async {
        guard entry.kind != .embed,
              let remoteURL = entry.remoteURL,
              ["https", "http"].contains(remoteURL.scheme?.lowercased() ?? ""),
              !downloadingIDs.contains(entry.id) else {
            notice = "仅支持下载提供文件直链的图片或视频。"
            return
        }
        downloadingIDs.insert(entry.id)
        defer { downloadingIDs.remove(entry.id) }
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                notice = "下载失败：服务器未返回媒体文件。"
                return
            }
            let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let ext = remoteURL.pathExtension.lowercased()
            let imageExtensions = ["jpg", "jpeg", "png", "webp", "gif", "heic"]
            let videoExtensions = ["mp4", "mov", "m4v", "webm", "avi"]
            let isImage = mime.hasPrefix("image/") || (mime == "application/octet-stream" && imageExtensions.contains(ext))
            let isVideo = mime.hasPrefix("video/") || (mime == "application/octet-stream" && videoExtensions.contains(ext))
            guard isImage || isVideo else {
                notice = "此链接没有返回可下载的图片或视频文件。"
                return
            }
            let kind: MediaKind = isImage ? .image : .video
            let directory = itemURL.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeExt = ext.isEmpty ? (kind == .image ? "jpg" : "mp4") : ext
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(safeExt)
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            let downloaded = MediaEntry(kind: kind, title: entry.title, remoteURL: destination, coverURL: entry.coverURL, author: entry.author, platform: entry.platform, source: "download")
            items.insert(downloaded, at: 0)
            persist()
            notice = "已下载到库。"
        } catch { notice = "下载失败：\(error.localizedDescription)" }
    }

    func toggleFavorite(_ entry: MediaEntry) {
        if let index = items.firstIndex(where: { $0.identity == entry.identity }) {
            items[index].isFavorite.toggle()
        } else {
            var saved = entry
            saved.isFavorite = true
            items.insert(saved, at: 0)
        }
        persist()
    }

    func delete(_ entry: MediaEntry) {
        let deleted = items.filter { $0.id == entry.id }
        items.removeAll { $0.id == entry.id }
        folderAssignments.removeValue(forKey: entry.id)
        playback.removeValue(forKey: entry.id)
        queueIDs.removeAll { $0 == entry.id }
        let mediaDirectory = itemURL.deletingLastPathComponent().appendingPathComponent("media", isDirectory: true).standardizedFileURL
        let prefix = mediaDirectory.path + "/"
        for item in deleted {
            guard let url = item.remoteURL, url.isFileURL else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        persist()
        persistFolders()
    }

    private func merge(_ incoming: [MediaEntry]) {
        guard !incoming.isEmpty else { return }
        discoverItems = unique(incoming.shuffled())
        if let data = try? JSONEncoder().encode(discoverItems) {
            defaults.set(data, forKey: "moonlight-discover-cache")
        }
    }

    private func unique(_ entries: [MediaEntry]) -> [MediaEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.identity).inserted }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: itemURL, options: .atomic)
    }

    private func persistFolders() {
        guard let data = try? JSONEncoder().encode(LibraryOrganization(folders: folders, assignments: folderAssignments, playback: playback, queueIDs: queueIDs)) else { return }
        try? data.write(to: organizationURL, options: .atomic)
    }
}




