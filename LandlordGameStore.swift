import SwiftUI

@MainActor final class LandlordGameStore: ObservableObject {
    @Published private(set) var game: LandlordGame
    @Published var preferences: CardMediaPreferences
    @Published private(set) var selection: [Int] = []
    @Published var automatic = false
    @Published var paused = false
    @Published var message = ""
    @Published private(set) var summaries: [[Int]] = []
    private var task: Task<Void, Never>?
    private var visible = false
    private var recorded: UUID?
    private let defaults: UserDefaults
    var mapping: CardMediaMapping {
        CardMediaMapping(cards: Array(0..<54), media: preferences.mediaIDs, game: game.id, cycle: preferences.cycle)
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "landlord-game-v241"),
           let restored = try? JSONDecoder().decode(LandlordGame.self, from: data), restored.validated {
            game = restored
        } else { game = LandlordGame() }
        preferences = defaults.data(forKey: "landlord-media-v241").flatMap { try? JSONDecoder().decode(CardMediaPreferences.self, from: $0) } ?? CardMediaPreferences()
        summaries = Array((defaults.array(forKey: "landlord-scores-v241") as? [[Int]] ?? []).suffix(3))
    }
    func persist() {
        defaults.set(try? JSONEncoder().encode(game), forKey: "landlord-game-v241")
        defaults.set(try? JSONEncoder().encode(preferences), forKey: "landlord-media-v241")
        defaults.set(summaries, forKey: "landlord-scores-v241")
    }
    func activate(_ active: Bool) { visible = active; if !active { persist() }; schedule() }
    func refresh() { persist(); schedule() }
    func choose(_ id: Int) {
        guard game.hands[0].contains(where: { $0.id == id }) else { return }
        if selection.contains(id) { selection.removeAll { $0 == id } } else { selection.append(id) }
    }
    func hint() { selection = game.suggestion(for: 0); message = selection.isEmpty ? "没有可压过的牌，可以不出。" : "已按提示选牌，可继续调整。" }
    func bid(_ value: Int) { changed(game.bid(value, player: 0)) }
    func play() { changed(game.play(selection, player: 0)) }
    func pass() { changed(game.pass(player: 0)) }
    func newGame() { task?.cancel(); game = LandlordGame(); selection = []; automatic = false; message = "新一局，请叫分。"; refresh() }
    private func changed(_ success: Bool) {
        if success { selection = []; message = ""; complete(); refresh() }
        else { message = "当前选牌不符合牌型或不能压过上一手。" }
    }
    private func complete() {
        guard game.phase == .finished, recorded != game.id else { return }
        recorded = game.id; summaries.append(game.scores); summaries = Array(summaries.suffix(3))
    }
    private func schedule() {
        task?.cancel(); task = nil
        guard visible, !paused, game.phase == .bidding || game.phase == .playing,
              game.turn != 0 || automatic else { return }
        let round = game.id
        task = Task { [weak self] in
            let fast = ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests")
            try? await Task.sleep(nanoseconds: fast ? 40_000_000 : 750_000_000)
            guard !Task.isCancelled, let self, self.game.id == round, self.visible, !self.paused else { return }
            if self.game.autoAct() { self.selection = []; self.complete(); self.refresh() }
        }
    }
}