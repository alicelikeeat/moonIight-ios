import Foundation
import UIKit

/// A subscription the user added. Refresh uses only public RSS or a public REST API.
struct FollowedSource: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var platform: String
    var title: String
    /// channel, playlist, rss, account, trending, local
    var kind: String
    var ref: String
    var instance: String = ""
}

enum PublicLink {
    enum Hit: Equatable {
        case youtubeVideo(String)
        case youtubeChannel(String)
        case youtubePlaylist(String)
        case youtubeFeed(String)
        case biliBV(String)
        case biliAid(String)
        case biliSpace(String)
        case peertube(host: String, id: String)
        case rss(String)
    }

    static func parse(_ raw: String) -> Hit? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.contains("youtube.com/feeds/") || lower.contains("feeds/videos.xml") {
            return .youtubeFeed(text)
        }
        if let id = youtubeVideoID(text) { return .youtubeVideo(id) }
        if let id = youtubeChannelID(text) { return .youtubeChannel(id) }
        if let id = youtubePlaylistID(text) { return .youtubePlaylist(id) }
        if let bvid = firstMatch(text, #"BV[0-9A-Za-z]{10}"#) { return .biliBV(bvid) }
        if let aid = biliAid(text) { return .biliAid(aid) }
        if let mid = biliMid(text) { return .biliSpace(mid) }
        if let video = peertubeVideo(text) { return .peertube(host: video.host, id: video.id) }
        if lower.hasPrefix("http"), lower.contains("/feed") || lower.hasSuffix(".xml") || lower.contains("rss") {
            return .rss(text)
        }
        return nil
    }

    static func media(_ raw: String) -> MediaEntry? {
        switch parse(raw) {
        case .youtubeVideo(let id):
            return MediaEntry(
                id: "yt-\(id)", kind: .embed, title: "YouTube",
                remoteURL: "https://www.youtube.com/watch?v=\(id)",
                platform: PlatformID.youtube, embedURL: EmbedLinks.youtube(id, mute: true),
                author: "YouTube", source: "youtube"
            )
        case .biliBV(let bvid):
            return MediaEntry(
                id: "bv-\(bvid)", kind: .embed, title: bvid,
                remoteURL: "https://www.bilibili.com/video/\(bvid)", biliBvid: bvid,
                platform: PlatformID.bili, embedURL: BiliLinks.player(bvid: bvid),
                author: "哔哩哔哩", source: "bili"
            )
        case .biliAid(let aid):
            return MediaEntry(
                id: "av-\(aid)", kind: .embed, title: "av\(aid)",
                remoteURL: "https://www.bilibili.com/video/av\(aid)",
                platform: PlatformID.bili, embedURL: BiliLinks.player(aid: aid),
                author: "哔哩哔哩", source: "bili"
            )
        case .peertube:
            // A watch page is HTML. Native playback waits for /api/v1/videos/{id}.
            return nil
        default:
            return nil
        }
    }

    /// Subscription, not a single video. Space pages need a user-supplied RSS.
    static func follow(from raw: String, instance: String) -> (FollowedSource?, String?) {
        switch parse(raw) {
        case .youtubeChannel(let id):
            return (FollowedSource(platform: PlatformID.youtube, title: "YouTube 频道", kind: "channel", ref: id), nil)
        case .youtubePlaylist(let id):
            return (FollowedSource(platform: PlatformID.youtube, title: "YouTube 播放列表", kind: "playlist", ref: id), nil)
        case .youtubeFeed(let url):
            return (FollowedSource(platform: PlatformID.youtube, title: "YouTube RSS", kind: "rss", ref: url), nil)
        case .biliSpace:
            return (nil, "UP 主页不能直接拉列表。请贴一条公开 RSS。")
        case .rss(let url):
            let platform = url.lowercased().contains("bilibili") ? PlatformID.bili : PlatformID.web
            return (FollowedSource(platform: platform, title: "RSS", kind: "rss", ref: url), nil)
        case .peertube(let host, let id):
            return (FollowedSource(platform: PlatformID.peertube, title: id, kind: "video", ref: id, instance: host), nil)
        default:
            if let channel = peertubeChannel(raw) {
                return (FollowedSource(platform: PlatformID.peertube, title: channel.name, kind: channel.account ? "account" : "channel", ref: channel.name, instance: channel.host), nil)
            }
            if let host = normalizedHost(instance), raw.trimmingCharacters(in: .whitespacesAndNewlines) == "热门" {
                return (FollowedSource(platform: PlatformID.peertube, title: "PeerTube 热门", kind: "trending", ref: "trending", instance: host), nil)
            }
            return (nil, "这不是可以订阅的频道、播放列表或 RSS")
        }
    }

