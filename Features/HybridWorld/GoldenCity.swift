import Foundation

// 月光水晶城 (Crystal Moon City) — the Golden World reference town.
//
// A 96×96 walled core inside the 256×256 region, laid out by fixed district
// rules (north castle on a terrace, central fountain plaza, east homes and
// gardens, west inn / workshop / market, south gate, river and stone bridge,
// forest and winding roads outside). Buildings come from the Architecture
// Kit, so the same rules with another seed or art style give another town
// of the same quality, not a random scatter.
//
// The plan is rebuilt from (seed, intent): only those two are saved (in the
// World Director blueprint), never thousands of cell lists. Every object is
// `.generated`; anything the player built or edited is never covered.

enum GoldenWater: String, Codable, Sendable {
    case river, lake
}

/// What the words ask of a town. Clamped data only — an AI may fill it.
struct GoldenTownIntent: Codable, Equatable, Sendable {
    var style = ArtStyle.crystalFantasy
    var water = GoldenWater.river
    var forest = true
    var mountains = true
    var gardens = true
    var winding = true

    static func parse(_ prompt: String) -> GoldenTownIntent {
        let t = prompt.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        var intent = GoldenTownIntent()
        if has("木屋", "砖", "古典", "传统", "classic", "wooden", "brick", "medieval") && !has("水晶", "crystal", "玻璃", "glass") { intent.style = .classicFantasy }
        if has("湖", "lake") { intent.water = .lake }
        if has("无森林", "沙漠", "no forest", "desert") { intent.forest = false }
        if has("平原", "无山", "plain", "no mountain") { intent.mountains = false }
        if has("笔直", "棋盘", "straight", "grid") { intent.winding = false }
        return intent
    }
}

enum GoldenSurface: String, Sendable {
    case street, plaza, path, outer
}

struct GoldenViewpoint: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var x: Double
    var y: Double
    var z: Double
    /// Camera yaw in degrees (0 looks north, like `SpatialCameraRules`).
    var yaw: Double
    var indoor = false
    var position: SpatialVector { SpatialVector(x, y, z) }
}

struct GoldenDistrict: Equatable, Sendable {
    var key: String
    var name: String
    /// BiomeRegion kind for the World Director: plaza, district, garden, safe, forest.
    var kind: String
    var x: Int
    var y: Int
    var radius: Int
    var z = 0.0
}

struct GoldenCell: Hashable, Sendable {
    var x: Int
    var y: Int
    var key: Int { y * WorldGeometry.width + x }
    var inMap: Bool { (0..<WorldGeometry.width).contains(x) && (0..<WorldGeometry.width).contains(y) }
}

struct GoldenSpot: Equatable, Sendable {
    var x: Int
    var y: Int
    var base = 0.0
}

struct GoldenCityPlan: Sendable {
    static let version = 1
    static let coreMin = 80, coreMax = 175
    static let terraceHeight = 2.0

    var seed: UInt64
    var intent: GoldenTownIntent
    var buildings: [KitBuildingSpec] = []
    var landmarkKey = "spire"
    var roads: [Int: GoldenSurface] = [:]
    var water = Set<Int>()
    var bridgeDeck = Set<Int>()
    var bridgeRails = Set<Int>()
    var banks = Set<Int>()
    var wall = Set<Int>()
    var terrace = Set<Int>()
    /// Stair cell → top height.
    var stairs: [Int: Double] = [:]
    var fountain = GoldenSpot(x: 127, y: 127)
    var lamps: [GoldenSpot] = []
    var crystals: [GoldenSpot] = []
    var benches: [(spot: GoldenSpot, horizontal: Bool)] = []
    var stalls: [GoldenSpot] = []
    var beds: [(x: Int, y: Int, width: Int, depth: Int)] = []
    var fences: [GoldenSpot] = []
    var trees: [GoldenSpot] = []
    var bushes: [GoldenSpot] = []
    var flowers: [GoldenSpot] = []
    var citizens: [SpatialVector] = []
    var farMountains: [TerrainFeature] = []
    var districts: [GoldenDistrict] = []
    var viewpoints: [GoldenViewpoint] = []
    var route: [WorldPoint] = []
    var spawn = GoldenViewpoint(key: "spawn", name: "出发点", x: 127.5, y: 50.5, z: 0, yaw: 0)

    var pack: ArtStylePack { intent.style.pack }
    var landmark: KitBuildingSpec? { buildings.first { $0.key == landmarkKey } }
    static func key(_ x: Int, _ y: Int) -> Int { y * WorldGeometry.width + x }
    static func cell(_ key: Int) -> GoldenCell { GoldenCell(x: key % WorldGeometry.width, y: key / WorldGeometry.width) }
}

// MARK: Planner

enum GoldenCityPlanner {
    static func plan(seed: UInt64, intent: GoldenTownIntent = GoldenTownIntent()) -> GoldenCityPlan {
        var random = SpatialRandom(seed: seed ^ 0x601D_E2C1_7A11_5EED)
        var plan = GoldenCityPlan(seed: seed, intent: intent)
        plan.buildings = buildings(&random)
        water(&plan, &random)
        fortifications(&plan)
        castleTerrace(&plan)
        roads(&plan, &random)
        doorPaths(&plan)
        streetFurniture(&plan)
        gardens(&plan)
        forest(&plan, &random)
        viewpoints(&plan)
        return plan
    }

