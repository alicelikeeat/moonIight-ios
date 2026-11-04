import Foundation

// One-tap world generation: deterministic for the same seed, settings and
// generator version. Everything it makes is ordinary, editable world data.

/// Reproducible random numbers (SplitMix64).
struct SpatialRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }
}

enum WorldStyle: String, Codable, CaseIterable, Sendable {
    case mixed, nature, ruins, islands
    var title: String {
        switch self {
        case .mixed: L10n.t("混合玻璃世界", "Mixed Glass World"); case .nature: L10n.t("玻璃自然世界", "Glass Nature")
        case .ruins: L10n.t("玻璃遗迹世界", "Glass Ruins"); case .islands: L10n.t("悬浮群岛世界", "Floating Islands")
        }
    }
}

enum ContentDensity: String, Codable, CaseIterable, Sendable {
    case low, medium, high
    var title: String { switch self { case .low: L10n.t("稀疏", "Low"); case .medium: L10n.t("中等", "Medium"); case .high: L10n.t("密集", "High") } }
    var factor: Double { switch self { case .low: 0.6; case .medium: 1; case .high: 1.5 } }
}

enum GameDifficulty: String, Codable, CaseIterable, Sendable {
    case easy, normal, hard
    var title: String { switch self { case .easy: L10n.t("简单", "Easy"); case .normal: L10n.t("普通", "Normal"); case .hard: L10n.t("困难", "Hard") } }
    var health: Double { switch self { case .easy: 0.8; case .normal: 1; case .hard: 1.35 } }
    var damage: Double { switch self { case .easy: 0.75; case .normal: 1; case .hard: 1.3 } }
}

struct WorldGenerationConfiguration: Codable, Equatable, Sendable {
    var style = WorldStyle.mixed
    var density = ContentDensity.medium
    var difficulty = GameDifficulty.normal
    var maze = true
    var miniBoss = true
    var bigBoss = true
    var seed: UInt64 = 20_261_103
    // v1.60 amounts (optional so saved settings from v1.58 still open):
    // multipliers on the style's defaults, and floating islands anywhere.
    var buildingAmount: Double?
    var plantAmount: Double?
    var creatureAmount: Double?
    var enemyAmount: Double?
    var floatingIslands: Bool?
    var buildingFactor: Double { min(3, max(0, buildingAmount ?? 1)) }
    var plantFactor: Double { min(3, max(0, plantAmount ?? 1)) }
    var creatureFactor: Double { min(3, max(0, creatureAmount ?? 1)) }
    var enemyFactor: Double { min(3, max(0, enemyAmount ?? 1)) }
}

/// What a generation would add and replace (shown before confirming).
struct GenerationSummary: Equatable, Sendable {
    var blocks = 0, buildings = 0, plants = 0, neutral = 0, enemies = 0, guards = 0, miniBosses = 0, bosses = 0, pickups = 0
    var mazes = 0
    var replacedGenerated = 0
    var keptUser = 0
    var attempts = 1
    var problems: [String] = []
}

enum SpatialWorldGenerator {
    static let version = 1

    struct Region: Equatable, Sendable { var kind: String; var x: Int; var y: Int; var radius: Int }