    static func youtubeVideoID(_ text: String) -> String? {
        if let url = URL(string: text), let host = url.host?.lowercased() {
            if host.contains("youtu.be") {
                let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return validYouTubeID(id)
            }
            let parts = url.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" || $0 == "v" }),
               parts.indices.contains(i + 1), let id = validYouTubeID(parts[i + 1]) {
                return id
            }
            if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
               let v = items.first(where: { $0.name == "v" })?.value, let id = validYouTubeID(v) {
                return id
            }
        }
        return nil
    }

    static func youtubeChannelID(_ text: String) -> String? {
        if let url = URL(string: text), let host = url.host?.lowercased(), host.contains("youtube.com") {
            let parts = url.path.split(separator: "/").map(String.init)
            if let i = parts.firstIndex(of: "channel"), parts.indices.contains(i + 1) {
                let id = parts[i + 1]
                if id.hasPrefix("UC"), id.count >= 20 { return id }
            }
        }
        if text.hasPrefix("UC"), text.count >= 20, text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return text
        }
        if let url = URL(string: text),
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let id = items.first(where: { $0.name == "channel_id" })?.value, id.hasPrefix("UC") {
            return id
        }
        return nil
    }

    static func youtubePlaylistID(_ text: String) -> String? {
        guard youtubeVideoID(text) == nil else { return nil }
        if let url = URL(string: text),
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let id = items.first(where: { $0.name == "list" || $0.name == "playlist_id" })?.value,
           id.count >= 8 {
            return id
        }
        return nil
    }

    static func biliAid(_ text: String) -> String? {
        if let raw = firstMatch(text, #"(?i)(?:^|[^\d])av(\d{1,12})"#) { return digits(raw) }
        if let raw = firstMatch(text, #"(?i)(?:aid=)(\d{1,12})"#) { return digits(raw) }
        return nil
    }

    static func biliMid(_ text: String) -> String? {
        guard let url = URL(string: text), url.host?.lowercased().contains("space.bilibili.com") == true else { return nil }
        return url.path.split(separator: "/").first.flatMap { $0.allSatisfy(\.isNumber) ? String($0) : nil }
    }

    static func peertubeVideo(_ text: String) -> (host: String, id: String)? {
        guard let url = URL(string: text), let host = url.host?.lowercased(), !host.contains("youtube"), !host.contains("bilibili") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "w"), parts.indices.contains(i + 1) { return (host, parts[i + 1]) }
        if let i = parts.firstIndex(of: "watch"), parts.indices.contains(i + 1) { return (host, parts[i + 1]) }
        if parts.count >= 3, parts[0] == "videos", parts[1] == "watch" { return (host, parts[2]) }
        return nil
    }

    static func peertubeChannel(_ text: String) -> (host: String, name: String, account: Bool)? {
        guard let url = URL(string: text), let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { $0 == "c" || $0 == "video-channels" }), parts.indices.contains(i + 1) {
            return (host, parts[i + 1], false)
        }
        if let i = parts.firstIndex(where: { $0 == "a" || $0 == "accounts" }), parts.indices.contains(i + 1) {
            return (host, parts[i + 1], true)
        }
        return nil
    }

    static func normalizedHost(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: withScheme)?.host?.lowercased()
    }

    private static func validYouTubeID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard (8...20).contains(id.count), id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return id
    }

    private static func digits(_ raw: String) -> String? {
        let n = raw.filter(\.isNumber)
        return n.isEmpty ? nil : n
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range) else { return nil }
        let span = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
        guard let r = Range(span, in: text) else { return nil }
        return String(text[r])
    }
}

enum BiliLinks {
    static func player(bvid: String) -> String {
        "https://player.bilibili.com/player.html?bvid=\(bvid)&page=1&high_quality=1&autoplay=1&danmaku=0&mute=1"
    }
    static func player(aid: String) -> String {
        "https://player.bilibili.com/player.html?aid=\(aid)&page=1&high_quality=1&autoplay=1&danmaku=0&mute=1"
    }
    static func app(bvid: String) -> URL? { URL(string: "bilibili://video/\(bvid)") }
    static func web(bvid: String) -> URL? { URL(string: "https://www.bilibili.com/video/\(bvid)") }

