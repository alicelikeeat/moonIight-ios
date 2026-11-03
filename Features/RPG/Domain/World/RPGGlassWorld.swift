import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// V2.2: all-glass world, 300-cell visible budget, adaptive HUD, analog
// stick and smart media grids. Pure rules only; rendering lives in the
// scene and the SwiftUI HUD.

// MARK: Visible-cell budget

extension RPGCameraRules {
    /// At most this many cells are on screen (design budget for full glass).
    static let visibleBudget = 300
    /// Closest zoom (cells 96 pt on screen).
    static let closestZoom: CGFloat = 0.25
    /// Cells a play view aims to show (40–100 in the plan).
    static let playCells = 80

    /// Cells at least partly visible in a `viewSize` view at camera scale
    /// `zoom` (a partly visible column or row counts).
    static func visibleCells(viewSize: CGSize, zoom: CGFloat) -> Int {
        guard viewSize.width > 0, viewSize.height > 0, zoom.isFinite, zoom > 0 else { return 0 }
        let columns = Int((viewSize.width * zoom / cell).rounded(.up)) + 1
        let rows = Int((viewSize.height * zoom / cell).rounded(.up)) + 1
        return min(columns, WorldGeometry.width) * min(rows, WorldGeometry.width)
    }

    /// The widest zoom that keeps the view within `budget` cells.
    static func budgetZoom(viewSize: CGSize, budget: Int = visibleBudget) -> CGFloat {
        guard viewSize.width > 0, viewSize.height > 0 else { return 1 }
        var low = closestZoom, high = maxZoom
        if visibleCells(viewSize: viewSize, zoom: high) <= budget { return high }
        if visibleCells(viewSize: viewSize, zoom: low) > budget { return low }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if visibleCells(viewSize: viewSize, zoom: middle) <= budget { low = middle } else { high = middle }
        }
        return low
    }

    /// Default play zoom: about `playCells` cells on screen.
    static func playZoom(viewSize: CGSize) -> CGFloat { budgetZoom(viewSize: viewSize, budget: playCells) }

    /// Zoom kept between the closest zoom and the visible budget.
    static func clampZoom(_ zoom: CGFloat, viewSize: CGSize) -> CGFloat {
        guard zoom.isFinite else { return playZoom(viewSize: viewSize) }
        return min(budgetZoom(viewSize: viewSize), max(closestZoom, zoom))
    }
}

// MARK: Glass quality

/// Every level keeps the base glass on every visible cell; higher levels
/// add the moving highlight.
enum RPGGlassQuality: String, CaseIterable, Sendable {
    case high, standard, performance
    var title: String {
        switch self {
        case .high: L10n.t("高质量", "High")
        case .standard: L10n.t("标准", "Standard")
        case .performance: L10n.t("性能优先", "Performance")
        }
    }
    /// Strength of the moving highlight (0: static base glass only).
    var sheen: Double {
        switch self { case .high: 0.14; case .standard: 0.07; case .performance: 0 }
    }
    /// What is actually drawn: Low Power Mode and Reduce Motion drop the
    /// moving highlight, never the base glass.
    static func effective(_ chosen: RPGGlassQuality, lowPower: Bool, reduceMotion: Bool) -> RPGGlassQuality {
        lowPower || reduceMotion ? .performance : chosen
    }
}

// MARK: Adaptive HUD glass

enum RPGHUDGlassKind: String, Sendable {
    /// Status bar, notices.
    case light
    /// Stick, attack, skills.
    case interactive
    /// Tool bars, property panel, menus.
    case panel
}

/// Inputs for the HUD's look. First version: system settings and game
/// state only, no per-frame background sampling.
struct RPGHUDConditions: Equatable, Sendable {
    var dark = false
    var increasedContrast = false
    var reduceTransparency = false
    var inCombat = false
    var editing = false
    var lowPower = false
}

