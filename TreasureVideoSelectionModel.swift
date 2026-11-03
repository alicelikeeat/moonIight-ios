import Foundation

enum TreasureWallMode: String, Codable, CaseIterable, Identifiable {
    case sequential, random, simultaneous
    var id: String { rawValue }
    var title: String { switch self { case .sequential: "顺序"; case .random: "随机"; case .simultaneous: "同时" } }
}

/// Selection is always ordered, unique and bounded, including decoded state.
struct TreasureVideoSelectionModel: Codable, Equatable {
    static let maximum = 10
    private(set) var ids: [String] = []
    var target = 4
    private(set) var recoveredOverflow = false
    init() {}
    private enum CodingKeys: String, CodingKey { case ids, target }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = TreasureRules.unique(try values.decodeIfPresent([String].self, forKey: .ids) ?? [], id: \.self)
        ids = Array(raw.prefix(Self.maximum))
        recoveredOverflow = raw.count > Self.maximum
        target = min(10, max(1, try values.decodeIfPresent(Int.self, forKey: .target) ?? 4))
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(ids, forKey: .ids); try values.encode(target, forKey: .target)
    }
    enum Result: Equatable { case added, removed, full, unavailable }
    mutating func toggle(_ id: String, available: Set<String>) -> Result {
        if ids.contains(id) { ids.removeAll { $0 == id }; recoveredOverflow = false; return .removed }
        guard available.contains(id) else { return .unavailable }
        guard ids.count < Self.maximum else { return .full }
        ids.append(id); recoveredOverflow = false; return .added
    }
    @discardableResult mutating func prune(available: Set<String>) -> Bool {
        let previous = ids; ids.removeAll { !available.contains($0) }; return previous != ids
    }
    mutating func clear() { ids.removeAll(); recoveredOverflow = false }
}

struct TreasureWallQueue {
    private(set) var order: [String]
    private(set) var index = 0
    var current: String? { order.indices.contains(index) ? order[index] : nil }
    init(ids: [String], random: Bool) {
        let unique = Array(TreasureRules.unique(ids, id: \.self).prefix(10))
        order = random ? unique.shuffled() : unique
    }
    mutating func advance(loop: Bool, random: Bool) -> String? {
        index += 1
        guard index >= order.count else { return current }
        guard loop, !order.isEmpty else { return nil }
        let previous = order.last
        if random {
            order.shuffle()
            if order.count > 1 && order.first == previous { order.swapAt(0, 1) }
        }
        index = 0; return current
    }
}

enum TreasureWallPolicy {
    static func columns(_ count: Int) -> Int { count <= 1 ? 1 : count <= 4 ? 2 : 3 }
    static func decoderLimit(memory: UInt64, constrained: Bool, critical: Bool) -> Int {
        if critical { return 1 }
        if constrained { return 2 }
        return memory >= 8_000_000_000 ? 6 : memory >= 6_000_000_000 ? 4 : memory >= 4_000_000_000 ? 3 : 2
    }
    static func visible(ids: [String], visible: Set<String>, limit: Int) -> [String] {
        Array(TreasureRules.unique(ids, id: \.self).filter { visible.contains($0) }.prefix(max(0, min(10, limit))))
    }
}