    static func open(bvid: String) {
        guard let app = app(bvid: bvid) else { return }
        UIApplication.shared.open(app, options: [:]) { ok in
            if !ok, let web = web(bvid: bvid) { UIApplication.shared.open(web) }
        }
    }
}

enum FeedXML {
    static func youtube(_ xml: String) -> [MediaEntry] {
        chunks(xml).compactMap { chunk in
            let title = unescape(slice(chunk, "<title>", "</title>") ?? "YouTube")
            let id = slice(chunk, "<yt:videoId>", "</yt:videoId>") ?? PublicLink.youtubeVideoID(chunk)
            guard let id else { return nil }
            return MediaEntry(
                id: "yt-\(id)", kind: .embed, title: title,
                remoteURL: "https://www.youtube.com/watch?v=\(id)",
                coverURL: slice(chunk, "url=\"", "\""),
                platform: PlatformID.youtube, embedURL: EmbedLinks.youtube(id, mute: true),
                author: slice(chunk, "<name>", "</name>") ?? "YouTube", source: "youtube"
            )
        }
    }

    static func bili(_ xml: String) -> [MediaEntry] {
        chunks(xml).compactMap { chunk in
            guard let bvid = PublicLink.parse(chunk).flatMap({ if case .biliBV(let id) = $0 { return id } else { return nil } })
                    ?? firstBV(chunk) else { return nil }
            let title = unescape(slice(chunk, "<title>", "</title>") ?? bvid)
            return MediaEntry(
                id: "bv-\(bvid)", kind: .embed, title: title,
                remoteURL: "https://www.bilibili.com/video/\(bvid)", biliBvid: bvid,
                platform: PlatformID.bili, embedURL: BiliLinks.player(bvid: bvid),
                author: "哔哩哔哩", source: "bili"
            )
        }
    }

    static func chunks(_ xml: String) -> [String] {
        func rows(_ tag: String) -> [String] {
            let pieces = xml.components(separatedBy: tag)
            guard pieces.count > 1 else { return [] }
            return Array(pieces.dropFirst())
        }
        return (rows("<entry") + rows("<item")).filter {
            $0.contains("<title") || $0.contains("BV") || $0.contains("youtube")
        }
    }

    static func slice(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start) else { return nil }
        let rest = text[a.upperBound...]
        guard let b = rest.range(of: end) else { return nil }
        let value = String(rest[..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func firstBV(_ text: String) -> String? {
        PublicLink.parse(text).flatMap { if case .biliBV(let id) = $0 { return id } else { return nil } }
    }
}

enum YouTubeAPI {
    static func entries(json: String) -> [MediaEntry] {
        guard let root = JSONBox.obj(json), let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let video = (item["id"] as? [String: Any])?["videoId"] as? String
            guard let video else { return nil }
            let snippet = item["snippet"] as? [String: Any]
            let title = (snippet?["title"] as? String) ?? "YouTube"
            let author = (snippet?["channelTitle"] as? String) ?? "YouTube"
            let thumbs = snippet?["thumbnails"] as? [String: Any]
            let medium = (thumbs?["medium"] as? [String: Any])?["url"] as? String
                ?? (thumbs?["default"] as? [String: Any])?["url"] as? String
            return MediaEntry(
                id: "yt-\(video)", kind: .embed, title: title,
                remoteURL: "https://www.youtube.com/watch?v=\(video)", coverURL: medium,
                platform: PlatformID.youtube, embedURL: EmbedLinks.youtube(video, mute: true),
                author: author, source: "youtube"
            )
        }
    }

    static func search(key: String, query: String) async -> [MediaEntry] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var c = URLComponents(string: "https://www.googleapis.com/youtube/v3/search") else { return [] }
        c.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "8"),
            URLQueryItem(name: "safeSearch", value: "strict"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "key", value: trimmed),
        ]
        guard let url = c.url, let text = await HTTP.text(url) else { return [] }
        return entries(json: text)
    }
}

enum PeerTubeAPI {
    static func entries(json: String, host: String) -> [MediaEntry] {
        guard let root = JSONBox.obj(json) else { return [] }
        let rows: [[String: Any]]
        if let data = root["data"] as? [[String: Any]] { rows = data }
        else if root["uuid"] != nil || root["shortUUID"] != nil { rows = [root] }
        else { rows = [] }
        return rows.compactMap { video($0, host: host) }
    }

