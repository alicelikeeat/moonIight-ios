import Foundation

// Region index and streaming hooks. This slice keeps one resident 256×256
// world (the central town). Neighbour loads are signals for later terrain,
// not generated continents.
//
// TODO: TerrainMeshSystem — near = full collision, mid = simplified meshes,
// far = low terrain. Only the hook and the tier exist here.
// TODO: fill the other 16×16 regions. Their records stay `authored == false`.

enum StreamTier: String, Codable, Sendable {
    case near, mid, far
}

struct StreamRequest: Equatable, Sendable {
    var address: RegionAddress
    var tier: StreamTier
    var regionKey: String
    var authored: Bool
}

struct StreamDelta: Equatable, Sendable {
    var load: [StreamRequest]
    var unload: [RegionAddress]
}

struct RegionStreamHooks {
    var load: (StreamRequest) -> Void
    var unload: (RegionAddress) -> Void
    static let ignore = RegionStreamHooks(load: { _ in }, unload: { _ in })
}

struct WorldRegionManager: Sendable {
    let graph: WorldGraph
    private(set) var resident: [RegionAddress: StreamTier] = [:]
    private let byAddress: [RegionAddress: WorldRegionRecord]

    init(graph: WorldGraph) {
        self.graph = graph
        var map: [RegionAddress: WorldRegionRecord] = [:]
        for region in graph.regions { map[region.address] = region }
        byAddress = map
    }

    func region(at address: RegionAddress) -> WorldRegionRecord? { byAddress[address] }

    static func decompose(_ global: GlobalCell) -> (address: RegionAddress, localX: Int, localY: Int)? {
        guard global.valid else { return nil }
        let side = HybridWorldScale.regionSide
        return (RegionAddress(column: global.x / side, row: global.y / side), global.x % side, global.y % side)
    }

    static func compose(address: RegionAddress, localX: Int, localY: Int) -> GlobalCell? {
        guard address.valid, (0..<HybridWorldScale.regionSide).contains(localX), (0..<HybridWorldScale.regionSide).contains(localY) else { return nil }
        return GlobalCell(x: address.originX + localX, y: address.originY + localY)
    }

    /// Chebyshev window: the player's region, the ring around it, and one ring further.
    static func window(around address: RegionAddress) -> (near: [RegionAddress], mid: [RegionAddress], far: [RegionAddress]) {
        guard address.valid else { return ([], [], []) }
        var near: [RegionAddress] = [], mid: [RegionAddress] = [], far: [RegionAddress] = []
        let edge = HybridWorldScale.regionsAlongEdge
        for row in 0..<edge {
            for column in 0..<edge {
                let other = RegionAddress(column: column, row: row)
                let distance = max(abs(column - address.column), abs(row - address.row))
                if distance == 0 { near.append(other) }
                else if distance == 1 { mid.append(other) }
                else if distance == 2 { far.append(other) }
            }
        }
        return (near, mid, far)
    }

    /// Updates which regions should be resident. Calls hooks for new or retiered loads and for drops.
    mutating func updateStreaming(around global: GlobalCell, hooks: RegionStreamHooks = .ignore) -> StreamDelta {
        guard let focus = Self.decompose(global)?.address else { return StreamDelta(load: [], unload: []) }
        let window = Self.window(around: focus)
        var desired: [RegionAddress: StreamTier] = [:]
        for address in window.near { desired[address] = .near }
        for address in window.mid { desired[address] = .mid }
        for address in window.far { desired[address] = .far }
        var load: [StreamRequest] = []
        var unload: [RegionAddress] = []
        for (address, tier) in desired where resident[address] != tier {
            guard let region = byAddress[address] else { continue }
            let request = StreamRequest(address: address, tier: tier, regionKey: region.id.key, authored: region.authored)
            load.append(request)
            hooks.load(request)
        }
        for address in resident.keys where desired[address] == nil {
            unload.append(address)
            hooks.unload(address)
        }
        resident = desired
        load.sort { ($0.address.column, $0.address.row, $0.tier.rawValue) < ($1.address.column, $1.address.row, $1.tier.rawValue) }
        unload.sort { ($0.column, $0.row) < ($1.column, $1.row) }
        return StreamDelta(load: load, unload: unload)
    }
}
