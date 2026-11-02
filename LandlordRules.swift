import Foundation

struct LandlordCard: Codable, Hashable, Identifiable, Sendable {
    let id: Int
    var rank: Int { id < 52 ? id / 4 + 3 : id == 52 ? 16 : 17 }
    var suit: Int { id < 52 ? id % 4 : 4 }
    var rankText: String {
        switch rank { case 11: "J"; case 12: "Q"; case 13: "K"; case 14: "A"; case 15: "2"; case 16: "小王"; case 17: "大王"; default: String(rank) }
    }
    var suitText: String { ["♠", "♥", "♣", "♦", "★"][suit] }
    var isRed: Bool { suit == 1 || suit == 3 || rank == 17 }
    var label: String { rank >= 16 ? rankText : suitText + rankText }
    static let deck = (0..<54).map { LandlordCard(id: $0) }
    static func ordered(_ cards: [Self]) -> [Self] { cards.sorted { ($0.rank, $0.suit) < ($1.rank, $1.suit) } }
}

enum LandlordHandKind: String, Codable, Sendable {
    case single, pair, triple, tripleSingle, triplePair, straight, pairs, plane, planeSingles, planePairs, fourSingles, fourPairs, bomb, rocket
    var title: String {
        switch self {
        case .single: "单张"; case .pair: "对子"; case .triple: "三张"; case .tripleSingle: "三带一"; case .triplePair: "三带一对"
        case .straight: "顺子"; case .pairs: "连对"; case .plane: "飞机"; case .planeSingles: "飞机带单"; case .planePairs: "飞机带对"
        case .fourSingles: "四带二"; case .fourPairs: "四带两对"; case .bomb: "炸弹"; case .rocket: "王炸"
        }
    }
}
struct LandlordPattern: Codable, Equatable, Sendable {
    let kind: LandlordHandKind
    let high: Int
    let count: Int
    let run: Int
    func beats(_ other: Self) -> Bool {
        if kind == .rocket { return other.kind != .rocket }
        if other.kind == .rocket { return false }
        if kind == .bomb && other.kind != .bomb { return true }
        return kind == other.kind && count == other.count && run == other.run && high > other.high
    }
}

