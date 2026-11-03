import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Map editor sub-modes (task E). Free edit uses the creative-mode rules
/// (whole map, no resource cost, protected story areas still refused);
/// character build uses the adventure rules (cells within 4 of the player,
/// resources spent). Gameplay simulation is paused in both.
enum RPGEditorMode: String, CaseIterable, Sendable {
    case free, character
    var title: String { self == .free ? "自由编辑" : "角色建造" }
    var gameMode: RPGGameMode { self == .free ? .creative : .adventure }
}

/// Saving status shown in the editor toolbar.
enum RPGSaveState: Equatable, Sendable {
    case saved, saving, unsaved, failed(String)
    var title: String {
        switch self {
        case .saved: "已保存"
        case .saving: "保存中…"
        case .unsaved: "未保存"
        case .failed: "保存失败"
        }
    }
}

enum RPGCameraRules {
    static let cell: CGFloat = 24
    static let minZoom: CGFloat = 0.6
    static let maxZoom: CGFloat = 2.2
    static var worldSide: CGFloat { CGFloat(WorldGeometry.width) * cell }

    /// Camera scale (SKCameraNode scale: larger shows more of the map).
    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(maxZoom, max(minZoom, zoom))
    }

    /// Keeps the camera centre on the map.
    static func clampCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(worldSide, max(0, point.x.isFinite ? point.x : 0)), y: min(worldSide, max(0, point.y.isFinite ? point.y : 0)))
    }

    /// The map cell under a scene point, or nil off the map.
    static func cell(at point: CGPoint) -> SurfacePoint? {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 else { return nil }
        let cell = SurfacePoint(x: Int(point.x / Self.cell), z: Int(point.y / Self.cell))
        return cell.valid ? cell : nil
    }

    /// Chunk ring loaded around the focus: zoomed out shows more of the map.
    static func chunkRadius(zoom: CGFloat) -> Int { zoom > 1.3 ? 2 : 1 }

    /// A one-finger drag pans the map only after it has moved this far, so
    /// a small wobble during a tap still selects the cell.
    static let panSlop: CGFloat = 8

    /// Scene translation for a finger moving `delta` view points (y down)
    /// at camera scale `zoom`: the map follows the finger.
    static func panTranslation(viewDelta delta: CGPoint, zoom: CGFloat) -> CGPoint {
        CGPoint(x: -delta.x * zoom, y: delta.y * zoom)
    }
}