    /// Generates a world: previous generated objects are replaced, the
    /// user's own objects kept. Re-tries with derived seeds until the
    /// layout passes validation (spawn safe, regions and bosses reachable,
    /// maze solvable).
    static func generate(_ configuration: WorldGenerationConfiguration, keeping existing: SpatialWorld) -> (world: SpatialWorld, summary: GenerationSummary) {
        var base = existing
        let replaced = base.blocks.filter { $0.origin == .generated }.count + base.plants.filter { $0.origin == .generated }.count +
            base.creatures.filter { $0.origin == .generated }.count + base.pickups.filter { $0.origin == .generated }.count
        base.blocks.removeAll { $0.origin == .generated }; base.plants.removeAll { $0.origin == .generated }
        base.creatures.removeAll { $0.origin == .generated }; base.pickups.removeAll { $0.origin == .generated }
        let keptGroups = Set(base.blocks.compactMap(\.groupID))
        let removedMotions = Set(base.groups.filter { $0.origin == .generated && !keptGroups.contains($0.id) }.compactMap(\.motionID))
        base.groups.removeAll { $0.origin == .generated && !keptGroups.contains($0.id) }
        base.motions.removeAll { removedMotions.contains($0.id) }
        let kept = base.blocks.count + base.plants.count + base.creatures.count + base.pickups.count

        var last: (SpatialWorld, GenerationSummary)?
        for attempt in 0..<6 {
            let seed = configuration.seed &+ UInt64(attempt) &* 0xA24B_AED4_963E_E407
            var (candidate, summary) = build(configuration, seed: seed, onto: base)
            summary.problems = validate(candidate)
            summary.attempts = attempt + 1; summary.replacedGenerated = replaced; summary.keptUser = kept
            candidate.generation = SpatialGenerationRecord(configuration: configuration, version: version, attempts: attempt + 1)
            last = (candidate, summary)
            if summary.problems.isEmpty { break }
        }
        return last!
    }

    // MARK: Layout

    static func regions(_ configuration: WorldGenerationConfiguration, random: inout SpatialRandom) -> [Region] {
        var kinds = ["nature", "buildings", "ruins"]
        if configuration.maze { kinds.append("maze") }
        if configuration.bigBoss { kinds.append("boss") }
        let start = random.unit() * 2 * .pi
        return kinds.enumerated().map { index, kind in
            let angle = start + Double(index) * 2 * .pi / Double(kinds.count) + (random.unit() - 0.5) * 0.5
            let distance = 38 + random.unit() * 22
            let radius = kind == "boss" ? 8 : kind == "maze" ? 9 : kind == "nature" ? 18 : 15
            let x = min(235 - radius, max(20 + radius, Int(128 + cos(angle) * distance)))
            let y = min(235 - radius, max(20 + radius, Int(128 + sin(angle) * distance)))
            return Region(kind: kind, x: x, y: y, radius: radius)
        }
    }