enum LandlordRules {
    /// All legal interpretations are retained, so an ambiguous airplane can
    /// match the current table instead of being rejected by a greedy parser.
    static func patterns(_ cards: [LandlordCard]) -> [LandlordPattern] {
        guard !cards.isEmpty, Set(cards.map(\.id)).count == cards.count,
              cards.allSatisfy({ (0..<54).contains($0.id) }) else { return [] }
        let groups = Dictionary(grouping: cards, by: \.rank).mapValues(\.count)
        let ranks = groups.keys.sorted(), counts = groups.values.sorted(), n = cards.count
        var result: [LandlordPattern] = []
        func add(_ kind: LandlordHandKind, _ high: Int, _ run: Int = 1) { result.append(.init(kind: kind, high: high, count: n, run: run)) }
        func consecutive(_ values: [Int]) -> Bool { !values.isEmpty && values.last! <= 14 && zip(values, values.dropFirst()).allSatisfy { $1 == $0 + 1 } }
        if n == 1 { add(.single, ranks[0]) }
        if n == 2 && ranks == [16, 17] { add(.rocket, 17) }
        if counts == [2] { add(.pair, ranks[0]) }
        if counts == [3] { add(.triple, ranks[0]) }
        if counts == [4] { add(.bomb, ranks[0]) }
        if n == 4, let triple = groups.first(where: { $0.value == 3 }) { add(.tripleSingle, triple.key) }
        if counts == [2, 3], let triple = groups.first(where: { $0.value == 3 }) { add(.triplePair, triple.key) }
        if n >= 5 && counts.allSatisfy({ $0 == 1 }) && consecutive(ranks) { add(.straight, ranks.last!, ranks.count) }
        if n >= 6 && n % 2 == 0 && counts.allSatisfy({ $0 == 2 }) && consecutive(ranks) { add(.pairs, ranks.last!, ranks.count) }
        if n >= 6 && n % 3 == 0 && counts.allSatisfy({ $0 == 3 }) && consecutive(ranks) { add(.plane, ranks.last!, ranks.count) }
        for (divisor, kind) in [(4, LandlordHandKind.planeSingles), (5, .planePairs)] where n % divisor == 0 && n / divisor >= 2 {
            let length = n / divisor
            guard length <= 12 else { continue }
            for low in 3...max(3, 15 - length) {
                let body = Array(low..<(low + length))
                guard body.last! <= 14, body.allSatisfy({ groups[$0] == 3 }) else { continue }
                let wings = groups.filter { !body.contains($0.key) }
                if divisor == 4 && wings.values.reduce(0, +) == length { add(kind, body.last!, length) }
                if divisor == 5 && wings.count == length && wings.values.allSatisfy({ $0 == 2 }) { add(kind, body.last!, length) }
            }
        }
        if let four = groups.first(where: { $0.value == 4 }) {
            if n == 6 { add(.fourSingles, four.key) }
            if n == 8 && groups.filter({ $0.key != four.key }).values.sorted() == [2, 2] { add(.fourPairs, four.key) }
        }
        return result
    }
    static func pattern(_ cards: [LandlordCard], beating target: LandlordPattern? = nil) -> LandlordPattern? {
        let candidates = patterns(cards)
        if let target { return candidates.first { $0.beats(target) } }
        return candidates.first
    }
    /// Bounded template generation for bots, not a 2^20 subset search.
    static func moves(_ hand: [LandlordCard], beating target: LandlordPattern?) -> [[LandlordCard]] {
        let byRank = Dictionary(grouping: LandlordCard.ordered(hand), by: \.rank)
        let ranks = byRank.keys.sorted()
        var candidates: [[LandlordCard]] = []
        for rank in ranks {
            let group = byRank[rank]!
            for count in 1...min(4, group.count) { candidates.append(Array(group.prefix(count))) }
            if group.count >= 3 {
                for wing in ranks where wing != rank {
                    candidates.append(Array(group.prefix(3)) + Array(byRank[wing]!.prefix(1)))
                    if byRank[wing]!.count >= 2 { candidates.append(Array(group.prefix(3)) + Array(byRank[wing]!.prefix(2))) }
                }
            }
            if group.count == 4 {
                let singles = ranks.filter { $0 != rank }.flatMap { byRank[$0]! }
                if singles.count >= 2 { candidates.append(group + Array(singles.prefix(2))) }
                let pairs = ranks.filter { $0 != rank && byRank[$0]!.count >= 2 }
                if pairs.count >= 2 { candidates.append(group + Array(byRank[pairs[0]]!.prefix(2)) + Array(byRank[pairs[1]]!.prefix(2))) }
            }
        }
        if let small = byRank[16]?.first, let big = byRank[17]?.first { candidates.append([small, big]) }
        for multiplicity in 1...3 {
            let minimum = multiplicity == 1 ? 5 : multiplicity == 2 ? 3 : 2
            for low in 3...14 {
                var run: [LandlordCard] = []
                for high in low...14 {
                    guard let cards = byRank[high], cards.count >= multiplicity else { break }
                    run += cards.prefix(multiplicity)
                    let length = high - low + 1
                    guard length >= minimum else { continue }
                    candidates.append(run)
                    if multiplicity == 3 {
                        let rest = ranks.filter { $0 < low || $0 > high }
                        let wings = rest.flatMap { byRank[$0]! }
                        if wings.count >= length { candidates.append(run + Array(wings.prefix(length))) }
                        let pairs = rest.filter { byRank[$0]!.count >= 2 }
                        if pairs.count >= length { candidates.append(run + pairs.prefix(length).flatMap { Array(byRank[$0]!.prefix(2)) }) }
                    }
                }
            }
        }
        var seen = Set<[Int]>()
        return candidates.filter { cards in
            seen.insert(cards.map(\.id).sorted()).inserted && pattern(cards, beating: target) != nil
        }.sorted {
            let a = pattern($0, beating: target)!, b = pattern($1, beating: target)!
            let aBomb = a.kind == .bomb || a.kind == .rocket, bBomb = b.kind == .bomb || b.kind == .rocket
            if aBomb != bBomb { return !aBomb }
            if target == nil && $0.count != $1.count { return $0.count > $1.count }
            return a.high == b.high ? $0.map(\.id).lexicographicallyPrecedes($1.map(\.id)) : a.high < b.high
        }
    }
}

