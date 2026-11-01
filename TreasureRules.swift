import Foundation

/// Deterministic policy shared by the scene and command-line regression tests.
enum TreasureRules {
    static func unique<Element, ID: Hashable>(_ elements: [Element], id: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return elements.filter { seen.insert($0[keyPath: id]).inserted }
    }
    static func count(selected: Int, available: Int) -> Int {
        min(max(selected, 0), max(available, 0), 42)
    }
    static func shouldDrag(distance: CGFloat) -> Bool { distance > 10 }
    static func shouldOpen(dragged: Bool, held: Bool) -> Bool { !dragged && !held }
}
