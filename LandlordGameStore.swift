import SwiftUI

@MainActor final class LandlordGameStore: ObservableObject {
    @Published private(set) var game: LandlordGame
    @Published var preferences: CardMediaPreferences
    @Published var table: LandlordTablePreferences
    @Published private(set) var selection: [Int] = []
    @Published var automatic = false
    @Published var paused = false
    @Published var message = ""
    @Published private(set) var summaries: [[Int]] = []
    @Published private(set) var interpretations: [LandlordInterpretation] = []
    @Published private(set) var thinking = false
    private var task: Task<Void, Never>?
    private var choicesTask: Task<Void, Never>?
    private var visible = false
    private var recorded: UUID?
    private let defaults: UserDefaults
    private let legacyMode: Bool
    private let writer: VersionedJSONWriter<LandlordGame>
    private var saveSequence = 0
    var mapping: CardMediaMapping {
        CardMediaMapping(cards: Array(0..<54), media: preferences.mediaIDs, game: game.id, cycle: preferences.cycle)
    }
    init(defaults: UserDefaults = .standard, legacy: Bool = false) {
        self.defaults = defaults
        legacyMode = legacy
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Games/Landlord")
        let file = VersionedJSONFile<LandlordGame>(directory: directory, name: legacy ? "legacy-session" : "session", schemaVersion: 1, maximumBytes: 256 << 10)
        var revision = 0, blocked = false
        var restored: LandlordGame?
        var loadingMessage = ""
        do {
            if let snapshot = try file.load() {
                revision = snapshot.revision
                if snapshot.payload.validated { restored = snapshot.payload }
                else { blocked = true; loadingMessage = "保存的对局未通过校验，已保留原文件，本次不覆盖。" }
            }
        } catch { blocked = true; loadingMessage = "对局存档暂不可写：\(error.localizedDescription)。原文件已保留。" }
        let testing = ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") || ProcessInfo.processInfo.arguments.contains("--landlord-liquid-ui-tests")
        let resetTesting = testing && !ProcessInfo.processInfo.arguments.contains("--landlord-resume-ui-tests")
        if !testing, restored == nil, !file.exists, let data = defaults.data(forKey: "landlord-game-v241"),
           let legacy = try? JSONDecoder().decode(LandlordGame.self, from: data), legacy.validated { restored = legacy }
        game = resetTesting ? Self.freshGame() : restored ?? Self.freshGame()
        writer = VersionedJSONWriter(file: file, loadedRevision: revision, blocked: blocked)
        preferences = defaults.data(forKey: "landlord-media-v241").flatMap { try? JSONDecoder().decode(CardMediaPreferences.self, from: $0) } ?? CardMediaPreferences()
        table = defaults.data(forKey: "landlord-table-v1").flatMap { try? JSONDecoder().decode(LandlordTablePreferences.self, from: $0) } ?? LandlordTablePreferences()
        table.normalize(); table.begin(game.id)
        if resetTesting { table = LandlordTablePreferences(); table.begin(game.id); preferences = CardMediaPreferences() }
        if legacy { table.nextGameWild = false }
        summaries = Array((defaults.array(forKey: "landlord-scores-v241") as? [[Int]] ?? []).filter { $0.count == 3 }.suffix(3))
        recorded = defaults.string(forKey: "landlord-recorded-round").flatMap(UUID.init(uuidString:))
        message = loadingMessage
    }
    private static func freshGame(wild: Bool = false) -> LandlordGame {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") || ProcessInfo.processInfo.arguments.contains("--landlord-liquid-ui-tests") {
            return LandlordGame(deck: LandlordCard.deck, wildcardRank: wild ? 7 : nil)
        }
        #endif
        return LandlordGame(wildcardRank: wild ? Int.random(in: 3...15) : nil)
    }
    func persist() {
        saveSequence += 1
        let sequence = saveSequence, snapshot = game
        Task { [weak self, writer] in
            do { try await writer.save(snapshot, sequence: sequence) }
            catch { self?.message = "对局保存失败：\(error.localizedDescription)" }
        }
        // Keep the old key untouched for backwards recovery.
        defaults.set(try? JSONEncoder().encode(preferences), forKey: "landlord-media-v241")
        defaults.set(try? JSONEncoder().encode(table), forKey: "landlord-table-v1")
        defaults.set(summaries, forKey: "landlord-scores-v241")
        defaults.set(recorded?.uuidString, forKey: "landlord-recorded-round")
    }
    func activate(_ active: Bool) { visible = active; if !active { persist() }; schedule() }
    func refresh() { table.normalize(); persist(); schedule() }
    func choose(_ id: Int) {
        guard game.hands[0].contains(where: { $0.id == id }) else { return }
        if selection.contains(id) { selection.removeAll { $0 == id } } else { selection.append(id) }
        dismissChoices()
    }
    func setSelection(_ ids: [Int]) {
        selection = Array(Set(ids).intersection(Set(game.hands[0].map(\.id)))).sorted()
        dismissChoices()
    }
    func hint() {
        guard !thinking else { return }
        let snapshot = game
        thinking = true
        choicesTask = Task { [weak self] in
            let move = await Task.detached(priority: .userInitiated) { snapshot.suggestedMove(for: 0) }.value
            guard !Task.isCancelled, let self else { return }
            thinking = false
            guard game == snapshot else { return }
            selection = move?.cards.map(\.id) ?? []
            message = selection.isEmpty ? "未找到推荐出牌，可手动选择或不出。" : "已选好建议牌，点出牌确认；癞子解释可在候选中调整。"
        }
    }
    func bid(_ value: Int) { changed(game.bid(value, player: 0)) }
    func play() {
        guard game.turn == 0, game.phase == .playing, !thinking else { return }
        let snapshot = game, selected = selection
        thinking = true
        choicesTask = Task { [weak self] in
            let choices = await Task.detached(priority: .userInitiated) { snapshot.choices(for: selected) }.value
            guard !Task.isCancelled, let self else { return }
            thinking = false
            guard game == snapshot, selection == selected else { return }
            if choices.count > 1 && !legacyMode { interpretations = choices; paused = true; schedule() }
            else if let choice = choices.first { commit(choice) }
            else { message = "当前选牌不符合牌型或不能压过上一手。" }
        }
    }
    func commit(_ choice: LandlordInterpretation) {
        interpretations = []; paused = false
        changed(game.play(selection, player: 0, declared: choice))
    }
    func dismissChoices() {
        choicesTask?.cancel(); choicesTask = nil; thinking = false
        if !interpretations.isEmpty { interpretations = []; paused = false; schedule() }
    }
    func pass() { changed(game.pass(player: 0)) }
    func newGame() {
        task?.cancel(); dismissChoices()
        game = Self.freshGame(wild: !legacyMode && table.nextGameWild); table.begin(game.id)
        selection = []; automatic = false; message = "新一局，请叫分。"; refresh()
    }
    private func changed(_ success: Bool) {
        if success { selection = []; message = ""; complete(); refresh() }
        else { message = "当前操作不符合轮次、牌型或压制规则。" }
    }
    private func complete() {
        guard game.phase == .finished, recorded != game.id else { return }
        recorded = game.id; summaries.append(game.scores); summaries = Array(summaries.suffix(3))
    }
    private func schedule() {
        task?.cancel(); task = nil
        guard visible, !paused, game.phase == .bidding || game.phase == .playing,
              game.turn != 0 || automatic else { return }
        let snapshot = game
        task = Task { [weak self] in
            let fast = ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") || ProcessInfo.processInfo.arguments.contains("--landlord-liquid-ui-tests")
            do { try await Task.sleep(for: .milliseconds(fast ? 40 : 850)) } catch { return }
            let advanced = await Task.detached(priority: .userInitiated) { () -> LandlordGame in
                var copy = snapshot; _ = copy.autoAct(); return copy
            }.value
            guard !Task.isCancelled, let self, game == snapshot, visible, !paused else { return }
            if advanced != snapshot { game = advanced; selection = []; complete(); refresh() }
        }
    }
}