    private static func build(_ configuration: WorldGenerationConfiguration, seed: UInt64, onto base: SpatialWorld) -> (SpatialWorld, GenerationSummary) {
        var random = SpatialRandom(seed: seed)
        var world = base
        var summary = GenerationSummary()
        let prefix = "gen\(seed % 1_000_000)"
        var counter = 0
        func nextID(_ kind: String) -> String { counter += 1; return "\(prefix):\(kind):\(counter)" }
        world.spawn = SpatialVector(128.5, 128.5, 0)
        world.player.position = world.spawn; world.player.lastSafe = world.spawn
        let difficulty = configuration.difficulty, density = configuration.density.factor
        let style = configuration.style

        // Cells kept clear: the spawn and corridors to every region.
        var reserved = Set<Int>(), occupied = Set<Int>()
        func key(_ x: Int, _ y: Int) -> Int { y * WorldGeometry.width + x }
        for block in world.blocks where block.collision == .solid { occupied.insert(key(block.x, block.y)) }
        for dx in -6...6 { for dy in -6...6 where dx * dx + dy * dy <= 36 { reserved.insert(key(128 + dx, 128 + dy)) } }
        let regions = regions(configuration, random: &random)
        var corridors: [Int: (Int, Int)] = [:]
        for region in regions {
            let steps = max(abs(region.x - 128), abs(region.y - 128))
            for step in 0...steps {
                let t = Double(step) / Double(max(1, steps))
                let x = Int((128 + Double(region.x - 128) * t).rounded()), y = Int((128 + Double(region.y - 128) * t).rounded())
                for wx in -1...1 { for wy in -1...1 { reserved.insert(key(x + wx, y + wy)); corridors[key(x + wx, y + wy)] = (x + wx, y + wy) } }
            }
        }
        func free(_ x: Int, _ y: Int, _ w: Int, _ d: Int, margin: Int = 1) -> Bool {
            for cx in (x - margin)..<(x + w + margin) { for cy in (y - margin)..<(y + d + margin) {
                guard (2..<254).contains(cx), (2..<254).contains(cy) else { return false }
                if reserved.contains(key(cx, cy)) || occupied.contains(key(cx, cy)) { return false }
            } }
            return true
        }
        func claim(_ x: Int, _ y: Int, _ w: Int, _ d: Int) { for cx in x..<(x + w) { for cy in y..<(y + d) { occupied.insert(key(cx, cy)) } } }
        func spot(in region: Region, _ w: Int, _ d: Int, tries: Int = 30) -> (Int, Int)? {
            for _ in 0..<tries {
                let angle = random.unit() * 2 * .pi, r = random.unit() * Double(region.radius)
                let x = region.x + Int(cos(angle) * r) - w / 2, y = region.y + Int(sin(angle) * r) - d / 2
                if free(x, y, w, d) { return (x, y) }
            }
            return nil
        }
        func addBuilding(_ kind: BuildingKind, at x: Int, _ y: Int, elevation: Double = 0, variant: Int = 0) {
            let group = nextID("group"), size = SpatialBuilder.footprint(kind)
            let blocks = SpatialBuilder.building(kind, x: x, y: y, elevation: elevation, groupID: group, idPrefix: group, origin: .generated, variant: variant)
            guard !blocks.isEmpty else { return }
            world.groups.append(BuildingGroup(id: group, name: kind.title, motionID: nil, origin: .generated, template: kind.rawValue))
            world.blocks.append(contentsOf: blocks); summary.blocks += blocks.count; summary.buildings += 1
            claim(x - (kind == .bridge ? 1 : 0), y, size.width, size.depth)
        }
        func creature(_ kind: CreatureKind, x: Double, y: Double, z: Double = 0) {
            let base: (Int, Int) = switch kind { case .neutral: (10, 0); case .enemy: (30, 6); case .guardian: (45, 8); case .miniBoss: (160, 12); case .boss: (420, 16) }
            let health = min(5000, Int(Double(base.0) * difficulty.health)), damage = min(60, Int((Double(base.1) * difficulty.damage).rounded()))
            let position = SpatialVector(x, y, z)
            world.creatures.append(CreatureEntity(id: nextID(kind.rawValue), kind: kind, position: position, home: position, health: health, maxHealth: health, damage: damage, origin: .generated))
            switch kind { case .neutral: summary.neutral += 1; case .enemy: summary.enemies += 1; case .guardian: summary.guards += 1; case .miniBoss: summary.miniBosses += 1; case .boss: summary.bosses += 1 }
        }
        func plant(_ kind: PlantKind, x: Int, y: Int, z: Double = 0) {
            guard !reserved.contains(key(x, y)) || !kind.solid, !occupied.contains(key(x, y)) else { return }
            world.plants.append(PlantEntity(id: nextID("plant"), kind: kind, x: x, y: y, z: z, scale: 0.8 + random.unit() * 0.5, hue: random.unit(), origin: .generated))
            if kind.solid { occupied.insert(key(x, y)) }
            summary.plants += 1
        }
        func pickup(x: Double, y: Double, z: Double, shards: Int) {
            world.pickups.append(PickupEntity(id: nextID("chest"), position: SpatialVector(x, y, z), shards: shards, origin: .generated)); summary.pickups += 1
        }
        func groundPoint(in region: Region) -> (Int, Int)? {
            for _ in 0..<20 {
                let angle = random.unit() * 2 * .pi, r = random.unit() * Double(region.radius)
                let x = region.x + Int(cos(angle) * r), y = region.y + Int(sin(angle) * r)
                if (2..<254).contains(x), (2..<254).contains(y), !occupied.contains(key(x, y)) { return (x, y) }
            }
            return nil
        }

        /// Floating islands: platforms with stairs up, a creature on each.
        func islands(in region: Region) {
            for _ in 0..<Int(3 * density) {
                guard let (x, y) = spot(in: region, 12, 4) else { continue }
                addBuilding(.stairs, at: x, y); addBuilding(.floatingPlatform, at: x + 8, y)
                creature(.neutral, x: Double(x + 10), y: Double(y + 2), z: 3.35)
            }
        }

        for region in regions {
            switch region.kind {
            case "nature":
                let count = Int(Double(style == .nature ? 360 : style == .ruins ? 90 : 200) * density * configuration.plantFactor)
                for _ in 0..<count {
                    guard let (x, y) = groundPoint(in: region) else { continue }
                    let roll = random.unit()
                    let kind: PlantKind = roll < 0.4 ? .grass : roll < 0.62 ? .flower : roll < 0.76 ? .bush : roll < 0.9 ? .tree : .glow
                    plant(kind, x: x, y: y)
                }
                for _ in 0..<Int(8 * density * configuration.creatureFactor) { if let (x, y) = groundPoint(in: region) { creature(.neutral, x: Double(x) + 0.5, y: Double(y) + 0.5) } }
                if style == .islands || configuration.floatingIslands == true { islands(in: region) }
            case "buildings":
                let kinds: [BuildingKind] = [.hut, .tower, .hut, .altar, .mediaWall, .bridge, .floatingPlatform]
                for index in 0..<Int((style == .nature ? 3 : 6) * density * configuration.buildingFactor) {
                    let kind = kinds[index % kinds.count]
                    let size = SpatialBuilder.footprint(kind)
                    if kind == .floatingPlatform {
                        // A platform always comes with stairs up to it.
                        guard let (x, y) = spot(in: region, 12, 4) else { continue }
                        addBuilding(.stairs, at: x, y); addBuilding(.floatingPlatform, at: x + 8, y)
                        pickup(x: Double(x + 10), y: Double(y + 2), z: 3.35, shards: 3)
                    } else if let (x, y) = spot(in: region, size.width + (kind == .bridge ? 2 : 0), size.depth) {
                        addBuilding(kind, at: x + (kind == .bridge ? 1 : 0), y, variant: random.int(0...7))
                    }
                }
                for _ in 0..<Int(4 * density * configuration.enemyFactor) { if let (x, y) = groundPoint(in: region) { creature(.enemy, x: Double(x) + 0.5, y: Double(y) + 0.5) } }
                for _ in 0..<Int((2 * configuration.enemyFactor).rounded()) { if let (x, y) = groundPoint(in: region) { creature(.guardian, x: Double(x) + 0.5, y: Double(y) + 0.5) } }
                for _ in 0..<Int(30 * density) { if let (x, y) = groundPoint(in: region) { plant(random.unit() < 0.5 ? .grass : .flower, x: x, y: y) } }
                if style == .islands || configuration.floatingIslands == true { islands(in: region) }
            case "ruins":
                for index in 0..<Int((style == .ruins ? 7 : 4) * density * configuration.buildingFactor) {
                    if let (x, y) = spot(in: region, 6, 6) { addBuilding(.ruins, at: x, y, variant: index + random.int(0...99)); pickup(x: Double(x) + 3, y: Double(y) + 3, z: 0, shards: 2) }
                }
                for _ in 0..<Int(6 * density * configuration.enemyFactor) { if let (x, y) = groundPoint(in: region) { creature(.enemy, x: Double(x) + 0.5, y: Double(y) + 0.5) } }
                if configuration.miniBoss && !configuration.maze, let (x, y) = groundPoint(in: region) { creature(.miniBoss, x: Double(x) + 0.5, y: Double(y) + 0.5) }
                for _ in 0..<Int(20 * density) { if let (x, y) = groundPoint(in: region) { plant(.grass, x: x, y: y) } }
            case "maze":
                let cells = configuration.density == .high ? 8 : 6
                let side = cells * 2 + 1
                let x = region.x - side / 2, y = region.y - side / 2
                do {
                    let maze = SpatialMaze.generate(width: cells, height: cells, random: &random)
                    let group = nextID("group")
                    world.groups.append(BuildingGroup(id: group, name: L10n.t("玻璃迷宫", "Glass Maze"), motionID: nil, origin: .generated, template: "maze"))
                    var wallIndex = 0
                    for ty in 0..<side { for tx in 0..<side where maze.wall(tx, ty) {
                        let cx = x + tx, cy = y + ty
                        guard (0..<256).contains(cx), (0..<256).contains(cy) else { continue }
                        world.blocks.append(SpatialBlock(id: "\(group):\(wallIndex)", x: cx, y: cy, elevation: 0, thickness: 2, glass: .tinted("9FB8FF", density: 0.5), groupID: group, origin: .generated))
                        occupied.insert(key(cx, cy)); wallIndex += 1
                    } }
                    // Keep the approach to the entrance open.
                    for open in 1...3 { reserved.insert(key(x + maze.entrance * 2 + 1, y - open)) }
                    summary.blocks += wallIndex; summary.mazes += 1
                    for end in maze.deadEnds.prefix(3) { pickup(x: Double(x + end.0 * 2 + 1) + 0.5, y: Double(y + end.1 * 2 + 1) + 0.5, z: 0, shards: 4) }
                    creature(.guardian, x: Double(x + maze.entrance * 2 + 1) + 0.5, y: Double(y) - 1.5)
                    if configuration.miniBoss { creature(.miniBoss, x: Double(x + maze.exit * 2 + 1) + 0.5, y: Double(y + side) + 1.5) }
                }
            case "boss":
                let x = region.x - 5, y = region.y - 5
                addBuilding(.bossArena, at: x, y)
                creature(.boss, x: Double(x) + 5.5, y: Double(y) + 5.5, z: 0.4)
                pickup(x: Double(x) + 5.5, y: Double(y) + 8.5, z: 0.4, shards: 10)
            default: break
            }
        }
        // A few glow plants along the paths so routes read at a glance.
        var lamp = 0
        for (_, cell) in corridors.sorted(by: { $0.key < $1.key }) where (cell.0 + cell.1) % 23 == 0 && lamp < 40 {
            world.plants.append(PlantEntity(id: nextID("lamp"), kind: .glow, x: cell.0, y: cell.1, z: 0, scale: 0.6, hue: 0.55, origin: .generated)); lamp += 1; summary.plants += 1
        }
        return (world, summary)
    }

