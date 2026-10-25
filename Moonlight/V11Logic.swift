import Foundation

enum BackdropMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case theme, black, photo, video
    var id: String { rawValue }
    var label: String {
        switch self {
        case .theme: return "跟随主题"
        case .black: return "纯黑"
        case .photo: return "照片"
        case .video: return "视频"
        }
    }
}

enum BackdropPage: String, Codable, CaseIterable, Identifiable, Sendable {
    case home, discover, moments, chat, me, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home: return "首页"
        case .discover: return "发现"
        case .moments: return "朋友圈"
        case .chat: return "消息"
        case .me: return "我"
        case .settings: return "设置"
        }
    }
}

enum BackdropPages {
    static let homeOnly = ["home"]

    /// `backdropAllPages == true` becomes every page. `false` becomes 首页 only.
    /// An explicit `backdropPages` list wins over the old boolean.
    static func migrate(stored: [String]?, allPages: Bool?) -> [String] {
        if let stored { return normalize(stored) }
        if let allPages { return allPages ? BackdropPage.allCases.map(\.rawValue) : homeOnly }
        return homeOnly
    }

    static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return BackdropPage.allCases.map(\.rawValue).filter { raw.contains($0) && seen.insert($0).inserted }
    }

    static func summary(_ pages: [String]) -> String {
        let set = Set(normalize(pages))
        if set.isEmpty { return "未选择" }
        if set == Set(BackdropPage.allCases.map(\.rawValue)) { return "全部页面" }
        if set == Set(homeOnly) { return "仅首页" }
        return BackdropPage.allCases.filter { set.contains($0.rawValue) }.map(\.label).joined(separator: "、")
    }

    static func shows(_ page: BackdropPage, mode: BackdropMode, pages: [String]) -> Bool {
        guard mode != .theme else { return false }
        return normalize(pages).contains(page.rawValue)
    }

    static func selectAll() -> [String] { BackdropPage.allCases.map(\.rawValue) }
    static func selectHome() -> [String] { homeOnly }
}

enum FeedPlace {
    /// Saved id wins. A stale index is clamped. Remembering off always starts at the top.
    static func index(enabled: Bool, savedID: String, savedIndex: Int, ids: [String]) -> Int {
        guard enabled, !ids.isEmpty else { return 0 }
        if !savedID.isEmpty, let found = ids.firstIndex(of: savedID) { return found }
        if savedIndex >= 0, savedIndex < ids.count { return savedIndex }
        return 0
    }
}

enum ImageHold {
    static let choices: [(Int, String)] = [(0, "永久"), (3, "3 秒"), (5, "5 秒"), (10, "10 秒"), (15, "15 秒"), (30, "30 秒")]
    static func label(_ seconds: Int) -> String {
        choices.first { $0.0 == seconds }?.1 ?? (seconds <= 0 ? "永久" : "\(seconds) 秒")
    }
    static func seconds(_ stored: Int) -> Int { stored <= 0 ? 0 : stored }
}

enum RevealPace: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast, standard, slow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fast: return "快"
        case .standard: return "标准"
        case .slow: return "慢"
        }
    }
    var seconds: Double {
        switch self {
        case .fast: return 0.22
        case .standard: return 0.48
        case .slow: return 0.9
        }
    }
    static func of(_ raw: String) -> RevealPace { RevealPace(rawValue: raw) ?? .standard }
}

enum FanAim {
    /// Same rule as the ring: a tap-mode menu stays open on release. 水滴 and 滑块 fire on release.
    static func firesOnRelease(select: MenuSelect, drop: Bool) -> Bool {
        drop || select == .slider || select == .drag || select == .drop
    }
}

enum SourceCatalog {
    static let rows: [(key: String, title: String, subtitle: String)] = [
        ("bili", "哔哩哔哩", "只嵌入官方播放页"),
        ("biliHot", "哔哩热榜", "公开热门，不签名"),
        ("youtube", "YouTube", "官方播放器或 RSS"),
        ("vimeo", "Vimeo", "官方播放器"),
        ("dailymotion", "Dailymotion", "官方播放器"),
        ("archive", "Archive.org", "公开影像"),
        ("nasa", "NASA", "公开影像"),
        ("peertube", "PeerTube", "实例公开接口"),
        ("commons", "维基共享资源", "公开文件"),
        ("podcast", "播客 / RSS", "公开订阅"),
        ("web", "网址源", "遵守 robots.txt"),
    ]

    static func flag(for platform: String) -> String? {
        switch platform {
        case PlatformID.bili: return "bili"
        case PlatformID.youtube: return "youtube"
        case PlatformID.vimeo: return "vimeo"
        case PlatformID.dailymotion: return "dailymotion"
        case PlatformID.archive: return "archive"
        case PlatformID.nasa: return "nasa"
        case PlatformID.peertube: return "peertube"
        case PlatformID.commons: return "commons"
        case PlatformID.web: return "web"
        default: return nil
        }
    }
}

extension AppSettings {
    func sourceOn(_ key: String) -> Bool { sourceFlags[key] ?? true }

    mutating func setSource(_ key: String, _ on: Bool) { sourceFlags[key] = on }

    var reveal: RevealPace { RevealPace.of(revealSpeed) }

    func showsBackdrop(_ page: BackdropPage) -> Bool {
        BackdropPages.shows(page, mode: backdropMode, pages: backdropPages)
    }
}

struct WebSource: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var url: String
    var title: String = ""
}

