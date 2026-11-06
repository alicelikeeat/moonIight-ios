import Foundation

// 月光中央城 — the quality benchmark for this slice, built from ordinary
// `SpatialWorld` blocks inside the central 256×256 region (continent address
// column 7, row 7). Streets are decoration so stepping onto them does not
// change the walk height. Roofs and walls stay in the collision list when hidden.
//
// World Director still owns generation: these ids do not use the `wd` prefix,
// and any block the player has edited (`origin == .user`) is left in place.

enum HybridVisualPart: String, Codable, Sendable {
    case roof, wall, street, landmark, plaza
}

enum CentralTown {
    static let idPrefix = "moonlight-town"
    static let address = RegionAddress(column: 7, row: 7)

    @discardableResult
    static func stamp(onto world: inout SpatialWorld) -> Int {
        var draft = TownDraft(world: world)
        draft.roads()
        draft.plazaMarks()
        for spec in HouseSpec.district { draft.building(spec) }
        draft.trees()
        draft.citizen()
        draft.finish()
        let skipped = draft.skipped
        world = draft.world
        return skipped
    }

    static func stampedBlank() -> SpatialWorld {
        var world = SpatialWorld()
        stamp(onto: &world)
        return world
    }
}

private enum TownFacing {
    case south, north, east, west
}

private struct HouseSpec {
    var key: String
    var name: String
    var x0: Int
    var y0: Int
    var x1: Int
    var y1: Int
    var door: TownFacing
    var stories: Int
    var landmark: Bool

    static let district: [HouseSpec] = [
        HouseSpec(key: "nw", name: "月门客栈", x0: 110, y0: 136, x1: 119, y1: 145, door: .east, stories: 3, landmark: false),
        HouseSpec(key: "ne", name: "水晶铺", x0: 136, y0: 136, x1: 145, y1: 145, door: .west, stories: 3, landmark: false),
        HouseSpec(key: "sw", name: "南屋", x0: 110, y0: 110, x1: 119, y1: 119, door: .east, stories: 3, landmark: false),
        HouseSpec(key: "se", name: "灯屋", x0: 136, y0: 110, x1: 145, y1: 119, door: .west, stories: 3, landmark: false),
        HouseSpec(key: "spire", name: "月光尖塔", x0: 122, y0: 160, x1: 133, y1: 169, door: .south, stories: 8, landmark: true),
    ]

    func isDoorway(x: Int, y: Int, layer: Int) -> Bool {
        guard layer < 2 else { return false }
        let midX = (x0 + x1) / 2, midY = (y0 + y1) / 2
        switch door {
        case .south: return y == y0 && (x == midX || x == midX + 1)
        case .north: return y == y1 && (x == midX || x == midX + 1)
        case .west: return x == x0 && (y == midY || y == midY + 1)
        case .east: return x == x1 && (y == midY || y == midY + 1)
        }
    }
}

private struct TownDraft {
    var world: SpatialWorld
    var occluders: [BuildingOccluder] = []
    var skipped = 0

    mutating func roads() {
        let glass = TownGlass.street
        for x in 124...131 {
            for y in 96...159 { slab(x: x, y: y, part: .street, glass: glass) }
        }
        for y in 124...131 {
            for x in 96...159 where !(124...131).contains(x) { slab(x: x, y: y, part: .street, glass: glass) }
        }
    }

    mutating func plazaMarks() {
        let post = TownGlass.plaza
        for (x, y) in [(123, 123), (132, 123), (123, 132), (132, 132)] {
            _ = block(id: "\(CentralTown.idPrefix):post:\(x):\(y)", x: x, y: y, elevation: 0, thickness: 1.4, glass: post, collision: .decor, part: .plaza, group: nil)
        }
        let crystal = TownGlass.landmark
        for (x, y) in [(127, 127), (128, 127)] {
            _ = block(id: "\(CentralTown.idPrefix):fountain:\(x):\(y)", x: x, y: y, elevation: 0.12, thickness: 1.1, glass: crystal, collision: .decor, part: .landmark, group: nil)
        }
    }

