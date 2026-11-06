import Foundation

var checks = 0
@MainActor func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(value(), message) }
func cards(_ ranks: [Int]) -> [LandlordCard] {
    var count: [Int: Int] = [:]
    return ranks.map { rank in
        let suit = count[rank, default: 0]; count[rank] = suit + 1
        return .init(id: rank >= 16 ? rank + 36 : (rank - 3) * 4 + suit)
    }
}
let wild = 7
let pair = LandlordRules.choices(cards([7, 8]), wildcardRank: wild, beating: nil)
check(pair.contains { $0.pattern.kind == .pair && $0.pattern.high == 8 && $0.substitutions.count == 1 }, "wild pair")
check(LandlordRules.choices(cards([7]), wildcardRank: wild, beating: nil).allSatisfy { $0.pattern.high == 7 && $0.substitutions.isEmpty }, "single wild keeps natural rank")
check(LandlordRules.interpret(cards([7]), wildcardRank: wild, substitutions: [16: 15]).isEmpty, "single cannot be substituted")
check(LandlordRules.interpret(cards([7, 17]), wildcardRank: wild, substitutions: [16: 17]).isEmpty, "cannot substitute joker")
check(LandlordRules.interpret(cards([8, 8]), wildcardRank: wild, substitutions: [20: 9]).isEmpty, "nonwild cannot be substituted")
check(LandlordRules.choices([.init(id: 99)], wildcardRank: wild, beating: nil).isEmpty, "invalid card fails safely")
check(LandlordRules.choices([.init(id: 16), .init(id: 16)], wildcardRank: wild, beating: nil).isEmpty, "duplicate rejected")
let straight = LandlordRules.choices(cards([3, 4, 5, 6, 7]), wildcardRank: wild, beating: nil)
check(straight.contains { $0.pattern.kind == .straight && $0.pattern.high == 7 }, "natural straight remains valid")
let aceRun = LandlordRules.choices(cards([11, 12, 13, 14, 7]), wildcardRank: wild, beating: nil)
check(aceRun.contains { $0.pattern.kind == .straight && $0.pattern.high == 14 }, "wild completes ace-high run")
check(!aceRun.contains { $0.pattern.kind == .straight && $0.pattern.high == 15 }, "2 cannot be in straight")
let pairs = LandlordRules.choices(cards([3,3,4,4,5,7]), wildcardRank: wild, beating: nil)
check(pairs.contains { $0.pattern.kind == .pairs && $0.pattern.high == 5 }, "consecutive pairs")
let plane = LandlordRules.choices(cards([3,3,3,4,4,7,8,9]), wildcardRank: wild, beating: nil)
check(plane.contains { $0.pattern.kind == .planeSingles && $0.pattern.high == 4 }, "airplane with wild and wings")
let soft = LandlordRules.choices(cards([8,8,8,7]), wildcardRank: wild, beating: nil).first { $0.pattern.kind == .bomb }!
let hard = LandlordRules.choices(cards([3,3,3,3]), wildcardRank: wild, beating: nil).first!
let pureChoices = LandlordRules.choices(cards([7,7,7,7]), wildcardRank: wild, beating: nil).filter { $0.pattern.kind == .bomb }
check(pureChoices.count == 1 && pureChoices[0].pattern.tier == 3, "canonical pure wild bomb")
let rocket = LandlordRules.choices(cards([16,17]), wildcardRank: wild, beating: nil).first!
check(soft.pattern.tier == 1 && hard.pattern.tier == 2, "soft and hard bomb classification")
check(hard.pattern.beats(soft.pattern), "hard outranks higher soft")
check(pureChoices[0].pattern.beats(hard.pattern) && rocket.pattern.beats(pureChoices[0].pattern), "bomb hierarchy")
check(!soft.pattern.beats(hard.pattern) && !hard.pattern.beats(rocket.pattern), "reverse hierarchy rejected")
check(LandlordRules.choices(cards([7,8]), wildcardRank: wild, beating: LandlordPattern(kind: .pair, high: 9, count: 2, run: 1)).isEmpty, "target filters invalid pair")
for choice in plane + straight + pairs + pureChoices + pair {
    let input = choice.pattern.count == 8 ? cards([3,3,3,4,4,7,8,9]) : choice.pattern.count == 6 ? cards([3,3,4,4,5,7]) : choice.pattern.count == 5 ? cards([3,4,5,6,7]) : choice.pattern.count == 4 ? cards([7,7,7,7]) : cards([7,8])
    check(LandlordRules.interpret(input, wildcardRank: wild, substitutions: choice.substitutions).contains(choice), "declaration round-trip")
}
// Strip newly introduced optional keys to simulate a real v1.84 archive.
var legacy = LandlordGame(deck: LandlordCard.deck)
check(legacy.bid(3, player: 0), "classic bid")
check(legacy.play([0], player: 0), "classic play")
let legacyData = try JSONEncoder().encode(legacy)
var object = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
object.removeValue(forKey: "wildcardRank")
let oldData = try JSONSerialization.data(withJSONObject: object)
let restored = try JSONDecoder().decode(LandlordGame.self, from: oldData)
check(restored == legacy && restored.validated && restored.wildcardRank == nil, "legacy archive loads as classic")
let start = Date()
for seed in 0..<8 {
    var deck = LandlordCard.deck
    // Stable seeded permutation independent of system randomness.
    var state = UInt64(seed + 7)
    for i in stride(from: 53, through: 1, by: -1) { state = state &* 6364136223846793005 &+ 1; deck.swapAt(i, Int(state % UInt64(i + 1))) }
    var game = LandlordGame(deck: deck, startingSeat: seed % 3, wildcardRank: seed < 4 ? nil : seed + 3)
    var actions = 0
    while game.phase == .bidding || game.phase == .playing {
        check(game.autoAct(), "bot always performs a legal action")
        check(game.conserved && game.validated, "54 physical cards and valid transitions")
        actions += 1; precondition(actions < 300, "round terminates")
    }
    check(game.phase == .finished && game.scores.reduce(0,+) == 0, "game settles")
    let prior = game
    let gathered = LandlordTablePile.piles(game, collect: true)
    check(gathered.flatMap(\.cards).count == 54 && Set(gathered.flatMap(\.cards).map(\.id)).count == 54, "central table collects all 54 unique physical cards")
    check(gathered.filter(\.played).count == game.history.count, "collection never becomes a fictitious play")
    check(game == prior, "collecting does not mutate ownership or settlement")
    check(LandlordTablePile.piles(game, collect: false).count == game.history.count, "history renderer never truncates plays")
    let reloaded = try JSONDecoder().decode(LandlordGame.self, from: JSONEncoder().encode(game))
    check(reloaded == game && reloaded.validated, "wild declarations and settlement persist")
    check(game.history.flatMap(\.cards).count + game.hands.flatMap { $0 }.count == 54, "table + hands exactly full deck")
}
var preferences = LandlordTablePreferences()
check(preferences.canInspectHand(0) && !preferences.canInspectHand(1) && !preferences.canInspectHand(2), "default visibility")
preferences.revealed = [true,true,true]; check(preferences.canInspectHand(1), "reveal all")
preferences.revealed[1] = false; check(!preferences.canInspectHand(1), "hide again")
let oldPreferences = try JSONSerialization.jsonObject(with: JSONEncoder().encode(preferences)) as! [String: Any]
let oldPreferencesData = try JSONSerialization.data(withJSONObject: oldPreferences.filter { $0.key != "gatherRemaining" })
let compatiblePreferences = try JSONDecoder().decode(LandlordTablePreferences.self, from: oldPreferencesData)
check(compatiblePreferences.revealed == preferences.revealed && !compatiblePreferences.gatherRemaining, "new preferences preserve prior settings")
preferences.offsets[0] = .init(x: .nan, y: 8); preferences.revealed = []; preferences.normalize()
check(preferences.revealed == [true,false,false] && preferences.offsets[0] == .init(x:0,y:0.7), "damaged UI preferences bounded")
let id = UUID(); preferences.begin(id); preferences.offsets[1] = .init(x:0.2,y:0.3); preferences.begin(id)
check(!preferences.offsets.isEmpty, "same round preserves arrangement")
preferences.begin(UUID()); check(preferences.offsets.isEmpty, "new round clears old positions")
for width in [280.0,320,390,740] {
    let rows = LandlordTableLayout.handRows(cardCount: 20, width: width, compact: width > 600)
    check(rows.flatMap { $0 } == Array(0..<20), "layout retains all 20 cards")
}
check(LandlordTableLayout.cardIndex(x:184,width:185,count:20,cardWidth:0) == 19, "finger reaches last inspected card")
check(LandlordTableLayout.cardIndex(x: -5,width:185,count:20,cardWidth:0) == nil, "out of bounds finger")
print("Landlord liquid: \(checks) checks passed; complete games and wild rules \(Date().timeIntervalSince(start)) seconds")
