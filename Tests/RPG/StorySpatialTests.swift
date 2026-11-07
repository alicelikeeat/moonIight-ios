import Foundation

/// The official story played entirely from 3D-world events: blocks broken
/// in 3D, walking there in 3D, and the village guard fought as a 3D creature.
func storySpatialTests() throws {
    let generator = RPGWorldGenerator(seed: 42)
    var tale = WorldState(seed: 42); tale.player.surface = generator.anchor(.spawn); tale.sideRegions = [generator.sideRegion]
    try RPGStoryRuntime.start(graphID: RPGOfficialStory.graph.id, world: &tale)
    try RPGStoryRuntime.advance(world: &tale, generator: generator)
    try RPGStoryRuntime.advance(world: &tale, generator: generator)
    try RPGStoryRuntime.advance(choiceID: "help", world: &tale, generator: generator)
    check(tale.story.activeProgress?.current == "gather", "3D story: reaches the first-material quest")
    check(RPGStorySpatial.objective(world: tale, generator: generator) == nil, "3D story: an event quest has no place marker")
    check(!RPGStorySpatial.conditionMet(world: tale, generator: generator), "3D story: the quest waits before anything breaks")

    // A block broken in 3D completes the material quest.
    RPGStorySpatial.blocksDestroyed(["glass-block-1"], world: &tale)
    RPGStoryRuntime.recordEvents(world: &tale)
    check(RPGStorySpatial.conditionMet(world: tale, generator: generator), "3D story: a block broken in 3D meets the material quest")
    let wood = tale.inventory["wood", default: 0]
    try RPGStoryRuntime.advance(world: &tale, generator: generator)
    check(tale.story.activeProgress?.current == "villageGate" && tale.inventory["wood", default: 0] == wood + 3, "3D story: the reward is paid once")
    RPGStorySpatial.blocksDestroyed([], world: &tale)
    check(tale.events.filter { $0.kind == "blockDestroyed" }.count == 1, "3D story: an empty removal records nothing")

    // Walking there in 3D: the village marker, then arrival.
    let village = generator.anchor(.village)
    check(RPGStorySpatial.objective(world: tale, generator: generator) == .init(title: RPGAnchorID.village.title, point: village, radius: 4),
          "3D story: the village quest points at the village on the shared grid")
    let revision = tale.revision
    check(!RPGStorySpatial.syncPlayer(SpatialVector(Double(generator.anchor(.spawn).x) + 0.5, Double(generator.anchor(.spawn).z) + 0.5, 0), world: &tale),
          "3D story: standing still changes nothing")
    check(RPGStorySpatial.syncPlayer(SpatialVector(Double(village.x) + 2.7, Double(village.z) + 0.2, 0), world: &tale) &&
          tale.player.surface == SurfacePoint(x: village.x + 2, z: village.z) && tale.revision == revision,
          "3D story: the 3D position becomes the story cell without an edit revision")
    check(RPGStorySpatial.conditionMet(world: tale, generator: generator), "3D story: arriving in 3D meets the village condition")
    try RPGStoryRuntime.advance(world: &tale, generator: generator)
    try RPGStoryRuntime.advance(world: &tale, generator: generator)
    check(tale.story.activeProgress?.current == "villageChoice", "3D story: the keeper's dialogue follows")
    var sideways = tale; sideways.player.perspective = .side
    check(RPGStorySpatial.syncPlayer(SpatialVector(Double(village.x) + 2.5, Double(village.z) + 0.5, 0), world: &sideways) && sideways.player.perspective == .topDown,
          "3D story: an old side-view save reads positions again")
    check(!RPGStorySpatial.syncPlayer(SpatialVector(.nan, 1, 0), world: &sideways), "3D story: a broken position is ignored")
    check(RPGStorySpatial.syncPlayer(SpatialVector(-40, 900, 0), world: &sideways) && sideways.player.surface == SurfacePoint(x: 0, z: 255), "3D story: positions are clamped to the grid")

    // The guard fight as a 3D creature.
    try RPGStoryRuntime.advance(choiceID: "fight", world: &tale, generator: generator)
    let guardID = RPGStoryRuntime.enemyID(graphID: RPGOfficialStory.graph.id, key: "village-guardian")
    let shown = RPGStorySpatial.storyCreatures(for: tale)
    check(shown.count == 1 && shown[0].id == RPGStorySpatial.creaturePrefix + guardID && shown[0].health == 45 && shown[0].alive, "3D story: the guard appears as a 3D creature")
    let guardCell = tale.combat.enemies.first { $0.id == guardID }?.surface
    let guardCheckpoint = tale
    check(RPGStorySpatial.objective(world: tale, generator: generator)?.point == guardCell, "3D story: the marker points at the guard")
    var creatures = [CreatureEntity(id: "wild-slime", kind: .enemy, position: SpatialVector(10, 10, 0), home: SpatialVector(10, 10, 0), health: 20, maxHealth: 20, damage: 3)]
    check(RPGStorySpatial.reconcile(&creatures, with: tale) && creatures.count == 2, "3D story: reconcile adds the guard next to other creatures")
    check(!RPGStorySpatial.reconcile(&creatures, with: tale) && creatures.count == 2, "3D story: reconcile is idempotent")
    var elsewhere = creatures
    check(RPGStorySpatial.reconcile(&elsewhere, with: tale, inStoryRegion: false) && elsewhere.map(\.id) == ["wild-slime"],
          "3D story: outside the story's region the guard is not in the world")
    check(RPGStorySpatial.reconcile(&elsewhere, with: tale) && elsewhere.count == 2, "3D story: back in the region the guard returns")
    check(!RPGStorySpatial.defeated("wild-slime", world: &tale), "3D story: other creatures are not story enemies")
    let shards = tale.inventory["moon-shard", default: 0]
    check(RPGStorySpatial.defeated(RPGStorySpatial.creaturePrefix + guardID, world: &tale), "3D story: defeating the guard in 3D is recorded")
    check(tale.combat.defeatedIDs.contains(guardID) && !tale.player.inCombat && tale.inventory["moon-shard", default: 0] == shards &&
          tale.events.contains { $0.kind == "enemyDefeated" } && tale.events.contains { $0.kind == "combatWon" },
          "3D story: defeat list, events and combat flag as on the old map, shards not paid twice")
    check(!RPGStorySpatial.defeated(RPGStorySpatial.creaturePrefix + guardID, world: &tale), "3D story: a defeat counts once")
    check(RPGStorySpatial.storyCreatures(for: tale).isEmpty, "3D story: a defeated guard is not shown again")
    check(RPGStorySpatial.reconcile(&creatures, with: tale) && creatures.map(\.id) == ["wild-slime"], "3D story: a stale living guard is removed from 3D")
    var corpse = CreatureEntity(id: RPGStorySpatial.creaturePrefix + guardID, kind: .enemy, position: SpatialVector(5, 5, 0), home: SpatialVector(5, 5, 0), health: 0, maxHealth: 45, damage: 7)
    corpse.state = .dead
    var withCorpse = [corpse]
    check(!RPGStorySpatial.reconcile(&withCorpse, with: tale) && withCorpse.count == 1, "3D story: the 3D world keeps its own fallen guard")
    RPGStoryRuntime.recordEvents(world: &tale)
    check(RPGStorySpatial.conditionMet(world: tale, generator: generator), "3D story: the battle condition is met")
    try RPGStoryRuntime.advance(world: &tale, generator: generator)
    try RPGStoryRuntime.advance(world: &tale, generator: generator)
    check(tale.story.activeProgress?.ended == true && tale.inventory["moon-shard", default: 0] == shards + 1, "3D story: the battle ending pays the story's own reward")
    check(RPGStorySpatial.objective(world: tale, generator: generator) == nil && !RPGStorySpatial.conditionMet(world: tale, generator: generator), "3D story: nothing to point at once the chapter ends")
    let reloaded = try RPGWorldCodec.decode(RPGWorldCodec.encode(tale))
    check(reloaded == tale, "3D story: progress made in 3D saves and reloads unchanged")
    // Story enemies stand on a free 3D cell near their story cell.
    let wall: Set<String> = ["9,9", "10,9", "11,9", "9,10", "10,10", "11,10", "9,11", "10,11", "11,11"]
    let freeSpot = RPGStorySpatial.nearestFree(SpatialVector(10.5, 10.5, 0)) { !wall.contains("\(Int($0.x)),\(Int($0.y))") }
    check(freeSpot == SpatialVector(8.5, 8.5, 0), "3D story: a blocked spot moves to the nearest free cell, in a fixed order (\(freeSpot))")
    check(RPGStorySpatial.nearestFree(SpatialVector(3.2, 4.7, 0)) { _ in true } == SpatialVector(3.2, 4.7, 0), "3D story: a free spot stays exactly where it is")
    check(RPGStorySpatial.nearestFree(SpatialVector(50.5, 50.5, 0)) { _ in false } == SpatialVector(50.5, 50.5, 0), "3D story: nowhere free keeps the spot")
    var placed: [CreatureEntity] = []
    _ = RPGStorySpatial.reconcile(&placed, with: guardCheckpoint, free: { $0.x < Double(guardCell?.x ?? 0) })
    check(placed.count == 1 && placed[0].position.x < Double(guardCell?.x ?? 0) && placed[0].home == placed[0].position,
          "3D story: the guard is summoned onto a free cell, home included")

    // An old 2D save: wandering slimes and a stale combat flag.
    var old = WorldState(seed: 9); old.player.surface = generator.anchor(.spawn); old.player.perspective = .side
    old.combat.enemies = [RPGEnemyState(id: "slime:3:4", surface: SurfacePoint(x: 40, z: 40), aggro: true)]
    old.player.inCombat = true
    let oldEntities = old.entities, oldInventory = old.inventory
    check(RPGStorySpatial.storyCreatures(for: old).isEmpty, "3D story: 2D wandering enemies are never summoned in 3D")
    RPGStorySpatial.normalize(&old)
    check(old.combat.enemies.isEmpty && !old.player.inCombat && old.player.perspective == .topDown && old.entities == oldEntities && old.inventory == oldInventory,
          "3D story: an old save drops 2D wanderers and the stale combat flag, nothing else")
    try RPGStoryRuntime.start(graphID: RPGOfficialStory.graph.id, world: &old)
    check(old.story.activeGraphID == RPGOfficialStory.graph.id, "3D story: the story can start in a normalised old save")
    var fighting = tale; fighting.combat.enemies.append(RPGEnemyState(id: "story:1:boss", surface: SurfacePoint(x: 50, z: 50), health: 30, aggro: true)); fighting.player.inCombat = true
    RPGStorySpatial.normalize(&fighting)
    check(fighting.player.inCombat && fighting.combat.enemies.contains { $0.id == "story:1:boss" }, "3D story: a living story enemy keeps the fight going")
    print("RPG 3D story: official chapter played from 3D events")
}