    // MARK: Buildings

    private static func spec(_ key: String, _ name: String, _ kind: KitBuildingKind, _ x0: Int, _ y0: Int, _ w: Int, _ d: Int,
                             door: BuildingSide, storeys: Int, roof: KitRoof, base: Double = 0) -> KitBuildingSpec {
        KitBuildingSpec(key: key, name: name, kind: kind, x0: x0, y0: y0, width: w, depth: d, base: base, storeys: storeys, roof: roof, door: door)
    }

    /// Fixed footprints (designed with two-cell gaps so roofs never touch),
    /// varied storeys, roofs, windows and details per seed.
    static func buildings(_ random: inout SpatialRandom) -> [KitBuildingSpec] {
        let t = GoldenCityPlan.terraceHeight
        var list: [KitBuildingSpec] = []
        // North: castle on the terrace. The spire is the focal point on the avenue axis.
        var spire = spec("spire", "月光尖塔", .keep, 124, 158, 8, 8, door: .south, storeys: random.int(5...6), roof: .spire, base: t)
        spire.windowEvery = 2; spire.banner = true; spire.finial = true
        var westWing = spec("wing-w", "西翼殿", .keep, 110, 157, 12, 10, door: .south, storeys: 3, roof: .hip, base: t)
        westWing.windowEvery = 2; westWing.balcony = true
        var eastWing = spec("wing-e", "东翼殿", .keep, 134, 157, 12, 10, door: .south, storeys: 3, roof: random.pick([.hip, .gable]), base: t)
        eastWing.windowEvery = 3; eastWing.banner = true
        var westTower = spec("tower-w", "西塔", .castleTower, 102, 161, 6, 6, door: .south, storeys: 4, roof: .spire, base: t)
        westTower.windowEvery = 2
        var eastTower = spec("tower-e", "东塔", .castleTower, 148, 161, 6, 6, door: .south, storeys: random.int(4...5), roof: .spire, base: t)
        eastTower.windowEvery = 2; eastTower.banner = true
        list += [spire, westWing, eastWing, westTower, eastTower]

        // Gates (walk-through) and wall towers.
        for (key, name, x0, y0, w, d, door) in [("gate-s", "南门", 123, 78, 10, 6, BuildingSide.south), ("gate-w", "西门", 78, 123, 6, 10, .west), ("gate-e", "东门", 172, 123, 6, 10, .east)] {
            var gate = spec(key, name, .gatehouse, x0, y0, w, d, door: door, storeys: 2, roof: .flat)
            gate.doorWidth = 4; gate.passage = true; gate.windowEvery = 0; gate.banner = true
            list.append(gate)
        }
        for (key, x0, y0, door) in [("wt-sw", 81, 81, BuildingSide.north), ("wt-se", 169, 81, .north), ("wt-nw", 81, 169, .south), ("wt-ne", 169, 169, .south)] {
            var tower = spec(key, "城墙塔", .wallTower, x0, y0, 6, 6, door: door, storeys: 2, roof: .spire)
            tower.windowEvery = 0
            list.append(tower)
        }

        // Town. North row doors face the street (south), south row doors face north.
        let roofs: [KitRoof] = [.gable, .hip]
        func town(_ key: String, _ name: String, _ kind: KitBuildingKind, _ x0: Int, _ y0: Int, _ w: Int, _ d: Int, _ door: BuildingSide, storeys: ClosedRange<Int>) -> KitBuildingSpec {
            var b = spec(key, name, kind, x0, y0, w, d, door: door, storeys: random.int(storeys), roof: random.pick(roofs))
            b.windowEvery = random.pick([2, 3])
            b.balcony = b.storeys >= 2 && random.unit() < 0.5
            b.sign = kind == .shop || kind == .inn || kind == .workshop
            return b
        }
        list.append(town("shop-e", "水晶铺", .shop, 141, 130, 9, 8, .south, storeys: 2...2))
        list.append(town("house-e1", "月光居", .house, 153, 130, 9, 9, .south, storeys: 1...2))
        list.append(town("house-e2", "星屋", .house, 164, 131, 7, 8, .south, storeys: 1...2))
        list.append(town("house-e3", "花匠屋", .house, 142, 117, 9, 9, .north, storeys: 1...2))
        list.append(town("house-e4", "湖畔屋", .house, 154, 118, 9, 8, .north, storeys: 1...2))
        var chapel = town("chapel", "月神礼拜堂", .chapel, 165, 114, 6, 12, .north, storeys: 3...3)
        chapel.roof = .spire; chapel.windowEvery = 2; chapel.balcony = false
        list.append(chapel)
        var inn = town("inn", "月门旅馆", .inn, 86, 130, 12, 10, .south, storeys: 2...2)
        inn.roof = .gable; inn.balcony = true; inn.furnished = true
        list.append(inn)
        var workshop = town("workshop", "工坊", .workshop, 101, 130, 8, 8, .south, storeys: 1...1)
        workshop.roof = .gable
        list.append(workshop)
        list.append(town("shop-w", "杂货铺", .shop, 111, 130, 5, 8, .south, storeys: 1...2))
        var market = town("market", "西市集", .pavilion, 86, 114, 13, 12, .north, storeys: 1...1)
        market.open = true; market.roof = .gable; market.windowEvery = 0; market.balcony = false; market.sign = false
        list.append(market)
        var library = town("library", "星图书馆", .library, 101, 116, 10, 10, .north, storeys: 2...2)
        library.roof = .hip
        list.append(library)
        var guardhouse = town("guardhouse", "卫兵所", .guardhouse, 113, 96, 9, 9, .east, storeys: 2...2)
        guardhouse.roof = .flat; guardhouse.banner = true
        list.append(guardhouse)
        var lodge = town("lodge", "旅人驿站", .inn, 134, 95, 10, 10, .west, storeys: 2...2)
        lodge.roof = .gable; lodge.balcony = true; lodge.sign = true
        list.append(lodge)

        // No two town buildings may read as copies: nudge details until every signature differs.
        var seen = Set<String>()
        for index in list.indices where !list[index].kind.repeats {
            var attempt = 0
            while seen.contains(list[index].signature) && attempt < 8 {
                switch attempt % 3 {
                case 0: list[index].windowEvery = list[index].windowEvery == 2 ? 3 : 2
                case 1: list[index].sign.toggle()
                default: list[index].banner.toggle()
                }
                attempt += 1
            }
            seen.insert(list[index].signature)
        }
        return list
    }

