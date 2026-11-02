import Foundation

enum RPGTerrain: UInt16, Codable, CaseIterable, Sendable {
    case grass, sand, water, cliff, road
    var passable: Bool { self != .water && self != .cliff }
}
enum RPGAnchorID: String, Codable, CaseIterable, Sendable {
    case spawn, village, ruins, temple, boss, creation
    var title: String {
        switch self { case .spawn: "出生地"; case .village: "月光村"; case .ruins: "记忆遗迹"; case .temple: "双界神殿"; case .boss: "Boss 领域"; case .creation: "创作区域" }
    }
}
struct RPGAnchor: Equatable, Sendable, Identifiable {
    let id: RPGAnchorID
    let point: SurfacePoint
}
struct RPGChunk: Equatable, Sendable {
    let coordinate: ChunkCoordinate
    let terrain: [RPGTerrain]
    let entities: [WorldEntity]
    func tile(localX: Int, localZ: Int) -> RPGTerrain? {
        guard (0..<32).contains(localX), (0..<32).contains(localZ) else { return nil }
        return terrain[localZ * 32 + localX]
    }
}
/// Fixed integer hash and reserved corridors make generation order irrelevant.
struct RPGWorldGenerator: Sendable {
    static let version = 1
    let seed: UInt64
    let anchors: [RPGAnchor]
    private let corridor: Set<SurfacePoint>
    init(seed: UInt64) {
        self.seed = seed
        let centers = [SurfacePoint(x: 16, z: 16), .init(x: 56, z: 48), .init(x: 120, z: 88),
                       .init(x: 176, z: 144), .init(x: 224, z: 216), .init(x: 48, z: 208)]
        anchors = zip(RPGAnchorID.allCases, centers).enumerated().map { index, pair in
            let n = Self.hash(seed: seed, x: index, z: 0, salt: 7)
            return .init(id: pair.0, point: .init(x: pair.1.x + Int(n % 7) - 3, z: pair.1.z + Int((n >> 8) % 7) - 3))
        }
        var roads = Set<SurfacePoint>()
        func reserve(_ point: SurfacePoint, radius: Int) {
            for dz in -radius...radius { for dx in -radius...radius {
                let p = SurfacePoint(x: point.x + dx, z: point.z + dz)
                if p.valid { roads.insert(p) }
            } }
        }
        for anchor in anchors { reserve(anchor.point, radius: 4) }
        let start = anchors[0].point
        for anchor in anchors.dropFirst() {
            for x in min(start.x, anchor.point.x)...max(start.x, anchor.point.x) { reserve(.init(x: x, z: start.z), radius: 1) }
            for z in min(start.z, anchor.point.z)...max(start.z, anchor.point.z) { reserve(.init(x: anchor.point.x, z: z), radius: 1) }
        }
        corridor = roads
    }
    static func hash(seed: UInt64, x: Int, z: Int, salt: UInt64 = 0) -> UInt64 {
        var n = seed ^ (UInt64(truncatingIfNeeded: x) &* 0x9E3779B97F4A7C15) ^ (UInt64(truncatingIfNeeded: z) &* 0xBF58476D1CE4E5B9) ^ salt
        n = (n ^ (n >> 30)) &* 0xBF58476D1CE4E5B9
        n = (n ^ (n >> 27)) &* 0x94D049BB133111EB
        return n ^ (n >> 31)
    }
    func tile(at point: SurfacePoint) -> RPGTerrain? {
        guard point.valid else { return nil }
        if corridor.contains(point) { return .road }
        let value = Self.hash(seed: seed, x: point.x, z: point.z) % 100
        if value < 12 { return .water }
        if value < 18 { return .cliff }
        return (point.x / 64 + point.z / 64) % 3 == 1 ? .sand : .grass
    }
    func protected(_ point: SurfacePoint) -> Bool { corridor.contains(point) }
    func anchor(_ id: RPGAnchorID) -> SurfacePoint { anchors.first { $0.id == id }!.point }
    var sideRegion: SideRegion {
        let p = anchor(.temple)
        return .init(id: "temple-slice-v1", origin: .init(x: p.x - 16, z: p.z), width: 48,
                     landing: .init(regionID: "temple-slice-v1", horizontal: 16, height: 2))
    }
    func chunk(_ coordinate: ChunkCoordinate) -> RPGChunk? {
        guard coordinate.valid else { return nil }
        var tiles: [RPGTerrain] = [], entities: [WorldEntity] = []
        tiles.reserveCapacity(1024)
        for z in 0..<32 { for x in 0..<32 {
            let point = SurfacePoint(x: coordinate.x * 32 + x, z: coordinate.z * 32 + z)
            let terrain = tile(at: point)!
            tiles.append(terrain)
            let n = Self.hash(seed: seed, x: point.x, z: point.z, salt: 41)
            if terrain.passable && !protected(point) && n % 31 == 0 {
                let shared = sideRegion.contains(point)
                let definition = n % 2 == 0 ? "wood" : "stone"
                entities.append(.init(id: "g1:\(seed):\(point.x):\(point.z)", definitionID: definition,
                    scope: shared ? .shared : .topDownOnly, surface: point,
                    side: shared ? .init(regionID: sideRegion.id, horizontal: point.x - sideRegion.origin.x, height: 2) : nil))
            }
        } }
        return .init(coordinate: coordinate, terrain: tiles, entities: entities)
    }
    func priorityChunks(around point: SurfacePoint) -> [ChunkCoordinate] {
        guard let center = point.chunk else { return [] }
        return ChunkCoordinate.all.filter { abs($0.x - center.x) <= 1 && abs($0.z - center.z) <= 1 }.sorted {
            let a = abs($0.x - center.x) + abs($0.z - center.z), b = abs($1.x - center.x) + abs($1.z - center.z)
            return a == b ? $0.id < $1.id : a < b
        }
    }
    /// Terrain flood-fill acceptance check used by the generation harness.
    func anchorsReachable() -> Bool {
        var queue = [anchor(.spawn)], visited = Set(queue), head = 0
        while head < queue.count {
            let point = queue[head]; head += 1
            for delta in [(1,0),(-1,0),(0,1),(0,-1)] {
                let next = SurfacePoint(x: point.x + delta.0, z: point.z + delta.1)
                if next.valid && !visited.contains(next) && tile(at: next)?.passable == true { visited.insert(next); queue.append(next) }
            }
        }
        return anchors.allSatisfy { visited.contains($0.point) }
    }
}
actor RPGChunkCache {
    private var values: [ChunkCoordinate: RPGChunk] = [:]
    private var order: [ChunkCoordinate] = []
    private let generator: RPGWorldGenerator
    init(seed: UInt64) { generator = RPGWorldGenerator(seed: seed) }
    func load(_ coordinates: [ChunkCoordinate]) -> [RPGChunk] {
        var result: [RPGChunk] = []
        for coordinate in coordinates {
            if Task.isCancelled { break }
            if values[coordinate] == nil { values[coordinate] = generator.chunk(coordinate) }
            order.removeAll { $0 == coordinate }; order.append(coordinate)
            if let value = values[coordinate] { result.append(value) }
        }
        while order.count > 12 { values[order.removeFirst()] = nil }
        return result
    }
    func clear() { values.removeAll(); order.removeAll() }
    var count: Int { values.count }
}
