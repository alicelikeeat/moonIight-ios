import SwiftUI
import Combine

/// The world save and its story. Since v1.88 the sandbox is the 3D world:
/// `Glass3DController` edits `world.spatial` through `commitSpatial`, and
/// reports where the player is, which creatures fell and which blocks broke
/// so the story can follow. This class opens, switches and saves worlds,
/// runs the story, and keeps the player's health, stamina and moon shards.
/// Saves from the old 2D sandbox open unchanged; only the 2D wandering
/// enemies (never visible in 3D) are dropped when a world opens.
@MainActor final class RPGSession: ObservableObject {
    private(set) var world = WorldState() { didSet { if !simulating { objectWillChange.send() } } }
    /// Set while a change should not redraw observers (position, vitals).
    private var simulating = false
    @Published private(set) var pendingStory = false
    @Published private(set) var recoveryChoices: [RPGRecoveryChoice] = []
    /// Set when the world could not be loaded and nothing is recoverable,
    /// so the sandbox shows a create/retry screen instead of a blank one.
    @Published private(set) var loadError: String?
    @Published private(set) var notice = L10n.t("正在读取世界…", "Loading world…")
    @Published private(set) var active = false
    @Published private(set) var ready = false
    @Published private(set) var working = false
    @Published private(set) var saveState = RPGSaveState.saved
    /// The 3D world's glass quality, kept between launches.
    @Published var glassQuality = RPGGlassQuality(rawValue: UserDefaults.standard.string(forKey: "moonlight.world.glassQuality") ?? "") ?? .standard {
        didSet { UserDefaults.standard.set(glassQuality.rawValue, forKey: "moonlight.world.glassQuality") }
    }
    private var boot: Task<Void, Never>?
    private var edit: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var generation = UUID()
    private var terrainGenerator = RPGWorldGenerator(seed: 20261102)
    private let storage: RPGWorldDiskStore
    private static var testReset = false
    #if DEBUG
    private static var testRecoveryPrepared = false
    private static var testFuturePrepared = false
    private static var testVillagePrepared = false
    #endif
    /// Story places (anchors) for this world's seed, on the shared grid.
    var generator: RPGWorldGenerator { terrainGenerator }

