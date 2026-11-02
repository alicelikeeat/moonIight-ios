import SwiftUI

@MainActor final class RPGSession: ObservableObject {
    @Published private(set) var world = WorldState()
    @Published private(set) var notice = "正在生成世界…"
    @Published private(set) var active = false
    @Published private(set) var loadedChunks = 0
    @Published private(set) var selected: SurfacePoint?
    let scene = RPGTopDownScene()
    private var chunks: [RPGChunk] = []
    private var cache: RPGChunkCache?
    private var loading: Task<Void, Never>?
    private var generation = UUID()
    private var displayedChunk: ChunkCoordinate?
    private var terrainGenerator = RPGWorldGenerator(seed: 20261102)
    var generator: RPGWorldGenerator { terrainGenerator }
    func activate() {
        active = true; scene.isPaused = false
        scene.onSelectCell = { [weak self] point in self?.selected = point; self?.scene.select(point) }
        if !world.generated {
            world.player.surface = generator.anchor(.spawn); world.sideRegions = [generator.sideRegion]; world.generated = true
        }
        loadVisible(force: true)
    }
    func pause() { active = false; scene.isPaused = true; loading?.cancel() }
    func shutdown() { pause(); generation = UUID(); scene.shutdown(); let old = cache; Task { await old?.clear() }; cache = nil; chunks = []; displayedChunk = nil }
    func move(dx: Int, dz: Int) {
        guard active, abs(dx) <= 1, abs(dz) <= 1 else { return }
        let old = world.player.surface, next = SurfacePoint(x: old.x + dx, z: old.z + dz)
        guard generator.tile(at: next)?.passable == true else { notice = "前方无法通行。"; return }
        if dx != 0 && dz != 0 {
            guard generator.tile(at: .init(x: old.x + dx, z: old.z))?.passable == true,
                  generator.tile(at: .init(x: old.x, z: old.z + dz))?.passable == true else { return }
        }
        guard !chunks.flatMap(\.entities).contains(where: { $0.surface == next && $0.physics.topDownSolid }) else { notice = "前方有资源方块。"; return }
        world.player.surface = next; scene.movePlayer(next); loadVisible()
    }
    func returnToSpawn() { world.player.surface = generator.anchor(.spawn); scene.movePlayer(world.player.surface); loadVisible(force: true) }
    func validateRoundTrip() {
        do {
            let decoded = try RPGWorldCodec.decode(RPGWorldCodec.encode(world))
            notice = decoded == world ? "世界数据往返校验通过。" : "世界数据校验失败。"
        } catch { notice = error.localizedDescription }
    }
    private func loadVisible(force: Bool = false) {
        guard active, force || displayedChunk != world.player.surface.chunk else { return }
        loading?.cancel()
        if cache == nil { cache = RPGChunkCache(seed: world.seed) }
        let wanted = generator.priorityChunks(around: world.player.surface), epoch = generation, cache = cache
        loading = Task { [weak self] in
            let chunks = await cache?.load(wanted) ?? []
            guard !Task.isCancelled, let self, self.generation == epoch, self.active else { return }
            self.chunks = chunks; self.loadedChunks = chunks.count; self.displayedChunk = self.world.player.surface.chunk
            self.scene.show(chunks: chunks, world: self.world)
            self.notice = "世界已生成 · \(self.loadedChunks) / 64 区块在附近 · 轻点地表选择格子。"
        }
    }
}
