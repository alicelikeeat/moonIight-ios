import Foundation

extension WorldState {
    /// The same world as a schema 6 writer would have saved it.
    func withoutCellStyles() -> WorldState {
        var copy = self
        copy.mediaBindings = mediaBindings.filter { $0.kind == .image || $0.kind == .video }.map { var b = $0; b.style = nil; b.fit = nil; b.paused = nil; return b }
        copy.entities = entities.map { var e = $0; if let id = e.mediaBindingID, !copy.mediaBindings.contains(where: { $0.id == id }) { e.mediaBindingID = nil }; return e }
        copy.undo = []; copy.redo = []
        return copy
    }
}

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name); checks += 1
}
func rejected(_ state: WorldState, _ name: String) {
    do { _ = try RPGWorldCodec.encode(state); preconditionFailure(name) } catch { checks += 1 }
}
let empty = WorldState(seed: 42)
let roundTrip = try RPGWorldCodec.decode(RPGWorldCodec.encode(empty))
check(roundTrip == empty, "world round trip")
check(ChunkCoordinate.all.count == 64 && Set(ChunkCoordinate.all.map(\.id)).count == 64, "64 chunk identities")
for x in [0, 31, 32, 255] {
    for z in [0, 31, 32, 255] {
        let point = SurfacePoint(x: x, z: z)
        check(point.chunk == .init(x: x / 32, z: z / 32), "chunk edge mapping")
    }
}
check(SurfacePoint(x: -1, z: 0).chunk == nil && SurfacePoint(x: 256, z: 0).chunk == nil, "out of bounds")
var invalid = empty; invalid.schemaVersion = 99; rejected(invalid, "unknown schema")
invalid = empty; invalid.generatorVersion = 2; rejected(invalid, "unknown generator")
invalid = empty; invalid.player.surface.x = 256; rejected(invalid, "invalid player coordinate")
let landing = SidePlacement(regionID: "test", horizontal: 1, height: 2)
let region = SideRegion(id: "test", origin: .init(x: 10, z: 20), width: 32, landing: landing)
let entity = WorldEntity(id: "shared", definitionID: "stone", scope: .shared, surface: .init(x: 11, z: 20), side: landing)
var world = empty; world.sideRegions = [region]; world.entities = [entity]
let mappedRoundTrip = try RPGWorldCodec.decode(RPGWorldCodec.encode(world))
check(mappedRoundTrip == world, "shared mapping Codable")
check(TopDownProjection().visibleEntities(in: world).map(\.id) == ["shared"], "top identity")
check(SideViewProjection(regionID: "test").visibleEntities(in: world).map(\.id) == ["shared"], "side same identity")
invalid = world; invalid.entities.append(entity); rejected(invalid, "duplicate entity identity")
invalid = world; invalid.entities[0].surface?.z = 21; rejected(invalid, "surface z is not side y")
invalid = world; invalid.entities[0].side?.horizontal = 2; rejected(invalid, "mapping is explicit")
invalid = world; invalid.entities[0].mediaBindingID = "missing"; rejected(invalid, "missing binding")
invalid = world; invalid.entities[0].scope = .sideOnly; rejected(invalid, "side only cannot occupy surface")
invalid = world; invalid.sideRegions[0].width = 256; rejected(invalid, "region overflow")
invalid = world; invalid.player.perspective = .side; rejected(invalid, "no landing for side player")
var binding = MediaBinding(id: "binding", mediaID: "library-item", kind: .video)
world.mediaBindings = [binding]; world.entities[0].mediaBindingID = binding.id
let bound = try RPGWorldCodec.decode(RPGWorldCodec.encode(world))
check(bound.entities[0].id == entity.id && bound.mediaBindings[0].mediaID == "library-item", "media independent identity")
binding.cropWidth = 1.5; invalid = world; invalid.mediaBindings = [binding]; rejected(invalid, "bad crop")
print("RPG P1: \(checks) checks passed")

let generated = RPGWorldGenerator(seed: 42)
check(RPGWorldGenerator.hash(seed: 42, x: 100, z: 100) == 1100301830784546726, "generator v1 integer golden vector")
check(generated.anchor(.spawn) == .init(x: 13, z: 17) && generated.anchor(.temple) == .init(x: 177, z: 147), "anchor golden positions")
var forward: [Int: RPGChunk] = [:], identities = Set<String>()
for coordinate in ChunkCoordinate.all {
    let chunk = generated.chunk(coordinate)!
    check(chunk.terrain.count == 1024, "chunk dimensions")
    for entity in chunk.entities {
        check(identities.insert(entity.id).inserted && entity.surface?.chunk == coordinate, "stable global ownership")
        check(!generated.protected(entity.surface!), "resources do not block reserved paths")
    }
    forward[coordinate.id] = chunk
}
for coordinate in ChunkCoordinate.all.reversed() { check(generated.chunk(coordinate) == forward[coordinate.id], "generation order independent") }
check(RPGWorldGenerator(seed: 1).chunk(.init(x: 2, z: 2)) != generated.chunk(.init(x: 2, z: 2)), "seed affects world")
check(generated.chunk(.init(x: -1, z: 0)) == nil && generated.tile(at: .init(x: 256, z: 0)) == nil, "generator rejects invalid coordinates")
for seed in [UInt64(0), 1, 42, UInt64.max] {
    let value = RPGWorldGenerator(seed: seed)
    check(value.anchorsReachable(), "all six plot anchors reachable")
    check(value.anchors.allSatisfy { value.tile(at: $0.point)?.passable == true && value.protected($0.point) }, "safe anchors reserved before noise")
}
check(generated.priorityChunks(around: .init(x: 0, z: 0)).count == 4 && generated.priorityChunks(around: .init(x: 100, z: 100)).count == 9, "candidate neighborhood clipped to world")
var generatedState = WorldState(seed: 42)
generatedState.sideRegions = [generated.sideRegion]
generatedState.entities = ChunkCoordinate.all.flatMap { forward[$0.id]!.entities }
try generatedState.validate()
print("RPG P2: \(checks) total checks passed")