enum RobotsRule {
    static func allowed(robots: String, path: String) -> Bool {
        let lines = robots.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        var inStar = false
        var disallows: [String] = []
        var allows: [String] = []
        for line in lines {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("user-agent:") {
                let agent = String(line.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                inStar = agent == "*"
                continue
            }
            guard inStar else { continue }
            if lower.hasPrefix("disallow:") {
                let value = ruleValue(line)
                if !value.isEmpty { disallows.append(value) }
            } else if lower.hasPrefix("allow:") {
                let value = ruleValue(line)
                if !value.isEmpty { allows.append(value) }
            }
        }
        let allowLen = allows.filter { path.hasPrefix($0) }.map(\.count).max() ?? -1
        let denyLen = disallows.filter { path.hasPrefix($0) }.map(\.count).max() ?? -1
        if denyLen < 0 { return true }
        return allowLen > denyLen
    }

    private static func ruleValue(_ line: String) -> String {
        String(line.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
    }
}

enum PageMedia {
    static func entries(html: String, page: URL) -> [MediaEntry] {
        var found: [(url: URL, video: Bool)] = []
        func add(_ raw: String?, video: Bool) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("data:"), !trimmed.hasPrefix("javascript:") else { return }
            guard let url = URL(string: trimmed, relativeTo: page)?.absoluteURL, url.scheme == "http" || url.scheme == "https" else { return }
            if found.contains(where: { $0.url == url }) { return }
            found.append((url, video))
        }
        for kind in ["og:video", "og:video:url", "twitter:player"] {
            add(meta(html, kind), video: true)
        }
        add(meta(html, "og:image"), video: false)
        for src in matches(html, #"<video[^>]+src=["']([^"']+)["']"#) { add(src, video: true) }
        for src in matches(html, #"<source[^>]+src=["']([^"']+)["']"#) { add(src, video: true) }
        for src in matches(html, #"<img[^>]+src=["']([^"']+)["']"#) {
            let lower = src.lowercased()
            if lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png") || lower.contains(".webp") || lower.contains(".gif") {
                add(src, video: false)
            }
        }
        return found.prefix(8).map { item in
            if let known = PublicLink.media(item.url.absoluteString) { return known }
            return MediaEntry(
                kind: item.video ? .video : .image,
                title: page.host ?? "网页",
                remoteURL: item.url.absoluteString,
                platform: PlatformID.web,
                author: page.host ?? "",
                source: "web"
            )
        }
    }

    private static func meta(_ html: String, _ property: String) -> String? {
        let pattern = #"<meta[^>]+(?:property|name)=["']"# + NSRegularExpression.escapedPattern(for: property) + #"["'][^>]+content=["']([^"']+)["']"#
        if let value = matches(html, pattern).first { return value }
        let swapped = #"<meta[^>]+content=["']([^"']+)["'][^>]+(?:property|name)=["']"# + NSRegularExpression.escapedPattern(for: property) + #"["']"#
        return matches(html, swapped).first
    }

    private static func matches(_ text: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}

enum BiliHot {
    static let unavailable = "热榜暂时无法获取"

    static func parse(_ data: Data) -> Result<[MediaEntry], String> {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failure(unavailable) }
        let code = (obj["code"] as? NSNumber)?.intValue ?? (obj["code"] as? Int ?? -1)
        guard code == 0 else { return .failure(unavailable) }
        let dataObj = obj["data"] as? [String: Any]
        let list = (dataObj?["list"] as? [[String: Any]]) ?? (obj["data"] as? [[String: Any]]) ?? []
        let items = list.compactMap(entry)
        if items.isEmpty { return .failure(unavailable) }
        return .success(items)
    }

    static func entry(_ object: [String: Any]) -> MediaEntry? {
        let bvid = (object["bvid"] as? String) ?? ""
        guard bvid.hasPrefix("BV"), bvid.count >= 6 else { return nil }
        let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = object["owner"] as? [String: Any]
        let author = (owner?["name"] as? String) ?? "哔哩哔哩"
        let stat = object["stat"] as? [String: Any]
        let views = (stat?["view"] as? NSNumber)?.intValue ?? (stat?["view"] as? Int ?? 0)
        let cover = object["pic"] as? String
        return MediaEntry(
            id: "bv-\(bvid)",
            kind: .embed,
            title: (title?.isEmpty == false) ? title! : bvid,
            remoteURL: "https://www.bilibili.com/video/\(bvid)",
            coverURL: cover,
            biliBvid: bvid,
            platform: PlatformID.bili,
            embedURL: BiliLinks.player(bvid: bvid),
            author: views > 0 ? "\(author) · \(viewsLabel(views))" : author,
            source: "bili-hot"
        )
    }

    static func viewsLabel(_ views: Int) -> String {
        if views >= 100_000_000 { return String(format: "%.1f亿播放", Double(views) / 100_000_000) }
        if views >= 10_000 { return String(format: "%.1f万播放", Double(views) / 10_000) }
        return "\(views)播放"
    }

    static func load() async -> Result<[MediaEntry], String> {
        let urls = [
            "https://api.bilibili.com/x/web-interface/popular?ps=20&pn=1",
            "https://api.bilibili.com/x/web-interface/ranking/v2?rid=0&type=all",
        ]
        var sawError = false
        for raw in urls {
            guard let url = URL(string: raw), let data = await HTTP.get(url) else { continue }
            switch parse(data) {
            case .success(let items) where !items.isEmpty:
                return .success(items)
            default:
                sawError = true
            }
        }
        return .failure(sawError ? unavailable : unavailable)
    }
}
