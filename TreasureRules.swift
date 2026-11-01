import Foundation

/// Deterministic policy shared by the scene and command-line regression tests.
enum TreasureRules {
    static func count(selected: Int, available: Int) -> Int {
        min(max(selected, 0), max(available, 0), 42)
    }
    static func shouldDrag(distance: CGFloat) -> Bool { distance > 10 }
    static func shouldOpen(dragged: Bool, held: Bool) -> Bool { !dragged && !held }
}
