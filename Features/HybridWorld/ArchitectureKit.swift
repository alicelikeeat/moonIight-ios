import Foundation

// Moonlight Architecture Kit. A building is assembled from a few modules
// (wall, window, door, pillar, roof, balcony, banner, sign) that share one
// grid and one set of heights, then expanded into ordinary `SpatialBlock`s.
// That keeps collision, saving, editing, undo and both cameras on the data
// the game already has: there is no second building format to load.
//
// Grid standard (docs/golden-world/GOLDEN_WORLD_SPEC.md):
//   1 cell = 1 m · storey 3 · door 2 high · window sill 1, opening 1
//   walls 1 cell thick on the footprint edge · roof eaves overhang 1
//   gable/hip rise 0.5 per cell · spire rise 1.0 per cell
// The door socket is the cell straight outside the door; roads join there.

enum KitMetrics {
    static let storey = 3.0
    static let doorHeight = 2.0
    static let sill = 1.0
    static let windowHeight = 1.0
    static let roofRise = 0.5
    static let spireRise = 1.0
    static let overhang = 1
    static let minFootprint = 4
    static let maxFootprint = 24
    static let maxStoreys = 6
    /// Road slabs sit on the ground without changing the walk height.
    static let slab = 0.08
}

/// Which side of a footprint. South is −y (the side the pixel camera sees first).
enum BuildingSide: String, Codable, CaseIterable, Sendable {
    case south, north, east, west

    /// Outward direction in map cells.
    var normal: (x: Double, y: Double) {
        switch self {
        case .south: return (0, -1)
        case .north: return (0, 1)
        case .east: return (1, 0)
        case .west: return (-1, 0)
        }
    }
}

/// What a block is to the hybrid view: roofs and walls can be cut or faded per building.
enum HybridVisualPart: String, Codable, Sendable {
    case roof, wall, street, landmark, plaza
}

// MARK: Materials and style packs

/// A material slot. Modules ask for a slot; the style pack decides the look.
enum KitSlot: String, Codable, CaseIterable, Sendable {
    case wall, trim, roof, window, accent, street, plaza, water, metal
}

struct KitMaterial: Equatable, Sendable {
    var tintHex: String
    var semantic: GlassSemantic
    var role: GlassRenderRole
    var surface: SpatialSurface?
    var density: Double
    var glow = false

    var glass: SpatialGlass {
        var glass = SpatialGlass.tinted(tintHex, density: density)
        glass.surface = surface
        glass.glow = glow
        glass.semantic = semantic.rawValue
        glass.role = role.rawValue
        return glass
    }
}

/// Art style packs. Layout rules are shared; only modules' materials change.
enum ArtStyle: String, Codable, CaseIterable, Sendable {
    case crystalFantasy, classicFantasy

    var title: String {
        switch self {
        case .crystalFantasy: L10n.t("水晶幻想", "Crystal Fantasy")
        case .classicFantasy: L10n.t("古典幻想", "Classic Fantasy")
        }
    }

    var pack: ArtStylePack {
        switch self {
        case .crystalFantasy:
            return ArtStylePack(style: self, materials: [
                .wall: KitMaterial(tintHex: "F1EEE8", semantic: .whiteStone, role: .structure, surface: .stone, density: 0.8),
                .trim: KitMaterial(tintHex: "D6D2CA", semantic: .whiteStone, role: .structure, surface: .stone, density: 0.8),
                .roof: KitMaterial(tintHex: "8FB8E0", semantic: .roofGlass, role: .structure, surface: .crystal, density: 0.6),
                .window: KitMaterial(tintHex: "BFE3FF", semantic: .windowGlass, role: .structure, surface: nil, density: 0.3),
                .accent: KitMaterial(tintHex: "F7FBFF", semantic: .landmarkGlass, role: .landmark, surface: .crystal, density: 0.48, glow: true),
                .street: KitMaterial(tintHex: "E4E1DA", semantic: .whiteStone, role: .ground, surface: .stone, density: 0.8),
                .plaza: KitMaterial(tintHex: "D5E2EE", semantic: .streetCrystal, role: .ground, surface: .crystal, density: 0.55),
                .water: KitMaterial(tintHex: "7EB6D8", semantic: .water, role: .water, surface: nil, density: 0.4),
                .metal: KitMaterial(tintHex: "9AA6B8", semantic: .metalTrim, role: .decor, surface: .metal, density: 0.8),
            ])
        case .classicFantasy:
            return ArtStylePack(style: self, materials: [
                .wall: KitMaterial(tintHex: "E9DCC4", semantic: .whiteStone, role: .structure, surface: .stone, density: 0.8),
                .trim: KitMaterial(tintHex: "7A5A3C", semantic: .wood, role: .structure, surface: .stone, density: 0.8),
                .roof: KitMaterial(tintHex: "B5523B", semantic: .roofTile, role: .structure, surface: .stone, density: 0.8),
                .window: KitMaterial(tintHex: "CFE6F2", semantic: .windowGlass, role: .structure, surface: nil, density: 0.3),
                .accent: KitMaterial(tintHex: "E8C468", semantic: .landmarkGlass, role: .landmark, surface: .metal, density: 0.6, glow: true),
                .street: KitMaterial(tintHex: "B9AE9C", semantic: .whiteStone, role: .ground, surface: .stone, density: 0.8),
                .plaza: KitMaterial(tintHex: "C9BFAE", semantic: .whiteStone, role: .ground, surface: .stone, density: 0.8),
                .water: KitMaterial(tintHex: "6FA6C8", semantic: .water, role: .water, surface: nil, density: 0.4),
                .metal: KitMaterial(tintHex: "5E5A55", semantic: .metalTrim, role: .decor, surface: .metal, density: 0.8),
            ])
        }
    }
}

