import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Experimental "glass on every cell" modes, for measuring what a phone can
/// sustain. Pure logic only; drawing lives in the scenes and RPGGridGlass.
enum RPGGlassMode: String, CaseIterable, Sendable {
    /// Shipping behaviour: native glass on the selected cell only.
    case selected
    /// A: a shared glass-look texture over every cell, drawn by SpriteKit.
    /// Not system Liquid Glass; works on iOS 16+.
    case texture
    /// B: one native glass view whose shape is the grid of visible cells.
    case nativeMerged
    /// C: one native glass view per cell for the N cells nearest the player.
    case nativeNearest

    var title: String {
        switch self {
        case .selected: "仅选中格（默认）"
        case .texture: "A 全格子仿玻璃纹理"
        case .nativeMerged: "B 合并单层原生玻璃"
        case .nativeNearest: "C 逐格原生玻璃"
        }
    }
    var short: String {
        switch self { case .selected: "仅选中"; case .texture: "A 纹理"; case .nativeMerged: "B 合并"; case .nativeNearest: "C 逐格" }
    }
    var isNative: Bool { self == .nativeMerged || self == .nativeNearest }
}

/// What actually renders this frame, after automatic downgrades.
enum RPGGlassRender: Equatable, Sendable {
    case selectedOnly
    case texture
    case nativeMerged
    case nativeNearest(Int)

    var label: String {
        switch self {
        case .selectedOnly: "selected"
        case .texture: "texture"
        case .nativeMerged: "nativeMerged"
        case .nativeNearest(let count): "nativeNearest:\(count)"
        }
    }
}

struct RPGGlassConditions: Equatable, Sendable {
    var nativeAvailable = true
    var lowPower = false
    /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    var thermal = 0
    var reduceTransparency = false
    var cameraMoving = false
}

enum RPGGlassPolicy {
    static let nearestChoices = [16, 64, 256]

    /// Native modes fall back to the texture (A) when the system cannot or
    /// should not afford them, and while the camera moves (B and C need a
    /// still camera to stay aligned without per-frame view updates).
    static func resolve(_ mode: RPGGlassMode, nearest: Int, _ conditions: RPGGlassConditions) -> (render: RPGGlassRender, reason: String?) {
        switch mode {
        case .selected: return (.selectedOnly, nil)
        case .texture: return (.texture, nil)
        case .nativeMerged, .nativeNearest:
            if !conditions.nativeAvailable { return (.texture, "iOS 26 以下没有原生 Liquid Glass") }
            if conditions.reduceTransparency { return (.texture, "系统已开启降低透明度") }
            if conditions.lowPower { return (.texture, "低电量模式") }
            if conditions.thermal >= 2 { return (.texture, "设备发热（\(thermalTitle(conditions.thermal))）") }
            if conditions.cameraMoving { return (.texture, "镜头移动中") }
            return mode == .nativeMerged ? (.nativeMerged, nil) : (.nativeNearest(max(1, min(256, nearest))), nil)
        }
    }

    static func thermalTitle(_ raw: Int) -> String {
        switch raw { case 0: "正常"; case 1: "温热"; case 2: "严重"; default: "危急" }
    }

    /// Cell rectangles (view points) covering `bounds`, given where one cell
    /// corner lands on screen and the on-screen cell size. Capped so a
    /// zoomed-out view can never ask for an unbounded number of cells.
    static func gridCells(bounds: CGSize, corner: CGPoint, cell: CGFloat, limit: Int = 2048) -> [CGRect] {
        guard cell >= 4, bounds.width > 0, bounds.height > 0, corner.x.isFinite, corner.y.isFinite else { return [] }
        let startX = corner.x - (corner.x / cell).rounded(.down) * cell - cell
        let startY = corner.y - (corner.y / cell).rounded(.down) * cell - cell
        var cells: [CGRect] = []
        var y = startY
        while y < bounds.height {
            var x = startX
            while x < bounds.width {
                if x + cell > 0, y + cell > 0 { cells.append(CGRect(x: x, y: y, width: cell, height: cell)) }
                if cells.count >= limit { return cells }
                x += cell
            }
            y += cell
        }
        return cells
    }

    /// The `count` cells whose centres are closest to `center` (the player).
    static func nearest(_ cells: [CGRect], to center: CGPoint, count: Int) -> [CGRect] {
        Array(cells.sorted { lhs, rhs in
            let a = hypot(lhs.midX - center.x, lhs.midY - center.y), b = hypot(rhs.midX - center.x, rhs.midY - center.y)
            return a == b ? (lhs.minY, lhs.minX) < (rhs.minY, rhs.minX) : a < b
        }.prefix(max(0, count)))
    }
}

/// One timed measurement in the glass lab.
struct RPGGlassSample: Equatable, Identifiable, Sendable {
    let id: Int
    let mode: RPGGlassMode
    let nearest: Int
    let effective: String
    let seconds: Double
    /// Frames per second over the whole measured window.
    let averageFramesPerSecond: Double
    /// Seconds the scene was actually drawing (sheets and edits pause it).
    let measuredSeconds: Double
    /// For native modes: seconds native glass was on screen, versus the
    /// texture stand-in while the camera moved or the system forced it.
    let nativeSeconds: Double
    /// Frames per second over the last 600 frames (about 10 s).
    let framesPerSecond: Double
    let p95Milliseconds: Double
    let hitches: Int
    let frames: Int
    let memoryMB: Double?
    let thermalStart: Int
    let thermalEnd: Int
    let device: String

    var line: String {
        let modeText = mode == .nativeNearest ? "\(mode.short) N=\(nearest)" : mode.short
        let memory = memoryMB.map { String(format: "%.0f MB", $0) } ?? "未知"
        let native = mode.isNative ? " · 原生玻璃 \(String(format: "%.0f", nativeSeconds))/\(String(format: "%.0f", measuredSeconds)) 秒" : ""
        return "#\(id) \(modeText) · 实际 \(effective) · \(String(format: "%.0f", seconds)) 秒（绘制 \(String(format: "%.0f", measuredSeconds)) 秒）\(native) · 全程 FPS \(String(format: "%.1f", averageFramesPerSecond)) · 近 10 秒 FPS \(String(format: "%.1f", framesPerSecond)) · p95 \(String(format: "%.1f", p95Milliseconds)) ms · >50ms \(hitches)/\(frames) · 内存 \(memory) · 发热 \(RPGGlassPolicy.thermalTitle(thermalStart))→\(RPGGlassPolicy.thermalTitle(thermalEnd)) · \(device)"
    }
}
