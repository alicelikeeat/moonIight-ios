import Foundation

// Shared by the app and the widget extension (and the domain tests): the
// deep links a widget opens, the world snapshot the app leaves for it, and
// where that snapshot lives. Plain Foundation only.

/// `moonlight://<host>` links. Every widget tap is one of these, so the
/// shortcuts work even when the App Group (and with it the status) is not
/// available after re-signing.
enum MoonlightLink: String, CaseIterable, Sendable {
    case sandbox
    case world3D = "world3d"
    case camera
    case search

    static let scheme = "moonlight"

    var url: URL { URL(string: Self.scheme + "://" + rawValue)! }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let host = url.host?.lowercased(), let link = Self(rawValue: host) else { return nil }
        self = link
    }

    var title: String {
        switch self {
        case .sandbox: "沙盒"
        case .world3D: "3D 世界"
        case .camera: "拍摄"
        case .search: "搜索"
        }
    }

    var symbol: String {
        switch self {
        case .sandbox: "cube.transparent"
        case .world3D: "view.3d"
        case .camera: "camera.fill"
        case .search: "magnifyingglass"
        }
    }
}

/// What the widget shows about the world, written by the app after a save.
struct MoonlightWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchema = 1
    var schema = Self.currentSchema
    var worldTitle: String
    var health: Int
    var stamina: Int
    var shards: Int
    var blocks: Int
    var revision: Int
    var savedAt: Date
    /// Top-down minimap around the player, row-major from the north edge;
    /// 0 is open ground, anything else is 0xRRGGBB + 1.
    var mapSide: Int
    var map: [UInt32]

    var valid: Bool {
        schema == Self.currentSchema && !worldTitle.isEmpty && worldTitle.count <= 80 &&
            (0...100).contains(health) && (0...100).contains(stamina) && shards >= 0 && blocks >= 0 && revision >= 0 &&
            (0...MoonlightMinimap.maximumSide).contains(mapSide) && map.count == mapSide * mapSide
    }
}

/// One cell for the minimap: a block's map position, top height and colour.
struct MoonlightMinimapCell: Sendable {
    var x: Int
    var y: Int
    var top: Double
    var rgb: UInt32
}

enum MoonlightMinimap {
    static let side = 24
    static let maximumSide = 48

    /// The highest block per cell in a `side`-wide square centred on the
    /// player; north (larger y) is the first row.
    static func build(_ cells: [MoonlightMinimapCell], centerX: Int, centerY: Int, side: Int = Self.side) -> [UInt32] {
        let side = max(1, min(maximumSide, side))
        let half = side / 2
        var map = [UInt32](repeating: 0, count: side * side)
        var heights = [Double](repeating: -.infinity, count: side * side)
        for cell in cells {
            let column = cell.x - (centerX - half)
            let row = (centerY + half - 1) - cell.y
            guard (0..<side).contains(column), (0..<side).contains(row) else { continue }
            let index = row * side + column
            if cell.top > heights[index] {
                heights[index] = cell.top
                map[index] = (cell.rgb & 0xFFFFFF) + 1
            }
        }
        return map
    }

    /// "F1EEE8" → 0xF1EEE8; clear glass (nil or unreadable) is a pale glass tone.
    static func rgb(hex: String?) -> UInt32 {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return 0xDCEBF5 }
        return value
    }
}

/// The snapshot file in the shared App Group container.
enum MoonlightWidgetStore {
    static let appGroup = "group.com.moonlight.feed"
    static let fileName = "widget-snapshot.json"
    /// Widget kinds, for targeted timeline reloads.
    static let statusKind = "MoonlightWorldStatus"
    static let shortcutsKind = "MoonlightShortcuts"

    /// nil when the App Group entitlement did not survive signing.
    static var containerURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }

    static func encode(_ snapshot: MoonlightWidgetSnapshot) -> Data? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(snapshot)
    }

    static func decode(_ data: Data?) -> MoonlightWidgetSnapshot? {
        guard let data else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(MoonlightWidgetSnapshot.self, from: data), snapshot.valid else { return nil }
        return snapshot
    }

    @discardableResult
    static func write(_ snapshot: MoonlightWidgetSnapshot) -> Bool {
        guard snapshot.valid, let folder = containerURL, let data = encode(snapshot) else { return false }
        return (try? data.write(to: folder.appendingPathComponent(fileName), options: .atomic)) != nil
    }

    static func read() -> MoonlightWidgetSnapshot? {
        guard let folder = containerURL else { return nil }
        return decode(try? Data(contentsOf: folder.appendingPathComponent(fileName)))
    }
}