/// How a HUD surface is drawn: clear or regular system glass, with an
/// optional scrim behind text and a solid fallback when transparency is off.
struct RPGHUDGlassStyle: Equatable, Sendable {
    var regular: Bool
    var interactive: Bool
    /// Extra backing for text legibility (0–1).
    var scrim: Double
    /// Reduce Transparency: an opaque surface instead of glass.
    var solid: Bool
    /// Combat warning tint on interactive controls.
    var combatTint: Bool

    static func resolve(_ kind: RPGHUDGlassKind, _ conditions: RPGHUDConditions) -> RPGHUDGlassStyle {
        let solid = conditions.reduceTransparency
        // Panels and anything over a busy map read better on regular glass;
        // light surfaces stay clear unless contrast or combat asks for more.
        let regular = kind == .panel || conditions.increasedContrast || conditions.editing || (kind == .light && conditions.inCombat)
        var scrim = kind == .light ? 0.12 : kind == .panel ? 0.06 : 0
        if conditions.increasedContrast { scrim += 0.18 }
        if conditions.inCombat && kind == .light { scrim += 0.08 }
        return RPGHUDGlassStyle(regular: regular, interactive: kind == .interactive && !conditions.lowPower, scrim: min(0.4, scrim),
                                solid: solid, combatTint: kind == .interactive && conditions.inCombat)
    }
}

// MARK: Analog stick

/// The stick reads 360°; the world stays a grid, so it walks in the
/// nearest of 8 directions, faster the further it is pushed. Movement and
/// combat rules are unchanged.
enum RPGStickRules {
    static let deadZone = 0.18
    static let slowestStep = 0.3
    static let fastestStep = 0.11

    /// Drag offset → unit-disc vector (x right, y down as on screen).
    static func vector(dx: Double, dy: Double, radius: Double) -> (x: Double, y: Double) {
        guard radius > 0, dx.isFinite, dy.isFinite else { return (0, 0) }
        let length = (dx * dx + dy * dy).squareRoot()
        let scale = length > radius ? 1 / length : 1 / radius
        return (dx * scale, dy * scale)
    }

    static func magnitude(_ v: (x: Double, y: Double)) -> Double { min(1, (v.x * v.x + v.y * v.y).squareRoot()) }

    /// Grid step for a stick vector, or nil inside the dead zone. Screen
    /// up is +z in the world.
    static func step(_ v: (x: Double, y: Double), deadZone: Double = deadZone) -> (dx: Int, dz: Int)? {
        guard magnitude(v) > deadZone else { return nil }
        let angle = atan2(-v.y, v.x)
        let sector = Int((angle / (.pi / 4)).rounded()) & 7
        let steps: [(Int, Int)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
        return (steps[sector].0, steps[sector].1)
    }

    /// Seconds between steps: a full push walks fastest.
    static func interval(_ v: (x: Double, y: Double), deadZone: Double = deadZone) -> Double {
        let push = max(0, min(1, (magnitude(v) - deadZone) / (1 - deadZone)))
        return slowestStep + (fastestStep - slowestStep) * push
    }

    /// Fraction of a cooldown still to run, for the button's ring (0: ready).
    static func cooldownFraction(remaining: Double, total: Double) -> Double {
        guard total > 0, remaining.isFinite else { return 0 }
        return max(0, min(1, remaining / total))
    }
}

// MARK: Smart media grid

/// One cell's piece of a media grid: the group shares a single binding
/// (one copy of the file, one video/GIF timeline) and each cell shows its
/// row and column of it.
struct RPGMediaRegion: Codable, Equatable, Hashable, Sendable {
    static let maximumSide = 32
    /// The group's shared binding id.
    var groupID: String
    var row: Int
    var column: Int
    var rows: Int
    var columns: Int
    /// nil or false: crop to fill the grid; true: stretch the whole picture.
    var stretch: Bool?

    var valid: Bool {
        !groupID.isEmpty && groupID.count <= 128 && (1...Self.maximumSide).contains(rows) && (1...Self.maximumSide).contains(columns) &&
            (0..<rows).contains(row) && (0..<columns).contains(column)
    }