func editRejected(_ title: String, _ operation: () throws -> Void) {
    do { try operation(); preconditionFailure(title) } catch { checks += 1 }
}
var editing = WorldState(seed: 42)
editing.generated = true; editing.sideRegions = [generated.sideRegion]; editing.player.mode = .creative
let pair = (60..<230).compactMap { z -> [SurfacePoint]? in
    let a = SurfacePoint(x: 31,z: z), b = SurfacePoint(x: 32,z: z)
    return [a,b].allSatisfy({ generated.tile(at: $0)?.passable == true && !generated.protected($0) && RPGWorldEditing.entity(at: $0,world: editing,generator: generated) == nil }) ? [a,b] : nil
}.first!
let pristine = editing
editRejected("protected anchor remains protected in creative") { try RPGWorldEditing.place([.init(point: generated.anchor(.spawn),definitionID: "wood")],world: &editing,generator: generated) }
check(editing == pristine,"protection failure is atomic")
try RPGWorldEditing.place(pair.map { .init(point: $0,definitionID: "wood") },world: &editing,generator: generated)
check(editing.entities.count == 2 && Set(editing.entities.compactMap { $0.surface?.chunk }).count == 2,"batch across chunk boundary")
let placedIDs = editing.entities.map(\.id)
try RPGWorldEditing.undo(world: &editing); check(editing.entities.isEmpty,"undo full batch")
try RPGWorldEditing.redo(world: &editing); check(editing.entities.map(\.id) == placedIDs,"redo preserves identity")
let occupiedBefore = editing
editRejected("occupied batch") { try RPGWorldEditing.place(pair.map { .init(point:$0,definitionID:"stone") },world:&editing,generator:generated) }
check(editing == occupiedBefore,"failed occupied batch rolls back all state")
let clipboard = try RPGWorldEditing.copy(from: pair[0],to:pair[1],world:editing,generator:generated)
check(clipboard.cells.count == 2 && clipboard.width == 2,"copy range data")
try RPGWorldEditing.hit(pair[0],world:&editing,generator:generated)
check(editing.damage[placedIDs[0]] == 1 && editing.entities.count == 2,"hit changes durability before removal")
try RPGWorldEditing.hit(pair[0],world:&editing,generator:generated)
try RPGWorldEditing.hit(pair[0],world:&editing,generator:generated)
check(editing.entities.count == 1 && editing.inventory["wood"] == pristine.inventory["wood"]! + 1,"destroy removes and drops once")
let drops = editing.inventory
try RPGWorldEditing.undo(world:&editing); check(editing.damage[placedIDs[0]] == 2,"undo restores previous damage")
try RPGWorldEditing.redo(world:&editing); check(editing.inventory == drops,"redo does not duplicate drop")
var adventure = pristine; adventure.player.mode = .adventure; adventure.player.surface = .init(x:30,z:pair[0].z); adventure.inventory["wood"] = 1
let poor = adventure
editRejected("insufficient total resources") { try RPGWorldEditing.place(pair.map { .init(point:$0,definitionID:"wood") },world:&adventure,generator:generated) }
check(adventure == poor,"resource failure rolls back inventory and world")
adventure.inventory["wood"] = 2
try RPGWorldEditing.place(pair.map { .init(point:$0,definitionID:"wood") },world:&adventure,generator:generated)
check(adventure.inventory["wood"] == 0,"resource cost committed once")
try RPGWorldEditing.undo(world:&adventure); check(adventure.inventory["wood"] == 2,"undo refunds exactly")
var removedResource = pristine
let resource = ChunkCoordinate.all.lazy.compactMap { generated.chunk($0)?.entities.first }.first!
try RPGWorldEditing.hit(resource.surface!,world:&removedResource,generator:generated,force:true)
check(removedResource.removedGeneratedIDs.contains(resource.id),"generated removal stored as delta")
let restoredResource = try RPGWorldCodec.decode(RPGWorldCodec.encode(removedResource))
check(RPGWorldEditing.entity(at:resource.surface!,world:restoredResource,generator:generated) == nil,"removed generated block stays removed after serialization")
removedResource.player.surface = resource.surface!
let occupiedResource = removedResource
editRejected("cannot restore block through player") { try RPGWorldEditing.undo(world:&removedResource) }
check(removedResource == occupiedResource,"collision rejection is atomic")
editRejected("oversize fill") { _ = try RPGWorldEditing.rectangle(.init(x:0,z:0),.init(x:255,z:255)) }
check(RPGWorldEditing.line(.init(x:31,z:31),.init(x:34,z:34)).count == 4,"continuous paint bridges sampled movement")
let saveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rpg-tests-" + UUID().uuidString,isDirectory:true)
let disk = RPGWorldDiskStore(root: saveRoot)
try await disk.save(editing)
let diskRoundTrip = try await disk.load()
check(diskRoundTrip == editing,"atomic file round trip")
var later = editing; later.revision += 1; later.inventory["stone",default:0] += 1
try await disk.save(later)
let folder = saveRoot.appendingPathComponent("Worlds").appendingPathComponent(editing.id)
try Data("broken".utf8).write(to:folder.appendingPathComponent("world.json"),options:.atomic)
let recovered = try await disk.load()
let usedBackup = await disk.recoveredFromBackup
check(recovered == editing && usedBackup,"previous-good backup restores corrupted primary")
try Data("broken".utf8).write(to:folder.appendingPathComponent("world.backup.json"),options:.atomic)
do { _ = try await disk.load(); preconditionFailure("both corrupt must report failure") } catch { checks += 1 }
var hostile = editing; hostile.id = "../escape"
do { try await disk.save(hostile); preconditionFailure("path traversal") } catch { checks += 1 }
try? FileManager.default.removeItem(at:saveRoot)
print("RPG P3: \(checks) total checks passed")

var dual = WorldState(seed:42)
dual.generated=true;dual.sideRegions=[generated.sideRegion];dual.player.mode = .creative;dual.player.surface=generated.anchor(.temple)
let beforeSwitch=dual
try RPGProjectionRules.switchPerspective(world:&dual,generator:generated)
check(dual.player.perspective == .side && dual.player.side == generated.sideRegion.landing,"safe mapped entrance")
try RPGProjectionRules.switchPerspective(world:&dual,generator:generated)
check(dual.player.perspective == .topDown && dual.player.surface == beforeSwitch.player.surface,"return uses explicit surface entrance")
dual.player.inCombat=true
let fighting=dual
editRejected("combat locks projection") {try RPGProjectionRules.switchPerspective(world:&dual,generator:generated)}
check(dual==fighting,"combat rejection preserves all state")
dual.player.inCombat=false;dual.player.surface=generated.anchor(.spawn)
editRejected("no arbitrary rotation anywhere") {try RPGProjectionRules.switchPerspective(world:&dual,generator:generated)}
dual.player.surface=generated.anchor(.temple)
let sharedPoint=(0..<generated.sideRegion.width).map{SurfacePoint(x:generated.sideRegion.origin.x+$0,z:generated.sideRegion.origin.z)}.first{ $0 != dual.player.surface && generated.tile(at:$0)?.passable == true && !generated.protected($0) && RPGWorldEditing.entity(at:$0,world:dual,generator:generated)==nil }!
try RPGWorldEditing.place([.init(point:sharedPoint,definitionID:"wood")],world:&dual,generator:generated)
let sharedID=dual.entities[0].id
check(dual.entities[0].scope == .shared && RPGProjectionRules.sideEntities(world:dual,generator:generated).contains{$0.id==sharedID},"same constructed identity in both projections")
try RPGProjectionRules.switchPerspective(world:&dual,generator:generated)
let sharedCell=dual.entities[0].side!
try RPGProjectionRules.hitSide(sharedCell,world:&dual,generator:generated,force:true)
check(!dual.entities.contains{$0.id==sharedID} && !RPGProjectionRules.sideEntities(world:dual,generator:generated).contains{$0.id==sharedID},"side destruction reflected in surface data")
try RPGWorldEditing.undo(world:&dual)
check(dual.entities.contains{$0.id==sharedID},"undo restores shared identity")
let sideOnly=SidePlacement(regionID:generated.sideRegion.id,horizontal:24,height:10)
try RPGProjectionRules.placeSide(sideOnly,definitionID:"platform",world:&dual,generator:generated)
let sideID=dual.entities.last!.id
check(dual.entities.last!.scope == .sideOnly && dual.entities.last!.surface == nil && !TopDownProjection().visibleEntities(in:dual).contains{$0.id==sideID},"side height is independent and scoped")
let savedDual=try RPGWorldCodec.decode(RPGWorldCodec.encode(dual))
check(savedDual == dual,"both projections share one save")
var landingBlocked=WorldState(seed:42)
landingBlocked.generated=true;landingBlocked.sideRegions=[generated.sideRegion];landingBlocked.isCreativeCopy=true;landingBlocked.parentWorldID="original";landingBlocked.player.mode = .creative
try RPGWorldEditing.place([.init(point:generated.anchor(.temple),definitionID:"wood")],world:&landingBlocked,generator:generated)
landingBlocked.player.surface=generated.anchor(.temple)
let blockedBefore=landingBlocked
editRejected("blocked landing never partially switches") {try RPGProjectionRules.switchPerspective(world:&landingBlocked,generator:generated)}
check(landingBlocked == blockedBefore,"blocked landing rollback")
print("RPG P4: \(checks) total checks passed")