    init() {
        var root = RPGWorldDiskStore.defaultURL()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests") {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RPG-UITests", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--rpg-reset-world") && !Self.testReset {
                try? FileManager.default.removeItem(at: root); Self.testReset = true
            }
        }
        #endif
        storage = RPGWorldDiskStore(root: root)
    }

    // MARK: Opening worlds

    func activate() {
        active = true
        if !ready && boot == nil { loadWorld() }
    }
    func pause() { active = false; silenceMedia(); save(leaving: true) }

    func recoverWorld(_ id: String) {
        guard !ready, !working, recoveryChoices.contains(where: { $0.id == id }) else { return }
        working = true; let epoch = generation, storage = storage
        boot = Task { [weak self] in
            do {
                let value = try await storage.load(id: id); try await storage.save(value)
                guard let self, !Task.isCancelled, self.generation == epoch else { return }
                self.boot = nil; self.assign(value); self.notice = L10n.t("已恢复选中的保留世界。", "Restored the selected saved world.")
            } catch { guard let self, self.generation == epoch else { return }; self.boot = nil; self.working = false; self.notice = error.localizedDescription }
        }
    }

    func loadWorld() {
        let epoch = generation, storage = storage
        boot = Task { [weak self] in
            do {
                #if DEBUG
                try await Self.prepareTestFixtures(storage)
                #endif
                let value = try await storage.load() ?? WorldState()
                let recovered = await storage.recoveredFromBackup
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.boot = nil; self.assign(value)
                self.notice = recovered ? L10n.t("已从保留的有效存档恢复。", "Restored from the last valid save.") : L10n.t("世界已就绪。", "World ready.")
            } catch {
                guard let self, self.generation == epoch else { return }
                self.boot = nil; self.notice = error.localizedDescription; self.ready = false; self.loadError = error.localizedDescription
                if error as? RPGWorldError != .unsupportedVersion {
                    let choices = (try? await storage.recoverableWorlds()) ?? []
                    guard !Task.isCancelled, self.generation == epoch else { return }
                    self.recoveryChoices = choices
                }
            }
        }
    }

    #if DEBUG
    /// UI-test worlds: two interrupted saves to choose between, or a world
    /// from a newer app version that must neither open nor be overwritten.
    private static func prepareTestFixtures(_ storage: RPGWorldDiskStore) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--rpg-recovery-ui-tests"), !testRecoveryPrepared {
            testRecoveryPrepared = true
            let root = await storage.root
            enum Interrupted: Error { case beforeIndex }
            let interrupted = RPGWorldDiskStore(root: root, fault: { if $0 == .beforePointer { throw Interrupted.beforeIndex } })
            for id in ["recover-target", "recover-other"] {
                var fixture = WorldState(seed: id == "recover-target" ? 42 : 43); fixture.id = id
                let generator = RPGWorldGenerator(seed: fixture.seed); fixture.generated = true; fixture.player.surface = generator.anchor(.spawn); fixture.sideRegions = [generator.sideRegion]
                fixture.entities = [.init(id: "recovered-building", definitionID: "wood", scope: .topDownOnly, surface: .init(x: 30, z: 30))]
                let graph = RPGStoryGraph(id: "recovery.graph", title: "恢复回执", start: "end", nodes: [.init(id: "end", kind: .end, text: "奖励已经保存", actions: [.init(kind: .giveItem, key: "moon-shard", value: 7)])])
                try RPGStoryAuthoring.install(graph, bindings: [], world: &fixture); try RPGStoryRuntime.start(graphID: graph.id, world: &fixture); try RPGStoryRuntime.advance(world: &fixture, generator: generator)
                do { try await interrupted.save(fixture) } catch Interrupted.beforeIndex {}
            }
        }
        if arguments.contains("--rpg-story-village-ui-tests"), !testVillagePrepared {
            // The official story played up to "walk to 月光村", the way the
            // 3D world gets there (a block broken in 3D).
            testVillagePrepared = true
            var fixture = WorldState(seed: 42); fixture.id = "story-village"
            let generator = RPGWorldGenerator(seed: 42); fixture.generated = true; fixture.player.surface = generator.anchor(.spawn); fixture.sideRegions = [generator.sideRegion]
            try RPGStoryRuntime.start(graphID: RPGOfficialStory.graph.id, world: &fixture)
            try RPGStoryRuntime.advance(world: &fixture, generator: generator)
            try RPGStoryRuntime.advance(world: &fixture, generator: generator)
            try RPGStoryRuntime.advance(choiceID: "help", world: &fixture, generator: generator)
            RPGStorySpatial.blocksDestroyed(["fixture-block"], world: &fixture)
            try RPGStoryRuntime.advance(world: &fixture, generator: generator)
            try await storage.save(fixture)
        }
        if arguments.contains("--rpg-future-world-ui-tests"), !testFuturePrepared {
            testFuturePrepared = true
            let root = await storage.root, folder = root.appendingPathComponent("Worlds/future-world", isDirectory: true)
            var fixture = WorldState(seed: 7); fixture.id = "future-world"
            if var object = try JSONSerialization.jsonObject(with: RPGWorldCodec.encode(fixture)) as? [String: Any] {
                object["schemaVersion"] = WorldState.currentSchema + 1
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("world.json"))
                try Data(#"{"id":"future-world"}"#.utf8).write(to: root.appendingPathComponent("active.json"))
            }
        }
    }
    #endif

    private func assign(_ value: WorldState) {
        recoveryChoices = []; loadError = nil
        generation = UUID(); saving?.cancel(); edit?.cancel()
        world = value; silenceMedia(); terrainGenerator = .init(seed: world.seed)
        if !world.generated { world.player.surface = generator.anchor(.spawn); world.sideRegions = [generator.sideRegion]; world.generated = true }
        RPGStorySpatial.normalize(&world)
        storyConditionWasMet = RPGStorySpatial.conditionMet(world: world, generator: generator)
        ready = true; working = false
    }

    /// Name shown for the current world. Saves have no name field, so it is
    /// derived from what identifies the world.
    var worldTitle: String { (world.isCreativeCopy ? L10n.t("创作副本", "Creative Copy") : L10n.t("原世界", "Original World")) + " · Seed \(world.seed)" }
    var modeTitle: String { world.player.mode == .creative ? L10n.t("创造模式", "Creative") : L10n.t("冒险模式", "Adventure") }
    var perspectiveTitle: String { L10n.t("3D 世界", "3D World") }
    /// The active story and the step the player is on.
    var questSummary: String {
        let graph = world.story.activeGraph, progress = world.story.activeProgress
        if progress?.ended == true { return graph.title + L10n.t(" · 已完成", " · Done") }
        guard let node = graph.nodes.first(where: { $0.id == (progress?.current ?? graph.start) }) else { return graph.title }
        let text = node.text.isEmpty ? node.kind.rawValue : node.text
        return graph.title + " · " + (text.count > 28 ? String(text.prefix(28)) + "…" : text)
    }
    /// Every world kept on disk, for the world switcher.
    func listWorlds() async -> [RPGRecoveryChoice] { (try? await storage.recoverableWorlds()) ?? [] }
    /// Saves the current world, then opens another one kept on disk.
    func switchWorld(_ id: String) {
        guard !working, id != world.id || !ready else { return }
        replaceWorld { storage in try await storage.load(id: id) }
    }
    /// Saves the current world (if any), then starts a new one with a fresh
    /// seed. Existing worlds, readable or not, stay on disk untouched.
    func createWorld() {
        guard !working else { return }
        replaceWorld { _ in WorldState(seed: UInt64.random(in: 1...999_999_999)) }
    }
    private func replaceWorld(_ next: @escaping @Sendable (RPGWorldDiskStore) async throws -> WorldState) {
        working = true; silenceMedia()
        let current = ready ? world : nil, epoch = generation, storage = storage
        boot = Task { [weak self] in
            do {
                if let current { try await storage.save(current) }
                let value = try await next(storage); try await storage.save(value)
                guard let self, !Task.isCancelled, self.generation == epoch else { return }
                self.boot = nil; self.assign(value); self.notice = L10n.t("已打开：", "Opened: ") + self.worldTitle
            } catch {
                guard let self, self.generation == epoch else { return }
                self.boot = nil; self.working = false; self.notice = error.localizedDescription
            }
        }
    }
    func creativeCopy() {
        guard ready, !working else { return }
        saving?.cancel(); working = true; let snapshot = world, storage = storage, epoch = generation
        Task { [weak self] in
            do {
                try await storage.save(snapshot)
                var copy = snapshot; copy.parentWorldID = snapshot.parentWorldID ?? snapshot.id; copy.id = UUID().uuidString
                copy.isCreativeCopy = true; copy.player.mode = .creative; copy.player.surface = RPGWorldGenerator(seed: copy.seed).anchor(.creation)
                copy.undo = []; copy.redo = []; copy.events = []; copy.revision = 0
                try await storage.save(copy)
                guard let self, self.generation == epoch else { return }; self.assign(copy); self.notice = L10n.t("已进入独立创作副本，原世界保留。", "Entered a creative copy; the original world is kept.")
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }
    func returnToOriginal() {
        guard let id = world.parentWorldID, ready, !working else { return }
        saving?.cancel(); working = true; let snapshot = world, storage = storage, epoch = generation
        Task { [weak self] in
            do {
                try await storage.save(snapshot); let original = try await storage.load(id: id); try await storage.save(original)
                guard let self, self.generation == epoch else { return }; self.assign(original); self.notice = L10n.t("已返回原世界。", "Back to the original world.")
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }

    // MARK: Saving

    /// Story media start muted every time a world opens or closes.
    private func silenceMedia() {
        if world.mediaBindings.contains(where: { !$0.muted }) {
            for index in world.mediaBindings.indices { world.mediaBindings[index].muted = true }; world.revision += 1
        }
    }
    func saveBeforeExit() async -> Bool {
        guard ready else { return true }
        guard !working else { notice = L10n.t("请等待当前操作完成。", "Please wait for the current action to finish."); return false }
        silenceMedia(); saving?.cancel(); working = true
        do { try await storage.save(world); active = false; working = false; return true }
        catch { working = false; notice = error.localizedDescription; return false }
    }
    /// `leaving`: the world is being paused; the widgets redraw right away.
    func save(leaving: Bool = false) {
        guard ready else { return }
        saveState = .saving
        saving?.cancel(); let snapshot = world, epoch = generation, storage = storage
        saving = Task { [weak self] in
            do {
                try await storage.save(snapshot)
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.notice = L10n.t("世界已保存 · 修订 \(snapshot.revision)", "World saved · revision \(snapshot.revision)"); self.saveState = .saved
                MoonlightWidgetBridge.publish(MoonlightWidgetBridge.snapshot(
                    title: self.worldTitle, health: snapshot.player.health, stamina: snapshot.player.stamina,
                    shards: snapshot.inventory["moon-shard", default: 0], revision: Int(clamping: snapshot.revision), spatial: snapshot.spatial), leaving: leaving)
            } catch {
                guard !Task.isCancelled, let self, self.generation == epoch else { return }; self.notice = error.localizedDescription
                self.saveState = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs a world change off the main thread, then commits it if nothing
    /// else changed the world meanwhile.
    private func perform(_ action: @escaping @Sendable (inout WorldState, RPGWorldGenerator) throws -> Void) {
        guard ready, !working, world.player.health > 0 else { return }
        working = true; let snapshot = world, generator = generator, epoch = generation
        edit = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<WorldState, Error> in
                do { var value = snapshot; try action(&value, generator); return .success(value) } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self, self.generation == epoch else { return }
            self.working = false
            switch result {
            case .success(let value):
                guard self.world.revision == snapshot.revision else { self.notice = RPGEditError.stale.localizedDescription; return }
                self.world = value
                RPGStoryRuntime.recordEvents(world: &self.world)
                self.storyConditionWasMet = RPGStorySpatial.conditionMet(world: self.world, generator: self.generator)
                self.notice = L10n.t("操作已提交。", "Done."); self.save()
            case .failure(let error): self.notice = error.localizedDescription
            }
        }
    }

    // MARK: 3D world: same save, same health and shards

    /// The 3D layer; a blank sheet of glass until something is built.
    var spatialWorld: SpatialWorld { world.spatial ?? .blank() }
    var playerHealth: Int { world.player.health }
    var playerStamina: Int { world.player.stamina }
    var moonShards: Int { world.inventory["moon-shard", default: 0] }

    /// Writes the 3D layer (and any new media bindings) into the shared
    /// world, validated; saved atomically by the world storage.
    @discardableResult
    func commitSpatial(_ value: SpatialWorld, addBindings: [MediaBinding] = [], persist: Bool = true) -> Bool {
        guard ready, !working else { return false }
        var next = world
        next.spatial = value
        for binding in addBindings where !next.mediaBindings.contains(where: { $0.id == binding.id }) { next.mediaBindings.append(binding) }
        if next.mediaBindings.count > 960 { try? RPGMediaBindings.pruneUnreferenced(&next) }
        do { try next.validate() } catch { notice = error.localizedDescription; return false }
        next.revision += 1
        world = next
        if persist { save() }
        return true
    }
    /// Health, stamina and shards changed by 3D combat and chests.
    func applySpatialVitals(health: Int, stamina: Int, shardDelta: Int = 0) {
        guard ready else { return }
        simulating = true
        world.player.health = max(0, min(100, health)); world.player.stamina = max(0, min(100, stamina))
        if shardDelta != 0 { world.inventory["moon-shard", default: 0] = max(0, min(1_000_000, world.inventory["moon-shard", default: 0] + shardDelta)) }
        simulating = false
    }

    // MARK: Story

    func acknowledgeStory() { pendingStory = false }
    func installStory(_ graph: RPGStoryGraph, bindings: [MediaBinding]) -> Bool {
        guard ready, !working else { return false }
        do { try RPGStoryAuthoring.install(graph, bindings: bindings, world: &world); save(); return true }
        catch { notice = error.localizedDescription; return false }
    }
    func recordStoryMedia(_ nodeID: String, seconds: Double) {
        guard ready, seconds.isFinite, (0...10_000_000).contains(seconds) else { return }
        let key = world.story.activeGraphID + ":" + nodeID
        guard world.story.mediaPositions[key] != nil || world.story.mediaPositions.count < 4096 else { return }
        world.story.mediaPositions[key] = seconds; world.revision += 1; save()
    }
    func prepareStory() {
        guard ready, world.story.activeProgress == nil else { return }
        beginStory(world.story.activeGraphID)
    }
    func beginStory(_ id: String) {
        guard ready, !working else { return }
        do {
            let new = !world.story.progress.contains { $0.id == id }
            try RPGStoryRuntime.start(graphID: id, world: &world)
            if new { try RPGStoryRuntime.advance(world: &world, generator: generator) }
            storyConditionWasMet = RPGStorySpatial.conditionMet(world: world, generator: generator)
            save()
        } catch { notice = error.localizedDescription }
    }
    func advanceStory(choice: String? = nil) {
        perform { world, generator in try RPGStoryRuntime.advance(choiceID: choice, world: &world, generator: generator) }
    }

    // MARK: Story in the 3D world

    /// Whether the current quest's condition held at the last check: the
    /// story panel opens once when it becomes true.
    private var storyConditionWasMet = false
    /// The 3D player's position; four times a second from the 3D world.
    func storyPlayerMoved3D(_ position: SpatialVector) {
        guard ready else { return }
        simulating = true
        let moved = RPGStorySpatial.syncPlayer(position, world: &world)
        simulating = false
        if moved { checkStoryObjective() }
    }
    /// A creature fell in 3D; story enemies are recorded and saved.
    func storyCreatureDefeated3D(_ id: String) {
        guard ready, RPGStorySpatial.defeated(id, world: &world) else { return }
        RPGStoryRuntime.recordEvents(world: &world); checkStoryObjective(); save()
    }
    /// Blocks removed in 3D count as broken for the story.
    func storyBlocksDestroyed3D(_ ids: [String]) {
        guard ready, !ids.isEmpty else { return }
        RPGStorySpatial.blocksDestroyed(ids, world: &world)
        RPGStoryRuntime.recordEvents(world: &world); checkStoryObjective(); save()
    }
    var storyObjective: RPGStorySpatial.Objective? { ready ? RPGStorySpatial.objective(world: world, generator: generator) : nil }
    private func checkStoryObjective() {
        let met = RPGStorySpatial.conditionMet(world: world, generator: generator)
        if met && !storyConditionWasMet { pendingStory = true }
        storyConditionWasMet = met
    }
}