    static func video(_ o: [String: Any], host: String) -> MediaEntry? {
        if (o["nsfw"] as? Bool) == true { return nil }
        let uuid = (o["uuid"] as? String) ?? (o["shortUUID"] as? String) ?? ""
        guard !uuid.isEmpty else { return nil }
        let short = (o["shortUUID"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? uuid
        let origin = hostOf(o, fallback: host)
        let name = (o["name"] as? String) ?? "PeerTube"
        let thumb = thumbnail(o, apiHost: host)
        let author = ((o["account"] as? [String: Any])?["displayName"] as? String)
            ?? ((o["channel"] as? [String: Any])?["displayName"] as? String) ?? origin
        let downloadEnabled = (o["downloadEnabled"] as? Bool) ?? false
        let mp4 = fileURL(o["files"] as? [[String: Any]])
        let hls = playlistURL(o["streamingPlaylists"] as? [[String: Any]])
        let watch = absolute(o["url"] as? String, host: origin) ?? "https://\(origin)/videos/watch/\(uuid)"
        let embed = absolute(o["embedPath"] as? String, host: origin) ?? "https://\(origin)/videos/embed/\(short)"
        if let playback = mp4 ?? hls {
            return MediaEntry(
                id: "pt-\(origin)-\(uuid)", kind: .video, title: name,
                remoteURL: playback, coverURL: thumb,
                platform: PlatformID.peertube, embedURL: nil,
                downloadURL: downloadEnabled ? mp4 : nil,
                author: author, source: "peertube"
            )
        }
        return MediaEntry(
            id: "pt-\(origin)-\(uuid)", kind: .embed, title: name,
            remoteURL: watch, coverURL: thumb,
            platform: PlatformID.peertube, embedURL: embed,
            author: author, source: "peertube"
        )
    }

    /// Latest videos when the query is empty, search otherwise.
    /// A blank instance uses framatube.org. List rows omit `files`; those play from the official embed.
    static func browse(instance: String, query: String, count: Int = 20) async -> Result<[MediaEntry], SourceError> {
        let host = PublicLink.normalizedHost(instance) ?? defaultHost
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if q.isEmpty {
            url = endpoint(host, "/api/v1/videos", [
                URLQueryItem(name: "sort", value: "-publishedAt"),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "nsfw", value: "false"),
            ])
        } else {
            url = endpoint(host, "/api/v1/search/videos", [
                URLQueryItem(name: "search", value: q),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "nsfw", value: "false"),
            ])
        }
        guard let url else { return .failure(SourceError(message: "PeerTube 地址无效（\(host)）")) }
        switch await HTTP.fetch(url, headers: ["User-Agent": browserUA]) {
        case .success(let data):
            let rows = entries(json: String(decoding: data, as: UTF8.self), host: host)
            if !rows.isEmpty || q.isEmpty { return .success(rows) }
            if case .success(let found) = await sepia(query: q, count: count), !found.isEmpty { return .success(found) }
            return .success(rows)
        case .failure:
            if !q.isEmpty, case .success(let found) = await sepia(query: q, count: count), !found.isEmpty {
                return .success(found)
            }
            return .failure(SourceError(message: "PeerTube 暂时连不上（\(host)）"))
        }
    }

    /// Loads `/api/v1/videos/{id}` and keeps the entry only when a file or playlist exists.
    static func fetch(host: String, id: String) async -> MediaEntry? {
        guard let host = PublicLink.normalizedHost(host),
              let safe = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !safe.isEmpty,
              let url = endpoint(host, "/api/v1/videos/\(safe)", [URLQueryItem(name: "nsfw", value: "false")]),
              let text = await HTTP.text(url) else { return nil }
        return entries(json: text, host: host).first
    }

    static func search(instance: String, query: String, count: Int = 8) async -> [MediaEntry] {
        guard let host = PublicLink.normalizedHost(instance),
              let url = endpoint(host, "/api/v1/search/videos", [
                URLQueryItem(name: "search", value: query),
                URLQueryItem(name: "count", value: String(count)),
                URLQueryItem(name: "nsfw", value: "false"),
              ]),
              let text = await HTTP.text(url) else { return [] }
        return entries(json: text, host: host)
    }