var visualWorld=WorldState(seed:42)
visualWorld.sideRegions=[generated.sideRegion]
let identityBefore=visualWorld.id
try RPGMediaBindings.assign(mediaID:"local-video",kind:.video,to:.player,world:&visualWorld,generator:generated)
try RPGMediaBindings.assign(mediaID:"local-image",kind:.image,to:.background(0),world:&visualWorld,generator:generated)
check(visualWorld.id==identityBefore && visualWorld.player.mediaBindingID != nil && visualWorld.backgroundBindingIDs.count==1,"media does not replace world or player identity")
let serializedVisual=try RPGWorldCodec.encode(visualWorld)
let visualRestored=try RPGWorldCodec.decode(serializedVisual)
check(visualRestored == visualWorld && !String(data:serializedVisual,encoding:.utf8)!.contains("file://"),"world stores media identity without original file bytes or sandbox URL")
var oldJSON=try JSONSerialization.jsonObject(with:serializedVisual) as! [String:Any]
oldJSON["schemaVersion"]=1;oldJSON["videoBudget"]=nil;oldJSON["backgroundBindingIDs"]=nil
let migrated=try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject:oldJSON))
check(migrated.schemaVersion==WorldState.currentSchema && migrated.player.mediaBindingID==visualWorld.player.mediaBindingID && migrated.mediaBindings==visualWorld.mediaBindings,"schema 1 media defaults preserve existing identities")
let manyRequests=(0..<256).map{RPGMediaRequest(ownerID:String($0),mediaID:String($0),role:.interactive,visible:true)}
check(RPGMediaPolicy.schedule(manyRequests,limit:256).count==2,"256 video bindings never create 256 slots")
check(RPGMediaPolicy.schedule((0..<54).map{.init(ownerID:String($0),mediaID:"shared",role:.interactive,visible:true)},limit:2)==["shared"],"one decoder for reused texture")
let backgroundRequests=(0..<3).map{RPGMediaRequest(ownerID:String($0),mediaID:String($0),role:.background,visible:true)}
check(RPGMediaPolicy.schedule(backgroundRequests,limit:2).count==1,"one background video role")
check(RPGMediaPolicy.schedule([.init(ownerID:"offscreen",mediaID:"v",role:.player,visible:false)],limit:2).isEmpty,"invisible texture gets no slot")
check(RPGMediaPolicy.schedule(backgroundRequests+[.init(ownerID:"player",mediaID:"player",role:.player,visible:true)],limit:2).first=="player","player role priority")
check(RPGMediaPolicy.schedule(manyRequests,limit:0).isEmpty,"static budget")
var badMedia=visualWorld;badMedia.backgroundBindingIDs=["missing"]
rejected(badMedia,"invalid background reference")
print("RPG P5: \(checks) total checks passed")

// P6: actions are atomic, rewards and enemy identity survive saving and projection.
var fighter = WorldState(seed:42)
let arenaGenerator = RPGWorldGenerator(seed:42)
fighter.sideRegions = [arenaGenerator.sideRegion]
fighter.player.surface = arenaGenerator.anchor(.spawn)
let origin = fighter.player.surface
fighter.combat.enemies = [.init(id:"test-enemy",surface:.init(x:origin.x+2,z:origin.z),aggro:true)]
fighter.player.inCombat = true
try RPGCombatRules.action(.attack,world:&fighter,generator:arenaGenerator,passable:{$0.valid})
check(fighter.combat.enemies[0].health==18 && fighter.player.stamina==92,"attack shares health and stamina")
let cooldownSnapshot=fighter
do { try RPGCombatRules.action(.attack,world:&fighter,generator:arenaGenerator,passable:{$0.valid});preconditionFailure("cooldown accepted") }catch{check(fighter==cooldownSnapshot,"cooldown rejection is atomic")}
try RPGCombatRules.action(.skill,world:&fighter,generator:arenaGenerator,passable:{$0.valid})
check(fighter.combat.enemies[0].health==0 && fighter.inventory["moon-shard"]==1 && !fighter.player.inCombat,"one reward and combat exit")
for _ in 0..<40 { RPGCombatRules.advance(world:&fighter,generator:arenaGenerator,delta:0.1,passable:{$0.valid}) }
try RPGCombatRules.action(.skill,world:&fighter,generator:arenaGenerator,passable:{$0.valid})
check(fighter.inventory["moon-shard"]==1 && fighter.combat.defeatedIDs==["test-enemy"],"dead enemies never drop twice")
let combatRestored=try RPGWorldCodec.decode(RPGWorldCodec.encode(fighter))
check(combatRestored==fighter,"combat save restores cooldowns and exact defeated identities")
var tired=fighter;tired.player.stamina=0;tired.combat.attackRemaining=0
let tiredBefore=tired
do {try RPGCombatRules.action(.attack,world:&tired,generator:arenaGenerator,passable:{$0.valid});preconditionFailure("stamina accepted")}catch{check(tired==tiredBefore,"stamina rejection rolls back cooldown")}
var roller=fighter;roller.player.stamina=100;roller.combat.rollRemaining=0
try RPGCombatRules.action(.roll,world:&roller,generator:arenaGenerator,passable:{$0.x<origin.x+2})
check(roller.player.surface.x==origin.x+1 && roller.combat.invulnerableRemaining>0,"roll stops before obstruction")
let pathStep=RPGCombatRules.nextStep(from:.init(x:10,z:10),to:.init(x:12,z:10),passable:{$0 != SurfacePoint(x:11,z:10)})
check(pathStep != nil && pathStep != SurfacePoint(x:11,z:10),"enemy path routes around solid wall")
var bossFight=WorldState(seed:42);bossFight.player.surface=origin;bossFight.player.weapon = .moonBlade
bossFight.combat.enemies=[.init(id:"test-boss",boss:true,surface:.init(x:origin.x+1,z:origin.z),health:65,maximumHealth:120,aggro:true)]
try RPGCombatRules.action(.attack,world:&bossFight,generator:arenaGenerator,passable:{$0.valid})
check(bossFight.combat.enemies[0].phase==2 && bossFight.events.contains{$0.kind=="bossPhaseChanged"},"boss crosses second phase")
var sideFighter=WorldState(seed:42);sideFighter.sideRegions=[arenaGenerator.sideRegion]
sideFighter.player.perspective = .side;sideFighter.player.side=arenaGenerator.sideRegion.landing
let sideOrigin=sideFighter.player.side!
sideFighter.combat.enemies=[.init(id:"side-target",scope:.sideOnly,surface:nil,side:.init(regionID:sideOrigin.regionID,horizontal:sideOrigin.horizontal+1,height:sideOrigin.height+1)),.init(id:"surface-target",surface:sideFighter.player.surface)]
try RPGCombatRules.action(.attack,world:&sideFighter,generator:arenaGenerator,passable:{$0.valid})
check(sideFighter.combat.enemies[0].health==18 && sideFighter.combat.enemies[1].health==30,"air attack uses side volume only")
var brokenEnemy=sideFighter;brokenEnemy.combat.enemies[0].scope = .shared
rejected(brokenEnemy,"shared enemy requires explicit surface mapping")
var legacyCombat=try JSONSerialization.jsonObject(with:RPGWorldCodec.encode(fighter)) as! [String:Any]
legacyCombat["schemaVersion"]=2;legacyCombat["combat"]=nil
var legacyPlayer=legacyCombat["player"] as! [String:Any];legacyPlayer["facing"]=nil;legacyPlayer["weapon"]=nil;legacyPlayer["armor"]=nil;legacyCombat["player"]=legacyPlayer
let legacyRestored=try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject:legacyCombat))
check(legacyRestored.id==fighter.id && legacyRestored.player.surface==fighter.player.surface && legacyRestored.combat.enemies.isEmpty,"schema 2 migration preserves world and initializes combat")
print("RPG P6: \(checks) total checks passed")

