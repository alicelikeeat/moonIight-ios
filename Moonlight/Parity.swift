import Foundation

/// The 29 ring actions that can wear a photo or a video.
enum ButtonSkinID: String, CaseIterable, Codable, Identifiable, Sendable {
    case fav, mute, play, loop, share, save, post, info
    case random, reshuffle, top, record, compose, settings
    case download, speed, hide, delete
    case like, dislike, comment, filter
    case dwell, backdrop, nextSame, browser
    case appearance, capture, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fav: return "收藏"
        case .mute: return "静音"
        case .play: return "播放"
        case .loop: return "循环"
        case .share: return "分享"
        case .save: return "保存"
        case .post: return "发到朋友圈"
        case .info: return "信息"
        case .random: return "随机一条"
        case .reshuffle: return "重新洗牌"
        case .top: return "回到顶部"
        case .record: return "录屏"
        case .compose: return "发动态"
        case .settings: return "设置"
        case .download: return "下载"
        case .speed: return "倍速"
        case .hide: return "隐藏"
        case .delete: return "删除"
        case .like: return "赞"
        case .dislike: return "踩"
        case .comment: return "评论"
        case .filter: return "筛选"
        case .dwell: return "停留"
        case .backdrop: return "设为背景"
        case .nextSame: return "下一个同源"
        case .browser: return "浏览器打开"
        case .appearance: return "外观"
        case .capture: return "拍摄"
        case .recent: return "最近删除"
        }
    }

    var symbol: String {
        switch self {
        case .fav: return "heart"
        case .mute: return "speaker.slash"
        case .play: return "play"
        case .loop: return "repeat"
        case .share: return "square.and.arrow.up"
        case .save: return "square.and.arrow.down"
        case .post: return "person.2"
        case .info: return "info.circle"
        case .random: return "shuffle"
        case .reshuffle: return "arrow.triangle.2.circlepath"
        case .top: return "arrow.up"
        case .record: return "record.circle"
        case .compose: return "square.and.pencil"
        case .settings: return "gearshape"
        case .download: return "arrow.down.circle"
        case .speed: return "speedometer"
        case .hide: return "eye.slash"
        case .delete: return "trash"
        case .like: return "hand.thumbsup"
        case .dislike: return "hand.thumbsdown"
        case .comment: return "text.bubble"
        case .filter: return "line.3.horizontal.decrease"
        case .dwell: return "timer"
        case .backdrop: return "photo"
        case .nextSame: return "forward.end"
        case .browser: return "safari"
        case .appearance: return "circle.lefthalf.filled"
        case .capture: return "circle.fill"
        case .recent: return "trash"
        }
    }
}

struct ButtonSkin: Codable, Equatable, Sendable {
    var path: String
    var video: Bool
}

enum ButtonSkins {
    static let count = ButtonSkinID.allCases.count

    static func identify(key: String?, title: String) -> ButtonSkinID? {
        if let key, let mapped = keyMap[key] { return mapped }
        return titleMap[title]
    }

    static func resolve(key: String?, title: String, skins: [String: ButtonSkin]) -> (id: ButtonSkinID, skin: ButtonSkin)? {
        guard let id = identify(key: key, title: title), let skin = skins[id.rawValue] else { return nil }
        return (id, skin)
    }

    static func assign(_ ids: [ButtonSkinID], skin: ButtonSkin, into skins: inout [String: ButtonSkin]) {
        for id in ids { skins[id.rawValue] = skin }
    }

    static func assignAll(_ skin: ButtonSkin, into skins: inout [String: ButtonSkin]) {
        assign(ButtonSkinID.allCases, skin: skin, into: &skins)
    }

    static func clear(_ ids: [ButtonSkinID], skins: inout [String: ButtonSkin]) {
        for id in ids { skins.removeValue(forKey: id.rawValue) }
    }

    private static let keyMap: [String: ButtonSkinID] = [
        "fav": .fav, "mute": .mute, "play": .play, "loop": .loop, "share": .share, "save": .save,
        "post": .post, "info": .info, "random": .random, "reshuffle": .reshuffle, "top": .top,
        "record": .record, "compose": .compose, "settings": .settings, "mv_play": .play,
        "mv_mute": .mute, "mv_save": .save, "mv_open": .play,
    ]

    private static let titleMap: [String: ButtonSkinID] = [
        "收藏": .fav, "已收藏": .fav, "取消收藏": .fav,
        "静音": .mute, "打开声音": .mute, "取消静音": .mute,
        "播放": .play, "暂停": .play,
        "循环": .loop, "循环开": .loop, "循环关": .loop, "循环播放": .loop,
        "分享": .share,
        "保存": .save, "保存到相册": .save,
        "发到朋友圈": .post, "发朋友圈": .post,
        "信息": .info, "视频信息": .info,
        "随机一条": .random, "随机一下": .random,
        "重新洗牌": .reshuffle,
        "回到顶部": .top,
        "录屏": .record,
        "发动态": .compose,
        "设置": .settings,
        "下载": .download, "下载到我的下载": .download, "自动缓存": .download,
        "倍速": .speed,
        "隐藏": .hide, "取消隐藏": .hide,
        "删除": .delete,
        "赞": .like,
        "踩": .dislike,
        "评论": .comment,
        "筛选": .filter,
        "停留": .dwell,
        "设为背景": .backdrop,
        "下一个同源": .nextSame,
        "浏览器打开": .browser,
        "外观": .appearance,
        "拍摄": .capture,
        "最近删除": .recent,
    ]
}