    static func load(_ source: FollowedSource) async -> [MediaEntry] {
        switch source.platform {
        case PlatformID.youtube:
            let urlString: String
            switch source.kind {
            case "channel": urlString = "https://www.youtube.com/feeds/videos.xml?channel_id=\(source.ref)"
            case "playlist": urlString = "https://www.youtube.com/feeds/videos.xml?playlist_id=\(source.ref)"
            default: urlString = source.ref
            }
            guard let url = URL(string: urlString), let xml = await HTTP.text(url, accept: "application/atom+xml,application/xml,text/xml,*/*") else { return [] }
            return FeedXML.youtube(xml)
        case PlatformID.bili:
            guard source.kind == "rss", let url = URL(string: source.ref),
                  let xml = await HTTP.text(url, accept: "application/rss+xml,application/xml,text/xml,*/*") else { return [] }
            return FeedXML.bili(xml)
        case PlatformID.peertube:
            guard let host = PublicLink.normalizedHost(source.instance.isEmpty ? source.ref : source.instance) else { return [] }
            let path: String
            var query = [URLQueryItem(name: "count", value: "12"), URLQueryItem(name: "nsfw", value: "false")]
            switch source.kind {
            case "account": path = "/api/v1/accounts/\(source.ref)/videos"
            case "trending":
                path = "/api/v1/videos"
                query.append(URLQueryItem(name: "sort", value: "-trending"))
            case "local":
                path = "/api/v1/videos"
                query.append(URLQueryItem(name: "sort", value: "-publishedAt"))
                query.append(URLQueryItem(name: "isLocal", value: "true"))
            case "video": path = "/api/v1/videos/\(source.ref)"
            default: path = "/api/v1/video-channels/\(source.ref)/videos"
            }
            guard let url = endpoint(host, path, query), let text = await HTTP.text(url) else { return [] }
            return entries(json: text, host: host)
        default:
            guard let url = URL(string: source.ref), let xml = await HTTP.text(url, accept: "application/xml,text/xml,*/*") else { return [] }
            let bili = FeedXML.bili(xml)
            return bili.isEmpty ? FeedXML.youtube(xml) : bili
        }
    }

    static let defaultHost = "framatube.org"
    private static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static func sepia(query: String, count: Int) async -> Result<[MediaEntry], SourceError> {
        guard let url = endpoint("sepiasearch.org", "/api/v1/search/videos", [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "nsfw", value: "false"),
        ]) else { return .failure(SourceError(message: "PeerTube 暂时连不上（sepiasearch.org）")) }
        switch await HTTP.fetch(url, headers: ["User-Agent": browserUA]) {
        case .success(let data):
            return .success(entries(json: String(decoding: data, as: UTF8.self), host: "sepiasearch.org"))
        case .failure:
            return .failure(SourceError(message: "PeerTube 暂时连不上（sepiasearch.org）"))
        }
    }

    private static func hostOf(_ o: [String: Any], fallback: String) -> String {
        if let url = o["url"] as? String, let host = URL(string: url)?.host, !host.isEmpty { return host }
        if let host = (o["account"] as? [String: Any])?["host"] as? String, !host.isEmpty { return host }
        return fallback
    }

    private static func thumbnail(_ o: [String: Any], apiHost: String) -> String? {
        if let thumbs = o["thumbnails"] as? [[String: Any]] {
            let urls = thumbs.compactMap { $0["fileUrl"] as? String }.filter { !$0.isEmpty }
            if let best = urls.first { return best }
        }
        if let raw = o["thumbnailUrl"] as? String ?? o["previewUrl"] as? String { return absolute(raw, host: apiHost) }
        if let raw = o["thumbnailPath"] as? String ?? o["previewPath"] as? String { return absolute(raw, host: apiHost) }
        return nil
    }

    private static func absolute(_ raw: String?, host: String) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("https://") || raw.hasPrefix("http://") { return raw }
        if raw.hasPrefix("//") { return "https:" + raw }
        if raw.hasPrefix("/") { return "https://\(host)\(raw)" }
        return "https://\(host)/\(raw)"
    }

    private static func fileURL(_ files: [[String: Any]]?) -> String? {
        guard let files else { return nil }
        let urls = files.compactMap { $0["fileUrl"] as? String }.filter { !$0.isEmpty && !DownloadPolicy.isStreamURL($0) }
        return urls.first { $0.contains("720") } ?? urls.first
    }

    private static func playlistURL(_ lists: [[String: Any]]?) -> String? {
        lists?.compactMap { $0["playlistUrl"] as? String }.first { url in
            !url.isEmpty && !url.lowercased().contains(".mpd")
        }
    }

    private static func endpoint(_ host: String, _ path: String, _ query: [URLQueryItem]) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = path
        c.queryItems = query
        return c.url
    }
}