// P7: both official branches, transactional actions and graph validation.
try RPGOfficialStory.graph.validate()
var tale=WorldState(seed:42);tale.player.surface=arenaGenerator.anchor(.spawn);tale.sideRegions=[arenaGenerator.sideRegion]
try RPGStoryRuntime.start(graphID:RPGOfficialStory.graph.id,world:&tale)
try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)
check(tale.story.activeProgress?.current=="prologue","official prologue begins")
try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)
try RPGStoryRuntime.advance(choiceID:"help",world:&tale,generator:arenaGenerator)
check(tale.story.activeProgress?.current=="gather" && tale.story.activeProgress?.variables["promise"]==1,"official branch writes variable")
let waitingWood=tale.inventory["wood"]
try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)
check(tale.story.activeProgress?.current=="gather" && tale.inventory["wood"]==waitingWood,"unsatisfied quest holds without reward")
tale.events.append(.init(id:"mined-once",kind:"blockDestroyed",entityID:"block",definitionID:"wood"))
try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)
check(tale.story.activeProgress?.current=="villageGate" && tale.inventory["wood"]==15,"material event completes prologue once")
let villageCheckpoint=tale
for _ in 0..<3{try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)}
check(tale.inventory["wood"]==15,"waiting never replays prior reward")
tale.player.surface=arenaGenerator.anchor(.village)
try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)
try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)
check(tale.story.activeProgress?.current=="villageChoice","stable semantic village anchor gates dialogue")
let villageChoiceCheckpoint=tale
try RPGStoryRuntime.advance(choiceID:"repair",world:&tale,generator:arenaGenerator)
try RPGStoryRuntime.advance(world:&tale,generator:arenaGenerator)
check(tale.story.activeProgress?.ended==true && tale.inventory["stone"]==6 && tale.inventory["moon-shard"]==1,"peace branch consumes materials and ends chapter")
var resumedTale=try RPGWorldCodec.decode(RPGWorldCodec.encode(tale))
try RPGStoryRuntime.advance(world:&resumedTale,generator:arenaGenerator)
check(resumedTale==tale,"completed story does not replay after reload")
var battleTale=villageChoiceCheckpoint
try RPGStoryRuntime.advance(choiceID:"fight",world:&battleTale,generator:arenaGenerator)
let guardID=RPGStoryRuntime.enemyID(graphID:RPGOfficialStory.graph.id,key:"village-guardian")
check(battleTale.combat.enemies.contains{$0.id==guardID} && battleTale.player.inCombat,"battle branch creates stable enemy")
try RPGCombatRules.action(.skill,world:&battleTale,generator:arenaGenerator,passable:{$0.valid})
try RPGCombatRules.action(.attack,world:&battleTale,generator:arenaGenerator,passable:{$0.valid})
for _ in 0..<4 {RPGCombatRules.advance(world:&battleTale,generator:arenaGenerator,delta:0.1,passable:{$0.valid})}
try RPGCombatRules.action(.attack,world:&battleTale,generator:arenaGenerator,passable:{$0.valid})
try RPGStoryRuntime.advance(world:&battleTale,generator:arenaGenerator)
try RPGStoryRuntime.advance(world:&battleTale,generator:arenaGenerator)
check(battleTale.story.activeProgress?.ended==true && battleTale.inventory["moon-shard"]==2,"combat event finishes alternative chapter branch")
var invalidGraph=RPGOfficialStory.graph;invalidGraph.nodes[0].next="missing"
do{try invalidGraph.validate();preconditionFailure("broken link accepted")}catch{checks+=1}
invalidGraph=RPGOfficialStory.graph;invalidGraph.nodes[0].next="prologue"
do{try invalidGraph.validate();preconditionFailure("cycle accepted")}catch{checks+=1}
let rollbackGraph=RPGStoryGraph(id:"rollback",title:"回滚检查",start:"action",nodes:[.init(id:"action",kind:.world,next:"end",actions:[.init(kind:.giveItem,key:"wood",value:2),.init(kind:.takeItem,key:"stone",value:100)]),.init(id:"end",kind:.end)])
var rollbackWorld=WorldState(seed:42);rollbackWorld.story.customGraphs=[rollbackGraph]
try RPGStoryRuntime.start(graphID:rollbackGraph.id,world:&rollbackWorld)
let rollbackBefore=rollbackWorld
do{try RPGStoryRuntime.advance(world:&rollbackWorld,generator:arenaGenerator);preconditionFailure("insufficient story cost accepted")}catch{check(rollbackWorld==rollbackBefore,"failed node restores rewards, progress and receipts atomically")}
var counterWorld=villageCheckpoint
RPGStoryRuntime.recordEvents(world:&counterWorld);RPGStoryRuntime.recordEvents(world:&counterWorld)
check(counterWorld.story.eventCounts["blockDestroyed"]==1,"repeated event delivery is idempotent")
let graphData=try RPGStoryCodec.encode(RPGOfficialStory.graph)
let decodedGraph=try RPGStoryCodec.decode(graphData)
check(decodedGraph==RPGOfficialStory.graph,"independent story JSON round trip")
print("RPG P7: \(checks) total checks passed")