    /// This cell's part of the group's texture rectangle (unit texture
    /// coordinates, origin bottom-left as in SpriteKit). Row 0 is the top.
    func subRect(of group: CGRect) -> CGRect {
        let width = group.width / CGFloat(columns), height = group.height / CGFloat(rows)
        return CGRect(x: group.minX + CGFloat(column) * width, y: group.minY + CGFloat(rows - 1 - row) * height, width: width, height: height)
    }

    /// The texture rectangle covering the whole group: the binding's crop,
    /// trimmed to the grid's aspect unless stretched.
    static func groupRect(crop: CGRect, pixels: CGSize, rows: Int, columns: Int, stretch: Bool) -> CGRect {
        guard !stretch, pixels.width > 0, pixels.height > 0, rows > 0, columns > 0, crop.width > 0, crop.height > 0 else { return crop }
        var rect = crop
        let contentAspect = (pixels.width * rect.width) / (pixels.height * rect.height)
        let gridAspect = CGFloat(columns) / CGFloat(rows)
        if contentAspect > gridAspect {
            let width = rect.width * gridAspect / contentAspect
            rect.origin.x += (rect.width - width) / 2; rect.size.width = width
        } else {
            let height = rect.height * contentAspect / gridAspect
            rect.origin.y += (rect.height - height) / 2; rect.size.height = height
        }
        return rect
    }
}

/// What a media-grid draft creates.
struct RPGMediaGridSpec: Equatable, Sendable {
    var template: MediaBinding
    var rows: Int
    var columns: Int
    var stretch = false
    /// Where the top-left piece goes.
    var anchor = SurfacePoint(x: 0, z: 0)
    /// Moving or re-slicing an existing group replaces it in the same edit.
    var replacing: String? = nil

    var count: Int { rows * columns }
    var valid: Bool {
        (1...RPGMediaRegion.maximumSide).contains(rows) && (1...RPGMediaRegion.maximumSide).contains(columns) &&
            count <= RPGWorldEditing.maximumBatch && template.kind.usesLibraryFile && !template.mediaID.isEmpty
    }

    /// The cells with the top-left piece at `anchor` (rows go down the
    /// screen, which is −z), clipped to the map.
    func cells(at anchor: SurfacePoint) -> [SurfacePoint] {
        (0..<rows).flatMap { row in (0..<columns).map { column in SurfacePoint(x: anchor.x + column, z: anchor.z - row) } }.filter(\.valid)
    }
    var cells: [SurfacePoint] { cells(at: anchor) }
    func region(row: Int, column: Int, groupID: String) -> RPGMediaRegion {
        RPGMediaRegion(groupID: groupID, row: row, column: column, rows: rows, columns: columns, stretch: stretch ? true : nil)
    }
    /// Row and column of `point` in this grid.
    func position(of point: SurfacePoint) -> (row: Int, column: Int)? {
        let column = point.x - anchor.x, row = anchor.z - point.z
        return (0..<rows).contains(row) && (0..<columns).contains(column) ? (row, column) : nil
    }

    /// Suggested rows × columns for a total count (as square as possible,
    /// wider than tall for landscape pictures).
    static func shape(for total: Int, aspect: Double = 1) -> (rows: Int, columns: Int) {
        let total = max(1, min(RPGMediaRegion.maximumSide * RPGMediaRegion.maximumSide, total))
        var best = (rows: 1, columns: total), bestScore = Double.infinity
        for rows in 1...RPGMediaRegion.maximumSide where total % rows == 0 {
            let columns = total / rows
            guard columns <= RPGMediaRegion.maximumSide else { continue }
            let score = abs(log(Double(columns) / Double(rows)) - log(max(0.01, aspect)))
            if score < bestScore { bestScore = score; best = (rows, columns) }
        }
        if bestScore == .infinity {
            // No exact split fits 32 × 32: the nearest square-ish grid.
            let rows = min(RPGMediaRegion.maximumSide, max(1, Int(Double(total).squareRoot().rounded())))
            return (rows, min(RPGMediaRegion.maximumSide, Int((Double(total) / Double(rows)).rounded(.up))))
        }
        return best
    }
}
