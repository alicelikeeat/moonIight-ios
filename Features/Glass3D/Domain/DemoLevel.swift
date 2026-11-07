import Foundation

/// v1.88 step 9: the smallest playable level — 月光水晶城 as the town, a
/// battle field with ordinary enemies, and a walled Boss arena with a
/// three-phase Boss and a reward chest — all reachable on foot from the
/// spawn. Placed around the world's spawn; everything it adds carries the
/// `demo:` prefix, so placing it again replaces it and never touches what
/// the player built.
enum DemoLevel {
    static let prefix = "demo:"
    static let bossScriptID = "demo.boss"
    static let enemyCount = 6
    static let arenaRadius = 7

    struct Report: Equatable, Sendable {
        var field: SpatialVector?
        var arena: SpatialVector?
        var enemies = 0
        var arenaBlocks = 0
        var bossID: String?
        /// The walk spawn → field and spawn → Boss exists (A*, after the walls stand).
        var reachable = false
        var problems: [String] = []
    }

    /// Where the field and the arena may go, relative to the spawn, in order of preference.
    static let layouts: [(field: (Double, Double), arena: (Double, Double))] = [
        ((36, 0), (-40, 0)), ((-36, 0), (40, 0)), ((0, -22), (36, -10)), ((30, -14), (-34, -14)), ((0, -20), (0, -40)),
    ]

    static func stamp(onto world: inout SpatialWorld) -> Report {
        var report = Report()
        world.blocks.removeAll { $0.id.hasPrefix(prefix) }
        world.creatures.removeAll { $0.id.hasPrefix(prefix) }
        world.pickups.removeAll { $0.id.hasPrefix(prefix) }
        let spawn = world.spawn
        var geometry = SpatialGeometry(blocks: world.blocks, plants: world.plants)
        geometry.groundHoles = Set(world.groundHoles ?? [])
        let navigator = SpatialNavigator(geometry: geometry)
        let walkable = Set(navigator.reachable(from: spawn, climb: SpatialPhysics.stepUp, limit: 120_000).filter { $0.level == 0 }.map { $0.y * WorldGeometry.width + $0.x })
        func open(_ x: Int, _ y: Int) -> Bool {
            (12..<(WorldGeometry.width - 12)).contains(x) && (12..<(WorldGeometry.width - 12)).contains(y) && walkable.contains(y * WorldGeometry.width + x)
        }
        func areaOpen(_ cx: Int, _ cy: Int, radius: Int) -> Bool {
            for dy in -radius...radius { for dx in -radius...radius where dx * dx + dy * dy <= radius * radius { if !open(cx + dx, cy + dy) { return false } } }
            return true
        }
        let base = (x: Int(spawn.x.rounded(.down)), y: Int(spawn.y.rounded(.down)))
        guard let layout = layouts.first(where: { l in
            areaOpen(base.x + Int(l.field.0), base.y + Int(l.field.1), radius: 4) && areaOpen(base.x + Int(l.arena.0), base.y + Int(l.arena.1), radius: arenaRadius + 1)
        }) else {
            report.problems.append(L10n.t("出生点附近没有足够的空地放战斗区和 Boss 场地", "No open ground near the spawn for the battle field and the Boss arena"))
            return report
        }
        let field = (x: base.x + Int(layout.field.0), y: base.y + Int(layout.field.1))
        let arena = (x: base.x + Int(layout.arena.0), y: base.y + Int(layout.arena.1))
        report.field = SpatialVector(Double(field.x) + 0.5, Double(field.y) + 0.5, 0)
        report.arena = SpatialVector(Double(arena.x) + 0.5, Double(arena.y) + 0.5, 0)

        // The arena: a ring wall with a three-cell gate facing the spawn.
        let toSpawn = atan2(spawn.y - Double(arena.y) - 0.5, spawn.x - Double(arena.x) - 0.5)
        for dy in -arenaRadius...arenaRadius { for dx in -arenaRadius...arenaRadius {
            let d = (Double(dx * dx + dy * dy)).squareRoot()
            guard abs(d - Double(arenaRadius)) < 0.5 else { continue }
            var gap = atan2(Double(dy), Double(dx)) - toSpawn
            gap = abs(atan2(sin(gap), cos(gap)))
            if gap * Double(arenaRadius) < 1.6 { continue }
            world.blocks.append(SpatialBlock(id: "\(prefix)wall:\(dx):\(dy)", x: arena.x + dx, y: arena.y + dy, elevation: 0, thickness: 2.2,
                                             glass: SpatialGlass.tinted("8E9AAF", density: 0.85), collision: .solid, origin: .generated))
            report.arenaBlocks += 1
        }}

        // The battle field: ordinary enemies on open cells around its centre.
        let offsets = [(0, 0), (2, 1), (-2, 1), (1, -2), (-1, -2), (3, -1), (-3, -1), (0, 3)]
        for (index, offset) in offsets.enumerated() where report.enemies < enemyCount {
            let x = field.x + offset.0, y = field.y + offset.1
            guard open(x, y) else { continue }
            let at = SpatialVector(Double(x) + 0.5, Double(y) + 0.5, 0)
            world.creatures.append(CreatureEntity(id: "\(prefix)enemy:\(index)", kind: .enemy, position: at, home: at, health: 30, maxHealth: 30, damage: 6, origin: .generated))
            report.enemies += 1
        }

        // The Boss, its script and the reward behind it.
        var script = BossDirector.example(id: bossScriptID)
        script.name = L10n.t("月光守卫者", "Moonlight Warden")
        var scripts = world.bossScripts ?? []
        scripts.removeAll { $0.id == bossScriptID }; scripts.append(script)
        world.bossScripts = scripts
        let bossAt = report.arena!
        var boss = CreatureEntity(id: "\(prefix)boss", kind: .boss, position: bossAt, home: bossAt, health: 300, maxHealth: 300, damage: 14, origin: .generated)
        boss.bossScriptID = bossScriptID
        world.creatures.append(boss)
        report.bossID = boss.id
        let behind = SpatialVector(bossAt.x - cos(toSpawn) * 3, bossAt.y - sin(toSpawn) * 3, 0)
        world.pickups.append(PickupEntity(id: "\(prefix)chest", position: behind, shards: 25, origin: .generated))

        // Walk check with the walls standing.
        var walled = SpatialGeometry(blocks: world.blocks, plants: world.plants)
        walled.groundHoles = geometry.groundHoles
        let walker = SpatialNavigator(geometry: walled)
        let toField = walker.path(from: spawn, to: report.field!, limit: 40_000) != nil
        let toBoss = walker.path(from: spawn, to: bossAt, limit: 40_000) != nil
        report.reachable = toField && toBoss
        if !toField { report.problems.append(L10n.t("走不到战斗区", "The battle field cannot be reached on foot")) }
        if !toBoss { report.problems.append(L10n.t("走不进 Boss 场地", "The Boss arena cannot be entered on foot")) }
        return report
    }
}
