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
    var title: String { self == .free ? L10n.t("自由编辑", "Free Edit") : L10n.t("角色建造", "Character Build") }
    var gameMode: RPGGameMode { self == .free ? .creative : .adventure }
}

/// Saving status shown in the editor toolbar.
enum RPGSaveState: Equatable, Sendable {
    case saved, saving, unsaved, failed(String)
    var title: String {
        switch self {
        case .saved: L10n.t("已保存", "Saved")
        case .saving: L10n.t("保存中…", "Saving…")
        case .unsaved: L10n.t("未保存", "Unsaved")
        case .failed: L10n.t("保存失败", "Save failed")
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

    /// Chunks covering the visible map plus a margin, nearest first, so a
    /// wide landscape screen never shows unloaded ground at its edges.
    static func chunks(center: CGPoint, viewSize: CGSize, zoom: CGFloat, margin: CGFloat = cell * 8) -> [ChunkCoordinate] {
        guard viewSize.width > 0, viewSize.height > 0, center.x.isFinite, center.y.isFinite else { return [] }
        let halfWidth = viewSize.width * clampZoom(zoom) / 2 + margin, halfHeight = viewSize.height * clampZoom(zoom) / 2 + margin
        let chunkSide = cell * CGFloat(WorldGeometry.chunkSide)
        func index(_ value: CGFloat) -> Int { min(WorldGeometry.chunkColumns - 1, max(0, Int((value / chunkSide).rounded(.down)))) }
        let xs = index(center.x - halfWidth)...index(center.x + halfWidth), zs = index(center.y - halfHeight)...index(center.y + halfHeight)
        let middle = (x: center.x / chunkSide, z: center.y / chunkSide)
        return zs.flatMap { z in xs.map { ChunkCoordinate(x: $0, z: z) } }.sorted { a, b in
            let da = hypot(CGFloat(a.x) + 0.5 - middle.x, CGFloat(a.z) + 0.5 - middle.z), db = hypot(CGFloat(b.x) + 0.5 - middle.x, CGFloat(b.z) + 0.5 - middle.z)
            return da == db ? a.id < b.id : da < db
        }
    }

    /// A one-finger drag pans the map only after it has moved this far, so
    /// a small wobble during a tap still selects the cell.
    static let panSlop: CGFloat = 8

    /// Scene translation for a finger moving `delta` view points (y down)
    /// at camera scale `zoom`: the map follows the finger.
    static func panTranslation(viewDelta delta: CGPoint, zoom: CGFloat) -> CGPoint {
        CGPoint(x: -delta.x * zoom, y: delta.y * zoom)
    }
}

/// Bottom toolbar tools (task E3).
enum RPGEditorTool: String, CaseIterable, Sendable {
    case select, image, video, gif, text, number, icon, shape, mediaGrid, terrain, erase, multi, brush, fill
    var title: String {
        switch self {
        case .select: L10n.t("选择", "Select"); case .image: L10n.t("图片", "Image"); case .video: L10n.t("视频", "Video"); case .gif: "GIF"; case .text: L10n.t("文字", "Text"); case .number: L10n.t("数字", "Number")
        case .icon: L10n.t("图标", "Icon"); case .shape: L10n.t("形状", "Shape"); case .mediaGrid: L10n.t("切格", "Grid"); case .terrain: L10n.t("地形", "Terrain"); case .erase: L10n.t("擦除", "Erase"); case .multi: L10n.t("多选", "Multi"); case .brush: L10n.t("画笔", "Brush"); case .fill: L10n.t("填充", "Fill")
        }
    }
    var symbol: String {
        switch self {
        case .select: "hand.point.up.left"; case .image: "photo"; case .video: "video"; case .gif: "sparkles.rectangle.stack"
        case .text: "textformat"; case .number: "number"; case .icon: "star"; case .shape: "scribble.variable"; case .mediaGrid: "square.grid.3x3.square"; case .terrain: "mountain.2"; case .erase: "eraser"
        case .multi: "rectangle.dashed"; case .brush: "paintbrush.pointed"; case .fill: "square.fill.on.square"
        }
    }
    /// Content tools open the property panel on the tapped cell with this kind.
    var contentKind: RPGMediaKind? {
        switch self { case .image: .image; case .video: .video; case .gif: .gif; case .text: .text; case .number: .number; case .icon: .icon; default: nil }
    }
    /// Tools whose single-finger drag draws a draft.
    var draws: Bool { self == .shape || self == .terrain || self == .erase || self == .brush }
    /// Tools whose drag defines a rectangle.
    var drawsRectangle: Bool { self == .fill || self == .multi }
}

/// A rectangular multi-selection.
struct RPGArea: Equatable, Sendable {
    var a: SurfacePoint
    var b: SurfacePoint
    var cells: [SurfacePoint] { RPGEditDraft.rectangle(a, b) }
    var count: Int { (abs(a.x - b.x) + 1) * (abs(a.z - b.z) + 1) }
    var origin: SurfacePoint { SurfacePoint(x: min(a.x, b.x), z: min(a.z, b.z)) }
}
