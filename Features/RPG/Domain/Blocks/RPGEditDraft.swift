import Foundation

/// What a draft writes into every cell it covers (task E).
enum RPGDraftPayload: Equatable, Sendable {
    /// Place a block of this definition on empty cells.
    case block(String)
    /// Give every covered cell this content; empty cells get a display cell.
    case content(MediaBinding)
    /// Paint terrain.
    case terrain(RPGTerrain)
    /// Remove blocks and their content.
    case erase
    /// Paste a copied area with its first cell at the draft's first cell.
    case paste(RPGClipboard)
    /// Swap blocks of one material for another, keeping their content (同类型替换).
    case replace(from: String, to: String)

    var title: String {
        switch self {
        case .block(let id): "放置" + (BlockDefinition.find(id)?.title ?? id)
        case .content(let binding): "内容 · " + binding.kind.title
        case .terrain(let terrain): "地形 · " + terrain.title
        case .erase: "擦除"
        case .paste: "粘贴"
        case .replace(let from, let to): "替换 " + (BlockDefinition.find(from)?.title ?? from) + " → " + (BlockDefinition.find(to)?.title ?? to)
        }
    }
}

extension RPGTerrain {
    var title: String {
        switch self { case .grass: "草地"; case .sand: "沙地"; case .water: "水面"; case .cliff: "崖壁"; case .road: "道路" }
    }
}

/// An unconfirmed edit: the cells a brush, fill or paste would touch. It
/// never changes the world; `RPGDraftCommit` turns it into one transaction.
struct RPGEditDraft: Equatable, Sendable {
    var payload: RPGDraftPayload
    private(set) var cells: [SurfacePoint] = []
    private var seen: Set<SurfacePoint> = []
    /// The draft stopped growing at the batch limit.
    private(set) var truncated = false

    init(payload: RPGDraftPayload) { self.payload = payload }

    var count: Int { cells.count }
    var isEmpty: Bool { cells.isEmpty }

    /// Adds cells once each, in order, up to the batch limit.
    mutating func add(_ points: [SurfacePoint]) {
        for point in points where point.valid && !seen.contains(point) {
            guard cells.count < RPGWorldEditing.maximumBatch else { truncated = true; return }
            seen.insert(point); cells.append(point)
        }
    }
    /// Adds a stroke segment, filling the cells between fast-moving samples.
    mutating func addStroke(from a: SurfacePoint, to b: SurfacePoint) { add(RPGWorldEditing.line(a, b)) }
    /// Replaces the cells with a rectangle (fill, box tools), clipped to the map.
    mutating func setRectangle(_ a: SurfacePoint, _ b: SurfacePoint) {
        cells = []; seen = []; truncated = false
        add(RPGEditDraft.rectangle(a, b))
    }
    static func rectangle(_ a: SurfacePoint, _ b: SurfacePoint) -> [SurfacePoint] {
        let minX = max(0, min(a.x, b.x)), maxX = min(WorldGeometry.width - 1, max(a.x, b.x))
        let minZ = max(0, min(a.z, b.z)), maxZ = min(WorldGeometry.width - 1, max(a.z, b.z))
        guard minX <= maxX, minZ <= maxZ else { return [] }
        return (minZ...maxZ).flatMap { z in (minX...maxX).map { SurfacePoint(x: $0, z: z) } }
    }
    /// The cells a clipboard would cover with its corner at `origin`.
    static func footprint(_ clipboard: RPGClipboard, at origin: SurfacePoint) -> [SurfacePoint] {
        clipboard.cells.map { SurfacePoint(x: origin.x + $0.dx, z: origin.z + $0.dz) }
    }
}

enum RPGDraftSkip: String, CaseIterable, Sendable {
    case protected, blocked, occupied, empty, player, unchanged
    var title: String {
        switch self {
        case .protected: "保护区"
        case .blocked: "地形不可建造"
        case .occupied: "已有方块"
        case .empty: "没有方块"
        case .player: "角色所在格"
        case .unchanged: "无变化"
        }
    }
}

/// Which draft cells would change and why the others are skipped, shown
/// before confirming.
struct RPGDraftPlan: Equatable, Sendable {
    var cells: [SurfacePoint] = []
    var skipped: [RPGDraftSkip: Int] = [:]
    /// Cells beyond character-build range (character build refuses these).
    var outOfRange = 0
    var skippedTotal: Int { skipped.values.reduce(0, +) }
    var summary: String {
        var text = "影响 \(cells.count) 格"
        let reasons = RPGDraftSkip.allCases.compactMap { reason in skipped[reason].map { "\(reason.title) \($0)" } }
        if !reasons.isEmpty { text += "，跳过 " + reasons.joined(separator: "、") }
        if outOfRange > 0 { text += "，\(outOfRange) 格超出角色建造范围" }
        return text
    }
}

enum RPGDraftCommit {
    static let characterRange = 4