struct ArtStylePack: Equatable, Sendable {
    var style: ArtStyle
    var materials: [KitSlot: KitMaterial]

    func material(_ slot: KitSlot) -> KitMaterial { materials[slot] ?? materials[.wall]! }
    func glass(_ slot: KitSlot) -> SpatialGlass { material(slot).glass }
    /// Every tint this pack may put in the world (the quality gate checks against it).
    var palette: Set<String> { Set(materials.values.map(\.tintHex)) }
}

// MARK: Building specs

enum KitBuildingKind: String, Codable, CaseIterable, Sendable {
    case house, shop, inn, workshop, chapel, library, keep, castleTower, wallTower, gatehouse, pavilion, guardhouse

    /// Wall towers repeat on purpose; everything else should look different.
    var repeats: Bool { self == .wallTower }
}

enum KitRoof: String, Codable, Sendable {
    case gable, hip, spire, flat
}

struct KitBuildingSpec: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var kind: KitBuildingKind
    var x0: Int
    var y0: Int
    var width: Int
    var depth: Int
    /// Ground height under the building (castle terrace is higher).
    var base: Double = 0
    var storeys: Int
    var roof: KitRoof
    var door: BuildingSide
    /// 2 for doors, 4 for city gates.
    var doorWidth = 2
    /// A window every `windowEvery` cells along a side (0 = none).
    var windowEvery = 3
    var balcony = false
    var banner = false
    var sign = false
    /// Columns and a roof, no walls (market pavilion).
    var open = false
    /// A counter and a lamp inside (one interior viewpoint).
    var furnished = false
    /// Crystal finial on top.
    var finial = false
    /// The door repeats on the opposite side (a gate you walk through).
    var passage = false

    var x1: Int { x0 + width - 1 }
    var y1: Int { y0 + depth - 1 }
    var eaves: Double { base + Double(storeys) * KitMetrics.storey }

    var valid: Bool {
        !key.isEmpty && key.count <= 40 && key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) && (1...32).contains(name.count) &&
            (KitMetrics.minFootprint...KitMetrics.maxFootprint).contains(width) && (KitMetrics.minFootprint...KitMetrics.maxFootprint).contains(depth) &&
            (1...KitMetrics.maxStoreys).contains(storeys) && x0 >= 1 && y0 >= 1 && x1 < WorldGeometry.width - 1 && y1 < WorldGeometry.width - 1 &&
            base.isFinite && (0...8).contains(base) && [2, 4].contains(doorWidth) && (0...6).contains(windowEvery) &&
            doorWidth <= (door == .south || door == .north ? width - 2 : depth - 2)
    }

    /// Two buildings with the same signature read as copies.
    var signature: String {
        "\(kind.rawValue)|\(width)x\(depth)|\(storeys)|\(roof.rawValue)|\(door.rawValue)|\(windowEvery)|\(balcony)|\(banner)|\(sign)|\(open)|\(passage)"
    }

    /// Footprint plus the roof's eaves overhang (flat roofs have none).
    var roofBounds: (x0: Int, y0: Int, x1: Int, y1: Int) {
        let o = roof == .flat ? 0 : KitMetrics.overhang
        return (x0 - o, y0 - o, x1 + o, y1 + o)
    }

    /// The cells the door takes on its side.
    var doorCells: [(x: Int, y: Int)] {
        let along = door == .south || door == .north ? width : depth
        let start = (along - doorWidth) / 2
        return (start..<(start + doorWidth)).map { i in
            switch door {
            case .south: return (x0 + i, y0)
            case .north: return (x0 + i, y1)
            case .west: return (x0, y0 + i)
            case .east: return (x1, y0 + i)
            }
        }
    }

    /// Door cells and, for a passage, the matching cells on the far side.
    var openingCells: [(x: Int, y: Int)] {
        guard passage else { return doorCells }
        return doorCells + doorCells.map { cell in
            switch door {
            case .south: return (cell.x, y1)
            case .north: return (cell.x, y0)
            case .west: return (x1, cell.y)
            case .east: return (x0, cell.y)
            }
        }
    }

    /// The cells straight outside the door, where paths connect.
    var doorSocket: [(x: Int, y: Int)] {
        doorCells.map { cell in
            switch door {
            case .south: return (cell.x, cell.y - 1)
            case .north: return (cell.x, cell.y + 1)
            case .west: return (cell.x - 1, cell.y)
            case .east: return (cell.x + 1, cell.y)
            }
        }
    }

    func side(x: Int, y: Int) -> BuildingSide? {
        if y == y0 { return .south }
        if y == y1 { return .north }
        if x == x0 { return .west }
        if x == x1 { return .east }
        return nil
    }

    /// Highest point of the roof (and finial).
    var roofTop: Double {
        let half = Double((min(width, depth) + 2 * KitMetrics.overhang - 1) / 2)
        let body: Double
        switch roof {
        case .flat: body = eaves + 0.6
        case .gable: body = eaves + 0.4 + half * KitMetrics.roofRise + 0.35
        case .hip: body = eaves + 0.4 + half * KitMetrics.roofRise
        case .spire: body = eaves + 0.6 + half * KitMetrics.spireRise
        }
        return min(SpatialBlock.maximumHeight, body + (finial ? 2.7 : 0))
    }
}

