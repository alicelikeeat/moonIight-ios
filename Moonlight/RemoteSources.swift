import Foundation

enum HTTP {
    static let userAgent = "Moonlight/0.1 (iOS; educational)"

    static func get(_ url: URL, accept: String = "application/json,*/*", headers: [String: String] = [:]) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func text(_ url: URL, accept: String = "application/json,*/*", headers: [String: String] = [:]) async -> String? {
        guard let data = await get(url, accept: accept, headers: headers) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum JSONBox {
    static func obj(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    static func obj(_ text: String) -> [String: Any]? { obj(Data(text.utf8)) }
}

enum ArchiveAPI {
    static func search(query: String, limit: Int = 4) async -> [MediaEntry] {
        let q = "mediatype:movies AND format:\"MPEG4\" AND (\(query))"
        var c = URLComponents(string: "https://archive.org/advancedsearch.php")!
        c.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "rows", value: String(limit)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = c.url, let data = await HTTP.get(url), let root = JSONBox.obj(data),
              let docs = (root["response"] as? [String: Any])?["docs"] as? [[String: Any]] else { return [] }
        var out: [MediaEntry] = []
        for doc in docs {
            guard let id = doc["identifier"] as? String, !id.isEmpty else { continue }
            if let meta = await HTTP.text(URL(string: "https://archive.org/metadata/\(id)")!) ,
               let entry = resolve(metadataJSON: meta, id: id, titleHint: doc["title"] as? String ?? "", creator: doc["creator"]) {
                out.append(entry)
            }
        }
        return out
    }

    static func resolve(metadataJSON: String, id: String, titleHint: String, creator: Any?) -> MediaEntry? {
        guard let root = JSONBox.obj(metadataJSON), let files = root["files"] as? [[String: Any]] else { return nil }
        var bestName: String?
        var bestSize = Int64.max
        for f in files {
            guard let name = f["name"] as? String else { continue }
            let lower = name.lowercased()
            if !lower.hasSuffix(".mp4") || lower.contains("sample") { continue }
            let size = Int64((f["size"] as? String) ?? "") ?? Int64((f["size"] as? NSNumber)?.int64Value ?? 0)
            if size >= 100_000 && size <= bestSize {
                bestSize = size
                bestName = name
            }
        }
        if bestName == nil {
            bestName = files.compactMap { $0["name"] as? String }.first { n in
                let l = n.lowercased()
                return l.hasSuffix(".mp4") && !l.contains("sample")
            }
        }
        guard let file = bestName else { return nil }
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        let url = "https://archive.org/download/\(id)/\(encoded)"
        let creatorStr: String = {
            if let s = creator as? String { return s }
            if let a = creator as? [String] { return a.joined(separator: ", ") }
            if let a = creator as? [Any] { return a.compactMap { $0 as? String }.joined(separator: ", ") }
            return (root["metadata"] as? [String: Any])?["creator"] as? String ?? ""
        }()
        var title = titleHint
        if title.isEmpty { title = ((root["metadata"] as? [String: Any])?["title"] as? String) ?? id }
        if title.isEmpty { title = id }
        return MediaEntry(
            kind: .video, title: title, remoteURL: url,
            coverURL: "https://archive.org/services/img/\(id)",
            platform: PlatformID.archive,
            author: creatorStr.isEmpty ? "Internet Archive" : creatorStr,
            source: "archive"
        )
    }
}

enum NASAAPI {
    static func search(query: String, limit: Int = 4) async -> [MediaEntry] {
        var c = URLComponents(string: "https://images-api.nasa.gov/search")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "media_type", value: "video"),
            URLQueryItem(name: "page_size", value: String(limit)),
        ]
        guard let url = c.url, let data = await HTTP.get(url), let root = JSONBox.obj(data),
              let items = ((root["collection"] as? [String: Any])?["items"] as? [[String: Any]]) else { return [] }
        var out: [MediaEntry] = []
        for item in items {
            if out.count >= limit { break }
            guard let data0 = (item["data"] as? [[String: Any]])?.first,
                  let nasaId = data0["nasa_id"] as? String, !nasaId.isEmpty else { continue }
            let title = (data0["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? nasaId
            let cover = ((item["links"] as? [[String: Any]])?.first?["href"] as? String)?.replacingOccurrences(of: "http://", with: "https://")
            let asset = "https://images-api.nasa.gov/asset/\(nasaId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nasaId)"
            guard let assetURL = URL(string: asset), let raw = await HTTP.text(assetURL), let mp4 = pickMP4(assetJSON: raw) else { continue }
            out.append(MediaEntry(
                kind: .video, title: title, remoteURL: mp4.replacingOccurrences(of: "http://", with: "https://"),
                coverURL: cover, platform: PlatformID.nasa,
                author: (data0["center"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "NASA",
                source: "nasa"
            ))
        }
        return out
    }

    static func pickMP4(assetJSON: String) -> String? {
        guard let root = JSONBox.obj(assetJSON),
              let items = (root["collection"] as? [String: Any])?["items"] as? [[String: Any]] else { return nil }
        let hrefs = items.compactMap { $0["href"] as? String }
        return hrefs.first { $0.lowercased().contains("~medium.mp4") }
            ?? hrefs.first { $0.lowercased().contains("~mobile.mp4") }
            ?? hrefs.first { $0.lowercased().hasSuffix(".mp4") && !$0.lowercased().contains("orig") }
            ?? hrefs.first { $0.lowercased().hasSuffix(".mp4") }
    }
}

enum CommonsAPI {
    static func search(keyword: String, limit: Int = 16) async -> [MediaEntry] {
        let q = "\(keyword) filetype:bitmap|video"
        var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        c.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: String(limit)),
            URLQueryItem(name: "gsrsearch", value: q),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|size"),
            URLQueryItem(name: "iiurlwidth", value: "1080"),
        ]
        guard let url = c.url, let data = await HTTP.get(url), let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(json: text)
    }

    static func parse(json: String) -> [MediaEntry] {
        guard let root = JSONBox.obj(json),
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        var out: [MediaEntry] = []
        for (_, value) in pages {
            guard let p = value as? [String: Any],
                  let info = (p["imageinfo"] as? [[String: Any]])?.first else { continue }
            let mime = (info["mime"] as? String) ?? ""
            let full = (info["url"] as? String) ?? ""
            let thumb = ((info["thumburl"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? full
            if full.isEmpty && thumb.isEmpty { continue }
            let kind: MediaKind
            if mime.hasPrefix("video") { kind = .video }
            else if mime.hasPrefix("image") { kind = .image }
            else { continue }
            let title = ((p["title"] as? String) ?? "Commons").replacingOccurrences(of: "File:", with: "")
            out.append(MediaEntry(
                kind: kind, title: title, remoteURL: full.isEmpty ? thumb : full,
                coverURL: thumb.isEmpty ? nil : thumb,
                platform: PlatformID.commons, author: "Wikimedia", source: "commons"
            ))
        }
        return out
    }
}

enum PexelsAPI {
    static func search(key: String, query: String) async -> [MediaEntry] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var photos: [MediaEntry] = []
        if var c = URLComponents(string: "https://api.pexels.com/v1/search") {
            c.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "per_page", value: "12")]
            if let url = c.url, let data = await HTTP.get(url, headers: ["Authorization": trimmed]),
               let root = JSONBox.obj(data), let arr = root["photos"] as? [[String: Any]] {
                photos = arr.compactMap { o in
                    let src = o["src"] as? [String: Any]
                    guard let link = (src?["large2x"] as? String) ?? (src?["large"] as? String) else { return nil }
                    let alt = (o["alt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pexels"
                    let author = (o["photographer"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pexels"
                    return MediaEntry(kind: .image, title: alt, remoteURL: link, coverURL: link, platform: PlatformID.pexels, author: author, source: "pexels")
                }
            }
        }
        var videos: [MediaEntry] = []
        if var c = URLComponents(string: "https://api.pexels.com/videos/search") {
            c.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "per_page", value: "8")]
            if let url = c.url, let data = await HTTP.get(url, headers: ["Authorization": trimmed]),
               let root = JSONBox.obj(data), let arr = root["videos"] as? [[String: Any]] {
                videos = arr.compactMap { o in
                    guard let files = o["video_files"] as? [[String: Any]] else { return nil }
                    var best: String?
                    var bestW = Int.max
                    for f in files {
                        guard (f["file_type"] as? String) == "video/mp4", let link = f["link"] as? String, !link.isEmpty else { continue }
                        let w = (f["width"] as? NSNumber)?.intValue ?? 0
                        if (480...1280).contains(w) && w < bestW { best = link; bestW = w }
                        else if best == nil { best = link; bestW = w }
                    }
                    guard let url = best else { return nil }
                    let author = (o["user"] as? [String: Any])?["name"] as? String ?? "Pexels"
                    let cover = o["image"] as? String
                    return MediaEntry(kind: .video, title: "Pexels 视频", remoteURL: url, coverURL: cover, platform: PlatformID.pexels, author: author, source: "pexels")
                }
            }
        }
        return photos + videos
    }
}

enum PixabayAPI {
    static func search(key: String, query: String) async -> [MediaEntry] {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        var images: [MediaEntry] = []
        if var c = URLComponents(string: "https://pixabay.com/api/") {
            c.queryItems = [
                URLQueryItem(name: "key", value: trimmed),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "image_type", value: "photo"),
                URLQueryItem(name: "per_page", value: "12"),
            ]
            if let url = c.url, let data = await HTTP.get(url), let root = JSONBox.obj(data), let hits = root["hits"] as? [[String: Any]] {
                images = hits.compactMap { o in
                    let link = (o["largeImageURL"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (o["webformatURL"] as? String)
                    guard let link, !link.isEmpty else { return nil }
                    return MediaEntry(kind: .image, title: (o["tags"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pixabay", remoteURL: link, coverURL: link, platform: PlatformID.pixabay, author: (o["user"] as? String) ?? "", source: "pixabay")
                }
            }
        }
        var videos: [MediaEntry] = []
        if var c = URLComponents(string: "https://pixabay.com/api/videos/") {
            c.queryItems = [
                URLQueryItem(name: "key", value: trimmed),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "per_page", value: "8"),
                URLQueryItem(name: "safesearch", value: "true"),
            ]
            if let url = c.url, let data = await HTTP.get(url), let root = JSONBox.obj(data), let hits = root["hits"] as? [[String: Any]] {
                videos = hits.compactMap { o in
                    guard let vids = o["videos"] as? [String: Any] else { return nil }
                    let pick = ["medium", "small", "large"].compactMap { vids[$0] as? [String: Any] }.first { ($0["url"] as? String)?.isEmpty == false }
                    guard let link = pick?["url"] as? String else { return nil }
                    return MediaEntry(kind: .video, title: (o["tags"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Pixabay 视频", remoteURL: link, coverURL: pick?["thumbnail"] as? String, platform: PlatformID.pixabay, author: (o["user"] as? String) ?? "", source: "pixabay")
                }
            }
        }
        return images + videos
    }
}

enum LinkResolver {
    struct Result {
        var entry: MediaEntry?
        var message: String?
    }

    static func resolve(_ raw: String) -> Result {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return Result(entry: nil, message: "请粘贴 http(s) 链接")
        }
        let lower = text.lowercased()
        if lower.contains(".m3u8") || lower.contains(".mpd") {
            return Result(entry: nil, message: "流媒体地址不能下载或直接播放。请粘贴官方页面，用网页播放器打开。")
        }
        if let bvid = text.range(of: #"BV[0-9A-Za-z]{10}"#, options: .regularExpression).map({ String(text[$0]) }) {
            return Result(entry: MediaEntry(
                kind: .embed, title: bvid, remoteURL: text, biliBvid: bvid,
                platform: PlatformID.bili, embedURL: EmbedLinks.bili(bvid, mute: true),
                author: "哔哩哔哩", source: "bili"
            ), message: nil)
        }
        if let id = youtubeID(text) {
            return Result(entry: MediaEntry(
                kind: .embed, title: "YouTube", remoteURL: text,
                platform: PlatformID.youtube, embedURL: EmbedLinks.youtube(id, mute: true),
                author: "YouTube", source: "youtube"
            ), message: nil)
        }
        if let id = vimeoID(text) {
            return Result(entry: MediaEntry(
                kind: .embed, title: "Vimeo", remoteURL: text,
                platform: PlatformID.vimeo, embedURL: EmbedLinks.vimeo(id, mute: true),
                author: "Vimeo", source: "vimeo"
            ), message: nil)
        }
        if let id = dailymotionID(text) {
            return Result(entry: MediaEntry(
                kind: .embed, title: "Dailymotion", remoteURL: text,
                platform: PlatformID.dailymotion, embedURL: EmbedLinks.dailymotion(id, mute: true),
                author: "Dailymotion", source: "dailymotion"
            ), message: nil)
        }
        if lower.contains("archive.org/") {
            return Result(entry: MediaEntry(
                kind: .video, title: url.lastPathComponent, remoteURL: text,
                platform: PlatformID.archive, author: "Internet Archive", source: "archive"
            ), message: nil)
        }
        let path = url.path.lowercased()
        if path.hasSuffix(".mp4") || path.hasSuffix(".mov") || path.hasSuffix(".m4v") || path.hasSuffix(".webm") {
            return Result(entry: MediaEntry(kind: .video, title: url.lastPathComponent, remoteURL: text, platform: PlatformID.url, source: "url"), message: nil)
        }
        if path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") || path.hasSuffix(".png") || path.hasSuffix(".gif") || path.hasSuffix(".webp") || path.hasSuffix(".heic") {
            return Result(entry: MediaEntry(kind: .image, title: url.lastPathComponent, remoteURL: text, coverURL: text, platform: PlatformID.url, source: "url"), message: nil)
        }
        return Result(entry: MediaEntry(
            kind: .embed, title: url.host ?? "网页", remoteURL: text,
            platform: PlatformID.web, embedURL: text, source: "web"
        ), message: nil)
    }

    static func youtubeID(_ text: String) -> String? {
        if let u = URL(string: text), u.host?.contains("youtu.be") == true {
            let id = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        guard let u = URL(string: text), let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return items.first { $0.name == "v" }?.value
    }

    static func vimeoID(_ text: String) -> String? {
        guard text.contains("vimeo.com"), let u = URL(string: text) else { return nil }
        return u.path.split(separator: "/").last.map(String.init).flatMap { Int($0) != nil ? $0 : nil }
    }

    static func dailymotionID(_ text: String) -> String? {
        guard text.contains("dailymotion.com"), let u = URL(string: text) else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "video"), parts.indices.contains(i + 1) { return parts[i + 1] }
        return nil
    }
}
