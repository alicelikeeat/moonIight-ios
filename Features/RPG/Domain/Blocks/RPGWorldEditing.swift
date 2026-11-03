import Foundation

struct BlockDefinition: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let durability: Int
    let cost: String?
    let drop: String?
    let solid: Bool
    static let all: [BlockDefinition] = [
        .init(id: "wood", title: "木块", durability: 3, cost: "wood", drop: "wood", solid: true),
        .init(id: "stone", title: "石块", durability: 5, cost: "stone", drop: "stone", solid: true),
        .init(id: "lamp", title: "月灯", durability: 2, cost: "wood", drop: "wood", solid: false),
        .init(id: "door", title: "门", durability: 3, cost: "wood", drop: "wood", solid: true),
        .init(id: "platform", title: "平台", durability: 4, cost: "wood", drop: "wood", solid: true),
        .init(id: "trigger", title: "触发方块", durability: 2, cost: "stone", drop: "stone", solid: false),
        // Task E (A+): a see-through, walk-through cell that only carries
        // content, so content can be painted onto empty ground.
        .init(id: RPGWorldEditing.displayDefinition, title: "展示格", durability: 1, cost: nil, drop: nil, solid: false),
    ]
    static func find(_ id: String) -> Self? { all.first { $0.id == id } }
    /// Name in the current app language.
    var name: String {
        switch id {
        case "wood": L10n.t("木块", "Wood"); case "stone": L10n.t("石块", "Stone"); case "lamp": L10n.t("月灯", "Moon lamp")
        case "door": L10n.t("门", "Door"); case "platform": L10n.t("平台", "Platform"); case "trigger": L10n.t("触发方块", "Trigger block")
        case RPGWorldEditing.displayDefinition: L10n.t("展示格", "Display cell")
        default: title
        }
    }
}
struct RPGEntityChange: Codable, Equatable, Sendable {
    let id: String
    let before: WorldEntity?
    let after: WorldEntity?
    let removedBefore: Bool
    let removedAfter: Bool
    let damageBefore: Int?
    let damageAfter: Int?
}
struct RPGEditTransaction: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let changes: [RPGEntityChange]
    let inventoryBefore: [String: Int]
    let inventoryAfter: [String: Int]
    let title: String
    /// Schema 8: terrain edits in the same transaction (nil before).
    var terrainChanges: [RPGTerrainChange]? = nil
}
struct RPGTerrainChange: Codable, Equatable, Sendable {
    let point: SurfacePoint
    /// Override before/after; nil means the generated terrain.
    let before: RPGTerrain?
    let after: RPGTerrain?
}
/// Terrain as the world sees it: map-editor overrides over the generator.
enum RPGWorldTerrain {
    static func key(_ point: SurfacePoint) -> String { "\(point.x),\(point.z)" }
    static func point(_ key: String) -> SurfacePoint? {
        let parts = key.split(separator: ",")
        guard parts.count == 2, let x = Int(parts[0]), let z = Int(parts[1]) else { return nil }
        let point = SurfacePoint(x: x, z: z)
        return point.valid ? point : nil
    }
    static func tile(at point: SurfacePoint, world: WorldState, generator: RPGWorldGenerator) -> RPGTerrain? {
        guard point.valid else { return nil }
        return world.terrainOverrides?[key(point)] ?? generator.tile(at: point)
    }
    static func passable(_ point: SurfacePoint, world: WorldState, generator: RPGWorldGenerator) -> Bool {
        tile(at: point, world: world, generator: generator)?.passable == true
    }
    /// For closures that run while the world is being mutated.
    static func passable(_ point: SurfacePoint, overrides: [String: RPGTerrain], generator: RPGWorldGenerator) -> Bool {
        guard point.valid else { return false }
        return (overrides[key(point)] ?? generator.tile(at: point))?.passable == true
    }
}
struct RPGWorldEvent: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: String
    let entityID: String
    let definitionID: String
}
struct RPGClipboard: Equatable, Sendable {
    struct Cell: Equatable, Sendable { let dx: Int; let dz: Int; let definitionID: String; let mediaBindingID: String? }
    let width: Int
    let height: Int
    let cells: [Cell]
}
enum RPGEditError: Error, LocalizedError, Equatable {
    case outside, occupied, protectedArea, resources, tooFar, unknownDefinition, tooLarge, stale, nothingToUndo, nothingToRedo
    var errorDescription: String? {
        switch self {
        case .outside: L10n.t("位置越界或地形无法建造。", "Out of bounds, or the terrain cannot be built on.")
        case .occupied: L10n.t("位置已被占用，或会挡住玩家。", "The cell is occupied or would block the player.")
        case .protectedArea: L10n.t("官方剧情保护区不可修改；可创建独立创作副本。", "Protected story area; make a creative copy to change it.")
        case .resources: L10n.t("资源不足。", "Not enough resources.")
        case .tooFar: L10n.t("角色建造只能修改角色身边 4 格内的格子；请切换到自由编辑或重新选择。", "Character build only edits cells within 4 of the player; switch to Free Edit or reselect.")
        case .unknownDefinition: L10n.t("未知方块定义。", "Unknown block.")
        case .tooLarge: L10n.t("一次最多操作 1024 格。", "At most 1024 cells at once.")
        case .stale: L10n.t("相关世界状态已变化，本次操作未提交。", "The world changed; this edit was not applied.")
        case .nothingToUndo: L10n.t("没有可撤销的操作。", "Nothing to undo.")
        case .nothingToRedo: L10n.t("没有可重做的操作。", "Nothing to redo.")
        }
    }
}
struct RPGPlacement: Sendable {
    let point: SurfacePoint
    let definitionID: String
    var mediaBindingID: String? = nil
}
enum RPGWorldEditing {
    static let maximumBatch = 1024
    /// Undo depth target (task E: 50), further limited by `undoChangeBudget`.
    static let undoLimit = 50
    /// Total entity + terrain changes kept across undo history, so large
    /// fills cannot grow the save without bound.
    static let undoChangeBudget = 8192
    static let displayDefinition = "display"
    static func entities(in chunk: RPGChunk, world: WorldState) -> [WorldEntity] {
        let overrides = Set(world.entities.map(\.id)), removed = Set(world.removedGeneratedIDs)
        return chunk.entities.filter { !overrides.contains($0.id) && !removed.contains($0.id) } + world.entities.filter { $0.surface?.chunk == chunk.coordinate }
    }
    static func entity(at point: SurfacePoint, world: WorldState, generator: RPGWorldGenerator) -> WorldEntity? {
        guard point.valid else{return nil}
        if let base=generator.baseEntity(at:point),!world.removedGeneratedIDs.contains(base.id),!world.entities.contains(where:{$0.id==base.id}) {return base}
        return world.entities.first{$0.surface==point}
    }
    static func rectangle(_ a: SurfacePoint, _ b: SurfacePoint) throws -> [SurfacePoint] {
        guard a.valid, b.valid else { throw RPGEditError.outside }
        let width = abs(a.x - b.x) + 1, height = abs(a.z - b.z) + 1
        guard width * height <= maximumBatch else { throw RPGEditError.tooLarge }
        return (min(a.z,b.z)...max(a.z,b.z)).flatMap { z in (min(a.x,b.x)...max(a.x,b.x)).map { SurfacePoint(x: $0, z: z) } }
    }
    static func line(_ a: SurfacePoint, _ b: SurfacePoint) -> [SurfacePoint] {
        guard a.valid, b.valid else { return [] }
        var x = a.x, z = a.z, result: [SurfacePoint] = []
        let dx = abs(b.x - x), dz = -abs(b.z - z), sx = x < b.x ? 1 : -1, sz = z < b.z ? 1 : -1
        var error = dx + dz
        while result.count < maximumBatch {
            result.append(.init(x: x, z: z)); if x == b.x && z == b.z { break }
            let doubled = 2 * error
            if doubled >= dz { error += dz; x += sx }
            if doubled <= dx { error += dx; z += sz }
        }
        return result
    }
    private static func check(_ point: SurfacePoint, world: WorldState, generator: RPGWorldGenerator) throws {
        guard point.valid else { throw RPGEditError.outside }
        if !world.isCreativeCopy && generator.protected(point) { throw RPGEditError.protectedArea }
        if world.player.mode == .adventure && abs(point.x - world.player.surface.x) + abs(point.z - world.player.surface.z) > 4 { throw RPGEditError.tooFar }
    }
    static func place(_ placements: [RPGPlacement], world: inout WorldState, generator: RPGWorldGenerator) throws {
        guard !placements.isEmpty, placements.count <= maximumBatch else { throw RPGEditError.tooLarge }
        guard Set(placements.map(\.point)).count == placements.count else { throw RPGEditError.occupied }
        var next = world, changes: [RPGEntityChange] = []
        let inventory = world.inventory
        for (index, request) in placements.enumerated() {
            try check(request.point, world: world, generator: generator)
            guard let definition = BlockDefinition.find(request.definitionID) else { throw RPGEditError.unknownDefinition }
            guard RPGWorldTerrain.passable(request.point, world: next, generator: generator) else { throw RPGEditError.outside }
            let sidePoint = SidePlacement(regionID: generator.sideRegion.id, horizontal: request.point.x - generator.sideRegion.origin.x, height: 2)
            let playerCollision = world.player.perspective == .topDown ? request.point == world.player.surface : world.player.side == sidePoint
            guard !world.combat.enemies.contains(where: { $0.health > 0 && (world.player.perspective == .topDown ? $0.surface == request.point : $0.side == sidePoint) }), !playerCollision, entity(at: request.point, world: next, generator: generator) == nil else { throw RPGEditError.occupied }
            if let binding = request.mediaBindingID, !world.mediaBindings.contains(where: { $0.id == binding }) { throw RPGWorldError.missingReference }
            if world.player.mode == .adventure, let cost = definition.cost {
                guard next.inventory[cost, default: 0] > 0 else { throw RPGEditError.resources }
                next.inventory[cost, default: 0] -= 1
            }
            let entity = newEntity(at: request.point, definition: definition, index: index, world: world, generator: generator, mediaBindingID: request.mediaBindingID)
            next.entities.append(entity)
            changes.append(.init(id: entity.id, before: nil, after: entity, removedBefore: false, removedAfter: false, damageBefore: nil, damageAfter: nil))
        }
        try finish(next: &next, changes: changes, inventoryBefore: inventory, title: "放置 \(placements.count) 格")
        world = next
    }
    /// A newly placed block, shared with the side slice when it sits on the
    /// mapped row so both projections show the same identity and content.
    static func newEntity(at point: SurfacePoint, definition: BlockDefinition, index: Int, world: WorldState, generator: RPGWorldGenerator, mediaBindingID: String?) -> WorldEntity {
        let id = "placed:\(world.id):\(world.revision + 1):\(index)"
        let shared = generator.sideRegion.contains(point)
        return WorldEntity(id: id, definitionID: definition.id, scope: shared ? .shared : .topDownOnly, surface: point,
            side: shared ? .init(regionID: generator.sideRegion.id, horizontal: point.x - generator.sideRegion.origin.x, height: 2) : nil,
            physics: .init(topDownSolid: definition.solid, sideSolid: definition.solid, sideGravity: false, pushable: false, hitPoints: definition.durability, width: 1, height: 1), mediaBindingID: mediaBindingID)
    }
    static func hit(_ point: SurfacePoint, world: inout WorldState, generator: RPGWorldGenerator, force: Bool = false) throws {
        try check(point, world: world, generator: generator)
        guard let target = entity(at: point, world: world, generator: generator), let definition = BlockDefinition.find(target.definitionID) else { throw RPGEditError.unknownDefinition }
        var next = world
        let before = world.entities.first { $0.id == target.id }, removed = world.removedGeneratedIDs.contains(target.id), damage = world.damage[target.id]
        let destroyed = force && world.player.mode == .creative || (damage ?? 0) + 1 >= target.physics.hitPoints
        if destroyed {
            next.entities.removeAll { $0.id == target.id }; next.damage[target.id] = nil
            if target.id.hasPrefix("g1:") { next.removedGeneratedIDs.append(target.id); next.removedGeneratedIDs.sort() }
            if let drop = definition.drop { next.inventory[drop, default: 0] += 1 }
            next.events.append(.init(id: "event:\(next.revision + 1):\(target.id)", kind: "blockDestroyed", entityID: target.id, definitionID: target.definitionID))
            next.events = Array(next.events.suffix(256))
        } else { next.damage[target.id] = (damage ?? 0) + 1 }
        let change = RPGEntityChange(id: target.id, before: before, after: next.entities.first { $0.id == target.id }, removedBefore: removed,
            removedAfter: next.removedGeneratedIDs.contains(target.id), damageBefore: damage, damageAfter: next.damage[target.id])
        try finish(next: &next, changes: [change], inventoryBefore: world.inventory, title: destroyed ? "破坏与掉落" : "方块受击")
        world = next
    }
    static func finish(next: inout WorldState, changes: [RPGEntityChange], inventoryBefore: [String: Int], title: String, terrainChanges: [RPGTerrainChange] = []) throws {
        let transaction = RPGEditTransaction(id: UUID().uuidString, changes: changes, inventoryBefore: inventoryBefore, inventoryAfter: next.inventory, title: title,
                                             terrainChanges: terrainChanges.isEmpty ? nil : terrainChanges)
        next.undo.append(transaction); next.undo = trimmedHistory(next.undo); next.redo = []
        next.revision += 1
        try next.validate()
    }
    /// Keeps the newest transactions within the depth and change budgets;
    /// the latest one is always kept.
    static func trimmedHistory(_ history: [RPGEditTransaction]) -> [RPGEditTransaction] {
        var kept: [RPGEditTransaction] = [], total = 0
        for transaction in history.reversed() {
            let size = transaction.changes.count + (transaction.terrainChanges ?? []).count
            if !kept.isEmpty && (kept.count >= undoLimit || total + size > undoChangeBudget) { break }
            kept.append(transaction); total += size
        }
        return kept.reversed()
    }
    static func undo(world: inout WorldState) throws {
        guard let transaction = world.undo.last else { throw RPGEditError.nothingToUndo }
        try replay(transaction, inverse: true, world: &world)
    }
    static func redo(world: inout WorldState) throws {
        guard let transaction = world.redo.last else { throw RPGEditError.nothingToRedo }
        try replay(transaction, inverse: false, world: &world)
    }
    private static func replay(_ transaction: RPGEditTransaction, inverse: Bool, world: inout WorldState) throws {
        guard world.inventory == (inverse ? transaction.inventoryAfter : transaction.inventoryBefore) else { throw RPGEditError.stale }
        var next = world
        for change in transaction.changes {
            let expected = inverse ? change.after : change.before
            guard world.entities.first(where: { $0.id == change.id }) == expected,
                  world.removedGeneratedIDs.contains(change.id) == (inverse ? change.removedAfter : change.removedBefore),
                  world.damage[change.id] == (inverse ? change.damageAfter : change.damageBefore) else { throw RPGEditError.stale }
            let restoredGenerated = !(inverse ? change.removedBefore : change.removedAfter) && world.removedGeneratedIDs.contains(change.id)
            if restoredGenerated {
                let parts = change.id.split(separator: ":")
                if world.player.perspective == .topDown, parts.count == 4, let x = Int(parts[2]), let z = Int(parts[3]), SurfacePoint(x: x, z: z) == world.player.surface { throw RPGEditError.occupied }
            }
            if restoredGenerated, let player = world.player.side, world.player.perspective == .side,
               let generated = RPGProjectionRules.sideBaseEntities(world: world, generator: RPGWorldGenerator(seed: world.seed)).first(where: { $0.id == change.id }),
               generated.physics.sideSolid && RPGProjectionRules.occupies(generated, player) { throw RPGEditError.occupied }
            let value = inverse ? change.before : change.after
            if world.player.perspective == .topDown, let value, value.surface == world.player.surface && value.physics.topDownSolid { throw RPGEditError.occupied }
            if let value, let player = world.player.side, world.player.perspective == .side, value.physics.sideSolid && RPGProjectionRules.occupies(value,player) { throw RPGEditError.occupied }
            next.entities.removeAll { $0.id == change.id }; if let value { next.entities.append(value) }
            next.removedGeneratedIDs.removeAll { $0 == change.id }
            if inverse ? change.removedBefore : change.removedAfter { next.removedGeneratedIDs.append(change.id) }
            next.damage[change.id] = inverse ? change.damageBefore : change.damageAfter
        }
        for change in transaction.terrainChanges ?? [] {
            let key = RPGWorldTerrain.key(change.point)
            guard world.terrainOverrides?[key] == (inverse ? change.after : change.before) else { throw RPGEditError.stale }
            var overrides = next.terrainOverrides ?? [:]
            overrides[key] = inverse ? change.before : change.after
            next.terrainOverrides = overrides.isEmpty ? nil : overrides
        }
        next.removedGeneratedIDs.sort(); next.inventory = inverse ? transaction.inventoryBefore : transaction.inventoryAfter
        if inverse { next.undo.removeLast(); next.redo.append(transaction) } else { next.redo.removeLast(); next.undo.append(transaction) }
        // Edit notifications are rebuilt from committed state; do not replay old
        // story rewards when undoing or redoing a destroyed block.
        next.events = []; next.revision += 1
        try next.validate(); world = next
    }
    static func copy(from a: SurfacePoint, to b: SurfacePoint, world: WorldState, generator: RPGWorldGenerator) throws -> RPGClipboard {
        let points = try rectangle(a,b)
        let x = min(a.x,b.x), z = min(a.z,b.z)
        let cells = points.compactMap { point -> RPGClipboard.Cell? in
            guard let entity = entity(at: point, world: world, generator: generator) else { return nil }
            return .init(dx: point.x - x, dz: point.z - z, definitionID: entity.definitionID, mediaBindingID: entity.mediaBindingID)
        }
        return .init(width: abs(a.x-b.x)+1, height: abs(a.z-b.z)+1, cells: cells)
    }
    static func paste(_ clipboard: RPGClipboard, at origin: SurfacePoint, world: inout WorldState, generator: RPGWorldGenerator) throws {
        let requests = clipboard.cells.map { RPGPlacement(point: .init(x: origin.x + $0.dx, z: origin.z + $0.dz), definitionID: $0.definitionID, mediaBindingID: $0.mediaBindingID) }
        try place(requests, world: &world, generator: generator)
    }
}
