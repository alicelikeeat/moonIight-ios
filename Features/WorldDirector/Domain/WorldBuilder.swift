import Foundation

// v1.81 World Director: blueprint → ordinary SpatialWorld objects
// (blocks, groups, plants, creatures, chests, media bindings). Everything
// made here is marked `.generated` and tagged with its layer in its id
// ("wd<seed>-<pass>:<layer>:<n>"), so a later regeneration replaces only
// generated objects of the chosen layers (and area) and never touches what
// the user built or edited. Built in priority order within a block budget.

enum WorldDirectorError: Error, Equatable, LocalizedError {
    case cancelled, invalidBlueprint([String]), nothingBuilt
    var errorDescription: String? {
        switch self {
        case .cancelled: L10n.t("已取消，世界没有改变", "Cancelled; the world is unchanged")
        case .invalidBlueprint(let problems): L10n.t("世界规划无效：", "Invalid world plan: ") + problems.joined(separator: ", ")
        case .nothingBuilt: L10n.t("没有生成任何内容", "Nothing was generated")
        }
    }
}

/// A generated 3D model (from the AI 3D library) to stand in the world.
struct StatuePlacement: Codable, Equatable, Sendable {
    var assetID: String
    var modelID: String
    var position: SpatialVector
}

struct WorldBuildOutput: Sendable {
    var world: SpatialWorld
    var bindings: [MediaBinding]
    var statues: [StatuePlacement]
    var counts: [WorldLayer: Int]
    var notes: [String]
}

enum SpatialWorldBuilder {
    static let version = 1

    /// The layer tag of a World Director object id, nil for other ids.
    static func layer(of id: String) -> WorldLayer? {
        guard id.hasPrefix("wd") else { return nil }
        let parts = id.split(separator: ":")
        return parts.count >= 3 ? WorldLayer(rawValue: String(parts[1])) : nil
    }
    /// Layer an older generated object (not from World Director) belongs to.
    static func fallbackLayer(block: Bool) -> WorldLayer { block ? .buildings : .plants }

    static func pass(of world: SpatialWorld) -> Int {
        var best = 0
        for id in world.blocks.map(\.id) + world.plants.map(\.id) where id.hasPrefix("wd") {
            if let dash = id.firstIndex(of: "-"), let colon = id.firstIndex(of: ":"), dash < colon, let n = Int(id[id.index(after: dash)..<colon]) { best = max(best, n) }
        }
        return best
    }

    /// Builds `layers` of `blueprint` onto `base`. With all layers and no
    /// area, every earlier generated object is replaced; otherwise only
    /// generated objects of those layers inside the area. User objects
    /// (origin `.user`, which edits set) always stay.
    static func build(_ blueprint: WorldBlueprint, assets: [AssetDescriptor], onto base: SpatialWorld,
                      layers: Set<WorldLayer> = Set(WorldLayer.allCases), area: (center: WorldPoint, radius: Int)? = nil,
                      difficulty: GameDifficulty = .normal, updateAtmosphere: Bool = true,
                      cancelled: () -> Bool = { false }) throws -> WorldBuildOutput {
        let problems = blueprint.validate()
        guard problems.isEmpty else { throw WorldDirectorError.invalidBlueprint(problems) }
        var b = WorldBuildState(blueprint: blueprint, assets: assets, base: base, layers: layers, area: area, difficulty: difficulty)
        b.clear()
        if blueprint.town != nil {
            // Golden World town: the kit city takes terrain/roads/buildings/decorations/plants
            // (filtered by layer inside), then the usual creatures and far mountains.
            if cancelled() { throw WorldDirectorError.cancelled }
            b.goldenCity()
            if layers.contains(.creatures) { b.creatures() }
            if cancelled() { throw WorldDirectorError.cancelled }
            if layers.contains(.terrain) { b.terrain(far: true) }
            if cancelled() { throw WorldDirectorError.cancelled }
            return b.finish(updateAtmosphere: updateAtmosphere && layers.count == WorldLayer.allCases.count)
        }
        let order: [(WorldLayer, (inout WorldBuildState) -> Void)] = [
            (.terrain, { $0.terrain(far: false) }), (.buildings, { $0.landmark() }), (.roads, { $0.roads() }),
            // The user's pictures before filler buildings: they get the spots.
            (.media, { $0.media() }), (.buildings, { $0.buildings() }), (.decorations, { $0.decorations() }),
            (.plants, { $0.plants() }), (.creatures, { $0.creatures() }), (.terrain, { $0.terrain(far: true) }),
        ]
        for (layer, step) in order where layers.contains(layer) {
            if cancelled() { throw WorldDirectorError.cancelled }
            step(&b)
        }
        if cancelled() { throw WorldDirectorError.cancelled }
        return b.finish(updateAtmosphere: updateAtmosphere && layers.count == WorldLayer.allCases.count)
    }
}

/// Mutable build state.
struct WorldBuildState {
    let bp: WorldBlueprint
    let assets: [String: AssetDescriptor]
    let layers: Set<WorldLayer>
    let area: (center: WorldPoint, radius: Int)?
    let difficulty: GameDifficulty
    var world: SpatialWorld
    var random: SpatialRandom
    var bindings: [MediaBinding] = []
    var statues: [StatuePlacement] = []
    var counts: [WorldLayer: Int] = [:]
    var notes: [String] = []
    let prefix: String
    var counter = 0
    /// Solid height ranges per cell (to avoid overlaps), and cells kept clear.
    var solid: [Int: [ClosedRange<Double>]] = [:]
    var reserved = Set<Int>()
    var roadCells = Set<Int>()
    var generatedBlocks = 0
    let heights: [Int: Double]

    static func key(_ x: Int, _ y: Int) -> Int { y * WorldGeometry.width + x }

