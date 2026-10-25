import Foundation

/// Where a 定时长按 was held. Each context has its own assignable action.
enum HoldContext: String, Codable, CaseIterable, Equatable, Sendable {
    case feedItem = "FEED_ITEM"
    case tab = "TAB"
    case momentVideo = "MOMENT_VIDEO"
    case player = "PLAYER"

    var label: String {
        switch self {
        case .feedItem: return "首页内容"
        case .tab: return "底部标签"
        case .momentVideo: return "朋友圈视频"
        case .player: return "播放页"
        }
    }
}

enum HoldTier: Equatable, Sendable { case none, timed, center }
enum HoldOutcome: Equatable, Sendable { case tap, long, timed, center, cancelled }

enum HoldEvent: Equatable, Sendable {
    case long
    /// Timed threshold. `fireKey` is nil when nothing assignable should run.
    case timed(HoldContext?, String?, Bool)
    case center
    case cancelled
}

struct HoldConfig: Equatable, Sendable {
    var longMs: Int64 = 500
    var timedOn: Bool = false
    var timedMs: Int64 = 5000
    var autoFire: Bool = true
    var centerOn: Bool = true
    var centerMs: Int64 = 5000
    /// Diameter of the centre circle as a fraction of the short screen side.
    var centerFrac: Float = 0.30
    var slopPx: Float = 24

    static func clampSeconds(_ value: Float) -> Float { min(15, max(3, value)) }

    /// Seconds → milliseconds, clamped to 3…15s, then at least longMs + 500.
    static func timedMs(seconds: Float, longMs: Int64 = 500) -> Int64 {
        let raw = Int64(clampSeconds(seconds) * 1000)
        return max(raw, longMs + 500)
    }

    static func from(_ settings: AppSettings, slopPx: Float = 24, longMs: Int64 = 500) -> HoldConfig {
        HoldConfig(
            longMs: longMs,
            timedOn: settings.timedOn,
            timedMs: timedMs(seconds: settings.timedSeconds, longMs: longMs),
            autoFire: settings.timedAutoFire,
            centerOn: settings.centerPanel,
            slopPx: slopPx
        )
    }
}

/// Third gesture tier. Tap, long-press, timed auto-fire, and the centre 全部按键 hold.
final class HoldMachine {
    enum Phase: Equatable { case idle, pressed, long, fired, cancelled }

    var cfg: HoldConfig
    private(set) var phase: Phase = .idle
    private var downAt: Int64 = 0
    private var ox: Float = 0
    private var oy: Float = 0
    private var w: Float = 0
    private var h: Float = 0
    private(set) var context: HoldContext?
    private var assigned: String?
    private(set) var deferred = false
    private(set) var firedTier: HoldTier = .none

    init(cfg: HoldConfig = HoldConfig()) { self.cfg = cfg }

    func down(_ t: Int64, _ x: Float, _ y: Float, _ width: Float, _ height: Float) {
        phase = .pressed
        downAt = t
        ox = x
        oy = y
        w = width
        h = height
        context = nil
        assigned = nil
        deferred = false
        firedTier = .none
    }

    /// This press opened a ring, or registered a deferred one (朋友圈 video).
    func ring(_ ctx: HoldContext?, _ assignedKey: String?, deferred: Bool = false) {
        guard phase == .pressed || phase == .long else { return }
        if context != nil && !deferred && self.deferred { return }
        context = ctx
        if let ctx, let assignedKey, TimedActions.assignable(ctx, assignedKey) {
            assigned = assignedKey
        } else {
            assigned = nil
        }
        self.deferred = deferred
    }

    var inCenter: Bool {
        let r = min(w, h) * cfg.centerFrac / 2
        let dx = ox - w / 2
        let dy = oy - h / 2
        return w > 0 && h > 0 && dx * dx + dy * dy <= r * r
    }

    static func inCenter(x: Float, y: Float, width: Float, height: Float, frac: Float = 0.30) -> Bool {
        let r = min(width, height) * frac / 2
        let dx = x - width / 2
        let dy = y - height / 2
        return width > 0 && height > 0 && dx * dx + dy * dy <= r * r
    }

    func tier() -> HoldTier {
        if cfg.centerOn && inCenter { return .center }
        if cfg.timedOn && context != nil { return .timed }
        return .none
    }

    func targetMs() -> Int64 {
        switch tier() {
        case .center: return cfg.centerMs
        case .timed: return cfg.timedMs
        case .none: return Int64.max
        }
    }

    func elapsed(_ t: Int64) -> Int64 {
        if phase == .idle { return 0 }
        return max(0, t - downAt)
    }

    /// Countdown fill 0…1 from the normal long-press to the threshold.
    func progress(_ t: Int64) -> Float {
        let tg = targetMs()
        if tg == Int64.max { return 0 }
        let denom = max(Int64(1), tg - cfg.longMs)
        let raw = Float(elapsed(t) - cfg.longMs) / Float(denom)
        return min(1, max(0, raw))
    }

    var showing: Bool { phase == .long && tier() != .none }

    func move(_ x: Float, _ y: Float) -> HoldEvent? {
        guard phase == .pressed || phase == .long else { return nil }
        let dx = x - ox
        let dy = y - oy
        if dx * dx + dy * dy > cfg.slopPx * cfg.slopPx {
            phase = .cancelled
            return .cancelled
        }
        return nil
    }