enum SkinPlayBudget {
    static let cap = 4

    /// First `cap` distinct ids may play. Later ones stay on a still frame.
    static func playing(_ ids: [String], cap: Int = cap) -> Set<String> {
        var out = Set<String>()
        var ordered: [String] = []
        for id in ids where out.insert(id).inserted {
            ordered.append(id)
            if ordered.count == cap { break }
        }
        return Set(ordered)
    }
}

@MainActor
final class SkinStage {
    static let shared = SkinStage()
    private var holders: [String] = []

    func claim(_ id: String) -> Bool {
        if let index = holders.firstIndex(of: id) { return index < SkinPlayBudget.cap }
        guard holders.count < SkinPlayBudget.cap else { return false }
        holders.append(id)
        return true
    }

    func release(_ id: String) {
        holders.removeAll { $0 == id }
    }
}

enum MomentAutoplay: String, Codable, CaseIterable, Sendable {
    case off, all, picked
    var label: String {
        switch self {
        case .off: return "关闭"
        case .all: return "全部"
        case .picked: return "指定"
        }
    }
}

enum MomentPlay {
    static let cap = 6

    static func allows(mode: MomentAutoplay, momentID: String, picked: Set<String>, already: Int) -> Bool {
        if already >= cap { return false }
        switch mode {
        case .off: return false
        case .all: return true
        case .picked: return picked.contains(momentID)
        }
    }
}

enum TrashKind: String, Codable, Sendable { case entry, moment }

struct TrashItem: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: TrashKind
    var title: String
    var deletedAt: Int64
    var entry: MediaEntry?
    var moment: Moment?
}

enum TrashBin {
    static func shredEntry(_ entry: MediaEntry, into bin: inout [TrashItem], now: Int64) {
        bin.removeAll { $0.kind == .entry && $0.entry?.id == entry.id }
        bin.insert(TrashItem(id: IDs.new(), kind: .entry, title: entry.title, deletedAt: now, entry: entry, moment: nil), at: 0)
    }

    static func shredMoment(_ moment: Moment, into bin: inout [TrashItem], now: Int64) {
        bin.removeAll { $0.kind == .moment && $0.moment?.id == moment.id }
        let title = moment.text.isEmpty ? "一条动态" : moment.text
        bin.insert(TrashItem(id: IDs.new(), kind: .moment, title: title, deletedAt: now, entry: nil, moment: moment), at: 0)
    }

    static func take(_ id: String, from bin: inout [TrashItem]) -> TrashItem? {
        guard let index = bin.firstIndex(where: { $0.id == id }) else { return nil }
        return bin.remove(at: index)
    }
}

enum DownloadLane: String, Codable, Sendable {
    case active, auto
    var listsInLibrary: Bool { self == .active }
}

enum ResumePlan {
    static func request(url: URL, receivedBytes: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if receivedBytes > 0 {
            request.setValue("bytes=\(receivedBytes)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func resumeData(from error: NSError) -> Data? {
        error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }
}

enum TransferRestart: Equatable {
    case full
    case range(Int64)
    case resume

    static func choose(received: Int64, hasResume: Bool, hasPartial: Bool) -> TransferRestart {
        if hasResume { return .resume }
        if received > 0 && hasPartial { return .range(received) }
        return .full
    }
}

enum FileJoin {
    static func append(part: URL, onto dest: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) {
            if fm.fileExists(atPath: part.path) {
                try fm.moveItem(at: part, to: dest)
            }
            return
        }
        let handle = try FileHandle(forWritingTo: dest)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contentsOf: part))
        try handle.close()
        try? fm.removeItem(at: part)
    }
}

enum IconPreset: String, CaseIterable, Identifiable, Sendable {
    case primary, ink, paper, crescent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .primary: return "默认"
        case .ink: return "墨色"
        case .paper: return "素纸"
        case .crescent: return "新月"
        }
    }
    /// nil selects the primary bundle icon.
    var alternateName: String? {
        switch self {
        case .primary: return nil
        case .ink: return "IconInk"
        case .paper: return "IconPaper"
        case .crescent: return "IconCrescent"
        }
    }
}

enum PublicRefresh {
    static func merge(existing: [MediaEntry], incoming: [MediaEntry]) -> [MediaEntry] {
        var seen = Set(existing.compactMap { $0.remoteURL ?? $0.embedURL })
        var out = existing
        for item in incoming {
            let key = item.remoteURL ?? item.embedURL ?? item.id
            if seen.insert(key).inserted { out.append(item) }
        }
        return out
    }

    /// Writes a merged cache when the app model is not in memory yet.
    static func write(_ incoming: [MediaEntry]) {
        let existing: [MediaEntry]
        if let data = AtomicFile.read(Paths.refreshFile),
           let items = try? JSONDecoder().decode([MediaEntry].self, from: data) {
            existing = items
        } else {
            existing = []
        }
        let merged = merge(existing: existing, incoming: incoming)
        if let data = try? JSONEncoder().encode(merged) {
            try? AtomicFile.write(data, to: Paths.refreshFile)
        }
    }
}

struct TransferJob: Codable, Equatable, Sendable {
    var id: String
    var url: String
    var title: String
    var lane: DownloadLane
    var received: Int64 = 0
    var resumeFile: String?
    var partialFile: String?
    var entry: MediaEntry?
    var done: Bool = false
    var error: String?
    var retried: Bool = false
}
