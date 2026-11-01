import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
    checks += 1
}
for available in [0, 1, 5, 12, 42, 65] {
    for selected in [6, 12, 20, 30, 42] {
        check(TreasureRules.count(selected: selected, available: available) == min(selected, available, 42), "count matrix")
    }
}
check(TreasureRules.count(selected: -1, available: 20) == 0, "negative preference")
check(TreasureRules.count(selected: 100, available: 100) == 42, "hard cap")
for _ in 0..<30 {
    check(TreasureRules.shouldOpen(dragged: false, held: false), "tap")
    check(!TreasureRules.shouldOpen(dragged: false, held: true), "hold suppresses tap")
    check(!TreasureRules.shouldOpen(dragged: true, held: false), "drag suppresses tap")
    check(!TreasureRules.shouldDrag(distance: 10), "threshold inclusive")
    check(TreasureRules.shouldDrag(distance: 10.1), "drag threshold")
}
check(TreasureRules.unique(["b", "a", "b", "c", "a"], id: \.self) == ["b", "a", "c"], "unique stable order")
check(TreasureRules.unique([String](), id: \.self).isEmpty, "empty identity set")
print("Treasure policy: \(checks) checks passed")