    static func plan(_ draft: RPGEditDraft, world: WorldState, generator: RPGWorldGenerator) -> RPGDraftPlan {
        var plan = RPGDraftPlan()
        let playerCell = world.player.perspective == .topDown ? world.player.surface : nil
        for point in targetCells(draft) {
            if world.player.mode == .adventure && abs(point.x - world.player.surface.x) + abs(point.z - world.player.surface.z) > characterRange { plan.outOfRange += 1 }
            if let reason = skipReason(point, payload: draft.payload, world: world, generator: generator, playerCell: playerCell) {
                plan.skipped[reason, default: 0] += 1
            } else { plan.cells.append(point) }
        }
        return plan
    }

    /// Commits the draft as one undoable transaction. Character build
    /// (adventure rules) refuses the whole draft when any cell is out of
    /// range; cells that cannot change are skipped, not partially written.
    @discardableResult
    static func commit(_ draft: RPGEditDraft, world: inout WorldState, generator: RPGWorldGenerator) throws -> RPGDraftPlan {
        let plan = plan(draft, world: world, generator: generator)
        if plan.outOfRange > 0 { throw RPGEditError.tooFar }
        guard !plan.cells.isEmpty else { throw RPGEditError.outside }
        guard plan.cells.count <= RPGWorldEditing.maximumBatch else { throw RPGEditError.tooLarge }
        switch draft.payload {
        case .block(let definition):
            try RPGWorldEditing.place(plan.cells.map { RPGPlacement(point: $0, definitionID: definition) }, world: &world, generator: generator)
        case .paste(let clipboard):
            let origin = draft.cells.first ?? plan.cells[0]
            let wanted = Set(plan.cells)
            let placements = clipboard.cells.compactMap { cell -> RPGPlacement? in
                let point = SurfacePoint(x: origin.x + cell.dx, z: origin.z + cell.dz)
                return wanted.contains(point) ? RPGPlacement(point: point, definitionID: cell.definitionID, mediaBindingID: cell.mediaBindingID) : nil
            }
            try RPGWorldEditing.place(placements, world: &world, generator: generator)
        case .content(let template):
            try commitContent(template, cells: plan.cells, world: &world, generator: generator)
        case .terrain(let terrain):
            try commitTerrain(terrain, cells: plan.cells, world: &world, generator: generator)
        case .erase:
            try commitErase(plan.cells, world: &world, generator: generator)
        case .replace(_, let to):
            try commitReplace(to: to, cells: plan.cells, world: &world, generator: generator)
        }
        return plan
    }

    // MARK: Internals

    private static func targetCells(_ draft: RPGEditDraft) -> [SurfacePoint] {
        if case .paste(let clipboard) = draft.payload, let origin = draft.cells.first {
            return RPGEditDraft.footprint(clipboard, at: origin).filter(\.valid)
        }
        return draft.cells
    }

    private static func skipReason(_ point: SurfacePoint, payload: RPGDraftPayload, world: WorldState, generator: RPGWorldGenerator, playerCell: SurfacePoint?) -> RPGDraftSkip? {
        if !world.isCreativeCopy && generator.protected(point) { return .protected }
        let entity = RPGWorldEditing.entity(at: point, world: world, generator: generator)
        let passable = RPGWorldTerrain.passable(point, world: world, generator: generator)
        switch payload {
        case .block, .paste:
            if !passable { return .blocked }
            if entity != nil { return .occupied }
            if point == playerCell { return .player }
            if world.combat.enemies.contains(where: { $0.health > 0 && $0.surface == point }) { return .occupied }
        case .content:
            if entity == nil {
                if !passable { return .blocked }
                if point == playerCell { return .player }
            }
        case .terrain(let terrain):
            if RPGWorldTerrain.tile(at: point, world: world, generator: generator) == terrain { return .unchanged }
            if !terrain.passable {
                if point == playerCell { return .player }
                if entity != nil { return .occupied }
            }
        case .erase:
            if entity == nil { return .empty }
        case .replace(let from, let to):
            guard let entity else { return .empty }
            if entity.definitionID != from || from == to { return .unchanged }
            if point == playerCell && BlockDefinition.find(to)?.solid == true { return .player }
        }
        return nil
    }