    // MARK: Validation

    /// Problems with a generated layout (empty when it is playable).
    static func validate(_ world: SpatialWorld) -> [String] {
        let geometry = SpatialGeometry(blocks: world.blocks, plants: world.plants)
        let navigator = SpatialNavigator(geometry: geometry)
        var problems: [String] = []
        // Spawn: standable and with nothing solid on it.
        if geometry.blocked(x: world.spawn.x, y: world.spawn.y, z: world.spawn.z) { problems.append("spawn blocked") }
        let reach = navigator.reachable(from: world.spawn, climb: 1.0, drop: 64)
        if reach.count < 400 { problems.append("spawn enclosed (\(reach.count))") }
        func reachable(_ point: SpatialVector, slack: Int = 1) -> Bool {
            let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
            for dx in -slack...slack { for dy in -slack...slack {
                for h in navigator.surfaces(x: x + dx, y: y + dy) where abs(h - point.z) < 0.6 {
                    if reach.contains(SpatialNavigator.Node(x: x + dx, y: y + dy, level: Int((h * 20).rounded()))) { return true }
                }
            } }
            return false
        }
        for creature in world.creatures where creature.origin == .generated {
            if !reachable(creature.position, slack: creature.kind == .boss ? 3 : 1) { problems.append("\(creature.kind.rawValue) unreachable"); break }
        }
        for pickup in world.pickups where pickup.origin == .generated && !pickup.collected {
            if !reachable(pickup.position, slack: 1) { problems.append("chest unreachable"); break }
        }
        // No hostile right next to the spawn.
        if world.creatures.contains(where: { $0.kind.hostile && ($0.position - world.spawn).flatLength < 14 }) { problems.append("hostile near spawn") }
        return problems
    }
}

