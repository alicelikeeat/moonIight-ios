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

enum LandlordHandKind: String, Codable, Hashable, Sendable {
    case single, pair, triple, tripleSingle, triplePair, straight, pairs, plane, planeSingles, planePairs, fourSingles, fourPairs, bomb, rocket
    var title: String {
        switch self {
        case .single: "单张"; case .pair: "对子"; case .triple: "三张"; case .tripleSingle: "三带一"; case .triplePair: "三带一对"
        case .straight: "顺子"; case .pairs: "连对"; case .plane: "飞机"; case .planeSingles: "飞机带单"; case .planePairs: "飞机带对"
        case .fourSingles: "四带二"; case .fourPairs: "四带两对"; case .bomb: "炸弹"; case .rocket: "王炸"
        }
    }
}
struct LandlordPattern: Codable, Hashable, Sendable {
    let kind: LandlordHandKind
    let high: Int
    let count: Int
    let run: Int
    var bombTier: LandlordBombTier? = nil
    var tier: Int { kind == .rocket ? 4 : kind == .bomb ? (bombTier ?? .hard).rawValue : 0 }
    func beats(_ other: Self) -> Bool {
        if kind == .rocket { return other.kind != .rocket }
        if other.kind == .rocket { return false }
        if kind == .bomb && other.kind != .bomb { return true }
        if kind == .bomb && other.kind == .bomb && tier != other.tier { return tier > other.tier }
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
    var interpretation: LandlordInterpretation? = nil
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
    private(set) var wildcardRank: Int?
    init(deck: [LandlordCard] = LandlordCard.deck.shuffled(), startingSeat: Int = 0, wildcardRank: Int? = nil) {
        let valid = deck.count == 54 && Set(deck.map(\.id)) == Set(0..<54) ? deck : LandlordCard.deck
        id = UUID(); turn = min(2, max(0, startingSeat))
        hands = (0..<3).map { seat in LandlordCard.ordered(Array(valid[(seat * 17)..<(seat * 17 + 17)])) }
        bottom = Array(valid.suffix(3))
        self.wildcardRank = wildcardRank.flatMap { (3...15).contains($0) ? $0 : nil }
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
    @discardableResult mutating func play(_ ids: [Int], player: Int, declared: LandlordInterpretation? = nil) -> Bool {
        guard phase == .playing, turn == player, !ids.isEmpty, Set(ids).count == ids.count else { return false }
        let lookup = Dictionary(uniqueKeysWithValues: hands[player].map { ($0.id, $0) })
        let cards = ids.compactMap { lookup[$0] }
        guard cards.count == ids.count else { return false }
        let choice: LandlordInterpretation?
        if let declared {
            choice = LandlordRules.interpret(cards, wildcardRank: wildcardRank, substitutions: declared.substitutions)
                .first { $0 == declared && (target.map { declared.pattern.beats($0) } ?? true) }
        } else { choice = choices(for: ids).first }
        guard let choice else { return false }
        let pattern = choice.pattern
        let record = LandlordPlay(id: history.count, player: player, trick: trick, cards: cards, pattern: pattern,
                                  interpretation: wildcardRank == nil ? nil : choice)
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
        return suggestedMove(for: player)?.cards.map(\.id) ?? []
    }
    func choices(for ids: [Int]) -> [LandlordInterpretation] {
        guard phase == .playing, Set(ids).count == ids.count else { return [] }
        let cards = hands[turn].filter { ids.contains($0.id) }
        guard cards.count == ids.count else { return [] }
        return LandlordRules.choices(cards, wildcardRank: wildcardRank, beating: target)
    }
    func suggestedMove(for player: Int) -> LandlordMove? {
        guard phase == .playing, player == turn else { return nil }
        return LandlordRules.availableMoves(hands[player], wildcardRank: wildcardRank, beating: target).first
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
        if let move = suggestedMove(for: player) { return play(move.cards.map(\.id), player: player, declared: move.interpretation) }
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
              multiplier > 0, multiplier <= 131072, wildcardRank.map({ (3...15).contains($0) }) ?? true, conserved else { return false }
        if phase == .playing || phase == .finished { guard landlord != nil, highestBid > 0 else { return false } }
        guard playedHands == (0..<3).map({ seat in history.filter { $0.player == seat }.count }),
              lastPlay.map({ $0 == history.last && $0.player == leader }) ?? true else { return false }
        if phase == .playing { guard winner == nil, hands.allSatisfy({ !$0.isEmpty }) else { return false } }
        if phase == .finished {
            guard let winner, winner == history.last?.player, hands[winner].isEmpty, scores.reduce(0, +) == 0 else { return false }
        } else if scores != [0, 0, 0] { return false }
        return history.enumerated().allSatisfy { index, play in
            guard play.id == index, (0..<3).contains(play.player) else { return false }
            if let declaration = play.interpretation {
                return declaration.pattern == play.pattern && LandlordRules.interpret(play.cards, wildcardRank: wildcardRank,
                    substitutions: declaration.substitutions).contains(declaration)
            }
            return wildcardRank == nil && LandlordRules.patterns(play.cards).contains(play.pattern)
        }
    }
}

enum LandlordBombTier: Int, Codable, Hashable, Sendable { case soft = 1, hard = 2, pureWild = 3 }

struct LandlordInterpretation: Codable, Hashable, Identifiable, Sendable {
    let pattern: LandlordPattern
    var substitutions: [Int: Int] = [:]
    var id: String {
        "\(pattern.kind.rawValue):\(pattern.high):\(pattern.count):\(pattern.run):\(pattern.tier):" +
        substitutions.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
    var title: String {
        let tier = pattern.kind == .bomb ? (pattern.tier == 3 ? "纯癞子炸弹" : pattern.tier == 1 ? "软炸弹" : "硬炸弹") : pattern.kind.title
        return tier + " · " + LandlordCard.rankLabel(pattern.high)
    }
}

struct LandlordMove: Sendable {
    let cards: [LandlordCard]
    let interpretation: LandlordInterpretation
}

extension LandlordCard {
    static func rankLabel(_ rank: Int) -> String {
        (3...17).contains(rank) ? LandlordCard(id: rank >= 16 ? rank + 36 : (rank - 3) * 4).rankText : "?"
    }
}

extension LandlordRules {
    /// Validate one explicit declaration without enumerating other assignments.
    /// Virtual cards exist only inside the classifier; physical card IDs never change.
    static func interpret(_ cards: [LandlordCard], wildcardRank: Int?, substitutions: [Int: Int]) -> [LandlordInterpretation] {
        guard !cards.isEmpty, cards.count <= 20, Set(cards.map(\.id)).count == cards.count,
              cards.allSatisfy({ (0..<54).contains($0.id) }) else { return [] }
        guard let wildcardRank else {
            return substitutions.isEmpty ? patterns(cards).map { LandlordInterpretation(pattern: $0) } : []
        }
        guard (3...15).contains(wildcardRank), substitutions.allSatisfy({ id, rank in
            (3...15).contains(rank) && cards.contains { $0.id == id && $0.rank == wildcardRank }
        }), cards.count != 1 || substitutions.isEmpty else { return [] }
        var counts: [Int: Int] = [:]
        for card in cards { counts[substitutions[card.id] ?? card.rank, default: 0] += 1 }
        guard counts.allSatisfy({ rank, count in count <= (rank >= 16 ? 1 : 4) }) else { return [] }
        let virtual = counts.sorted(by: { $0.key < $1.key }).flatMap { rank, count in
            (0..<count).map { LandlordCard(id: rank >= 16 ? rank + 36 : (rank - 3) * 4 + $0) }
        }
        let changed = substitutions.filter { $0.value != wildcardRank }
        return patterns(virtual).map { pattern in
            var classified = pattern
            if pattern.kind == .bomb {
                if cards.allSatisfy({ $0.rank == wildcardRank }) {
                    classified = LandlordPattern(kind: .bomb, high: wildcardRank, count: 4, run: 1, bombTier: .pureWild)
                    return LandlordInterpretation(pattern: classified)
                }
                else if !changed.isEmpty { classified.bombTier = .soft }
            }
            return LandlordInterpretation(pattern: classified, substitutions: changed)
        }
    }

    /// At most C(16,4)=1820 rank multisets, instead of 13^4 permutations.
    /// Only called for the human's selected cards; bots construct bounded templates.
    static func choices(_ cards: [LandlordCard], wildcardRank: Int?, beating target: LandlordPattern?) -> [LandlordInterpretation] {
        guard let rank = wildcardRank, cards.count > 1 else {
            return interpret(cards, wildcardRank: wildcardRank, substitutions: [:]).filter { target.map($0.pattern.beats) ?? true }
        }
        let wild = cards.filter { $0.rank == rank }.sorted { $0.id < $1.id }
        guard wild.count <= 4 else { return [] }
        var best: [LandlordPattern: LandlordInterpretation] = [:]
        var assignment: [Int: Int] = [:]
        func visit(_ index: Int, minimum: Int) {
            if index == wild.count {
                for choice in interpret(cards, wildcardRank: rank, substitutions: assignment) where target.map(choice.pattern.beats) ?? true {
                    if best[choice.pattern].map({ $0.substitutions.count <= choice.substitutions.count }) != true { best[choice.pattern] = choice }
                }
                return
            }
            for value in minimum...15 { assignment[wild[index].id] = value; visit(index + 1, minimum: value) }
        }
        visit(0, minimum: 3)
        return best.values.sorted { a, b in
            if a.pattern.tier != b.pattern.tier { return a.pattern.tier < b.pattern.tier }
            if a.pattern.high != b.pattern.high { return a.pattern.high < b.pattern.high }
            return a.id < b.id
        }
    }

    static func availableMoves(_ hand: [LandlordCard], wildcardRank: Int?, beating target: LandlordPattern?) -> [LandlordMove] {
        guard let wildcardRank else {
            return moves(hand, beating: target).compactMap { cards in
                pattern(cards, beating: target).map { LandlordMove(cards: cards, interpretation: .init(pattern: $0)) }
            }
        }
        var output: [LandlordMove] = [], seen = Set<String>()
        func append(_ cards: [LandlordCard], _ substitutions: [Int: Int]) {
            for choice in interpret(cards, wildcardRank: wildcardRank, substitutions: substitutions) where target.map(choice.pattern.beats) ?? true {
                let key = cards.map(\.id).sorted().map(String.init).joined(separator: ",") + choice.id
                if seen.insert(key).inserted { output.append(.init(cards: cards, interpretation: choice)) }
            }
        }
        for cards in moves(hand, beating: nil) { append(cards, [:]) }
        let ordered = LandlordCard.ordered(hand)
        func construct(_ ranks: [Int]) -> ([LandlordCard], [Int: Int])? {
            guard ranks.count <= hand.count else { return nil }
            var available = ordered, cards: [LandlordCard] = [], substitutions: [Int: Int] = [:]
            for rank in ranks {
                let natural = available.firstIndex { $0.rank == rank }
                let index = natural ?? (rank < 16 ? available.firstIndex { $0.rank == wildcardRank } : nil)
                guard let index else { return nil }
                let card = available.remove(at: index); cards.append(card)
                if card.rank != rank { substitutions[card.id] = rank }
            }
            return (cards, substitutions)
        }
        func make(_ body: [Int], singleWings: Int = 0, pairWings: Int = 0) {
            guard let (initial, _) = construct(body) else { return }
            let excluded = Set(body)
            var rest = ordered.filter { card in !initial.contains(where: { $0.id == card.id }) }
            var wings: [Int] = []
            if singleWings > 0 {
                let candidates = rest.filter { !excluded.contains($0.rank) }
                guard candidates.count >= singleWings else { return }
                wings = candidates.prefix(singleWings).map(\.rank)
            }
            for _ in 0..<pairWings {
                let ranks = (3...15).filter { !excluded.contains($0) && !wings.contains($0) }
                let value = ranks.first { rank in rest.filter { $0.rank == rank }.count >= 2 }
                    ?? ranks.first { rank in rest.filter { $0.rank == rank || $0.rank == wildcardRank }.count >= 2 }
                guard let value else { return }
                for _ in 0..<2 {
                    guard let i = rest.firstIndex(where: { $0.rank == value }) ?? rest.firstIndex(where: { $0.rank == wildcardRank }) else { return }
                    rest.remove(at: i)
                }
                wings += [value, value]
            }
            if let (cards, subs) = construct(body + wings) { append(cards, subs) }
        }
        for rank in 3...15 {
            for n in 2...4 { make(Array(repeating: rank, count: n)) }
            for wing in 3...17 where wing != rank {
                make([rank, rank, rank, wing])
                if wing < 16 { make([rank, rank, rank, wing, wing]) }
            }
            make(Array(repeating: rank, count: 4), singleWings: 2)
            make(Array(repeating: rank, count: 4), pairWings: 2)
        }
        for multiplicity in 1...3 {
            let minimum = multiplicity == 1 ? 5 : multiplicity == 2 ? 3 : 2
            for low in 3...14 {
                guard low + minimum - 1 <= 14 else { continue }
                for high in (low + minimum - 1)...14 {
                    let body = (low...high).flatMap { Array(repeating: $0, count: multiplicity) }
                    guard body.count <= hand.count else { break }
                    make(body)
                    if multiplicity == 3 {
                        make(body, singleWings: high - low + 1)
                        make(body, pairWings: high - low + 1)
                    }
                }
            }
        }
        return output.sorted { a, b in
            if a.interpretation.pattern.tier != b.interpretation.pattern.tier { return a.interpretation.pattern.tier < b.interpretation.pattern.tier }
            if target == nil && a.cards.count != b.cards.count { return a.cards.count > b.cards.count }
            if a.interpretation.pattern.high != b.interpretation.pattern.high { return a.interpretation.pattern.high < b.interpretation.pattern.high }
            return a.interpretation.id + a.cards.map(\.id).description < b.interpretation.id + b.cards.map(\.id).description
        }
    }
}
