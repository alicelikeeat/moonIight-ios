import Foundation

// v1.86: the other 255 regions of the continent. Each region is its own
// 256×256 world, built the first time the player arrives (World Director
// themes, a fixed seed per region, so a region is the same every time it is
// first visited) and saved on its own afterwards. Walking off an edge of the
// map, or picking a region on the continent map, travels there. The player's
// characters, skills and hotbar go along; blocks, creatures and the undo
// history stay with their region.

enum TravelDirection: String, CaseIterable, Sendable {
    case west, east, south, north
    /// Change of region address (row grows with map y, column with map x).
    var step: (column: Int, row: Int) {
        switch self {
        case .west: (-1, 0)
        case .east: (1, 0)
        case .south: (0, -1)
        case .north: (0, 1)
        }
    }
}

enum RegionTravel {
    /// How close to the edge (cells) the travel prompt appears.
    static let edgeMargin = 2.0

    /// The edge the player stands at, if any (the nearest one).
    static func edge(at position: SpatialVector, margin: Double = edgeMargin) -> TravelDirection? {
        guard position.x.isFinite, position.y.isFinite else { return nil }
        let side = Double(HybridWorldScale.regionSide)
        let distances: [(TravelDirection, Double)] = [(.west, position.x), (.east, side - position.x), (.south, position.y), (.north, side - position.y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= margin else { return nil }
        return nearest.0
    }

    static func neighbour(of address: RegionAddress, _ direction: TravelDirection) -> RegionAddress? {
        let next = RegionAddress(column: address.column + direction.step.column, row: address.row + direction.step.row)
        return next.valid ? next : nil
    }

    /// Where the player appears after crossing: the facing edge of the new
    /// map, at the same place along it.
    static func arrival(from position: SpatialVector, crossing direction: TravelDirection) -> SpatialVector {
        let side = Double(HybridWorldScale.regionSide), inset = edgeMargin + 1.5
        let along: (Double) -> Double = { min(side - inset, max(inset, $0.isFinite ? $0 : side / 2)) }
        switch direction {
        case .west: return SpatialVector(side - inset, along(position.y), 0)
        case .east: return SpatialVector(inset, along(position.y), 0)
        case .south: return SpatialVector(along(position.x), side - inset, 0)
        case .north: return SpatialVector(along(position.x), inset, 0)
        }
    }

    /// Fixed seed per region.
    static func seed(_ address: RegionAddress) -> UInt64 {
        var x = UInt64(address.column &* 7919 &+ address.row &* 104_729) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        return x ^ (x >> 31)
    }

    /// Theme of a region: named regions have their own, the rest follow the seed.
    static func theme(_ record: WorldRegionRecord) -> WorldTheme {
        switch record.id.key {
        case "spirit-forest": return .nature
        case "crystal-mountains": return .futureCity
        case "ancient-castle": return .bossAdventure
        case "sky-isles": return .skyCity
        default:
            let themes: [WorldTheme] = [.nature, .skyCity, .memory, .futureCity, .bossAdventure]
            return themes[Int(seed(record.address) % UInt64(themes.count))]
        }
    }

    /// Shown name: the region's own name, or theme plus grid position.
    static func title(_ record: WorldRegionRecord) -> String {
        if record.name != "待接入区域" { return record.name }
        return theme(record).title + String(format: " · %02d-%02d", record.address.column, record.address.row)
    }

    static func request(_ record: WorldRegionRecord) -> WorldGenerationRequest {
        var request = WorldGenerationRequest(theme: theme(record))
        request.seed = seed(record.address)
        request.prompt = [record.name == "待接入区域" ? nil : record.name, record.landmark].compactMap { $0 }.joined(separator: " ")
        return request
    }

    /// Builds a region's world the first time it is visited.
    static func build(_ record: WorldRegionRecord, cancelled: () -> Bool = { false }) throws -> SpatialWorld {
        if record.address == CentralTown.address { return CentralTown.stampedBlank() }
        let found = try WorldDirectorEngine.candidates(request(record), intent: nil, base: SpatialWorld(), count: 1, cancelled: cancelled)
        guard let best = found.first(where: { $0.report.passed }) ?? found.first else { throw WorldDirectorError.cancelled }
        var world = best.output.world
        world.history = SpatialHistory()
        return world
    }

    /// The player's own things travel along; the region keeps its content.
    /// Puts the player at `arrival` (on top of whatever stands there).
    static func enter(_ region: SpatialWorld, at address: RegionAddress, from previous: SpatialWorld, arrival: SpatialVector?) -> SpatialWorld {
        var world = region
        world.characters = previous.characters
        world.playerCharacterID = previous.playerCharacterID
        world.skills = previous.skills
        world.hotbar = previous.hotbar
        world.bossScripts = previous.bossScripts
        // Creatures that wear a character or a boss script the player no
        // longer has fall back to their plain body.
        let characterIDs = Set((world.characters ?? []).map(\.id)), scriptIDs = Set((world.bossScripts ?? []).map(\.id))
        for i in world.creatures.indices {
            if let id = world.creatures[i].characterID, !characterIDs.contains(id) { world.creatures[i].characterID = nil }
            if let id = world.creatures[i].bossScriptID, !scriptIDs.contains(id) { world.creatures[i].bossScriptID = nil }
        }
        // The region's own roofs and walls only (never the previous region's).
        var hybrid = world.hybrid ?? HybridWorldSave.centralFocus(mode: .spatial3D)
        hybrid.viewMode = previous.hybrid?.viewMode ?? hybrid.viewMode
        hybrid.regionColumn = address.column; hybrid.regionRow = address.row
        world.hybrid = hybrid
        world.history = SpatialHistory()
        if let arrival {
            var spot = arrival
            spot.z = groundHeight(world, x: arrival.x, y: arrival.y)
            world.player.position = spot
            world.player.lastSafe = spot
            world.player.verticalSpeed = 0
        }
        return world
    }

    /// Top of the highest solid block under (x, y), or 0 on open ground.
    static func groundHeight(_ world: SpatialWorld, x: Double, y: Double) -> Double {
        let cx = Int(x.rounded(.down)), cy = Int(y.rounded(.down))
        return world.blocks.filter { $0.x == cx && $0.y == cy && $0.collision == .solid }.map(\.top).max() ?? 0
    }

    /// Region file name.
    static func archiveName(_ address: RegionAddress) -> String { String(format: "region-%02d-%02d.json", address.column, address.row) }
}
