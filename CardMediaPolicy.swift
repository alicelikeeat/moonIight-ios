import Foundation
import CoreGraphics

enum CardFaceStyle: String, Codable, CaseIterable { case classic, media }
struct CardMediaPreferences: Codable, Equatable {
    var style = CardFaceStyle.classic
    var mediaIDs: [String] = []
    var cycle = true
    var budget = 2
    mutating func normalize(available: Set<String>) {
        var seen = Set<String>()
        mediaIDs = Array(mediaIDs.filter { available.contains($0) && seen.insert($0).inserted }.prefix(54))
        budget = min(2, max(0, budget))
    }
}
struct CardMediaMapping: Codable, Equatable {
    private(set) var assignments: [Int: String] = [:]
    init(cards: [Int], media: [String], game: UUID, cycle: Bool) {
        var seen = Set<String>()
        let media = Array(media.filter { seen.insert($0).inserted }.prefix(54))
        guard !media.isEmpty else { return }
        let seed = game.uuidString.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
        let offset = Int(seed % UInt64(media.count))
        for (index, card) in cards.sorted().enumerated() where cycle || index < media.count {
            assignments[card] = media[(index + offset) % media.count]
        }
    }
}
enum CardVisibility: String, Codable { case hidden, partial, visible }
struct CardPlaybackSnapshot: Codable, Equatable {
    let mediaID: String
    var seconds: Double = 0
    var frameReference: String?
    var visibility = CardVisibility.hidden
}
enum CardPreviewRole: Int, Sendable { case other = 1, hand, central, focus }
struct CardMediaCandidate: Equatable {
    let cardID: Int
    let mediaID: String
    let role: CardPreviewRole
    let z: Int
    let visibility: CardVisibility
}
enum CardMediaPolicy {
    static func budget(requested: Int, serious: Bool, critical: Bool, memoryPressure: Bool) -> Int {
        if critical || memoryPressure { return 0 }
        return min(serious ? 1 : 2, max(0, requested))
    }
    static func scheduled(_ candidates: [CardMediaCandidate], budget: Int) -> [String] {
        var seen = Set<String>()
        return Array(candidates.filter { $0.visibility != .hidden }.sorted {
            if $0.role != $1.role { return $0.role.rawValue > $1.role.rawValue }
            if $0.z != $1.z { return $0.z > $1.z }
            return $0.cardID < $1.cardID
        }.compactMap { seen.insert($0.mediaID).inserted ? $0.mediaID : nil }.prefix(max(0, min(2, budget))))
    }
    static func visibleArea(_ rect: CGRect, coveredBy occluders: [CGRect]) -> CGFloat {
        guard rect.width > 0, rect.height > 0, !rect.isInfinite else { return 0 }
        var remaining = [rect]
        for occluder in occluders {
            remaining = remaining.flatMap { area -> [CGRect] in
                let intersection = area.intersection(occluder)
                guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return [area] }
                return [CGRect(x: area.minX, y: area.minY, width: area.width, height: intersection.minY - area.minY),
                        CGRect(x: area.minX, y: intersection.maxY, width: area.width, height: area.maxY - intersection.maxY),
                        CGRect(x: area.minX, y: intersection.minY, width: intersection.minX - area.minX, height: intersection.height),
                        CGRect(x: intersection.maxX, y: intersection.minY, width: area.maxX - intersection.maxX, height: intersection.height)]
                    .filter { $0.width > 0 && $0.height > 0 }
            }
            if remaining.isEmpty { break }
        }
        return remaining.reduce(0) { $0 + $1.width * $1.height }
    }
}

/// Explicit cost/entry bounded LRU; UIImage ownership stays in this cache.
struct CardFrameLRU<Value> {
    private struct Entry { var value: Value; var cost: Int; var tick: UInt64 }
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var cost = 0
    var maxEntries: Int
    var maxCost: Int
    init(maxEntries: Int, maxCost: Int) { self.maxEntries = maxEntries; self.maxCost = maxCost }
    var count: Int { entries.count }
    func contains(_ key: String) -> Bool { entries[key] != nil }
    mutating func value(_ key: String) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.tick = clock; entries[key] = entry; return entry.value
    }
    mutating func put(_ value: Value, key: String, cost newCost: Int) {
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard newCost >= 0 && newCost <= maxCost else { return }
        clock &+= 1; entries[key] = Entry(value: value, cost: newCost, tick: clock); cost += newCost
        trim()
    }
    mutating func trim() {
        while entries.count > maxEntries || cost > maxCost {
            guard let key = entries.min(by: { $0.value.tick < $1.value.tick })?.key, let old = entries.removeValue(forKey: key) else { break }
            cost -= old.cost
        }
    }
    mutating func remove(_ key: String) { if let old = entries.removeValue(forKey: key) { cost -= old.cost } }
    mutating func removeAll() { entries.removeAll(); cost = 0 }
}
