import Foundation

enum TreasureTargetKind: String, Codable, CaseIterable, Identifiable {
    case library, single, favorites, queue, folder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: "媒体库"; case .single: "单个媒体"; case .favorites: "收藏集"
        case .queue: "播放队列"; case .folder: "文件夹播放列表"
        }
    }
}
enum TreasureSound: String, Codable, CaseIterable, Identifiable {
    case original, muted
    var id: String { rawValue }
    var title: String { self == .original ? "原视频声音" : "静音" }
}
enum TreasureBackground: String, Codable, CaseIterable, Identifiable {
    case system, solid, purple
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .solid: "自定义纯色"; case .purple: "黑紫主题" }
    }
}
struct TreasurePlaybackOptions: Codable, Equatable {
    var target = TreasureTargetKind.library
    var startID = ""
    var folderID = ""
    var count = 1
    var autoPlay = true
    var autoPlayOnReturn = false
    var confirmed = false
    var sound = TreasureSound.original
    var volume = 100.0
    var imageSeconds = 5.0
    var background = TreasureBackground.system
    var red = 0.08
    var green = 0.08
    var blue = 0.12

    static func load(_ data: Data) -> Self {
        guard var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        value.count = min(10, max(1, value.count))
        value.volume = value.volume.isFinite ? min(100, max(0, value.volume)) : 100
        value.imageSeconds = value.imageSeconds.isFinite ? min(30, max(1, value.imageSeconds)) : 5
        value.red = min(1, max(0, value.red)); value.green = min(1, max(0, value.green)); value.blue = min(1, max(0, value.blue))
        return value
    }
}
enum TreasurePlaybackPlan {
    /// Snapshot stable IDs; search only chooses the start, never truncates the
    /// original list context. Reaching the tail never wraps or duplicates IDs.
    static func ids(in source: [String], startingAt id: String, count: Int, single: Bool = false) -> [String] {
        let ordered = TreasureRules.unique(source, id: \.self)
        guard let start = ordered.firstIndex(of: id) else { return [] }
        return Array(ordered.dropFirst(start).prefix(single ? 1 : min(10, max(1, count))))
    }
}
