import Foundation
import WidgetKit

/// Leaves the world's status for the home and lock screen widgets after a
/// save. Writing is cheap and happens every save; asking WidgetKit to
/// redraw is rationed (the system budgets reloads), except when the app is
/// leaving the world, which is when the widget is about to be looked at.
@MainActor
enum MoonlightWidgetBridge {
    private static var lastReload: Date?
    private static var lastWritten: MoonlightWidgetSnapshot?
    static let reloadInterval: TimeInterval = 300

    static func snapshot(title: String, health: Int, stamina: Int, shards: Int, revision: Int,
                         spatial: SpatialWorld?, savedAt: Date = Date()) -> MoonlightWidgetSnapshot {
        let blocks = spatial?.blocks ?? []
        let player = spatial?.player.position ?? SpatialVector(128.5, 128.5, 0)
        let cells = blocks.map { MoonlightMinimapCell(x: $0.x, y: $0.y, top: $0.top, rgb: MoonlightMinimap.rgb(hex: $0.glass.tintHex)) }
        let side = MoonlightMinimap.side
        return MoonlightWidgetSnapshot(worldTitle: String(title.prefix(80)), health: max(0, min(100, health)), stamina: max(0, min(100, stamina)),
                                       shards: max(0, shards), blocks: blocks.count, revision: max(0, revision), savedAt: savedAt,
                                       mapSide: side, map: MoonlightMinimap.build(cells, centerX: Int(player.x.rounded(.down)), centerY: Int(player.y.rounded(.down)), side: side))
    }

    /// `leaving`: the app is pausing the world; redraw the widgets now.
    static func publish(_ snapshot: MoonlightWidgetSnapshot, leaving: Bool) {
        var comparable = snapshot; comparable.savedAt = lastWritten?.savedAt ?? snapshot.savedAt
        let changed = comparable != lastWritten
        guard changed || leaving else { return }
        guard MoonlightWidgetStore.write(snapshot) else { return }   // no App Group after re-signing: shortcuts still work
        lastWritten = snapshot
        let now = Date()
        if leaving || lastReload.map({ now.timeIntervalSince($0) >= reloadInterval }) ?? true {
            lastReload = now
            WidgetCenter.shared.reloadTimelines(ofKind: MoonlightWidgetStore.statusKind)
        }
    }
}