struct LandlordPlay: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let player: Int
    let trick: Int
    let cards: [LandlordCard]
    let pattern: LandlordPattern
}
enum LandlordPhase: String, Codable, Sendable { case bidding, playing, finished, redeal }
struct LandlordGame: Codable, Equatable, Sendable {
    let id: UUID
    private(set) var hands: [[LandlordCard]]
    private(set) var bottom: [LandlordCard]
    private(set) var phase = LandlordPhase.bidding
    private(set) var turn: Int
    private(set) var landlord: Int?
    private(set) var highestBid = 0
    private(set) var bidCount = 0
    private(set) var leader: Int?
    private(set) var lastPlay: LandlordPlay?
    private(set) var passes = 0
    private(set) var trick = 1
    private(set) var history: [LandlordPlay] = []
    private(set) var playedHands = [0, 0, 0]
    private(set) var multiplier = 1
    private(set) var winner: Int?
    private(set) var scores = [0, 0, 0]
    private(set) var spring = false
    init(deck: [LandlordCard] = LandlordCard.deck.shuffled(), startingSeat: Int = 0) {
        let valid = deck.count == 54 && Set(deck.map(\.id)) == Set(0..<54) ? deck : LandlordCard.deck
        id = UUID(); turn = min(2, max(0, startingSeat))
        hands = (0..<3).map { seat in LandlordCard.ordered(Array(valid[(seat * 17)..<(seat * 17 + 17)])) }
        bottom = Array(valid.suffix(3))
    }
    var target: LandlordPattern? { lastPlay?.pattern }
    var targetPlayer: Int? { lastPlay?.player }
    var conserved: Bool {
        let cards = hands.flatMap { $0 } + history.flatMap(\.cards) + ((phase == .bidding || phase == .redeal) ? bottom : [])
        return cards.count == 54 && Set(cards.map(\.id)) == Set(0..<54)
    }
    @discardableResult mutating func bid(_ value: Int, player: Int) -> Bool {
        guard phase == .bidding, player == turn, value == 0 || (value > highestBid && value <= 3) else { return false }
        if value > 0 { highestBid = value; landlord = player }
        bidCount += 1
        if value == 3 || bidCount == 3 {
            guard let landlord else { phase = .redeal; return true }
            hands[landlord] = LandlordCard.ordered(hands[landlord] + bottom)
            turn = landlord; leader = landlord; phase = .playing
        } else { turn = (turn + 1) % 3 }
        return true
    }
    @discardableResult mutating func play(_ ids: [Int], player: Int) -> Bool {
        guard phase == .playing, turn == player, !ids.isEmpty, Set(ids).count == ids.count else { return false }
        let lookup = Dictionary(uniqueKeysWithValues: hands[player].map { ($0.id, $0) })
        let cards = ids.compactMap { lookup[$0] }
        guard cards.count == ids.count, let pattern = LandlordRules.pattern(cards, beating: target) else { return false }
        let record = LandlordPlay(id: history.count, player: player, trick: trick, cards: cards, pattern: pattern)
        hands[player].removeAll { ids.contains($0.id) }
        history.append(record); lastPlay = record; leader = player; passes = 0; playedHands[player] += 1
        if pattern.kind == .bomb || pattern.kind == .rocket { multiplier *= 2 }
        if hands[player].isEmpty { settle(player) } else { turn = (turn + 1) % 3 }
        return true
    }
    @discardableResult mutating func pass(player: Int) -> Bool {
        guard phase == .playing, turn == player, lastPlay != nil else { return false }
        passes += 1
        if passes == 2 {
            turn = leader!; lastPlay = nil; passes = 0; trick += 1
        } else { turn = (turn + 1) % 3 }
        return true
    }
    func suggestion(for player: Int) -> [Int] {
        guard phase == .playing, player == turn else { return [] }
        return LandlordRules.moves(hands[player], beating: target).first?.map(\.id) ?? []
    }
    @discardableResult mutating func autoAct() -> Bool {
        let player = turn
        if phase == .bidding {
            let strength = hands[player].filter { $0.rank >= 15 }.count
            let bid = highestBid == 0 ? 1 : strength >= 4 && highestBid < 3 ? highestBid + 1 : 0
            return self.bid(bid, player: player)
        }
        guard phase == .playing else { return false }
        if let targetPlayer, player != landlord && targetPlayer != landlord { return pass(player: player) }
        let move = suggestion(for: player)
        if !move.isEmpty { return play(move, player: player) }
        return pass(player: player)
    }
    private mutating func settle(_ player: Int) {
        winner = player; phase = .finished
        guard let landlord else { return }
        let landlordWon = player == landlord
        spring = landlordWon ? playedHands.enumerated().filter { $0.offset != landlord }.allSatisfy { $0.element == 0 } : playedHands[landlord] == 1
        if spring { multiplier *= 2 }
        let stake = max(1, highestBid) * multiplier
        scores = (0..<3).map { seat in (seat == landlord ? 2 : -1) * stake * (landlordWon ? 1 : -1) }
    }
}

extension LandlordGame {
    var validated: Bool {
        guard hands.count == 3, bottom.count == 3, Set(bottom.map(\.id)).count == 3,
              (0..<3).contains(turn), landlord.map({ (0..<3).contains($0) }) ?? true,
              leader.map({ (0..<3).contains($0) }) ?? true,
              winner.map({ (0..<3).contains($0) }) ?? true,
              bottom.allSatisfy({ (0..<54).contains($0.id) }),
              scores.count == 3, playedHands.count == 3, history.count <= 54,
              (0...3).contains(highestBid), (0...3).contains(bidCount), (0...1).contains(passes),
              multiplier > 0, multiplier <= 131072, conserved else { return false }
        if phase == .playing || phase == .finished { guard landlord != nil, highestBid > 0 else { return false } }
        guard playedHands == (0..<3).map({ seat in history.filter { $0.player == seat }.count }),
              lastPlay.map({ $0 == history.last && $0.player == leader }) ?? true else { return false }
        if phase == .playing { guard winner == nil, hands.allSatisfy({ !$0.isEmpty }) else { return false } }
        if phase == .finished {
            guard let winner, winner == history.last?.player, hands[winner].isEmpty, scores.reduce(0, +) == 0 else { return false }
        } else if scores != [0, 0, 0] { return false }
        return history.enumerated().allSatisfy { index, play in
            play.id == index && (0..<3).contains(play.player) && LandlordRules.patterns(play.cards).contains(play.pattern)
        }
    }
}