// P8: creation, isolated preview, bounded imports and missing media fallback.
let authored=RPGStoryAuthoring.template()
try authored.validate()
let sourceBeforePreview=tale
var preview=try RPGStoryAuthoring.preview(authored,bindings:[],source:tale)
try RPGStoryRuntime.advance(world:&preview,generator:arenaGenerator)
try RPGStoryRuntime.advance(choiceID:"watch",world:&preview,generator:arenaGenerator)
check(preview.story.activeProgress?.current=="media","authored branch enters media node")
try RPGStoryRuntime.advance(world:&preview,generator:arenaGenerator)
check(preview.story.activeProgress?.ended==true && tale==sourceBeforePreview,"preview rewards never mutate source world")
var publishedWorld=tale
try RPGStoryAuthoring.install(authored,bindings:[],world:&publishedWorld)
check(publishedWorld.story.customGraphs.contains{$0.id==authored.id} && publishedWorld.story.progress==tale.story.progress,"publishing keeps official progress")
let publishedBeforeDuplicate=publishedWorld
do{try RPGStoryAuthoring.install(authored,bindings:[],world:&publishedWorld);preconditionFailure("duplicate graph accepted")}catch{check(publishedWorld==publishedBeforeDuplicate,"duplicate publication rolls back")}
var missingCutscene=authored
let mediaIndex=missingCutscene.nodes.firstIndex{$0.kind == .media}!
missingCutscene.nodes[mediaIndex].mediaBindingID="missing-local-binding"
var fallbackPreview=try RPGStoryAuthoring.preview(missingCutscene,bindings:[],source:tale)
try RPGStoryRuntime.advance(world:&fallbackPreview,generator:arenaGenerator)
try RPGStoryRuntime.advance(choiceID:"watch",world:&fallbackPreview,generator:arenaGenerator)
try RPGStoryRuntime.advance(world:&fallbackPreview,generator:arenaGenerator)
check(fallbackPreview.story.activeProgress?.ended==true,"missing media never blocks subtitles or skip")
let authoredData=try RPGStoryCodec.encode(authored)
let authoredRoundTrip=try RPGStoryCodec.decode(authoredData)
check(authoredRoundTrip==authored,"custom branch exports and imports independently")
let executableJSON=String(decoding:authoredData,as:UTF8.self).replacingOccurrences(of:"giveItem",with:"runJavaScript")
do{_=try RPGStoryCodec.decode(Data(executableJSON.utf8));preconditionFailure("script action accepted")}catch{checks+=1}
do{_=try RPGStoryCodec.decode(Data(repeating:32,count:RPGStoryCodec.maximumBytes+1));preconditionFailure("oversize import accepted")}catch{checks+=1}
var mediaResumeWorld=tale;mediaResumeWorld.story.mediaPositions["official:media"]=12.5
let mediaResumeDecoded=try RPGWorldCodec.decode(RPGWorldCodec.encode(mediaResumeWorld))
check(mediaResumeDecoded.story.mediaPositions["official:media"]==12.5,"cutscene resume time persists without video bytes")
var schema4JSON=try JSONSerialization.jsonObject(with:RPGWorldCodec.encode(tale)) as! [String:Any]
schema4JSON["schemaVersion"]=4
var schema4Story=schema4JSON["story"] as! [String:Any];schema4Story["mediaPositions"]=nil;schema4JSON["story"]=schema4Story
let schema4Migrated=try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject:schema4JSON))
check(schema4Migrated.story.activeProgress==tale.story.activeProgress && schema4Migrated.story.mediaPositions.isEmpty,"schema 4 migration keeps node receipts and branch choices")
print("RPG P8: \(checks) total checks passed")

// P9: every injected interruption keeps world deltas and story receipts together.
enum InjectedSaveFailure:Error{case interruption}
var durableBase=villageChoiceCheckpoint;durableBase.revision=100
var durableNext=durableBase
try RPGStoryRuntime.advance(choiceID:"repair",world:&durableNext,generator:arenaGenerator)
durableNext.entities.append(.init(id:"durable-construction",definitionID:"wood",scope:.topDownOnly,surface:.init(x:30,z:30)))
durableNext.inventory["wood",default:0]-=1;durableNext.story.mediaPositions["cutscene-checkpoint"]=3.25;durableNext.revision+=1
try durableNext.validate()
for checkpoint in RPGSaveCheckpoint.allCases {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("rpg-fault-"+UUID().uuidString)
    let baselineStore=RPGWorldDiskStore(root:root);try await baselineStore.save(durableBase)
    let interrupted=RPGWorldDiskStore(root:root,fault:{point in if point==checkpoint{throw InjectedSaveFailure.interruption}})
    do{try await interrupted.save(durableNext);preconditionFailure("fault not injected")}catch{checks+=1}
    let restored=try await RPGWorldDiskStore(root:root).load()
    let committed=[RPGSaveCheckpoint.afterPrimary,.beforePointer,.afterPointer].contains(checkpoint)
    check(restored == (committed ? durableNext:durableBase),"interrupted save never mixes construction and reward receipts")
    if var resumed=restored,committed {
        let reward=resumed.inventory["moon-shard"]
        try RPGStoryRuntime.advance(world:&resumed,generator:arenaGenerator)
        check(resumed.inventory["moon-shard"]==reward,"interrupted node reward never replays")
    }
    try FileManager.default.removeItem(at:root)
}
let recoveryRoot=FileManager.default.temporaryDirectory.appendingPathComponent("rpg-recovery-"+UUID().uuidString)
let recoveryStore=RPGWorldDiskStore(root:recoveryRoot)
try await recoveryStore.save(durableBase);try await recoveryStore.save(durableNext)
let recoveryFolder=recoveryRoot.appendingPathComponent("Worlds").appendingPathComponent(durableBase.id)
let recoveryPrimary=recoveryFolder.appendingPathComponent("world.json"),recoveryBackup=recoveryFolder.appendingPathComponent("world.backup.json")
let goodBackup=try Data(contentsOf:recoveryBackup)
try Data("broken".utf8).write(to:recoveryPrimary,options:.atomic)
var staleWorld=durableBase;staleWorld.revision=99
do{try await recoveryStore.save(staleWorld);preconditionFailure("stale snapshot replaced backup")}catch{checks+=1}
let preservedBackup=try Data(contentsOf:recoveryBackup)
check(preservedBackup==goodBackup,"corrupt primary cannot permit stale write over good backup")
var futureObject=try JSONSerialization.jsonObject(with:RPGWorldCodec.encode(durableNext)) as! [String:Any]
futureObject["schemaVersion"]=999
let futureBytes=try JSONSerialization.data(withJSONObject:futureObject)
try futureBytes.write(to:recoveryPrimary,options:.atomic)
do{_=try await recoveryStore.load();preconditionFailure("future schema silently downgraded")}catch{check(error as? RPGWorldError == .unsupportedVersion,"future schema surfaced instead of old backup")}
do{try await recoveryStore.save(durableNext);preconditionFailure("future schema overwritten")}catch{checks+=1}
let retainedFuture=try Data(contentsOf:recoveryPrimary)
check(retainedFuture==futureBytes,"future file bytes retained on load and save rejection")
try RPGWorldCodec.encode(durableNext).write(to:recoveryPrimary,options:.atomic)
try Data("broken pointer".utf8).write(to:recoveryRoot.appendingPathComponent("active.json"),options:.atomic)
let recoveredPointer=try await recoveryStore.load()
let pointerFlag=await recoveryStore.recoveredFromBackup
check(recoveredPointer==durableNext && pointerFlag,"active pointer backup recovers complete latest world")
var orphan=durableNext;orphan.id=UUID().uuidString;orphan.parentWorldID=durableBase.id;orphan.isCreativeCopy=true
let pointerFault=RPGWorldDiskStore(root:recoveryRoot,fault:{if $0 == .beforePointer{throw InjectedSaveFailure.interruption}})
// Repair locator first; then interrupt a new copy before switching it active.
try await recoveryStore.save(durableNext)
do{try await pointerFault.save(orphan);preconditionFailure("copy pointer fault absent")}catch{checks+=1}
let activeAfterFault=try await recoveryStore.load()
let readableOrphan=try await recoveryStore.load(id:orphan.id)
check(activeAfterFault==durableNext && readableOrphan==orphan,"copy interruption preserves original and recoverable orphan")
try FileManager.default.removeItem(at:recoveryRoot)
print("RPG P9: \(checks) total checks passed")