/// A perfect maze (one path between any two cells) on a cell grid, drawn
/// as walls on a (2w+1) × (2h+1) tile grid. Entrance on the south side,
/// exit on the north side.
struct SpatialMaze: Sendable {
    let width: Int, height: Int
    private(set) var open: Set<Int> = []
    let entrance: Int, exit: Int
    private(set) var deadEnds: [(Int, Int)] = []

    var side: (Int, Int) { (width * 2 + 1, height * 2 + 1) }

    func wall(_ tx: Int, _ ty: Int) -> Bool {
        let (w, h) = side
        guard (0..<w).contains(tx), (0..<h).contains(ty) else { return false }
        if ty == 0 && tx == entrance * 2 + 1 { return false }
        if ty == h - 1 && tx == exit * 2 + 1 { return false }
        return !open.contains(ty * w + tx)
    }

    static func generate(width: Int, height: Int, random: inout SpatialRandom) -> SpatialMaze {
        var maze = SpatialMaze(width: width, height: height, entrance: random.int(0...(width - 1)), exit: random.int(0...(width - 1)))
        let w = width * 2 + 1
        var visited = Set<Int>(), stack = [(0, 0)]
        visited.insert(0); maze.open.insert(1 * w + 1)
        while let (cx, cy) = stack.last {
            let options = [(1, 0), (-1, 0), (0, 1), (0, -1)].map { (cx + $0.0, cy + $0.1, $0.0, $0.1) }
                .filter { (0..<width).contains($0.0) && (0..<height).contains($0.1) && !visited.contains($0.1 * width + $0.0) }
            if options.isEmpty {
                let exits = [(1, 0), (-1, 0), (0, 1), (0, -1)].filter { maze.open.contains((cy * 2 + 1 + $0.1) * w + cx * 2 + 1 + $0.0) }.count
                if exits == 1 && !(cx == 0 && cy == 0) { maze.deadEnds.append((cx, cy)) }
                stack.removeLast(); continue
            }
            let (nx, ny, dx, dy) = random.pick(options)
            visited.insert(ny * width + nx)
            maze.open.insert((cy * 2 + 1 + dy) * w + cx * 2 + 1 + dx)
            maze.open.insert((ny * 2 + 1) * w + nx * 2 + 1)
            stack.append((nx, ny))
        }
        return maze
    }

    /// Tiles from entrance to exit, or nil if the maze is not solvable.
    func solve() -> [(Int, Int)]? {
        let (w, h) = side
        let start = (entrance * 2 + 1, 0), goal = (exit * 2 + 1, h - 1)
        var previous: [Int: Int] = [start.1 * w + start.0: -1], queue = [start], head = 0
        while head < queue.count {
            let (x, y) = queue[head]; head += 1
            if (x, y) == goal {
                var path: [(Int, Int)] = [], k = y * w + x
                while k >= 0 { path.append((k % w, k / w)); k = previous[k]! }
                return path.reversed()
            }
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard (0..<w).contains(nx), (0..<h).contains(ny), !wall(nx, ny), previous[ny * w + nx] == nil else { continue }
                previous[ny * w + nx] = y * w + x; queue.append((nx, ny))
            }
        }
        return nil
    }
}
