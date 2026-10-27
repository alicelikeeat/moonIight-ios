import Foundation

struct DiscoveryBatch: Sendable {
    var entries: [MediaEntry]
    var nextPageToken: String? = nil
}

struct DiscoverySourceResult: Sendable {
    var sourceID: String
    var entries: [MediaEntry]
    var nextPageToken: String?
    var error: String?
}

private struct DiscoveryFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum DiscoveryAPI {
    static func load(sources: [MediaSource], query: String?, page: Int,
                     keys: [String: String], tokens: [String: String] = [:]) async -> [DiscoverySourceResult] {
        await withTaskGroup(of: DiscoverySourceResult.self) { group in
            for source in sources where source.enabled {
                group.addTask {
                    do {
                        let batch = try await withThrowingTaskGroup(of: DiscoveryBatch.self) { race in
                            race.addTask { try await fetch(source, query: query, page: page, keys: keys, token: tokens[source.id]) }
                            race.addTask {
                                try await Task.sleep(nanoseconds: 18_000_000_000)
                                throw DiscoveryFailure(message: "连接超时，请重试")
                            }
                            defer { race.cancelAll() }
                            return try await race.next()!
                        }
                        let tagged = batch.entries.map { entry in
                            var result = entry
                            result.source = source.id
                            return result
                        }
                        return DiscoverySourceResult(sourceID: source.id, entries: tagged, nextPageToken: batch.nextPageToken)
                    } catch {
                        return DiscoverySourceResult(sourceID: source.id, entries: [], error: error.localizedDescription)
                    }
                }
            }
            var results: [DiscoverySourceResult] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private static func fetch(_ source: MediaSource, query: String?, page: Int,
                              keys: [String: String], token: String?) async throws -> DiscoveryBatch {
        let keyword = query ?? ["nature", "space", "ocean", "city"].randomElement()!
        switch source.kind {
        case "bili":
            guard query == nil else { throw DiscoveryFailure(message: "提供推荐和热榜；关键词搜索需平台签名") }
            if source.id == "bili-ranking" {
                let root = try await json("https://api.bilibili.com/x/web-interface/ranking/v2", ["rid": "0", "type": "all"])
                guard (root["code"] as? Int ?? -1) == 0,
                      let data = root["data"] as? [String: Any], let rows = data["list"] as? [[String: Any]] else {
                    throw DiscoveryFailure(message: root["message"] as? String ?? "热榜返回异常")
                }
                return DiscoveryBatch(entries: rows.prefix(20).compactMap { row in
                    guard let id = row["bvid"] as? String else { return nil }
                    let owner = row["owner"] as? [String: Any]
                    return MediaEntry(id: "bili-\(id)", kind: .embed, title: row["title"] as? String ?? id,
                                      remoteURL: URL(string: "https://www.bilibili.com/video/\(id)"),
                                      coverURL: safeURL((row["pic"] as? String)?.replacingOccurrences(of: "http://", with: "https://")),
                                      embedURL: URL(string: "https://player.bilibili.com/player.html?bvid=\(id)&page=1&danmaku=0"),
                                      author: owner?["name"] as? String ?? "哔哩", platform: "bili", source: source.id)
                })
            }
            return DiscoveryBatch(entries: try await MediaAPI.bilibiliPopular())
        case "youtube":
            let key = keys["youtube"] ?? ""
            if let query {
                if page > 1 && token == nil { return DiscoveryBatch(entries: []) }
                let result = try await MediaAPI.youtubeSearch(query: query, apiKey: key, pageToken: token)
                return DiscoveryBatch(entries: result.entries, nextPageToken: result.nextPageToken)
            }
            if let configured = source.url, !configured.isEmpty {
                return DiscoveryBatch(entries: try await feed(youtubeFeed(configured), source: source))
            }
            return DiscoveryBatch(entries: try await MediaAPI.youtubeRSS(channelID: MediaAPI.youtubeChannels.randomElement()!, limit: 12))
        case "vimeo":
            let key = keys["vimeo"] ?? ""
            if !key.isEmpty {
                let root = try await json("https://api.vimeo.com/videos", ["query": keyword, "per_page": "12", "page": "\(page)"], headers: ["Authorization": "Bearer \(key)"])
                let rows = root["data"] as? [[String: Any]] ?? []
                return DiscoveryBatch(entries: rows.compactMap { row in
                    guard let link = row["link"] as? String, let url = URL(string: link) else { return nil }
                    let pictures = row["pictures"] as? [String: Any]
                    let sizes = pictures?["sizes"] as? [[String: Any]]
                    let user = row["user"] as? [String: Any]
                    var entry = directEntry(url, title: row["name"] as? String ?? "Vimeo")
                    entry.coverURL = safeURL(sizes?.last?["link"] as? String)
                    entry.author = user?["name"] as? String ?? "Vimeo"
                    return entry
                })
            }
            if let url = source.url.flatMap(URL.init(string:)) {
                if url.pathExtension == "xml" || url.path.contains("rss") {
                    return DiscoveryBatch(entries: try await feed(url, source: source))
                }
                return DiscoveryBatch(entries: [try await resolve(url)])
            }
            throw DiscoveryFailure(message: "添加 Vimeo 视频或 RSS 地址；关键词搜索需 Access Token")
        case "dailymotion":
            var parameters = ["fields": "id,title,thumbnail_720_url,thumbnail_url,owner.screenname,url", "limit": "12", "page": "\(page)"]
            if query == nil { parameters["sort"] = "trending" } else { parameters["search"] = keyword }
            let root = try await json("https://api.dailymotion.com/videos", parameters)
            return DiscoveryBatch(entries: (root["list"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return MediaEntry(id: "dm-\(id)", kind: .embed, title: row["title"] as? String ?? id,
                                  remoteURL: URL(string: "https://www.dailymotion.com/video/\(id)"),
                                  coverURL: safeURL(row["thumbnail_720_url"] as? String ?? row["thumbnail_url"] as? String),
                                  embedURL: URL(string: "https://www.dailymotion.com/embed/video/\(id)"),
                                  author: row["owner.screenname"] as? String ?? "Dailymotion", platform: "dailymotion", source: source.id)
            })
        case "archive":
            let root = try await json("https://archive.org/advancedsearch.php", ["q": "mediatype:movies AND format:\"MPEG4\" AND (\(keyword))", "fl[]": "identifier,title,creator", "rows": "6", "page": "\(page)", "output": "json"])
            let response = root["response"] as? [String: Any]
            let docs = response?["docs"] as? [[String: Any]] ?? []
            let hints = docs.compactMap { row -> ArchiveHint? in
                guard let id = row["identifier"] as? String else { return nil }
                return ArchiveHint(id: id, title: row["title"] as? String ?? id,
                                   author: row["creator"] as? String ?? (row["creator"] as? [String])?.joined(separator: ", ") ?? "Internet Archive")
            }
            let entries = await withTaskGroup(of: MediaEntry?.self) { group in
                for hint in hints { group.addTask { try? await archiveVideo(hint) } }
                var entries: [MediaEntry] = []
                for await entry in group { if let entry { entries.append(entry) } }
                return entries
            }
            return DiscoveryBatch(entries: entries)
        case "nasa":
            let root = try await json("https://images-api.nasa.gov/search", ["q": query ?? "space", "media_type": "video", "page_size": "6", "page": "\(page)"])
            let collection = root["collection"] as? [String: Any]
            let rows = collection?["items"] as? [[String: Any]] ?? []
            let hints = rows.compactMap { row -> NASAHint? in
                guard let info = (row["data"] as? [[String: Any]])?.first, let id = info["nasa_id"] as? String else { return nil }
                return NASAHint(id: id, title: info["title"] as? String ?? id,
                                cover: (row["links"] as? [[String: Any]])?.first?["href"] as? String,
                                author: info["center"] as? String ?? "NASA")
            }
            let entries = await withTaskGroup(of: MediaEntry?.self) { group in
                for hint in hints { group.addTask { try? await nasaVideo(hint) } }
                var entries: [MediaEntry] = []
                for await entry in group { if let entry { entries.append(entry) } }
                return entries
            }
            return DiscoveryBatch(entries: entries)
        case "peertube":
            let root = try await json("https://sepiasearch.org/api/v1/search/videos", ["search": keyword, "count": "12", "start": "\((page - 1) * 12)", "nsfw": "false"])
            return DiscoveryBatch(entries: (root["data"] as? [[String: Any]] ?? []).compactMap { row in
                let account = row["account"] as? [String: Any]
                let host = account?["host"] as? String ?? ""
                let id = row["uuid"] as? String ?? row["shortUUID"] as? String ?? ""
                guard !id.isEmpty, !host.isEmpty else { return nil }
                let embed = safeURL(row["embedUrl"] as? String) ?? URL(string: "https://\(host)/videos/embed/\(id)")
                let cover = safeURL(row["thumbnailUrl"] as? String) ?? safeURL(row["thumbnailPath"] as? String, relativeTo: URL(string: "https://\(host)"))
                return MediaEntry(id: "pt-\(id)", kind: .embed, title: row["name"] as? String ?? id,
                                  remoteURL: safeURL(row["url"] as? String) ?? URL(string: "https://\(host)/videos/watch/\(id)"),
                                  coverURL: cover, embedURL: embed,
                                  author: account?["displayName"] as? String ?? "PeerTube", platform: "peertube", source: source.id)
            })
        case "commons":
            let root = try await json("https://commons.wikimedia.org/w/api.php", ["action": "query", "format": "json", "generator": "search", "gsrnamespace": "6", "gsrlimit": "12", "gsroffset": "\((page - 1) * 12)", "gsrsearch": "\(keyword) filetype:video", "prop": "imageinfo", "iiprop": "url|mime", "iiurlwidth": "640"])
            let data = root["query"] as? [String: Any]
            let pages = data?["pages"] as? [String: [String: Any]] ?? [:]
            return DiscoveryBatch(entries: pages.values.compactMap { row in
                guard let info = (row["imageinfo"] as? [[String: Any]])?.first, let url = safeURL(info["url"] as? String) else { return nil }
                let mime = info["mime"] as? String ?? ""
                let video = mime.hasPrefix("video/") || mime == "application/ogg"
                let native = mime == "video/mp4" || mime == "video/quicktime"
                return MediaEntry(id: "commons-\(row["pageid"] ?? url.absoluteString)", kind: video ? (native ? .video : .embed) : .image,
                                  title: (row["title"] as? String ?? "Commons").replacingOccurrences(of: "File:", with: ""),
                                  remoteURL: url, coverURL: safeURL(info["thumburl"] as? String) ?? (video ? nil : url),
                                  embedURL: video && !native ? safeURL(info["descriptionurl"] as? String) : nil,
                                  author: "Wikimedia Commons", platform: "commons", source: source.id)
            })
        case "rss":
            guard let url = source.url.flatMap(URL.init(string:)) else { throw DiscoveryFailure(message: "请先添加 RSS / Atom 订阅地址") }
            let entries = try await feed(url, source: source)
            return DiscoveryBatch(entries: query == nil ? entries : entries.filter { $0.title.localizedCaseInsensitiveContains(keyword) || $0.author.localizedCaseInsensitiveContains(keyword) })
        case "web":
            guard let url = source.url.flatMap(URL.init(string:)) else { throw DiscoveryFailure(message: "请先添加网站或视频直链") }
            let entries = try await webpage(url, source: source)
            return DiscoveryBatch(entries: query == nil ? entries : entries.filter { $0.title.localizedCaseInsensitiveContains(keyword) })
        case "pexels":
            let key = keys["pexels"] ?? ""
            guard !key.isEmpty else { throw DiscoveryFailure(message: "请先配置 Pexels API Key") }
            let root = try await json("https://api.pexels.com/videos/search", ["query": keyword, "per_page": "12", "page": "\(page)"], headers: ["Authorization": key])
            return DiscoveryBatch(entries: (root["videos"] as? [[String: Any]] ?? []).compactMap { row in
                let files = (row["video_files"] as? [[String: Any]] ?? []).filter { $0["file_type"] as? String == "video/mp4" }
                let preferred = files.filter { (480...1280).contains($0["width"] as? Int ?? 0) }.sorted { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
                guard let file = preferred.first ?? files.first, let url = safeURL(file["link"] as? String) else { return nil }
                let user = row["user"] as? [String: Any]
                return MediaEntry(id: "pexels-\(row["id"] ?? url.absoluteString)", kind: .video,
                                  title: row["url"] as? String ?? "Pexels video", remoteURL: url, coverURL: safeURL(row["image"] as? String),
                                  author: user?["name"] as? String ?? "Pexels", platform: "pexels", source: source.id)
            })
        case "pixabay":
            let key = keys["pixabay"] ?? ""
            guard !key.isEmpty else { throw DiscoveryFailure(message: "请先配置 Pixabay API Key") }
            let root = try await json("https://pixabay.com/api/videos/", ["key": key, "q": keyword, "per_page": "12", "page": "\(page)", "safesearch": "true"])
            return DiscoveryBatch(entries: (root["hits"] as? [[String: Any]] ?? []).compactMap { row in
                let videos = row["videos"] as? [String: [String: Any]]
                let file = videos?["medium"] ?? videos?["small"]
                guard let url = safeURL(file?["url"] as? String) else { return nil }
                return MediaEntry(id: "pixabay-\(row["id"] ?? url.absoluteString)", kind: .video, title: row["tags"] as? String ?? "Pixabay video",
                                  remoteURL: url, coverURL: safeURL(file?["thumbnail"] as? String), author: row["user"] as? String ?? "Pixabay", platform: "pixabay", source: source.id)
            })
        case "twitch":
            let key = keys["twitch"] ?? "", client = keys["twitch-client"] ?? ""
            guard !key.isEmpty, !client.isEmpty else { throw DiscoveryFailure(message: "请配置 Twitch Client ID 和 Access Token") }
            let root = try await json("https://api.twitch.tv/helix/search/channels", ["query": keyword, "first": "12", "live_only": "true"], headers: ["Authorization": "Bearer \(key)", "Client-Id": client])
            return DiscoveryBatch(entries: (root["data"] as? [[String: Any]] ?? []).compactMap { row in
                guard let login = row["broadcaster_login"] as? String, let url = URL(string: "https://www.twitch.tv/\(login)") else { return nil }
                return MediaEntry(id: "twitch-\(login)", kind: .embed, title: row["title"] as? String ?? login,
                                  remoteURL: url, coverURL: safeURL(row["thumbnail_url"] as? String), embedURL: url,
                                  author: row["display_name"] as? String ?? login, platform: "twitch", source: source.id)
            })
        default:
            throw DiscoveryFailure(message: "暂不支持这个来源")
        }
    }

    private struct ArchiveHint: Sendable { var id: String; var title: String; var author: String }
    private static func archiveVideo(_ hint: ArchiveHint) async throws -> MediaEntry {
        let root = try await json("https://archive.org/metadata/\(hint.id)")
        let files = (root["files"] as? [[String: Any]] ?? []).filter {
            let name = $0["name"] as? String ?? ""
            return name.lowercased().hasSuffix(".mp4") && !name.lowercased().contains("sample")
        }.sorted { (Int($0["size"] as? String ?? "") ?? Int.max) < (Int($1["size"] as? String ?? "") ?? Int.max) }
        let file = files.first?["name"] as? String
        let url = file.map { URL(string: "https://archive.org/download/\(hint.id)/")!.appendingPathComponent($0) }
        return MediaEntry(id: "archive-\(hint.id)", kind: url == nil ? .embed : .video, title: hint.title,
                          remoteURL: url ?? URL(string: "https://archive.org/details/\(hint.id)"),
                          coverURL: URL(string: "https://archive.org/services/img/\(hint.id)"),
                          embedURL: url == nil ? URL(string: "https://archive.org/embed/\(hint.id)") : nil,
                          author: hint.author, platform: "archive", source: "archive")
    }

    private struct NASAHint: Sendable { var id: String; var title: String; var cover: String?; var author: String }
    private static func nasaVideo(_ hint: NASAHint) async throws -> MediaEntry {
        let root = try await json(URL(string: "https://images-api.nasa.gov/asset/")!.appendingPathComponent(hint.id).absoluteString)
        let collection = root["collection"] as? [String: Any]
        let urls = (collection?["items"] as? [[String: Any]] ?? []).compactMap { $0["href"] as? String }.filter { $0.lowercased().hasSuffix(".mp4") }
        guard let url = safeURL(urls.first(where: { $0.contains("~medium.mp4") }) ?? urls.first(where: { $0.contains("~mobile.mp4") }) ?? urls.first) else { throw MediaServiceError.noResults }
        return MediaEntry(id: "nasa-\(hint.id)", kind: .video, title: hint.title, remoteURL: url, coverURL: safeURL(hint.cover), author: hint.author, platform: "nasa", source: "nasa")
    }

    static func resolve(_ url: URL) async throws -> MediaEntry {
        if var resolved = PlatformResolver.resolve(url.absoluteString) {
            if resolved.platform == "youtube",
               let root = try? await json("https://www.youtube.com/oembed", ["url": url.absoluteString, "format": "json"]) {
                resolved.title = root["title"] as? String ?? resolved.title
                resolved.author = root["author_name"] as? String ?? resolved.author
                resolved.coverURL = safeURL(root["thumbnail_url"] as? String) ?? resolved.coverURL
            } else if resolved.platform == "bili", let id = PlatformResolver.bilibiliID(in: url.absoluteString),
                      let root = try? await json("https://api.bilibili.com/x/web-interface/view", ["bvid": id]),
                      let data = root["data"] as? [String: Any] {
                resolved.title = data["title"] as? String ?? resolved.title
                resolved.coverURL = safeURL((data["pic"] as? String)?.replacingOccurrences(of: "http://", with: "https://"))
                resolved.author = (data["owner"] as? [String: Any])?["name"] as? String ?? resolved.author
            }
            return resolved
        }
        if url.host?.lowercased().hasSuffix("vimeo.com") == true {
            let root = try await json("https://vimeo.com/api/oembed.json", ["url": url.absoluteString])
            var entry = directEntry(url, title: root["title"] as? String ?? "Vimeo")
            entry.coverURL = safeURL(root["thumbnail_url"] as? String)
            entry.author = root["author_name"] as? String ?? "Vimeo"
            return entry
        }
        return directEntry(url)
    }

    static func directEntry(_ url: URL, title: String? = nil) -> MediaEntry {
        let host = url.host?.lowercased() ?? ""
        var platform = "web", embed = url, kind = MediaKind.embed
        if host.hasSuffix("vimeo.com"), let id = url.pathComponents.last, id.allSatisfy(\.isNumber) {
            platform = "vimeo"; embed = URL(string: "https://player.vimeo.com/video/\(id)")!
        } else if host.hasSuffix("dailymotion.com") || host == "dai.ly" {
            platform = "dailymotion"
            let id = url.pathComponents.last?.components(separatedBy: "_").first ?? ""
            embed = URL(string: "https://www.dailymotion.com/embed/video/\(id)") ?? url
        } else if host == "archive.org", url.pathComponents.count > 2 {
            platform = "archive"; embed = URL(string: "https://archive.org/embed/\(url.pathComponents[2])") ?? url
        } else if url.path.contains("/videos/watch/") || url.path.hasPrefix("/w/") {
            platform = "peertube"
            embed = URL(string: "https://\(host)/videos/embed/\(url.lastPathComponent)") ?? url
        }
        let ext = url.pathExtension.lowercased()
        if ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac"].contains(ext) { kind = .video }
        if ["jpg", "jpeg", "png", "heic", "webp", "gif"].contains(ext) { kind = .image }
        return MediaEntry(kind: kind, title: title ?? (url.lastPathComponent.isEmpty ? host : url.lastPathComponent),
                          remoteURL: url, coverURL: kind == .image ? url : nil, embedURL: kind == .embed ? embed : nil,
                          author: host, platform: platform, source: platform)
    }

    static func webpage(_ url: URL, source: MediaSource) async throws -> [MediaEntry] {
        let direct = directEntry(url)
        if direct.kind != .embed || direct.platform != "web" { return [try await resolve(url)] }
        let data = try await bytes(url)
        guard let html = String(data: data, encoding: .utf8) else { throw MediaServiceError.invalidResponse }
        let title = captures(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).first?.first ?? source.name
        var entries: [MediaEntry] = []
        let tags = captures(#"<(?:video|source|img)\b([^>]+)>"#, in: html)
        for match in tags.prefix(80) {
            guard let attributes = match.first,
                  let raw = attribute("src", in: attributes) ?? attribute("data-src", in: attributes),
                  let media = safeURL(raw, relativeTo: url) else { continue }
            var entry = directEntry(media, title: attribute("alt", in: attributes) ?? title)
            guard entry.kind != .embed else { continue }
            if entry.kind == .video { entry.coverURL = safeURL(attribute("poster", in: attributes), relativeTo: url) }
            entry.author = source.name
            entries.append(entry)
        }
        for match in captures(#"<meta\b([^>]+)>"#, in: html) {
            guard let attrs = match.first,
                  let property = attribute("property", in: attrs) ?? attribute("name", in: attrs),
                  ["og:video", "og:video:url", "og:video:secure_url", "og:image"].contains(property),
                  let media = safeURL(attribute("content", in: attrs), relativeTo: url) else { continue }
            entries.append(directEntry(media, title: title))
        }
        for match in captures(#"<iframe\b([^>]+)>"#, in: html).prefix(12) {
            guard let attributes = match.first, let embeddedURL = safeURL(attribute("src", in: attributes), relativeTo: url) else { continue }
            entries.append(directEntry(embeddedURL, title: title))
        }
        if entries.isEmpty { throw DiscoveryFailure(message: "页面未公开图片或视频直链，可添加官方视频页面或 RSS") }
        return entries
    }

    private static func youtubeFeed(_ value: String) throws -> URL {
        if value.hasPrefix("UC"), !value.contains("/") {
            return endpoint("https://www.youtube.com/feeds/videos.xml", ["channel_id": value])
        }
        guard let url = URL(string: value), let host = url.host, host.hasSuffix("youtube.com") else { throw DiscoveryFailure(message: "请填写 YouTube 频道 ID、频道地址或播放列表地址") }
        if url.path == "/feeds/videos.xml" { return url }
        let parts = url.pathComponents
        if parts.count > 2, parts[1] == "channel" { return endpoint("https://www.youtube.com/feeds/videos.xml", ["channel_id": parts[2]]) }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value {
            return endpoint("https://www.youtube.com/feeds/videos.xml", ["playlist_id": id])
        }
        throw DiscoveryFailure(message: "该频道地址未包含频道 ID，请使用 /channel/UC… 或播放列表地址")
    }

    private static func feed(_ url: URL, source: MediaSource) async throws -> [MediaEntry] {
        let data = try await bytes(url)
        let delegate = DiscoveryFeedParser(source: source)
        let xml = XMLParser(data: data)
        xml.delegate = delegate
        guard xml.parse() else { throw DiscoveryFailure(message: "这不是有效的 RSS / Atom 订阅") }
        return Array(delegate.entries.prefix(40))
    }

    private static func endpoint(_ base: String, _ parameters: [String: String] = [:]) -> URL {
        var components = URLComponents(string: base)!
        if !parameters.isEmpty { components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return components.url!
    }

    private static func bytes(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw DiscoveryFailure(message: "仅支持 HTTP / HTTPS 地址") }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Moonlight-iOS/2.0 (personal media reader)", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MediaServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw DiscoveryFailure(message: "服务返回 HTTP \(http.statusCode)") }
        guard data.count <= 6 * 1024 * 1024 else { throw DiscoveryFailure(message: "页面或订阅内容过大") }
        return data
    }

    private static func json(_ base: String, _ parameters: [String: String] = [:], headers: [String: String] = [:]) async throws -> [String: Any] {
        let data = try await bytes(endpoint(base, parameters), headers: headers)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MediaServiceError.invalidResponse }
        if let error = root["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "接口返回错误"
            throw DiscoveryFailure(message: message)
        }
        return root
    }

    fileprivate static func safeURL(_ value: String?, relativeTo base: URL? = nil) -> URL? {
        guard let value, !value.isEmpty, let url = URL(string: value.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        captures("(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']+)["']"#, in: text).first?.first
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }
}

private final class DiscoveryFeedParser: NSObject, XMLParserDelegate {
    let source: MediaSource
    var entries: [MediaEntry] = []
    private var insideItem = false
    private var textStack: [String] = []
    private var title = "", author = "", link = "", media = "", cover = "", videoID = "", mediaType = ""
    private var channelCover = ""
    private var inChannelImage = false

    init(source: MediaSource) { self.source = source }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        textStack.append("")
        let local = name.components(separatedBy: ":").last?.lowercased() ?? name
        if local == "item" || local == "entry" {
            insideItem = true; title = ""; author = ""; link = ""; media = ""; cover = ""; videoID = ""; mediaType = ""
        }
        guard insideItem else {
            if name.lowercased() == "itunes:image" { channelCover = attributes["href"] ?? attributes["url"] ?? channelCover }
            if local == "image" { inChannelImage = true }
            return
        }
        if local == "enclosure" || (local == "link" && attributes["rel"] == "enclosure") {
            media = attributes["url"] ?? attributes["href"] ?? media
            mediaType = attributes["type"] ?? mediaType
        } else if local == "link", let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" {
            link = href
        } else if local == "thumbnail" || name.lowercased() == "itunes:image" {
            cover = attributes["url"] ?? attributes["href"] ?? cover
        } else if name.lowercased() == "media:content", let url = attributes["url"] {
            if (attributes["type"] ?? "").hasPrefix("image/") { cover = url }
            else if media.isEmpty { media = url }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !textStack.isEmpty { textStack[textStack.count - 1] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8), !textStack.isEmpty { textStack[textStack.count - 1] += value }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = (textStack.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !textStack.isEmpty { textStack[textStack.count - 1] += value }
        let local = name.components(separatedBy: ":").last?.lowercased() ?? name
        guard insideItem else {
            if local == "url", inChannelImage { channelCover = value }
            if local == "image" { inChannelImage = false }
            return
        }
        switch local {
        case "title": if title.isEmpty { title = value }
        case "link": if !value.isEmpty { link = value }
        case "author", "creator", "name": if author.isEmpty { author = value }
        case "videoid": videoID = value
        case "item", "entry":
            insideItem = false
            let raw = !media.isEmpty ? media : link
            guard let url = DiscoveryAPI.safeURL(raw) else { return }
            var entry = PlatformResolver.resolve(url.absoluteString) ?? DiscoveryAPI.directEntry(url, title: title)
            if !media.isEmpty, mediaType.hasPrefix("audio/") || mediaType.hasPrefix("video/") { entry.kind = .video; entry.embedURL = nil }
            if !videoID.isEmpty, let resolved = PlatformResolver.resolve("https://www.youtube.com/watch?v=\(videoID)") { entry = resolved }
            entry.title = title.isEmpty ? source.name : title
            entry.author = author.isEmpty ? source.name : author
            entry.coverURL = DiscoveryAPI.safeURL(cover) ?? entry.coverURL ?? DiscoveryAPI.safeURL(channelCover)
            entry.source = source.id
            if source.kind == "rss" { entry.platform = "rss" }
            entries.append(entry)
        default: break
        }
    }
}