/// One box before it becomes a block. `tag` is unique inside its building.
struct KitPiece: Equatable, Sendable {
    var tag: String
    var x: Int
    var y: Int
    var bottom: Double
    var top: Double
    var size = 1.0
    var slot: KitSlot
    var collision = SpatialCollision.solid
    var part: HybridVisualPart?

    var thickness: Double { top - bottom }
}

enum KitAssembler {
    /// Every piece of one building, walls first. Deterministic.
    static func building(_ spec: KitBuildingSpec) -> [KitPiece] {
        guard spec.valid else { return [] }
        var pieces: [KitPiece] = []
        if spec.open { pieces += columns(spec) } else { pieces += walls(spec) }
        pieces += roof(spec)
        pieces += extras(spec)
        return pieces.filter { $0.top <= SpatialBlock.maximumHeight && $0.thickness >= 0.05 && $0.thickness <= 16 }
    }

    private static func perimeter(_ spec: KitBuildingSpec) -> [(Int, Int)] {
        var cells: [(Int, Int)] = []
        for x in spec.x0...spec.x1 { cells.append((x, spec.y0)); cells.append((x, spec.y1)) }
        for y in (spec.y0 + 1)..<spec.y1 { cells.append((spec.x0, y)); cells.append((spec.x1, y)) }
        return cells
    }

    private static func isCorner(_ spec: KitBuildingSpec, _ x: Int, _ y: Int) -> Bool {
        (x == spec.x0 || x == spec.x1) && (y == spec.y0 || y == spec.y1)
    }

    /// Position along a side, from 0 at its first corner.
    private static func along(_ spec: KitBuildingSpec, _ side: BuildingSide, _ x: Int, _ y: Int) -> Int {
        side == .south || side == .north ? x - spec.x0 : y - spec.y0
    }

