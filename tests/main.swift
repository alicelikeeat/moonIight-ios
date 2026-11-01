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

let sequence = (0..<12).map(String.init)
for count in [1, 5, 10] {
    check(TreasurePlaybackPlan.ids(in: sequence, startingAt: "1", count: count) == Array(sequence.dropFirst().prefix(count)), "continuous count")
}
check(TreasurePlaybackPlan.ids(in: sequence, startingAt: "10", count: 10) == ["10", "11"], "tail stops")
check(TreasurePlaybackPlan.ids(in: ["a", "a", "b"], startingAt: "a", count: 5) == ["a", "b"], "stable IDs")
check(TreasurePlaybackPlan.ids(in: sequence, startingAt: "deleted", count: 5).isEmpty, "missing target")
check(TreasurePlaybackPlan.ids(in: sequence, startingAt: "2", count: 10, single: true) == ["2"], "single target does not duplicate")
check(TreasurePlaybackPlan.ids(in: [], startingAt: "a", count: 1).isEmpty, "empty collection")
check(TreasurePlaybackPlan.ids(in: sequence, startingAt: "0", count: 100).count == 10, "maximum ten")
let defaults = TreasurePlaybackOptions.load(Data())
check(defaults.background == .system && defaults.count == 1 && !defaults.autoPlayOnReturn && defaults.sound == .original, "safe defaults")
var saved = defaults
saved.startID = "2"; saved.count = 5; saved.sound = .muted; saved.background = .purple
let encodedOptions = try JSONEncoder().encode(saved)
check(TreasurePlaybackOptions.load(encodedOptions) == saved, "settings round trip")
saved.count = 99; saved.volume = -10
let normalized = TreasurePlaybackOptions.load(try JSONEncoder().encode(saved))
check(normalized.count == 10 && normalized.volume == 0, "invalid preference bounds")
print("V2.1 playback policy: \(checks) total checks passed")

check(MediaSearchIntent.parse("搜索视频 月亮") == MediaSearchIntent(query: "月亮", kind: "video"), "video search route")
check(MediaSearchIntent.parse("搜索图片 猫")?.kind == "image", "image search filter")
check(MediaSearchIntent.parse("搜索")?.query == "", "focus empty search")
check(MediaSearchIntent.parse("打开库") == nil, "non-search action stays non-search")
print("V2.1 total: \(checks) checks passed")
