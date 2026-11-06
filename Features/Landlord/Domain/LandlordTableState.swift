import Foundation

struct LandlordTableOffset: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var bounded: Self { .init(x: x.isFinite ? min(0.7, max(-0.7, x)) : 0, y: y.isFinite ? min(0.7, max(-0.7, y)) : 0) }
}

struct LandlordSeatProfile: Codable, Equatable, Sendable {
    var name: String
    var avatarMediaID: String?
}

struct LandlordTablePreferences: Codable, Equatable, Sendable {
    var revealed = [true, false, false]
    var profiles = [LandlordSeatProfile(name: "我"), LandlordSeatProfile(name: "右家"), LandlordSeatProfile(name: "左家")]
    var animations = true
    var sound = false
    var haptics = true
    var nextGameWild = false
    var expanded = false
    var gatherRemaining = false
    var offsets: [Int: LandlordTableOffset] = [:]
    var arrangementGameID: UUID?

    init() {}
    private enum CodingKeys: String, CodingKey {
        case revealed, profiles, animations, sound, haptics, nextGameWild, expanded, gatherRemaining, offsets, arrangementGameID
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revealed = try c.decodeIfPresent([Bool].self, forKey: .revealed) ?? revealed
        profiles = try c.decodeIfPresent([LandlordSeatProfile].self, forKey: .profiles) ?? profiles
        animations = try c.decodeIfPresent(Bool.self, forKey: .animations) ?? animations
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? haptics
        nextGameWild = try c.decodeIfPresent(Bool.self, forKey: .nextGameWild) ?? nextGameWild
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? expanded
        gatherRemaining = try c.decodeIfPresent(Bool.self, forKey: .gatherRemaining) ?? false
        offsets = try c.decodeIfPresent([Int: LandlordTableOffset].self, forKey: .offsets) ?? [:]
        arrangementGameID = try c.decodeIfPresent(UUID.self, forKey: .arrangementGameID)
        normalize()
    }

    mutating func normalize() {
        if revealed.count != 3 { revealed = [true, false, false] }
        if profiles.count != 3 { profiles = Self().profiles }
        for i in profiles.indices {
            profiles[i].name = String(profiles[i].name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
            if profiles[i].name.isEmpty { profiles[i].name = Self().profiles[i].name }
        }
        offsets = Dictionary(uniqueKeysWithValues: offsets.filter { (0..<57).contains($0.key) }.prefix(57).map { ($0.key, $0.value.bounded) })
    }

    func canInspectHand(_ player: Int) -> Bool { (0..<3).contains(player) && revealed.count == 3 && revealed[player] }

    mutating func begin(_ id: UUID) {
        if arrangementGameID != id { offsets = [:]; gatherRemaining = false; arrangementGameID = id }
    }
}

/// Presentation piles distinguish actual plays from unplayed cards collected
/// after settlement. Collecting never creates a fake play or changes ownership.
struct LandlordTablePile: Identifiable, Equatable, Sendable {
    let id: Int
    let player: Int
    let cards: [LandlordCard]
    let title: String
    let played: Bool
    var substitutions: [Int: Int] = [:]

    static func piles(_ game: LandlordGame, collect: Bool) -> [Self] {
        var result = game.history.map { play in
            Self(id: play.id, player: play.player, cards: play.cards,
                 title: "第\(play.trick)轮 · \(play.interpretation?.title ?? play.pattern.kind.title)",
                 played: true, substitutions: play.interpretation?.substitutions ?? [:])
        }
        if collect && game.phase == .finished {
            for player in 0..<3 where !game.hands[player].isEmpty {
                result.append(Self(id: 54 + player, player: player, cards: game.hands[player], title: "未出手牌", played: false))
            }
        }
        return result
    }
}

enum LandlordTableLayout {
    /// Public plays first, then separately owned hands. A full-deck rank-sorted
    /// grid would disclose ownership even if every private card had a back.
    static func inspectionOrder(_ game: LandlordGame, revealed: [Bool]) -> [LandlordCard] {
        var result = game.history.flatMap(\.cards)
        let used = Set(result.map(\.id))
        if game.bottomIsPublic { result += game.bottom.filter { !used.contains($0.id) } }
        let publicIDs = Set(result.map(\.id))
        var seed: UInt64 = 1469598103934665603
        for byte in game.id.uuidString.utf8 { seed = (seed ^ UInt64(byte)) &* 1099511628211 }
        func key(_ card: LandlordCard) -> UInt64 {
            var x = seed &+ UInt64(card.id + 1) &* 0x9e3779b97f4a7c15
            x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
            x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
            return x ^ (x >> 31)
        }
        func masked(_ cards: [LandlordCard]) -> [LandlordCard] { cards.sorted { key($0) < key($1) } }
        for player in 0..<3 {
            let hand = game.hands[player].filter { !publicIDs.contains($0.id) }
            result += revealed.count == 3 && revealed[player] ? hand : masked(hand)
        }
        if !game.bottomIsPublic { result += masked(game.bottom) }
        return result
    }
    static func handRows(cardCount: Int, width: Double, compact: Bool) -> [[Int]] {
        guard cardCount > 0 else { return [] }
        let columns = compact ? 20 : max(6, min(12, Int(max(240, width) / 30)))
        return stride(from: 0, to: cardCount, by: columns).map { Array($0..<min(cardCount, $0 + columns)) }
    }
    static func cardIndex(x: Double, width: Double, count: Int, cardWidth: Double) -> Int? {
        guard count > 0, width.isFinite, width > 0, x.isFinite, x >= 0, x <= width else { return nil }
        let step = cardWidth <= 0 ? width / Double(count) : count > 1 ? max(1, (width - cardWidth) / Double(count - 1)) : width
        return min(count - 1, max(0, Int(x / step)))
    }
}
