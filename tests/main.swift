import Foundation
import CoreGraphics

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
print("V2.3 total: \(checks) checks passed")

// V2.4.1: pure rules and renderer-independent card/media identity.
func cards(_ ranks: [Int]) -> [LandlordCard] {
    var counts: [Int: Int] = [:]
    return ranks.map { rank in
        let suit = counts[rank, default: 0]; counts[rank] = suit + 1
        return LandlordCard(id: rank >= 16 ? rank + 36 : (rank - 3) * 4 + suit)
    }
}
let legalHands: [([Int], LandlordHandKind)] = [
    ([3], .single), ([3,3], .pair), ([3,3,3], .triple), ([3,3,3,4], .tripleSingle),
    ([3,3,3,4,4], .triplePair), ([3,4,5,6,7], .straight), ([3,3,4,4,5,5], .pairs),
    ([3,3,3,4,4,4], .plane), ([3,3,3,4,4,4,7,8], .planeSingles),
    ([3,3,3,4,4,4,7,7,8,8], .planePairs), ([3,3,3,3,4,5], .fourSingles),
    ([3,3,3,3,4,4,5,5], .fourPairs), ([3,3,3,3], .bomb), ([16,17], .rocket)
]
for (ranks, kind) in legalHands { check(LandlordRules.pattern(cards(ranks))?.kind == kind, "landlord legal \(kind)") }
for ranks in [[11,12,13,14,15], [3,4,5,6], [3,3,4,4], [3,3,3,4,4,4,5]] {
    check(LandlordRules.pattern(cards(ranks)) == nil, "illegal short/2 run or bad wings")
}
check(LandlordRules.pattern([LandlordCard(id: 0), LandlordCard(id: 0)]) == nil, "duplicate card rejected")
check(LandlordRules.pattern(cards([16,17]))!.beats(LandlordRules.pattern(cards([15,15,15,15]))!), "rocket beats bomb")
check(!LandlordRules.pattern(cards([4,4]))!.beats(LandlordRules.pattern(cards([3]))!), "different pattern cannot beat")
var testGame = LandlordGame(deck: LandlordCard.deck)
check(!testGame.play([0], player: 0) && !testGame.pass(player: 0), "no plays during bidding")
check(!testGame.bid(3, player: 2), "wrong turn bid rejected")
check(testGame.bid(1, player: 0) && testGame.conserved, "bidding preserves bottom before assignment")
check(!testGame.bid(1, player: 1) && testGame.bid(0, player: 1) && testGame.bid(0, player: 2), "higher bid or pass")
check(testGame.hands[0].count == 20 && testGame.conserved, "landlord receives bottom exactly once")
check(!testGame.play([17], player: 0) && !testGame.play([0,0], player: 0), "foreign or duplicate card rejected")
check(testGame.play([1,0], player: 0), "pair play")
check(testGame.history.last?.cards.map(\.id) == [1,0], "actual selection order retained")
check(testGame.pass(player: 1) && testGame.pass(player: 2) && testGame.turn == 0 && testGame.target == nil && testGame.trick == 2, "two passes reset target to leader")
check(!testGame.pass(player: 0), "cannot pass on free lead")
var noBid = LandlordGame()
for seat in 0..<3 { check(noBid.bid(0, player: seat), "pass bid") }
check(noBid.phase == .redeal && noBid.conserved, "all pass redeal")
// Deterministic, full three-seat games, legal moves at every transition.
for seed in 0..<20 {
    var randomState = UInt64(seed + 1)
    var deck = LandlordCard.deck
    for i in stride(from: 53, through: 1, by: -1) {
        randomState = randomState &* 6364136223846793005 &+ 1
        deck.swapAt(i, Int(randomState % UInt64(i + 1)))
    }
    var game = LandlordGame(deck: deck, startingSeat: seed % 3)
    var actions = 0
    while game.phase == .bidding || game.phase == .playing {
        check(game.conserved && game.validated, "54 cards conserved and valid on every transition")
        check(game.autoAct(), "bot always takes a legal action")
        actions += 1
        if actions > 165 { break }
    }
    check(game.phase == .finished && game.validated && actions <= 165, "whole game terminates")
    let stake = game.highestBid * game.multiplier
    check(game.scores[game.landlord!] == (game.winner == game.landlord ? 2 : -2) * stake, "exact landlord settlement")
    check(game.scores.reduce(0,+) == 0 && game.winner != nil, "scores settle zero sum")
    let serialized = try JSONEncoder().encode(game)
    let decoded = try JSONDecoder().decode(LandlordGame.self, from: serialized)
    check(decoded == game, "whole game Codable round trip")
}
let mapID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
let mapped = CardMediaMapping(cards: Array(0..<54), media: ["a","b","a"], game: mapID, cycle: true)
check(mapped.assignments.count == 54 && Set(mapped.assignments.values) == ["a","b"], "54 identities cyclic shared assets")
check(mapped == CardMediaMapping(cards: Array(0..<54), media: ["a","b"], game: mapID, cycle: true), "stable persisted mapping")
check(CardMediaMapping(cards: Array(0..<54), media: ["a","b"], game: mapID, cycle: false).assignments.count == 2, "noncyclic fallback")
let candidates = (0..<54).map { CardMediaCandidate(cardID: $0, mediaID: String($0), role: .hand, z: $0, visibility: .visible) }
check(CardMediaPolicy.scheduled(candidates, budget: 54) == ["53","52"], "54 mapped videos never exceed two decoders")
let focused = CardMediaCandidate(cardID: 0, mediaID: "focus", role: .focus, z: 0, visibility: .visible)
check(CardMediaPolicy.scheduled(candidates + [focused], budget: 2).first == "focus", "focus priority")
check(CardMediaPolicy.scheduled([.init(cardID: 0, mediaID: "a", role: .focus, z: 1, visibility: .hidden)], budget: 2).isEmpty, "fully hidden owns no decoder")
check(CardMediaPolicy.scheduled((0..<54).map { .init(cardID: $0, mediaID: "shared", role: .central, z: $0, visibility: .partial) }, budget: 2) == ["shared"], "duplicate media joins same timeline")
check(CardMediaPolicy.budget(requested: 2, serious: true, critical: false, memoryPressure: false) == 1, "serious heat shrinks budget")
check(CardMediaPolicy.budget(requested: 2, serious: false, critical: true, memoryPressure: false) == 0, "critical heat static")
check(CardMediaPolicy.budget(requested: 2, serious: false, critical: false, memoryPressure: true) == 0, "memory warning static")
let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
check(CardMediaPolicy.visibleArea(rect, coveredBy: [rect]) == 0, "fully covered")
check(CardMediaPolicy.visibleArea(rect, coveredBy: [CGRect(x: 0,y: 0,width: 50,height: 100), CGRect(x: 25,y: 0,width: 50,height: 100)]) == 2500, "occluder union no double subtraction")
var lru = CardFrameLRU<Int>(maxEntries: 2, maxCost: 100)
lru.put(1, key: "a", cost: 30); lru.put(2, key: "b", cost: 30); _ = lru.value("a"); lru.put(3, key: "c", cost: 30)
check(lru.value("b") == nil && lru.value("a") == 1 && lru.cost == 60, "least recently used eviction")
lru.maxCost = 20; lru.trim(); check(lru.count == 0 && lru.cost == 0, "pressure trim releases owners")
let snapshot = CardPlaybackSnapshot(mediaID: "a", seconds: 12.25, frameReference: "a", visibility: .hidden)
let decodedSnapshot = try JSONDecoder().decode(CardPlaybackSnapshot.self, from: JSONEncoder().encode(snapshot))
check(decodedSnapshot == snapshot, "hidden snapshot retains progress and frame reference")
print("V2.4.1 total: \(checks) checks passed")

let ambiguousPlane = cards([3,3,3,4,4,4,5,5,5,6,6,6])
let airplaneTarget = LandlordPattern(kind: .planeSingles, high: 4, count: 12, run: 3)
check(LandlordRules.pattern(ambiguousPlane, beating: airplaneTarget)?.kind == .planeSingles, "target-aware ambiguous airplane")
var mediaGame = LandlordGame(deck: LandlordCard.deck)
let beforeMedia = mediaGame
var mediaPrefs = CardMediaPreferences()
mediaPrefs.style = .media; mediaPrefs.mediaIDs = ["v", "p", "missing"]; mediaPrefs.normalize(available: ["v", "p"])
_ = CardMediaMapping(cards: Array(0..<54), media: mediaPrefs.mediaIDs, game: mediaGame.id, cycle: true)
check(mediaGame == beforeMedia && mediaPrefs.mediaIDs == ["v", "p"], "media changes cannot mutate rules state")
print("V2.4.1 validated total: \(checks) checks passed")