    // MARK: Water and bridge

    private static func water(_ plan: inout GoldenCityPlan, _ random: inout SpatialRandom) {
        switch plan.intent.water {
        case .river:
            let phase = random.unit() * 6
            for x in 16...239 {
                let center = 60 + Int((2 * sin(Double(x) / 19 + phase)).rounded())
                for y in (center - 2)...(center + 1) { plan.water.insert(GoldenCityPlan.key(x, y)) }
            }
        case .lake:
            for x in 80...176 { for y in 34...66 {
                let dx = Double(x - 128) / 46, dy = Double(y - 50) / 14
                if dx * dx + dy * dy <= 1 { plan.water.insert(GoldenCityPlan.key(x, y)) }
            } }
        }
        let crossing = plan.water.map(GoldenCityPlan.cell).filter { (124...131).contains($0.x) }.map(\.y)
        guard let low = crossing.min(), let high = crossing.max() else { return }
        for y in low...high {
            for x in 125...130 { plan.bridgeDeck.insert(GoldenCityPlan.key(x, y)) }
        }
        for y in (low - 1)...(high + 1) {
            plan.bridgeRails.insert(GoldenCityPlan.key(124, y)); plan.bridgeRails.insert(GoldenCityPlan.key(131, y))
        }
        plan.water.subtract(plan.bridgeDeck)
        plan.water.subtract(plan.bridgeRails)
        plan.spawn = GoldenViewpoint(key: "spawn", name: "出发点", x: 127.5, y: Double(low - 5) + 0.5, z: 0, yaw: 0)
    }

    // MARK: Wall, gates, terrace

    private static func fortifications(_ plan: inout GoldenCityPlan) {
        let gates = plan.buildings.filter { $0.kind == .gatehouse }
        func inGate(_ x: Int, _ y: Int) -> Bool { gates.contains { x >= $0.x0 && x <= $0.x1 && y >= $0.y0 && y <= $0.y1 } }
        let lo = GoldenCityPlan.coreMin, hi = GoldenCityPlan.coreMax
        for i in lo...hi {
            for (x, y) in [(i, lo), (i, hi), (lo, i), (hi, i)] where !inGate(x, y) { plan.wall.insert(GoldenCityPlan.key(x, y)) }
        }
    }

    private static func castleTerrace(_ plan: inout GoldenCityPlan) {
        for x in 100...155 { for y in 152...168 { plan.terrace.insert(GoldenCityPlan.key(x, y)) } }
        // Five steps of 0.4 up to the terrace (the walk step is 0.5).
        for (row, y) in (147...151).enumerated() {
            for x in 124...131 { plan.stairs[GoldenCityPlan.key(x, y)] = Double(row + 1) * 0.4 }
        }
        for x in 100...155 where !(124...131).contains(x) {
            plan.fences.append(GoldenSpot(x: x, y: 152, base: GoldenCityPlan.terraceHeight))
        }
    }

    // MARK: Roads