    mutating func building(_ spec: HouseSpec) {
        let groupID = "\(CentralTown.idPrefix):group:\(spec.key)"
        world.groups.append(BuildingGroup(id: groupID, name: spec.name, motionID: nil, origin: .generated, template: spec.landmark ? "landmark" : "house"))
        let wallGlass = spec.landmark ? TownGlass.landmark : TownGlass.house
        let roofGlass = spec.landmark ? TownGlass.landmark : TownGlass.roof
        var walls: [String] = []
        var roofs: [String] = []
        var perimeter: [(Int, Int)] = []
        for x in spec.x0...spec.x1 { perimeter.append((x, spec.y0)); perimeter.append((x, spec.y1)) }
        if spec.y1 - spec.y0 > 1 {
            for y in (spec.y0 + 1)..<spec.y1 { perimeter.append((spec.x0, y)); perimeter.append((spec.x1, y)) }
        }
        for layer in 0..<spec.stories {
            for (x, y) in perimeter where !spec.isDoorway(x: x, y: y, layer: layer) {
                let id = "\(CentralTown.idPrefix):\(spec.key):w:\(x):\(y):\(layer)"
                if block(id: id, x: x, y: y, elevation: Double(layer), thickness: 1, glass: wallGlass, collision: .solid, part: .wall, group: groupID) != nil {
                    walls.append(id)
                }
            }
        }
        for x in spec.x0...spec.x1 {
            for y in spec.y0...spec.y1 {
                let id = "\(CentralTown.idPrefix):\(spec.key):r:\(x):\(y)"
                if block(id: id, x: x, y: y, elevation: Double(spec.stories), thickness: spec.landmark ? 0.55 : 0.4, glass: roofGlass, collision: .solid, part: .roof, group: groupID) != nil {
                    roofs.append(id)
                }
            }
        }
        guard !walls.isEmpty || !roofs.isEmpty else {
            world.groups.removeAll { $0.id == groupID }
            return
        }
        occluders.append(BuildingOccluder(id: spec.key, name: spec.name, minX: spec.x0, maxX: spec.x1, minY: spec.y0, maxY: spec.y1, interiorCeiling: Double(spec.stories), floorIndex: 0, roofIDs: roofs, wallIDs: walls))
    }

    mutating func trees() {
        let spots = [(122, 100), (122, 112), (122, 148), (133, 100), (133, 112), (133, 148), (100, 122), (112, 122), (148, 122), (156, 122), (100, 133), (112, 133), (148, 133), (156, 133)]
        for (index, spot) in spots.enumerated() {
            let id = "\(CentralTown.idPrefix):tree:\(index)"
            guard world.plants.allSatisfy({ $0.id != id }), !world.blocks.contains(where: { $0.x == spot.0 && $0.y == spot.1 && $0.origin == .user }) else { continue }
            world.plants.append(PlantEntity(id: id, kind: .tree, x: spot.0, y: spot.1, z: 0, scale: 0.9, hue: 0.34, origin: .generated))
        }
    }

    mutating func citizen() {
        let id = "\(CentralTown.idPrefix):citizen"
        guard world.creatures.allSatisfy({ $0.id != id }) else { return }
        let spot = SpatialVector(136.5, 120.5, 0)
        world.creatures.append(CreatureEntity(id: id, kind: .neutral, position: spot, home: spot, health: 20, maxHealth: 20, damage: 0, origin: .generated))
    }

    mutating func finish() {
        let mode = world.hybrid?.viewMode ?? .spatial3D
        world.hybrid = HybridWorldSave(viewMode: mode, regionColumn: CentralTown.address.column, regionRow: CentralTown.address.row, occluders: occluders)
    }

    private mutating func slab(x: Int, y: Int, part: HybridVisualPart, glass: SpatialGlass) {
        _ = block(id: "\(CentralTown.idPrefix):road:\(x):\(y)", x: x, y: y, elevation: 0, thickness: 0.08, glass: glass, collision: .decor, part: part, group: nil)
    }

    @discardableResult
    private mutating func block(id: String, x: Int, y: Int, elevation: Double, thickness: Double, glass: SpatialGlass, collision: SpatialCollision, part: HybridVisualPart, group: String?) -> String? {
        guard (0..<WorldGeometry.width).contains(x), (0..<WorldGeometry.width).contains(y) else { return nil }
        if world.blocks.contains(where: { $0.id == id }) { return nil }
        if collision == .solid {
            let top = elevation + thickness
            if world.blocks.contains(where: { $0.x == x && $0.y == y && $0.collision == .solid && $0.elevation < top - 0.01 && elevation < $0.top - 0.01 }) {
                skipped += 1
                return nil
            }
        } else if part == .street && world.blocks.contains(where: { $0.x == x && $0.y == y }) {
            skipped += 1
            return nil
        } else if world.blocks.contains(where: { $0.x == x && $0.y == y && $0.origin == .user }) {
            skipped += 1
            return nil
        }
        var block = SpatialBlock(id: id, x: x, y: y, elevation: elevation, thickness: thickness, glass: glass, collision: collision, groupID: group, origin: .generated)
        block.hybridPart = part
        guard block.valid else { skipped += 1; return nil }
        world.blocks.append(block)
        return id
    }
}

private enum TownGlass {
    static let street = make("D5E2EE", density: 0.55, semantic: .streetCrystal, role: .ground, glow: false)
    static let house = make("E7EEF6", density: 0.4, semantic: .houseGlass, role: .structure, glow: false)
    static let roof = make("F4F7FB", density: 0.62, semantic: .moonlightCrystalWhite, role: .structure, glow: false)
    static let landmark = make("F7FBFF", density: 0.48, semantic: .landmarkGlass, role: .landmark, glow: true)
    static let plaza = make("E7EEF6", density: 0.5, semantic: .moonlightCrystalBlue, role: .decor, glow: false)

    static func make(_ hex: String, density: Double, semantic: GlassSemantic, role: GlassRenderRole, glow: Bool) -> SpatialGlass {
        var glass = SpatialGlass.tinted(hex, density: density)
        glass.surface = .crystal
        glass.glow = glow
        glass.semantic = semantic.rawValue
        glass.role = role.rawValue
        return glass
    }
}
