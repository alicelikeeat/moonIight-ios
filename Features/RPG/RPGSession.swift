import SwiftUI

enum RPGTool: String, CaseIterable { case select, paint, erase }
@MainActor final class RPGSession: ObservableObject {
    @Published private(set) var world = WorldState()
    @Published private(set) var notice = "正在读取世界…"
    @Published private(set) var active = false
    @Published private(set) var ready = false
    @Published private(set) var working = false { didSet { applyScenePause() } }
    @Published private(set) var loadedChunks = 0
    @Published private(set) var selected: SurfacePoint?
    @Published private(set) var selectedSide: SidePlacement?
    @Published private(set) var projectionEvidence = ""
    @Published private(set) var overlayVisible = false
    let sideScene = RPGSideScene()
    @Published var definition = "wood"
    @Published var tool = RPGTool.select { didSet { scene.tool = tool } }
    @Published private(set) var rangeStart: SurfacePoint?
    @Published private(set) var hasClipboard = false
    let scene = RPGTopDownScene()
    private var chunks: [RPGChunk] = []
    private var cache: RPGChunkCache?
    private var loading: Task<Void, Never>?
    private var boot: Task<Void, Never>?
    private var edit: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var generation = UUID()
    private var displayedChunk: ChunkCoordinate?
    private var terrainGenerator = RPGWorldGenerator(seed: 20261102)
    private let storage: RPGWorldDiskStore
    private var clipboard: RPGClipboard?
    private static var testReset = false
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
    func activate() {
        active = true; bindScenes(); applyScenePause()
        if ready { loadVisible(force: true) } else if boot == nil { loadWorld() }
    }
    func loadWorld() {
        let epoch = generation, storage = storage
        boot = Task { [weak self] in
            do {
                let value = try await storage.load() ?? WorldState()
                let recovered = await storage.recoveredFromBackup
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.boot = nil; self.assign(value)
                self.notice = recovered ? "已从上一份有效备份恢复。" : "世界已就绪。"
            } catch {
                guard let self, self.generation == epoch else { return }
                self.boot = nil; self.notice = error.localizedDescription; self.ready = false
            }
        }
    }
    private func assign(_ value: WorldState) {
        generation = UUID(); loading?.cancel(); saving?.cancel()
        scene.shutdown(); sideScene.shutdown()
        world = value; terrainGenerator = .init(seed: world.seed)
        if !world.generated { world.player.surface = generator.anchor(.spawn); world.sideRegions = [generator.sideRegion]; world.generated = true }
        cache = RPGChunkCache(seed: world.seed); chunks = []; displayedChunk = nil; selected = nil; rangeStart = nil
        ready = true; working = false
        bindScenes(); applyScenePause(); scene.tool = tool
        loadVisible(force: true)
    }
    func pause() { active = false; applyScenePause(); loading?.cancel(); save() }
    func shutdown() {
        save(); active = false; generation = UUID(); loading?.cancel(); boot?.cancel(); edit?.cancel(); boot = nil
        scene.shutdown(); sideScene.shutdown(); let old = cache; Task { await old?.clear() }; cache = nil; chunks = []; displayedChunk = nil
    }
    func move(dx: Int, dz: Int) {
        guard active, ready, !working, abs(dx) <= 1, abs(dz) <= 1 else { return }
        if world.player.perspective == .side {
            if dz > 0 { sideScene.jump() }; if dx != 0 { sideScene.step(dx) }; return
        }
        let old = world.player.surface, next = SurfacePoint(x: old.x + dx, z: old.z + dz)
        guard generator.tile(at: next)?.passable == true else { notice = "前方无法通行。"; return }
        if dx != 0 && dz != 0 {
            guard generator.tile(at: .init(x: old.x + dx, z: old.z))?.passable == true,
                  generator.tile(at: .init(x: old.x, z: old.z + dz))?.passable == true else { return }
        }
        guard RPGWorldEditing.entity(at: next, world: world, generator: generator)?.physics.topDownSolid != true else { notice = "前方有方块。"; return }
        world.player.surface = next; world.revision += 1; scene.movePlayer(next); loadVisible()
    }
    func returnToSpawn() {
        guard ready, !working, !world.player.inCombat else { return }
        if world.player.perspective == .side {
            world.player.side = generator.sideRegion.landing; world.player.surface = generator.anchor(.temple); world.revision += 1
            sideScene.respawn(generator.sideRegion.landing)
        } else { world.player.surface = generator.anchor(.spawn); world.revision += 1; scene.movePlayer(world.player.surface); loadVisible(force: true) }
    }
    func setMode(_ mode: RPGGameMode) { guard ready, !working, !world.player.inCombat else { return }; world.player.mode = mode; world.revision += 1; save() }
    func chooseSite() {
        guard ready else { return }
        let p = world.player.surface
        for radius in 1...8 { for dz in -radius...radius { for dx in -radius...radius where max(abs(dx),abs(dz)) == radius {
            let point = SurfacePoint(x: p.x+dx, z: p.z+dz)
            if world.player.mode == .adventure && abs(dx)+abs(dz)>4 { continue }
            if point.valid && generator.tile(at: point)?.passable == true && (world.isCreativeCopy || !generator.protected(point)) && RPGWorldEditing.entity(at: point, world: world, generator: generator) == nil {
                selected = point; scene.select(point); notice = "已选附近可建造空地。"; return
            }
        } } }
        notice = "身边是保护区或障碍，请先向外探索，或使用创作副本。"
    }
    private func bindScenes() {
        scene.onSelectCell = { [weak self] point in self?.selected = point; self?.scene.select(point) }
        scene.onStroke = { [weak self] points in self?.stroke(points) }
        sideScene.onSelectCell = { [weak self] point in
            guard let self else { return }; self.selectedSide = point; self.sideScene.select(point)
            if let region = self.world.sideRegions.first(where: { $0.id == point.regionID }) { self.selected = .init(x: region.origin.x + point.horizontal, z: region.origin.z) }
        }
        sideScene.onPosition = { [weak self] point, _ in
            guard let self, self.ready, self.active, self.world.player.perspective == .side, self.world.player.side != point else { return }
            self.world.player.side = point
            if let region = self.world.sideRegions.first(where: { $0.id == point.regionID }) { self.world.player.surface = .init(x: region.origin.x + point.horizontal, z: region.origin.z) }
            self.world.revision += 1
        }
    }
    private func applyScenePause() {
        scene.isPaused = !active || working || overlayVisible || world.player.perspective != .topDown
        sideScene.isPaused = !active || working || overlayVisible || world.player.perspective != .side
    }
    func setOverlay(_ value: Bool) { overlayVisible = value; applyScenePause() }
    func travelToTemple() {
        guard ready, !working, !world.player.inCombat, world.player.perspective == .topDown else { return }
        guard world.player.mode == .creative else { notice = "冒险模式请沿通路探索；创造模式可定位到双界入口。"; return }
        world.player.surface = generator.anchor(.temple); world.revision += 1; loadVisible(force: true)
    }
    func chooseMappedSite() {
        guard ready, world.player.perspective == .topDown else { return }
        let region = generator.sideRegion
        for offset in 3...15 {
            let point = SurfacePoint(x: generator.anchor(.temple).x + offset, z: region.origin.z)
            if generator.tile(at: point)?.passable == true && (world.isCreativeCopy || !generator.protected(point)) && RPGWorldEditing.entity(at: point, world: world, generator: generator) == nil {
                selected = point; scene.select(point); notice = "已选共享映射行上的空格。"; return
            }
        }
        notice = "映射行暂无空地。"
    }
    func toggleProjection() {
        guard ready, !working else { return }
        if world.player.perspective == .side && !sideScene.isOnGround { notice = "请先落地并回到入口。"; return }
        do {
            try RPGProjectionRules.switchPerspective(world: &world, generator: generator)
            selected = nil; selectedSide = nil; applyScenePause()
            if world.player.perspective == .side { sideScene.show(world: world, resetPlayer: true); updateProjectionEvidence() }
            else { loadVisible(force: true) }
            notice = world.player.perspective == .side ? "已进入独立侧视切片；靛色平台为侧视专属。" : "已返回俯视地表。"
            save()
        } catch { notice = error.localizedDescription }
    }
    private func updateProjectionEvidence() {
        let ids = world.player.perspective == .side ? sideScene.sharedIDs : scene.sharedIDs
        projectionEvidence = world.player.perspective.rawValue + ":" + ids.sorted().joined(separator: ",")
    }
    private func renderCurrent() {
        if world.player.perspective == .side { sideScene.show(world: world); sideScene.select(selectedSide) }
        else { scene.show(chunks: chunks, world: world); scene.select(selected) }
        updateProjectionEvidence()
    }
    private func perform(_ action: @escaping @Sendable (inout WorldState, RPGWorldGenerator) throws -> Void) {
        guard ready, active, !working else { return }
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
                self.world = value; self.renderCurrent()
                self.notice = "操作已提交。"; self.save()
            case .failure(let error): self.notice = error.localizedDescription
            }
        }
    }
    func placeSelected() {
        if world.player.perspective == .side, let selectedSide {
            let definition = definition
            perform { world, generator in try RPGProjectionRules.placeSide(selectedSide, definitionID: definition, world: &world, generator: generator) }; return
        }
        guard let selected else { notice = "先轻点地表或选择附近空地。"; return }
        let definition = definition
        perform { world, generator in try RPGWorldEditing.place([.init(point: selected, definitionID: definition)], world: &world, generator: generator) }
    }
    func hitSelected(force: Bool = false) {
        if world.player.perspective == .side, let selectedSide {
            perform { world, generator in try RPGProjectionRules.hitSide(selectedSide, world: &world, generator: generator, force: force) }; return
        }
        guard let selected else { return }
        perform { world, generator in try RPGWorldEditing.hit(selected, world: &world, generator: generator, force: force) }
    }
    func undo() { perform { world, _ in try RPGWorldEditing.undo(world: &world) } }
    func redo() { perform { world, _ in try RPGWorldEditing.redo(world: &world) } }
    func markRange() { rangeStart = selected; notice = selected == nil ? "先选择范围起点。" : "已标记起点；再轻点终点。" }
    func fillRange() {
        guard let a = rangeStart, let b = selected else { return }; let definition = definition
        perform { world, generator in let points = try RPGWorldEditing.rectangle(a,b); try RPGWorldEditing.place(points.map { .init(point: $0, definitionID: definition) }, world: &world, generator: generator) }
    }
    func copyRange() {
        guard let a = rangeStart ?? selected, let b = selected else { return }
        do { clipboard = try RPGWorldEditing.copy(from: a, to: b, world: world, generator: generator); hasClipboard = !(clipboard?.cells.isEmpty ?? true); notice = "已复制 \(clipboard?.cells.count ?? 0) 个方块。" } catch { notice = error.localizedDescription }
    }
    func paste() { guard let clipboard, let selected else { return }; perform { world, generator in try RPGWorldEditing.paste(clipboard, at: selected, world: &world, generator: generator) } }
    private func stroke(_ points: [SurfacePoint]) {
        if tool == .paint {
            let definition = definition; perform { world, generator in try RPGWorldEditing.place(points.map { .init(point: $0, definitionID: definition) }, world: &world, generator: generator) }
        } else if tool == .erase, let point = points.last { selected = point; hitSelected(force: true) }
    }
    func saveBeforeExit() async -> Bool {
        guard ready else { return true }
        guard !working else { notice = "请等待当前操作完成。"; return false }
        saving?.cancel(); working = true
        do { try await storage.save(world); active = false; working = false; return true }
        catch { working = false; notice = error.localizedDescription; return false }
    }
    func save() {
        guard ready else { return }
        saving?.cancel(); let snapshot = world, epoch = generation, storage = storage
        saving = Task { [weak self] in
            do {
                try await storage.save(snapshot)
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.notice = "世界已保存 · 修订 \(snapshot.revision)"
            } catch {
                guard !Task.isCancelled, let self, self.generation == epoch else { return }; self.notice = error.localizedDescription
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
                guard let self, self.generation == epoch else { return }; self.assign(copy); self.notice = "已进入独立创作副本，原世界保留。"
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }
    func returnToOriginal() {
        guard let id = world.parentWorldID, ready, !working else { return }
        saving?.cancel(); working = true; let snapshot = world, storage = storage, epoch = generation
        Task { [weak self] in
            do {
                try await storage.save(snapshot); let original = try await storage.load(id: id); try await storage.save(original)
                guard let self, self.generation == epoch else { return }; self.assign(original); self.notice = "已返回原世界。"
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }
    func validateRoundTrip() {
        do { let decoded = try RPGWorldCodec.decode(RPGWorldCodec.encode(world)); notice = decoded == world ? "世界数据往返校验通过。" : "世界数据校验失败。" }
        catch { notice = error.localizedDescription }
    }
    private func loadVisible(force: Bool = false) {
        guard active, ready else { return }
        if world.player.perspective == .side { sideScene.show(world: world); updateProjectionEvidence(); return }
        guard force || displayedChunk != world.player.surface.chunk else { return }
        loading?.cancel(); if cache == nil { cache = RPGChunkCache(seed: world.seed) }
        let wanted = generator.priorityChunks(around: world.player.surface), epoch = generation, cache = cache
        loading = Task { [weak self] in
            let chunks = await cache?.load(wanted) ?? []
            guard !Task.isCancelled, let self, self.generation == epoch, self.active else { return }
            self.chunks = chunks; self.loadedChunks = chunks.count; self.displayedChunk = self.world.player.surface.chunk
            self.renderCurrent()
            self.notice = "世界已就绪 · \(self.loadedChunks)/64 区块在附近。"
        }
    }
}