    private static func roads(_ plan: inout GoldenCityPlan, _ random: inout SpatialRandom) {
        func paint(_ x: Int, _ y: Int, _ surface: GoldenSurface) {
            guard (0..<WorldGeometry.width).contains(x), (0..<WorldGeometry.width).contains(y) else { return }
            let k = GoldenCityPlan.key(x, y)
            guard !plan.bridgeDeck.contains(k), !plan.bridgeRails.contains(k), !plan.water.contains(k), !plan.wall.contains(k) else { return }
            if plan.roads[k] == nil || surface == .plaza { plan.roads[k] = surface }
        }
        // Plaza with a ring pattern; the fountain sits in the middle.
        for x in 116...139 { for y in 116...139 {
            if hypot(Double(x - plan.fountain.x), Double(y - plan.fountain.y)) <= 3.5 { continue }
            paint(x, y, .plaza)
        } }
        // Avenue (gate → plaza → castle stairs) and the east–west street.
        for x in 126...129 {
            for y in 78...115 { paint(x, y, .street) }
            for y in 140...146 { paint(x, y, .street) }
        }
        for y in 126...129 {
            for x in 78...115 { paint(x, y, .street) }
            for x in 140...177 { paint(x, y, .street) }
        }
        // Outside the walls: straight near the gate and bridge, winding further out.
        let waterTop = plan.bridgeDeck.map { $0 / WorldGeometry.width }.min() ?? 60
        let straightFrom = max(8, waterTop - 8)
        let phase = random.unit() * 6
        func wiggle(_ t: Double, fade: Double) -> Int {
            guard plan.intent.winding else { return 0 }
            return Int((6 * sin(t / 13 + phase) * fade).rounded())
        }
        var previous: Int?
        for y in stride(from: 77, through: 0, by: -1) {
            if y >= straightFrom || plan.bridgeDeck.contains(GoldenCityPlan.key(127, y)) {
                for x in 126...129 { paint(x, y, .outer) }
                previous = 127
                continue
            }
            let fade = min(1, Double(straightFrom - y) / 10)
            let center = 127 + wiggle(Double(y), fade: fade)
            let from = min(center, previous ?? center), to = max(center, previous ?? center)
            for c in from...to { for x in (c - 1)...(c + 1) { paint(x, y, .outer) } }
            previous = center
        }
        for (range, gateEdge, step) in [(Array((0...77).reversed()), 77, -1), (Array(178...255), 178, 1)] {
            var last: Int?
            for x in range {
                let distance = abs(x - gateEdge)
                let fade = min(1, max(0, Double(distance - 10) / 10))
                let center = 127 + (distance <= 10 ? 0 : wiggle(Double(x) * Double(step), fade: fade))
                let from = min(center, last ?? center), to = max(center, last ?? center)
                let rows = distance <= 10 ? Array(126...129) : Array((from - 1)...(to + 1))
                for y in rows { paint(x, y, .outer) }
                last = center
            }
        }
        // Banks: a low stone edge where land meets water, except at the bridge.
        for k in plan.water {
            let c = GoldenCityPlan.cell(k)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let n = GoldenCell(x: c.x + dx, y: c.y + dy)
                guard n.inMap else { continue }
                let nk = n.key
                if plan.water.contains(nk) || plan.bridgeDeck.contains(nk) || plan.bridgeRails.contains(nk) || plan.roads[nk] != nil { continue }
                plan.banks.insert(nk)
            }
        }
    }

    /// A path from every ground-floor door to the nearest road, straight out from the door.
    private static func doorPaths(_ plan: inout GoldenCityPlan) {
        func insideBuilding(_ x: Int, _ y: Int) -> Bool {
            plan.buildings.contains { x >= $0.x0 && x <= $0.x1 && y >= $0.y0 && y <= $0.y1 }
        }
        for building in plan.buildings where building.base == 0 && building.kind != .gatehouse {
            let step = building.door.normal
            for socket in building.doorSocket {
                var cells: [Int] = []
                var x = socket.x, y = socket.y
                var reached = false
                for _ in 0..<14 {
                    guard (1..<(WorldGeometry.width - 1)).contains(x), (1..<(WorldGeometry.width - 1)).contains(y) else { break }
                    let k = GoldenCityPlan.key(x, y)
                    if let surface = plan.roads[k], surface != .path { reached = true; break }
                    if plan.wall.contains(k) || plan.water.contains(k) || plan.terrace.contains(k) || insideBuilding(x, y) { break }
                    cells.append(k)
                    x += Int(step.x); y += Int(step.y)
                }
                if reached { for k in cells where plan.roads[k] == nil { plan.roads[k] = .path } }
            }
        }
    }

    // MARK: Furniture, gardens, forest

    private static func streetFurniture(_ plan: inout GoldenCityPlan) {
        for y in stride(from: 87, through: 113, by: 7) { plan.lamps += [GoldenSpot(x: 125, y: y), GoldenSpot(x: 130, y: y)] }
        // Street lamps stand in the gaps between buildings, not in front of doors.
        for (x, y) in [(99, 130), (110, 130), (100, 125), (113, 125), (140, 125), (140, 130), (151, 130), (163, 130), (152, 125), (164, 125)] {
            plan.lamps.append(GoldenSpot(x: x, y: y))
        }
        plan.lamps += [GoldenSpot(x: 117, y: 117), GoldenSpot(x: 138, y: 117), GoldenSpot(x: 117, y: 138), GoldenSpot(x: 138, y: 138)]
        plan.lamps += [GoldenSpot(x: 123, y: 153, base: GoldenCityPlan.terraceHeight), GoldenSpot(x: 132, y: 153, base: GoldenCityPlan.terraceHeight)]
        if let low = plan.bridgeDeck.map({ $0 / WorldGeometry.width }).min(), let high = plan.bridgeDeck.map({ $0 / WorldGeometry.width }).max() {
            plan.lamps += [GoldenSpot(x: 124, y: low - 2), GoldenSpot(x: 131, y: low - 2), GoldenSpot(x: 124, y: high + 2), GoldenSpot(x: 131, y: high + 2)]
        }
        plan.crystals += [GoldenSpot(x: 119, y: 119), GoldenSpot(x: 136, y: 119), GoldenSpot(x: 119, y: 136), GoldenSpot(x: 136, y: 136),
                          GoldenSpot(x: 122, y: 76), GoldenSpot(x: 133, y: 76),
                          GoldenSpot(x: 120, y: 154, base: GoldenCityPlan.terraceHeight), GoldenSpot(x: 135, y: 154, base: GoldenCityPlan.terraceHeight)]
        plan.benches += [(GoldenSpot(x: 121, y: 118), true), (GoldenSpot(x: 133, y: 118), true), (GoldenSpot(x: 121, y: 137), true), (GoldenSpot(x: 133, y: 137), true)]
        plan.stalls += [GoldenSpot(x: 89, y: 117), GoldenSpot(x: 94, y: 117), GoldenSpot(x: 89, y: 121), GoldenSpot(x: 94, y: 121)]
        plan.citizens = [SpatialVector(124.5, 121.5, 0), SpatialVector(150.5, 146.5, 0), SpatialVector(92.5, 128.5, 0)]
    }

    private static func gardens(_ plan: inout GoldenCityPlan) {
        guard plan.intent.gardens else { return }
        // East gardens behind the homes, between them and the castle terrace.
        for x in [144, 151, 158, 165] { plan.beds.append((x: x, y: 142, width: 5, depth: 3)) }
        plan.beds.append((x: 160, y: 156, width: 6, depth: 4))
        for bed in plan.beds {
            for x in (bed.x + 1)..<(bed.x + bed.width - 1) { for y in (bed.y + 1)..<(bed.y + bed.depth - 1) { plan.flowers.append(GoldenSpot(x: x, y: y)) } }
        }
        for x in stride(from: 142, through: 172, by: 2) { plan.fences.append(GoldenSpot(x: x, y: 140)) }
        for spot in [(146, 148), (153, 149), (160, 147), (167, 150), (158, 163), (166, 162), (162, 167), (170, 156)] { plan.trees.append(GoldenSpot(x: spot.0, y: spot.1)) }
        // South-east orchard and south-west yard.
        for x in stride(from: 147, through: 167, by: 5) { for y in stride(from: 88, through: 108, by: 5) { plan.trees.append(GoldenSpot(x: x, y: y)) } }
        for x in stride(from: 88, through: 106, by: 6) { for y in stride(from: 88, through: 106, by: 6) { plan.trees.append(GoldenSpot(x: x, y: y)) } }
        for spot in [(119, 113), (136, 113), (119, 142), (136, 142)] { plan.bushes.append(GoldenSpot(x: spot.0, y: spot.1)) }
    }

    private static func forest(_ plan: inout GoldenCityPlan, _ random: inout SpatialRandom) {
        if plan.intent.mountains {
            for (index, x) in [70, 128, 186].enumerated() {
                plan.farMountains.append(TerrainFeature(kind: .mountain, center: WorldPoint(x: x, y: 236 + (index == 1 ? 2 : 0), z: 0), radius: 8, height: 24 + Double(random.int(0...6))))
            }
        }
        guard plan.intent.forest else { return }
        func clear(_ x: Int, _ y: Int) -> Bool {
            if x >= 68 && x <= 187 && y >= 68 && y <= 187 { return false }
            for mountain in plan.farMountains where hypot(Double(x - mountain.center.x), Double(y - mountain.center.y)) < Double(mountain.radius + 3) { return false }
            for dx in -2...2 { for dy in -2...2 {
                let k = GoldenCityPlan.key(x + dx, y + dy)
                if plan.roads[k] != nil || plan.water.contains(k) || plan.banks.contains(k) || plan.bridgeRails.contains(k) { return false }
            } }
            return true
        }
        for gx in stride(from: 5, to: 251, by: 7) { for gy in stride(from: 5, to: 251, by: 7) {
            let x = gx + random.int(0...4) - 2, y = gy + random.int(0...4) - 2
            guard (4..<252).contains(x), (4..<252).contains(y), clear(x, y), random.unit() < 0.65 else { continue }
            if random.unit() < 0.72 { plan.trees.append(GoldenSpot(x: x, y: y)) } else { plan.bushes.append(GoldenSpot(x: x, y: y)) }
        } }
    }

    // MARK: Viewpoints, districts, route

    private static func viewpoints(_ plan: inout GoldenCityPlan) {
        let s = plan.spawn
        let bridgeNorth = Double((plan.bridgeDeck.map { $0 / WorldGeometry.width }.max() ?? 64) + 2) + 0.5
        plan.viewpoints = [
            GoldenViewpoint(key: "gate", name: "城门", x: 127.5, y: 86.5, z: 0, yaw: 0),
            GoldenViewpoint(key: "plaza", name: "主广场", x: 127.5, y: 121.5, z: 0, yaw: 0),
            GoldenViewpoint(key: "street", name: "东西大街", x: 100.5, y: 127.5, z: 0, yaw: 90),
            GoldenViewpoint(key: "castle", name: "城堡台阶", x: 127.5, y: 154.5, z: GoldenCityPlan.terraceHeight, yaw: 180),
            GoldenViewpoint(key: "garden", name: "东园", x: 156.5, y: 146.5, z: 0, yaw: 0),
            GoldenViewpoint(key: "market", name: "西市", x: 92.5, y: 128.5, z: 0, yaw: 180),
            GoldenViewpoint(key: "bridge", name: "石桥", x: 127.5, y: bridgeNorth, z: 0, yaw: 0),
            GoldenViewpoint(key: "forest", name: "森林边缘", x: 127.5, y: max(6.5, s.y - 22), z: 0, yaw: 0),
            GoldenViewpoint(key: "inn", name: "旅馆内部", x: 91.5, y: 133.5, z: 0, yaw: 0, indoor: true),
        ]
        plan.districts = [
            GoldenDistrict(key: "plaza", name: "主广场", kind: "plaza", x: 127, y: 121, radius: 10),
            GoldenDistrict(key: "castle", name: "水晶城堡", kind: "district", x: 127, y: 155, radius: 10, z: GoldenCityPlan.terraceHeight),
            GoldenDistrict(key: "east", name: "东区居民", kind: "district", x: 150, y: 127, radius: 10),
            GoldenDistrict(key: "west", name: "西区工坊", kind: "district", x: 100, y: 127, radius: 10),
            GoldenDistrict(key: "garden", name: "东园", kind: "garden", x: 156, y: 146, radius: 6),
            GoldenDistrict(key: "south", name: "南门石桥", kind: "safe", x: 127, y: Int(s.y), radius: 5),
        ]
        if plan.intent.forest { plan.districts.append(GoldenDistrict(key: "forest", name: "外围森林", kind: "forest", x: 40, y: 200, radius: 24)) }
        plan.route = [
            WorldPoint(x: 127, y: Int(s.y), z: 0), WorldPoint(x: 127, y: Int(bridgeNorth), z: 0), WorldPoint(x: 127, y: 86, z: 0),
            WorldPoint(x: 127, y: 121, z: 0), WorldPoint(x: 127, y: 145, z: 0), WorldPoint(x: 127, y: 155, z: GoldenCityPlan.terraceHeight),
        ]
    }
}