    /// One shared binding for the whole stroke keeps the binding count low;
    /// editing one cell later gives that cell its own binding.
    private static func commitContent(_ template: MediaBinding, cells: [SurfacePoint], world: inout WorldState, generator: RPGWorldGenerator) throws {
        var binding = template; binding.id = UUID().uuidString
        guard binding.valid else { throw RPGWorldError.invalidState }
        var next = world
        if next.mediaBindings.count >= 960 { try RPGMediaBindings.pruneUnreferenced(&next) }
        guard next.mediaBindings.count < 1024 else { throw RPGWorldError.invalidState }
        next.mediaBindings.append(binding)
        guard let display = BlockDefinition.find(RPGWorldEditing.displayDefinition) else { throw RPGEditError.unknownDefinition }
        var changes: [RPGEntityChange] = []
        for (index, point) in cells.enumerated() {
            if let existing = RPGWorldEditing.entity(at: point, world: world, generator: generator) {
                let before = world.entities.first { $0.id == existing.id }
                var after = existing; after.mediaBindingID = binding.id
                next.entities.removeAll { $0.id == existing.id }; next.entities.append(after)
                changes.append(.init(id: existing.id, before: before, after: after, removedBefore: false, removedAfter: false,
                                     damageBefore: world.damage[existing.id], damageAfter: world.damage[existing.id]))
            } else {
                let entity = RPGWorldEditing.newEntity(at: point, definition: display, index: index, world: world, generator: generator, mediaBindingID: binding.id)
                next.entities.append(entity)
                changes.append(.init(id: entity.id, before: nil, after: entity, removedBefore: false, removedAfter: false, damageBefore: nil, damageAfter: nil))
            }
        }
        try RPGWorldEditing.finish(next: &next, changes: changes, inventoryBefore: world.inventory, title: "内容 \(cells.count) 格")
        world = next
    }

    private static func commitTerrain(_ terrain: RPGTerrain, cells: [SurfacePoint], world: inout WorldState, generator: RPGWorldGenerator) throws {
        var next = world, overrides = world.terrainOverrides ?? [:], changes: [RPGTerrainChange] = []
        for point in cells {
            let key = RPGWorldTerrain.key(point), before = overrides[key]
            // Painting the generated terrain back clears the override.
            let after: RPGTerrain? = generator.tile(at: point) == terrain ? nil : terrain
            guard before != after else { continue }
            overrides[key] = after
            changes.append(.init(point: point, before: before, after: after))
        }
        guard !changes.isEmpty else { throw RPGEditError.outside }
        next.terrainOverrides = overrides.isEmpty ? nil : overrides
        try RPGWorldEditing.finish(next: &next, changes: [], inventoryBefore: world.inventory, title: "地形 \(changes.count) 格", terrainChanges: changes)
        world = next
    }

    /// Editor erase removes blocks with their content. Unlike mining it
    /// gives no drops and records no story events.
    private static func commitErase(_ cells: [SurfacePoint], world: inout WorldState, generator: RPGWorldGenerator) throws {
        var next = world, changes: [RPGEntityChange] = []
        for point in cells {
            guard let target = RPGWorldEditing.entity(at: point, world: world, generator: generator) else { continue }
            let before = world.entities.first { $0.id == target.id }
            next.entities.removeAll { $0.id == target.id }
            let generated = target.id.hasPrefix("g1:")
            if generated && !next.removedGeneratedIDs.contains(target.id) { next.removedGeneratedIDs.append(target.id) }
            changes.append(.init(id: target.id, before: before, after: nil, removedBefore: world.removedGeneratedIDs.contains(target.id),
                                 removedAfter: generated, damageBefore: world.damage[target.id], damageAfter: nil))
            next.damage[target.id] = nil
        }
        next.removedGeneratedIDs.sort()
        try RPGWorldEditing.finish(next: &next, changes: changes, inventoryBefore: world.inventory, title: "擦除 \(changes.count) 格")
        world = next
    }
}

extension RPGDraftCommit {
    /// Old block out, new block in at the same cell with the same content,
    /// all in one transaction. No drops or costs: this is an editor action.
    fileprivate static func commitReplace(to definitionID: String, cells: [SurfacePoint], world: inout WorldState, generator: RPGWorldGenerator) throws {
        guard let definition = BlockDefinition.find(definitionID) else { throw RPGEditError.unknownDefinition }
        // Two changes per cell (old out, new in) must fit one transaction.
        guard cells.count * 2 <= RPGWorldEditing.maximumBatch else { throw RPGEditError.tooLarge }
        var next = world, changes: [RPGEntityChange] = []
        for (index, point) in cells.enumerated() {
            guard let old = RPGWorldEditing.entity(at: point, world: world, generator: generator) else { continue }
            let before = world.entities.first { $0.id == old.id }
            next.entities.removeAll { $0.id == old.id }
            let generated = old.id.hasPrefix("g1:")
            if generated && !next.removedGeneratedIDs.contains(old.id) { next.removedGeneratedIDs.append(old.id) }
            changes.append(.init(id: old.id, before: before, after: nil, removedBefore: world.removedGeneratedIDs.contains(old.id),
                                 removedAfter: generated, damageBefore: world.damage[old.id], damageAfter: nil))
            next.damage[old.id] = nil
            let replacement = RPGWorldEditing.newEntity(at: point, definition: definition, index: index, world: world, generator: generator, mediaBindingID: old.mediaBindingID)
            next.entities.append(replacement)
            changes.append(.init(id: replacement.id, before: nil, after: replacement, removedBefore: false, removedAfter: false, damageBefore: nil, damageAfter: nil))
        }
        next.removedGeneratedIDs.sort()
        try RPGWorldEditing.finish(next: &next, changes: changes, inventoryBefore: world.inventory, title: "替换 \(changes.count / 2) 格")
        world = next
    }
}