    private static func walls(_ spec: KitBuildingSpec) -> [KitPiece] {
        var pieces: [KitPiece] = []
        let doors = Set(spec.openingCells.map { $0.y * WorldGeometry.width + $0.x })
        let doorFrame = Set(spec.openingCells.flatMap { cell -> [Int] in
            spec.door == .south || spec.door == .north
                ? [cell.y * WorldGeometry.width + cell.x - 1, cell.y * WorldGeometry.width + cell.x + 1]
                : [(cell.y - 1) * WorldGeometry.width + cell.x, (cell.y + 1) * WorldGeometry.width + cell.x]
        }).subtracting(doors)
        let gate = spec.doorWidth >= 4
        for (x, y) in perimeter(spec) {
            let key = y * WorldGeometry.width + x
            guard let side = spec.side(x: x, y: y) else { continue }
            let position = along(spec, side, x, y)
            let length = side == .south || side == .north ? spec.width : spec.depth
            for storey in 0..<spec.storeys {
                let z = spec.base + Double(storey) * KitMetrics.storey
                let tag = "w:\(x):\(y):\(storey)"
                func add(_ suffix: String, _ bottom: Double, _ top: Double, _ slot: KitSlot) {
                    pieces.append(KitPiece(tag: tag + suffix, x: x, y: y, bottom: bottom, top: top, slot: slot, part: .wall))
                }
                if isCorner(spec, x, y) || (storey == 0 && doorFrame.contains(key)) {
                    add("", z, z + KitMetrics.storey, .trim)
                } else if doors.contains(key) && storey == 0 {
                    // Door: open below the lintel. City gates stay open for the whole storey.
                    if !gate { add(":l", z + KitMetrics.doorHeight, z + KitMetrics.storey, .trim) }
                } else if doors.contains(key) && gate && storey == 1 {
                    add(":l", z, z + KitMetrics.storey, .trim)
                } else if spec.windowEvery > 0 && position > 0 && position < length - 1 && position % spec.windowEvery == spec.windowEvery / 2 {
                    add(":s", z, z + KitMetrics.sill, .wall)
                    add(":p", z + KitMetrics.sill, z + KitMetrics.sill + KitMetrics.windowHeight, .window)
                    add(":l", z + KitMetrics.sill + KitMetrics.windowHeight, z + KitMetrics.storey, .trim)
                } else {
                    add("", z, z + KitMetrics.storey, .wall)
                }
            }
        }
        return pieces
    }

    /// Pavilion: trim columns on the corners and every third cell of the edge.
    private static func columns(_ spec: KitBuildingSpec) -> [KitPiece] {
        perimeter(spec).compactMap { x, y in
            guard let side = spec.side(x: x, y: y) else { return nil }
            guard isCorner(spec, x, y) || along(spec, side, x, y) % 3 == 0 else { return nil }
            return KitPiece(tag: "c:\(x):\(y)", x: x, y: y, bottom: spec.base, top: spec.eaves, size: 0.6, slot: .trim, part: .wall)
        }
    }

    private static func roof(_ spec: KitBuildingSpec) -> [KitPiece] {
        var pieces: [KitPiece] = []
        let o = spec.roof == .flat ? 0 : KitMetrics.overhang
        let rx0 = spec.x0 - o, rx1 = spec.x1 + o, ry0 = spec.y0 - o, ry1 = spec.y1 + o
        let ridgeAlongX = spec.width >= spec.depth
        for x in rx0...rx1 {
            for y in ry0...ry1 {
                guard (0..<WorldGeometry.width).contains(x), (0..<WorldGeometry.width).contains(y) else { continue }
                let toEdge: Int
                switch spec.roof {
                case .gable: toEdge = ridgeAlongX ? min(y - ry0, ry1 - y) : min(x - rx0, rx1 - x)
                case .hip, .spire: toEdge = min(min(y - ry0, ry1 - y), min(x - rx0, rx1 - x))
                case .flat: toEdge = 0
                }
                let tag = "r:\(x):\(y)"
                switch spec.roof {
                case .flat:
                    let rim = x == rx0 || x == rx1 || y == ry0 || y == ry1
                    pieces.append(KitPiece(tag: tag, x: x, y: y, bottom: spec.eaves, top: spec.eaves + (rim ? 0.6 : 0.3), slot: rim ? .trim : .roof, part: .roof))
                case .gable, .hip:
                    pieces.append(KitPiece(tag: tag, x: x, y: y, bottom: spec.eaves, top: spec.eaves + 0.4 + Double(toEdge) * KitMetrics.roofRise, slot: .roof, part: .roof))
                case .spire:
                    pieces.append(KitPiece(tag: tag, x: x, y: y, bottom: spec.eaves, top: spec.eaves + 0.6 + Double(toEdge) * KitMetrics.spireRise, slot: .roof, part: .roof))
                }
            }
        }
        // Ridge crest: a small crystal every third ridge cell (gable only).
        if spec.roof == .gable {
            let half = ridgeAlongX ? (ry1 - ry0) / 2 : (rx1 - rx0) / 2
            let ridgeTop = spec.eaves + 0.4 + Double(half) * KitMetrics.roofRise
            if ridgeAlongX {
                for x in stride(from: rx0 + 1, through: rx1 - 1, by: 3) {
                    pieces.append(KitPiece(tag: "crest:\(x)", x: x, y: ry0 + half, bottom: ridgeTop, top: ridgeTop + 0.35, size: 0.4, slot: .accent, collision: .decor, part: .roof))
                }
            } else {
                for y in stride(from: ry0 + 1, through: ry1 - 1, by: 3) {
                    pieces.append(KitPiece(tag: "crest:\(y)", x: rx0 + half, y: y, bottom: ridgeTop, top: ridgeTop + 0.35, size: 0.4, slot: .accent, collision: .decor, part: .roof))
                }
            }
        }
        if spec.finial {
            let cx = (spec.x0 + spec.x1) / 2, cy = (spec.y0 + spec.y1) / 2
            let top = pieces.filter { $0.x == cx && $0.y == cy }.map(\.top).max() ?? spec.eaves
            pieces.append(KitPiece(tag: "fin:0", x: cx, y: cy, bottom: top, top: top + 1.5, size: 0.6, slot: .accent, collision: .decor, part: .roof))
            pieces.append(KitPiece(tag: "fin:1", x: cx, y: cy, bottom: top + 1.5, top: top + 2.7, size: 0.35, slot: .accent, collision: .decor, part: .roof))
        }
        return pieces
    }

