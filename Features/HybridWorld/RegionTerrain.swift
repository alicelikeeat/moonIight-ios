import Foundation

// Distant terrain for the regions around the open 256×256 map. Visual only:
// no collision, no blocks, nothing saved. The open region stays the only
// walkable map; this gives the mid and far stream tiers something to show
// so the edge of the map reads as land instead of empty sky.
//
// Height is a pure function of the continent cell, so two patches that share
// an edge agree on it. The fade keeps the first stretch past the map edge at
// ground height, so the terrain meets the glass ground without a step.

enum RegionBiome: String, Codable, Sendable {
    case plains, forest, mountains, castle, isles, wild

    static func of(regionKey: String) -> RegionBiome {
        switch regionKey {
        case "central-town": return .plains
        case "spirit-forest": return .forest
        case "crystal-mountains": return .mountains
        case "ancient-castle": return .castle
        case "sky-isles": return .isles
        default: return .wild
        }
    }

    /// Peak height in cells.
    var amplitude: Double {
        switch self {
        case .plains: return 4
        case .forest: return 12
        case .mountains: return 56
        case .castle: return 16
        case .isles: return 26
        case .wild: return 8
        }
    }

    var tintHex: String {
        switch self {
        case .plains: return "C9D8E6"
        case .forest: return "9FC7B0"
        case .mountains: return "D9E4F4"
        case .castle: return "C7C2D8"
        case .isles: return "B9D4F0"
        case .wild: return "B8C9D6"
        }
    }
}

struct TerrainPatch: Equatable, Sendable {
    var address: RegionAddress
    var tier: StreamTier
    var biome: RegionBiome
    /// Samples along one edge.
    var samples: Int
    /// Cells between samples.
    var spacing: Int
    /// South-west corner in the open map's local cells (can be negative or past 256).
    var originX: Int
    var originY: Int
    /// Row-major, `samples × samples`, row = y.
    var heights: [Double]
    /// Triangle list over the sample grid, already trimmed to the sky dome.
    var triangles: [UInt32]

    var key: String { "\(address.column):\(address.row):\(tier.rawValue)" }

    func height(column: Int, row: Int) -> Double { heights[row * samples + column] }
    func localX(column: Int) -> Int { originX + column * spacing }
    func localY(row: Int) -> Int { originY + row * spacing }
}

struct RegionTerrain: Sendable {
    /// The sky dome is a 500-cell sphere around the map centre. Triangles past
    /// this radius would poke through it.
    static let visibleRadius = 470.0
    static let mapCentre = Double(HybridWorldScale.regionSide) / 2
    /// Cells past the map edge that stay flat before the hills rise.
    static let flatMargin = 16.0
    static let riseDistance = 96.0
    /// Sits just under the glass ground so the shared edge does not flicker.
    static let baseHeight = -0.05

    static func spacing(for tier: StreamTier) -> Int? {
        switch tier {
        case .near: return nil
        case .mid: return 16
        case .far: return 32
        }
    }

    private let amplitudes: [RegionAddress: Double]
    private let biomes: [RegionAddress: RegionBiome]
    private let seed: UInt64

    init(graph: WorldGraph, seed: UInt64 = 0x4D4F_4F4E) {
        var amplitudes: [RegionAddress: Double] = [:]
        var biomes: [RegionAddress: RegionBiome] = [:]
        for region in graph.regions {
            let biome = RegionBiome.of(regionKey: region.id.key)
            biomes[region.address] = biome
            amplitudes[region.address] = biome.amplitude
        }
        self.amplitudes = amplitudes
        self.biomes = biomes
        self.seed = seed
    }

    func biome(at address: RegionAddress) -> RegionBiome { biomes[address] ?? .wild }

    /// Height at a continent cell, seen from the open region `focus`.
    func height(globalX: Double, globalY: Double, focus: RegionAddress) -> Double {
        let side = Double(HybridWorldScale.regionSide)
        let localX = globalX - Double(focus.originX), localY = globalY - Double(focus.originY)
        let outside = max(max(-localX, localX - side), max(-localY, localY - side), 0)
        let fade = Self.smoothstep((outside - Self.flatMargin) / Self.riseDistance)
        guard fade > 0 else { return Self.baseHeight }
        let shape = 0.65 * noise(globalX / 128, globalY / 128, octave: 0) + 0.35 * noise(globalX / 48, globalY / 48, octave: 1)
        return Self.baseHeight + amplitude(globalX: globalX, globalY: globalY) * shape * fade
    }

