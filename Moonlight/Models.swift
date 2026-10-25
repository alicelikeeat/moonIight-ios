import Foundation

enum MediaKind: String, Codable, Sendable {
    case video, image, embed
}

enum PlatformID {
    static let bili = "bili"
    static let youtube = "youtube"
    static let vimeo = "vimeo"
    static let dailymotion = "dailymotion"
    static let archive = "archive"
    static let nasa = "nasa"
    static let commons = "commons"
    static let peertube = "peertube"
    static let pexels = "pexels"
    static let pixabay = "pixabay"
    static let twitch = "twitch"
    static let web = "web"
    static let local = "local"
    static let url = "url"

    static func label(_ id: String) -> String {
        switch id {
        case bili: return "哔哩"
        case youtube: return "YouTube"
        case vimeo: return "Vimeo"
        case dailymotion: return "Dailymotion"
        case archive: return "Archive"
        case nasa: return "NASA"
        case commons: return "Commons"
        case peertube: return "PeerTube"
        case pexels: return "Pexels"
        case pixabay: return "Pixabay"
        case twitch: return "Twitch"
        case web: return "网页"
        case local: return "本地"
        case url: return "直链"
        default: return id
        }
    }
}

struct MediaEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var kind: MediaKind
    var title: String
    var localPath: String?
    var remoteURL: String?
    var coverURL: String?
    var biliBvid: String?
    var platform: String?
    var embedURL: String?
    /// Direct file the instance allows saving. Never a YouTube or Bilibili stream.
    var downloadURL: String?
    var author: String = ""
    var favorite: Bool = false
    var hidden: Bool = false
    var source: String = "local"
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var dwellSeconds: Int = 0
    /// Per-item pinch override. nil follows the global 视频显示 setting.
    var fillOverride: Bool?
    var byteSize: Int64 = 0

    var isWebEmbed: Bool { kind == .embed }

    var resolvedPlatform: String {
        if let platform, !platform.isEmpty { return platform }
        if kind == .embed || !(biliBvid ?? "").isEmpty { return PlatformID.bili }
        if source == "local" { return PlatformID.local }
        return source.isEmpty ? PlatformID.web : source
    }

    func platformLabel() -> String { PlatformID.label(resolvedPlatform) }

    var playbackURL: URL? {
        if let localPath, FileManager.default.fileExists(atPath: localPath) {
            return URL(fileURLWithPath: localPath)
        }
        if let remoteURL {
            if PublicLink.peertubeVideo(remoteURL) != nil { return nil }
            return URL(string: remoteURL)
        }
        return nil
    }

    var imageURL: URL? {
        if let localPath, kind == .image, FileManager.default.fileExists(atPath: localPath) {
            return URL(fileURLWithPath: localPath)
        }
        if let coverURL { return URL(string: coverURL) }
        if kind == .image, let remoteURL { return URL(string: remoteURL) }
        return nil
    }
}

struct DownloadTask: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var url: String
    var title: String
    var progress: Double = 0
    var error: String?
    var done: Bool = false
    var localPath: String?
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}

struct LibrarySnapshot: Codable, Equatable, Sendable {
    var entries: [MediaEntry] = []
    var downloads: [DownloadTask] = []
}

enum ThemeMode: String, Codable, CaseIterable, Sendable {
    case system, dark, light
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

enum VideoDisplay: String, Codable, CaseIterable, Sendable {
    case smart = "SMART"
    case fit = "FIT"
    case fill = "FILL"
    var label: String {
        switch self {
        case .smart: return "智能"
        case .fit: return "完整显示"
        case .fill: return "铺满"
        }
    }
    var short: String {
        switch self {
        case .smart: return "智能"
        case .fit: return "完整"
        case .fill: return "铺满"
        }
    }
}

enum MenuSelect: String, Codable, CaseIterable, Sendable {
    case drop = "DROP"
    case slider = "SLIDER"
    case tap = "TAP"
    /// Older builds stored drag-to-select as DRAG. Treated as 滑块.
    case drag = "DRAG"