// P10: graph-backed block behavior reuses receipts instead of arbitrary scripts.
var behaviorWorld=WorldState(seed:42);behaviorWorld.player.mode = .creative
let behaviorGraph=RPGStoryGraph(id:"behavior-test",title:"方块事件",start:"reward",nodes:[.init(id:"reward",kind:.end,text:"触发成功",actions:[.init(kind:.giveItem,key:"wood",value:2)])])
try RPGStoryAuthoring.install(behaviorGraph,bindings:[],world:&behaviorWorld)
let behaviorTarget=WorldEntity(id:"behavior-block",definitionID:"wood",scope:.topDownOnly,surface:.init(x:30,z:30))
behaviorWorld.entities=[behaviorTarget];behaviorWorld.player.surface = .init(x:29,z:30)
let tapBinding=RPGBehaviorBinding(entityID:behaviorTarget.id,graphID:behaviorGraph.id)
try RPGBehaviorRules.bind(tapBinding,target:behaviorTarget,world:&behaviorWorld,generator:arenaGenerator)
let firstFire=try RPGBehaviorRules.fire(.tap,targetID:behaviorTarget.id,entities:[behaviorTarget],world:&behaviorWorld,generator:arenaGenerator)
check(firstFire && behaviorWorld.inventory["wood"]==14,"tap executes graph actions once")
let secondFire=try RPGBehaviorRules.fire(.tap,targetID:behaviorTarget.id,entities:[behaviorTarget],world:&behaviorWorld,generator:arenaGenerator)
check(!secondFire && behaviorWorld.inventory["wood"]==14,"binding receipt prevents repeat activation")
let behaviorReload=try RPGWorldCodec.decode(RPGWorldCodec.encode(behaviorWorld))
check(behaviorReload.behaviors==behaviorWorld.behaviors,"behavior receipt survives world save")
for trigger in [RPGBehaviorTrigger.proximity,.attack,.timer,.storyEvent] {
    var scenario=behaviorWorld;scenario.story.progress=[];scenario.behaviors = .init();scenario.inventory["wood"]=12
    var binding=RPGBehaviorBinding(entityID:behaviorTarget.id,graphID:behaviorGraph.id,trigger:trigger)
    binding.delay=1
    try RPGBehaviorRules.bind(binding,target:behaviorTarget,world:&scenario,generator:arenaGenerator)
    if trigger == .timer {scenario.combat.clock=2}
    if trigger == .storyEvent {scenario.story.eventCounts["blockDestroyed"]=1}
    let fired=try RPGBehaviorRules.fire(trigger,targetID:trigger == .attack ? behaviorTarget.id:nil,entities:[behaviorTarget],world:&scenario,generator:arenaGenerator)
    check(fired && scenario.inventory["wood"]==14,"each declared trigger executes whitelisted graph")
}
var gatedBehavior=behaviorWorld;gatedBehavior.behaviors = .init();gatedBehavior.story.progress=[]
let gatedBinding=RPGBehaviorBinding(entityID:behaviorTarget.id,graphID:behaviorGraph.id,condition:.init(kind:.resource,key:"stone",value:100))
try RPGBehaviorRules.bind(gatedBinding,target:behaviorTarget,world:&gatedBehavior,generator:arenaGenerator)
let gatedBefore=gatedBehavior
let gatedFire=try RPGBehaviorRules.fire(.tap,targetID:behaviorTarget.id,entities:[behaviorTarget],world:&gatedBehavior,generator:arenaGenerator)
check(!gatedFire && gatedBehavior==gatedBefore,"failed behavior condition keeps world and receipt unchanged")
let protectedTarget=WorldEntity(id:"protected-anchor",definitionID:"wood",scope:.topDownOnly,surface:arenaGenerator.anchor(.village))
let protectedBinding=RPGBehaviorBinding(entityID:protectedTarget.id,graphID:behaviorGraph.id)
do{try RPGBehaviorRules.bind(protectedBinding,target:protectedTarget,world:&gatedBehavior,generator:arenaGenerator);preconditionFailure("protected behavior modified")}catch{checks+=1}
var metrics=RPGFrameMetrics()
for frame in 0...1000{metrics.sample(Double(frame)/60)}
check(metrics.count==600 && metrics.totalFrames==1000 && abs(metrics.framesPerSecond-60)<0.01,"bounded full frame sampling")
check(metrics.p95Milliseconds>16 && metrics.p95Milliseconds<17,"p95 frame time reports milliseconds")
let sampled=metrics.totalFrames;metrics.pause();metrics.sample(1000)
check(metrics.totalFrames==sampled,"background and overlay pauses do not become fake hitches")
metrics.sample(1000.08)
check(metrics.hitches==1,"active frame hitch is recorded")
var schema5JSON=try JSONSerialization.jsonObject(with:RPGWorldCodec.encode(behaviorWorld)) as! [String:Any]
schema5JSON["schemaVersion"]=5;schema5JSON["behaviors"]=nil
let schema5Migrated=try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject:schema5JSON))
check(schema5Migrated.story==behaviorWorld.story && schema5Migrated.entities==behaviorWorld.entities && schema5Migrated.behaviors.bindings.isEmpty,"schema 5 migration preserves world and story")
print("RPG P10: \(checks) total checks passed")

// Preserve generator-v1 identities while avoiding whole chunks per collision.
for anchor in RPGAnchorID.allCases where anchor != .spawn {
    let route=RPGWorldRoute.path(from:arenaGenerator.anchor(.spawn),to:arenaGenerator.anchor(anchor),generator:arenaGenerator,entities:[],removedIDs:[])
    check(route.last==arenaGenerator.anchor(anchor) && !route.isEmpty,"all story anchors have a reserved walking route")
    check(route.allSatisfy{arenaGenerator.protected($0) && arenaGenerator.baseEntity(at:$0)==nil},"official guide stays on resource-free reserved corridors")
    var previous=arenaGenerator.anchor(.spawn)
    check(route.allSatisfy{point in defer{previous=point};return abs(point.x-previous.x)+abs(point.z-previous.z)==1},"guide never teleports across cells")
}
let routeResource=ChunkCoordinate.all.flatMap{arenaGenerator.chunk($0)?.entities ?? []}.first{entity in
    guard let p=entity.surface,p.x>0,p.x<255 else{return false}
    return [-1,1].allSatisfy{dx in let next=SurfacePoint(x:p.x+dx,z:p.z);return arenaGenerator.tile(at:next)?.passable==true && arenaGenerator.baseEntity(at:next)==nil}
}!
let routePoint=routeResource.surface!,routeStart=SurfacePoint(x:routePoint.x-1,z:routePoint.z),routeEnd=SurfacePoint(x:routePoint.x+1,z:routePoint.z)
let detour=RPGWorldRoute.path(from:routeStart,to:routeEnd,generator:arenaGenerator,entities:[],removedIDs:[])
check(detour.last==routeEnd && !detour.contains(routePoint),"route avoids resources in chunks that were never loaded")
let clearedRoute=RPGWorldRoute.path(from:routeStart,to:routeEnd,generator:arenaGenerator,entities:[],removedIDs:[routeResource.id])
check(clearedRoute.count==2 && clearedRoute.contains(routePoint),"removed-generated delta reopens route")
var lookupWorld=WorldState(seed:42)
check(RPGWorldEditing.entity(at:routePoint,world:lookupWorld,generator:arenaGenerator)==routeResource,"point lookup retains generator-v1 entity identity and physics")
lookupWorld.removedGeneratedIDs=[routeResource.id]
check(RPGWorldEditing.entity(at:routePoint,world:lookupWorld,generator:arenaGenerator)==nil,"point lookup honors removal tombstone")
let cancelledRoute=RPGWorldRoute.path(from:routeStart,to:routeEnd,generator:arenaGenerator,entities:[],removedIDs:[],cancelled:{true})
check(cancelledRoute.isEmpty,"cancelled route cannot continue navigation work")
print("RPG final: \(checks) total checks passed")

