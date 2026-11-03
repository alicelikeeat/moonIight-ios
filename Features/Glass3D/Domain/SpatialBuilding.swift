import Foundation

// Building on the 2.5D glass world: templates made of ordinary blocks,
// group copy/move/turn/raise, height tools, conflict checks and media.

enum BuildingKind: String, Codable, CaseIterable, Sendable {
    case hut, tower, bridge, floatingPlatform, stairs, ruins, altar, mediaWall, bossArena
    var title: String {
        switch self {
        case .hut: L10n.t("玻璃小屋", "Glass Hut"); case .tower: L10n.t("玻璃高塔", "Glass Tower"); case .bridge: L10n.t("玻璃桥梁", "Glass Bridge")
        case .floatingPlatform: L10n.t("悬浮平台", "Floating Platform"); case .stairs: L10n.t("玻璃阶梯", "Glass Stairs")
        case .ruins: L10n.t("玻璃废墟", "Glass Ruins"); case .altar: L10n.t("玻璃祭坛", "Glass Altar")
        case .mediaWall: L10n.t("玻璃媒体墙", "Glass Media Wall"); case .bossArena: L10n.t("Boss 战斗平台", "Boss Arena")
        }
    }
    var symbol: String {
        switch self {
        case .hut: "house"; case .tower: "building.2"; case .bridge: "road.lanes"; case .floatingPlatform: "square.stack.3d.up"
        case .stairs: "stairs"; case .ruins: "building.columns"; case .altar: "flame"; case .mediaWall: "rectangle.on.rectangle"; case .bossArena: "shield.lefthalf.filled"
        }
    }
}

/// Cell offset and shape of one templated block.
private struct Piece { var dx: Int; var dy: Int; var z: Double; var thickness: Double; var size = 1.0; var collision = SpatialCollision.solid; var tint: String? = nil }