    /// 水滴 is not a picker item. It is the 水滴选择 toggle, off by default.
    static let choices: [MenuSelect] = [.tap, .slider]

    var label: String {
        switch self {
        case .drop: return "水滴"
        case .slider, .drag: return "滑块"
        case .tap: return "点击"
        }
    }

    var followsFinger: Bool { self != .tap }
    var isDrop: Bool { self == .drop }
}

enum MenuBackdrop: String, Codable, CaseIterable, Sendable {
    case clear = "CLEAR"
    case light = "LIGHT"
    case blur = "BLUR"
    var label: String {
        switch self {
        case .clear: return "透明"
        case .light: return "轻度模糊"
        case .blur: return "模糊"
        }
    }
    var blurRadius: Double {
        switch self {
        case .clear: return 0
        case .light: return 5
        case .blur: return 24
        }
    }
    var dim: Double {
        switch self {
        case .clear: return 0
        case .light: return 0.5
        case .blur: return 1
        }
    }
    var labelShadow: Bool { dim < 1 }
}

enum FeedScope: String, CaseIterable, Identifiable {
    case all, local, online
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .local: return "本地"
        case .online: return "在线"
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var theme: ThemeMode = .system
    var videoDisplay: VideoDisplay = .smart
    var menuBackdrop: MenuBackdrop = .blur
    var menuSelect: MenuSelect = .tap
    /// Opt-in. Off: long-press only opens the ring. On: a glass droplet selects on release.
    var dropSelect: Bool = false
    /// Default on: the system tab bar keeps drag-to-switch. Off replaces it with a glass bar and no slider.
    var tabLens: Bool = true
    /// Style name or "RANDOM".
    var ringAnim: String = RingAnim.star.rawValue
    var ringAnimSet: String = RingAnim.choices.map(\.rawValue).joined(separator: ",")
    var pexelsKey: String = ""
    var pixabayKey: String = ""
    var youtubeKey: String = ""
    var peertubeInstance: String = ""
    var follows: [FollowedSource] = []
    var hiddenFollowIDs: [String] = []
    var chatServerURL: String = ""
    var feedMuted: Bool = true
    /// Hide the home-feed buttons while a video plays, then again after the quiet interval.
    var chromeAutoHide: Bool = true
    /// Seconds of quiet before the feed buttons hide again. 1, 2, 3, 5, 10, or a custom value.
    var chromeHideSeconds: Float = 3
    /// Skip home-feed autoplay while Low Power Mode is on.
    var pauseOnLowPower: Bool = true
    /// Skip home-feed autoplay on a cellular / expensive network.
    var autoplayWifiOnly: Bool = false
    var homeBackdropPath: String?
    /// 星轨速度 0.5…2. 慢 0.7 · 标准 1 · 快 1.4.
    var starSpeed: Float = 1
    /// 定时长按. Off by default; the centre 全部按键 panel is its own switch.
    var timedOn: Bool = false
    var timedSeconds: Float = 5
    var timedShowTime: Bool = true
    var timedCountdown: Bool = true
    var timedAutoFire: Bool = true
    /// HoldContext raw value → TimedActions key. Destructive keys are dropped on load.
    var timedAssign: [String: String] = [:]
    var centerPanel: Bool = true
    var buttonSkins: [String: ButtonSkin] = [:]
    var momentAutoplay: MomentAutoplay = .all
    var momentAutoplayIds: [String] = []
    var homeBackdropVideo: Bool = false
    var iconPreset: String = IconPreset.primary.rawValue
    var bgRefreshOn: Bool = true
    var lastRefreshAt: Int64 = 0
    var backdropMode: BackdropMode = .theme
    var backdropPhoto: String?
    var backdropVideo: String?
    var backdropPhotoFocus: MediaFocus = MediaFocus()
    var backdropVideoFocus: MediaFocus = MediaFocus()
    var backdropPhotoBlur: Bool = true
    var backdropVideoBlur: Bool = true
    /// Page ids that show the custom background. 首页 only unless the person adds more.
    var backdropPages: [String] = ["home"]
    /// Home video and page backgrounds may draw under the status bar and Dynamic Island.
    var edgeToEdge: Bool = false
    var sourceFlags: [String: Bool] = [:]
    var webSources: [WebSource] = []
    var biliHotCategory: String = ""
    /// Replay the home-feed video when it ends.
    var feedLoop: Bool = false
    /// Shuffle the home feed instead of newest-first.
    var feedShuffle: Bool = false
    /// How long a photo stays before the next card. 0 is 永久.
    var imageHold: Int = 0
    var rememberPlace: Bool = false
    var feedMemoryID: String = ""
    var feedMemoryIndex: Int = 0
    var feedMemorySeconds: Double = 0
    /// Leave the app pauses everything. Coming back continues only what was playing.
    var resumeOnReturn: Bool = true
    var revealBlur: Bool = true
    var revealSpeed: String = RevealPace.standard.rawValue
    /// Thin progress line while the home feed is immersive.
    var progressLine: Bool = false