    private static func extras(_ spec: KitBuildingSpec) -> [KitPiece] {
        var pieces: [KitPiece] = []
        let outside = spec.doorSocket
        // Balcony over the door: floor slab and two posts, first floor up.
        if spec.balcony && spec.storeys >= 2 {
            let z = spec.base + KitMetrics.storey
            for (index, cell) in outside.enumerated() {
                pieces.append(KitPiece(tag: "bal:\(index)", x: cell.x, y: cell.y, bottom: z - 0.3, top: z, slot: .trim))
                pieces.append(KitPiece(tag: "rail:\(index)", x: cell.x, y: cell.y, bottom: z, top: z + 0.9, size: 0.25, slot: .metal, collision: .decor))
            }
        }
        // Banner on the door side, beside the door.
        if spec.banner, let first = outside.first {
            let offset: (Int, Int) = spec.door == .south || spec.door == .north ? (-2, 0) : (0, -2)
            let x = first.x + offset.0, y = first.y + offset.1
            let top = spec.eaves - 0.4
            pieces.append(KitPiece(tag: "banner", x: x, y: y, bottom: max(spec.base + 1.2, top - 2.2), top: top, size: 0.5, slot: .accent, collision: .decor))
        }
        // Hanging sign beside the door at head height.
        if spec.sign, let last = outside.last {
            let offset: (Int, Int) = spec.door == .south || spec.door == .north ? (1, 0) : (0, 1)
            pieces.append(KitPiece(tag: "sign", x: last.x + offset.0, y: last.y + offset.1, bottom: spec.base + 2.1, top: spec.base + 2.7, size: 0.7, slot: .accent, collision: .decor))
        }
        // Interior: a counter across from the door and a glowing lamp on it.
        if spec.furnished && !spec.open {
            let cx = (spec.x0 + spec.x1) / 2, cy = (spec.y0 + spec.y1) / 2
            let horizontal = spec.door == .south || spec.door == .north
            let far = spec.door == .south ? spec.y1 - 2 : spec.door == .north ? spec.y0 + 2 : spec.door == .west ? spec.x1 - 2 : spec.x0 + 2
            for i in -1...1 {
                let x = horizontal ? cx + i : far, y = horizontal ? far : cy + i
                pieces.append(KitPiece(tag: "counter:\(i)", x: x, y: y, bottom: spec.base, top: spec.base + 1, slot: .trim))
            }
            let lx = horizontal ? cx : far, ly = horizontal ? far : cy
            pieces.append(KitPiece(tag: "lamp", x: lx, y: ly, bottom: spec.base + 1, top: spec.base + 1.5, size: 0.4, slot: .accent, collision: .decor))
        }
        return pieces
    }

