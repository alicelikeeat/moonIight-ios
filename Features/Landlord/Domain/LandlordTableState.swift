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
    var offsets: [Int: LandlordTableOffset] = [:]
    var arrangementGameID: UUID?

    mutating func normalize() {
        if revealed.count != 3 { revealed = [true, false, false] }
        if profiles.count != 3 { profiles = Self().profiles }
        for i in profiles.indices {
            profiles[i].name = String(profiles[i].name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
            if profiles[i].name.isEmpty { profiles[i].name = Self().profiles[i].name }
        }
        offsets = Dictionary(uniqueKeysWithValues: offsets.filter { (0..<54).contains($0.key) }.prefix(54).map { ($0.key, $0.value.bounded) })
    }

    func canInspectHand(_ player: Int) -> Bool { (0..<3).contains(player) && revealed.count == 3 && revealed[player] }

    mutating func begin(_ id: UUID) {
        if arrangementGameID != id { offsets = [:]; arrangementGameID = id }
    }
}

enum LandlordTableLayout {
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