    /// Missing keys from older builds keep their defaults instead of wiping the file.
    static func load(_ data: Data) -> AppSettings? {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if obj["backdropPages"] == nil, let legacy = obj["backdropAllPages"] as? Bool {
            obj["backdropPages"] = BackdropPages.migrate(stored: nil, allPages: legacy)
        }
        let focus: [String: Any] = ["x": 0.5, "y": 0.3, "scale": 1.0]
        let defaults: [String: Any] = [
            "theme": "system",
            "videoDisplay": "SMART",
            "menuBackdrop": "BLUR",
            "menuSelect": "TAP",
            "dropSelect": false,
            "tabLens": true,
            "ringAnim": "STAR",
            "ringAnimSet": "SPIN,LOTUS,STAR,MOON",
            "pexelsKey": "",
            "pixabayKey": "",
            "youtubeKey": "",
            "peertubeInstance": "",
            "follows": [Any](),
            "hiddenFollowIDs": [String](),
            "chatServerURL": "",
            "feedMuted": true,
            "chromeAutoHide": true,
            "chromeHideSeconds": 3.0,
            "pauseOnLowPower": true,
            "autoplayWifiOnly": false,
            "starSpeed": 1.0,
            "timedOn": false,
            "timedSeconds": 5.0,
            "timedShowTime": true,
            "timedCountdown": true,
            "timedAutoFire": true,
            "timedAssign": [String: String](),
            "centerPanel": true,
            "buttonSkins": [String: Any](),
            "momentAutoplay": "all",
            "momentAutoplayIds": [String](),
            "homeBackdropVideo": false,
            "iconPreset": "primary",
            "bgRefreshOn": true,
            "lastRefreshAt": 0,
            "backdropMode": "theme",
            "backdropPhotoBlur": true,
            "backdropVideoBlur": true,
            "backdropPages": ["home"],
            "backdropPhotoFocus": focus,
            "backdropVideoFocus": focus,
            "edgeToEdge": false,
            "sourceFlags": [String: Bool](),
            "webSources": [Any](),
            "biliHotCategory": "",
            "feedLoop": false,
            "feedShuffle": false,
            "imageHold": 0,
            "rememberPlace": false,
            "feedMemoryID": "",
            "feedMemoryIndex": 0,
            "feedMemorySeconds": 0.0,
            "resumeOnReturn": true,
            "revealBlur": true,
            "revealSpeed": "standard",
            "progressLine": false,
        ]
        for (key, value) in defaults where obj[key] == nil { obj[key] = value }
        guard JSONSerialization.isValidJSONObject(obj),
              let patched = try? JSONSerialization.data(withJSONObject: obj),
              var decoded = try? JSONDecoder().decode(AppSettings.self, from: patched) else { return nil }
        decoded.starSpeed = RingMotion.clampSpeed(decoded.starSpeed)
        decoded.chromeHideSeconds = ChromeTiming.clamp(decoded.chromeHideSeconds)
        if decoded.menuSelect == .drop {
            decoded.menuSelect = .tap
            decoded.dropSelect = true
        }
        if decoded.menuSelect == .drag { decoded.menuSelect = .slider }
        decoded.timedSeconds = HoldConfig.clampSeconds(decoded.timedSeconds)
        decoded.timedAssign = TimedActions.sanitize(decoded.timedAssign)
        decoded.backdropPages = BackdropPages.normalize(decoded.backdropPages)
        decoded.imageHold = ImageHold.seconds(decoded.imageHold)
        if RevealPace(rawValue: decoded.revealSpeed) == nil { decoded.revealSpeed = RevealPace.standard.rawValue }
        return decoded
    }
}

enum RingAnim: String, Codable, CaseIterable, Sendable {
    case spin = "SPIN"
    case lotus = "LOTUS"
    case star = "STAR"
    case moon = "MOON"
    case fade = "FADE"

