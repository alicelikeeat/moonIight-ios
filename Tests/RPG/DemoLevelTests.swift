import Foundation

/// The minimal playable level around 月光水晶城: a battle field and a
/// walled Boss arena that can both be walked to from the spawn.
func demoLevelTests() {
    var world = GoldenCity.stampedBlank()
    world.blocks.append(SpatialBlock(id: "player-tower", x: 20, y: 20, elevation: 0, thickness: 3, origin: .user))
    let townBlocks = world.blocks.count
    let report = DemoLevel.stamp(onto: &world)
    check(report.problems.isEmpty && report.reachable, "demo: the field and the arena are reachable on foot from the spawn (\(report.problems))")
    check(report.enemies == DemoLevel.enemyCount && world.creatures.filter { $0.id.hasPrefix("demo:enemy") }.allSatisfy { $0.kind == .enemy && $0.alive },
          "demo: six ordinary enemies stand on the battle field")
    let boss = world.creatures.first { $0.id == report.bossID }
    check(boss?.kind == .boss && boss?.bossScriptID == DemoLevel.bossScriptID && world.bossScripts?.first { $0.id == DemoLevel.bossScriptID }?.phases.count == 3,
          "demo: the Boss has its three-phase script")
    check(boss.map { SpatialBattle.script(for: $0, in: world)?.valid == true } == true, "demo: the Boss's script is valid and is the one it plays")
    check(report.arenaBlocks > 30 && world.pickups.contains { $0.id == "demo:chest" && $0.shards == 25 }, "demo: a walled arena with a reward chest")
    if let arena = report.arena, let field = report.field {
        check((boss!.position - arena).flatLength < 0.01 && (field - arena).flatLength > 20, "demo: the Boss stands in its arena, away from the field")
        let walls = world.blocks.filter { $0.id.hasPrefix("demo:wall") }
        check(walls.allSatisfy { abs((SpatialVector(Double($0.x) + 0.5, Double($0.y) + 0.5, 0) - arena).flatLength - Double(DemoLevel.arenaRadius)) < 1 },
              "demo: the wall is a ring around the arena")
    }
    check(world.blocks.count == townBlocks + report.arenaBlocks && world.blocks.contains { $0.id == "player-tower" && $0.origin == .user },
          "demo: the town and the player's own build are untouched")
    var again = world
    let second = DemoLevel.stamp(onto: &again)
    check(second == report && again.blocks.count == world.blocks.count && again.creatures.count == world.creatures.count && again.pickups.count == world.pickups.count,
          "demo: placing it again replaces it, it does not pile up")
    var crowded = SpatialWorld.blank()
    for y in 0..<WorldGeometry.width { for x in 0..<WorldGeometry.width where (x + y) % 3 == 0 { crowded.blocks.append(SpatialBlock(id: "c\(x):\(y)", x: x, y: y, elevation: 0, thickness: 2)) } }
    let refused = DemoLevel.stamp(onto: &crowded)
    check(!refused.problems.isEmpty && !refused.reachable && !crowded.creatures.contains { $0.id.hasPrefix("demo:") }, "demo: with no open ground nothing is placed and the reason is given")
    print("RPG demo level: town, battle field (\(report.enemies)), Boss arena (\(report.arenaBlocks) wall blocks), reachable \(report.reachable)")
}