// First save has no old locator: recover a committed orphan instead of a new world.
for checkpoint in RPGSaveCheckpoint.allCases {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("rpg-first-save-"+UUID().uuidString)
    let interrupted=RPGWorldDiskStore(root:root,fault:{if $0==checkpoint{throw InjectedSaveFailure.interruption}})
    do{try await interrupted.save(durableNext);preconditionFailure("first-save fault missing")}catch{checks+=1}
    let reader=RPGWorldDiskStore(root:root)
    let restored=try await reader.load()
    let committed=[RPGSaveCheckpoint.afterPrimary,.beforePointer,.afterPointer].contains(checkpoint)
    check(restored == (committed ? durableNext:nil),"first save either has no committed state or restores exact world and receipts")
    if checkpoint == .afterPrimary || checkpoint == .beforePointer {
        let recovered=await reader.recoveredFromBackup
        check(recovered,"unindexed committed world is reported as recovery")
    }
    try FileManager.default.removeItem(at:root)
}
let ambiguousRoot=FileManager.default.temporaryDirectory.appendingPathComponent("rpg-multiple-orphans-"+UUID().uuidString)
let orphanWriter=RPGWorldDiskStore(root:ambiguousRoot,fault:{if $0 == .beforePointer{throw InjectedSaveFailure.interruption}})
var otherOrphan=durableNext;otherOrphan.id=UUID().uuidString
for value in [durableNext,otherOrphan] {do{try await orphanWriter.save(value)}catch InjectedSaveFailure.interruption{}}
let orphanReader=RPGWorldDiskStore(root:ambiguousRoot)
do{_=try await orphanReader.load();preconditionFailure("multiple orphans silently selected")}catch{check(error as? RPGSaveError == .ambiguous,"multiple retained worlds require explicit selection")}
let options=try await orphanReader.recoverableWorlds()
check(Set(options.map(\.id))==Set([durableNext.id,otherOrphan.id]),"all retained valid worlds are selectable")
let chosen=try await orphanReader.load(id:durableNext.id);try await orphanReader.save(chosen)
let selectedAfterRecovery=try await orphanReader.load()
check(selectedAfterRecovery==durableNext,"selection repairs locator without changing world or receipts")
var replayedRecovery=selectedAfterRecovery!
let priorRecoveryReward=replayedRecovery.inventory["moon-shard"]
try RPGStoryRuntime.advance(world:&replayedRecovery,generator:arenaGenerator)
check(replayedRecovery.inventory["moon-shard"]==priorRecoveryReward,"first-save recovery cannot replay already committed reward")
try FileManager.default.removeItem(at:ambiguousRoot)
let corruptOrphanRoot=FileManager.default.temporaryDirectory.appendingPathComponent("rpg-corrupt-orphan-"+UUID().uuidString)
let corruptOrphanStore=RPGWorldDiskStore(root:corruptOrphanRoot)
try await corruptOrphanStore.save(durableNext)
try FileManager.default.removeItem(at:corruptOrphanRoot.appendingPathComponent("active.json"))
let corruptOrphanPrimary=corruptOrphanRoot.appendingPathComponent("Worlds").appendingPathComponent(durableNext.id).appendingPathComponent("world.json")
try Data("corrupt retained world".utf8).write(to:corruptOrphanPrimary)
do{_=try await corruptOrphanStore.load();preconditionFailure("corrupt unindexed world silently reset")}catch{checks+=1}
let stillCorrupt=try Data(contentsOf:corruptOrphanPrimary)
check(stillCorrupt==Data("corrupt retained world".utf8),"unreadable orphan bytes are preserved")
try FileManager.default.removeItem(at:corruptOrphanRoot)
print("RPG recovery: \(checks) total checks passed")
let oversizedRoot=FileManager.default.temporaryDirectory.appendingPathComponent("rpg-oversized-preserve-"+UUID().uuidString)
let oversizedStore=RPGWorldDiskStore(root:oversizedRoot)
try await oversizedStore.save(durableBase);try await oversizedStore.save(durableNext)
let oversizedPrimary=oversizedRoot.appendingPathComponent("Worlds").appendingPathComponent(durableBase.id).appendingPathComponent("world.json")
let oversizedOriginal=Data(repeating:32,count:RPGWorldCodec.maximumBytes+1)
try oversizedOriginal.write(to:oversizedPrimary)
do{_=try await oversizedStore.load();preconditionFailure("oversized primary silently downgraded")}catch{check(error as? RPGWorldError == .oversized,"oversized primary reported without loading an old backup")}
do{try await oversizedStore.save(durableNext);preconditionFailure("oversized retained file overwritten")}catch{checks+=1}
let oversizedRetained=try Data(contentsOf:oversizedPrimary)
check(oversizedRetained==oversizedOriginal,"unreadable oversized file is not overwritten")
try FileManager.default.removeItem(at:oversizedRoot)

// P11: independent cell content (schema 7).
func cellBinding(_ kind: RPGMediaKind, media: String = "", value: String? = nil) -> MediaBinding {
    var binding = MediaBinding(id: "template", mediaID: media, kind: kind)
    if let value { binding.style = RPGCellStyle(value: value) }
    return binding
}
check(cellBinding(.image, media: "photo").valid && cellBinding(.gif, media: "anim").valid && cellBinding(.video, media: "clip").valid, "library kinds valid")
check(!cellBinding(.image).valid && !cellBinding(.gif).valid, "library kinds need media")
check(cellBinding(.icon, value: "star.fill").valid && cellBinding(.icon, media: "custom-icon", value: "").valid, "symbol or custom icon")
check(!cellBinding(.icon, value: "Star Fill").valid && !cellBinding(.icon).valid && !cellBinding(.icon, media: "x", value: "star").valid, "icon must be exactly one source")
check(cellBinding(.number, value: "42").valid && cellBinding(.number, value: "-3.25").valid, "numbers")
check(!cellBinding(.number, value: "4e2").valid && !cellBinding(.number, value: "").valid && !cellBinding(.number, media: "x", value: "1").valid, "number format")
check(cellBinding(.text, value: "月光").valid && cellBinding(.text, value: "a\nb\nc").valid, "text")
check(!cellBinding(.text, value: "").valid && !cellBinding(.text, value: String(repeating: "字", count: 65)).valid && !cellBinding(.text, value: "a\nb\nc\nd").valid, "text limits")
var badStyle = cellBinding(.text, value: "x"); badStyle.style?.colorHex = "GG0000"; check(!badStyle.valid, "color hex")
badStyle = cellBinding(.text, value: "x"); badStyle.style?.size = 1.5; check(!badStyle.valid, "text size")
badStyle = cellBinding(.text, value: "x"); badStyle.style?.backgroundHex = "12345"; check(!badStyle.valid, "background hex")