    func tick(_ t: Int64) -> HoldEvent? {
        let e = elapsed(t)
        if phase == .pressed && e >= cfg.longMs {
            phase = .long
            return .long
        }
        guard phase == .long else { return nil }
        switch tier() {
        case .center:
            if e >= cfg.centerMs {
                phase = .fired
                firedTier = .center
                return .center
            }
            return nil
        case .timed:
            if e >= cfg.timedMs {
                phase = .fired
                firedTier = .timed
                return .timed(context, cfg.autoFire ? assigned : nil, deferred)
            }
            return nil
        case .none:
            return nil
        }
    }

    func up(_ t: Int64) -> HoldOutcome {
        _ = tick(t)
        let out: HoldOutcome
        switch phase {
        case .idle, .pressed: out = .tap
        case .long: out = .long
        case .fired: out = firedTier == .center ? .center : .timed
        case .cancelled: out = .cancelled
        }
        phase = .idle
        return out
    }
}

struct TimedOption: Equatable, Identifiable, Sendable {
    var key: String
    var label: String
    var reversible: Bool
    var titles: Set<String>
    var id: String { key }
}

enum TimedActions {
    static let byContext: [HoldContext: [TimedOption]] = [
        .feedItem: [
            opt("fav", "收藏 / 取消收藏", true, "收藏", "取消收藏", "已收藏"),
            opt("mute", "静音", true, "静音", "打开声音", "取消静音"),
            opt("play", "播放 / 暂停", true, "播放", "暂停"),
            opt("loop", "循环播放", true, "循环播放", "循环开", "循环关"),
            opt("share", "分享", false, "分享"),
            opt("save", "保存到相册", false, "保存到相册", "保存"),
            opt("post", "发到朋友圈", false, "发到朋友圈"),
            opt("info", "视频信息", false, "视频信息", "信息"),
        ],
        .tab: [
            opt("random", "随机一条", false, "随机一条", "随机一下"),
            opt("reshuffle", "重新洗牌", false, "重新洗牌"),
            opt("top", "回到顶部", false, "回到顶部"),
            opt("record", "录屏", false, "录屏"),
            opt("compose", "发动态", false, "发动态"),
            opt("settings", "设置", false, "设置"),
        ],
        .momentVideo: [
            opt("mv_play", "播放 / 暂停", true, "播放", "暂停"),
            opt("mv_mute", "静音 / 打开声音", true, "静音", "打开声音"),
            opt("mv_open", "进入播放页面", false, "进入播放页面"),
            opt("mv_save", "保存到相册", false, "保存到相册", "保存"),
        ],
        .player: [
            opt("fav", "收藏", true, "收藏", "已收藏"),
            opt("mute", "静音 / 打开声音", true, "静音", "打开声音"),
            opt("share", "分享", false, "分享"),
            opt("save", "保存到相册", false, "保存到相册"),
            opt("random", "随机一条", false, "随机一条"),
            opt("record", "录屏", false, "录屏"),
        ],
    ]

    static func options(_ context: HoldContext) -> [TimedOption] { byContext[context] ?? [] }

    static func assignable(_ context: HoldContext, _ key: String) -> Bool {
        options(context).contains { $0.key == key }
    }

    static func option(_ context: HoldContext, _ key: String?) -> TimedOption? {
        guard let key else { return nil }
        return options(context).first { $0.key == key }
    }

    /// Drops stored keys that are missing or not assignable, including anything destructive.
    static func sanitize(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, key) in raw {
            guard let context = HoldContext(rawValue: name), assignable(context, key) else { continue }
            out[name] = key
        }
        return out
    }

    /// The leaf this timed hold may run. Parents, destructive, and disabled actions are skipped.
    static func resolve(items: [RingItem], groups: [MenuGroup], context: HoldContext?, key: String?) -> RingItem? {
        guard let context, let key, let opt = option(context, key) else { return nil }
        return leaves(items: items, groups: groups).first { item in
            item.children.isEmpty && !item.destructive && item.enabled &&
                (item.key == key || opt.titles.contains(item.title))
        }
    }

    static func leaves(items: [RingItem], groups: [MenuGroup]) -> [RingItem] {
        var out: [RingItem] = []
        func walk(_ item: RingItem) {
            if item.children.isEmpty { out.append(item) }
            else { item.children.forEach(walk) }
        }
        items.forEach(walk)
        groups.forEach { $0.items.forEach(walk) }
        return out
    }

    private static func opt(_ key: String, _ label: String, _ reversible: Bool, _ titles: String...) -> TimedOption {
        TimedOption(key: key, label: label, reversible: reversible, titles: Set(titles))
    }
}

enum PanelFlatten {
    /// Parents with children become 「父 · 子」 tiles. Titles are de-duplicated.
    static func tiles(items: [RingItem], groups: [MenuGroup]) -> [RingItem] {
        var out: [RingItem] = []
        var seen = Set<String>()
        func add(_ item: RingItem, titled: String, destructive: Bool) {
            guard seen.insert(titled).inserted else { return }
            var copy = item
            copy.title = titled
            copy.children = []
            if destructive { copy.destructive = true }
            out.append(copy)
        }
        func walk(_ item: RingItem, destructive: Bool) {
            if item.children.isEmpty {
                add(item, titled: item.title, destructive: destructive || item.destructive)
            } else {
                for child in item.children {
                    add(child, titled: "\(item.title) · \(child.title)", destructive: destructive || child.destructive)
                }
            }
        }
        items.forEach { walk($0, destructive: false) }
        for group in groups {
            group.items.forEach { walk($0, destructive: group.danger) }
        }
        return out
    }
}