    init(blueprint: WorldBlueprint, assets: [AssetDescriptor], base: SpatialWorld, layers: Set<WorldLayer>, area: (center: WorldPoint, radius: Int)?, difficulty: GameDifficulty) {
        bp = blueprint
        self.assets = Dictionary(assets.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        self.layers = layers; self.area = area; self.difficulty = difficulty
        world = base
        random = SpatialRandom(seed: blueprint.seed ^ 0xD1B5_4A32_D192_ED03)
        prefix = "wd\(blueprint.seed % 100_000)-\(SpatialWorldBuilder.pass(of: base) + 1)"
        heights = WorldBuildState.heightMap(blueprint)
    }

    /// Walkable top of the terrain per cell (islands, hills, plateaus).
    static func heightMap(_ bp: WorldBlueprint) -> [Int: Double] {
        var map: [Int: Double] = [:]
        for f in bp.terrainPlan.features where f.kind == .island || f.kind == .hill || f.kind == .plateau {
            let r = f.radius
            for dy in -r...r { for dx in -r...r {
                let x = f.center.x + dx, y = f.center.y + dy
                guard (0..<256).contains(x), (0..<256).contains(y) else { continue }
                let d = (Double(dx * dx + dy * dy)).squareRoot()
                guard d <= Double(r) + edge(x, y, seed: bp.seed) else { continue }
                let top: Double
                switch f.kind {
                case .hill: top = ((f.height * max(0, 1 - (d / Double(r)) * (d / Double(r)))) * 2).rounded() / 2
                default: top = f.height
                }
                guard top >= 0.5 else { continue }
                let k = key(x, y)
                map[k] = max(map[k] ?? 0, top)
            } }
        }
        return map
    }
    /// A little deterministic noise on outlines (−0.8 … 0.8 cells).
    static func edge(_ x: Int, _ y: Int, seed: UInt64) -> Double {
        var r = SpatialRandom(seed: seed ^ UInt64(truncatingIfNeeded: x * 73_856_093 ^ y * 19_349_663))
        return (r.unit() - 0.5) * 1.6
    }
    func surface(_ x: Int, _ y: Int) -> Double { heights[Self.key(x, y)] ?? 0 }
    func inArea(_ x: Int, _ y: Int) -> Bool {
        guard let area else { return true }
        return hypot(Double(x - area.center.x), Double(y - area.center.y)) <= Double(area.radius)
    }

    // MARK: Clearing

    /// Removes the generated objects this build replaces.
    mutating func clear() {
        let layers = self.layers, area = self.area
        let full = layers.count == WorldLayer.allCases.count && area == nil
        func inside(_ x: Int, _ y: Int) -> Bool {
            guard let area else { return true }
            return hypot(Double(x - area.center.x), Double(y - area.center.y)) <= Double(area.radius)
        }
        func replaced(_ id: String, origin: SpatialOrigin, x: Int, y: Int, block: Bool) -> Bool {
            guard origin == .generated else { return false }
            if full { return true }
            let layer = SpatialWorldBuilder.layer(of: id) ?? SpatialWorldBuilder.fallbackLayer(block: block)
            return layers.contains(layer) && inside(x, y)
        }
        let touchedGroups = Set(world.blocks.filter { replaced($0.id, origin: $0.origin, x: $0.x, y: $0.y, block: true) }.compactMap(\.groupID))
        world.blocks.removeAll { replaced($0.id, origin: $0.origin, x: $0.x, y: $0.y, block: true) }
        // A town building is one unit: if part of it is replaced, all of it goes (never half a house).
        if bp.town != nil && !touchedGroups.isEmpty {
            world.blocks.removeAll { $0.origin == .generated && ($0.groupID.map(touchedGroups.contains) ?? false) }
        }
        world.plants.removeAll { replaced($0.id, origin: $0.origin, x: $0.x, y: $0.y, block: false) }
        if full || layers.contains(.creatures) {
            world.creatures.removeAll { $0.origin == .generated && inside(Int($0.position.x), Int($0.position.y)) }
            world.pickups.removeAll { $0.origin == .generated && inside(Int($0.position.x), Int($0.position.y)) }
        }
        let usedGroups = Set(world.blocks.compactMap(\.groupID))
        let removedMotions = Set(world.groups.filter { $0.origin == .generated && !usedGroups.contains($0.id) }.compactMap(\.motionID))
        world.groups.removeAll { $0.origin == .generated && !usedGroups.contains($0.id) }
        world.motions.removeAll { removedMotions.contains($0.id) }
        // What stays occupies its space.
        for block in world.blocks where block.collision == .solid { solid[Self.key(block.x, block.y), default: []].append(block.elevation...block.top) }
        generatedBlocks = world.blocks.filter { $0.origin == .generated }.count
        // The spawn stays clear.
        let s = bp.spawnPlan.position
        for dx in -3...3 { for dy in -3...3 where dx * dx + dy * dy <= 9 { reserved.insert(Self.key(s.x + dx, s.y + dy)) } }
    }

    // MARK: Adding

    mutating func nextID(_ layer: WorldLayer) -> String { counter += 1; return "\(prefix):\(layer.rawValue):\(counter)" }

    func glass(_ hex: String, density: Double? = nil, surface: SpatialSurface? = nil, glow: Bool = false, frosted: Bool = false) -> SpatialGlass {
        var g = SpatialGlass.tinted(hex, density: min(0.9, max(0.1, density ?? bp.palette.glassDensity)))
        g.surface = surface; g.glow = glow; g.frosted = frosted
        return g
    }

    func fits(_ x: Int, _ y: Int, _ bottom: Double, _ top: Double) -> Bool {
        guard let ranges = solid[Self.key(x, y)] else { return true }
        return !ranges.contains { $0.lowerBound < top - 0.01 && bottom < $0.upperBound - 0.01 }
    }

    /// Adds one block if it is inside the map, the area, the budget and
    /// overlaps no solid block. Returns its id.
    @discardableResult
    mutating func block(_ layer: WorldLayer, x: Int, y: Int, bottom: Double, top: Double, glass: SpatialGlass,
                        collision: SpatialCollision = .solid, size: Double = 1, yaw: Double = 0, group: String? = nil, force: Bool = false) -> String? {
        guard (0..<WorldGeometry.width).contains(x), (0..<WorldGeometry.width).contains(y), top - bottom >= 0.05, inArea(x, y) else { return nil }
        guard generatedBlocks < bp.performanceBudget.maxBlocks, world.blocks.count < SpatialWorld.blockLimit - 50 else { return nil }
        let lower = max(SpatialBlock.lowestElevation, bottom)
        if collision == .solid && !force && !fits(x, y, lower, top) { return nil }
        var id: String?
        var z = lower
        // Columns taller than 16 are split.
        while z < top - 0.01 {
            let t = min(16, top - z)
            let piece = SpatialBlock(id: nextID(layer), x: x, y: y, elevation: z, thickness: t, size: size, yaw: yaw, glass: glass,
                                     collision: collision, groupID: group, origin: .generated)
            guard piece.valid else { return id }
            world.blocks.append(piece); generatedBlocks += 1; counts[layer, default: 0] += 1
            if collision == .solid { solid[Self.key(x, y), default: []].append(z...(z + t)) }
            id = id ?? piece.id
            z += t
        }
        return id
    }

    mutating func group(_ name: String, template: String) -> String {
        let id = nextID(.buildings) + ":g"
        world.groups.append(BuildingGroup(id: id, name: String(name.prefix(64)), motionID: nil, origin: .generated, template: template))
        return id
    }

    // MARK: Terrain

    mutating func terrain(far: Bool) {
        for f in bp.terrainPlan.features where (f.kind == .mountain) == far {
            // Optional scenery is placed whole or not at all.
            let estimate = Int(Double.pi * Double(f.radius * f.radius) * (f.kind == .mountain ? 1.6 : 1))
            if [.mountain, .lake, .cloud].contains(f.kind), generatedBlocks + estimate > bp.performanceBudget.maxBlocks * 9 / 10 {
                notes.append(L10n.t("预算有限，省略了一处远景", "Budget: one piece of scenery left out")); continue
            }
            switch f.kind {
            case .island:
                let r = f.radius
                for dy in -r...r { for dx in -r...r {
                    let x = f.center.x + dx, y = f.center.y + dy, d = Double(dx * dx + dy * dy).squareRoot()
                    guard d <= Double(r) + Self.edge(x, y, seed: bp.seed) else { continue }
                    let depth = max(0.6, f.depth * (1 - (d / Double(r + 1)) * (d / Double(r + 1))))
                    // Opaque rock below, a lighter walkable top.
                    let topLayer = glass(bp.palette.secondary, density: 0.7, surface: .stone)
                    block(.terrain, x: x, y: y, bottom: max(0.05, f.height - depth), top: f.height, glass: topLayer)
                } }
            case .hill, .plateau:
                let tint = bp.theme == .nature ? "86B07A" : bp.palette.secondary
                let r = f.radius
                for dy in -r...r { for dx in -r...r {
                    let x = f.center.x + dx, y = f.center.y + dy
                    let top = surface(x, y)
                    guard top >= 0.5 else { continue }
                    block(.terrain, x: x, y: y, bottom: 0, top: top, glass: glass(tint, density: 0.75, surface: .stone))
                } }
            case .mountain:
                let r = f.radius
                for dy in -r...r { for dx in -r...r {
                    let x = f.center.x + dx, y = f.center.y + dy, d = Double(dx * dx + dy * dy).squareRoot()
                    guard d <= Double(r) else { continue }
                    let top = (f.height * (1 - d / Double(r + 1)) * 2).rounded() / 2
                    guard top >= 1 else { continue }
                    let snow = top > f.height * 0.75
                    block(.terrain, x: x, y: y, bottom: 0, top: top, glass: glass(snow ? "EEF2F7" : "8E99AE", density: 0.8, surface: .stone))
                } }
            case .lake:
                water(center: f.center, radius: f.radius)
            case .cloud:
                let puffs = 6 + f.radius
                for _ in 0..<puffs {
                    let a = random.unit() * 2 * .pi, r = random.unit() * Double(f.radius)
                    let x = f.center.x + Int(cos(a) * r), y = f.center.y + Int(sin(a) * r)
                    guard surface(x, y) == 0 else { continue }
                    let z = f.height + random.unit() * 0.6
                    block(.terrain, x: x, y: y, bottom: z, top: z + 0.4 + random.unit() * 0.5, glass: glass("FFFFFF", density: 0.55, frosted: true),
                          collision: .decor, size: 0.7 + random.unit() * 0.3)
                }
            }
        }
    }

    mutating func water(center: WorldPoint, radius: Int) {
        for dy in -radius...radius { for dx in -radius...radius {
            let x = center.x + dx, y = center.y + dy
            guard Double(dx * dx + dy * dy).squareRoot() <= Double(radius) + Self.edge(x, y, seed: bp.seed &+ 7), surface(x, y) == 0 else { continue }
            block(.terrain, x: x, y: y, bottom: 0.01, top: 0.09, glass: glass("6FB7E8", density: 0.45), collision: .decor)
            reserved.insert(Self.key(x, y))
        } }
    }

    // MARK: Roads and bridges

    /// Cells on a straight line, `width` wide.
    static func line(_ a: WorldPoint, _ b: WorldPoint, width: Int) -> [(x: Int, y: Int, t: Double)] {
        let steps = max(abs(b.x - a.x), abs(b.y - a.y), 1)
        let dx = Double(b.x - a.x) / Double(steps), dy = Double(b.y - a.y) / Double(steps)
        let len = max(1e-6, (dx * dx + dy * dy).squareRoot())
        let nx = -dy / len, ny = dx / len
        var seen = Set<Int>(), out: [(Int, Int, Double)] = []
        for i in 0...steps {
            let cx = Double(a.x) + dx * Double(i), cy = Double(a.y) + dy * Double(i)
            for w in 0..<width {
                let o = Double(w) - Double(width - 1) / 2
                let x = Int((cx + nx * o).rounded()), y = Int((cy + ny * o).rounded())
                if seen.insert(key(x, y)).inserted { out.append((x, y, Double(i) / Double(steps))) }
            }
        }
        return out
    }

    mutating func roads() {
        for segment in bp.roadNetwork.segments {
            let cells = Self.line(segment.from, segment.to, width: segment.width)
            switch segment.kind {
            case "stream":
                for c in cells where surface(c.x, c.y) == 0 {
                    block(.roads, x: c.x, y: c.y, bottom: 0.01, top: 0.09, glass: glass("6FB7E8", density: 0.45), collision: .decor)
                }
            case "bridge":
                let railing = glass(bp.palette.primary, density: 0.35)
                let deck = glass(bp.palette.primary, density: 0.55)
                let paving = glass(bp.palette.accent, density: 0.5)
                // The gap runs from where the path leaves the first land to
                // where it reaches the last; the deck slopes evenly between
                // those two heights (never a step taller than half a cell).
                let ordered = cells.sorted { $0.t < $1.t }
                let startLand = segment.from.z <= 0.05 ? 0 : surface(segment.from.x, segment.from.y)
                let endLand = segment.to.z <= 0.05 ? 0 : surface(segment.to.x, segment.to.y)
                let exit = ordered.last(where: { $0.t < 0.5 && startLand > 0 && abs(surface($0.x, $0.y) - startLand) < 0.01 })?.t ?? 0
                let enter = ordered.first(where: { $0.t > 0.5 && endLand > 0 && abs(surface($0.x, $0.y) - endLand) < 0.01 })?.t ?? 1
                func level(_ t: Double) -> Double {
                    if t <= exit { return startLand }
                    if t >= enter { return endLand }
                    let f = (t - exit) / max(0.0001, enter - exit)
                    return ((startLand + (endLand - startLand) * f) * 4).rounded() / 4
                }
                for c in ordered {
                    let land = surface(c.x, c.y), h = level(c.t)
                    roadCells.insert(Self.key(c.x, c.y))
                    if land > 0 && abs(land - h) < 0.3 {
                        block(.roads, x: c.x, y: c.y, bottom: land, top: land + 0.1, glass: paving)
                    } else if land == 0 && h >= 0.15 {
                        block(.roads, x: c.x, y: c.y, bottom: max(0.02, h - 0.4), top: h, glass: deck)
                    }
                }
                let edges = Set(Self.line(segment.from, segment.to, width: segment.width + 2).map { Self.key($0.x, $0.y) }).subtracting(cells.map { Self.key($0.x, $0.y) })
                for k in edges.sorted() where k % 2 == 0 {
                    let x = k % WorldGeometry.width, y = k / WorldGeometry.width
                    guard surface(x, y) == 0, let near = ordered.min(by: { abs($0.x - x) + abs($0.y - y) < abs($1.x - x) + abs($1.y - y) }) else { continue }
                    let h = level(near.t)
                    guard h >= 0.5 else { continue }
                    block(.roads, x: x, y: y, bottom: h, top: h + 0.7, glass: railing, collision: .decor, size: 0.3)
                }
            case "avenue":
                // The full width stays clear; only the centre line is built.
                let line = Set(Self.line(segment.from, segment.to, width: 1).map { Self.key($0.x, $0.y) })
                for c in cells {
                    roadCells.insert(Self.key(c.x, c.y))
                    guard line.contains(Self.key(c.x, c.y)) else { continue }
                    let land = surface(c.x, c.y)
                    block(.roads, x: c.x, y: c.y, bottom: land, top: land + 0.06, glass: glass(bp.palette.accent, density: 0.5, glow: true), collision: .decor, size: 0.5)
                }
            default:
                let paving = glass(bp.theme == .futureCity ? "3A4152" : bp.palette.secondary, density: 0.8, surface: .stone)
                for c in cells {
                    let land = surface(c.x, c.y)
                    roadCells.insert(Self.key(c.x, c.y))
                    block(.roads, x: c.x, y: c.y, bottom: land, top: land + 0.1, glass: paving)
                }
            }
        }
        for k in roadCells { reserved.insert(k) }
    }

    // MARK: Landmark

    mutating func landmark() {
        let lm = bp.landmarkPlan, p = lm.position, z = surface(p.x, p.y), s = lm.scale
        let g = group(lm.kind.title, template: "landmark:\(lm.kind.rawValue)")
        let primary = glass(bp.palette.primary, density: 0.5), accent = glass(bp.palette.accent, density: 0.45, surface: .crystal, glow: true)
        let stone = glass(bp.palette.secondary, density: 0.8, surface: .stone)
        func column(_ x: Int, _ y: Int, _ h: Double, _ look: SpatialGlass, size: Double = 1) {
            block(.buildings, x: x, y: y, bottom: z, top: z + h, glass: look, size: size, group: g)
        }
        // The landmark area stays free of other buildings.
        for dx in -7...7 { for dy in -7...7 { reserved.insert(Self.key(p.x + dx, p.y + dy)) } }
        switch lm.kind {
        case .crystalPalace:
            for dx in -1...1 { for dy in -1...1 { column(p.x + dx, p.y + dy, 10 * s, primary) } }
            for (dx, dy) in [(-4, -4), (4, -4), (-4, 4), (4, 4)] { column(p.x + dx, p.y + dy, 14 * s, accent, size: 0.8) }
            for (dx, dy) in [(-4, 0), (4, 0), (0, -4), (0, 4)] { column(p.x + dx, p.y + dy, 6 * s, stone) }
            block(.buildings, x: p.x, y: p.y, bottom: z + 10 * s, top: z + 18 * s, glass: accent, size: 0.6, group: g)
            // A frosted roof ring linking the towers.
            for dx in -3...3 { for dy in -3...3 where max(abs(dx), abs(dy)) == 3 {
                block(.buildings, x: p.x + dx, y: p.y + dy, bottom: z + 6 * s, top: z + 6.4 * s, glass: glass(bp.palette.primary, density: 0.35, frosted: true), group: g)
            } }
        case .spire:
            for dx in 0...1 { for dy in 0...1 { column(p.x + dx, p.y + dy, 24 * s, accent) } }
            for dx in -2...3 { for dy in -2...3 where max(abs(dx - 0), abs(dy - 0)) >= 2 { column(p.x + dx, p.y + dy, 1.5, stone) } }
        case .ancientTree:
            for dx in -1...1 { for dy in -1...1 { column(p.x + dx, p.y + dy, 9 * s, glass("7A5A3C", density: 0.85, surface: .stone)) } }
            for layer in 0..<2 {
                let r = 5 - layer, h = z + 9 * s + Double(layer) * 1.4
                for dx in -r...r { for dy in -r...r where dx * dx + dy * dy <= r * r {
                    block(.buildings, x: p.x + dx, y: p.y + dy, bottom: h, top: h + 1, glass: glass("7FD88A", density: 0.4, glow: true), collision: .decor, group: g)
                } }
            }
        case .megaTower:
            let h = 40 * s
            for dx in -2...2 { for dy in -2...2 {
                let corner = abs(dx) == 2 && abs(dy) == 2
                column(p.x + dx, p.y + dy, corner ? h + 2 : h, corner ? glass(bp.palette.secondary, density: 0.85, surface: .metal) : primary)
            } }
            block(.buildings, x: p.x, y: p.y, bottom: z + h, top: z + h + 6, glass: accent, size: 0.5, group: g)
        case .galleryHall:
            for dx in -4...4 { for dy in -4...4 {
                if (abs(dx) == 4 || abs(dy) == 4) && (dx + dy) % 4 == 0 { column(p.x + dx, p.y + dy, 5.5, stone) }
                block(.buildings, x: p.x + dx, y: p.y + dy, bottom: z + 5.5, top: z + 5.8, glass: glass(bp.palette.primary, density: 0.3, frosted: true), group: g)
            } }
            block(.buildings, x: p.x, y: p.y, bottom: z + 5.8, top: z + 9, glass: accent, size: 0.7, group: g)
        case .arena:
            for piece in SpatialBuilder.building(.bossArena, x: p.x - 5, y: p.y - 5, elevation: z, groupID: g, idPrefix: nextID(.buildings), origin: .generated) {
                if fits(piece.x, piece.y, piece.elevation, piece.top) || piece.collision != .solid { add(piece, layer: .buildings) }
            }
        }
    }

    /// Adds a block made elsewhere (SpatialBuilder templates).
    mutating func add(_ piece: SpatialBlock, layer: WorldLayer) {
        guard inArea(piece.x, piece.y), generatedBlocks < bp.performanceBudget.maxBlocks, piece.valid else { return }
        var b = piece; b.origin = .generated
        if b.glass.tintHex == nil { b.glass.tintHex = bp.palette.primary }
        world.blocks.append(b); generatedBlocks += 1; counts[layer, default: 0] += 1
        if b.collision == .solid { solid[Self.key(b.x, b.y), default: []].append(b.elevation...b.top) }
    }

    // MARK: Buildings

    /// A flat, free footprint near a region's centre.
    mutating func spot(in region: BiomeRegion, width: Int, depth: Int) -> (Int, Int, Double)? {
        for _ in 0..<40 {
            let a = random.unit() * 2 * .pi, r = random.unit() * Double(max(1, region.radius - max(width, depth) / 2))
            let x = region.center.x + Int(cos(a) * r) - width / 2, y = region.center.y + Int(sin(a) * r) - depth / 2
            let z = surface(x, y)
            var ok = (4..<250).contains(x) && (4..<250).contains(y)
            if ok { for cx in (x - 1)...(x + width) { for cy in (y - 1)...(y + depth) where ok {
                if reserved.contains(Self.key(cx, cy)) || surface(cx, cy) != z || !fits(cx, cy, z, z + 3) { ok = false }
            } } }
            if ok { return (x, y, z) }
        }
        return nil
    }

    mutating func claim(_ x: Int, _ y: Int, _ w: Int, _ d: Int) {
        for cx in (x - 1)...(x + w) { for cy in (y - 1)...(y + d) { reserved.insert(Self.key(cx, cy)) } }
    }

    mutating func buildings() {
        let regions = Dictionary(bp.biomeRegions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for zone in bp.buildingZones {
            guard let region = regions[zone.regionID], !zone.structures.isEmpty else { continue }
            for index in 0..<zone.count {
                let name = zone.structures[index % zone.structures.count]
                if let kind = BuildingKind(rawValue: name) {
                    let size = SpatialBuilder.footprint(kind)
                    guard let (x, y, z) = spot(in: region, width: size.width, depth: size.depth) else { continue }
                    let g = group(kind.title, template: kind.rawValue)
                    let pieces = SpatialBuilder.building(kind, x: x, y: y, elevation: z, groupID: g, idPrefix: nextID(.buildings), origin: .generated, variant: random.int(0...7))
                    let opaque = bp.palette.opaqueShare
                    for (i, piece) in pieces.enumerated() {
                        var b = piece
                        if b.glass.tintHex == nil { b.glass.tintHex = bp.palette.primary }
                        // Foundations and every few pieces are opaque supports.
                        if b.elevation <= z + 0.01 || Double(i % 10) < opaque * 10 * 0.5 { b.glass.surface = .stone; b.glass.tintHex = bp.palette.secondary; b.glass.density = 0.8 }
                        add(b, layer: .buildings)
                    }
                    claim(x, y, size.width, size.depth)
                } else if name == "skyscraper" {
                    let w = 3 + random.int(0...2), d = 3 + random.int(0...2)
                    guard let (x, y, z) = spot(in: region, width: w, depth: d) else { continue }
                    let near = max(0.3, 1 - hypot(Double(x - bp.spawnPlan.position.x), Double(y - bp.spawnPlan.position.y)) / 90)
                    let h = (8 + random.unit() * 22 * near) * (bp.performanceBudget.tier == .low ? 0.7 : 1)
                    let g = group(L10n.t("玻璃高楼", "Glass Tower"), template: "skyscraper")
                    let tint = random.unit() < 0.5 ? bp.palette.primary : bp.palette.accent
                    for dx in 0..<w { for dy in 0..<d {
                        let corner = (dx == 0 || dx == w - 1) && (dy == 0 || dy == d - 1)
                        block(.buildings, x: x + dx, y: y + dy, bottom: z, top: z + h,
                              glass: corner ? glass(bp.palette.secondary, density: 0.85, surface: .metal) : glass(tint, density: 0.5), group: g)
                    } }
                    block(.buildings, x: x + w / 2, y: y + d / 2, bottom: z + h, top: z + h + 1.2, glass: glass(bp.palette.accent, density: 0.5, glow: true), size: 0.5, group: g)
                    claim(x, y, w, d)
                } else if name == "pavilion" {
                    guard let (x, y, z) = spot(in: region, width: 3, depth: 3) else { continue }
                    let g = group(L10n.t("玻璃凉亭", "Glass Pavilion"), template: "pavilion")
                    for (dx, dy) in [(0, 0), (2, 0), (0, 2), (2, 2)] {
                        block(.buildings, x: x + dx, y: y + dy, bottom: z, top: z + 2.5, glass: glass(bp.palette.secondary, density: 0.8, surface: .stone), size: 0.4, group: g)
                    }
                    for dx in 0...2 { for dy in 0...2 {
                        block(.buildings, x: x + dx, y: y + dy, bottom: z + 2.5, top: z + 2.8, glass: glass(bp.palette.accent, density: 0.4, frosted: true), group: g)
                    } }
                    claim(x, y, 3, 3)
                }
            }
        }
    }

    // MARK: Media

    mutating func media() {
        var index = 0
        for assignment in bp.assetAssignments {
            index += 1
            let planned = assignment.position, p = planned
            if assignment.slot == "statue" {
                if let asset = assets[assignment.assetID], let model = asset.libraryID, inArea(p.x, p.y) {
                    statues.append(StatuePlacement(assetID: asset.assetID, modelID: model, position: SpatialVector(Double(p.x) + 0.5, Double(p.y) + 0.5, surface(p.x, p.y))))
                }
                continue
            }
            let width = assignment.slot == "landmarkScreen" ? 6 : 4
            let rows = assignment.slot == "landmarkScreen" ? 4 : 3
            let lift = assignment.slot == "billboard" ? 3.0 : 0
            // The planned spot, or the nearest flat free one around it.
            guard let (wx, wy, z) = wallSpot(near: planned, width: width, height: lift + Double(rows)) else {
                notes.append(L10n.t("有一面影像墙找不到空位，已省略", "No room for one media wall; left out")); continue
            }
            let wall = WorldPoint(x: wx, y: wy, z: z)
            var ids: [String] = []
            let g = group(L10n.t("影像墙", "Media Wall"), template: "mediaWall")
            if lift > 0 {
                for x in [wall.x, wall.x + width - 1] { block(.media, x: x, y: wall.y, bottom: z, top: z + lift, glass: glass(bp.palette.secondary, density: 0.85, surface: .metal), size: 0.4, group: g) }
            }
            for column in 0..<width { for row in 0..<rows {
                let bottom = z + lift + Double(row)
                if let id = block(.media, x: wall.x + column, y: wall.y, bottom: bottom, top: bottom + 1, glass: glass(bp.palette.primary, density: 0.65, frosted: true), group: g) { ids.append(id) }
            } }
            claim(wall.x, wall.y, width, 1)
            guard ids.count == width * rows else { continue }
            if let asset = assets[assignment.assetID], let library = asset.libraryID {
                let kind: RPGMediaKind = asset.mediaType == .video ? .video : asset.mediaType == .gif ? .gif : .image
                let binding = MediaBinding(id: "\(prefix):bind:\(index)", mediaID: library, kind: kind, fit: .fill)
                bindings.append(binding)
                SpatialBuilder.mediaGrid(bindingID: binding.id, blocks: ids, face: .front, stretch: true, world: &world)
                // mediaGrid marks blocks as user-edited; these stay generated.
                let set = Set(ids)
                for i in world.blocks.indices where set.contains(world.blocks[i].id) { world.blocks[i].origin = .generated }
            } else {
                // No picture: a glowing frame shows where one can go.
                for i in world.blocks.indices where ids.contains(world.blocks[i].id) { world.blocks[i].glass.glow = true; world.blocks[i].glass.tintHex = bp.palette.accent }
            }
        }
    }

    func wallSpot(near p: WorldPoint, width: Int, height: Double) -> (Int, Int, Double)? {
        for radius in 0...8 {
            for dy in -radius...radius { for dx in -radius...radius where max(abs(dx), abs(dy)) == radius {
                let x = p.x + dx, y = p.y + dy
                guard (3..<(250 - width)).contains(x), (3..<250).contains(y), inArea(x, y) else { continue }
                let z = surface(x, y)
                var ok = true
                for c in 0..<width where ok {
                    let k = Self.key(x + c, y)
                    if reserved.contains(k) || surface(x + c, y) != z || !fits(x + c, y, z, z + height) { ok = false }
                }
                if ok { return (x, y, z) }
            } }
        }
        return nil
    }

    // MARK: Decoration

    mutating func decorations() {
        let plan = bp.decorationPlan
        let lm = bp.landmarkPlan.position
        for _ in 0..<plan.crystals {
            let a = random.unit() * 2 * .pi, r = 8 + random.unit() * 10
            let x = lm.x + Int(cos(a) * r), y = lm.y + Int(sin(a) * r)
            let z = surface(x, y)
            guard !reserved.contains(Self.key(x, y)) else { continue }
            block(.decorations, x: x, y: y, bottom: z, top: z + 0.6 + random.unit() * 1.2, glass: glass(bp.palette.accent, density: 0.45, surface: .crystal, glow: true),
                  collision: .decor, size: 0.3 + random.unit() * 0.3, yaw: random.unit() * 90)
        }
        // Lamps along the roads (glow plants are lights).
        var placed = 0
        for k in roadCells.sorted() where placed < plan.lamps && k % 9 == 0 {
            let x = k % WorldGeometry.width, y = k / WorldGeometry.width
            for (dx, dy) in [(2, 0), (0, 2), (-2, 0)] where !roadCells.contains(Self.key(x + dx, y + dy)) && inArea(x + dx, y + dy) {
                world.plants.append(PlantEntity(id: nextID(.decorations), kind: .glow, x: x + dx, y: y + dy, z: surface(x + dx, y + dy), scale: 0.7, hue: 0.55, origin: .generated))
                counts[.decorations, default: 0] += 1; placed += 1
                break
            }
        }
    }

    mutating func plants() {
        let plan = bp.decorationPlan
        let weights: [String: Double] = ["garden": 3, "forest": 4, "safe": 0.6, "plaza": 0.5, "district": 0.4, "ruins": 1, "combat": 0.8, "reward": 0.6, "arena": 0.2]
        let regions = bp.biomeRegions.filter { (weights[$0.kind] ?? 0) > 0 }
        let total = regions.reduce(0) { $0 + (weights[$1.kind] ?? 0) * $1.density * Double($1.radius * $1.radius) }
        guard total > 0 else { return }
        var trees = 0
        for region in regions {
            let share = (weights[region.kind] ?? 0) * region.density * Double(region.radius * region.radius) / total
            let count = Int(Double(plan.plants) * share)
            for _ in 0..<count {
                guard world.plants.filter({ $0.origin == .generated }).count < bp.performanceBudget.maxPlants else { return }
                let a = random.unit() * 2 * .pi, r = random.unit().squareRoot() * Double(region.radius)
                let x = region.center.x + Int(cos(a) * r), y = region.center.y + Int(sin(a) * r)
                let k = Self.key(x, y)
                guard (2..<254).contains(x), (2..<254).contains(y), inArea(x, y), !roadCells.contains(k) else { continue }
                let z = surface(x, y)
                guard fits(x, y, z, z + 1.5) else { continue }
                let roll = random.unit()
                var kind: PlantKind = roll < plan.flowersShare ? .flower : roll < plan.flowersShare + 0.3 ? .grass : .bush
                if region.kind == "forest" || region.kind == "garden", trees < plan.trees, random.unit() < 0.25 { kind = .tree }
                if kind.solid && reserved.contains(k) { kind = .grass }
                if kind == .tree { trees += 1 }
                world.plants.append(PlantEntity(id: nextID(.plants), kind: kind, x: x, y: y, z: z, scale: 0.8 + random.unit() * 0.5, hue: random.unit(), origin: .generated))
                counts[.plants, default: 0] += 1
                if kind.solid { solid[k, default: []].append(z...(z + 1.5)) }
            }
        }
    }

    // MARK: Creatures and chests

    mutating func creature(_ kind: CreatureKind, at p: WorldPoint) {
        guard inArea(p.x, p.y), world.creatures.filter({ $0.origin == .generated }).count < bp.performanceBudget.maxCreatures else { return }
        // Hostiles never start near the spawn.
        if kind.hostile && p.distance(bp.spawnPlan.position) < 16 { return }
        let base: (Int, Int) = switch kind { case .neutral: (10, 0); case .enemy: (30, 6); case .guardian: (45, 8); case .miniBoss: (160, 12); case .boss: (420, 16) }
        let health = min(5000, Int(Double(base.0) * difficulty.health)), damage = min(60, Int((Double(base.1) * difficulty.damage).rounded()))
        let position = SpatialVector(Double(p.x) + 0.5, Double(p.y) + 0.5, surface(p.x, p.y) + (kind == .boss ? 0.4 : 0))
        world.creatures.append(CreatureEntity(id: nextID(.creatures), kind: kind, position: position, home: position, health: health, maxHealth: health, damage: damage, origin: .generated))
        counts[.creatures, default: 0] += 1
    }
    mutating func chest(at p: WorldPoint, shards: Int) {
        guard inArea(p.x, p.y) else { return }
        world.pickups.append(PickupEntity(id: nextID(.creatures), position: SpatialVector(Double(p.x) + 0.5, Double(p.y) + 0.5, surface(p.x, p.y)), shards: shards, origin: .generated))
        counts[.creatures, default: 0] += 1
    }
    func near(_ c: WorldPoint, _ r: Double, _ random: inout SpatialRandom) -> WorldPoint {
        let a = random.unit() * 2 * .pi, d = random.unit() * r
        return WorldPoint(x: min(250, max(5, c.x + Int(cos(a) * d))), y: min(250, max(5, c.y + Int(sin(a) * d))), z: 0)
    }

    mutating func creatures() {
        var r = random
        for region in bp.biomeRegions {
            switch region.kind {
            case "garden", "forest", "safe", "plaza":
                for _ in 0..<(region.kind == "forest" ? 3 : 1) { creature(.neutral, at: near(region.center, Double(region.radius) * 0.7, &r)) }
            case "ruins":
                for _ in 0..<2 { creature(.enemy, at: near(region.center, Double(region.radius) * 0.6, &r)) }
                chest(at: region.center, shards: 3)
            case "combat":
                for _ in 0..<(2 + Int(region.density * 2)) { creature(.enemy, at: near(region.center, Double(region.radius) * 0.7, &r)) }
                creature(.guardian, at: near(region.center, 3, &r))
            case "reward":
                for _ in 0..<3 { chest(at: near(region.center, 3, &r), shards: 4) }
            case "arena":
                creature(.boss, at: region.center)
                chest(at: WorldPoint(x: region.center.x, y: region.center.y + 4, z: 0), shards: 10)
            default: break
            }
        }
        if bp.theme == .bossAdventure, let second = bp.biomeRegions.last(where: { $0.kind == "combat" }) { creature(.miniBoss, at: second.center) }
        // Every world: a reward at the end of each route.
        for route in bp.explorationRoutes { if let end = route.waypoints.last, end != bp.landmarkPlan.position { chest(at: WorldPoint(x: end.x + 2, y: end.y, z: 0), shards: 2) } }
        random = r
    }

    // MARK: Golden World town

    /// Id suffix that marks a town block (the layer tag stays in the middle, so local regeneration still works).
    static let goldenSuffix = ":gc"

    /// Builds the kit town from the blueprint's town intent, whole buildings or none,
    /// inside the area and the budget, never over a player's own blocks.
    mutating func goldenCity() {
        guard let intent = bp.town else { return }
        let plan = GoldenCityPlanner.plan(seed: bp.seed, intent: intent)
        let draft = GoldenCityDraftBuilder.draft(plan)
        let pack = plan.pack
        let liveGroups = Set(world.groups.map(\.id))
        var occluders = (world.hybrid?.occluders ?? []).filter { liveGroups.contains($0.groupID) }
        let userCells = Set(world.blocks.filter { $0.origin == .user }.map { Self.key($0.x, $0.y) })
        func free(_ piece: KitPiece) -> Bool {
            inArea(piece.x, piece.y) && !userCells.contains(Self.key(piece.x, piece.y)) && (piece.collision != .solid || fits(piece.x, piece.y, piece.bottom, piece.top))
        }
        for unit in draft.units where layers.contains(unit.layer) {
            if unit.atomic {
                guard unit.pieces.allSatisfy(free) else {
                    if unit.pieces.contains(where: { userCells.contains(Self.key($0.x, $0.y)) }) { notes.append(L10n.t("保留了你的建造，省略：", "Kept your build; left out: ") + unit.name) }
                    continue
                }
                guard generatedBlocks + unit.pieces.count <= bp.performanceBudget.maxBlocks, world.blocks.count + unit.pieces.count < SpatialWorld.blockLimit - 50 else {
                    notes.append(L10n.t("预算不足，省略：", "Over budget; left out: ") + unit.name); continue
                }
                let groupID = unit.building.map { group($0.name, template: "kit-" + $0.kind.rawValue) }
                for piece in unit.pieces {
                    add(GoldenCity.block(piece, id: nextID(unit.layer) + Self.goldenSuffix, pack: pack, group: groupID), layer: unit.layer)
                }
                if let spec = unit.building, let groupID { occluders.append(GoldenCity.occluder(spec, group: groupID)) }
            } else {
                for piece in unit.pieces where free(piece) {
                    guard generatedBlocks < bp.performanceBudget.maxBlocks, world.blocks.count < SpatialWorld.blockLimit - 50 else { break }
                    add(GoldenCity.block(piece, id: nextID(unit.layer) + Self.goldenSuffix, pack: pack, group: nil), layer: unit.layer)
                    if unit.layer == .roads { roadCells.insert(Self.key(piece.x, piece.y)) }
                }
            }
        }
        for k in plan.roads.keys { roadCells.insert(k) }
        // Plants never go on a block (road, water, wall), whichever seed laid it.
        let covered = Set(world.blocks.map { Self.key($0.x, $0.y) })
        if layers.contains(.plants) {
            var planted = world.plants.filter { $0.origin == .generated }.count
            for plant in draft.plants {
                guard planted < bp.performanceBudget.maxPlants else { break }
                let k = Self.key(plant.x, plant.y)
                guard inArea(plant.x, plant.y), !userCells.contains(k), !roadCells.contains(k), !covered.contains(k), fits(plant.x, plant.y, plant.z, plant.z + 1.5) else { continue }
                world.plants.append(PlantEntity(id: nextID(.plants), kind: plant.kind, x: plant.x, y: plant.y, z: plant.z, scale: plant.scale, hue: plant.hue, origin: .generated))
                counts[.plants, default: 0] += 1
                planted += 1
                if plant.kind.solid { solid[k, default: []].append(plant.z...(plant.z + 1.5)) }
            }
        }
        // Keep the spawn and route corridor out of the far-mountain pass.
        for point in plan.route { for dx in -2...2 { for dy in -2...2 { reserved.insert(Self.key(point.x + dx, point.y + dy)) } } }
        let mode = world.hybrid?.viewMode ?? .spatial3D
        world.hybrid = HybridWorldSave(viewMode: mode, regionColumn: GoldenCity.address.column, regionRow: GoldenCity.address.row, occluders: Array(occluders.prefix(48)))
    }

    // MARK: Finish

    mutating func finish(updateAtmosphere: Bool) -> WorldBuildOutput {
        let spawn = bp.spawnPlan.position.vector
        let full = layers.count == WorldLayer.allCases.count && area == nil
        if full {
            world.spawn = SpatialVector(spawn.x, spawn.y, surface(bp.spawnPlan.position.x, bp.spawnPlan.position.y))
            world.player.position = world.spawn; world.player.lastSafe = world.spawn; world.player.verticalSpeed = 0
            world.player.facing = bp.spawnPlan.facing
        }
        if updateAtmosphere { world.atmosphere = SpatialAtmosphere(bp.lightingProfile) }
        let kept = Array(assets.values).sorted { $0.assetID < $1.assetID }
        world.director = WorldDirectorRecord(blueprint: bp, intentSummary: bp.generationMetadata.notes.first ?? bp.theme.title,
                                             assets: kept.isEmpty ? (world.director?.assets) : Array(kept.prefix(60)))
        // Drop groups that ended up empty (budget, area).
        let used = Set(world.blocks.compactMap(\.groupID))
        world.groups.removeAll { $0.origin == .generated && !used.contains($0.id) }
        if generatedBlocks >= bp.performanceBudget.maxBlocks { notes.append(L10n.t("已达到方块预算，部分远景和装饰省略", "Block budget reached; some scenery and decoration left out")) }
        return WorldBuildOutput(world: world, bindings: bindings, statues: statues, counts: counts, notes: notes)
    }
}