    /// Mesh data for one stream request. Nil for the near tier (that is the open map itself).
    func patch(for request: StreamRequest, focus: RegionAddress) -> TerrainPatch? {
        guard request.address.valid, focus.valid, request.address != focus, let spacing = Self.spacing(for: request.tier) else { return nil }
        let side = HybridWorldScale.regionSide
        let samples = side / spacing + 1
        let originX = request.address.originX - focus.originX
        let originY = request.address.originY - focus.originY
        var heights = [Double](repeating: 0, count: samples * samples)
        for row in 0..<samples {
            for column in 0..<samples {
                let gx = Double(request.address.originX + column * spacing)
                let gy = Double(request.address.originY + row * spacing)
                heights[row * samples + column] = height(globalX: gx, globalY: gy, focus: focus)
            }
        }
        // Edge samples between coarser neighbours sit on the line those
        // neighbours draw, so a mid patch next to a far patch has no crack.
        if spacing < 32 {
            let step = 32 / spacing
            func snap(_ index: (Int) -> Int) {
                for i in 0..<samples where i % step != 0 {
                    let lower = i - i % step, upper = min(samples - 1, lower + step)
                    let t = Double(i - lower) / Double(upper - lower)
                    heights[index(i)] = heights[index(lower)] * (1 - t) + heights[index(upper)] * t
                }
            }
            snap { $0 }                                   // south edge
            snap { (samples - 1) * samples + $0 }         // north edge
            snap { $0 * samples }                         // west edge
            snap { $0 * samples + samples - 1 }           // east edge
        }
        var triangles: [UInt32] = []
        triangles.reserveCapacity((samples - 1) * (samples - 1) * 6)
        func inside(_ column: Int, _ row: Int) -> Bool {
            let dx = Double(originX + column * spacing) - Self.mapCentre
            let dy = Double(originY + row * spacing) - Self.mapCentre
            return dx * dx + dy * dy <= Self.visibleRadius * Self.visibleRadius
        }
        for row in 0..<(samples - 1) {
            for column in 0..<(samples - 1) {
                guard inside(column, row), inside(column + 1, row), inside(column, row + 1), inside(column + 1, row + 1) else { continue }
                let a = UInt32(row * samples + column), b = a + 1
                let c = UInt32((row + 1) * samples + column), d = c + 1
                triangles += [a, b, d, a, d, c]
            }
        }
        guard !triangles.isEmpty else { return nil }
        return TerrainPatch(address: request.address, tier: request.tier, biome: biome(at: request.address), samples: samples, spacing: spacing,
                            originX: originX, originY: originY, heights: heights, triangles: triangles)
    }

    /// Patches for every resident mid/far region. Order is stable.
    func patches(resident: [RegionAddress: StreamTier], graph: WorldGraph, focus: RegionAddress) -> [TerrainPatch] {
        let byAddress = Dictionary(graph.regions.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        return resident.sorted { ($0.key.column, $0.key.row) < ($1.key.column, $1.key.row) }.compactMap { entry in
            guard let region = byAddress[entry.key] else { return nil }
            return patch(for: StreamRequest(address: entry.key, tier: entry.value, regionKey: region.id.key, authored: region.authored), focus: focus)
        }
    }

    // MARK: Fields

    /// Bilinear blend of region amplitudes between region centres, so a
    /// mountain region rises gradually out of its plains neighbour.
    private func amplitude(globalX: Double, globalY: Double) -> Double {
        let side = Double(HybridWorldScale.regionSide)
        let fx = globalX / side - 0.5, fy = globalY / side - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func at(_ column: Int, _ row: Int) -> Double {
            let edge = HybridWorldScale.regionsAlongEdge - 1
            let address = RegionAddress(column: min(edge, max(0, column)), row: min(edge, max(0, row)))
            return amplitudes[address] ?? RegionBiome.wild.amplitude
        }
        let south = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let north = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        return south * (1 - ty) + north * ty
    }

    /// Smooth value noise in 0…1.
    private func noise(_ x: Double, _ y: Double, octave: UInt64) -> Double {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let tx = Self.smoothstep(x - Double(x0)), ty = Self.smoothstep(y - Double(y0))
        let a = lattice(x0, y0, octave), b = lattice(x0 + 1, y0, octave)
        let c = lattice(x0, y0 + 1, octave), d = lattice(x0 + 1, y0 + 1, octave)
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }

    private func lattice(_ x: Int, _ y: Int, _ octave: UInt64) -> Double {
        var z = seed &+ octave &* 0xD6E8_FEB8_6659_FD93
        z ^= UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        z ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    static func smoothstep(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        return c * c * (3 - 2 * c)
    }
}