// MARK: Draft — the plan as kit pieces, in build priority order

/// One placement unit. Atomic units (buildings) go in whole or not at all.
struct GoldenUnit: Equatable, Sendable {
    var key: String
    var name: String
    var layer: WorldLayer
    var priority: Int
    var atomic: Bool
    var building: KitBuildingSpec?
    var pieces: [KitPiece]
}

struct GoldenPlant: Equatable, Sendable {
    var tag: String
    var kind: PlantKind
    var x: Int
    var y: Int
    var z: Double
    var scale: Double
    var hue: Double
}

struct GoldenDraft: Equatable, Sendable {
    var units: [GoldenUnit]
    var plants: [GoldenPlant]
    var citizens: [SpatialVector]

    var pieceCount: Int { units.reduce(0) { $0 + $1.pieces.count } }
}

enum GoldenCityDraftBuilder {
    static func draft(_ plan: GoldenCityPlan) -> GoldenDraft {
        var units: [GoldenUnit] = []
        func cellPieces(_ cells: [Int], _ make: (GoldenCell) -> [KitPiece]) -> [KitPiece] {
            cells.sorted().flatMap { make(GoldenCityPlan.cell($0)) }
        }
        // 0 — the bones: terrace and stairs, castle, gates, wall, core streets, fountain.
        let terrace = cellPieces(Array(plan.terrace)) { c in [KitPiece(tag: "t:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: GoldenCityPlan.terraceHeight, slot: .wall)] }
            + plan.stairs.keys.sorted().map { k in
                let c = GoldenCityPlan.cell(k)
                return KitPiece(tag: "st:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: plan.stairs[k]!, slot: .trim)
            }
        units.append(GoldenUnit(key: "terrace", name: "城堡台地", layer: .terrain, priority: 0, atomic: true, building: nil, pieces: terrace))
        for building in plan.buildings {
            let priority: Int
            switch building.kind {
            case .keep, .castleTower, .gatehouse: priority = 0
            case .wallTower: priority = 2
            default: priority = 1
            }
            units.append(GoldenUnit(key: "b-" + building.key, name: building.name, layer: .buildings, priority: priority, atomic: true, building: building, pieces: KitAssembler.building(building)))
        }
        let wall = cellPieces(Array(plan.wall)) { c in
            var pieces = [KitPiece(tag: "wall:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: 4, slot: .wall)]
            if (c.x + c.y) % 2 == 0 { pieces.append(KitPiece(tag: "crenel:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 4, top: 4.8, slot: .trim)) }
            return pieces
        }
        units.append(GoldenUnit(key: "wall", name: "城墙", layer: .buildings, priority: 0, atomic: false, building: nil, pieces: wall))
        func roadPieces(_ surfaces: Set<GoldenSurface>) -> [KitPiece] {
            plan.roads.keys.sorted().compactMap { k in
                guard let surface = plan.roads[k], surfaces.contains(surface) else { return nil }
                let c = GoldenCityPlan.cell(k)
                var slot = KitSlot.street
                if surface == .plaza {
                    let ring = Int(max(abs(Double(c.x) - 127.5), abs(Double(c.y) - 127.5)))
                    slot = ring % 2 == 0 ? .plaza : .street
                }
                return KitPiece(tag: "road:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: KitMetrics.slab, slot: slot, collision: .decor)
            }
        }
        units.append(GoldenUnit(key: "streets", name: "主街与广场", layer: .roads, priority: 0, atomic: false, building: nil, pieces: roadPieces([.street, .plaza])))
        units.append(GoldenUnit(key: "fountain", name: "水晶喷泉", layer: .decorations, priority: 0, atomic: true, building: nil, pieces: KitAssembler.fountain(cx: plan.fountain.x, cy: plan.fountain.y)))
        // 1 — paths to doors.
        units.append(GoldenUnit(key: "paths", name: "门前小路", layer: .roads, priority: 1, atomic: false, building: nil, pieces: roadPieces([.path])))
        // 2 — river, bridge and banks.
        let bridge = cellPieces(Array(plan.bridgeDeck)) { c in [KitPiece(tag: "deck:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: 0.3, slot: .trim)] }
            + cellPieces(Array(plan.bridgeRails)) { c in [KitPiece(tag: "rail:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: 1.1, slot: .trim)] }
        units.append(GoldenUnit(key: "bridge", name: "石桥", layer: .roads, priority: 2, atomic: true, building: nil, pieces: bridge))
        let water = cellPieces(Array(plan.water)) { c in [KitPiece(tag: "water:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: 0.12, slot: .water, collision: .decor)] }
            + cellPieces(Array(plan.banks)) { c in [KitPiece(tag: "bank:\(c.x):\(c.y)", x: c.x, y: c.y, bottom: 0, top: 0.7, slot: .trim)] }
        units.append(GoldenUnit(key: "water", name: plan.intent.water == .lake ? "湖" : "河", layer: .terrain, priority: 2, atomic: false, building: nil, pieces: water))
        // 3 — outer roads and street furniture.
        units.append(GoldenUnit(key: "outer", name: "城外道路", layer: .roads, priority: 3, atomic: false, building: nil, pieces: roadPieces([.outer])))
        var furniture: [KitPiece] = []
        for lamp in plan.lamps { furniture += KitAssembler.lamp(x: lamp.x, y: lamp.y, base: lamp.base) }
        for crystal in plan.crystals { furniture += KitAssembler.crystal(x: crystal.x, y: crystal.y, base: crystal.base) }
        for bench in plan.benches { furniture += KitAssembler.bench(x: bench.spot.x, y: bench.spot.y, horizontal: bench.horizontal) }
        for stall in plan.stalls { furniture += KitAssembler.stall(x: stall.x, y: stall.y) }
        for bed in plan.beds { furniture += KitAssembler.flowerBed(x0: bed.x, y0: bed.y, width: bed.width, depth: bed.depth) }
        for fence in plan.fences { furniture += KitAssembler.fence([(fence.x, fence.y)], base: fence.base) }
        units.append(GoldenUnit(key: "furniture", name: "街道设施", layer: .decorations, priority: 3, atomic: false, building: nil, pieces: furniture))
        // Stable: same priority keeps the order above.
        units = units.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)

        var plants: [GoldenPlant] = []
        var hue = SpatialRandom(seed: plan.seed ^ 0xF10E)
        for (index, spot) in plan.trees.enumerated() { plants.append(GoldenPlant(tag: "tree:\(index)", kind: .tree, x: spot.x, y: spot.y, z: spot.base, scale: 0.85 + hue.unit() * 0.4, hue: 0.3 + hue.unit() * 0.08)) }
        for (index, spot) in plan.bushes.enumerated() { plants.append(GoldenPlant(tag: "bush:\(index)", kind: .bush, x: spot.x, y: spot.y, z: spot.base, scale: 0.8 + hue.unit() * 0.3, hue: 0.32)) }
        for (index, spot) in plan.flowers.enumerated() { plants.append(GoldenPlant(tag: "flower:\(index)", kind: .flower, x: spot.x, y: spot.y, z: 0.3, scale: 0.9, hue: hue.unit())) }
        return GoldenDraft(units: units, plants: plants, citizens: plan.citizens)
    }
}

// MARK: Budget and placement

struct GoldenBudget: Equatable, Sendable {
    var maxBlocks: Int
    var maxPlants: Int

    static func of(_ tier: WorldPerformanceTier) -> GoldenBudget {
        switch tier {
        case .low: GoldenBudget(maxBlocks: 8_500, maxPlants: 700)
        case .standard: GoldenBudget(maxBlocks: 12_000, maxPlants: 1_100)
        case .high: GoldenBudget(maxBlocks: 15_000, maxPlants: 1_600)
        }
    }
}

struct GoldenStampReport: Equatable, Sendable {
    var placedBuildings: [String] = []
    var skippedUnits: [String] = []
    var blocks = 0
    var plants = 0
    var spawn = SpatialVector(127.5, 50.5, 0)
    var facing = 90.0
}

/// Solid height ranges per cell, for the no-overlap rule.
struct GoldenOccupancy {
    var solid: [Int: [ClosedRange<Double>]] = [:]

    init(_ blocks: [SpatialBlock]) {
        for block in blocks where block.collision == .solid { solid[block.y * WorldGeometry.width + block.x, default: []].append(block.elevation...block.top) }
    }

    func fits(_ x: Int, _ y: Int, _ bottom: Double, _ top: Double) -> Bool {
        guard let ranges = solid[y * WorldGeometry.width + x] else { return true }
        return !ranges.contains { $0.lowerBound < top - 0.01 && bottom < $0.upperBound - 0.01 }
    }

    mutating func add(_ block: SpatialBlock) {
        if block.collision == .solid { solid[block.y * WorldGeometry.width + block.x, default: []].append(block.elevation...block.top) }
    }
}

enum GoldenCity {
    static let idPrefix = "golden"
    static let address = RegionAddress(column: 7, row: 7)
    static let defaultSeed: UInt64 = 20_261_106

    static func isPlaced(_ world: SpatialWorld) -> Bool { world.blocks.contains { $0.id.hasPrefix(idPrefix + ":") } }

    static func block(_ piece: KitPiece, id: String, pack: ArtStylePack, group: String?) -> SpatialBlock {
        var block = SpatialBlock(id: id, x: piece.x, y: piece.y, elevation: piece.bottom, thickness: piece.thickness, size: piece.size,
                                 glass: pack.glass(piece.slot), collision: piece.collision, groupID: group, origin: .generated)
        block.hybridPart = piece.part
        return block
    }

    static func occluder(_ spec: KitBuildingSpec, group: String) -> BuildingOccluder {
        BuildingOccluder(id: String(spec.key.prefix(64)), name: spec.name, minX: spec.x0, maxX: spec.x1, minY: spec.y0, maxY: spec.y1,
                         interiorCeiling: spec.eaves, groupID: group, roofTop: spec.roofTop, base: spec.base)
    }

    /// Places the town into the open region. User-made or user-edited objects
    /// stay; a building that would touch one is left out whole.
    @discardableResult
    static func stamp(onto world: inout SpatialWorld, plan: GoldenCityPlan, budget: GoldenBudget = .of(.standard)) -> GoldenStampReport {
        let draft = GoldenCityDraftBuilder.draft(plan)
        let pack = plan.pack
        var report = GoldenStampReport()
        var occupancy = GoldenOccupancy(world.blocks)
        let userCells = Set(world.blocks.filter { $0.origin == .user }.map { $0.y * WorldGeometry.width + $0.x })
        var existing = Set(world.blocks.map(\.id))
        var occluders = (world.hybrid?.occluders ?? []).filter { o in world.groups.contains { $0.id == o.groupID } }
        var added = 0
        for unit in draft.units {
            let group = unit.building.map { "\(idPrefix):group:\($0.key)" }
            let blocks = unit.pieces.map { block($0, id: "\(idPrefix):\(unit.key):\($0.tag)", pack: pack, group: group) }
            if unit.atomic {
                let fits = blocks.allSatisfy { b in
                    b.valid && !existing.contains(b.id) && !userCells.contains(b.y * WorldGeometry.width + b.x) &&
                        (b.collision != .solid || occupancy.fits(b.x, b.y, b.elevation, b.top))
                }
                guard fits, added + blocks.count <= budget.maxBlocks, world.blocks.count + blocks.count <= SpatialWorld.blockLimit else {
                    report.skippedUnits.append(unit.name); continue
                }
                for b in blocks { world.blocks.append(b); occupancy.add(b); existing.insert(b.id) }
                added += blocks.count
                if let spec = unit.building, let group {
                    world.groups.append(BuildingGroup(id: group, name: spec.name, motionID: nil, origin: .generated, template: "kit-" + spec.kind.rawValue))
                    occluders.append(occluder(spec, group: group))
                    report.placedBuildings.append(spec.key)
                }
            } else {
                var skipped = false
                for b in blocks {
                    guard added < budget.maxBlocks, world.blocks.count < SpatialWorld.blockLimit else { skipped = true; break }
                    let k = b.y * WorldGeometry.width + b.x
                    guard b.valid, !existing.contains(b.id), !userCells.contains(k), b.collision != .solid || occupancy.fits(b.x, b.y, b.elevation, b.top) else { continue }
                    world.blocks.append(b); occupancy.add(b); existing.insert(b.id); added += 1
                }
                if skipped { report.skippedUnits.append(unit.name) }
            }
        }
        var plants = 0
        let plantIDs = Set(world.plants.map(\.id))
        for plant in draft.plants {
            guard plants < budget.maxPlants else { break }
            let id = "\(idPrefix):plant:\(plant.tag)"
            let k = plant.y * WorldGeometry.width + plant.x
            guard !plantIDs.contains(id), !userCells.contains(k), plan.roads[k] == nil, occupancy.fits(plant.x, plant.y, plant.z, plant.z + 1.5) else { continue }
            world.plants.append(PlantEntity(id: id, kind: plant.kind, x: plant.x, y: plant.y, z: plant.z, scale: plant.scale, hue: plant.hue, origin: .generated))
            if plant.kind.solid { occupancy.solid[k, default: []].append(plant.z...(plant.z + 1.5)) }
            plants += 1
        }
        for (index, spot) in draft.citizens.enumerated() {
            let id = "\(idPrefix):citizen:\(index)"
            guard world.creatures.allSatisfy({ $0.id != id }) else { continue }
            world.creatures.append(CreatureEntity(id: id, kind: .neutral, position: spot, home: spot, health: 20, maxHealth: 20, damage: 0, origin: .generated))
        }
        let mode = world.hybrid?.viewMode ?? .spatial3D
        world.hybrid = HybridWorldSave(viewMode: mode, regionColumn: address.column, regionRow: address.row, occluders: Array(occluders.prefix(48)))
        report.blocks = added
        report.plants = plants
        report.spawn = plan.spawn.position
        report.facing = 90
        return report
    }
}
