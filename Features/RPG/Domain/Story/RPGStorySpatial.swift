import Foundation

/// The story in the 3D world. The 3D world and the story share one
/// 256 × 256 surface grid (blocks built on the old map already stand at
/// the same cells in 3D), so story places keep their coordinates; what the
/// story reads (where the player is, which enemies fell, which blocks
/// broke) now comes from the 3D world.
enum RPGStorySpatial {
    /// 3D creatures standing in for story enemies carry this id prefix.
    static let creaturePrefix = "rpg-enemy:"

    /// What the current quest points at, for the 3D marker and hint.
    struct Objective: Equatable, Sendable {
        var title: String
        var point: SurfacePoint
        /// The marker radius in cells: arriving inside it meets the condition.
        var radius: Int
    }

    // MARK: Player

    /// The 3D player's cell becomes the story's player position. Returns
    /// whether it changed. The revision is left alone: a position is not an
    /// edit, and bumping it would make in-flight story edits look stale.
    static func syncPlayer(_ position: SpatialVector, world: inout WorldState) -> Bool {
        guard position.x.isFinite, position.y.isFinite else { return false }
        let cell = SurfacePoint(x: min(255, max(0, Int(position.x.rounded(.down)))), z: min(255, max(0, Int(position.y.rounded(.down)))))
        guard cell != world.player.surface || world.player.perspective != .topDown else { return false }
        world.player.surface = cell
        world.player.perspective = .topDown
        return true
    }

    // MARK: Opening a save

    /// Story enemies carry ids from `RPGStoryRuntime.enemyID`.
    static func isStoryEnemy(_ id: String) -> Bool { id.hasPrefix("story:") }

    /// A save from the old 2D sandbox: the wandering enemies its map spawned
    /// never appear in 3D, so they are dropped, and the combat flag only
    /// counts story enemies still standing (a stale flag would block every
    /// story from starting). Story enemies, the defeated list and everything
    /// else stay as saved.
    static func normalize(_ world: inout WorldState) {
        world.combat.enemies.removeAll { !isStoryEnemy($0.id) }
        world.player.inCombat = world.player.health > 0 && world.combat.enemies.contains { $0.health > 0 && $0.aggro && $0.surface != nil && $0.scope != .sideOnly }
        if world.player.perspective != .topDown { world.player.perspective = .topDown }
    }

    // MARK: Enemies

    /// Story enemies the 3D world should show: alive, on the surface, not
    /// already defeated.
    static func storyCreatures(for world: WorldState) -> [CreatureEntity] {
        world.combat.enemies.compactMap { enemy in
            guard isStoryEnemy(enemy.id), enemy.health > 0, let s = enemy.surface, enemy.scope != .sideOnly, !world.combat.defeatedIDs.contains(enemy.id) else { return nil }
            let at = SpatialVector(Double(s.x) + 0.5, Double(s.z) + 0.5, 0)
            return CreatureEntity(id: creaturePrefix + enemy.id, kind: enemy.boss ? .miniBoss : .enemy, position: at, home: at,
                                  health: enemy.health, maxHealth: enemy.maximumHealth, damage: enemy.boss ? 10 : 7, origin: .generated)
        }
    }

    /// Brings the 3D creatures in line with the story: adds story enemies
    /// that are missing, removes ones the story no longer has. Other
    /// creatures are untouched. Returns whether anything changed.
    /// Outside the story's region (`inStoryRegion` false) no story enemy
    /// stands in 3D: the story's places are on the central region's grid.
    static func reconcile(_ creatures: inout [CreatureEntity], with world: WorldState, inStoryRegion: Bool = true) -> Bool {
        let wanted = inStoryRegion ? storyCreatures(for: world) : []
        let wantedIDs = Set(wanted.map(\.id))
        let before = creatures.count
        creatures.removeAll { $0.id.hasPrefix(creaturePrefix) && !wantedIDs.contains($0.id) && $0.alive }
        var changed = creatures.count != before
        let present = Set(creatures.map(\.id))
        for creature in wanted where !present.contains(creature.id) { creatures.append(creature); changed = true }
        return changed
    }

    /// A 3D creature died. A story enemy is recorded the way a defeat on the
    /// old map was (defeated list, event, combat flag); moon shards are not
    /// added here because the 3D world already paid them out.
    static func defeated(_ creatureID: String, world: inout WorldState) -> Bool {
        guard creatureID.hasPrefix(creaturePrefix) else { return false }
        let id = String(creatureID.dropFirst(creaturePrefix.count))
        guard let index = world.combat.enemies.firstIndex(where: { $0.id == id }), !world.combat.defeatedIDs.contains(id) else { return false }
        let enemy = world.combat.enemies[index]
        world.combat.enemies[index].health = 0
        world.combat.defeatedIDs.append(id); world.combat.defeatedIDs.sort()
        RPGCombatRules.event(enemy.boss ? "bossDefeated" : "enemyDefeated", enemy: enemy, world: &world)
        RPGCombatRules.updateCombatFlag(&world)
        world.revision += 1
        return true
    }

    // MARK: Blocks

    /// Blocks broken in 3D count like blocks broken on the old map.
    static func blocksDestroyed(_ ids: [String], world: inout WorldState) {
        guard !ids.isEmpty else { return }
        for id in ids.prefix(64) {
            world.events.append(.init(id: "event3d:\(world.revision + 1):\(id)", kind: "blockDestroyed", entityID: id, definitionID: "glass"))
        }
        world.events = Array(world.events.suffix(256))
        world.revision += 1
    }

    // MARK: Objective

    /// The current node's place or enemy, if it has one.
    static func objective(world: WorldState, generator: RPGWorldGenerator) -> Objective? {
        let graph = world.story.activeGraph
        let progress = world.story.activeProgress
        if progress?.ended == true { return nil }
        guard let node = graph.nodes.first(where: { $0.id == (progress?.current ?? graph.start) }), let condition = node.condition else { return nil }
        switch condition.kind {
        case .nearAnchor:
            return Objective(title: condition.anchor.title, point: generator.anchor(condition.anchor), radius: 4)
        case .enemyDefeated:
            let id = RPGStoryRuntime.enemyID(graphID: graph.id, key: condition.key)
            guard let enemy = world.combat.enemies.first(where: { $0.id == id && $0.health > 0 }), let s = enemy.surface else { return nil }
            return Objective(title: L10n.t("击败目标", "Defeat the target"), point: s, radius: 1)
        default:
            return nil
        }
    }

    /// Whether the current node's condition holds now (the 3D world then
    /// offers the story panel).
    static func conditionMet(world: WorldState, generator: RPGWorldGenerator) -> Bool {
        let graph = world.story.activeGraph
        guard let progress = world.story.activeProgress, !progress.ended,
              let node = graph.nodes.first(where: { $0.id == progress.current }), let condition = node.condition else { return false }
        return RPGStoryRuntime.condition(condition, world: world, progress: progress, graph: graph, generator: generator)
    }
}