    // MARK: Street and city modules (not buildings)

    static func lamp(x: Int, y: Int, base: Double = 0) -> [KitPiece] {
        [KitPiece(tag: "lamp:\(x):\(y):post", x: x, y: y, bottom: base, top: base + 2.6, size: 0.3, slot: .metal),
         KitPiece(tag: "lamp:\(x):\(y):head", x: x, y: y, bottom: base + 2.6, top: base + 3.05, size: 0.55, slot: .accent, collision: .decor)]
    }

    static func crystal(x: Int, y: Int, base: Double = 0) -> [KitPiece] {
        [KitPiece(tag: "crystal:\(x):\(y):0", x: x, y: y, bottom: base, top: base + 1.2, size: 0.5, slot: .accent, collision: .decor),
         KitPiece(tag: "crystal:\(x):\(y):1", x: x, y: y, bottom: base + 1.2, top: base + 2.0, size: 0.3, slot: .accent, collision: .decor)]
    }

    static func bench(x: Int, y: Int, horizontal: Bool) -> [KitPiece] {
        (0..<2).map { i in
            KitPiece(tag: "bench:\(x):\(y):\(i)", x: horizontal ? x + i : x, y: horizontal ? y : y + i, bottom: 0, top: 0.45, size: 0.8, slot: .trim)
        }
    }

    /// Low decor fence posts (no collision: the gaps are wider than the player).
    static func fence(_ cells: [(Int, Int)], base: Double = 0) -> [KitPiece] {
        cells.map { x, y in KitPiece(tag: "fence:\(x):\(y)", x: x, y: y, bottom: base, top: base + 0.8, size: 0.22, slot: .trim, collision: .decor) }
    }

    /// A raised flower bed edge. Flowers are plants placed by the caller.
    static func flowerBed(x0: Int, y0: Int, width: Int, depth: Int) -> [KitPiece] {
        var pieces: [KitPiece] = []
        for x in x0..<(x0 + width) { for y in y0..<(y0 + depth) where x == x0 || y == y0 || x == x0 + width - 1 || y == y0 + depth - 1 {
            pieces.append(KitPiece(tag: "bed:\(x):\(y)", x: x, y: y, bottom: 0, top: 0.3, slot: .trim, collision: .decor))
        } }
        return pieces
    }

    static func stall(x: Int, y: Int) -> [KitPiece] {
        [KitPiece(tag: "stall:\(x):\(y):0", x: x, y: y, bottom: 0, top: 1, slot: .trim),
         KitPiece(tag: "stall:\(x):\(y):1", x: x + 1, y: y, bottom: 0, top: 1, slot: .trim),
         KitPiece(tag: "stall:\(x):\(y):2", x: x, y: y, bottom: 2.3, top: 2.5, slot: .accent, collision: .decor),
         KitPiece(tag: "stall:\(x):\(y):3", x: x + 1, y: y, bottom: 2.3, top: 2.5, slot: .accent, collision: .decor)]
    }

    /// Fountain: stone rim, water, a column and two crystal tiers.
    static func fountain(cx: Int, cy: Int, radius: Int = 3) -> [KitPiece] {
        var pieces: [KitPiece] = []
        for dx in -radius...radius { for dy in -radius...radius {
            let d = (Double(dx * dx + dy * dy)).squareRoot()
            let x = cx + dx, y = cy + dy
            if d > Double(radius) + 0.5 { continue }
            if d > Double(radius) - 0.5 {
                pieces.append(KitPiece(tag: "fountain:rim:\(x):\(y)", x: x, y: y, bottom: 0, top: 0.6, slot: .trim))
            } else if dx == 0 && dy == 0 {
                pieces.append(KitPiece(tag: "fountain:base", x: x, y: y, bottom: 0, top: 1.6, size: 0.8, slot: .trim))
                pieces.append(KitPiece(tag: "fountain:tier0", x: x, y: y, bottom: 1.6, top: 2.6, size: 0.6, slot: .accent, collision: .decor))
                pieces.append(KitPiece(tag: "fountain:tier1", x: x, y: y, bottom: 2.6, top: 3.4, size: 0.35, slot: .accent, collision: .decor))
            } else {
                pieces.append(KitPiece(tag: "fountain:water:\(x):\(y)", x: x, y: y, bottom: 0, top: 0.35, slot: .water, collision: .decor))
            }
        } }
        return pieces
    }
}