    var label: String {
        switch self {
        case .spin: return "旋转展开"
        case .lotus: return "荷花"
        case .star: return "星轨"
        case .moon: return "月光"
        case .fade: return "淡入淡出"
        }
    }
    var short: String {
        switch self {
        case .spin: return "旋转"
        case .lotus: return "荷花"
        case .star: return "星轨"
        case .moon: return "月光"
        case .fade: return "淡入"
        }
    }
    var hint: String {
        switch self {
        case .spin: return "按钮像气泡一样弹进圆环，略微过冲后停在原大"
        case .lotus: return "每个按钮从花苞中绽放，收起时合拢下沉"
        case .star: return "按钮从远处沿弧线绕着手指飞来，越来越近，落入圆环"
        case .moon: return "全屏暗下，只有按钮被月光照亮（忽略菜单背景）"
        case .fade: return "系统已关闭动画时使用"
        }
    }

    static let choices: [RingAnim] = [.spin, .lotus, .star, .moon]
    static let random = "RANDOM"
    private static let legacy: [String: RingAnim] = ["BLUR": .star, "FALL": .star, "SHATTER": .lotus]

    static func of(_ raw: String?) -> RingAnim {
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let mapped = legacy[key] { return mapped }
        if let match = RingAnim(rawValue: key), match != .fade { return match }
        return .spin
    }

    static func parse(_ raw: String?) -> RingAnim? {
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let mapped = legacy[key] { return mapped }
        if let match = RingAnim(rawValue: key), match != .fade { return match }
        return nil
    }
}

enum RingAnimPick {
    static func normalize(_ raw: String?) -> String {
        if raw == RingAnim.random { return RingAnim.random }
        return RingAnim.of(raw).rawValue
    }

    static func parseSet(_ csv: String?) -> Set<RingAnim> {
        let set = Set((csv ?? "").split(separator: ",").compactMap { RingAnim.parse(String($0)) })
        return set.isEmpty ? Set(RingAnim.choices) : set
    }

    static func encodeSet(_ set: Set<RingAnim>) -> String {
        RingAnim.choices.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }

    static func pick(setting: String?, enabled: Set<RingAnim>, animatorScale: Float, rnd: () -> Int = { Int.random(in: 0...0x7fffffff) }) -> RingAnim {
        if animatorScale <= 0 { return .fade }
        if setting != RingAnim.random { return RingAnim.of(setting) }
        let pool = RingAnim.choices.filter { enabled.contains($0) }
        let use = pool.isEmpty ? RingAnim.choices : pool
        let n = use.count
        let i = abs(rnd()) % n
        return use[i]
    }
}
