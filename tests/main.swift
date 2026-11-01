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

let available = Set((0..<12).map(String.init))
for count in [1, 4, 9, 10] {
    var selected = TreasureVideoSelectionModel()
    for id in (0..<count).map(String.init) { check(selected.toggle(id, available: available) == .added, "valid selection") }
    check(selected.ids.count == count, "selection boundary")
}
var selected = TreasureVideoSelectionModel()
check(selected.target == 4 && selected.ids.isEmpty, "target four never autofills")
for id in (0..<10).map(String.init) { _ = selected.toggle(id, available: available) }
check(selected.toggle("10", available: available) == .full && selected.ids.count == 10, "eleventh refused")
check(selected.toggle("missing", available: available) == .unavailable, "invalid refused")
let restoredData = Data(#"{"ids":["0","0","1","2","3","4","5","6","7","8","9","10"],"target":15}"#.utf8)
var restored = try JSONDecoder().decode(TreasureVideoSelectionModel.self, from: restoredData)
check(restored.ids.count == 10 && restored.recoveredOverflow && restored.target == 10, "legacy truncation reported")
check(Set(restored.ids).count == restored.ids.count, "duplicate identity restored once")
check(restored.prune(available: ["0", "2"]) && restored.ids == ["0", "2"], "deleted media pruned preserving order")
let roundTrip = try JSONDecoder().decode(TreasureVideoSelectionModel.self, from: JSONEncoder().encode(restored))
check(roundTrip.ids == ["0", "2"], "selection persists")
for count in [1, 2, 4, 9, 10] {
    let ids = (0..<count).map(String.init)
    var sequential = TreasureWallQueue(ids: ids, random: false)
    for id in ids { check(sequential.current == id, "selection order"); _ = sequential.advance(loop: false, random: false) }
    check(sequential.current == nil, "nonloop tail stops")
    var random = TreasureWallQueue(ids: ids, random: true)
    for _ in 0..<10 {
        check(Set(random.order) == Set(ids) && random.order.count == ids.count, "shuffle no repetition")
        let oldLast = random.order.last
        for _ in ids { _ = random.advance(loop: true, random: true) }
        check(count == 1 || random.current != oldLast, "shuffle round boundary")
    }
}
check(TreasureWallPolicy.columns(1) == 1 && TreasureWallPolicy.columns(2) == 2 && TreasureWallPolicy.columns(4) == 2 && TreasureWallPolicy.columns(9) == 3 && TreasureWallPolicy.columns(10) == 3, "wall layouts")
check(TreasureWallPolicy.visible(ids: ["a", "b", "c", "a"], visible: ["b", "c"], limit: 1) == ["b"], "invisible media not decoded")
check(TreasureWallPolicy.decoderLimit(memory: 8_000_000_000, constrained: false, critical: true) == 1, "critical thermal budget")
check(TreasureWallPolicy.decoderLimit(memory: 8_000_000_000, constrained: true, critical: false) == 2, "low power budget")
print("V2.3 wall policy: \(checks) total checks passed")

check(MediaSearchIntent.parse("搜索视频 月亮") == MediaSearchIntent(query: "月亮", kind: "video"), "video search route")
check(MediaSearchIntent.parse("搜索图片 猫")?.kind == "image", "image search filter")
check(MediaSearchIntent.parse("搜索")?.query == "", "focus empty search")
check(MediaSearchIntent.parse("打开库") == nil, "non-search action stays non-search")
print("V2.1 total: \(checks) checks passed")