enum SpatialBuilder {
    /// Blocks for a building with its lower-left corner at (x, y) on height
    /// `elevation`. All blocks join one group so the building moves as one.
    static func building(_ kind: BuildingKind, x: Int, y: Int, elevation: Double, groupID: String, idPrefix: String,
                         origin: SpatialOrigin = .user, variant: Int = 0) -> [SpatialBlock] {
        var pieces: [Piece] = []
        switch kind {
        case .hut:
            for dx in 0..<5 { for dy in 0..<5 {
                let edge = dx == 0 || dx == 4 || dy == 0 || dy == 4
                pieces.append(Piece(dx: dx, dy: dy, z: 0, thickness: 0.2, collision: .oneWay))
                // Walls with a door on the south side.
                if edge && !(dy == 0 && dx == 2) { pieces.append(Piece(dx: dx, dy: dy, z: 0.2, thickness: 2)) }
                pieces.append(Piece(dx: dx, dy: dy, z: 2.2, thickness: 0.3, tint: "8FD3FF"))
            } }
        case .tower:
            let height = 6 + variant % 4
            for level in 0..<height { for dx in 0..<3 { for dy in 0..<3 where dx != 1 || dy != 1 {
                // A doorway at ground level.
                if level < 2 && dx == 1 && dy == 0 { continue }
                pieces.append(Piece(dx: dx, dy: dy, z: Double(level), thickness: 1))
            } } }
            pieces.append(contentsOf: (0..<3).flatMap { dx in (0..<3).map { dy in Piece(dx: dx, dy: dy, z: Double(height), thickness: 0.3, tint: "B9A6FF") } })
        case .bridge:
            for dx in 0..<9 {
                let rise = 1.0 - abs(Double(dx) - 4) / 4
                for dy in 0..<2 { pieces.append(Piece(dx: dx, dy: dy, z: 1 + rise, thickness: 0.25, collision: .oneWay)) }
            }
            // Ramps at both ends so it is walkable from the ground.
            pieces.append(Piece(dx: -1, dy: 0, z: 0, thickness: 0.5)); pieces.append(Piece(dx: -1, dy: 1, z: 0, thickness: 0.5))
            pieces.append(Piece(dx: 9, dy: 0, z: 0, thickness: 0.5)); pieces.append(Piece(dx: 9, dy: 1, z: 0, thickness: 0.5))
        case .floatingPlatform:
            for dx in 0..<4 { for dy in 0..<4 { pieces.append(Piece(dx: dx, dy: dy, z: 3, thickness: 0.35, collision: .oneWay, tint: "7FE3C8")) } }
        case .stairs:
            for step in 0..<8 { pieces.append(Piece(dx: step, dy: 0, z: 0, thickness: 0.45 * Double(step + 1))) ; pieces.append(Piece(dx: step, dy: 1, z: 0, thickness: 0.45 * Double(step + 1))) }
        case .ruins:
            var seed = UInt64(variant) &* 0x9E3779B97F4A7C15 &+ 7
            for dx in 0..<6 { for dy in 0..<6 where dx == 0 || dx == 5 || dy == 0 || dy == 5 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let height = Double((seed >> 33) % 4) * 0.5
                if (seed >> 40) % 3 == 0 { continue }
                pieces.append(Piece(dx: dx, dy: dy, z: 0, thickness: 0.5 + height, tint: "C9C2B8"))
            } }
        case .altar:
            for dx in 0..<3 { for dy in 0..<3 { pieces.append(Piece(dx: dx, dy: dy, z: 0, thickness: 0.4)) } }
            pieces.append(Piece(dx: 1, dy: 1, z: 0.4, thickness: 1.2, size: 0.6, tint: "FFD27A"))
        case .mediaWall:
            for dx in 0..<4 { for level in 0..<3 { pieces.append(Piece(dx: dx, dy: 0, z: Double(level), thickness: 1, collision: .media)) } }
        case .bossArena:
            for dx in 0..<11 { for dy in 0..<11 {
                let distance = hypot(Double(dx) - 5, Double(dy) - 5)
                guard distance <= 5.4 else { continue }
                pieces.append(Piece(dx: dx, dy: dy, z: 0, thickness: 0.4, tint: distance > 4.6 ? "FF6B6B" : nil))
            } }
            // Pillars at the rim, a gap on the south for the entrance.
            for (dx, dy) in [(1, 5), (9, 5), (5, 9), (2, 2), (8, 2), (2, 8), (8, 8)] { pieces.append(Piece(dx: dx, dy: dy, z: 0.4, thickness: 2.5, size: 0.7)) }
        }
        return pieces.enumerated().compactMap { index, piece in
            let px = x + piece.dx, py = y + piece.dy
            guard (0..<WorldGeometry.width).contains(px), (0..<WorldGeometry.width).contains(py) else { return nil }
            return SpatialBlock(id: "\(idPrefix):\(index)", x: px, y: py, elevation: elevation + piece.z, thickness: piece.thickness, size: piece.size,
                                glass: piece.tint.map { SpatialGlass.tinted($0) } ?? .clear, collision: piece.collision, groupID: groupID, origin: origin)
        }
    }

    /// Footprint of a building kind (for planning and previews).
    static func footprint(_ kind: BuildingKind) -> (width: Int, depth: Int) {
        switch kind {
        case .hut: (5, 5); case .tower: (3, 3); case .bridge: (11, 2); case .floatingPlatform: (4, 4); case .stairs: (8, 2)
        case .ruins: (6, 6); case .altar: (3, 3); case .mediaWall: (4, 1); case .bossArena: (11, 11)
        }
    }

    // MARK: Conflicts

    /// Solid blocks that would overlap an existing solid block in space.
    static func conflicts(_ candidates: [SpatialBlock], in world: SpatialWorld, ignoring: Set<String> = []) -> [String] {
        let index = SpatialIndex(blocks: world.blocks)
        var result: [String] = []
        for block in candidates where block.collision == .solid {
            let clash = index.blocks(atX: block.x, y: block.y).contains { other in
                !ignoring.contains(other.id) && other.id != block.id && other.collision == .solid &&
                    other.elevation < block.top - 1e-6 && block.elevation < other.top - 1e-6
            }
            if clash { result.append(block.id) }
        }
        return result
    }

    // MARK: Group operations

    static func blocks(of group: String, in world: SpatialWorld) -> [SpatialBlock] { world.blocks.filter { $0.groupID == group } }

    /// Copies a group `dx, dy, dz` away as a new group (cells off the map are dropped).
    static func copy(group: String, dx: Int, dy: Int, dz: Double, newGroup: String, idPrefix: String, world: inout SpatialWorld) {
        guard let original = world.groups.first(where: { $0.id == group }) else { return }
        let copies = blocks(of: group, in: world).enumerated().compactMap { index, block -> SpatialBlock? in
            var copy = block; copy.id = "\(idPrefix):\(index)"; copy.x += dx; copy.y += dy; copy.elevation += dz; copy.groupID = newGroup; copy.origin = .user
            return copy.valid ? copy : nil
        }
        world.groups.append(BuildingGroup(id: newGroup, name: String((original.name + L10n.t(" 副本", " Copy")).prefix(64)), motionID: nil, origin: .user, template: original.template))
        world.blocks.append(contentsOf: copies)
    }

    /// Moves every block of a group, keeping their relative heights.
    static func move(group: String, dx: Int, dy: Int, dz: Double, world: inout SpatialWorld) {
        for i in world.blocks.indices where world.blocks[i].groupID == group {
            var moved = world.blocks[i]; moved.x += dx; moved.y += dy; moved.elevation += dz; moved.origin = .user
            if moved.valid { world.blocks[i] = moved }
        }
    }

    /// Turns a group a quarter turn around its centre cell.
    static func rotateQuarter(group: String, world: inout SpatialWorld) {
        let members = blocks(of: group, in: world)
        guard let minX = members.map(\.x).min(), let maxX = members.map(\.x).max(), let minY = members.map(\.y).min(), let maxY = members.map(\.y).max() else { return }
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        for i in world.blocks.indices where world.blocks[i].groupID == group {
            var turned = world.blocks[i]
            let dx = turned.x - cx, dy = turned.y - cy
            turned.x = cx - dy; turned.y = cy + dx; turned.yaw = (turned.yaw + 90).truncatingRemainder(dividingBy: 360); turned.origin = .user
            if turned.valid { world.blocks[i] = turned }
        }
    }

    /// Raises or lowers blocks together (relative heights kept).
    static func raise(_ ids: Set<String>, by dz: Double, world: inout SpatialWorld) {
        for i in world.blocks.indices where ids.contains(world.blocks[i].id) {
            world.blocks[i].elevation = min(SpatialBlock.maximumHeight, max(-1, world.blocks[i].elevation + dz)); world.blocks[i].origin = .user
        }
    }
    /// Puts every block's bottom at the same height.
    static func align(_ ids: Set<String>, elevation: Double, world: inout SpatialWorld) {
        for i in world.blocks.indices where ids.contains(world.blocks[i].id) {
            world.blocks[i].elevation = min(SpatialBlock.maximumHeight, max(-1, elevation)); world.blocks[i].origin = .user
        }
    }
    /// Heights rising evenly from `from` to `to` along x then y.
    static func gradient(_ ids: Set<String>, from: Double, to: Double, world: inout SpatialWorld) {
        let ordered = world.blocks.indices.filter { ids.contains(world.blocks[$0].id) }.sorted { (world.blocks[$0].x, world.blocks[$0].y) < (world.blocks[$1].x, world.blocks[$1].y) }
        for (step, i) in ordered.enumerated() {
            let t = ordered.count > 1 ? Double(step) / Double(ordered.count - 1) : 0
            world.blocks[i].elevation = from + (to - from) * t; world.blocks[i].origin = .user
        }
    }
    static func snap(_ value: Double, step: Double) -> Double { step > 0 ? (value / step).rounded() * step : value }

    // MARK: Templates

    /// Saves a group as a reusable template (positions relative to its corner).
    static func template(from group: String, name: String, id: String, world: SpatialWorld) -> BuildingTemplate? {
        let members = blocks(of: group, in: world)
        guard let minX = members.map(\.x).min(), let minY = members.map(\.y).min(), let base = members.map(\.elevation).min() else { return nil }
        let relative = members.map { block -> SpatialBlock in
            var copy = block; copy.x -= minX; copy.y -= minY; copy.elevation -= base; copy.groupID = nil; copy.media = nil; copy.buttonTarget = nil; return copy
        }
        return BuildingTemplate(id: id, name: String(name.prefix(64)), blocks: relative)
    }
    static func stamp(_ template: BuildingTemplate, x: Int, y: Int, elevation: Double, groupID: String, idPrefix: String) -> [SpatialBlock] {
        template.blocks.enumerated().compactMap { index, block in
            var copy = block; copy.id = "\(idPrefix):\(index)"; copy.x += x; copy.y += y; copy.elevation += elevation; copy.groupID = groupID; copy.origin = .user
            return copy.valid ? copy : nil
        }
    }

    // MARK: Media on blocks

    /// Media grid across the top (or front) faces of the given blocks:
    /// one shared binding, a row and column per block by position.
    static func mediaGrid(bindingID: String, blocks ids: [String], face: SpatialFace, stretch: Bool, world: inout SpatialWorld) {
        let targets = world.blocks.filter { ids.contains($0.id) }
        guard let minX = targets.map(\.x).min(), let maxX = targets.map(\.x).max() else { return }
        // Top faces read like a map (rows from north to south); front faces
        // stand up, so rows go from the highest block down.
        let rowsByKey: [Double]
        if face == .top { rowsByKey = Array(Set(targets.map { Double($0.y) })).sorted(by: >) } else { rowsByKey = Array(Set(targets.map { ($0.elevation * 100).rounded() / 100 })).sorted(by: >) }
        let columns = maxX - minX + 1, rows = rowsByKey.count
        guard rows >= 1, columns >= 1, rows <= RPGMediaRegion.maximumSide, columns <= RPGMediaRegion.maximumSide else { return }
        for i in world.blocks.indices where ids.contains(world.blocks[i].id) {
            let block = world.blocks[i]
            let key = face == .top ? Double(block.y) : (block.elevation * 100).rounded() / 100
            guard let row = rowsByKey.firstIndex(of: key) else { continue }
            let region = RPGMediaRegion(groupID: bindingID, row: row, column: block.x - minX, rows: rows, columns: columns, stretch: stretch ? true : nil)
            world.blocks[i].media = SpatialMedia(bindingID: bindingID, face: face, region: rows * columns > 1 ? region : nil)
            world.blocks[i].origin = .user
        }
    }
}

/// The 2D sandbox's placed blocks seen in the 2.5D world: one unit block on
/// the ground per cell (display cells as thin media tiles), so old saves
/// and 2D edits appear in the same world.
enum SpatialLegacy {
    static func blocks(from entities: [WorldEntity]) -> [SpatialBlock] {
        entities.compactMap { entity in
            guard let surface = entity.surface else { return nil }
            let display = entity.definitionID == RPGWorldEditing.displayDefinition
            let media = entity.mediaBindingID.map { SpatialMedia(bindingID: $0, face: .top, region: entity.mediaRegion) }
            let tint: String? = entity.definitionID == "wood" ? "C68B59" : entity.definitionID == "stone" ? "9AA3AD" : nil
            return SpatialBlock(id: "legacy:" + entity.id, x: surface.x, y: surface.z, elevation: 0, thickness: display ? 0.08 : 1,
                                glass: tint.map { SpatialGlass.tinted($0, density: 0.5) } ?? .clear,
                                collision: display ? .decor : (entity.physics.topDownSolid ? .solid : .decor), media: media)
        }
    }
}