let cellGenerator = RPGWorldGenerator(seed: 42)
var cells = WorldState(seed: 42); cells.generated = true; cells.sideRegions = [cellGenerator.sideRegion]; cells.player.mode = .creative
let cellPoints = Array((0..<256).lazy.flatMap { z in (0..<256).lazy.map { SurfacePoint(x: $0, z: z) } }.filter {
    $0 != cells.player.surface && cellGenerator.tile(at: $0)?.passable == true && !cellGenerator.protected($0) &&
    !cellGenerator.sideRegion.contains($0) && RPGWorldEditing.entity(at: $0, world: cells, generator: cellGenerator) == nil
}.prefix(4))
check(cellPoints.count == 4, "four free cells")
try RPGWorldEditing.place(cellPoints.map { .init(point: $0, definitionID: "stone") }, world: &cells, generator: cellGenerator)
let cellIDs = cells.entities.map(\.id)
let contents: [MediaBinding] = [cellBinding(.image, media: "shared-photo"), cellBinding(.icon, value: "moon.stars.fill"), cellBinding(.number, value: "7"), cellBinding(.text, value: "门")]
for (id, content) in zip(cellIDs, contents) { try RPGMediaBindings.assign(content, to: .entity(id), world: &cells, generator: cellGenerator) }
let kinds = cellIDs.map { id in cells.mediaBindings.first { $0.id == cells.entities.first { $0.id == id }?.mediaBindingID }?.kind }
check(kinds == [.image, .icon, .number, .text], "adjacent cells keep their own kinds")
check(Set(cells.entities.compactMap(\.mediaBindingID)).count == 4 && !cells.mediaBindings.contains { $0.id == "template" }, "each cell gets its own binding identity")
check(cells.entities.allSatisfy { $0.definitionID == "stone" }, "content does not change block material")
let beforeEdit = cells
var renamed = cellBinding(.text, value: "窗"); renamed.style?.colorHex = "FFCC00"
try RPGMediaBindings.assign(renamed, to: .entity(cellIDs[3]), world: &cells, generator: cellGenerator)
func content(_ world: WorldState, _ id: String) -> MediaBinding? { world.mediaBindings.first { $0.id == world.entities.first { $0.id == id }?.mediaBindingID } }
check(content(cells, cellIDs[3])?.style?.value == "窗" && content(cells, cellIDs[3])?.style?.colorHex == "FFCC00", "edit one cell")
check(cellIDs.prefix(3).allSatisfy { content(cells, $0) == content(beforeEdit, $0) }, "editing one cell leaves the others alone")
try RPGWorldEditing.undo(world: &cells)
check(content(cells, cellIDs[3])?.style?.value == "门", "content edit is undoable")
try RPGWorldEditing.redo(world: &cells)
try RPGMediaBindings.assign(cellBinding(.image, media: "shared-photo"), to: .entity(cellIDs[1]), world: &cells, generator: cellGenerator)
check(content(cells, cellIDs[0])?.mediaID == content(cells, cellIDs[1])?.mediaID && content(cells, cellIDs[0])?.id != content(cells, cellIDs[1])?.id, "one library file on two cells")
try RPGMediaBindings.clear(.entity(cellIDs[2]), world: &cells)
check(content(cells, cellIDs[2]) == nil && cells.entities.contains { $0.id == cellIDs[2] }, "clearing content keeps the block")
let reopened = try RPGWorldCodec.decode(RPGWorldCodec.encode(cells))
check(reopened == cells, "cell contents survive save and reload")
editRejected("invalid content not bound") { try RPGMediaBindings.assign(cellBinding(.number, value: "abc"), to: .entity(cellIDs[0]), world: &cells, generator: cellGenerator) }

// Schema 6 files (no style/fit/paused keys) open unchanged.
var legacy = try JSONSerialization.jsonObject(with: RPGWorldCodec.encode(beforeEdit.withoutCellStyles())) as! [String: Any]
legacy["schemaVersion"] = 6
let legacyWorld = try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject: legacy))
check(legacyWorld.schemaVersion == 7 && legacyWorld.mediaBindings.count == beforeEdit.withoutCellStyles().mediaBindings.count && legacyWorld.mediaBindings.allSatisfy { $0.fit == nil && $0.paused == nil }, "schema 6 media bindings migrate")
var future = legacy; future["schemaVersion"] = 8
do { _ = try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject: future)); preconditionFailure("future schema accepted") } catch { check(error as? RPGWorldError == .unsupportedVersion, "schema 8 rejected") }

// Shared blocks show the same content in both projections.
var dualCells = WorldState(seed: 42); dualCells.generated = true; dualCells.sideRegions = [cellGenerator.sideRegion]; dualCells.player.mode = .creative; dualCells.player.surface = cellGenerator.anchor(.temple)
let rowPoint = (0..<cellGenerator.sideRegion.width).map { SurfacePoint(x: cellGenerator.sideRegion.origin.x + $0, z: cellGenerator.sideRegion.origin.z) }.first {
    $0 != dualCells.player.surface && cellGenerator.tile(at: $0)?.passable == true && !cellGenerator.protected($0) && RPGWorldEditing.entity(at: $0, world: dualCells, generator: cellGenerator) == nil
}!
try RPGWorldEditing.place([.init(point: rowPoint, definitionID: "wood")], world: &dualCells, generator: cellGenerator)
let rowID = dualCells.entities[0].id
try RPGMediaBindings.assign(cellBinding(.gif, media: "anim"), to: .entity(rowID), world: &dualCells, generator: cellGenerator)
let sideCopy = RPGProjectionRules.sideEntities(world: dualCells, generator: cellGenerator).first { $0.id == rowID }
check(sideCopy?.mediaBindingID == dualCells.entities[0].mediaBindingID && sideCopy?.mediaBindingID != nil, "side view shares the cell content")

// Unreferenced bindings are pruned; anything still referenced stays.
var crowded = cells
let referenced = Set(crowded.entities.compactMap(\.mediaBindingID))
let undoReferenced = Set(crowded.undo.flatMap { $0.changes.flatMap { [$0.before?.mediaBindingID, $0.after?.mediaBindingID] } }.compactMap { $0 })
for index in 0..<970 { crowded.mediaBindings.append(MediaBinding(id: "orphan-\(index)", mediaID: "x", kind: .image)) }
try RPGMediaBindings.assign(cellBinding(.number, value: "9"), to: .entity(cellIDs[2]), world: &crowded, generator: cellGenerator)
let kept = Set(crowded.mediaBindings.map(\.id))
check(!kept.contains { $0.hasPrefix("orphan-") }, "orphans pruned near limit")
check(referenced.isSubset(of: kept) && undoReferenced.isSubset(of: kept), "referenced and undo bindings kept")
check(content(crowded, cellIDs[2])?.style?.value == "9", "assign succeeds after pruning")
print("RPG cell content: \(checks) total checks passed")

print("RPG complete: \(checks) total checks passed")
