import Foundation
// Domain titles are bilingual; these checks read the Chinese ones.
UserDefaults.standard.set("zh", forKey: "moonlight.language")
#if canImport(CoreGraphics)
import CoreGraphics
#endif

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
check(legacyWorld.schemaVersion == WorldState.currentSchema && legacyWorld.mediaBindings.count == beforeEdit.withoutCellStyles().mediaBindings.count && legacyWorld.mediaBindings.allSatisfy { $0.fit == nil && $0.paused == nil }, "schema 6 media bindings migrate")
var future = legacy; future["schemaVersion"] = WorldState.currentSchema + 1
do { _ = try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject: future)); preconditionFailure("future schema accepted") } catch { check(error as? RPGWorldError == .unsupportedVersion, "future schema rejected") }

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


// P12: GIF timing.
let gifDelays = [0.1, 0.2, 0.3]
check(RPGGIFTiming.frameIndex(elapsed: 0, delays: gifDelays, loop: true) == 0, "gif starts at frame 0")
check(RPGGIFTiming.frameIndex(elapsed: 0.15, delays: gifDelays, loop: true) == 1, "gif second frame")
check(RPGGIFTiming.frameIndex(elapsed: 0.35, delays: gifDelays, loop: true) == 2, "gif third frame")
check(RPGGIFTiming.frameIndex(elapsed: 0.65, delays: gifDelays, loop: true) == 0, "gif loops")
check(RPGGIFTiming.frameIndex(elapsed: 0.65, delays: gifDelays, loop: false) == 2, "gif without loop holds last frame")
check(RPGGIFTiming.frameIndex(elapsed: 1000.15, delays: gifDelays, loop: true) == 2 && (0..<3).contains(RPGGIFTiming.frameIndex(elapsed: 123456.789, delays: gifDelays, loop: true)), "long-running gif stays in range")
check(RPGGIFTiming.frameIndex(elapsed: .nan, delays: gifDelays, loop: true) == 0 && RPGGIFTiming.frameIndex(elapsed: 1, delays: [], loop: true) == 0, "gif bad input")
check(RPGGIFTiming.normalizedDelay(0.005) == 0.1 && RPGGIFTiming.normalizedDelay(nil) == 0.1 && RPGGIFTiming.normalizedDelay(0.04) == 0.04 && RPGGIFTiming.normalizedDelay(99) == 10, "gif delay normalisation")
check(abs(RPGGIFTiming.offset(of: 2, delays: gifDelays) - 0.3) < 1e-9 && RPGGIFTiming.offset(of: 0, delays: gifDelays) == 0 && abs(RPGGIFTiming.offset(of: 9, delays: gifDelays) - 0.6) < 1e-9, "gif resume offset")
for index in 0..<3 { check(RPGGIFTiming.frameIndex(elapsed: RPGGIFTiming.offset(of: index, delays: gifDelays) + 0.001, delays: gifDelays, loop: true) == index, "pause resumes on the same frame") }
print("RPG gif timing: \(checks) total checks passed")


// P13: glass lab policy.
let calm = RPGGlassConditions()
check(RPGGlassPolicy.resolve(.selected, nearest: 64, calm).render == .selectedOnly && RPGGlassPolicy.resolve(.texture, nearest: 64, calm).render == .texture, "non-native modes pass through")
check(RPGGlassPolicy.resolve(.nativeMerged, nearest: 64, calm).render == .nativeMerged && RPGGlassPolicy.resolve(.nativeNearest, nearest: 64, calm).render == .nativeNearest(64), "native modes when calm")
check(RPGGlassPolicy.resolve(.nativeNearest, nearest: 999, calm).render == .nativeNearest(256) && RPGGlassPolicy.resolve(.nativeNearest, nearest: 0, calm).render == .nativeNearest(1), "nearest count clamped")
var harsh = calm; harsh.nativeAvailable = false
check(RPGGlassPolicy.resolve(.nativeMerged, nearest: 64, harsh).render == .texture && RPGGlassPolicy.resolve(.nativeMerged, nearest: 64, harsh).reason != nil, "no native glass before iOS 26")
for change in [{ (c: inout RPGGlassConditions) in c.lowPower = true }, { $0.thermal = 2 }, { $0.thermal = 3 }, { $0.reduceTransparency = true }, { $0.cameraMoving = true }] {
    var conditions = calm; change(&conditions)
    let result = RPGGlassPolicy.resolve(.nativeNearest, nearest: 16, conditions)
    check(result.render == .texture && result.reason != nil, "native downgrades to texture with a reason")
    check(RPGGlassPolicy.resolve(.selected, nearest: 16, conditions).render == .selectedOnly, "default mode never downgraded")
}
var warm = calm; warm.thermal = 1
check(RPGGlassPolicy.resolve(.nativeMerged, nearest: 16, warm).render == .nativeMerged, "fair thermal state keeps native glass")
let grid = RPGGlassPolicy.gridCells(bounds: CGSize(width: 100, height: 50), corner: CGPoint(x: 7, y: 3), cell: 24)
check(!grid.isEmpty && grid.allSatisfy { $0.width == 24 && $0.height == 24 }, "grid cells sized")
check(grid.contains { $0.minX == 7 && $0.minY == 3 }, "grid aligned to the scene corner")
check(grid.contains { $0.minX <= 0 && $0.maxX > 0 } && grid.contains { $0.maxX >= 100 } && grid.contains { $0.maxY >= 50 }, "grid covers every edge")
check(Set(grid.map { "\($0.minX),\($0.minY)" }).count == grid.count, "grid has no duplicate cells")
check(RPGGlassPolicy.gridCells(bounds: CGSize(width: 100, height: 50), corner: CGPoint(x: -1000.5, y: 9999), cell: 24).allSatisfy { $0.maxX > 0 && $0.maxY > 0 && $0.minX < 100 && $0.minY < 50 }, "far corners still produce on-screen cells")
check(RPGGlassPolicy.gridCells(bounds: CGSize(width: 10000, height: 10000), corner: .zero, cell: 4, limit: 2048).count == 2048, "grid capped")
check(RPGGlassPolicy.gridCells(bounds: CGSize(width: 100, height: 50), corner: .zero, cell: 2).isEmpty && RPGGlassPolicy.gridCells(bounds: .zero, corner: .zero, cell: 24).isEmpty, "degenerate grid empty")
let phoneGrid = RPGGlassPolicy.gridCells(bounds: CGSize(width: 874, height: 402), corner: CGPoint(x: 5, y: 11), cell: 24)
check((600...800).contains(phoneGrid.count), "landscape phone shows roughly 600-800 cells (\(phoneGrid.count))")
let closest = RPGGlassPolicy.nearest(phoneGrid, to: CGPoint(x: 437, y: 201), count: 16)
check(closest.count == 16 && closest.contains { $0.contains(CGPoint(x: 437, y: 201)) }, "nearest starts at the player's cell")
let farthestPicked = closest.map { hypot($0.midX - 437, $0.midY - 201) }.max()!
check(phoneGrid.filter { !closest.contains($0) }.allSatisfy { hypot($0.midX - 437, $0.midY - 201) >= farthestPicked }, "nearest really is nearest")
check(RPGGlassPolicy.nearest(phoneGrid, to: .zero, count: 16) == RPGGlassPolicy.nearest(phoneGrid.reversed(), to: .zero, count: 16), "nearest is deterministic")
check(RPGGlassPolicy.nearest(phoneGrid, to: .zero, count: 5000).count == phoneGrid.count, "nearest never exceeds the grid")
var lab = RPGFrameMetrics(); lab.sample(1); lab.sample(1.1); lab.reset()
check(lab.count == 0 && lab.totalFrames == 0 && lab.hitches == 0, "frame metrics reset for a new sample")
let sampleLine = RPGGlassSample(id: 1, mode: .nativeNearest, nearest: 64, effective: "nativeNearest:64", seconds: 60, averageFramesPerSecond: 29.5, measuredSeconds: 58, nativeSeconds: 31, framesPerSecond: 59.9, p95Milliseconds: 17.2, hitches: 1, frames: 3594, memoryMB: 210, thermalStart: 0, thermalEnd: 1, device: "iPhone17,1").line
check(sampleLine.contains("N=64") && sampleLine.contains("全程 FPS 29.5") && sampleLine.contains("近 10 秒 FPS 59.9") && sampleLine.contains("原生玻璃 31/58 秒") && sampleLine.contains("正常→温热"), "sample summary line")
// 100 slow frames (30 fps) followed by 600 fast ones (60 fps).
var whole = RPGFrameMetrics(); var clock = 0.0
for frame in 0...700 { whole.sample(clock); clock += frame < 100 ? 1.0 / 30 : 1.0 / 60 }
check(whole.totalFrames == 700 && abs(whole.sampledSeconds - (100.0 / 30 + 600.0 / 60)) < 0.001, "whole-window seconds")
check(abs(whole.averageFramesPerSecond - 52.5) < 0.1, "whole-window FPS includes the slow start")
check(whole.averageFramesPerSecond < whole.framesPerSecond && abs(whole.framesPerSecond - 60) < 0.5, "average differs from the recent window when the start was slow")
whole.pause(); whole.sample(1000); whole.sample(1000 + 1.0/60)
check(whole.totalFrames == 701 && whole.sampledSeconds < 13.4, "pauses are not counted as measured time")
let selectedLine = RPGGlassSample(id: 2, mode: .texture, nearest: 64, effective: "texture", seconds: 60, averageFramesPerSecond: 60, measuredSeconds: 60, nativeSeconds: 0, framesPerSecond: 60, p95Milliseconds: 16.7, hitches: 0, frames: 3600, memoryMB: nil, thermalStart: 0, thermalEnd: 0, device: "iPhone").line
check(!selectedLine.contains("原生玻璃"), "non-native samples omit native time")
print("RPG glass lab: \(checks) total checks passed")


// P14: map editor rules.
check(RPGEditorMode.free.gameMode == .creative && RPGEditorMode.character.gameMode == .adventure, "editor modes map onto existing edit rules")
check(RPGCameraRules.clampZoom(0.1) == RPGCameraRules.minZoom && RPGCameraRules.clampZoom(9) == RPGCameraRules.maxZoom && RPGCameraRules.clampZoom(.nan) == 1 && RPGCameraRules.clampZoom(1.5) == 1.5, "zoom clamped")
check(RPGCameraRules.clampCenter(CGPoint(x: -50, y: 99999)) == CGPoint(x: 0, y: RPGCameraRules.worldSide), "camera stays on the map")
check(RPGCameraRules.cell(at: CGPoint(x: 24 * 10 + 1, y: 24 * 7 + 23)) == SurfacePoint(x: 10, z: 7), "scene point to cell")
check(RPGCameraRules.cell(at: CGPoint(x: -1, y: 5)) == nil && RPGCameraRules.cell(at: CGPoint(x: RPGCameraRules.worldSide + 1, y: 5)) == nil && RPGCameraRules.cell(at: CGPoint(x: CGFloat.nan, y: 1)) == nil, "off-map points have no cell")
check(RPGCameraRules.panTranslation(viewDelta: CGPoint(x: 10, y: 10), zoom: 2) == CGPoint(x: -20, y: 20), "map follows the finger at any zoom")
check(RPGCameraRules.chunkRadius(zoom: 1) == 1 && RPGCameraRules.chunkRadius(zoom: 2) == 2, "more chunks when zoomed out")
let ringGenerator = RPGWorldGenerator(seed: 42)
check(ringGenerator.priorityChunks(around: SurfacePoint(x: 128, z: 128)).count == 9 && ringGenerator.priorityChunks(around: SurfacePoint(x: 128, z: 128), radius: 2).count == 25, "chunk rings")
check(ringGenerator.priorityChunks(around: SurfacePoint(x: 0, z: 0), radius: 2).count == 9 && ringGenerator.priorityChunks(around: SurfacePoint(x: 128, z: 128), radius: 2).first == ChunkCoordinate(x: 4, z: 4), "rings clipped at the edge, nearest first")
check(ringGenerator.priorityChunks(around: SurfacePoint(x: 128, z: 128), radius: 99).count == 64 && ringGenerator.priorityChunks(around: SurfacePoint(x: -5, z: 0)).isEmpty, "ring radius bounded")
let worldSideCells = Int(RPGCameraRules.worldSide / RPGCameraRules.cell)
check(worldSideCells == WorldGeometry.width, "camera rules match the 256 map")
check(RPGSaveState.failed("x").title == "保存失败" && RPGSaveState.saving.title == "保存中…", "save state titles")
print("RPG map editor: \(checks) total checks passed")


// P15: drafts, terrain, schema 8 and undo budget.
var map = WorldState(seed: 42); map.generated = true; map.sideRegions = [ringGenerator.sideRegion]; map.player.mode = .creative
let mapGen = ringGenerator
let freeRow = Array((0..<256).lazy.flatMap { z in (0..<256).lazy.map { SurfacePoint(x: $0, z: z) } }.filter {
    $0 != map.player.surface && mapGen.tile(at: $0)?.passable == true && !mapGen.protected($0) && !mapGen.sideRegion.contains($0) &&
    RPGWorldEditing.entity(at: $0, world: map, generator: mapGen) == nil
}.prefix(12))
check(freeRow.count == 12, "free cells for drafts")
var draft = RPGEditDraft(payload: .block("stone"))
draft.add(Array(freeRow.prefix(6))); draft.add(Array(freeRow.prefix(3)))
check(draft.count == 6, "draft cells counted once")
let untouched = map
let plan = RPGDraftCommit.plan(draft, world: map, generator: mapGen)
check(plan.cells.count == 6 && plan.skippedTotal == 0 && map == untouched, "planning never changes the world")
try RPGDraftCommit.commit(draft, world: &map, generator: mapGen)
check(map.entities.count == 6 && map.undo.count == 1 && map.undo[0].changes.count == 6, "a whole stroke is one transaction")
var again = RPGEditDraft(payload: .block("wood")); again.add(Array(freeRow.prefix(8)))
let overlap = RPGDraftCommit.plan(again, world: map, generator: mapGen)
check(overlap.cells.count == 2 && overlap.skipped[.occupied] == 6 && overlap.summary.contains("已有方块 6"), "occupied cells skipped and reported")
try RPGWorldEditing.undo(world: &map)
check(map.entities.isEmpty, "undo removes the whole stroke")
try RPGWorldEditing.redo(world: &map)
check(map.entities.count == 6, "redo restores it")
// Stroke interpolation: a fast swipe fills the cells in between.
var swipe = RPGEditDraft(payload: .erase); swipe.addStroke(from: SurfacePoint(x: 10, z: 10), to: SurfacePoint(x: 20, z: 10))
check(swipe.count == 11, "fast stroke fills gaps")
var box = RPGEditDraft(payload: .erase); box.setRectangle(SurfacePoint(x: 250, z: 250), SurfacePoint(x: 300, z: 300))
check(box.count == 36, "rectangles clipped to the map")
var huge = RPGEditDraft(payload: .erase); huge.setRectangle(SurfacePoint(x: 0, z: 0), SurfacePoint(x: 100, z: 100))
check(huge.count == RPGWorldEditing.maximumBatch && huge.truncated, "draft capped at the batch limit")
// Content brush: existing blocks keep their identity; empty cells get display cells.
var paint = RPGEditDraft(payload: .content(cellBinding(.text, value: "月")))
paint.add(Array(freeRow.prefix(8)))
try RPGDraftCommit.commit(paint, world: &map, generator: mapGen)
let painted = freeRow.prefix(8).compactMap { RPGWorldEditing.entity(at: $0, world: map, generator: mapGen) }
check(painted.count == 8 && painted.filter { $0.definitionID == RPGWorldEditing.displayDefinition }.count == 2, "display cells only where empty")
check(Set(painted.compactMap(\.mediaBindingID)).count == 1 && map.mediaBindings.contains { $0.style?.value == "月" }, "stroke shares one binding")
check(BlockDefinition.find(RPGWorldEditing.displayDefinition)?.solid == false, "display cells are walk-through")
try RPGMediaBindings.assign(cellBinding(.number, value: "8"), to: .entity(painted[0].id), world: &map, generator: mapGen)
check(content(map, painted[0].id)?.style?.value == "8" && content(map, painted[1].id)?.style?.value == "月", "editing one painted cell leaves the others")
try RPGWorldEditing.undo(world: &map); try RPGWorldEditing.undo(world: &map)
check(map.entities.count == 6 && map.entities.allSatisfy { $0.mediaBindingID == nil }, "content stroke undone as one")
// Terrain.
let roadCell = freeRow[10]
var terrainDraft = RPGEditDraft(payload: .terrain(.water)); terrainDraft.add([roadCell, map.player.surface])
let terrainPlan = RPGDraftCommit.plan(terrainDraft, world: map, generator: mapGen)
check(terrainPlan.cells == [roadCell] && terrainPlan.skippedTotal == 1, "player cell skipped")
var onPlayer = map; onPlayer.player.surface = freeRow[9]
var underPlayer = RPGEditDraft(payload: .terrain(.water)); underPlayer.add([freeRow[9]])
check(RPGDraftCommit.plan(underPlayer, world: onPlayer, generator: mapGen).skipped[.player] == 1, "water never painted under the player")
try RPGDraftCommit.commit(terrainDraft, world: &map, generator: mapGen)
check(RPGWorldTerrain.tile(at: roadCell, world: map, generator: mapGen) == .water && !RPGWorldTerrain.passable(roadCell, world: map, generator: mapGen), "terrain override applies")
editRejected("cannot build on painted water") { try RPGWorldEditing.place([.init(point: roadCell, definitionID: "stone")], world: &map, generator: mapGen) }
let terrainSaved = try RPGWorldCodec.decode(RPGWorldCodec.encode(map))
check(terrainSaved.terrainOverrides == map.terrainOverrides && terrainSaved.undo.last?.terrainChanges?.count == 1, "terrain and its history survive saving")
try RPGWorldEditing.undo(world: &map)
check(map.terrainOverrides == nil && RPGWorldTerrain.tile(at: roadCell, world: map, generator: mapGen) == mapGen.tile(at: roadCell), "terrain undo restores generated ground")
try RPGWorldEditing.redo(world: &map)
var back = RPGEditDraft(payload: .terrain(mapGen.tile(at: roadCell)!)); back.add([roadCell])
try RPGDraftCommit.commit(back, world: &map, generator: mapGen)
check(map.terrainOverrides == nil, "painting the original terrain clears the override")
var same = RPGEditDraft(payload: .terrain(mapGen.tile(at: roadCell)!)); same.add([roadCell])
check(RPGDraftCommit.plan(same, world: map, generator: mapGen).skipped[.unchanged] == 1, "no-op terrain cells skipped")
// Protected cells and character build range.
let protectedCell = (0..<256).lazy.flatMap { z in (0..<256).lazy.map { SurfacePoint(x: $0, z: z) } }.first { mapGen.protected($0) }!
var guarded = RPGEditDraft(payload: .terrain(.water)); guarded.add([protectedCell])
check(RPGDraftCommit.plan(guarded, world: map, generator: mapGen).skipped[.protected] == 1, "protected story cells never edited")
var character = map; character.player.mode = .adventure
var far = RPGEditDraft(payload: .erase); far.add(Array(freeRow.prefix(6)))
if RPGDraftCommit.plan(far, world: character, generator: mapGen).outOfRange > 0 {
    let before = character
    editRejected("character build refuses out-of-range drafts") { try RPGDraftCommit.commit(far, world: &character, generator: mapGen) }
    check(character == before, "refused draft leaves the world as it was")
}
// Erase: no drops, no story events, undoable.
let inventoryBeforeErase = map.inventory, eventsBeforeErase = map.events
var wipe = RPGEditDraft(payload: .erase); wipe.add(Array(freeRow.prefix(6)))
try RPGDraftCommit.commit(wipe, world: &map, generator: mapGen)
check(map.entities.isEmpty && map.inventory == inventoryBeforeErase && map.events == eventsBeforeErase, "editor erase gives no drops or events")
try RPGWorldEditing.undo(world: &map)
check(map.entities.count == 6, "erase undone")
// Same-type replace keeps content in one transaction.
try RPGMediaBindings.assign(cellBinding(.icon, value: "star.fill"), to: .entity(map.entities[0].id), world: &map, generator: mapGen)
var swap = RPGEditDraft(payload: .replace(from: "stone", to: "wood")); swap.add(Array(freeRow.prefix(6)))
let undoDepth = map.undo.count
try RPGDraftCommit.commit(swap, world: &map, generator: mapGen)
check(map.entities.count == 6 && map.entities.allSatisfy { $0.definitionID == "wood" } && map.undo.count == undoDepth + 1, "replace in one transaction")
check(map.entities.contains { content(map, $0.id)?.style?.value == "star.fill" }, "replace keeps content")
try RPGWorldEditing.undo(world: &map)
check(map.entities.allSatisfy { $0.definitionID == "stone" }, "replace undone")
// Paste preview.
let copied = try RPGWorldEditing.copy(from: freeRow[0], to: freeRow[0], world: map, generator: mapGen)
var pasteDraft = RPGEditDraft(payload: .paste(copied)); pasteDraft.add([freeRow[11]])
let pastePlan = RPGDraftCommit.plan(pasteDraft, world: map, generator: mapGen)
check(pastePlan.cells == [freeRow[11]], "paste footprint previewed")
try RPGDraftCommit.commit(pasteDraft, world: &map, generator: mapGen)
check(RPGWorldEditing.entity(at: freeRow[11], world: map, generator: mapGen)?.definitionID == "stone", "paste committed")
// Undo history: depth and change budget.
var history: [RPGEditTransaction] = (0..<70).map { RPGEditTransaction(id: "t\($0)", changes: [], inventoryBefore: [:], inventoryAfter: [:], title: "t", terrainChanges: [.init(point: SurfacePoint(x: 1, z: 1), before: nil, after: .sand)]) }
check(RPGWorldEditing.trimmedHistory(history).count == RPGWorldEditing.undoLimit && RPGWorldEditing.trimmedHistory(history).last?.id == "t69", "undo depth 50, newest kept")
history = (0..<20).map { index in RPGEditTransaction(id: "big\(index)", changes: [], inventoryBefore: [:], inventoryAfter: [:], title: "t", terrainChanges: (0..<1000).map { .init(point: SurfacePoint(x: $0 % 256, z: $0 / 256), before: nil, after: .sand) }) }
check(RPGWorldEditing.trimmedHistory(history).count == 8, "change budget limits large histories")
check(RPGWorldEditing.trimmedHistory([history[0]]).count == 1, "the latest transaction is always kept")
// Schema 7 worlds open; old terrain-less transactions still replay.
var schema7 = try JSONSerialization.jsonObject(with: RPGWorldCodec.encode(untouched)) as! [String: Any]
schema7["schemaVersion"] = 7; schema7["terrainOverrides"] = nil
let reopened7 = try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject: schema7))
check(reopened7.schemaVersion == WorldState.currentSchema && reopened7.terrainOverrides == nil, "schema 7 opens as current")
var badTerrain = map; badTerrain.terrainOverrides = ["999,1": .sand]; rejected(badTerrain, "terrain keys must be on the map")
print("RPG drafts: \(checks) total checks passed")


// P16: playback priority, hysteresis and budget.
let near = RPGMediaRequest(ownerID: "b", mediaID: "near", role: .interactive, visible: true, distance: 10)
let farAway = RPGMediaRequest(ownerID: "a", mediaID: "far", role: .interactive, visible: true, distance: 500)
var pickedCell = RPGMediaRequest(ownerID: "z", mediaID: "pickedCell", role: .interactive, visible: true, distance: 900); pickedCell.selected = true
check(RPGMediaPolicy.schedule([farAway, near], limit: 2) == ["near", "far"], "nearer cells first")
check(RPGMediaPolicy.schedule([farAway, near, pickedCell], limit: 2) == ["pickedCell", "near"], "selected cell first, then nearest")
check(RPGMediaPolicy.schedule([farAway, near, pickedCell], limit: 1) == ["pickedCell"], "budget respected")
let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)
let edge = CGRect(x: 110, y: 10, width: 20, height: 20)
check(!RPGMediaVisibility.visible(frame: edge, viewport: viewport, wasVisible: false, margin: 48), "off-screen cells do not start")
check(RPGMediaVisibility.visible(frame: edge, viewport: viewport, wasVisible: true, margin: 48), "cells just off screen keep playing")
check(!RPGMediaVisibility.visible(frame: edge.offsetBy(dx: 100, dy: 0), viewport: viewport, wasVisible: true, margin: 48), "cells well off screen stop")
check(RPGMediaVisibility.budget(base: 2, autoplay: true, reduceMotion: false, lowPower: false, cameraSettled: true) == 2, "full budget")
check(RPGMediaVisibility.budget(base: 2, autoplay: true, reduceMotion: false, lowPower: true, cameraSettled: true) == 1, "low power keeps one")
check(RPGMediaVisibility.budget(base: 2, autoplay: false, reduceMotion: false, lowPower: false, cameraSettled: true) == 0 && RPGMediaVisibility.budget(base: 2, autoplay: true, reduceMotion: true, lowPower: false, cameraSettled: true) == 0, "autoplay off or reduce motion: covers")
check(RPGMediaVisibility.budget(base: 2, autoplay: true, reduceMotion: false, lowPower: false, cameraSettled: false) == 0, "moving camera: covers")
check(RPGMediaVisibility.moved(from: (CGPoint(x: 0, y: 0), 1), to: (CGPoint(x: 5, y: 0), 1)) && !RPGMediaVisibility.moved(from: (CGPoint(x: 0, y: 0), 1), to: (CGPoint(x: 1, y: 1), 1)) && RPGMediaVisibility.moved(from: (.zero, 1), to: (.zero, 1.2)), "camera movement detection")
print("RPG playback: \(checks) total checks passed")


// P17: editor tools and areas.
check(RPGEditorTool.allCases.count == 14 && RPGEditorTool.text.contentKind == .text && RPGEditorTool.brush.contentKind == nil, "thirteen tools (shape added), content tools map to kinds")
check(RPGEditorTool.allCases.filter(\.draws) == [.shape, .terrain, .erase, .brush] && RPGEditorTool.allCases.filter(\.drawsRectangle) == [.multi, .fill], "drawing tools")
let area = RPGArea(a: SurfacePoint(x: 5, z: 9), b: SurfacePoint(x: 2, z: 7))
check(area.count == 12 && area.cells.count == 12 && area.origin == SurfacePoint(x: 2, z: 7), "area size and origin")
print("RPG tools: \(checks) total checks passed")


// P18: bilingual titles.
UserDefaults.standard.set("en", forKey: L10n.key)
check(RPGEditorTool.brush.title == "Brush" && RPGEditorMode.free.title == "Free Edit" && RPGTerrain.water.title == "Water" && RPGSaveState.saved.title == "Saved", "English titles")
check(BlockDefinition.find("stone")?.name == "Stone" && RPGMediaKind.gif.title == "GIF" && RPGEditError.tooLarge.errorDescription == "At most 1024 cells at once.", "English names and errors")
var englishPlan = RPGDraftPlan(); englishPlan.cells = [SurfacePoint(x: 1, z: 1)]; englishPlan.skipped[.occupied] = 2
check(englishPlan.summary == "1 cells; skipped occupied 2", "English draft summary")
UserDefaults.standard.set("zh", forKey: L10n.key)
check(RPGEditorTool.brush.title == "画笔" && BlockDefinition.find("stone")?.name == "石块" && englishPlan.summary == "影响 1 格，跳过 已有方块 2", "back to Chinese")
UserDefaults.standard.removeObject(forKey: L10n.key)
check(L10n.language == .zh && !L10n.isEnglish, "Chinese by default")
UserDefaults.standard.set("zh", forKey: L10n.key)
print("RPG languages: \(checks) total checks passed")


// P19: chunks cover the screen.
let wideScreen = RPGCameraRules.chunks(center: CGPoint(x: 20 * 24, y: 5 * 24), viewSize: CGSize(width: 874, height: 402), zoom: 1)
check(Set(wideScreen) == Set([ChunkCoordinate(x: 0, z: 0), ChunkCoordinate(x: 1, z: 0)]) && wideScreen.first == ChunkCoordinate(x: 0, z: 0), "landscape view near the map edge loads both chunks it shows")
let zoomedOut = RPGCameraRules.chunks(center: CGPoint(x: 128 * 24, y: 128 * 24), viewSize: CGSize(width: 874, height: 402), zoom: 2.2)
let coveredCells = (zoomedOut.map(\.x).max()! - zoomedOut.map(\.x).min()! + 1) * 32
check(CGFloat(coveredCells) * 24 >= 874 * 2.2, "zoomed out view fully covered (\(zoomedOut.count) chunks)")
check(RPGCameraRules.chunks(center: .zero, viewSize: .zero, zoom: 1).isEmpty, "empty view loads nothing")
print("RPG coverage: \(checks) total checks passed")


// P20: curved cell outlines and the glass shape editor model.
for template in ShapeTemplate.allCases {
    let outline = template.outline
    check(outline.valid && !outline.selfIntersects && outline.cubics.count == outline.anchors.count, "template \(template.rawValue) is a valid closed outline")
}
let circle = ShapeTemplate.circle.outline
check(circle.contains(ShapePoint(0.5, 0.5)) && !circle.contains(ShapePoint(0.02, 0.02)), "circle contains its centre, not its corner")
check(abs(circle.cubics[0].point(at: 0.5).distance(to: ShapePoint(0.5, 0.5)) - 0.46) < 0.003, "circle segments stay on the radius")
var edited = circle
let splitAt = edited.cubics[0].point(at: 0.5)
check(edited.insertAnchor(at: splitAt) == 1 && edited.anchors.count == 5, "tapping on the outline adds an anchor")
check(edited.cubics[0].point(at: 1).distance(to: splitAt) < 1e-9 && edited.cubics[0].point(at: 0.5).distance(to: circle.cubics[0].point(at: 0.25)) < 1e-9, "splitting keeps the curve unchanged")
check(edited.removeAnchor(1) && edited.anchors.count == 4, "remove an anchor")
var triangle = ShapeOutline(anchors: [ShapeAnchor(ShapePoint(0.5, 0.1)), ShapeAnchor(ShapePoint(0.9, 0.9)), ShapeAnchor(ShapePoint(0.1, 0.9))])
check(!triangle.removeAnchor(0) && triangle.anchors.count == 3, "never fewer than 3 anchors")
check(triangle.moveAnchor(0, to: ShapePoint(0.5, -0.4)) && triangle.anchors[0].point == ShapePoint(0.5, 0), "anchors stay inside 0–1")
check(edited.moveAnchor(0, to: ShapePoint(0.5, 0.2)) && edited.anchors[0].handleOut.y == edited.anchors[0].point.y, "handles move with their anchor")
edited.anchors[1].smooth = true
check(edited.moveHandle(1, .outgoing, to: ShapePoint(0.96, 0.7)), "drag a handle")
let mirrored = edited.anchors[1]
check(abs(mirrored.handleIn.distance(to: mirrored.point) - mirrored.handleOut.distance(to: mirrored.point)) < 1e-9, "smooth anchors keep symmetric handles")
edited.toggleSmooth(1)
check(!edited.anchors[1].smooth && edited.moveHandle(1, .outgoing, to: ShapePoint(0.9, 0.9)) && edited.anchors[1].handleIn == mirrored.handleIn, "corner handles move independently")
triangle.toggleSmooth(1)
check(triangle.anchors[1].smooth && triangle.anchors[1].handleIn != triangle.anchors[1].point && triangle.valid, "a bare corner gets handles when made smooth")
let bowtie = ShapeOutline(anchors: [ShapeAnchor(ShapePoint(0.1, 0.1)), ShapeAnchor(ShapePoint(0.9, 0.9)), ShapeAnchor(ShapePoint(0.9, 0.1)), ShapeAnchor(ShapePoint(0.1, 0.9))])
check(bowtie.selfIntersects, "self-intersection detected")
check(!ShapeTemplate.star.outline.sharpCorners(below: 60).isEmpty && ShapeTemplate.circle.outline.sharpCorners().isEmpty, "sharp corners warned, round ones not")
check(edited.snapped(ShapePoint(0.333, 0.67), step: 0.05) == ShapePoint(0.35, 0.65), "grid snap")
var tooMany = ShapeTemplate.star.outline
for _ in 0..<30 { tooMany.insertAnchor(at: ShapePoint(0.5, 0.05)) }
check(tooMany.anchors.count == ShapeOutline.maximumAnchors, "anchor count capped")
// Undo history: one entry per gesture, capped.
var shapeDoc = ShapeDocument(name: "水滴 Drop", outline: ShapeTemplate.droplet.outline)
var shapeHistory = ShapeHistory()
for step in 0..<80 { shapeHistory.record(shapeDoc); shapeDoc.outline.moveAnchor(0, to: ShapePoint(0.5, Double(step % 10) / 100)) }
check(shapeHistory.past.count == ShapeHistory.limit && ShapeHistory.limit >= 50, "at least 50 undo steps kept")
let beforeUndo = shapeDoc
if let previous = shapeHistory.undo(shapeDoc) { shapeDoc = previous }
if let next = shapeHistory.redo(shapeDoc) { shapeDoc = next }
check(shapeDoc == beforeUndo && shapeHistory.canUndo && !shapeHistory.canRedo, "undo then redo returns to the same shape")
// Library.
var library = ShapeLibrary(); library.upsert(shapeDoc)
let copyDoc = library.duplicate(shapeDoc.id, suffix: " 副本")
check(library.shapes.count == 2 && library.currentID == copyDoc?.id && copyDoc?.outline == shapeDoc.outline, "duplicate a shape")
library.remove(copyDoc!.id)
let libraryData = try JSONEncoder().encode(library)
check(ShapeLibrary.decode(libraryData) == library && library.currentID == shapeDoc.id, "library round trip")
// Export.
check(ShapeCodeExporter.typeName("水滴 Drop") == "DropShape" && ShapeCodeExporter.typeName("3 waves") == "Glass3WavesShape" && ShapeCodeExporter.typeName("") == "GlassShape", "Swift type names")
check(ShapeCodeExporter.number(0.5) == "0.5" && ShapeCodeExporter.number(1) == "1" && ShapeCodeExporter.number(0.123456) == "0.1235" && ShapeCodeExporter.number(-0.00001) == "0", "number formatting")
shapeDoc.tintHex = "FF8000"; shapeDoc.interactive = true
let swiftCode = ShapeCodeExporter.swift(shapeDoc)
check(swiftCode.contains("struct DropShape: Shape {") && swiftCode.components(separatedBy: "path.addCurve(").count - 1 == shapeDoc.outline.anchors.count && swiftCode.contains("path.closeSubpath()"), "Swift export is a closed Shape")
check(swiftCode.contains(".regular.tint(Color(red: 1, green: 0.502, blue: 0)).interactive()"), "Swift export names the glass")
let svgText = ShapeCodeExporter.svg(shapeDoc)
check(svgText.contains("viewBox=\"0 0 100 100\"") && svgText.contains(" Z\"") && svgText.components(separatedBy: " C ").count - 1 == shapeDoc.outline.anchors.count, "SVG export")
// Exported numbers redraw the same curve (relative coordinates at any size).
let firstCurve = shapeDoc.outline.cubics[0]
check(swiftCode.contains("path.move(to: p(\(ShapeCodeExporter.number(firstCurve.from.x)), \(ShapeCodeExporter.number(firstCurve.from.y))))"), "export starts at the first anchor")
// Text-to-shape results are checked before use.
let blob: [GeneratedShapeAnchor] = [.init(x: 0.5, y: 0.05, smooth: true), .init(x: 0.95, y: 0.5, smooth: true), .init(x: 0.5, y: 0.95, smooth: true), .init(x: 0.05, y: 0.5, smooth: true)]
if case .success(let generatedOutline) = ShapeGeneration.outline(from: blob) { check(generatedOutline.valid && generatedOutline.anchors.count == 4 && generatedOutline.contains(ShapePoint(0.5, 0.5)), "generated anchors become a closed outline") } else { check(false, "generated anchors become a closed outline") }
check(ShapeGeneration.outline(from: Array(blob.prefix(2))) == .failure(.tooFewAnchors), "too few generated anchors refused")
check(ShapeGeneration.outline(from: blob + [.init(x: 3, y: 0.5, smooth: false)]) == .failure(.outOfRange), "out-of-range generated anchors refused")
check(ShapeGeneration.outline(from: [.init(x: 0.1, y: 0.1, smooth: false), .init(x: 0.9, y: 0.9, smooth: false), .init(x: 0.9, y: 0.1, smooth: false), .init(x: 0.1, y: 0.9, smooth: false)]) == .failure(.selfIntersecting), "crossing generated outline refused")
check(ShapeGeneration.outline(from: blob + [blob[3]]).map(\.anchors.count) == .success(4), "duplicate generated anchors dropped")
check(ShapeGeneration.partialPoints([(0.2, 0.3), (0.5, nil), (nil, nil)]) == [ShapePoint(0.2, 0.3)], "streaming shows finished anchors only")
// World cells take outlines: one undoable transaction, kept by copy and replace.
var curved = map
let emptyCells = freeRow.filter { RPGWorldEditing.entity(at: $0, world: map, generator: mapGen) == nil }
check(emptyCells.count >= 4, "empty cells to shape (\(emptyCells.count))")
let curveCells = Array(emptyCells.prefix(3))
let blockCell = freeRow[0]
check(RPGWorldEditing.entity(at: blockCell, world: curved, generator: mapGen) != nil, "a placed block to shape")
var shapeDraft = RPGEditDraft(payload: .outline(ShapeTemplate.droplet.outline)); shapeDraft.add([blockCell] + curveCells)
let shapePlan = RPGDraftCommit.plan(shapeDraft, world: curved, generator: mapGen)
check(shapePlan.cells.count == 4 && curved == map, "outline draft planned without changing the world")
let undoBefore = curved.undo.count
try RPGDraftCommit.commit(shapeDraft, world: &curved, generator: mapGen)
check(curved.undo.count == undoBefore + 1 && RPGWorldEditing.entity(at: blockCell, world: curved, generator: mapGen)?.outline == ShapeTemplate.droplet.outline, "outline committed as one transaction")
check(RPGWorldEditing.entity(at: blockCell, world: curved, generator: mapGen)?.definitionID == RPGWorldEditing.entity(at: blockCell, world: map, generator: mapGen)?.definitionID, "material kept")
check(curveCells.allSatisfy { RPGWorldEditing.entity(at: $0, world: curved, generator: mapGen)?.definitionID == RPGWorldEditing.displayDefinition }, "empty cells get display cells with the curve")
check(RPGDraftCommit.plan(shapeDraft, world: curved, generator: mapGen).skipped[.unchanged] == 4, "same outline again is unchanged")
let curvedCopy = try RPGWorldCodec.decode(RPGWorldCodec.encode(curved))
check(curvedCopy == curved && curvedCopy.schemaVersion == WorldState.currentSchema, "outlines saved and reopened")
let clip = try RPGWorldEditing.copy(from: blockCell, to: blockCell, world: curved, generator: mapGen)
check(clip.cells.first?.outline == ShapeTemplate.droplet.outline, "copy keeps the outline")
var squareDraft = RPGEditDraft(payload: .outline(nil)); squareDraft.add([blockCell, emptyCells[3]])
let squarePlan = RPGDraftCommit.plan(squareDraft, world: curved, generator: mapGen)
check(squarePlan.cells == [blockCell] && squarePlan.skipped[.empty] == 1, "back to square only touches shaped blocks")
try RPGDraftCommit.commit(squareDraft, world: &curved, generator: mapGen)
check(RPGWorldEditing.entity(at: blockCell, world: curved, generator: mapGen)?.outline == nil, "back to square")
try RPGWorldEditing.undo(world: &curved)
check(RPGWorldEditing.entity(at: blockCell, world: curved, generator: mapGen)?.outline == ShapeTemplate.droplet.outline, "undo restores the curve")
try RPGWorldEditing.undo(world: &curved)
check(RPGWorldEditing.entity(at: blockCell, world: curved, generator: mapGen)?.outline == nil && curveCells.allSatisfy { RPGWorldEditing.entity(at: $0, world: curved, generator: mapGen) == nil }, "undo removes the curve and its display cells")
var badOutline = curved; badOutline.entities[0].outline = ShapeOutline(anchors: [ShapeAnchor(ShapePoint(0.5, 2))])
rejected(badOutline, "invalid outlines refused")
var schema8 = try JSONSerialization.jsonObject(with: RPGWorldCodec.encode(map)) as! [String: Any]
schema8["schemaVersion"] = 8
let reopened8 = try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject: schema8))
check(reopened8.schemaVersion == WorldState.currentSchema && reopened8.entities == map.entities, "schema 8 opens as current with square cells")
UserDefaults.standard.set("en", forKey: L10n.key)
check(ShapeTemplate.droplet.title == "Droplet" && RPGDraftPayload.outline(nil).title == "Shape · Square", "shape titles in English")
UserDefaults.standard.set("zh", forKey: L10n.key)
print("RPG curves: \(checks) total checks passed")


// P21: V2.2 glass world, HUD rules and smart media grids.
let phoneLandscape = CGSize(width: 874, height: 402), phonePortrait = CGSize(width: 402, height: 874)
check(RPGCameraRules.visibleCells(viewSize: phoneLandscape, zoom: 1) > 300, "the old default zoom showed more than 300 cells (\(RPGCameraRules.visibleCells(viewSize: phoneLandscape, zoom: 1)))")
for size in [phoneLandscape, phonePortrait, CGSize(width: 1376, height: 1032), CGSize(width: 320, height: 568)] {
    let widest = RPGCameraRules.budgetZoom(viewSize: size)
    check(RPGCameraRules.visibleCells(viewSize: size, zoom: widest) <= 300 && RPGCameraRules.visibleCells(viewSize: size, zoom: widest + 0.02) > 300 || widest == RPGCameraRules.closestZoom, "widest zoom stays within 300 cells on \(size)")
    let play = RPGCameraRules.playZoom(viewSize: size)
    check((40...100).contains(RPGCameraRules.visibleCells(viewSize: size, zoom: play)) || play == RPGCameraRules.closestZoom, "play view shows 40–100 cells on \(size) (\(RPGCameraRules.visibleCells(viewSize: size, zoom: play)))")
    check(RPGCameraRules.clampZoom(5, viewSize: size) == widest && RPGCameraRules.clampZoom(0.01, viewSize: size) == RPGCameraRules.closestZoom, "pinch clamped to the budget on \(size)")
}
check(RPGGlassQuality.allCases.allSatisfy { RPGGlassQuality.effective($0, lowPower: true, reduceMotion: false) == .performance } && RPGGlassQuality.effective(.high, lowPower: false, reduceMotion: false) == .high, "low power drops the highlight")
check(RPGGlassQuality.performance.sheen == 0 && RPGGlassQuality.high.sheen > RPGGlassQuality.standard.sheen, "quality levels")
let calmHUD = RPGHUDGlassStyle.resolve(.light, RPGHUDConditions())
check(!calmHUD.regular && !calmHUD.solid && calmHUD.scrim > 0, "status glass is clear with a light scrim")
check(RPGHUDGlassStyle.resolve(.light, RPGHUDConditions(increasedContrast: true)).regular && RPGHUDGlassStyle.resolve(.light, RPGHUDConditions(increasedContrast: true)).scrim > calmHUD.scrim, "increased contrast thickens the glass")
check(RPGHUDGlassStyle.resolve(.panel, RPGHUDConditions(reduceTransparency: true)).solid, "reduce transparency goes solid")
check(RPGHUDGlassStyle.resolve(.interactive, RPGHUDConditions(inCombat: true)).combatTint && RPGHUDGlassStyle.resolve(.interactive, RPGHUDConditions()).interactive, "combat tints the controls")
check(!RPGHUDGlassStyle.resolve(.interactive, RPGHUDConditions(lowPower: true)).interactive, "low power drops interactive glass")
// Stick.
check(RPGStickRules.step((0.05, -0.1)) == nil, "dead zone")
check(RPGStickRules.step((0, -1))! == (0, 1) && RPGStickRules.step((1, 0))! == (1, 0) && RPGStickRules.step((-0.7, 0.7))! == (-1, -1) && RPGStickRules.step((0.2, -0.95))! == (0, 1), "screen directions map to grid steps")
let push = RPGStickRules.vector(dx: 300, dy: 0, radius: 50)
check(push.x == 1 && push.y == 0 && RPGStickRules.vector(dx: 25, dy: 0, radius: 50).x == 0.5, "stick vector normalised to the base")
check(abs(RPGStickRules.interval((1, 0)) - RPGStickRules.fastestStep) < 1e-9 && RPGStickRules.interval((0.3, 0)) > RPGStickRules.interval((0.9, 0)), "further push walks faster")
check(RPGStickRules.cooldownFraction(remaining: 1.5, total: 3) == 0.5 && RPGStickRules.cooldownFraction(remaining: -1, total: 3) == 0, "cooldown ring")
// Media grid maths.
let piece = RPGMediaRegion(groupID: "g", row: 0, column: 2, rows: 2, columns: 4)
check(piece.subRect(of: CGRect(x: 0, y: 0, width: 1, height: 1)) == CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.5), "top row piece sits in the upper texture half")
check(RPGMediaRegion.groupRect(crop: CGRect(x: 0, y: 0, width: 1, height: 1), pixels: CGSize(width: 1000, height: 1000), rows: 1, columns: 2, stretch: false) == CGRect(x: 0, y: 0.25, width: 1, height: 0.5), "square picture cropped to a 2:1 grid")
check(RPGMediaRegion.groupRect(crop: CGRect(x: 0, y: 0, width: 1, height: 1), pixels: CGSize(width: 1000, height: 1000), rows: 1, columns: 2, stretch: true).width == 1, "stretch keeps the whole picture")
check(!RPGMediaRegion(groupID: "g", row: 2, column: 0, rows: 2, columns: 2).valid && !RPGMediaRegion(groupID: "", row: 0, column: 0, rows: 1, columns: 1).valid, "invalid regions refused")
check(RPGMediaGridSpec.shape(for: 12, aspect: 4.0 / 3) == (3, 4) && RPGMediaGridSpec.shape(for: 100) == (10, 10) && RPGMediaGridSpec.shape(for: 9) == (3, 3), "rows × columns from a total")
let primeShape = RPGMediaGridSpec.shape(for: 37)
check(primeShape.rows <= 32 && primeShape.columns <= 32 && primeShape.rows * primeShape.columns >= 37, "awkward totals still fit")
// Media grid commits: one binding, a region per cell, one undo step.
var gridWorld = map
let openArea = Array((0..<256).lazy.flatMap { z in (0..<256).lazy.map { SurfacePoint(x: $0, z: z) } }.filter { anchor in
    (0..<3).allSatisfy { row in (0..<4).allSatisfy { column in
        let p = SurfacePoint(x: anchor.x + column, z: anchor.z - row)
        return p.valid && p != gridWorld.player.surface && mapGen.tile(at: p)?.passable == true && !mapGen.protected(p) && !mapGen.sideRegion.contains(p) && RPGWorldEditing.entity(at: p, world: gridWorld, generator: mapGen) == nil
    } }
}.prefix(1))
check(openArea.count == 1, "open 4×3 area for a grid")
let videoTemplate = MediaBinding(id: "draft", mediaID: "clip-1", kind: .video)
var gridSpec = RPGMediaGridSpec(template: videoTemplate, rows: 3, columns: 4, anchor: openArea[0])
check(gridSpec.valid && gridSpec.cells.count == 12, "grid spec covers 12 cells")
let gridDraft = RPGEditDraft(payload: .mediaGrid(gridSpec))
let gridPlan = RPGDraftCommit.plan(gridDraft, world: gridWorld, generator: mapGen)
check(gridPlan.cells.count == 12 && gridPlan.overwrites == 0 && gridWorld == map, "grid previewed without changing the world")
let bindingsBefore = gridWorld.mediaBindings.count, undoBeforeGrid = gridWorld.undo.count
try RPGDraftCommit.commit(gridDraft, world: &gridWorld, generator: mapGen)
let gridEntities = gridWorld.entities.filter { $0.mediaRegion != nil }
check(gridEntities.count == 12 && gridWorld.mediaBindings.count == bindingsBefore + 1 && gridWorld.undo.count == undoBeforeGrid + 1, "12 cells share one binding in one transaction")
let groupID = gridEntities[0].mediaRegion!.groupID
check(gridEntities.allSatisfy { $0.mediaBindingID == groupID && $0.mediaRegion?.groupID == groupID }, "every piece points at the shared binding")
check(Set(gridEntities.map { "\($0.mediaRegion!.row),\($0.mediaRegion!.column)" }).count == 12, "each piece has its own row and column")
let topLeft = RPGWorldEditing.entity(at: openArea[0], world: gridWorld, generator: mapGen)?.mediaRegion
check(topLeft?.row == 0 && topLeft?.column == 0, "anchor cell is the top-left piece")
let gridCopy = try RPGWorldCodec.decode(RPGWorldCodec.encode(gridWorld))
check(gridCopy == gridWorld && gridCopy.schemaVersion == WorldState.currentSchema, "media grids saved and reopened")
// Overwrite reported, then a move replaces the old group in one edit.
let overPlan = RPGDraftCommit.plan(RPGEditDraft(payload: .mediaGrid(RPGMediaGridSpec(template: videoTemplate, rows: 1, columns: 1, anchor: openArea[0]))), world: gridWorld, generator: mapGen)
check(overPlan.overwrites == 1 && overPlan.summary.contains("覆盖已有内容 1 格"), "replacing content is reported")
var moved = gridSpec; moved.anchor = SurfacePoint(x: openArea[0].x + 1, z: openArea[0].z); moved.replacing = groupID; moved.columns = 3
let movePlan = RPGDraftCommit.plan(RPGEditDraft(payload: .mediaGrid(moved)), world: gridWorld, generator: mapGen)
check(movePlan.overwrites == 0, "moving a group over itself is not an overwrite")
try RPGDraftCommit.commit(RPGEditDraft(payload: .mediaGrid(moved)), world: &gridWorld, generator: mapGen)
let afterMove = gridWorld.entities.filter { $0.mediaRegion != nil }
check(afterMove.count == 9 && Set(afterMove.map(\.mediaBindingID)).count == 1 && !afterMove.contains { $0.mediaRegion?.groupID == groupID }, "moved and re-sliced as one new group")
check(RPGWorldEditing.entity(at: openArea[0], world: gridWorld, generator: mapGen) == nil, "old display cells removed")
try RPGWorldEditing.undo(world: &gridWorld)
check(gridWorld.entities.filter { $0.mediaRegion?.groupID == groupID }.count == 12, "undo restores the original group")
try RPGWorldEditing.redo(world: &gridWorld)
check(gridWorld.entities.filter { $0.mediaRegion != nil }.count == 9, "redo moves it again")
let liveGroup = gridWorld.entities.first { $0.mediaRegion != nil }!.mediaRegion!.groupID
var clearDraft = RPGEditDraft(payload: .clearGroup(liveGroup)); clearDraft.add(RPGDraftCommit.groupCells(liveGroup, world: gridWorld) + [openArea[0]])
var cleared = gridWorld
let clearPlan = RPGDraftCommit.plan(clearDraft, world: cleared, generator: mapGen)
check(clearPlan.cells.count == 9 && clearPlan.skipped[.unchanged] == 1, "group delete previews only its own cells")
try RPGDraftCommit.commit(clearDraft, world: &cleared, generator: mapGen)
check(!cleared.entities.contains { $0.mediaRegion != nil } && cleared.undo.count == gridWorld.undo.count + 1, "whole group deleted in one edit")
var mismatched = gridWorld; let mismatchIndex = mismatched.entities.firstIndex { $0.mediaRegion != nil }!
mismatched.entities[mismatchIndex].mediaRegion?.groupID = "other"; rejected(mismatched, "a piece must point at its own binding")
let gridClip = try RPGWorldEditing.copy(from: afterMove[0].surface!, to: afterMove[0].surface!, world: gridWorld, generator: mapGen)
check(gridClip.cells.first?.mediaRegion != nil, "copy keeps the piece")
check(!RPGMediaGridSpec(template: MediaBinding(id: "d", mediaID: "", kind: .image), rows: 2, columns: 2).valid && !RPGMediaGridSpec(template: videoTemplate, rows: 33, columns: 1).valid, "invalid grid specs refused")
var schema9 = try JSONSerialization.jsonObject(with: RPGWorldCodec.encode(map)) as! [String: Any]
schema9["schemaVersion"] = 9
let reopened9 = try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject: schema9))
check(reopened9.schemaVersion == WorldState.currentSchema, "schema 9 opens as current")
UserDefaults.standard.set("en", forKey: L10n.key)
check(RPGGlassQuality.performance.title == "Performance" && overPlan.summary.contains("replaces content in 1"), "V2.2 strings in English")
UserDefaults.standard.set("zh", forKey: L10n.key)
print("RPG glass world: \(checks) total checks passed")


// P22: V2.8 2.5D glass world.
do {
var sw = SpatialWorld.blank()
check(sw.blocks.isEmpty && sw.creatures.isEmpty && sw.plants.isEmpty && sw.generation == nil, "a new 2.5D world is plain glass")
var spatialHost = map; spatialHost.spatial = sw
check((try? RPGWorldCodec.decode(RPGWorldCodec.encode(spatialHost)))?.spatial == sw, "2.5D layer saved and reopened")
var schema10 = try JSONSerialization.jsonObject(with: RPGWorldCodec.encode(map)) as! [String: Any]
schema10["schemaVersion"] = 10
let reopened10 = try RPGWorldCodec.decode(JSONSerialization.data(withJSONObject: schema10))
check(reopened10.schemaVersion == 11 && reopened10.spatial == nil && reopened10.entities == map.entities, "schema 10 opens as 11, 2D data untouched")
// Free height, stacking in one cell, floating.
sw.edit("stack") { w in
    w.blocks.append(SpatialBlock(id: "low", x: 10, y: 10, elevation: 0, thickness: 1))
    w.blocks.append(SpatialBlock(id: "float", x: 10, y: 10, elevation: 3.37, thickness: 0.4, collision: .oneWay))
    w.blocks.append(SpatialBlock(id: "high", x: 10, y: 10, elevation: 7.25, thickness: 2.5))
}
check(SpatialIndex(blocks: sw.blocks).blocks(atX: 10, y: 10).count == 3 && sw.history.undo.count == 1, "three objects in one cell at free heights, one undo step")
check(abs(sw.blocks.first { $0.id == "float" }!.top - 3.77) < 1e-9, "top = bottom + thickness")
sw.edit("remove below") { w in w.blocks.removeAll { $0.id == "low" } }
check(sw.blocks.first { $0.id == "high" }?.elevation == 7.25, "removing a block below never drops the ones above")
sw.undoLast()
check(sw.blocks.count == 3, "undo brings it back")
sw.redoLast(); sw.undoLast()
check(SpatialBuilder.conflicts([SpatialBlock(id: "new", x: 10, y: 10, elevation: 0.5, thickness: 1)], in: sw) == ["new"] && SpatialBuilder.conflicts([SpatialBlock(id: "new", x: 10, y: 10, elevation: 1, thickness: 1)], in: sw).isEmpty, "solid overlap reported, touching is fine")
check(!SpatialBlock(id: "x", x: 300, y: 1, elevation: 0).valid && !SpatialBlock(id: "x", x: 1, y: 1, elevation: 0, thickness: 0).valid, "invalid blocks refused")
// Physics: walk, step up, blocked, jump, stand on a one-way platform, fall back.
let flat = SpatialGeometry(blocks: [SpatialBlock(id: "step", x: 21, y: 20, elevation: 0, thickness: 0.4), SpatialBlock(id: "wall", x: 21, y: 22, elevation: 0, thickness: 2)])
var body = SpatialPlayer(); body.position = SpatialVector(20.5, 20.5, 0); body.lastSafe = body.position
for _ in 0..<20 { SpatialPhysics.step(&body, input: SpatialInput(dx: 1, dy: 0), dt: 1.0 / 60, geometry: flat, previous: flat) }
check(body.position.x > 21 && abs(body.position.z - 0.4) < 1e-6 && body.grounded, "walks up a low step (\(body.position))")
var walker = SpatialPlayer(); walker.position = SpatialVector(21.5, 21.2, 0)
for _ in 0..<60 { SpatialPhysics.step(&walker, input: SpatialInput(dx: 0, dy: 1), dt: 1.0 / 60, geometry: flat, previous: flat) }
check(walker.position.y < 21.75, "a 2-high wall blocks (\(walker.position.y))")
var jumper = SpatialPlayer(); jumper.position = SpatialVector(40.5, 40.5, 0)
let shelf = SpatialGeometry(blocks: [SpatialBlock(id: "shelf", x: 40, y: 40, elevation: 1.0, thickness: 0.2, collision: .oneWay)])
SpatialPhysics.step(&jumper, input: SpatialInput(jump: true), dt: 1.0 / 60, geometry: shelf, previous: shelf)
var peak = 0.0
for _ in 0..<120 { SpatialPhysics.step(&jumper, input: SpatialInput(), dt: 1.0 / 60, geometry: shelf, previous: shelf); peak = max(peak, jumper.position.z) }
check(peak > 1.2 && abs(jumper.position.z - 1.2) < 1e-6 && jumper.grounded, "jumps up through a one-way platform and lands on it (peak \(peak))")
check(SpatialPhysics.jumpHeight > 1.4 && SpatialPhysics.jumpHeight < 1.7, "jump height about 1.5 cells")
var faller = SpatialPlayer(); faller.position = SpatialVector(60.5, 60.5, -25); faller.lastSafe = SpatialVector(61.5, 61.5, 0); faller.grounded = false
SpatialPhysics.step(&faller, input: SpatialInput(), dt: 1.0 / 60, geometry: flat, previous: flat)
check(faller.position == SpatialVector(61.5, 61.5, 0), "falling off the world returns to the last safe spot")
// Moving platform carries its rider.
var lift = SpatialMotion.lift(id: "m", height: 4)
lift.trigger = .always
let platformBlock = SpatialBlock(id: "p", x: 50, y: 50, elevation: 0, thickness: 0.3, collision: .oneWay, groupID: "g")
func frame(_ t: Double) -> [String: GroupFrame] {
    let pose = SpatialMotionRules.pose(lift, clock: t)
    return ["g": GroupFrame(pivot: SpatialVector(50.5, 50.5, 0), offset: pose.offset, yaw: pose.yaw)]
}
var rider = SpatialPlayer(); rider.position = SpatialVector(50.5, 50.5, 0.3)
var previousGeometry = SpatialGeometry(blocks: [platformBlock], frames: frame(0))
var t = 0.0
for _ in 0..<240 {
    t += 1.0 / 60
    let now = SpatialGeometry(blocks: [platformBlock], frames: frame(t))
    SpatialPhysics.step(&rider, input: SpatialInput(), dt: 1.0 / 60, geometry: now, previous: previousGeometry)
    previousGeometry = now
}
let liftPose = SpatialMotionRules.pose(lift, clock: t)
check(abs(rider.position.z - (0.3 + liftPose.offset.z)) < 0.05 && liftPose.offset.z > 1, "a rider goes up with the lift (\(rider.position.z) vs \(0.3 + liftPose.offset.z))")
var spinner = SpatialMotion.rotate(id: "r", degrees: 90); spinner.segmentDuration = 1
let before = GroupFrame(pivot: SpatialVector(0, 0, 0), offset: .zero, yaw: 0), after = GroupFrame(pivot: SpatialVector(0, 0, 0), offset: .zero, yaw: 90)
let carried = after.carry(SpatialVector(1, 0, 0), from: before)
check(abs(carried.x) < 1e-9 && abs(carried.y - 1) < 1e-9, "turning platforms turn their riders")
// Motion: ping-pong, loop, once, track, elevator, events.
let slide = SpatialMotion.slide(id: "s", dx: 6, dy: 0)
check(SpatialMotionRules.passLength(slide) == 5 && SpatialMotionRules.pose(slide, clock: 0.5).offset == .zero && !SpatialMotionRules.pose(slide, clock: 0.5).moving, "dwell at rest first")
check(SpatialMotionRules.pose(slide, clock: 2.5).offset.x == 3 && SpatialMotionRules.pose(slide, clock: 4).offset.x == 6, "travels to the end")
check(SpatialMotionRules.pose(slide, clock: 7.5).offset.x == 3 && SpatialMotionRules.pose(slide, clock: 5.5).offset.x == 6, "pauses at the far end, then comes back")
var once = slide; once.repeatMode = .once; once.trigger = .button
check(SpatialMotionRules.pose(once, clock: 3).offset == .zero, "a triggered motion waits")
check(SpatialMotionRules.start(&once, clock: 10) && !SpatialMotionRules.start(&once, clock: 10.2), "started once; re-trigger inside the cooldown ignored")
check(SpatialMotionRules.pose(once, clock: 20).offset.x == 6 && !SpatialMotionRules.pose(once, clock: 20).moving, "a single run stops at the end")
let loopTrack = SpatialMotion.track(id: "t", points: [.zero, SpatialVector(4, 0, 0), SpatialVector(4, 4, 2)], smooth: true, closed: true)
let atKey = SpatialMotionRules.pose(loopTrack, clock: 2.75).offset
check(loopTrack.valid && (atKey - SpatialVector(4, 0, 0)).flatLength < 1e-9 && SpatialMotionRules.pose(loopTrack, clock: 5.25).offset.z == 2, "closed smooth 3D track passes through its points")
var elevator = SpatialMotion.elevator(id: "e", floors: [0, 4, 8])
SpatialMotionRules.call(&elevator, floor: 2, clock: 0)
check(abs(SpatialMotionRules.pose(elevator, clock: 2.5).offset.z - 4) < 1e-9 && SpatialMotionRules.pose(elevator, clock: 6).offset.z == 8, "elevator rides to the chosen floor")
SpatialMotionRules.settle(&elevator, clock: 9)
check(elevator.restIndex == 2 && elevator.startedAt == nil, "elevator settles at the stop")
SpatialMotionRules.call(&elevator, floor: 0, clock: 10)
check(SpatialMotionRules.pose(elevator, clock: 15).offset.z == 0, "and comes back down")
var eventWorld = SpatialWorld.blank()
var near = SpatialMotion.slide(id: "near", dx: 3, dy: 0); near.trigger = .proximity; near.repeatMode = .once
eventWorld.motions = [near] + (0..<60).map { var m = SpatialMotion.slide(id: "tm\($0)", dx: 1, dy: 0); m.trigger = .timer; m.interval = 1; return m }
eventWorld.groups = [BuildingGroup(id: "ng", name: "n", motionID: "near")]
eventWorld.clock = 5
let fired = SpatialEventRules.step(&eventWorld, player: SpatialVector(10, 10, 0), groupCenters: ["ng": SpatialVector(11, 10, 0)])
check(fired == SpatialEventRules.actionsPerFrame && eventWorld.motions[0].startedAt == 5, "proximity trigger fires; actions capped per frame")
check(SpatialEventRules.step(&eventWorld, player: SpatialVector(10, 10, 0), groupCenters: ["ng": SpatialVector(11, 10, 0)]) <= SpatialEventRules.actionsPerFrame && eventWorld.motions[0].startedAt == 5, "no runaway re-triggering")
// Buildings and group operations.
for kind in BuildingKind.allCases {
    let blocks = SpatialBuilder.building(kind, x: 100, y: 100, elevation: 0, groupID: "g-\(kind.rawValue)", idPrefix: kind.rawValue)
    check(!blocks.isEmpty && blocks.allSatisfy { $0.valid && $0.groupID == "g-\(kind.rawValue)" } && Set(blocks.map(\.id)).count == blocks.count, "\(kind.rawValue) template is ordinary blocks")
}
var town = SpatialWorld.blank()
town.edit("hut") { w in
    w.groups.append(BuildingGroup(id: "hut", name: "Hut"))
    w.blocks += SpatialBuilder.building(.hut, x: 30, y: 30, elevation: 0, groupID: "hut", idPrefix: "hut")
}
let hutCount = town.blocks.count
town.edit("copy") { w in SpatialBuilder.copy(group: "hut", dx: 8, dy: 0, dz: 2, newGroup: "hut2", idPrefix: "hut2", world: &w) }
check(town.blocks.count == hutCount * 2 && town.blocks.filter { $0.groupID == "hut2" }.allSatisfy { $0.elevation >= 2 }, "copy a building, raised 2")
town.edit("move") { w in SpatialBuilder.move(group: "hut2", dx: 0, dy: 5, dz: 0.5, world: &w) }
check(town.blocks.filter { $0.groupID == "hut2" }.map(\.y).min() == 35, "move a whole group")
let beforeTurn = Set(town.blocks.filter { $0.groupID == "hut" }.map { "\($0.x),\($0.y)" })
town.edit("turn") { w in SpatialBuilder.rotateQuarter(group: "hut", world: &w) }
check(Set(town.blocks.filter { $0.groupID == "hut" }.map { "\($0.x),\($0.y)" }) == beforeTurn && town.blocks.filter { $0.groupID == "hut" }.allSatisfy { $0.yaw == 90 } && town.blocks.filter { $0.groupID == "hut" }.count == hutCount, "quarter turn keeps every block (square hut keeps its footprint)")
var stairWorld = SpatialWorld.blank(); stairWorld.groups = [BuildingGroup(id: "st", name: "st")]
stairWorld.blocks = SpatialBuilder.building(.stairs, x: 40, y: 40, elevation: 0, groupID: "st", idPrefix: "st")
SpatialBuilder.rotateQuarter(group: "st", world: &stairWorld)
check(Set(stairWorld.blocks.map(\.x)).count == 2 && Set(stairWorld.blocks.map(\.y)).count == 8, "a long stair turns to run the other way")
let ids = Set(town.blocks.filter { $0.groupID == "hut2" }.map(\.id))
let relative = town.blocks.filter { $0.groupID == "hut2" }.map(\.elevation)
town.edit("raise") { w in SpatialBuilder.raise(ids, by: 1.25, world: &w) }
check(zip(relative, town.blocks.filter { $0.groupID == "hut2" }.map(\.elevation)).allSatisfy { abs($1 - $0 - 1.25) < 1e-9 }, "raise keeps relative heights")
town.edit("gradient") { w in SpatialBuilder.gradient(Set(["hut2:0", "hut2:1", "hut2:2"]), from: 0, to: 4, world: &w) }
check(Set(town.blocks.filter { ["hut2:0", "hut2:1", "hut2:2"].contains($0.id) }.map(\.elevation)) == [0, 2, 4], "height gradient")
let template = SpatialBuilder.template(from: "hut", name: "My hut", id: "tpl", world: town)!
let stamped = SpatialBuilder.stamp(template, x: 60, y: 60, elevation: 1, groupID: "hut3", idPrefix: "hut3")
check(stamped.count == hutCount && stamped.map(\.x).min() == 60 && stamped.map(\.elevation).min() == 1, "templates save and stamp")
check(SpatialBuilder.snap(1.37, step: 0.25) == 1.25, "height snapping")
for _ in 0..<4 { town.undoLast() }
check(town.blocks.count == hutCount * 2 && town.blocks.filter { $0.groupID == "hut2" }.map(\.y).min() == 30, "undo steps back through group edits")
town.undoLast()
check(town.blocks.count == hutCount, "undo the copy too")
// Media across blocks: one binding, a row and column each.
var wall = SpatialWorld.blank()
wall.blocks = SpatialBuilder.building(.mediaWall, x: 5, y: 5, elevation: 0, groupID: "w", idPrefix: "w"); wall.groups = [BuildingGroup(id: "w", name: "w")]
SpatialBuilder.mediaGrid(bindingID: "vid", blocks: wall.blocks.map(\.id), face: .front, stretch: false, world: &wall)
let regions = wall.blocks.compactMap(\.media?.region)
check(regions.count == 12 && Set(regions.map { "\($0.row),\($0.column)" }).count == 12 && regions.allSatisfy { $0.rows == 3 && $0.columns == 4 }, "video wall: 3×4 pieces of one binding")
check(wall.blocks.first { $0.elevation == 2 }?.media?.region?.row == 0, "the top row of the wall shows the top of the picture")
var missingMedia = map; missingMedia.spatial = wall; rejected(missingMedia, "block media must reference a binding")
// Legacy 2D blocks appear at ground height.
let legacy = SpatialLegacy.blocks(from: map.entities)
check(legacy.count == map.entities.filter { $0.surface != nil }.count && legacy.allSatisfy { $0.elevation == 0 }, "2D blocks map to the ground of the 2.5D world")
// Camera: tilt limits and the 300-cell budget.
for tilt in [0.0, 30, 45, 65] {
    let distance = SpatialCameraRules.maxDistance(tilt: tilt, aspect: 874.0 / 402)
    let count = SpatialCameraRules.visibleCells(SpatialCameraState(tilt: tilt, distance: distance), aspect: 874.0 / 402)
    check(count <= 300 && SpatialCameraRules.visibleCells(SpatialCameraState(tilt: tilt, distance: distance + 1), aspect: 874.0 / 402) > 300, "tilt \(Int(tilt))°: at most 300 ground cells (\(count) at \(String(format: "%.1f", distance)))")
}
check(SpatialCameraRules.clampTilt(80) == 65 && SpatialCameraRules.clampTilt(-5) == 0, "tilt kept within 0–65°")
let ahead = SpatialCameraRules.worldDirection(stickX: 0, stickY: -1, yaw: 0), turned = SpatialCameraRules.worldDirection(stickX: 0, stickY: -1, yaw: 90)
check(abs(ahead.dx) < 1e-9 && abs(ahead.dy - 1) < 1e-9 && abs(turned.dx + 1) < 1e-9, "stick up walks away from the camera at any turn")
// Navigation and AI.
let mazeGeometry = SpatialGeometry(blocks: (0..<9).map { SpatialBlock(id: "w\($0)", x: 70, y: 66 + $0, elevation: 0, thickness: 2) } + [SpatialBlock(id: "ramp1", x: 72, y: 70, elevation: 0, thickness: 0.5), SpatialBlock(id: "ramp2", x: 73, y: 70, elevation: 0, thickness: 1.0), SpatialBlock(id: "top", x: 74, y: 70, elevation: 0, thickness: 1.5)])
let navigator = SpatialNavigator(geometry: mazeGeometry)
let around = navigator.path(from: SpatialVector(68.5, 70.5, 0), to: SpatialVector(71.5, 70.5, 0))
check(around != nil && around!.count > 4, "path goes around a wall")
check(navigator.path(from: SpatialVector(71.5, 70.5, 0), to: SpatialVector(74.5, 70.5, 1.5))?.last?.z == 1.5, "path climbs steps by height")
check(navigator.surfaces(x: 70, y: 70) == [2.0] && navigator.surfaces(x: 75, y: 70) == [0], "standable surfaces include block tops")
var goblin = CreatureEntity(id: "e1", kind: .enemy, position: SpatialVector(80.5, 80.5, 0), home: SpatialVector(80.5, 80.5, 0), health: 30, maxHealth: 30, damage: 6)
var brain = CreatureBrain()
let open = SpatialGeometry(blocks: [])
_ = SpatialAI.step(&goblin, brain: &brain, player: SpatialVector(95.5, 80.5, 0), playerAlive: true, dt: 0.1, geometry: open, navigator: nil, random: 0.5)
check(goblin.state == .idle, "far player not noticed")
var events: [CreatureEvent] = []
for _ in 0..<80 { events += SpatialAI.step(&goblin, brain: &brain, player: SpatialVector(84.5, 80.5, 0), playerAlive: true, dt: 0.1, geometry: open, navigator: nil, random: 0.5) }
check(events.contains(.hitPlayer(id: "e1", damage: 6)), "enemy notices, chases and hits (\(goblin.state))")
var floating = goblin; floating.state = .idle; floating.windUp = nil
check(SpatialAI.step(&floating, brain: &brain, player: SpatialVector(81.5, 80.5, 6), playerAlive: true, dt: 0.1, geometry: open, navigator: nil, random: 0.5).isEmpty && floating.state == .idle, "a player far above is out of reach")
for _ in 0..<300 { _ = SpatialAI.step(&goblin, brain: &brain, player: SpatialVector(140.5, 80.5, 0), playerAlive: true, dt: 0.1, geometry: open, navigator: nil, random: 0.5) }
check((goblin.position - goblin.home).flatLength < 1 && goblin.state == .idle, "returns to its area when the player leaves")
var boss = CreatureEntity(id: "b", kind: .boss, position: SpatialVector(150.5, 150.5, 0), home: SpatialVector(150.5, 150.5, 0), health: 400, maxHealth: 400, damage: 16)
var bossBrain = CreatureBrain(); bossBrain.areaCooldown = 0
check(SpatialAI.step(&boss, brain: &bossBrain, player: SpatialVector(165.5, 150.5, 0), playerAlive: true, dt: 0.1, geometry: open, navigator: nil, random: 0.3).isEmpty, "boss waits until the player enters its arena")
var bossEvents: [CreatureEvent] = []
for _ in 0..<40 { bossEvents += SpatialAI.step(&boss, brain: &bossBrain, player: SpatialVector(152.5, 150.5, 0), playerAlive: true, dt: 0.1, geometry: open, navigator: nil, random: 0.3) }
check(bossEvents.contains { if case .telegraph = $0 { return true }; return false } && bossEvents.contains { if case .areaHit = $0 { return true }; return false }, "boss area attack is telegraphed before it lands")
let telegraphIndex = bossEvents.firstIndex { if case .telegraph = $0 { return true }; return false }!, hitIndex = bossEvents.firstIndex { if case .areaHit = $0 { return true }; return false }!
check(telegraphIndex < hitIndex, "warning first, hit after")
boss.health = 150; _ = SpatialAI.step(&boss, brain: &bossBrain, player: SpatialVector(152.5, 150.5, 0), playerAlive: true, dt: 0.1, geometry: open, navigator: nil, random: 0.3)
check(boss.phase == 2, "boss enters phase 2 below half health")
var targets = [goblin, CreatureEntity(id: "behind", kind: .enemy, position: SpatialVector(79.0, 80.5, 0), home: .zero, health: 30, maxHealth: 30, damage: 6),
               CreatureEntity(id: "above", kind: .enemy, position: SpatialVector(81.5, 80.5, 3), home: .zero, health: 30, maxHealth: 30, damage: 6)]
targets[0].position = SpatialVector(81.5, 80.5, 0); targets[0].state = .idle
let struck = SpatialCombat.attack(.strike, from: SpatialVector(80.5, 80.5, 0), facing: 0, damage: 12, creatures: &targets, geometry: open)
check(struck == ["e1"], "a strike hits in front, not behind or far above")
let walled = SpatialGeometry(blocks: [SpatialBlock(id: "pillar", x: 81, y: 80, elevation: 0, thickness: 2)])
var hidden = [CreatureEntity(id: "h", kind: .enemy, position: SpatialVector(82.5, 80.5, 0), home: .zero, health: 30, maxHealth: 30, damage: 6)]
check(SpatialCombat.attack(.skill, from: SpatialVector(80.5, 80.5, 0), facing: 0, damage: 25, creatures: &hidden, geometry: walled).isEmpty, "walls block hits")
// Random generation: deterministic, valid, editable, keeps user work.
let maze = { var r = SpatialRandom(seed: 9); return SpatialMaze.generate(width: 6, height: 6, random: &r) }()
check(maze.solve() != nil && !maze.deadEnds.isEmpty, "maze has a way from entrance to exit")
var r1 = SpatialRandom(seed: 42), r2 = SpatialRandom(seed: 42)
check((0..<10).map { _ in r1.next() } == (0..<10).map { _ in r2.next() }, "seeded random repeats")
var userWorld = SpatialWorld.blank()
userWorld.blocks = [SpatialBlock(id: "mine", x: 5, y: 250, elevation: 2, thickness: 1)]
let config = WorldGenerationConfiguration()
let first = SpatialWorldGenerator.generate(config, keeping: userWorld)
let second = SpatialWorldGenerator.generate(config, keeping: userWorld)
check(first.world.blocks == second.world.blocks && first.world.creatures == second.world.creatures && first.world.plants == second.world.plants, "same seed and settings: same world")
check(first.summary.problems.isEmpty, "generated world passes validation (\(first.summary.problems), attempts \(first.summary.attempts))")
let s1 = first.summary
check(s1.buildings > 0 && s1.plants > 50 && s1.neutral > 0 && s1.enemies > 0 && s1.guards > 0 && s1.miniBosses == 1 && s1.bosses == 1 && s1.mazes == 1 && s1.pickups > 0, "every kind of content generated (\(s1))")
check(first.world.blocks.contains { $0.id == "mine" } && s1.keptUser == 1, "the user's own block is kept")
check(first.world.generation?.version == SpatialWorldGenerator.version && first.world.generation?.configuration == config, "seed, settings and version saved")
var other = config; other.seed = 7
check(SpatialWorldGenerator.generate(other, keeping: userWorld).world.blocks != first.world.blocks, "another seed gives another world")
let regenerated = SpatialWorldGenerator.generate(other, keeping: first.world)
check(regenerated.summary.replacedGenerated > 0 && regenerated.world.blocks.contains { $0.id == "mine" } && !regenerated.world.blocks.contains { $0.id.hasPrefix("gen\(config.seed % 1_000_000)") }, "regenerating replaces only generated objects")
var hostWithGen = map; hostWithGen.spatial = first.world
check((try? RPGWorldCodec.decode(RPGWorldCodec.encode(hostWithGen)))?.spatial == first.world, "generated world saved and reopened as-is")
var edited = first.world
edited.edit("generate") { _ in }
edited.edit("edit") { w in w.blocks[0].elevation += 1 }
check(edited.history.undo.count == 1, "generated objects are ordinary editable blocks")
for style in WorldStyle.allCases {
    var c = config; c.style = style; c.seed = 1000 + UInt64(style.hashValue & 0xFF)
    c.seed = 1234
    let result = SpatialWorldGenerator.generate(c, keeping: .blank())
    check(result.summary.problems.isEmpty, "\(style.rawValue) world passes validation (\(result.summary.problems))")
}
var bare = config; bare.maze = false; bare.miniBoss = false; bare.bigBoss = false
let bareResult = SpatialWorldGenerator.generate(bare, keeping: .blank())
check(bareResult.summary.mazes == 0 && bareResult.summary.bosses == 0 && bareResult.summary.miniBosses == 0, "maze and bosses can be switched off")
var hard = config; hard.difficulty = .hard
let hardBoss = SpatialWorldGenerator.generate(hard, keeping: .blank()).world.creatures.first { $0.kind == .boss }!
let normalBoss = first.world.creatures.first { $0.kind == .boss }!
check(hardBoss.maxHealth > normalBoss.maxHealth && hardBoss.damage <= 60, "difficulty scales bosses within caps")
var history = SpatialWorld.blank()
history.edit("gen") { w in w = SpatialWorldGenerator.generate(config, keeping: w).world }
check(history.history.undo.count == 1 && !history.blocks.isEmpty, "generation is one undo step")
history.undoLast()
check(history.blocks.isEmpty && history.generation == nil, "undo removes the whole generation")
UserDefaults.standard.set("en", forKey: L10n.key)
check(BuildingKind.hut.title == "Glass Hut" && WorldStyle.islands.title == "Floating Islands" && CreatureKind.boss.title == "Boss", "2.5D titles in English")
UserDefaults.standard.set("zh", forKey: L10n.key)
var movingWorld = SpatialWorld.blank()
movingWorld.motions = [SpatialMotion.slide(id: "mv", dx: 5, dy: 0)]
movingWorld.groups = [BuildingGroup(id: "mg", name: "m", motionID: "mv")]
movingWorld.blocks = [SpatialBlock(id: "mb", x: 90, y: 90, elevation: 0, thickness: 0.3, groupID: "mg"), SpatialBlock(id: "still", x: 92, y: 92, elevation: 0)]
let pivots = movingWorld.motionPivots()
let base = SpatialGeometry(blocks: movingWorld.blocks, frames: movingWorld.groupFrames(pivots: pivots, clock: 0))
let later = base.moved(frames: movingWorld.groupFrames(pivots: pivots, clock: 4))
check(base.boxes(x: 90.5, y: 90.5, radius: 0.1).count == 1 && later.boxes(x: 95.5, y: 90.5, radius: 0.1).count == 1 && later.boxes(x: 92.5, y: 92.5, radius: 0.1).count == 1, "moving boxes re-placed per frame, static ones kept")
print("RPG 2.5D world: \(checks) total checks passed")
}


// P23: v1.60 projection, picking and native glass faces.
do {
    let size = CGSize(width: 800, height: 400)
    let camera = SpatialProjection(eye: SpatialVector(100, 90, 10), target: SpatialVector(100, 100, 0), fieldOfView: 30, viewSize: size)
    let center = camera.project(SpatialVector(100, 100, 0))!
    check(abs(center.point.x - 400) < 1e-6 && abs(center.point.y - 200) < 1e-6, "target projects to the screen centre")
    check(camera.project(SpatialVector(100, 80, 10)) == nil, "points behind the camera are not drawn")
    let right = camera.project(SpatialVector(101, 100, 0))!.point, far = camera.project(SpatialVector(100, 101, 0))!.point
    check(right.x > 400 && abs(right.y - 200) < 1e-6 && far.y < 200, "map east is screen right, map north is up the screen")
    for screen in [CGPoint(x: 400, y: 200), CGPoint(x: 120, y: 330), CGPoint(x: 700, y: 50)] {
        let ray = camera.ray(through: screen)
        let t = -ray.origin.z / ray.direction.z
        let back = camera.project(ray.origin + ray.direction * t)!.point
        check(abs(back.x - screen.x) < 1e-6 && abs(back.y - screen.y) < 1e-6, "ray and projection agree at \(screen)")
    }
    let topDown = SpatialProjection(eye: SpatialVector(50, 50, 20), target: SpatialVector(50, 50, 0), fieldOfView: 30, viewSize: size)
    check(topDown.project(SpatialVector(50, 51, 0))!.point.y < 200, "straight down: north is still up")
    let turnedDown = SpatialProjection(eye: SpatialVector(50, 50, 20), target: SpatialVector(50, 50, 0), fieldOfView: 30, viewSize: size, yaw: 90)
    check(turnedDown.project(SpatialVector(49, 50, 0))!.point.y < 200, "straight down turned 90°: west is up, as the stick expects")
    let ahead = SpatialCameraRules.worldDirection(stickX: 0, stickY: -1, yaw: 90)
    check(abs(ahead.dx + 1) < 1e-9, "and the stick walks west")
    // Picking: nearest first, stacked blocks, creatures, ground.
    let stacked = [SpatialBlock(id: "low", x: 100, y: 100, elevation: 0), SpatialBlock(id: "high", x: 100, y: 100, elevation: 3, thickness: 0.5)]
    let down = topDown.ray(through: CGPoint(x: 400, y: 200))
    let overhead = SpatialProjection(eye: SpatialVector(100.5, 100.5, 20), target: SpatialVector(100.5, 100.5, 0), fieldOfView: 30, viewSize: size)
    let ray = overhead.ray(through: CGPoint(x: 400, y: 200))
    let hits = SpatialPicking.pick(origin: ray.origin, direction: ray.direction, blocks: stacked, frames: [:], creatures: [], pickups: [])
    check(hits.map(\.kind) == [.block, .block, .ground] && hits.map(\.id).prefix(2) == ["high", "low"], "picks the top block first, then the one below, then the ground")
    check(abs(hits[0].point.z - 3.5) < 1e-6 && hits[2].cell == SurfacePoint(x: 100, z: 100), "hit point and cell")
    _ = down
    let slime = CreatureEntity(id: "s", kind: .enemy, position: SpatialVector(100.5, 100.5, 0), home: .zero, health: 5, maxHealth: 5, damage: 1)
    check(SpatialPicking.pick(origin: ray.origin, direction: ray.direction, blocks: [], frames: [:], creatures: [slime], pickups: []).first?.kind == .creature, "creatures can be tapped")
    check(SpatialPicking.pick(origin: ray.origin, direction: ray.direction, blocks: [], frames: [:], creatures: [], pickups: [], groundHoles: [100 * 256 + 100]).isEmpty, "holes in the ground are not ground")
    let moving = SpatialBlock(id: "m", x: 100, y: 100, elevation: 0, groupID: "g")
    let shifted = SpatialPicking.pick(origin: ray.origin, direction: ray.direction, blocks: [moving], frames: ["g": GroupFrame(pivot: SpatialVector(100.5, 100.5, 0), offset: SpatialVector(5, 0, 0), yaw: 0)], creatures: [], pickups: [])
    check(!shifted.contains { $0.kind == .block }, "moving blocks are picked where they are now")
    // Native glass faces.
    let box = SpatialBlock(id: "b", x: 10, y: 10, elevation: 1, thickness: 2)
    let corners = SpatialFaces.corners(box)
    check(corners.count == 8 && corners[0].z == 1 && corners[7].z == 3 && abs(corners[2].x - 11) < 1e-9, "block corners")
    let fromAbove = SpatialFaces.visibleFaces(corners, eye: SpatialVector(10.5, 10.5, 20)).map(\.index)
    check(fromAbove == [0], "straight above: only the top face")
    let fromSouthEast = Set(SpatialFaces.visibleFaces(corners, eye: SpatialVector(20, 0, 10)).map(\.index))
    check(fromSouthEast == [0, 2, 3], "from the south-east and above: top, south and east faces")
    let turned = SpatialFaces.corners(SpatialBlock(id: "t", x: 10, y: 10, elevation: 0, yaw: 45))
    check(abs(turned[0].x - 10.5) < 1e-9, "turned blocks turn their corners")
    let clockwise = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 10, y: 0)]
    check(SpatialFaces.signedArea(SpatialFaces.oriented(clockwise)) > 0 && SpatialFaces.signedArea(SpatialFaces.oriented(clockwise.reversed())) > 0, "every face wound the same way")
    let many = (0..<500).map { SpatialBlock(id: "n\($0)", x: $0 % 50, y: $0 / 50, elevation: 0) }
    let nearest = SpatialFaces.nearest(many, to: SpatialVector(0.5, 0.5, 0), budget: 10)
    check(nearest.count == 10 && nearest.first?.id == "n0", "native glass budget keeps the nearest blocks")
    check(SpatialFaces.budget(.performance) == 0 && SpatialFaces.budget(.high) > SpatialFaces.budget(.standard), "budget follows glass quality")
    print("RPG projection: \(checks) total checks passed")
}


// P24: v1.60 characters, animation, skills, statuses, Boss phases, camera.
do {
    // Animation priorities and directions.
    var anim = CharacterAnimationState()
    CharacterAnimator.request(&anim, .walk, clock: 1, length: 0.6)
    CharacterAnimator.request(&anim, .attack, clock: 1.1, length: 0.6)
    CharacterAnimator.request(&anim, .walk, clock: 1.3, length: 0.6)
    check(anim.action == .attack, "an attack is not cut off by walking")
    CharacterAnimator.request(&anim, .walk, clock: 1.8, length: 0.6)
    check(anim.action == .walk, "walking resumes after the attack clip")
    CharacterAnimator.request(&anim, .hurt, clock: 2, length: 0.4); CharacterAnimator.request(&anim, .death, clock: 2.1, length: 0.4); CharacterAnimator.request(&anim, .idle, clock: 9, length: 0.4)
    check(anim.action == .death, "death is final")
    check(CharacterAnimator.movement(speed: 4, grounded: true, verticalSpeed: 0) == .run && CharacterAnimator.movement(speed: 1, grounded: false, verticalSpeed: -2) == .fall, "movement actions")
    check(CharacterAnimator.direction(facing: -90, cameraYaw: 0, count: 4) == 0 && CharacterAnimator.direction(facing: 90, cameraYaw: 0, count: 4) == 2, "facing the camera shows the front picture, facing away the back")
    check(CharacterAnimator.direction(facing: 0, cameraYaw: 0, count: 8) != CharacterAnimator.direction(facing: 180, cameraYaw: 0, count: 8), "left and right pictures differ")
    var hero = CharacterTemplate(id: "hero", name: "Hero")
    hero.clips[CharacterAction.idle.rawValue] = ActionClip(bindingIDs: ["idle-pic"])
    hero.clips[CharacterAction.walk.rawValue] = ActionClip(bindingIDs: ["walk-pic"], speed: 1.5)
    check(hero.clip(.run)?.bindingIDs == ["walk-pic"] && hero.clip(.attack)?.bindingIDs == ["idle-pic"] && hero.valid, "missing clips fall back to walk or idle")
    check(CharacterAnimator.clipTime(CharacterAnimationState(action: .walk, started: 0), clip: ActionClip(speed: 1, loop: true, length: 0.5), clock: 1.2) < 0.5, "looping clip time wraps")
    // Skills: projectiles, homing, pierce, explosion, beam, telegraphed area.
    let templates = SkillLibrary.templates()
    check(templates.count == 8 && templates.allSatisfy(\.valid), "eight valid skill templates")
    let fireball = templates.first { $0.id == "tpl.fireball" }!
    let foe = SkillTarget(id: "foe", position: SpatialVector(105, 100, 0), radius: 0.4, height: 1.4, faction: .enemy)
    let friend = SkillTarget(id: "friend", position: SpatialVector(103, 100, 0), radius: 0.4, height: 1.4, faction: .player)
    var cast = SkillCast(skill: fireball, faction: .player, origin: SpatialVector(100, 100, 0), facing: 0)
    var hits: [SkillHit] = [], visuals: [SkillVisual] = []
    for _ in 0..<120 { let step = cast.step(1.0 / 60, targets: [foe, friend], geometry: nil); hits += step.hits; visuals += step.visuals }
    check(hits.filter { $0.targetID == "foe" }.count == 2 && hits.allSatisfy { $0.targetID != "friend" }, "fireball hits the enemy (impact + explosion), passes friends")
    check(hits.first?.status?.kind == .burn && hits.first!.knockback.x > 0, "burn and knockback away from the caster")
    check(visuals.contains { if case .projectile = $0 { return true }; return false } && visuals.contains { if case .particles(.explosion, _, _) = $0 { return true }; return false }, "projectile and explosion are shown")
    var replay = SkillCast(skill: fireball, faction: .player, origin: SpatialVector(100, 100, 0), facing: 0)
    var again: [SkillHit] = []
    for _ in 0..<120 { again += replay.step(1.0 / 60, targets: [foe, friend], geometry: nil).hits }
    check(again == hits, "same cast, same hits (deterministic)")
    let wall = SpatialGeometry(blocks: [SpatialBlock(id: "w", x: 102, y: 99, elevation: 0, thickness: 3, size: 1), SpatialBlock(id: "w2", x: 102, y: 100, elevation: 0, thickness: 3)])
    var blocked = SkillCast(skill: fireball, faction: .player, origin: SpatialVector(100, 100.5, 0), facing: 0)
    var blockedHits: [SkillHit] = []
    let behindWall = SkillTarget(id: "foe", position: SpatialVector(105, 100.5, 0), radius: 0.4, height: 1.4, faction: .enemy)
    for _ in 0..<120 { blockedHits += blocked.step(1.0 / 60, targets: [behindWall], geometry: wall).hits }
    check(blockedHits.filter { $0.damage == fireball.events.compactMap { if case .projectile(let p) = $0.kind { return p.damage }; return nil }.first }.isEmpty, "walls stop projectiles")
    var pierce = SkillDefinition(id: "p", name: "Pierce", events: [SkillEvent(time: 0, kind: .projectile(ProjectileSpec(speed: 20, lifetime: 1, damage: 5, pierce: 1)))])
    let row = (1...3).map { SkillTarget(id: "r\($0)", position: SpatialVector(100 + Double($0) * 2, 100, 0), radius: 0.4, height: 1.4, faction: .enemy) }
    var pierceCast = SkillCast(skill: pierce, faction: .player, origin: SpatialVector(100, 100, 0), facing: 0)
    var pierceHits: [SkillHit] = []
    for _ in 0..<60 { pierceHits += pierceCast.step(1.0 / 60, targets: row, geometry: nil).hits }
    check(pierceHits.map(\.targetID) == ["r1", "r2"], "pierce 1 hits two targets, each once")
    pierce.events = [SkillEvent(time: 0, kind: .projectile(ProjectileSpec(speed: 6, lifetime: 3, damage: 5, homing: 400)))]
    let sideFoe = SkillTarget(id: "side", position: SpatialVector(100, 106, 0), radius: 0.4, height: 1.4, faction: .enemy)
    var homing = SkillCast(skill: pierce, faction: .player, origin: SpatialVector(100, 100, 0), facing: 0)
    var homingHits: [SkillHit] = []
    for _ in 0..<180 { homingHits += homing.step(1.0 / 60, targets: [sideFoe], geometry: nil).hits }
    check(homingHits.map(\.targetID) == ["side"], "homing shots turn toward a target at the side")
    let beam = templates.first { $0.id == "tpl.beam" }!
    var beamCast = SkillCast(skill: beam, faction: .player, origin: SpatialVector(100, 100, 0), facing: 0)
    var beamHits: [SkillHit] = []
    for _ in 0..<150 { beamHits += beamCast.step(1.0 / 60, targets: [foe], geometry: nil).hits }
    check(beamHits.count >= 6 && beamHits.count <= 8 && beamHits.allSatisfy { $0.damage == 6 }, "beam ticks on its interval (\(beamHits.count))")
    let meteor = templates.first { $0.id == "tpl.meteor" }!
    var meteorCast = SkillCast(skill: meteor, faction: .player, origin: SpatialVector(100, 100, 0), facing: 0)
    var meteorEvents: [(Double, Bool, Bool)] = []
    for _ in 0..<120 { let step = meteorCast.step(1.0 / 60, targets: [SkillTarget(id: "m", position: SpatialVector(104, 100, 0), radius: 0.4, height: 1.4, faction: .enemy)], geometry: nil)
        meteorEvents.append((meteorCast.time, step.visuals.contains { if case .telegraph = $0 { return true }; return false }, !step.hits.isEmpty)) }
    let warned = meteorEvents.first { $0.1 }!.0, struck = meteorEvents.first { $0.2 }!.0
    check(warned < struck && struck - warned >= 0.95, "area warns first, lands after the delay")
    check(meteorEvents.filter { $0.2 }.count == 1, "a one-shot area hits once")
    let cone = AreaSpec(shape: .cone, radius: 4, angle: 40)
    check(SkillCast.inArea(cone, center: .zero, facing: 0, target: SkillTarget(id: "a", position: SpatialVector(3, 0.5, 0), radius: 0.3, height: 1, faction: .enemy)) && !SkillCast.inArea(cone, center: .zero, facing: 0, target: SkillTarget(id: "b", position: SpatialVector(-3, 0, 0), radius: 0.3, height: 1, faction: .enemy)), "cone hits in front only")
    check(!SkillCast.inArea(AreaSpec(radius: 3), center: .zero, facing: 0, target: SkillTarget(id: "c", position: SpatialVector(1, 0, 5), radius: 0.3, height: 1, faction: .enemy)), "areas respect height")
    let invulnerable = SkillTarget(id: "i", position: SpatialVector(102, 100, 0), radius: 0.4, height: 1.4, faction: .enemy, invulnerable: true)
    var dodge = SkillCast(skill: fireball, faction: .player, origin: SpatialVector(100, 100, 0), facing: 0)
    var dodged: [SkillHit] = []
    for _ in 0..<60 { dodged += dodge.step(1.0 / 60, targets: [invulnerable], geometry: nil).hits }
    check(dodged.isEmpty, "invulnerable targets are not hit")
    var flood = SkillDefinition(id: "f", name: "Flood", events: (0..<40).map { SkillEvent(time: Double($0) * 0.01, kind: .projectile(ProjectileSpec(lifetime: 9, count: 12))) })
    flood.cooldown = 1
    var floodCast = SkillCast(skill: flood, faction: .enemy, origin: .zero, facing: 0)
    _ = floodCast.step(1, targets: [], geometry: nil)
    check(floodCast.projectiles.count == SkillCast.projectileLimit, "projectiles are capped per cast")
    for _ in 0..<2000 { _ = floodCast.step(0.05, targets: [], geometry: nil) }
    check(floodCast.time <= SkillCast.lifetimeLimit + 0.05, "a cast never runs past its lifetime limit")
    // Statuses.
    var effects: [StatusEffect] = []
    StatusRules.apply(StatusSpec(kind: .burn, perSecond: 4, duration: 2), to: &effects)
    StatusRules.apply(StatusSpec(kind: .burn, perSecond: 2, duration: 3), to: &effects)
    StatusRules.apply(StatusSpec(kind: .slow, perSecond: 0, duration: 1), to: &effects)
    check(effects.count == 2 && effects[0].remaining == 3, "same status refreshes instead of stacking")
    let tick = StatusRules.step(&effects, dt: 0.5)
    check(abs(tick.health + 2) < 1e-9 && tick.speed == 0.5, "burn damages, slow halves speed")
    _ = StatusRules.step(&effects, dt: 5)
    check(effects.isEmpty, "statuses expire")
    // Boss phases.
    let script = BossDirector.example(id: "boss")
    check(script.valid && script.phases.count == 3, "three-phase example boss")
    check(BossDirector.phase(script, health: 400, maxHealth: 400) == 0 && BossDirector.phase(script, health: 250, maxHealth: 400) == 1 && BossDirector.phase(script, health: 100, maxHealth: 400) == 2, "phases change with health")
    let phase = script.phases[2]
    let ready = Set(phase.skills.map(\.skillID))
    check(BossDirector.pick(phase, ready: ready, roll: 0.1) == "tpl.beam" && BossDirector.pick(phase, ready: ready, roll: 0.99) == "tpl.shockwave", "skills picked by weight")
    check(BossDirector.pick(phase, ready: ["tpl.meteor"], roll: 0.1) == "tpl.meteor" && BossDirector.pick(phase, ready: [], roll: 0.5) == nil, "only skills off cooldown")
    check(BossDirector.summonCount(SummonSpec(count: 3, cap: 4), alive: 3) == 1 && BossDirector.summonCount(SummonSpec(count: 3, cap: 4), alive: 5) == 0, "summons never exceed the cap")
    var badScript = script; badScript.phases[0].threshold = 0.5
    check(!badScript.valid, "first phase must start at full health")
    // Camera.
    check(ThirdPersonCamera.yawBehind(facing: 90) == 0, "behind a player facing north")
    check(abs(ThirdPersonCamera.approach(350, 10, rate: 90, dt: 0.1) - 359) < 1e-9, "turns the short way, smoothly")
    let walls = SpatialGeometry(blocks: (0..<5).map { SpatialBlock(id: "c\($0)", x: 120 + $0 - 2, y: 116, elevation: 0, thickness: 6) })
    var behind = SpatialCameraState(target: SpatialVector(120.5, 120.5, 0), tilt: 62, yaw: 0, distance: 8)
    let clear = ThirdPersonCamera.clearDistance(behind, wanted: 8, geometry: walls)
    check(clear < 8 && clear >= SpatialCameraRules.minDistance, "camera pulls in in front of a wall (\(clear))")
    behind.yaw = 180
    check(ThirdPersonCamera.clearDistance(behind, wanted: 8, geometry: walls) == 8, "no wall, no change")
    let lockable = [CreatureEntity(id: "near", kind: .enemy, position: SpatialVector(122, 120, 0), home: .zero, health: 5, maxHealth: 5, damage: 1),
                    CreatureEntity(id: "behind", kind: .enemy, position: SpatialVector(118.5, 120, 0), home: .zero, health: 5, maxHealth: 5, damage: 1),
                    CreatureEntity(id: "calm", kind: .neutral, position: SpatialVector(121, 120, 0), home: .zero, health: 5, maxHealth: 5, damage: 0)]
    check(ThirdPersonCamera.lockTarget(player: SpatialVector(120, 120, 0), facing: 0, creatures: lockable) == "near", "locks the hostile in front")
    // Saving the new data.
    var full = map
    var spatial = SpatialWorld.blank()
    spatial.skills = templates; spatial.bossScripts = [script]; spatial.hotbar = ["tpl.fireball", "tpl.beam"]
    spatial.creatures = [CreatureEntity(id: "boss1", kind: .boss, position: SpatialVector(50, 50, 0), home: SpatialVector(50, 50, 0), health: 400, maxHealth: 400, damage: 16, bossScriptID: "boss")]
    full.spatial = spatial
    check((try? RPGWorldCodec.decode(RPGWorldCodec.encode(full)))?.spatial == spatial, "skills, scripts and hotbar saved and reopened")
    var dangling = full; dangling.spatial?.creatures[0].bossScriptID = "missing"; rejected(dangling, "creatures must point at existing scripts")
    var badClip = full; badClip.spatial?.characters = [hero]; rejected(badClip, "character clips must point at media bindings")
    print("RPG skills: \(checks) total checks passed")
}


// P25: v1.60 battle: player casts, Boss phases, summons, statuses.
do {
    var arena = SpatialWorld.blank()
    arena.player.position = SpatialVector(100, 100, 0)
    arena.creatures = [CreatureEntity(id: "goblin", kind: .enemy, position: SpatialVector(103, 100, 0), home: SpatialVector(103, 100, 0), health: 20, maxHealth: 20, damage: 5),
                       CreatureEntity(id: "boss", kind: .boss, position: SpatialVector(106, 100, 0), home: SpatialVector(106, 100, 0), health: 400, maxHealth: 400, damage: 16, state: .chase)]
    var battle = SpatialBattle()
    var stamina = 100, health = 60
    check(battle.castPlayer("tpl.fireball", world: arena, origin: arena.player.position, facing: 0, target: nil, clock: 0, stamina: &stamina, health: &health) == .cast && stamina == 82, "player casts a skill, stamina spent")
    if case .cooldown = battle.castPlayer("tpl.fireball", world: arena, origin: arena.player.position, facing: 0, target: nil, clock: 0.5, stamina: &stamina, health: &health) { check(true, "cooldown respected") } else { check(false, "cooldown respected") }
    var low = 5
    check(battle.castPlayer("tpl.beam", world: arena, origin: arena.player.position, facing: 0, target: nil, clock: 1, stamina: &low, health: &health) == .stamina, "not enough stamina")
    check(battle.castPlayer("tpl.heal", world: arena, origin: arena.player.position, facing: 0, target: nil, clock: 1, stamina: &stamina, health: &health) == .cast && health == 95, "healing restores health")
    var defeated: [CreatureEntity] = [], visuals = 0, dealt = 0
    for frame in 0..<180 {
        let out = battle.step(1.0 / 60, world: &arena, playerFacing: 0, playerInvulnerable: false, playerAlive: true, geometry: nil, clock: Double(frame) / 60, roll: { _, n in Double(n % 10) / 10 })
        defeated += out.defeated; visuals += out.visuals.count; dealt += out.playerDamage
    }
    check(defeated.map(\.id) == ["goblin"] && arena.creatures.first { $0.id == "goblin" }?.state == .dead, "fireball defeats the goblin")
    check(visuals > 10, "casts produce visuals")
    // Boss: casts by phase, changes phase, summons within the cap.
    var bossWorld = SpatialWorld.blank()
    bossWorld.player.position = SpatialVector(50, 50, 0)
    bossWorld.creatures = [CreatureEntity(id: "b", kind: .boss, position: SpatialVector(54, 50, 0), home: SpatialVector(54, 50, 0), health: 400, maxHealth: 400, damage: 16, state: .chase)]
    var fight = SpatialBattle(), bossDamage = 0
    for frame in 0..<600 {
        let out = fight.step(1.0 / 60, world: &bossWorld, playerFacing: 0, playerInvulnerable: false, playerAlive: true, geometry: nil, clock: Double(frame) / 60, roll: { _, n in Double(n % 7) / 7 })
        bossDamage += out.playerDamage
    }
    check(bossDamage > 0, "the boss casts its phase skills at the player (\(bossDamage) damage)")
    bossWorld.creatures[0].health = 240
    var changes: [(id: String, phase: Int, appearance: String?)] = []
    for frame in 600..<620 { changes += fight.step(1.0 / 60, world: &bossWorld, playerFacing: 0, playerInvulnerable: false, playerAlive: true, geometry: nil, clock: Double(frame) / 60, roll: { _, _ in 0.5 }).phaseChanges }
    check(changes.map(\.phase) == [1], "phase 2 starts below two thirds")
    let summons = bossWorld.creatures.filter { $0.id.hasPrefix("summon:b:") }
    check(summons.count == 2, "phase 2 summons two helpers")
    bossWorld.creatures[0].health = 100
    for frame in 620..<640 { _ = fight.step(1.0 / 60, world: &bossWorld, playerFacing: 0, playerInvulnerable: false, playerAlive: true, geometry: nil, clock: Double(frame) / 60, roll: { _, _ in 0.5 }) }
    check(bossWorld.creatures.filter { $0.id.hasPrefix("summon:b:") }.count == 2, "phase 3 has no summons; the cap is never passed")
    var safe = SpatialWorld.blank()
    safe.player.position = SpatialVector(10, 10, 0)
    safe.creatures = [CreatureEntity(id: "far", kind: .boss, position: SpatialVector(60, 60, 0), home: SpatialVector(60, 60, 0), health: 400, maxHealth: 400, damage: 16, state: .chase)]
    var quiet = SpatialBattle(), quietDamage = 0
    for frame in 0..<300 { quietDamage += quiet.step(1.0 / 60, world: &safe, playerFacing: 0, playerInvulnerable: false, playerAlive: true, geometry: nil, clock: Double(frame) / 60, roll: { _, _ in 0.3 }).playerDamage }
    check(quietDamage == 0, "a distant boss never attacks")
    var dodge = SpatialBattle(), dodgeDamage = 0
    var close = bossWorld; close.creatures = [CreatureEntity(id: "b2", kind: .boss, position: SpatialVector(52, 50, 0), home: SpatialVector(52, 50, 0), health: 400, maxHealth: 400, damage: 16, state: .chase)]
    for frame in 0..<400 { dodgeDamage += dodge.step(1.0 / 60, world: &close, playerFacing: 0, playerInvulnerable: true, playerAlive: true, geometry: nil, clock: Double(frame) / 60, roll: { _, n in Double(n % 5) / 5 }).playerDamage }
    check(dodgeDamage == 0, "invulnerable frames ignore boss hits")
    // Statuses tick on creatures.
    var burning = SpatialWorld.blank()
    burning.creatures = [CreatureEntity(id: "x", kind: .enemy, position: SpatialVector(5, 5, 0), home: .zero, health: 10, maxHealth: 10, damage: 1, statuses: [StatusEffect(kind: .burn, perSecond: 5, remaining: 3)])]
    var ticks = SpatialBattle()
    for frame in 0..<180 { _ = ticks.step(1.0 / 60, world: &burning, playerFacing: 0, playerInvulnerable: false, playerAlive: true, geometry: nil, clock: Double(frame) / 60, roll: { _, _ in 0 }) }
    check(burning.creatures[0].health == 0 && burning.creatures[0].state == .dead, "burning finishes off a weak enemy")
    // Underground: a dug hole drops the player onto a basement floor.
    var cave = SpatialGeometry(blocks: [SpatialBlock(id: "basement", x: 30, y: 30, elevation: -4.3, thickness: 0.3)])
    cave.groundHoles = [30 * 256 + 30]
    var digger = SpatialPlayer(); digger.position = SpatialVector(30.5, 30.5, 0); digger.lastSafe = digger.position
    for _ in 0..<120 { SpatialPhysics.step(&digger, input: SpatialInput(), dt: 1.0 / 60, geometry: cave, previous: cave) }
    check(abs(digger.position.z + 4) < 1e-6 && digger.grounded, "falls through the hole onto the basement floor")
    var solidGround = cave; solidGround.groundHoles = []
    var stander = SpatialPlayer(); stander.position = SpatialVector(30.5, 30.5, 0)
    for _ in 0..<30 { SpatialPhysics.step(&stander, input: SpatialInput(), dt: 1.0 / 60, geometry: solidGround, previous: solidGround) }
    check(stander.position.z == 0, "no hole, no fall")
    check(SpatialNavigator(geometry: cave).surfaces(x: 30, y: 30) == [-4], "navigation sees the basement, not the ground")
    check(SpatialBlock(id: "deep", x: 1, y: 1, elevation: -16).valid && !SpatialBlock(id: "too deep", x: 1, y: 1, elevation: -17).valid, "underground down to 16 below")
    var sparse = WorldGenerationConfiguration(); sparse.plantAmount = 0; sparse.enemyAmount = 0; sparse.floatingIslands = true; sparse.seed = 77
    let sparseWorld = SpatialWorldGenerator.generate(sparse, keeping: .blank())
    check(sparseWorld.summary.enemies == 0 && sparseWorld.summary.guards <= 1 && sparseWorld.summary.problems.isEmpty, "amount sliders: no plants or enemies (\(sparseWorld.summary))")
    let oldRecord = try JSONDecoder().decode(WorldGenerationConfiguration.self, from: Data(#"{"style":"mixed","density":"medium","difficulty":"normal","maze":true,"miniBoss":true,"bigBoss":true,"seed":5}"#.utf8))
    check(oldRecord.buildingFactor == 1 && oldRecord.floatingIslands == nil, "v1.58 generator settings still open")
    print("RPG battle: \(checks) total checks passed")
}

// P26: v1.61 game controller mapping (Xbox layout).
do {
    check(SpatialGamepad.shaped(0.1, 0.1) == (0, 0), "stick drift inside the dead zone is ignored")
    let full = SpatialGamepad.shaped(1, 0)
    check(abs(full.x - 1) < 1e-9 && full.y == 0, "full push stays full")
    check(SpatialGamepad.shaped(.nan, 1) == (0, 0), "bad stick values are ignored")
    var pad = SpatialPadState(); pad.leftY = 1; pad.rightX = -1
    let move = SpatialGamepad.move(pad), look = SpatialGamepad.look(pad)
    check(move.x == 0 && abs(move.y + 1) < 1e-9, "left stick up = forward (screen-up, like the touch stick)")
    check(abs(look.x + 1) < 1e-9 && look.y == 0, "right stick left = look left")
    var down = SpatialPadState(); down.buttons = [.a, .x]
    check(SpatialGamepad.actions(down, previous: SpatialPadState(), playing: true) == [.jump, .attack], "A jumps, X attacks")
    check(SpatialGamepad.actions(down, previous: down, playing: true).isEmpty, "holding a button does not repeat")
    var triggers = SpatialPadState(); triggers.rightTrigger = 0.8
    check(SpatialGamepad.actions(triggers, previous: SpatialPadState(), playing: true) == [.hotbar(3)], "RT casts skill slot 4")
    var light = SpatialPadState(); light.rightTrigger = 0.3
    check(SpatialGamepad.actions(light, previous: SpatialPadState(), playing: true).isEmpty, "a light trigger touch does nothing")
    check(SpatialGamepad.action(for: .y, playing: true) == .skill && SpatialGamepad.action(for: .b, playing: true) == .dodge, "Y skill, B dodge")
    check(SpatialGamepad.action(for: .rightStick, playing: true) == .lock, "right stick click locks on")
    check(SpatialGamepad.action(for: .menu, playing: true) == .switchMode && SpatialGamepad.action(for: .menu, playing: false) == .switchMode, "Menu switches play / design")
    check(SpatialGamepad.action(for: .a, playing: false) == .backToCharacter && SpatialGamepad.action(for: .rightShoulder, playing: false) == .flyUp, "design: A back to character, RB fly up")
    var zoomIn = SpatialPadState(); zoomIn.rightTrigger = 1
    check(SpatialGamepad.zoomFactor(zoomIn, dt: 0.1) > 1 && SpatialGamepad.zoomFactor(SpatialPadState(), dt: 0.1) == 1, "design: RT zooms in, idle no zoom")
    print("RPG gamepad: \(checks) total checks passed")
}

// P27: v1.62 native glass steadiness: fade while the camera moves, steady
// face selection at the budget edge.
do {
    var fade = NativeGlassFade()
    var cam = SpatialCameraState()
    check(fade.step(camera: cam, dt: 1.0 / 60) == 1, "starts shown with a still camera")
    for _ in 0..<12 { cam.yaw += 1; _ = fade.step(camera: cam, dt: 1.0 / 60) }
    check(fade.visibility == 0, "hidden within 0.1 s of camera motion")
    _ = fade.step(camera: cam, dt: 1.0 / 60)
    for _ in 0..<10 { _ = fade.step(camera: cam, dt: 1.0 / 60) }
    check(fade.visibility == 0, "stays hidden until the camera has settled 0.2 s")
    for _ in 0..<8 { _ = fade.step(camera: cam, dt: 1.0 / 60) }
    check(fade.visibility > 0 && fade.visibility < 1, "fades back in after settling (\(fade.visibility))")
    for _ in 0..<30 { _ = fade.step(camera: cam, dt: 1.0 / 60) }
    check(fade.visibility == 1, "fully shown again")
    _ = fade.step(camera: cam, dt: 1.0 / 60, shaking: true)
    check(fade.visibility < 1, "screen shake counts as motion")
    var wrap = SpatialCameraState(); wrap.yaw = 359.99
    var wrapped = wrap; wrapped.yaw = -0.005
    check(!NativeGlassFade.moved(wrap, wrapped), "yaw wrap-around is not motion")
    var nudge = SpatialCameraState(); nudge.target = nudge.target + SpatialVector(0.01, 0, 0)
    check(NativeGlassFade.moved(SpatialCameraState(), nudge), "a small pan is motion")
    check(fade.step(camera: cam, dt: .nan) == fade.visibility, "bad frame time ignored")

    let row = (0..<20).map { SpatialBlock(id: String(format: "b%02d", $0), x: $0, y: 0, elevation: 0) }
    let first = SpatialFaces.nearest(row, to: SpatialVector(0.5, 0.5, 0), budget: 5)
    check(first.map(\SpatialBlock.id) == ["b00", "b01", "b02", "b03", "b04"], "nearest five")
    let drifted = SpatialFaces.nearest(row, to: SpatialVector(1.2, 0.5, 0), budget: 5, keeping: Set(first.map(\SpatialBlock.id)))
    check(Set(drifted.map(\SpatialBlock.id)) == Set(first.map(\SpatialBlock.id)), "a small drift keeps the same blocks")
    let far = SpatialFaces.nearest(row, to: SpatialVector(10.5, 0.5, 0), budget: 5, keeping: Set(first.map(\SpatialBlock.id)))
    check(Set(far.map(\SpatialBlock.id)) == ["b08", "b09", "b10", "b11", "b12"], "a real move picks the new nearest blocks")
    print("RPG glass steadiness: \(checks) total checks passed")
}

// P28: v1.63 revive clears what would kill the player again at once.
do {
    var reviveWorld = SpatialWorld.blank()
    var foe = CreatureEntity(id: "foe", kind: .boss, position: SpatialVector(132, 128.5, 0), home: SpatialVector(132, 128.5, 0), health: 400, maxHealth: 400, damage: 20)
    foe.bossScriptID = nil
    reviveWorld.creatures = [foe]
    var revive = SpatialBattle()
    var stamina = 100, life = 100
    _ = revive.castPlayer("tpl.fireball", world: reviveWorld, origin: reviveWorld.spawn, facing: 0, target: nil, clock: 0, stamina: &stamina, health: &life)
    let playerCasts = revive.casts.count
    StatusRules.apply(StatusSpec(kind: .burn), to: &revive.playerStatuses)
    check(!revive.playerStatuses.isEmpty, "burning before revive")
    revive.playerRevived()
    check(revive.playerStatuses.isEmpty, "revive ends burns and slows")
    check(revive.casts.count == playerCasts && revive.casts.allSatisfy { $0.casterID == SpatialBattle.playerID }, "revive keeps the player's own skills, drops enemy ones")
    print("RPG revive: \(checks) total checks passed")
}

// P29: v1.65 open asset libraries: starter pack manifest, character recipe,
// Poly Haven and Openverse parsing, licence labels.
do {
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: "Resources/Glass3DStarter/manifest.json"))
    let manifest = StarterManifest.decode(manifestData)
    check(manifest != nil && manifest!.items.count >= 40, "starter manifest decodes")
    if let manifest {
        check(manifest.items.allSatisfy { FileManager.default.fileExists(atPath: "Resources/Glass3DStarter/" + $0.file) }, "every starter file is bundled")
        check(manifest.items.allSatisfy { $0.license.hasPrefix("CC0") && !$0.attribution.needsCredit }, "starter pack is all CC0")
        check(manifest.characters.count == 5 && manifest.characters.allSatisfy { $0.poses.count == 7 }, "five starter characters, seven poses each")
        check(manifest.items.filter { $0.group == "textures" }.count >= 10, "starter textures")
    }
    let poseBindings = ["idle": "b-idle", "walk": "b-walk", "jump": "b-jump", "fall": "b-fall", "attack": "b-attack", "hurt": "b-hurt", "cheer": "b-cheer"]
    let hero = StarterCharacterRecipe.template(id: "char:starter", name: "Adventurer", bindings: poseBindings)
    check(hero.valid, "starter character is valid")
    check(hero.clips["run"]?.bindingIDs == ["b-walk"] && (hero.clips["run"]?.speed ?? 0) > 1, "run reuses the walk GIF, faster")
    check(hero.clips["attack"]?.loop == false && hero.clips["idle"]?.loop == true, "attack plays once, idle loops")
    check(hero.clips.count == CharacterAction.allCases.count, "every action has a pose")
    check(StarterCharacterRecipe.clips(bindings: ["idle": "x"]).keys.sorted() == ["idle"], "missing poses are left out")

    let haven = Data(#"{"red_brick":{"name":"Red Brick","categories":["brick","wall"],"tags":["red"],"authors":{"Rob Tuytel":"All"},"download_count":900},"plywood":{"name":"Plywood","categories":["wood"],"download_count":1200}}"#.utf8)
    let textures = OnlineAssetParsing.polyHaven(haven)
    check(textures.map(\.id) == ["plywood", "red_brick"], "Poly Haven: most downloaded first")
    check(textures.last?.attribution.author == "Rob Tuytel" && textures.last?.thumbnail.absoluteString.hasPrefix("https://cdn.polyhaven.com/") == true, "Poly Haven author and thumbnail")
    check(OnlineAssetParsing.filter(textures, query: "RED wall").map(\.id) == ["red_brick"], "Poly Haven search by tag and category")
    let files = Data(#"{"Diffuse":{"1k":{"jpg":{"url":"https://dl.polyhaven.org/a/red_brick_diff_1k.jpg"}}}}"#.utf8)
    check(OnlineAssetParsing.polyHavenDiffuse(files)?.lastPathComponent == "red_brick_diff_1k.jpg", "Poly Haven colour map")
    check(OnlineAssetParsing.polyHavenDiffuse(Data("{}".utf8)) == nil, "no colour map, no download")

    let verse = Data(#"{"results":[{"id":"a1","title":"Resume - Glasses","url":"https://live.staticflickr.com/7068/13903383190_5920c870e1_b.jpg","creator":"flazingo_photos","license":"by-sa","license_version":"2.0","license_url":"https://creativecommons.org/licenses/by-sa/2.0/","provider":"flickr","foreign_landing_url":"https://www.flickr.com/photos/x","thumbnail":"https://api.openverse.org/v1/images/a1/thumb/","attribution":"\"Resume - Glasses\" by flazingo_photos is licensed under CC BY-SA 2.0."},{"id":"a2","title":" ","url":"http://example.org/pic.png","license":"cc0","thumbnail":"https://api.openverse.org/v1/images/a2/thumb/"}]}"#.utf8)
    let images = OnlineAssetParsing.openverse(verse)
    check(images.count == 2, "Openverse results")
    check(images[0].download?.host == "live.staticflickr.com" && images[0].attribution.license == "CC BY-SA 2.0" && images[0].attribution.needsCredit, "Openverse original, licence label, needs credit")
    check(images[1].download?.host == "api.openverse.org" && images[1].title == "Untitled" && !images[1].attribution.needsCredit, "http original falls back to the https thumbnail; CC0 needs no credit")
    check(OnlineAssetParsing.openverseURL(query: " moon ", page: 2, cc0Only: true)?.query?.contains("license=cc0,pdm") == true, "CC0-only search")
    let defaultSearch = OnlineAssetParsing.openverseURL(query: "moon", page: 1, cc0Only: false)?.query ?? ""
    check(defaultSearch.contains("license=by,by-sa,cc0,pdm") && !defaultSearch.contains("nd") && !defaultSearch.contains("nc"), "default search: commercial use and adaptation allowed, no ND / NC")
    check(OnlineAssetParsing.licenseLabel("pdm", "") == "Public Domain" && OnlineAssetParsing.licenseLabel("by", "4.0") == "CC BY 4.0", "licence labels")
    print("RPG asset library: \(checks) total checks passed")
}

// P30: v1.67 local 3D generation core: depth → real mesh, mesh file, OBJ,
// manifest, video frame quality and assessment.
do {
    // A dome: nearer in the middle, subject = disc.
    let side = 64
    var near = [Float](repeating: 0, count: side * side), disc = near
    for y in 0..<side { for x in 0..<side {
        let dx = Double(x - side / 2) / Double(side / 2), dy = Double(y - side / 2) / Double(side / 2)
        let r = (dx * dx + dy * dy).squareRoot()
        disc[y * side + x] = r < 0.8 ? 1 : 0
        near[y * side + x] = Float(max(0, 1 - r))
    } }
    let field = DepthField(width: side, height: side, nearness: near, mask: disc)
    check(field.valid && abs(field.subjectCoverage() - 0.5) < 0.05, "depth field and subject coverage")
    var options = DepthMeshBuilder.Options(); options.resolution = 48
    var dome = try DepthMeshBuilder.build(field, aspect: 1, options: options)
    check(dome.valid, "mesh is valid")
    check(dome.depthExtent > 0.2, "real 3D: the mesh has depth, not a flat card (\(dome.depthExtent))")
    let zs = stride(from: 2, to: dome.positions.count, by: 3).map { dome.positions[$0] }
    check(Set(zs.map { Int($0 * 100) }).count > 10, "many distinct depths across the surface")
    let frontVertices = dome.vertexCount / 2
    let centre = (0..<frontVertices).min { a, b in
        let pa = (dome.positions[a * 3], dome.positions[a * 3 + 1]), pb = (dome.positions[b * 3], dome.positions[b * 3 + 1])
        return pa.0 * pa.0 + pa.1 * pa.1 < pb.0 * pb.0 + pb.1 * pb.1
    }!
    check(dome.positions[centre * 3 + 2] > 0.25, "the nearest part (centre of the dome) comes forward")
    var openOptions = options; openOptions.closed = false
    let open = try DepthMeshBuilder.build(field, aspect: 1, options: openOptions)
    check(dome.triangleCount > open.triangleCount * 2, "closed model adds a back and side walls")
    // Watertight: every edge of the closed model is shared by exactly two triangles.
    var edges: [String: Int] = [:]
    for t in 0..<dome.triangleCount {
        let tri = (0..<3).map { Int(dome.indices[t * 3 + $0]) }
        for (a, b) in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])] { edges["\(min(a, b))-\(max(a, b))", default: 0] += 1 }
    }
    check(edges.values.allSatisfy { $0 == 2 }, "closed model is watertight")
    check(dome.uvs.allSatisfy { $0 >= 0 && $0 <= 1 }, "texture coordinates inside the picture")
    let normalLengths: [Float] = (0..<dome.vertexCount).map { i -> Float in
        let nx: Float = dome.normals[i * 3], ny: Float = dome.normals[i * 3 + 1], nz: Float = dome.normals[i * 3 + 2]
        return (nx * nx + ny * ny + nz * nz).squareRoot()
    }
    check(normalLengths.allSatisfy { abs($0 - 1) < 0.01 }, "unit normals")
    dome.normalize(size: 1)
    let b = dome.bounds
    check(abs(b.max[0] + b.min[0]) < 0.01 && max(b.max[0] - b.min[0], b.max[1] - b.min[1], b.max[2] - b.min[2]) <= 1.0001, "normalised: centred, fits in 1")
    let wide = try DepthMeshBuilder.build(field, aspect: 2, options: options)
    let wb = wide.bounds
    check((wb.max[0] - wb.min[0]) > (wb.max[1] - wb.min[1]) * 1.5, "picture aspect kept")
    check((try? DepthMeshBuilder.build(DepthField(width: side, height: side, nearness: near, mask: near.map { _ in 0 }), aspect: 1)) == nil, "no subject, no model")
    check((try? DepthMeshBuilder.build(DepthField(width: 1, height: 1, nearness: [0], mask: [1]), aspect: 1)) == nil, "invalid field rejected")
    let flat = try DepthMeshBuilder.build(DepthField(width: side, height: side, nearness: near.map { _ in 0.5 }, mask: disc), aspect: 1, options: options)
    check(flat.valid, "flat depth still gives a valid closed plate")

    let encoded = GeneratedMeshCodec.encode(dome)
    check(GeneratedMeshCodec.decode(encoded) == dome, "mesh file round trip")
    check(GeneratedMeshCodec.decode(encoded.dropLast(4)) == nil && GeneratedMeshCodec.decode(Data("nope".utf8)) == nil, "broken mesh files rejected")
    let obj = OBJWriter.obj(open, materialFile: "model.mtl")
    check(obj.contains("mtllib model.mtl") && obj.components(separatedBy: "\nv ").count - 1 == open.vertexCount && obj.components(separatedBy: "\nf ").count - 1 == open.triangleCount, "OBJ export")
    check(OBJWriter.mtl(texture: "texture.jpg").contains("map_Kd texture.jpg"), "MTL points at the texture")

    let manifest = Generated3DManifest(id: "m1", name: "Dome", createdAt: Date(timeIntervalSince1970: 0), source: .image, sourceName: "dome.jpg", sourceHash: "abc",
                                       engine: "DepthMesh", engineVersion: "1.0", depthSource: .depthAnythingV2, geometry: .depthRelief, quality: .medium,
                                       vertexCount: dome.vertexCount, triangleCount: dome.triangleCount, textureWidth: 1024, textureHeight: 1024,
                                       meshFile: "mesh.m3dg", textureFile: "texture.jpg", usdzFile: nil, thumbnailFile: nil,
                                       humanoidDetected: false, rigging: .experimentalNotImplemented, animation: .experimentalNotImplemented, separableParts: .notAvailable)
    let reopened = try JSONDecoder().decode(Generated3DManifest.self, from: JSONEncoder().encode(manifest))
    check(reopened == manifest && reopened.valid, "manifest round trip")
    check(reopened.rigging != .ready && reopened.animation != .ready, "experimental rigging is never marked ready")
    check(GenerationQuality.recommended(memory: 8_000_000_000, thermal: 0) == .high && GenerationQuality.recommended(memory: 8_000_000_000, thermal: 2) == .low && GenerationQuality.recommended(memory: 4_000_000_000, thermal: 0) == .medium, "quality follows memory and temperature")
    check(GenerationQuality.allCases.allSatisfy { (1024...2048).contains($0.textureSize) }, "textures 1024–2048")

    // Frames.
    let sharpImage = (0..<(32 * 32)).map { UInt8(($0 % 2 == 0) != (($0 / 32) % 2 == 0) ? 255 : 0) }
    let blurImage = [UInt8](repeating: 128, count: 32 * 32)
    check(FrameQuality.sharpness(sharpImage, width: 32, height: 32) > 1000 && FrameQuality.sharpness(blurImage, width: 32, height: 32) == 0, "sharpness: checkerboard sharp, flat grey blurry")
    let ramp = (0..<72).map { UInt8(($0 % 9) * 20) }
    check(FrameQuality.differenceHash(ramp) == 0 && FrameQuality.differenceHash(ramp.reversed()) != 0, "difference hash")
    check(FrameQuality.downscale(sharpImage, width: 32, height: 32, to: 9, 8).count == 72, "downscale for hashing")
    var frames: [FrameStat] = []
    for i in 0..<40 { frames.append(FrameStat(index: i, time: Double(i) / 2, sharpness: i % 10 == 0 ? 1 : 200, hash: UInt64(i) * 0x0F0F_0F0F, shiftX: 0.06)) }
    frames.append(FrameStat(index: 40, time: 20, sharpness: 200, hash: UInt64(39) * 0x0F0F_0F0F, shiftX: 0.06))
    let picked = FrameQuality.select(frames)
    check(picked.blurry == 4 && picked.duplicates == 1 && picked.kept.count == 36, "blurry and duplicate frames dropped (\(picked.blurry), \(picked.duplicates), \(picked.kept.count))")
    check(VideoAssessment.assess(picked.kept).canReconstruct, "orbit video: multi-view ready")
    let still = picked.kept.map { f -> FrameStat in var g = f; g.shiftX = 0.002; return g }
    check(VideoAssessment.assess(still) == .insufficientViews(frames: still.count, sweep: still.reduce(0) { $0 + abs($1.shiftX) }), "camera barely moved: not reconstructable")
    let person = still.map { f -> FrameStat in var g = f; g.person = true; return g }
    check(VideoAssessment.assess(person) == .personFixedCamera, "fixed-camera person video recognised")
    check(VideoAssessment.assess(Array(picked.kept.prefix(3))) == .tooFewFrames(frames: 3), "too few frames")
    check(!VideoAssessment.personFixedCamera.canReconstruct && !VideoAssessment.personFixedCamera.message.isEmpty, "only multi-view input goes to reconstruction")

    check(PixelMath.half(0x3C00) == 1 && PixelMath.half(0xC000) == -2 && PixelMath.half(0x0000) == 0 && abs(PixelMath.half(0x3555) - 0.3333) < 0.001, "half floats")
    check(PixelMath.nearness(fromDepth: [2, 0, .nan]) == [0.5, 0, 0], "metric depth to nearness")
    let otsu = PixelMath.otsuMask([0.1, 0.12, 0.11, 0.9, 0.95, 0.92])
    check(otsu == [0, 0, 0, 1, 1, 1], "depth-only subject mask")
    print("RPG generate 3D: \(checks) total checks passed")
}

// P31: P2 experimental auto rig: skeleton from 2D joints, weights, clips,
// skinning and the validator, on a synthetic standing figure.
do {
    // 100×160 picture: head, torso, arms hanging at the sides, two legs.
    let w = 100, h = 160
    var mask = [Float](repeating: 0, count: w * h), depth = mask
    func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ d: Float) { for y in y0..<y1 { for x in x0..<x1 { mask[y * w + x] = 1; depth[y * w + x] = d } } }
    fill(42, 4, 58, 26, 0.9)     // head
    fill(34, 28, 66, 82, 1.0)    // torso
    fill(22, 30, 32, 80, 0.8)    // subject's right arm (picture left)
    fill(68, 30, 78, 80, 0.8)    // subject's left arm
    fill(36, 84, 48, 154, 0.85)  // right leg
    fill(52, 84, 64, 154, 0.85)  // left leg
    let figureField = DepthField(width: w, height: h, nearness: depth, mask: mask)
    var figureOptions = DepthMeshBuilder.Options(); figureOptions.resolution = 96; figureOptions.smoothingPasses = 0
    var figure = try DepthMeshBuilder.build(figureField, aspect: Double(w) / Double(h), options: figureOptions)
    figure.normalize(size: 1)
    func joint(_ x: Double, _ y: Double) -> BodyJoints2D.Point { .init(u: x / Double(w), v: y / Double(h), confidence: 0.9) }
    let pose = BodyJoints2D(points: [
        "head_joint": joint(50, 14), "neck_1_joint": joint(50, 28), "root": joint(50, 82),
        "right_shoulder_1_joint": joint(27, 32), "right_forearm_joint": joint(27, 55), "right_hand_joint": joint(27, 78),
        "left_shoulder_1_joint": joint(73, 32), "left_forearm_joint": joint(73, 55), "left_hand_joint": joint(73, 78),
        "right_upLeg_joint": joint(42, 86), "right_leg_joint": joint(42, 118), "right_foot_joint": joint(42, 150),
        "left_upLeg_joint": joint(58, 86), "left_leg_joint": joint(58, 118), "left_foot_joint": joint(58, 150),
    ])
    let map = AutoRig.uvToXY(figure)
    check(map != nil && map!.ax > 0 && map!.ay < 0, "picture to model mapping fitted")
    let skeleton = try AutoRig.skeleton(for: figure, joints: pose)
    check(skeleton.bones.count == RigBone.allCases.count, "ten bones from a full pose (\(skeleton.bones.count))")
    let torso = skeleton.bone(.torso)!, rightArm = skeleton.bone(.rightUpperArm)!
    check(torso.tail[1] > torso.head[1] && rightArm.head[0] < torso.head[0], "torso points up; subject's right arm on the picture's left")
    let fb = figure.bounds
    check(skeleton.bones.allSatisfy { $0.head[2] >= fb.min[2] - 0.001 && $0.head[2] <= fb.max[2] + 0.001 }, "joints sit inside the model's depth")
    let skin = AutoRig.weights(for: figure, skeleton: skeleton)
    check(skin.valid && skin.count == figure.vertexCount, "skin weights for every vertex")
    check(SkinWeights.decode(skin.encoded()) == skin && SkinWeights.decode(Data("SKN1".utf8)) == nil, "skin file round trip")
    // Hand vertices follow the forearm; foot vertices the shin.
    func nearest(_ x: Double, _ y: Double) -> Int {
        let tx = map!.ax * Float(x / Double(w)) + map!.bx, ty = map!.ay * Float(y / Double(h)) + map!.by
        return (0..<figure.vertexCount).min { a, b in
            let da = pow(figure.positions[a * 3] - tx, 2) + pow(figure.positions[a * 3 + 1] - ty, 2)
            let db = pow(figure.positions[b * 3] - tx, 2) + pow(figure.positions[b * 3 + 1] - ty, 2)
            return da < db
        }!
    }
    let hand = nearest(27, 76), foot = nearest(58, 150), chest = nearest(50, 50)
    check(skin.bone0[hand] == UInt8(RigBone.rightForearm.rawValue), "hand bound to the forearm")
    check(skin.bone0[foot] == UInt8(RigBone.leftShin.rawValue), "foot bound to the shin")
    check(skin.bone0[chest] == UInt8(RigBone.torso.rawValue), "chest bound to the torso")
    let rest = RigPose.deform(figure, skin: skin, matrices: RigPose.matrices(skeleton, clip: nil, time: 0))
    check(zip(rest.positions, figure.positions).allSatisfy { abs($0 - $1) < 1e-5 }, "rest pose leaves the mesh unchanged")
    let wave = RigClip.standard.first { $0.id == "wave" }!
    let waved = RigPose.deform(figure, skin: skin, matrices: RigPose.matrices(skeleton, clip: wave, time: 0.3)).positions
    func moved(_ i: Int) -> Float { (0..<3).map { waved[i * 3 + $0] - figure.positions[i * 3 + $0] }.reduce(0) { $0 + $1 * $1 }.squareRoot() }
    check(moved(hand) > 0.2 && moved(foot) < 0.001 && waved[hand * 3 + 1] > figure.positions[hand * 3 + 1], "wave lifts the right hand, feet stay")
    let walk = RigClip.standard.first { $0.id == "walk" }!
    let walked = RigPose.deform(figure, skin: skin, matrices: RigPose.matrices(skeleton, clip: walk, time: 0.27)).positions
    check(abs(walked[foot * 3 + 2] - figure.positions[foot * 3 + 2]) > 0.02, "walk swings the leg forward / back")
    let validation = RigValidation.run(figure, skeleton: skeleton, skin: skin)
    check(validation.passed, "validator passes the figure (\(validation.problems), stretch \(validation.maxStretch))")
    check(validation.clips.count == 4 && validation.clips.values.allSatisfy { $0 > 0.004 } && validation.clips["walk"]! > 0.02, "every clip moves something")
    let package = RigPackage(skeleton: skeleton, joints: pose, clips: RigClip.standard, validation: validation)
    check((try? JSONDecoder().decode(RigPackage.self, from: JSONEncoder().encode(package))) == package, "rig package round trip")
    let regions = RigPose.triangleRegions(figure, skin: skin)
    check(Set(regions) == [0, 1, 2, 3], "four body regions for colours")

    var partial = pose; partial.points["left_upLeg_joint"] = nil
    check((try? AutoRig.skeleton(for: figure, joints: partial)) == nil, "missing hip: not humanoid, no rig")
    var lowConfidence = pose; lowConfidence.points["neck_1_joint"]?.confidence = 0.1
    check((try? AutoRig.skeleton(for: figure, joints: lowConfidence)) == nil, "unsure neck: no rig")
    var noForearms = pose; noForearms.points["right_hand_joint"] = nil
    check((try? AutoRig.skeleton(for: figure, joints: noForearms))?.bone(.rightForearm) == nil, "missing wrist: forearm left out, arm still rigged")
    let identity = Mat4.rotation(axis: [0, 0, 1], angle: .pi / 2).point([1, 0, 0])
    check(abs(identity[0]) < 1e-6 && abs(identity[1] - 1) < 1e-6, "rotation maths")
    print("RPG auto rig: \(checks) total checks passed")
}

// P32: mirrored back (a guess for the unseen side, labelled as such).
do {
    let side = 48
    var near = [Float](repeating: 0, count: side * side), disc = near
    for y in 0..<side { for x in 0..<side {
        let dx = Double(x - side / 2) / Double(side / 2), dy = Double(y - side / 2) / Double(side / 2)
        let r = (dx * dx + dy * dy).squareRoot()
        disc[y * side + x] = r < 0.8 ? 1 : 0; near[y * side + x] = Float(max(0, 1 - r))
    } }
    var flatOptions = DepthMeshBuilder.Options(); flatOptions.resolution = 40
    var mirroredOptions = flatOptions; mirroredOptions.back = .mirrored
    let field = DepthField(width: side, height: side, nearness: near, mask: disc)
    let flatBack = try DepthMeshBuilder.build(field, aspect: 1, options: flatOptions)
    let mirrored = try DepthMeshBuilder.build(field, aspect: 1, options: mirroredOptions)
    check(mirrored.valid && mirrored.triangleCount == flatBack.triangleCount, "mirrored back keeps the same topology")
    check(mirrored.depthExtent > flatBack.depthExtent * 1.4, "mirrored back adds volume behind")
    let backZs = Set((flatBack.vertexCount / 2..<flatBack.vertexCount).map { flatBack.positions[$0 * 3 + 2] })
    check(backZs.count == 1, "flat back is one plane")
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Generated3DManifest(id: "x", name: "x", createdAt: Date(timeIntervalSince1970: 0), source: .image, sourceName: "x", sourceHash: "h", engine: "e", engineVersion: "1", depthSource: .cameraDepth, geometry: .depthRelief, quality: .low, vertexCount: 1, triangleCount: 1, textureWidth: 1, textureHeight: 1, meshFile: "m", textureFile: nil, usdzFile: nil, thumbnailFile: nil, humanoidDetected: true, rigging: .experimentalNotImplemented, animation: .experimentalNotImplemented, separableParts: .notAvailable))) as! [String: Any]
    legacy["backStyle"] = nil; legacy["rigFile"] = nil
    let old = try? JSONDecoder().decode(Generated3DManifest.self, from: JSONSerialization.data(withJSONObject: legacy))
    check(old != nil && old!.backStyle == nil && old!.rigFile == nil, "v1.67 manifests still open")
    print("RPG mirrored back: \(checks) total checks passed")
}

// P33: v1.69 quality: shape from the outline (round cross sections),
// no side walls, colour-only back, edge snapping, guided depth upsampling.
do {
    func radial(_ mesh: GeneratedMesh, _ i: Int) -> Float {
        let x: Float = mesh.positions[i * 3], y: Float = mesh.positions[i * 3 + 1]
        return (x * x + y * y).squareRoot()
    }
    func zOf(_ mesh: GeneratedMesh, _ i: Int) -> Float { mesh.positions[i * 3 + 2] }

    // A long strip 21 cells wide: the cross-section should be a half circle.
    let sw = 60, sh = 23
    var strip = [Bool](repeating: false, count: sw * sh)
    for y in 1..<22 { for x in 0..<sw { strip[y * sw + x] = true } }
    let swell = DepthRefine.inflation(strip, width: sw, height: sh, iterations: 400)
    let centre = swell[11 * sw + 30], quarter = swell[6 * sw + 30]
    check(abs(centre - 11) < 1.5, "strip centre as high as half its width (\(centre))")
    check(abs(quarter - (5 * 17 as Float).squareRoot()) < 1.5, "half-circle cross section (\(quarter))")

    // Body with a thin arm: the arm is thinner than the body.
    let bw = 80, bh = 60
    var bodyMask = [Float](repeating: 0, count: bw * bh)
    for y in 10..<50 { for x in 10..<40 { bodyMask[y * bw + x] = 1 } }   // wide body
    for y in 26..<34 { for x in 40..<75 { bodyMask[y * bw + x] = 1 } }   // thin arm
    var volume = DepthMeshBuilder.Options(); volume.resolution = 80; volume.smoothingPasses = 0; volume.back = .inflated
    let flatDepth = [Float](repeating: 0.5, count: bw * bh)
    let figure = try DepthMeshBuilder.build(DepthField(width: bw, height: bh, nearness: flatDepth, mask: bodyMask), aspect: Double(bw) / Double(bh), options: volume)
    func nearestFront(_ px: Double, _ py: Double) -> Int {
        let tx = Float((px / Double(bw - 1) - 0.5) * Double(bw) / Double(bh)), ty = Float(0.5 - py / Double(bh - 1))
        var best = 0; var bestD = Float.infinity
        for i in 0..<(figure.vertexCount / 2) {
            let dx: Float = figure.positions[i * 3] - tx, dy: Float = figure.positions[i * 3 + 1] - ty
            if dx * dx + dy * dy < bestD { bestD = dx * dx + dy * dy; best = i }
        }
        return best
    }
    let bodyZ = zOf(figure, nearestFront(25, 30)), armZ = zOf(figure, nearestFront(60, 30))
    check(bodyZ > 0.15 && armZ > 0.02 && armZ < bodyZ * 0.5, "thin arm thinner than the body (\(armZ) vs \(bodyZ))")
    check(figure.valid && figure.triangleCount % 2 == 0, "volume mesh valid, front and back only")
    let fronts = figure.vertexCount / 2
    let backMin = (fronts..<figure.vertexCount).map { zOf(figure, $0) }.min()!, frontMax = (0..<fronts).map { zOf(figure, $0) }.max()!
    check(backMin < -frontMax * 0.6 && backMin > -frontMax * 1.1, "back has volume too (\(backMin) vs \(frontMax))")
    // Closed: every edge, keyed by its end positions, is used exactly twice.
    var edgeUse: [String: Int] = [:]
    func posKey(_ i: Int) -> String { String(format: "%.5f,%.5f,%.5f", figure.positions[i * 3], figure.positions[i * 3 + 1], figure.positions[i * 3 + 2]) }
    for t in 0..<figure.triangleCount {
        let tri = (0..<3).map { Int(figure.indices[t * 3 + $0]) }
        for (a, b) in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])] { let ka = posKey(a), kb = posKey(b); edgeUse[ka < kb ? ka + "|" + kb : kb + "|" + ka, default: 0] += 1 }
    }
    check(edgeUse.values.allSatisfy { $0 % 2 == 0 }, "front and back meet on the outline: closed (no open edges) without side walls")
    var atlas = volume; atlas.backAtlas = true
    let atlased = try DepthMeshBuilder.build(DepthField(width: bw, height: bh, nearness: flatDepth, mask: bodyMask), aspect: Double(bw) / Double(bh), options: atlas)
    let half = atlased.vertexCount / 2
    check((0..<half).allSatisfy { atlased.uvs[$0 * 2] <= 0.5 } && (half..<atlased.vertexCount).allSatisfy { atlased.uvs[$0 * 2] >= 0.5 }, "front uses the picture, back the colour-only half")
    check((0..<half).allSatisfy { zOf(atlased, $0) >= 0 }, "front never dips behind the outline")

    // Outline snapping on a disc.
    let side = 200
    var disc = [Float](repeating: 0, count: side * side)
    for y in 0..<side { for x in 0..<side {
        let dx = (Double(x) + 0.5) / Double(side) - 0.5, dy = (Double(y) + 0.5) / Double(side) - 0.5
        disc[y * side + x] = (dx * dx + dy * dy).squareRoot() < 0.4 ? 1 : 0
    } }
    let discField = DepthField(width: side, height: side, nearness: disc, mask: disc)
    var plain = DepthMeshBuilder.Options(); plain.resolution = 40; plain.smoothingPasses = 0; plain.closed = false
    var snapped = plain; snapped.snapEdges = true
    func outline(_ mesh: GeneratedMesh) -> [Float] {
        var use: [String: Int] = [:]
        for t in 0..<mesh.triangleCount {
            let tri = (0..<3).map { Int(mesh.indices[t * 3 + $0]) }
            for (a, b) in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])] { use["\(min(a, b))-\(max(a, b))", default: 0] += 1 }
        }
        let ids = Set(use.filter { $0.value == 1 }.keys.flatMap { $0.split(separator: "-").compactMap { Int($0) } })
        return ids.map { radial(mesh, $0) }
    }
    func spread(_ r: [Float]) -> Float {
        let mean = r.reduce(0, +) / Float(r.count)
        let variance = r.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(r.count)
        return variance.squareRoot()
    }
    let before = outline(try DepthMeshBuilder.build(discField, aspect: 1, options: plain))
    let after = outline(try DepthMeshBuilder.build(discField, aspect: 1, options: snapped))
    check(spread(after) < spread(before) * 0.6, "snapped outline is smoother (\(spread(before)) → \(spread(after)))")

    // Guided upsampling: a coarse depth step lands on the picture's edge.
    let lw = 8, lh = 4, gw = 64, gh = 32
    var low = [Float](repeating: 0, count: lw * lh)
    for y in 0..<lh { for x in 0..<lw { low[y * lw + x] = x < 4 ? 1 : 0 } }
    var guidePixels = [Float](repeating: 0, count: gw * gh)
    for y in 0..<gh { for x in 0..<gw { guidePixels[y * gw + x] = x < 30 ? 0.9 : 0.1 } }
    let up = DepthRefine.guidedUpsample(low, width: lw, height: lh, guide: guidePixels, guideWidth: gw, guideHeight: gh)
    let row: [Float] = (0..<gw).map { up[16 * gw + $0] }
    check(row[28] > 0.85 && row[31] < 0.15, "depth edge follows the picture edge (\(row[28]), \(row[31]))")
    let soft = DepthField(width: lw, height: lh, nearness: low, mask: low).resampled(width: gw, height: gh).nearness
    let softRow: [Float] = (0..<gw).map { soft[16 * gw + $0] }
    let blurredGuided = row.filter { $0 > 0.15 && $0 < 0.85 }.count
    let blurredPlain = softRow.filter { $0 > 0.15 && $0 < 0.85 }.count
    check(blurredGuided < blurredPlain, "sharper than plain resizing (\(blurredPlain) → \(blurredGuided))")
    check(DepthRefine.guidedUpsample([1], width: 1, height: 1, guide: guidePixels, guideWidth: gw, guideHeight: gh).isEmpty, "bad input rejected")
    let square = (0..<25).map { i in i % 5 > 0 && i % 5 < 4 && i / 5 > 0 && i / 5 < 4 }
    let squareDistance = DepthRefine.distanceToOutside(square, width: 5, height: 5)
    check(squareDistance[12] == 2 && squareDistance[6] == 1 && squareDistance[0] == 0, "distance to the outline")
    check(GenerationQuality.medium.gridResolution >= 192, "denser default mesh")
    // Rig mapping still works on an atlas-textured volume model.
    let atlasMap = AutoRig.uvToXY(atlased)
    check(atlasMap != nil && atlasMap!.ax > 1.5, "picture mapping fitted on the front only (atlas u is halved)")
    print("RPG model quality: \(checks) total checks passed")
}

// P34: v1.69 generated characters in the world.
do {
    check(RigClip.id(for: .walk) == "walk" && RigClip.id(for: .run) == "run" && RigClip.id(for: .attack) == "wave" && RigClip.id(for: .idle) == "idle" && RigClip.id(for: .hurt) == "idle", "world actions pick rig clips")
    check(CharacterAction.allCases.allSatisfy { action in RigClip.standard.contains { $0.id == RigClip.id(for: action) } }, "every action has a clip")
    var generated = CharacterTemplate(id: "char:g", name: "Hachi")
    generated.mode = .generated
    check(!generated.valid, "generated look needs a model id")
    generated.generatedModelID = "model-1"
    check(generated.valid, "generated look valid with a model id")
    let oldTemplate = try JSONDecoder().decode(CharacterTemplate.self, from: Data(#"{"id":"c1","name":"Old","mode":"model","clips":{},"height":1.6,"aspect":0.6,"footAnchor":0,"opacity":1,"shadow":true,"colliderRadius":0.3,"colliderHeight":1.5,"hurtScale":1,"modelMediaID":"a.usdz","layerDepth":0.12}"#.utf8))
    check(oldTemplate.mode == .model && oldTemplate.generatedModelID == nil, "v1.68 character templates still open")
    var placed = CreatureEntity(id: "c:x", kind: .enemy, position: SpatialVector(1, 1, 0), home: SpatialVector(1, 1, 0), health: 30, maxHealth: 30, damage: 6)
    placed.characterID = generated.id
    check(placed.characterID == "char:g", "one creature can carry its own look")
    // v1.72 fix: edits that only touch looks, spawn or ground holes are kept.
    var lookWorld = SpatialWorld()
    lookWorld.edit("look") { w in w.characters = [generated] }
    lookWorld.edit("player look") { w in w.playerCharacterID = generated.id }
    lookWorld.edit("spawn") { w in w.spawn = SpatialVector(3.5, 4.5, 0) }
    lookWorld.edit("dig") { w in w.groundHoles = [7] }
    check(lookWorld.characters?.first?.id == "char:g" && lookWorld.playerCharacterID == "char:g", "picking a look saves the character")
    check(lookWorld.spawn == SpatialVector(3.5, 4.5, 0) && lookWorld.groundHoles == [7] && lookWorld.history.undo.isEmpty, "spawn and holes kept without undo entries")
    print("RPG world characters: \(checks) total checks passed")
}

// P35: native glass never draws faces right in front of the lens (the white
// screen-filling shape after revive).
do {
    let view = CGSize(width: 390, height: 844)
    check(SpatialFaces.drawable(depths: [5, 5, 6, 6], bounds: CGRect(x: 100, y: 100, width: 80, height: 60), viewSize: view), "normal face drawn")
    check(!SpatialFaces.drawable(depths: [0.2, 5, 6, 6], bounds: CGRect(x: 100, y: 100, width: 80, height: 60), viewSize: view), "corner at the lens: skipped")
    check(!SpatialFaces.drawable(depths: [3, 3, 3, 3], bounds: CGRect(x: -2000, y: -900, width: 4500, height: 3000), viewSize: view), "face bigger than the screen: skipped")
    check(!SpatialFaces.drawable(depths: [3, 3, .nan, 3], bounds: CGRect(x: 0, y: 0, width: 10, height: 10), viewSize: view), "broken projection skipped")
    // A real case: camera half a cell from a block face.
    let camera = SpatialProjection(eye: SpatialVector(10.5, 9.7, 1.5), target: SpatialVector(10.5, 14, 1.0), fieldOfView: 30, viewSize: view)
    let block = SpatialBlock(id: "near", x: 10, y: 10, elevation: 0, thickness: 3)
    var drawnHuge = 0
    for face in SpatialFaces.visibleFaces(SpatialFaces.corners(block), eye: camera.eye) {
        let projected = face.points.compactMap { camera.project($0) }
        guard projected.count == 4 else { continue }
        let xs = projected.map { $0.point.x }, ys = projected.map { $0.point.y }
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        if SpatialFaces.drawable(depths: projected.map(\.depth), bounds: bounds, viewSize: view) && bounds.width > view.width { drawnHuge += 1 }
    }
    check(drawnHuge == 0, "block next to the camera cannot cover the screen with glass")
    print("RPG near glass: \(checks) total checks passed")
}

// P36: one-tap clear world keeps the user's designs.
do {
    var busy = SpatialWorld.blank()
    busy.blocks = [SpatialBlock(id: "b", x: 3, y: 3, elevation: 0)]
    busy.creatures = [CreatureEntity(id: "c", kind: .enemy, position: SpatialVector(5, 5, 0), home: SpatialVector(5, 5, 0), health: 30, maxHealth: 30, damage: 6)]
    busy.groundHoles = [100]
    busy.characters = [CharacterTemplate(id: "char:1", name: "Hero")]
    busy.playerCharacterID = "char:1"
    busy.skills = [SkillLibrary.templates()[0]]
    busy.spawn = SpatialVector(40, 40, 2); busy.player.position = SpatialVector(41, 41, 0)
    let clean = busy.cleared()
    check(clean.blocks.isEmpty && clean.creatures.isEmpty && clean.groundHoles == nil && clean.plants.isEmpty && clean.pickups.isEmpty, "clear removes everything placed")
    check(clean.characters?.count == 1 && clean.playerCharacterID == "char:1" && clean.skills?.count == 1, "clear keeps characters, the player's look and skills")
    check(clean.player.position == clean.spawn && clean.spawn == SpatialWorld().spawn, "player back at the default spawn")
    print("RPG clear world: \(checks) total checks passed")
}

// P37: model renderer for GIF / video export and eight-direction characters.
do {
    // Dome, textured solid red.
    let side = 40
    var near = [Float](repeating: 0, count: side * side), disc = near
    for y in 0..<side { for x in 0..<side {
        let dx = Double(x - side / 2) / Double(side / 2), dy = Double(y - side / 2) / Double(side / 2)
        let r = (dx * dx + dy * dy).squareRoot()
        disc[y * side + x] = r < 0.8 ? 1 : 0; near[y * side + x] = Float(max(0, 1 - r))
    } }
    var o = DepthMeshBuilder.Options(); o.resolution = 32; o.back = .inflated
    var dome = try DepthMeshBuilder.build(DepthField(width: side, height: side, nearness: near, mask: disc), aspect: 1, options: o)
    dome.normalize(size: 1)
    let red = RasterImage(width: 4, height: 4, fill: [220, 30, 40, 255])
    let frame = ModelRasterizer.render(dome, texture: red, camera: RasterCamera(), width: 64, height: 64)
    check(frame.width == 64 && frame.rgba.count == 64 * 64 * 4, "frame size")
    check(frame.coverage > 0.15 && frame.coverage < 0.9, "the model fills part of the frame (\(frame.coverage))")
    let centre = frame.pixel(32, 32)
    check(centre[3] == 255 && centre[0] > 200 && centre[1] < 60, "centre shows the texture")
    check(frame.pixel(0, 0)[3] == 0, "background stays transparent")
    let side90 = ModelRasterizer.render(dome, texture: red, camera: RasterCamera(yaw: .pi / 2), width: 64, height: 64)
    check(side90.coverage > 0.05 && side90.coverage < frame.coverage, "turned 90°: thinner profile, still solid (\(side90.coverage))")
    let lit = ModelRasterizer.render(dome, texture: red, camera: RasterCamera(lighting: true), width: 64, height: 64)
    check(lit.pixel(32, 32)[0] <= centre[0], "lighting shades")
    let solid = ModelRasterizer.render(dome, texture: red, camera: RasterCamera(), width: 32, height: 32, background: [10, 20, 30, 255])
    check(solid.pixel(0, 0) == [10, 20, 30, 255], "solid background for video")

    // Depth test: a near red quad in front of a far blue one, drawn last.
    let texture = RasterImage(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 0, 255, 255])
    var quads = GeneratedMesh()
    quads.positions = [-0.3, -0.3, 0.2, 0.3, -0.3, 0.2, 0.3, 0.3, 0.2, -0.3, 0.3, 0.2,   -0.4, -0.4, -0.2, 0.4, -0.4, -0.2, 0.4, 0.4, -0.2, -0.4, 0.4, -0.2]
    quads.uvs = [0.1, 0.5, 0.1, 0.5, 0.1, 0.5, 0.1, 0.5,   0.9, 0.5, 0.9, 0.5, 0.9, 0.5, 0.9, 0.5]
    quads.indices = [0, 1, 2, 0, 2, 3,   4, 5, 6, 4, 6, 7]
    quads.computeNormals()
    let layered = ModelRasterizer.render(quads, texture: texture, camera: RasterCamera(pitch: 0), width: 40, height: 40, supersample: 1)
    check(layered.pixel(20, 20)[0] > 240 && layered.pixel(20, 20)[2] == 0, "nearer surface wins")
    check(layered.pixel(10, 20)[2] > 240 && layered.pixel(10, 20)[0] == 0 && layered.pixel(29, 20)[2] > 240, "farther surface visible around it")
    let behind = ModelRasterizer.render(quads, texture: texture, camera: RasterCamera(yaw: .pi, pitch: 0), width: 40, height: 40, supersample: 1)
    check(behind.coverage == 0, "back faces are culled (open quads seen from behind)")

    // Animated frames really differ.
    let w = 100, h = 160
    var mask = [Float](repeating: 0, count: w * h), depth = mask
    func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { for y in y0..<y1 { for x in x0..<x1 { mask[y * w + x] = 1; depth[y * w + x] = 1 } } }
    fill(42, 4, 58, 26); fill(34, 28, 66, 82); fill(22, 30, 32, 80); fill(68, 30, 78, 80); fill(36, 84, 48, 154); fill(52, 84, 64, 154)
    var fo = DepthMeshBuilder.Options(); fo.resolution = 64; fo.smoothingPasses = 0
    var figure = try DepthMeshBuilder.build(DepthField(width: w, height: h, nearness: depth, mask: mask), aspect: Double(w) / Double(h), options: fo)
    figure.normalize(size: 1)
    func jp(_ x: Double, _ y: Double) -> BodyJoints2D.Point { .init(u: x / Double(w), v: y / Double(h), confidence: 0.9) }
    let pose = BodyJoints2D(points: ["neck_1_joint": jp(50, 28), "root": jp(50, 82), "right_shoulder_1_joint": jp(27, 32), "right_forearm_joint": jp(27, 55), "right_hand_joint": jp(27, 78),
                                     "left_shoulder_1_joint": jp(73, 32), "left_forearm_joint": jp(73, 55), "left_hand_joint": jp(73, 78), "right_upLeg_joint": jp(42, 86), "right_leg_joint": jp(42, 118),
                                     "right_foot_joint": jp(42, 150), "left_upLeg_joint": jp(58, 86), "left_leg_joint": jp(58, 118), "left_foot_joint": jp(58, 150)])
    let skeleton = try AutoRig.skeleton(for: figure, joints: pose)
    let skin = AutoRig.weights(for: figure, skeleton: skeleton)
    let wave = RigClip.standard.first { $0.id == "wave" }!
    let posed = RigPose.deform(figure, skin: skin, matrices: RigPose.matrices(skeleton, clip: wave, time: 0.3))
    let restFrame = ModelRasterizer.render(figure, texture: red, camera: RasterCamera(), width: 48, height: 48, supersample: 1)
    let waveFrame = ModelRasterizer.render(figure, positions: posed.positions, normals: posed.normals, texture: red, camera: RasterCamera(), width: 48, height: 48, supersample: 1)
    let changed = stride(from: 3, to: restFrame.rgba.count, by: 4).filter { restFrame.rgba[$0] != waveFrame.rgba[$0] }.count
    check(changed > 20, "animated frame differs from the rest pose (\(changed) pixels)")

    check(ModelExportPlan.turntable(frames: 36).count == 36 && ModelExportPlan.directionYaws.count == 8, "turntable and eight directions")
    check(ModelExportPlan.times(period: 1.1, fps: 20).count == 22, "clip frame times")
    let mapped = ModelExportPlan.spriteClips.flatMap(\.actions)
    check(Set(mapped).count == mapped.count && Set(mapped) == Set(CharacterAction.allCases), "every action maps to exactly one baked clip")

    // P38: Claude motion design: request shape, reply parsing, clamping,
    // stop reasons and the on-device check of a designed clip.
    let opus = ClaudeMotion.models[0]
    let bodyData = try ClaudeMotion.requestBody(description: "jump for joy", skeleton: skeleton, model: opus)
    let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
    let outputConfig = body["output_config"] as? [String: Any]
    let format = outputConfig?["format"] as? [String: Any]
    check(body["model"] as? String == "claude-opus-5-5" && body["fallbacks"] as? String == "default", "Claude request: model and fallbacks")
    check(format?["type"] as? String == "json_schema" && body["thinking"] == nil && body["tool_choice"] == nil, "Claude request: structured output, no forced tools")
    let userText = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    check(userText.contains("right_upper_arm") && userText.contains("jump for joy"), "Claude request carries skeleton and description")
    check(ClaudeMotion.headers(apiKey: "k", model: opus)["anthropic-beta"] == ClaudeMotion.fallbackBeta && ClaudeMotion.headers(apiKey: "k", model: ClaudeMotion.models[1])["anthropic-beta"] == nil, "fallback beta header only with fallbacks")
    let answer = #"{"name":"欢跳","period_seconds":9,"channels":[{"bone":"right_upper_arm","axis":"z","amplitude_degrees":30,"bias_degrees":-200,"phase_turns":0.25,"cycles_per_period":7},{"bone":"left_thigh","axis":"x","amplitude_degrees":25,"bias_degrees":0,"phase_turns":0.5,"cycles_per_period":1},{"bone":"tail","axis":"x","amplitude_degrees":10,"bias_degrees":0,"phase_turns":0,"cycles_per_period":1}]}"#
    let reply: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "text", "text": answer]]]
    let designed = try ClaudeMotion.clip(fromResponse: try JSONSerialization.data(withJSONObject: reply), status: 200)
    let arm = designed.channels.first
    check(designed.channels.count == 2 && designed.name == "欢跳" && designed.id.hasPrefix("ai-"), "designed clip parsed, unknown bones dropped")
    check(designed.period == 4 && arm?.frequency == 4 && abs((arm?.bias ?? 0) + .pi / 2) < 1e-4, "designed clip clamped to safe ranges")
    func failure(_ object: [String: Any], _ status: Int) -> ClaudeMotionError? {
        do { _ = try ClaudeMotion.clip(fromResponse: try JSONSerialization.data(withJSONObject: object), status: status); return nil } catch { return error as? ClaudeMotionError }
    }
    check(failure(["stop_reason": "refusal", "stop_details": ["category": "cyber"], "content": []], 200) == .refused("cyber"), "refusal handled before reading content")
    check(failure(["stop_reason": "max_tokens", "content": [["type": "text", "text": "{"]]], 200) == .truncated, "max_tokens handled")
    check(failure(["type": "error", "error": ["type": "authentication_error", "message": "invalid x-api-key"]], 401) == .http(401, "invalid x-api-key"), "HTTP error message surfaced")
    check(failure(["stop_reason": "end_turn", "content": [["type": "text", "text": #"{"name":"x","period_seconds":1,"channels":[]}"#]]], 200) == .emptyClip, "empty clip rejected")
    let designedCheck = RigValidation.run(figure, skeleton: skeleton, skin: skin, clips: [designed])
    check(designedCheck.passed, "designed clip passes the deformation check \(designedCheck.problems)")
    let package = RigPackage(skeleton: skeleton, joints: pose, clips: RigClip.standard, validation: designedCheck)
    var grown = package
    for _ in 0..<10 { grown = ClaudeMotion.adding(try ClaudeMotion.clip(fromJSON: Data(answer.utf8)), to: grown) }
    check(grown.clips.count == RigClip.standard.count + 1, "same-name designed clip replaces the old one")
    var many = package
    for i in 0..<12 { var c = designed; c.id = "ai-\(i)"; c.name = "m\(i)"; many = ClaudeMotion.adding(c, to: many) }
    check(many.clips.count == RigClip.standard.count + 8 && many.clips.filter { !$0.id.hasPrefix("ai-") }.count == RigClip.standard.count, "designed clips capped, standard clips kept")
    print("RPG model render: \(checks) total checks passed")
}


// P39: v1.73 rigging — data layer, joints from the 3D mesh, 27-joint
// skeleton, 4-influence skin, eight motion tests, GLB, cloud protocol,
// versioned storage.
do {
    // Fixtures: a relief figure (as the app generates them) and a truly 3D
    // blocky figure, each with arms down and in T-pose.
    func reliefFigure(tpose: Bool, resolution: Int = 96) throws -> GeneratedMesh {
        let w = tpose ? 160 : 100, h = 160
        var mask = [Float](repeating: 0, count: w * h), depth = mask
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) { for y in y0..<y1 { for x in x0..<x1 { mask[y * w + x] = 1; depth[y * w + x] = 1 } } }
        let o = tpose ? 30 : 0
        fill(42 + o, 4, 58 + o, 24); fill(46 + o, 24, 54 + o, 30); fill(34 + o, 30, 66 + o, 84)
        if tpose { fill(4, 32, 34 + o, 42); fill(66 + o, 32, 156, 42) } else { fill(20, 32, 30, 82); fill(70, 32, 80, 82) }
        fill(36 + o, 84, 48 + o, 152); fill(52 + o, 84, 64 + o, 152); fill(36 + o, 150, 48 + o, 156); fill(52 + o, 150, 64 + o, 156)
        var fo = DepthMeshBuilder.Options(); fo.resolution = resolution; fo.smoothingPasses = 0; fo.back = .inflated; fo.snapEdges = true; fo.edgeRounding = 1
        var m = try DepthMeshBuilder.build(DepthField(width: w, height: h, nearness: depth, mask: mask), aspect: Double(w) / Double(h), options: fo)
        m.normalize(size: 1)
        return m
    }
    func voxelFigure(tpose: Bool) -> GeneratedMesh {
        let W = 64, H = 64
        var solid = Set<Int>()
        func key(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * H + y) * W + x }
        func box(_ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int) { for z in z0..<z1 { for y in y0..<y1 { for x in x0..<x1 { solid.insert(key(x, y, z)) } } } }
        box(27, 0, 6, 31, 2, 12); box(33, 0, 6, 37, 2, 12); box(27, 2, 6, 31, 28, 10); box(33, 2, 6, 37, 28, 10)
        box(26, 28, 5, 38, 48, 11); box(30, 48, 6, 34, 51, 10); box(28, 51, 5, 36, 60, 11)
        if tpose { box(4, 44, 6, 26, 47, 10); box(38, 44, 6, 60, 47, 10) }
        else { box(22, 24, 6, 25, 47, 10); box(39, 24, 6, 42, 47, 10); box(25, 44, 6, 26, 47, 10); box(38, 44, 6, 39, 47, 10) }
        var map: [[Int]: UInt32] = [:], positions: [Float] = [], indices: [UInt32] = []
        func vertex(_ p: [Int]) -> UInt32 {
            if let i = map[p] { return i }
            let i = UInt32(positions.count / 3); map[p] = i
            positions += [Float(p[0]), Float(p[1]), Float(p[2])]; return i
        }
        for k in solid.sorted() {
            let x = k % W, y = (k / W) % H, z = k / (W * H)
            for d in [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]] where !solid.contains(key(x + d[0], y + d[1], z + d[2])) || y + d[1] < 0 {
                let a = d.firstIndex { $0 != 0 }!, sign = d[a], u = (a + 1) % 3, v = (a + 2) % 3
                var base = [x, y, z]; if sign > 0 { base[a] += 1 }
                func c(_ du: Int, _ dv: Int) -> [Int] { var p = base; p[u] += du; p[v] += dv; return p }
                let q = (sign > 0 ? [c(0, 0), c(1, 0), c(1, 1), c(0, 1)] : [c(0, 0), c(0, 1), c(1, 1), c(1, 0)]).map(vertex)
                indices += [q[0], q[1], q[2], q[0], q[2], q[3]]
            }
        }
        var m = GeneratedMesh(positions: positions, normals: [], uvs: [Float](repeating: 0.5, count: positions.count / 3 * 2), indices: indices)
        m.computeNormals(); m.normalize(size: 1)
        return m
    }

    // Transforms.
    let rx = RigXform.translation(0.1, 0.2, -0.3) * RigXform.euler([0.3, -0.4, 0.5])
    let backAndForth = rx * rx.inverse!
    check(abs(backAndForth.a - 1) + abs(backAndForth.e - 1) + abs(backAndForth.i - 1) + abs(backAndForth.tx) + abs(backAndForth.ty) + abs(backAndForth.tz) < 1e-5, "rig transform inverse")
    check(RigXform(matrix: rx.matrix) == rx && RigXform(matrix: [Float](repeating: .nan, count: 16)) == nil, "rig transform 4×4 round trip, NaN refused")
    check(JointTag.rightUpperArm.mirror == .leftUpperArm && JointTag.chest.mirror == nil, "joint mirror names")
    let unknownTag = try JSONDecoder().decode([JointTag].self, from: Data(#"["leftHand","mixamorig:Spine"]"#.utf8))
    check(unknownTag == [.leftHand, .other], "unknown joint names read as other")

    // Mesh analysis.
    var broken = GeneratedMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 5, 5, 5, 6, 5, 5, 5, 6, 5, 0, -1, 0], normals: [Float](repeating: 0, count: 24), uvs: [Float](repeating: 0, count: 16),
                               indices: [0, 1, 2, 0, 1, 2, 0, 1, 3, 1, 0, 3, 0, 0, 1, 4, 5, 6, 0, 1, 7])
    broken.normals[2] = 1
    let brokenAnalysis = MeshAnalyzer.analyze(broken)
    check(brokenAnalysis.duplicateTriangles == 2 && brokenAnalysis.degenerateTriangles == 1 && brokenAnalysis.nonManifoldEdges == 1 && brokenAnalysis.components == 2, "mesh analysis: duplicates, degenerate, non-manifold, pieces")
    check(brokenAnalysis.invalidNormals == 7 && MeshAnalyzer.cleaned(broken).triangleCount == 4, "mesh analysis: normals, cleaned copy")
    let dense = try reliefFigure(tpose: true, resolution: 320)
    let reduced = MeshAnalyzer.simplified(dense, targetTriangles: 20_000)
    check(dense.triangleCount > 60_000 && reduced.triangleCount <= 20_000 && reduced.triangleCount > 2_000 && reduced.valid, "dense mesh reduced (\(dense.triangleCount) → \(reduced.triangleCount))")

    // Joints, skeleton, skin and the eight motion tests on four figures.
    let figures: [(String, GeneratedMesh, MeshAnalysis.PoseType)] = [
        ("relief arms down", try reliefFigure(tpose: false), .armsDown), ("relief T-pose", try reliefFigure(tpose: true), .tPose),
        ("3D arms down", voxelFigure(tpose: false), .armsDown), ("3D T-pose", voxelFigure(tpose: true), .tPose),
    ]
    var keptResult: RiggingResult?
    for (name, mesh, pose) in figures {
        let result = try RiggingPipeline.run(mesh)
        let s = result.skeleton, est = result.estimate
        check(est.pose == pose && est.humanoid >= 0.9 && result.route == .local, "\(name): humanoid in \(pose) found locally")
        check((22...32).contains(s.joints.count) && Set(s.joints.map(\.semanticTag)).count == s.joints.count, "\(name): \(s.joints.count) named joints")
        var skeletonOK = true
        do { try s.validate() } catch { skeletonOK = false }
        check(skeletonOK, "\(name): skeleton hierarchy, matrices and sides valid")
        let head = s.position(.head)!, pelvis = s.position(.pelvis)!, knee = s.position(.rightShin)!, ankle = s.position(.rightFoot)!, hand = s.position(.rightHand)!
        let b = mesh.bounds
        check(head.y > pelvis.y && pelvis.y > knee.y && knee.y > ankle.y && hand.x < pelvis.x && head.y < b.max[1] && ankle.y > b.min[1], "\(name): joints in body order, model frame")
        check(result.skin.valid(jointCount: s.joints.count, vertexCount: mesh.vertexCount), "\(name): ≤4 weights per vertex, non-negative, sum 1")
        let rest = SkinWeightSolver.deform(result.mesh, skin: result.skin, matrices: SkeletonPose.rest(s).skinning(s)).positions
        check(zip(rest, result.mesh.positions).allSatisfy { abs($0 - $1) < 1e-4 }, "\(name): bind pose leaves the mesh unchanged")
        let statuses = result.diagnostics.results.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: " ")
        check(result.diagnostics.results.count == 8 && result.diagnostics.results.allSatisfy { $0.status != .fail }, "\(name): eight motion tests without failures [\(statuses)]")
        check(Set(result.sockets.map(\.kind)) == Set(AttachmentSocket.Kind.allCases) && result.sockets.allSatisfy { s.index($0.jointID) != nil }, "\(name): six attachment sockets")
        if keptResult == nil { keptResult = result }
    }

    // Dense model timing (Linux CPU, not an iPhone measurement).
    let started = Date()
    let denseResult = try RiggingPipeline.run(dense)
    let seconds = Date().timeIntervalSince(started)
    check(denseResult.diagnostics.results.allSatisfy { $0.status != .fail }, "dense relief (\(dense.vertexCount) vertices) rigged without failures")
    print(String(format: "Rig timing, %d vertices / %d triangles: total %.2fs ", dense.vertexCount, dense.triangleCount, seconds) + denseResult.timings.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value))s" }.joined(separator: ", "))

    // Cancellation and failures.
    var cancelledRun = false
    do { _ = try RiggingPipeline.run(figures[0].1, cancelled: { true }) } catch RiggingError.cancelled { cancelledRun = true }
    check(cancelledRun, "rigging can be cancelled")
    var emptyRefused = false
    do { _ = try RiggingPipeline.run(GeneratedMesh()) } catch RiggingError.emptyMesh { emptyRefused = true }
    check(emptyRefused, "empty mesh refused")
    let blob = MeshAnalyzer.analyze(GeneratedMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], normals: [0, 0, 1, 0, 0, 1, 0, 0, 1], uvs: [0, 0, 0, 0, 0, 0], indices: [0, 1, 2]))
    check(RiggingPipeline.route(analysis: blob, estimate: JointEstimate(positions: [:], confidence: [:], pose: .unknown, humanoid: 0.3, notes: [])) != .local, "unclear models suggest the cloud (never upload by themselves)")

    // Hierarchy checks catch broken skeletons.
    let good = keptResult!.skeleton
    var looped = good; looped.joints[0].parentID = looped.joints[3].jointID
    var twoRoots = good; twoRoots.joints[5].parentID = nil
    var swapped = good
    let r = swapped.index(.rightHand)!, l = swapped.index(.leftHand)!
    let rp = swapped.worldRest[r].origin, lp = swapped.worldRest[l].origin
    swapped = SkeletonBuilder.moving(SkeletonBuilder.moving(swapped, joint: r, to: lp), joint: l, to: rp)
    func fails(_ s: SkeletonDefinition) -> Bool { do { try s.validate(); return false } catch { return true } }
    check(fails(looped) && fails(twoRoots) && fails(swapped) && !fails(good), "skeleton validation: cycles, roots, left / right")

    // Editing a joint and re-skinning (manual correction).
    let figure = figures[0].1
    let elbow = good.index(.rightForearm)!
    let moved = SkeletonBuilder.moving(good, joint: elbow, to: good.worldRest[elbow].origin + SIMD3(0, 0.02, 0))
    let reskinned = try RiggingPipeline.reskin(keptResult!.mesh, skeleton: moved)
    check(!fails(moved) && moved.joints[elbow].confidence == 1 && reskinned.valid(jointCount: moved.joints.count, vertexCount: figure.vertexCount), "joint moved by hand, weights recomputed")
    check(RiggingPipeline.test(keptResult!.mesh, skeleton: moved, skin: reskinned).count == 8, "edited rig re-tested")

    // Motion library: every world action has a clip.
    check(CharacterAction.allCases.allSatisfy { MotionClip.standard(MotionClip.id(for: $0)) != nil } && MotionClip.testIDs.count == 8, "every action maps to a motion; eight test motions")

    // GLB round trip with texture.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let glb = GLBCodec.write(figure, texture: png)
    let back = try GLBCodec.read(glb)
    check(back.mesh.vertexCount == figure.vertexCount && back.mesh.indices == figure.indices && back.texture == png && back.textureMime == "image/png", "GLB round trip: geometry and texture")
    check(zip(back.mesh.positions, figure.positions).allSatisfy { abs($0 - $1) < 1e-6 } && zip(back.mesh.uvs, figure.uvs).allSatisfy { abs($0 - $1) < 1e-6 }, "GLB keeps positions and UVs")
    var glbRefused = 0
    for bad in [Data("not a model".utf8), Data([0x67, 0x6C, 0x54, 0x46, 1, 0, 0, 0] + [UInt8](repeating: 0, count: 16))] { do { _ = try GLBCodec.read(bad) } catch { glbRefused += 1 } }
    check(glbRefused == 2, "GLB: wrong files refused")
    // A node translation is applied.
    var json = try JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + Int(glb[12]) + Int(glb[13]) * 256 + Int(glb[14]) * 65536))) as! [String: Any]
    json["nodes"] = [["mesh": 0, "translation": [0, 2, 0]]]
    var moved1 = try JSONSerialization.data(withJSONObject: json)
    while moved1.count % 4 != 0 { moved1.append(0x20) }
    let binStart = 20 + Int(glb[12]) + Int(glb[13]) * 256 + Int(glb[14]) * 65536
    var rebuilt = Data()
    func le(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { rebuilt.append(contentsOf: $0) } }
    le(0x4654_6C67); le(2); le(12 + 8 + moved1.count + (glb.count - binStart)); le(moved1.count); le(0x4E4F_534A); rebuilt.append(moved1); rebuilt.append(glb.subdata(in: binStart..<glb.count))
    let shifted = try GLBCodec.read(rebuilt)
    check(abs(shifted.mesh.positions[1] - figure.positions[1] - 2) < 1e-5, "GLB node transforms applied")

    // Cloud protocol (no server is contacted in tests).
    let config = CloudRigConfig.parse("https://rig.example.com/", token: " abc ")!
    let create = CloudRiggingProtocol.create(config, glb: glb)
    check(create.url?.absoluteString == "https://rig.example.com/v1/rig/jobs" && create.httpMethod == "POST" && create.value(forHTTPHeaderField: "Authorization") == "Bearer abc"
          && create.value(forHTTPHeaderField: "Content-Type") == "model/gltf-binary", "cloud: create job request")
    check(CloudRiggingProtocol.cancel(config, id: "j/1").url?.absoluteString == "https://rig.example.com/v1/rig/jobs/j%2F1/cancel" && CloudRiggingProtocol.delete(config, id: "j1").httpMethod == "DELETE"
          && CloudRiggingProtocol.result(config, id: "j1").url?.path == "/v1/rig/jobs/j1/result", "cloud: cancel, delete, result requests")
    check(CloudRigConfig.parse("http://evil.example.com", token: "") == nil && CloudRigConfig.parse("http://localhost:8080", token: "") != nil, "cloud: https only (localhost for testing)")
    func cloudError(_ status: Int) -> CloudRigError? { do { try CloudRiggingProtocol.check(status: status, body: Data(#"{"message":"bad mesh"}"#.utf8)); return nil } catch { return error as? CloudRigError } }
    check(cloudError(200) == nil && cloudError(401) == .unauthorized && cloudError(404) == .notFound && cloudError(422) == .rejected("bad mesh") && cloudError(503) == .server(503), "cloud: HTTP errors mapped")
    check(CloudRiggingProtocol.pollDelay(attempt: 0) < CloudRiggingProtocol.pollDelay(attempt: 3) && CloudRiggingProtocol.pollDelay(attempt: 50) == 10, "cloud: polling backs off, capped")
    let job = try CloudRiggingProtocol.job(Data(#"{"id":"j1","status":"running","progress":0.4}"#.utf8))
    check(job.status == .running && !job.finished, "cloud: job status decoded")
    let kept = keptResult!
    let reply = CloudRigResult(formatVersion: 1, vertexCount: kept.mesh.vertexCount, skeleton: kept.skeleton, joints: kept.skin.joints, weights: kept.skin.weights.map { $0 * 1.0004 }, engine: "test", notes: nil)
    let decoded = try CloudRiggingProtocol.decodeResult(try JSONEncoder().encode(reply), vertexCount: kept.mesh.vertexCount)
    check(decoded.skin.valid(jointCount: kept.skeleton.joints.count, vertexCount: kept.mesh.vertexCount) && decoded.skeleton == kept.skeleton, "cloud: result checked and weights renormalised")
    var mismatch = false
    do { _ = try CloudRiggingProtocol.decodeResult(try JSONEncoder().encode(reply), vertexCount: 3) } catch CloudRigError.incompatible { mismatch = true }
    var badWeights = reply; badWeights.weights[0] = .nan
    var nanRefused = false
    do { _ = try CloudRiggingProtocol.decodeResult(try JSONEncoder().encode(badWeights), vertexCount: kept.mesh.vertexCount) } catch { nanRefused = true }
    check(mismatch && nanRefused, "cloud: mismatched or invalid results refused")

    // Storage: save, reload, rollback, newer format refused, checkpoints.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rig-test-" + UUID().uuidString)
    let store = RiggingAssetStore(folder: folder)
    let character = RiggingPipeline.character(kept, modelID: "m1", meshFile: "m1.mesh", optimizedMeshFile: nil, skinFile: "m1.skin")
    try store.save(character, skin: kept.skin, optimizedMesh: nil)
    let loaded = try store.load("m1")
    check(loaded?.0 == character && loaded?.1 == kept.skin, "rig saved and reloaded (skeleton, weights, clips, sockets)")
    var second = character; second.metadata.notes = ["v2"]
    try store.save(second, skin: kept.skin, optimizedMesh: nil)
    let rolled = try store.rollback("m1")
    let restored = try store.load("m1")
    check(rolled && restored?.0.metadata.notes == character.metadata.notes, "previous save restored (rollback)")
    var future = try JSONSerialization.jsonObject(with: try character.encoded()) as! [String: Any]
    future["formatVersion"] = 99
    try JSONSerialization.data(withJSONObject: future).write(to: store.characterURL("m1"))
    var newerRefused = false, newerKept = false
    do { _ = try store.load("m1") } catch RiggedCharacter.LoadError.newerFormat(99) { newerRefused = true }
    do { try store.save(character, skin: kept.skin, optimizedMesh: nil) } catch RiggedCharacter.LoadError.newerFormat(99) { newerKept = true }
    check(newerRefused && newerKept, "files from a newer format are neither read nor overwritten")
    store.saveCheckpoint(.init(modelID: "m2", stage: "skeleton", skeleton: good, savedAt: Date()))
    check(store.checkpoint("m2")?.skeleton == good, "checkpoint keeps the skeleton for resuming")
    store.delete("m1"); store.delete("m2")
    check(!store.exists("m1") && store.checkpoint("m2") == nil, "rig files deleted")
    try? FileManager.default.removeItem(at: folder)
    let skinBytes = kept.skin.encoded()
    check(SkinInfluences.decode(skinBytes) == kept.skin && SkinInfluences.decode(skinBytes.dropLast()) == nil, "skin file round trip, truncated file refused")
    print("RPG rigging: \(checks) total checks passed")
}


// P40: v1.74 — text → 3D character (keywords / Claude spec), models from
// 2 / 4 / 6 photos, seam-aware rigging.
do {
    func signedVolume(_ m: GeneratedMesh) -> Float {
        var v: Float = 0
        for t in 0..<m.triangleCount {
            let a = Int(m.indices[t * 3]), b = Int(m.indices[t * 3 + 1]), c = Int(m.indices[t * 3 + 2]), p = m.positions
            let ab: Float = p[b * 3 + 1] * p[c * 3 + 2] - p[b * 3 + 2] * p[c * 3 + 1]
            let bc: Float = p[b * 3] * p[c * 3 + 2] - p[b * 3 + 2] * p[c * 3]
            let ca: Float = p[b * 3] * p[c * 3 + 1] - p[b * 3 + 1] * p[c * 3]
            v += (p[a * 3] * ab - p[a * 3 + 1] * bc + p[a * 3 + 2] * ca) / 6
        }
        return v
    }
    var prims = ProceduralCharacterBuilder.Builder()
    prims.capsule([0.5, 0.2, 0], [0.6, 0.8, 0.1], 0.05, .skin)
    let capsuleVolume = signedVolume(prims.mesh)
    var disc = ProceduralCharacterBuilder.Builder()
    disc.frustum(bottomCenter: [0.2, 0.2, 0.3], top: 0, bottomRadius: 0.2, topRadius: 0.2, .skin, axis: 0, thickness: 0.03)
    check(capsuleVolume > 0 && signedVolume(disc.mesh) > 0, "primitives face outwards")

    let warrior = CharacterKeywords.spec(for: "一个拿剑的红色战士")
    check(warrior.outfit == .armor && warrior.accessories.contains(.sword) && warrior.accessories.contains(.shield) && warrior.top == "B83A3A", "keywords: red warrior with sword and shield")
    check(CharacterKeywords.spec(for: "purple wizard").accessories.contains(.wizardHat) && CharacterKeywords.spec(for: "可爱的机器人").outfit == .robot, "keywords: wizard, robot")
    var odd = CharacterSpec(name: "  "); odd.height = .nan; odd.headScale = 9; odd.top = "#zz"; odd.accessories = [.sword, .sword]
    let fixed = odd.clamped
    check(fixed.height == 1.7 && fixed.headScale == 1.6 && fixed.top == CharacterSpec(name: "").top && fixed.accessories == [.sword] && !fixed.name.isEmpty, "character spec clamped")
    for prompt in ["一个拿剑的红色战士", "骑士", "金发弓箭手", "可爱的机器人", "紫色法师", "公主", "恶魔"] {
        let built = ProceduralCharacterBuilder.build(CharacterKeywords.spec(for: prompt))
        check(built.mesh.valid && signedVolume(built.mesh) > 0 && built.palette.width == 64, "\(prompt): closed coloured mesh (\(built.mesh.triangleCount) triangles)")
        var skeletonOK = true
        do { try built.skeleton.validate() } catch { skeletonOK = false }
        let tests = RiggingPipeline.test(built.mesh, skeleton: built.skeleton, skin: built.skin)
        check(skeletonOK && built.skin.valid(jointCount: built.skeleton.joints.count, vertexCount: built.mesh.vertexCount) && tests.allSatisfy { $0.status == .pass },
              "\(prompt): exact rig passes all 8 motion tests [\(tests.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: " "))]")
    }
    let claudeBody = try JSONSerialization.jsonObject(with: try ClaudeCharacter.requestBody(prompt: "a knight", model: ClaudeMotion.models[0])) as! [String: Any]
    check(((claudeBody["output_config"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String == "json_schema" && claudeBody["fallbacks"] as? String == "default", "Claude character request: structured output")
    let reply: [String: Any] = ["stop_reason": "end_turn", "content": [["type": "text", "text": #"{"name":"银骑士","height_m":1.9,"build":"heavy","head_scale":1,"hair":"none","outfit":"armor","accessories":["helmet","sword","shield","cape","laser"],"skin":"F0C8A8","hair_color":"333333","top":"C0C6D0","bottom":"404858","shoes":"303030","accent":"2850A0","metal":"D0D4DA"}"#]]]
    let knight = try ClaudeCharacter.spec(fromResponse: try JSONSerialization.data(withJSONObject: reply), status: 200)
    check(knight.name == "银骑士" && knight.build == .heavy && knight.accessories == [.helmet, .sword, .shield, .cape] && knight.top == "C0C6D0", "Claude character answer parsed, unknown items dropped")

    // Photos of a blocky figure from six directions (orthographic).
    let boxes: [(Int, Int, Int, Int, Int, Int)] = [(27, 0, 6, 31, 28, 12), (33, 0, 6, 37, 28, 12), (26, 28, 5, 38, 48, 11), (30, 48, 6, 34, 51, 10), (28, 51, 5, 36, 60, 11),
                                                   (21, 25, 6, 24, 47, 10), (40, 25, 6, 43, 47, 10), (24, 44, 6, 26, 47, 10), (38, 44, 6, 40, 47, 10)]
    func solid(_ x: Int, _ y: Int, _ z: Int) -> Bool { boxes.contains { x >= $0.0 && y >= $0.1 && z >= $0.2 && x < $0.3 && y < $0.4 && z < $0.5 } }
    func photo(_ view: PhotoView) -> ViewPhoto {
        let s = 4, pad = 20, W = 64, H = 64, D = 16
        let size: (Int, Int) = view == .front || view == .back ? (W, H) : view == .left || view == .right ? (D, H) : (W, D)
        let pw = size.0 * s + pad * 2, ph = size.1 * s + pad * 2
        var mask = [Float](repeating: 0, count: pw * ph)
        var image = RasterImage(width: pw, height: ph, fill: [10, 10, 10, 255])
        let tint: [UInt8] = view == .front ? [220, 40, 40] : view == .back ? [40, 40, 220] : [40, 200, 40]
        for py in pad..<(ph - pad) { for px in pad..<(pw - pad) {
            let u = (px - pad) / s, v = (py - pad) / s
            var hit = false
            switch view {
            case .front: for z in 0..<D where solid(u, H - 1 - v, z) { hit = true }
            case .back: for z in 0..<D where solid(W - 1 - u, H - 1 - v, z) { hit = true }
            case .left: for x in 0..<W where solid(x, H - 1 - v, D - 1 - u) { hit = true }
            case .right: for x in 0..<W where solid(x, H - 1 - v, u) { hit = true }
            case .top: for y in 0..<H where solid(u, y, v) { hit = true }
            case .bottom: for y in 0..<H where solid(u, y, D - 1 - v) { hit = true }
            }
            if hit { mask[py * pw + px] = 1; let o = (py * pw + px) * 4; image.rgba[o] = tint[0]; image.rgba[o + 1] = tint[1]; image.rgba[o + 2] = tint[2] }
        } }
        return ViewPhoto(width: pw, height: ph, mask: mask, image: image)
    }
    for set in [[PhotoView.front, .back], [.front, .back, .left, .right], PhotoView.allCases] {
        var photos: [PhotoView: ViewPhoto] = [:]
        for v in set { photos[v] = photo(v) }
        let result = try MultiViewCarver.build(photos)
        let a = MeshAnalyzer.analyze(result.mesh), b = result.mesh.bounds
        let depth = b.max[2] - b.min[2], width = b.max[0] - b.min[0]
        check(result.mesh.valid && a.watertight && a.components == 1 && signedVolume(result.mesh) > 0, "\(set.count) photos: one closed surface")
        check(abs(width - 22.0 / 60) < 0.03 && (set.count == 2 || abs(depth - 7.0 / 60) < 0.03), "\(set.count) photos: proportions (width \(width), depth \(depth))")
        let rig = try RiggingPipeline.run(result.mesh)
        check(rig.estimate.pose == .armsDown && rig.diagnostics.results.allSatisfy { $0.status != .fail }, "\(set.count) photos: rigged automatically")
        // The front faces take the front photo's colour.
        let front = result.mesh.vertexCount > 0 ? (0..<result.mesh.vertexCount).first { result.mesh.normals[$0 * 3 + 2] > 0.95 && abs(result.mesh.positions[$0 * 3]) < 0.02 && result.mesh.positions[$0 * 3 + 1] > 0.6 } : nil
        if let f = front {
            let u = result.mesh.uvs[f * 2], v = 1 - result.mesh.uvs[f * 2 + 1]
            let x = min(result.atlas.width - 1, Int(u * Float(result.atlas.width))), y = min(result.atlas.height - 1, Int(v * Float(result.atlas.height)))
            check(result.atlas.pixel(x, y)[0] > 150 && result.atlas.pixel(x, y)[2] < 100, "\(set.count) photos: front surface textured from the front photo")
        }
    }
    var noFront = false
    do { _ = try MultiViewCarver.build([.back: photo(.back)]) } catch MultiViewError.needsFront { noFront = true }
    check(noFront, "a front photo is required")
    let weld = MeshAnalyzer.weldMap(GeneratedMesh(positions: [0, 0, 0, 1, 0, 0, 0, 0, 0], normals: [Float](repeating: 0, count: 9), uvs: [Float](repeating: 0, count: 6), indices: []))
    check(weld == [0, 1, 0], "seam vertices welded for rigging")
    // Manual + AI joint editing.
    let built = ProceduralCharacterBuilder.build(CharacterKeywords.spec(for: "战士"))
    let base = built.skeleton
    let r = base.index(.rightHand)!, rightUpper = base.index(.rightUpperArm)!
    let moved = SkeletonBuilder.moving(base, joint: r, to: base.worldRest[r].origin + SIMD3(-0.05, 0.12, 0.1))
    var automatic: [JointTag: SIMD3<Float>] = [:]
    for (i, j) in base.joints.enumerated() { automatic[j.semanticTag] = base.worldRest[i].origin + SIMD3(0, 0.01, 0) }
    let assisted = SkeletonBuilder.assisted(moved, automatic: automatic, locked: [.rightHand, .rightUpperArm], mirror: true)
    let rh = assisted.position(.rightHand)!, lh = assisted.position(.leftHand)!, re = assisted.position(.rightForearm)!
    let ru = assisted.position(.rightUpperArm)!
    let centre = assisted.position(.pelvis)!.x
    check(rigLength(rh - moved.worldRest[r].origin) < 1e-4 && rigLength(ru - moved.worldRest[rightUpper].origin) < 1e-4, "AI assist keeps the joints placed by hand")
    check(abs(lh.x - (2 * centre - rh.x)) < 1e-4 && abs(lh.y - rh.y) < 1e-4, "AI assist mirrors the placed hand to the other side")
    let toHand = rh - ru, toElbow = re - ru
    let along = (toElbow * toHand).sum() / max(1e-6, (toHand * toHand).sum())
    check(along > 0.2 && along < 0.8 && rigLength(toElbow - toHand * along) < 1e-3, "the elbow is placed between the shoulder and the moved hand")
    check(abs(assisted.position(.head)!.y - base.position(.head)!.y - 0.01) < 1e-4, "untouched joints take the automatic positions")
    print("RPG v1.74 generation: \(checks) total checks passed")
}


// P41: v1.75 — local image → 3D: vertex colours, TripoSR decoder on the
// phone, local server protocol.
do {
    // GLB vertex colours round trip and baking into a texture.
    var tri = GeneratedMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0], normals: [Float](repeating: 0, count: 12), uvs: [Float](repeating: 0, count: 8), indices: [0, 1, 2, 1, 3, 2])
    tri.computeNormals()
    let colours: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 1]
    let coloured = try GLBCodec.read(GLBCodec.write(tri, colors: colours))
    check(coloured.colors == colours && coloured.texture == nil, "GLB vertex colours round trip")
    let baked = VertexColorBaker.bake(tri, colors: colours)
    check(baked.mesh.triangleCount == 2 && baked.mesh.vertexCount == 6 && baked.mesh.valid, "vertex colours baked: one cell per triangle")
    func texel(_ v: Int) -> [UInt8] {
        let u = baked.mesh.uvs[v * 2], w = 1 - baked.mesh.uvs[v * 2 + 1]
        return baked.texture.pixel(min(baked.texture.width - 1, Int(u * Float(baked.texture.width))), min(baked.texture.height - 1, Int(w * Float(baked.texture.height))))
    }
    check(texel(0)[0] == 255 && texel(0)[1] == 0 && texel(1)[1] == 255 && texel(2)[2] == 255 && texel(4)[0] == 255 && texel(4)[2] == 255, "each corner samples its vertex colour")

    // TripoSR decoder: tiny synthetic model whose density is a ball.
    let C = 2, S = 16
    var plane = [Float](repeating: 0, count: 3 * C * S * S)
    for p in 0..<3 { for y in 0..<S { for x in 0..<S {
        let u = (Float(x) + 0.5) / Float(S) * 2 - 1, v = (Float(y) + 0.5) / Float(S) * 2 - 1
        plane[p * C * S * S + y * S + x] = -(u * u + v * v)            // channel 0: −r² in this plane
        plane[p * C * S * S + S * S + y * S + x] = Float(p)            // channel 1: plane number
    } } }
    // One layer: density = 6 + Σ channel 0 (plane sums give −2r²), colours from channel 1.
    var w = [Float](repeating: 0, count: 4 * 3 * C)
    for p in 0..<3 { w[0 * 3 * C + p * C] = 4 }
    w[1 * 3 * C + 0 * C + 1] = 1; w[2 * 3 * C + 1 * C + 1] = 1; w[3 * 3 * C + 2 * C + 1] = 1
    var decoder = TripoSRDecoder(layers: [.init(outputs: 4, inputs: 3 * C, weights: w, bias: [6, 0, 0, 0])])
    decoder.channels = C; decoder.planeSize = S; decoder.threshold = 25
    let reloaded = try TripoSRDecoder.load(decoder.encoded())
    check(reloaded.layers.count == 1 && reloaded.channels == C && reloaded.planeSize == S && reloaded.layers[0].weights == w, "decoder weights file round trip")
    var corrupt = false
    do { _ = try TripoSRDecoder.load(Data("TSRDxxxx".utf8)) } catch { corrupt = true }
    check(corrupt, "damaged decoder file refused")
    // Texel centre samples exactly (align_corners = false), outside is zero padding.
    let centre = decoder.features(plane, points: [SIMD3((0.5 / Float(S) * 2 - 1) * 0.87, (0.5 / Float(S) * 2 - 1) * 0.87, 0)])
    check(abs(centre[0] - plane[0]) < 1e-5, "triplane sampled like grid_sample (texel centres)")
    let outside = decoder.features(plane, points: [SIMD3(5, 5, 5)])
    check(outside.allSatisfy { $0 == 0 }, "points outside the planes read zero")
    check(TripoSRDecoder.raw(SIMD3(1, 2, 3)) == SIMD3(-3, -1, 2), "TripoSR z-up → y-up front +z")
    let ball = try decoder.mesh(plane, resolution: 40)
    let a = MeshAnalyzer.analyze(ball.mesh), bb = ball.mesh.bounds
    let size = bb.max[0] - bb.min[0]
    check(ball.mesh.valid && a.watertight && a.components == 1 && size > 0.3 && size < 1.74, "decoder field becomes one closed surface (size \(size))")
    check(ball.colors.count == ball.mesh.vertexCount * 3 && ball.colors.allSatisfy { $0 > 0 && $0 < 1 }, "vertex colours from the decoder")

    // Local server protocol.
    check(LocalServerConfig.parse("192.168.1.20:8765", token: "") != nil && LocalServerConfig.parse("http://mac-studio.local:8765", token: "") != nil
          && LocalServerConfig.parse("http://172.20.0.5", token: "") != nil, "local network addresses accepted over http")
    check(LocalServerConfig.parse("http://example.com", token: "") == nil && LocalServerConfig.parse("http://8.8.8.8", token: "") == nil
          && LocalServerConfig.parse("https://gpu.example.com", token: "") != nil, "plain http to the internet refused")
    let server = LocalServerConfig.parse("192.168.1.20:8765/", token: "t")!
    let create = Image3DServerProtocol.create(server, image: Data([1, 2]), mime: "image/jpeg", texture: true)
    check(create.url?.absoluteString == "http://192.168.1.20:8765/v1/image3d/jobs" && create.httpMethod == "POST" && create.value(forHTTPHeaderField: "Authorization") == "Bearer t", "local server create request")
    check(Image3DServerProtocol.result(server, id: "a b").url?.path == "/v1/image3d/jobs/a%20b/result" || Image3DServerProtocol.result(server, id: "a b").url?.absoluteString.hasSuffix("/v1/image3d/jobs/a%20b/result") == true, "local server result request")
    let health = try Image3DServerProtocol.healthInfo(Data(#"{"name":"Moonlight Local 3D","backend":"triposr","version":"1.75"}"#.utf8))
    check(health.backend == "triposr", "health reply read")
    let served = try Image3DServerProtocol.model(fromGLB: GLBCodec.write(tri, colors: colours))
    check(served.texture != nil && served.mesh.triangleCount == 2, "server GLB with vertex colours gets a texture")
    print("RPG v1.75 local 3D: \(checks) total checks passed")
}

// P42: v1.76 — model files (glTF / FBX / OBJ / STL / 3MF) with their own
// skeletons and animations, and character sheets → views.
do {
    // Inflate (zlib from Python's zlib.compress).
    let z: [UInt8] = [120, 218, 203, 205, 207, 207, 203, 201, 76, 207, 40, 81, 200, 197, 100, 41, 2, 0, 187, 153, 11, 213]
    let inflated = try Inflate.zlib(z)
    check(String(decoding: inflated, as: UTF8.self) == "moonlight moonlight moonlight!", "zlib stream inflated")

    func bytes<T>(_ v: [T]) -> [UInt8] { v.withUnsafeBufferPointer { Array(UnsafeRawBufferPointer($0)) } }
    func deform(_ m: GeneratedMesh, _ s: SkeletonDefinition, _ skin: SkinInfluences, _ locals: [RigXform]?) -> [SIMD3<Float>] {
        let world = locals.map { s.worldTransforms(local: $0) } ?? s.worldRest
        let mats = zip(world, s.joints).map { $0 * (RigXform(matrix: $1.inverseBindMatrix) ?? .identity) }
        return (0..<m.vertexCount).map { v in
            let p = SIMD3(m.positions[v * 3], m.positions[v * 3 + 1], m.positions[v * 3 + 2])
            var o = SIMD3<Float>(repeating: 0)
            for (j, w) in skin.influences(v) { o += mats[j].point(p) * w }
            return o
        }
    }
    func far(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { let d = a - b; return (d * d).sum().squareRoot() }

    // glTF: a z-up armature node (turned upright), two joints, one animation.
    let pos: [Float] = [-0.5, 0, 0, 0.5, 0, 0, 0.5, 0, 2, -0.5, 0, 2]
    let jts: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
    let wts: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
    let idx: [UInt16] = [0, 1, 2, 0, 2, 3]
    let ibm: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,  1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -1, 1]
    let times: [Float] = [0, 1]
    let rot: [Float] = [0, 0, 0, 1, 0.7071068, 0, 0, 0.7071068]
    var bin: [UInt8] = []
    var views: [[String: Any]] = []
    for part in [bytes(pos), jts, bytes(wts), bytes(idx) + [0, 0], bytes(ibm), bytes(times), bytes(rot)] {
        views.append(["buffer": 0, "byteOffset": bin.count, "byteLength": part.count]); bin += part
    }
    let gltf: [String: Any] = [
        "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0, 3]]],
        "nodes": [["name": "Armature", "rotation": [-0.7071068, 0, 0, 0.7071068], "children": [1]], ["name": "Hips", "children": [2]],
                  ["name": "Spine", "translation": [0, 0, 1]], ["name": "Body", "mesh": 0, "skin": 0]],
        "skins": [["joints": [1, 2], "inverseBindMatrices": 4]],
        "meshes": [["primitives": [["attributes": ["POSITION": 0, "JOINTS_0": 1, "WEIGHTS_0": 2], "indices": 3]]]],
        "buffers": [["byteLength": bin.count, "uri": "data:application/octet-stream;base64," + Data(bin).base64EncodedString()]],
        "bufferViews": views,
        "accessors": [["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"], ["bufferView": 1, "componentType": 5121, "count": 4, "type": "VEC4"],
                      ["bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC4"], ["bufferView": 3, "componentType": 5123, "count": 6, "type": "SCALAR"],
                      ["bufferView": 4, "componentType": 5126, "count": 2, "type": "MAT4"], ["bufferView": 5, "componentType": 5126, "count": 2, "type": "SCALAR"],
                      ["bufferView": 6, "componentType": 5126, "count": 2, "type": "VEC4"]],
        "animations": [["name": "Armature|Walk", "samplers": [["input": 5, "output": 6]], "channels": [["sampler": 0, "target": ["node": 2, "path": "rotation"]]]]],
    ]
    let model = try ModelImport.read(try JSONSerialization.data(withJSONObject: gltf), fileName: "hero.gltf")
    let b = model.mesh.bounds
    check(b.max[1] - b.min[1] > 0.99 && b.max[2] - b.min[2] < 0.01, "glTF armature rotation stands the model up (normalised to 1 tall)")
    guard let rig = model.rig else { throw ImportError.empty }
    check(rig.skeleton.joints.count == 3 && rig.skin.valid(jointCount: 3, vertexCount: 4) && rig.clips.count == 1 && rig.clips[0].name == "Armature|Walk", "glTF skin, joints and animation kept")
    check((try? rig.skeleton.validate(humanoid: false)) != nil, "imported skeleton passes the checks")
    let rest = model.mesh.positions
    let atRest = deform(model.mesh, rig.skeleton, rig.skin, nil)
    let atStart = deform(model.mesh, rig.skeleton, rig.skin, rig.clips[0].locals(rig.skeleton, at: 0))
    check((0..<4).allSatisfy { far(atRest[$0], SIMD3(rest[$0 * 3], rest[$0 * 3 + 1], rest[$0 * 3 + 2])) < 1e-4 && far(atStart[$0], atRest[$0]) < 1e-4 },
          "rest pose and the clip's first frame match the stored mesh")
    let mid = deform(model.mesh, rig.skeleton, rig.skin, rig.clips[0].locals(rig.skeleton, at: 0.999))
    check(far(mid[0], atRest[0]) < 1e-4 && far(mid[2], atRest[2]) > 0.3, "animation turns the spine joint only")
    let clips = MotionClip.fromFile(rig.clips + [KeyframeClip(id: "x", name: "Attack 01", duration: 1, tracks: [], base: rig.clips[0].base)])
    check(clips.map(\.id) == ["walk", "swordSwing"] && clips[0].keyframes != nil, "file clips named after the motions they match")
    check(MotionClip.resolve("run", in: clips)?.id == "walk" && MotionClip.resolve("swordSwing", in: clips)?.id == "swordSwing"
          && MotionClip.resolve("walk", in: MotionClip.library)?.keyframes == nil, "world actions find file clips first")
    let pose = clips[0].pose(rig.skeleton, at: 0.5)
    check(pose.locals?.count == 3 && pose.skinning(rig.skeleton).count == 3, "file clips pose through full local transforms")
    let saved = try JSONEncoder().encode(clips[0]), old = try JSONEncoder().encode(MotionClip.library[1])
    let savedBack = try JSONDecoder().decode(MotionClip.self, from: saved), oldBack = try JSONDecoder().decode(MotionClip.self, from: old)
    check(savedBack == clips[0] && oldBack.keyframes == nil,
          "clips with and without keyframes round-trip (older saves still read)")
    // Missing companion buffer.
    var external = gltf; external["buffers"] = [["byteLength": bin.count, "uri": "hero.bin"]]
    let externalData = try JSONSerialization.data(withJSONObject: external)
    check((try? ModelImport.read(externalData, fileName: "hero.gltf")) == nil && (try? ModelImport.read(externalData, fileName: "hero.gltf", companions: ["Hero.BIN": Data(bin)])) != nil,
          "glTF .bin taken from the picked companion files")

    // ASCII FBX.
    let fbx = """
    ; FBX 7.4.0 project file
    FBXHeaderExtension:  {
    \tFBXVersion: 7400
    }
    Objects:  {
    \tGeometry: 10, "Geometry::Quad", "Mesh" {
    \t\tVertices: *12 {
    \t\t\ta: 0,0,0,1,0,0,1,1,0,0,1,0
    \t\t}
    \t\tPolygonVertexIndex: *4 {
    \t\t\ta: 0,1,2,-4
    \t\t}
    \t}
    \tModel: 20, "Model::Quad", "Mesh" {
    \t\tProperties70:  {
    \t\t\tP: "Lcl Translation", "Lcl Translation", "", "A",5,0,0
    \t\t}
    \t}
    }
    Connections:  {
    \tC: "OO",10,20
    \tC: "OO",20,0
    }
    """
    let quad = try ModelImport.read(Data(fbx.utf8), fileName: "quad.fbx")
    check(quad.mesh.triangleCount == 2 && quad.rig == nil, "ASCII FBX mesh read")

    // OBJ with a material library and texture.
    let obj = "mtllib quad.mtl\nv 0 0 0 1 0 0\nv 1 0 0 0 1 0\nv 1 1 0 0 0 1\nv 0 1 0 1 1 1\nvt 0 0\nvt 1 0\nvt 1 1\nvt 0 1\nusemtl skin\nf 1/1 2/2 3/3 4/4\n"
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]
    let objModel = try ModelImport.read(Data(obj.utf8), fileName: "quad.obj", companions: ["quad.mtl": Data("newmtl skin\nmap_Kd .\\Tex.PNG\n".utf8), "tex.png": Data(png)])
    check(objModel.mesh.triangleCount == 2 && objModel.texture == Data(png) && objModel.colors?.count == 12, "OBJ: polygon, vertex colours and map_Kd texture")

    // STL round trip (z-up on disk).
    let stl = try ModelImport.read(STLWriter.binary(objModel.mesh), fileName: "quad.stl")
    let sb = stl.mesh.bounds
    check(stl.mesh.triangleCount == 2 && stl.mesh.vertexCount == 4 && abs(sb.max[1] - sb.min[1] - 1) < 1e-3 && sb.max[2] - sb.min[2] < 1e-3,
          "STL written and read back in the same orientation")

    // 3MF (stored zip) with a base material colour; z-up → y-up.
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>
    <basematerials id="1"><base name="red" displaycolor="#FF0000"/></basematerials>
    <object id="2" type="model" pid="1" pindex="0"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="0" z="20"/></vertices>
    <triangles><triangle v1="0" v2="1" v3="2"/></triangles></mesh></object></resources><build><item objectid="2"/></build></model>
    """
    func storedZip(_ files: [(String, [UInt8])]) -> Data {
        var out: [UInt8] = [], central: [UInt8] = []
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8 & 255)] }
        func u32(_ v: Int) -> [UInt8] { u16(v & 0xFFFF) + u16(v >> 16) }
        for (name, body) in files {
            let n = Array(name.utf8), offset = out.count
            out += u32(0x04034B50) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(body.count) + u32(body.count) + u16(n.count) + u16(0) + n + body
            central += u32(0x02014B50) + u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(body.count) + u32(body.count) + u16(n.count) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + n
        }
        let start = out.count
        out += central + u32(0x06054B50) + u16(0) + u16(0) + u16(files.count) + u16(files.count) + u32(central.count) + u32(start) + u16(0)
        return Data(out)
    }
    let printed = try ModelImport.read(storedZip([("[Content_Types].xml", Array("<Types/>".utf8)), ("3D/3dmodel.model", Array(xml.utf8))]), fileName: "part.3mf")
    let pb = printed.mesh.bounds
    check(printed.mesh.triangleCount == 1 && pb.max[1] - pb.min[1] > 0.99 && printed.colors?.prefix(3).map { $0 } == [1, 0, 0], "3MF read from its zip, colour kept, stood up")

    // Character sheet: four figures on grey with a floor shadow each.
    var sheet = RasterImage(width: 400, height: 200, fill: [200, 200, 205, 255])
    func paint(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ c: [UInt8]) {
        for y in y0..<y1 { for x in x0..<x1 { let o = (y * 400 + x) * 4; for k in 0..<3 { sheet.rgba[o + k] = c[k] } } }
    }
    for c in [50, 150, 250, 350] {
        paint(c - 14, c + 14, 168, 174, [150, 150, 155])                 // floor shadow
        paint(c - 6, c + 6, 18, 38, [235, 220, 200])                     // head
        paint(c - 10, c + 10, 40, 110, [240, 240, 240])                  // body
        paint(c - 8, c + 8, 70, 72, [196, 196, 201])                      // grey shading close to the background
        paint(c - 10, c - 3, 110, 170, [240, 240, 240]); paint(c + 3, c + 10, 110, 170, [240, 240, 240])   // legs
    }
    let found = CharacterSheet.panels(sheet)
    check(found.count == 4 && found.allSatisfy { $0.h >= 140 && $0.w < 50 }, "four standing figures found in the row")
    let labelled = CharacterSheet.assign(found, labels: ["FRONT", "BACK", "LEFT SIDE", "3/4 FRONT"].enumerated().map { i, t in
        SheetLabel(text: t, x0: Float(50 + i * 100 - 15) / 400, x1: Float(50 + i * 100 + 15) / 400, y0: 0.9, y1: 0.95) }, imageWidth: 400, imageHeight: 200)
    check(labelled.map(\.view) == [.front, .back, .left, nil] && labelled[3].diagonal, "labels name the views; 3/4 is left out")
    check(CharacterSheet.assign(found, labels: [], imageWidth: 400, imageHeight: 200).map(\.view) == [.front, .back, .left, .right], "unlabelled sheets use the usual order")
    let view = CharacterSheet.photo(sheet, panel: labelled[0])
    func maskAt(_ x: Int, _ y: Int) -> Float { view.mask[(y - labelled[0].y0) * view.width + (x - labelled[0].x0)] }
    check(maskAt(50, 80) == 1 && maskAt(50, 71) == 1 && maskAt(44, 140) == 1, "figure outline kept, grey shading inside it filled")
    check(maskAt(50, 150) == 0 && maskAt(50, 171) == 0, "gap between the legs and the floor shadow are background")
    var photos: [PhotoView: ViewPhoto] = [:]
    for p in labelled { if let v = p.view { photos[v] = CharacterSheet.photo(sheet, panel: p) } }
    let carved = try MultiViewCarver.build(photos)
    check(carved.mesh.valid && carved.mesh.triangleCount > 100, "sheet views carve into a model")
    print("RPG v1.76 model files: \(checks) total checks passed")
}

// P43: v1.78 — Liquid Glass system: roles, non-touch bases, panels keep
// their taps, one place for motion, selection tools and projection sync.
do {
    let base = RPGHUDGlassStyle.resolve(.base, RPGHUDConditions(editing: true))
    check(!base.interactive && !base.regular && base.scrim == 0 && base.role == .clear, "a control base is clear, non-interactive glass without scrim")
    check(RPGHUDGlassStyle.resolve(.base, RPGHUDConditions(reduceTransparency: true)).role == .solid, "bases go solid with Reduce Transparency")
    check(RPGHUDGlassStyle.resolve(.panel, RPGHUDConditions()).role == .regular && RPGHUDGlassStyle.resolve(.light, RPGHUDConditions()).role == .clear,
          "panels are regular glass, status surfaces clear glass")
    check(RPGHUDGlassStyle.resolve(.interactive, RPGHUDConditions()).interactive && !RPGHUDGlassStyle.resolve(.light, RPGHUDConditions()).interactive
          && !RPGHUDGlassStyle.resolve(.panel, RPGHUDConditions()).interactive, "only touchable controls get interactive glass")
    check(RPGHUDGlassKind.panel.absorbsTouches && !RPGHUDGlassKind.light.absorbsTouches && !RPGHUDGlassKind.base.absorbsTouches && !RPGHUDGlassKind.interactive.absorbsTouches,
          "panels keep taps on empty areas; status surfaces and bases let them through")
    let morph = MoonGlassMotion.curve(.morph, reduceMotion: false), calm = MoonGlassMotion.curve(.morph, reduceMotion: true)
    check(!morph.linear && morph.response > 0.2 && morph.response < 0.6 && morph.damping >= 0.75, "glass morph is a gentle spring without a big bounce")
    check(calm.linear && calm.response > 0 && calm.response <= 0.25 && MoonGlassMotion.curve(.press, reduceMotion: true).response == 0,
          "Reduce Motion: morphs become short fades, press scaling stops")
    check(MoonGlassMotion.allows(lastAction: nil, now: 5) && !MoonGlassMotion.allows(lastAction: 5, now: 5.1) && MoonGlassMotion.allows(lastAction: 5, now: 5.4),
          "a glass action runs once while its group morphs")
    // Selection tools: copy beside the selection (loose blocks / a whole building).
    var dw = SpatialWorld()
    dw.blocks = [SpatialBlock(id: "a", x: 10, y: 10, elevation: 0, thickness: 1), SpatialBlock(id: "b", x: 12, y: 11, elevation: 2, thickness: 1),
                 SpatialBlock(id: "c", x: 30, y: 30, elevation: 0, thickness: 1)]
    let loose = SpatialBuilder.duplicate(["a", "b"], idPrefix: "copy", world: &dw)
    let copiedA = dw.blocks.first { $0.id == loose.first }
    check(loose.count == 2 && dw.blocks.count == 5 && copiedA?.x == 13 && copiedA?.y == 10 && copiedA?.elevation == 0 && copiedA?.groupID == nil,
          "loose blocks copied one selection width east, same heights")
    dw.groups = [BuildingGroup(id: "house", name: "House", motionID: nil, origin: .user, template: nil)]
    for i in dw.blocks.indices where dw.blocks[i].id == "c" { dw.blocks[i].groupID = "house" }
    let building = SpatialBuilder.duplicate(["c"], idPrefix: "copy2", world: &dw)
    check(building.count == 1 && dw.groups.count == 2 && dw.blocks.first { $0.id == building[0] }?.groupID == dw.groups[1].id, "a whole building copies as a new building")
    check(SpatialBuilder.duplicate([], idPrefix: "x", world: &dw).isEmpty && dw.blocks.count == 6, "nothing selected copies nothing")

    // Projection sync: the glass hides at once on rotation / resume and settles again.
    var settle = NativeGlassFade()
    for _ in 0..<40 { _ = settle.step(camera: SpatialCameraState(), dt: 1.0 / 60) }
    check(settle.visibility == 1, "still camera shows the glass")
    settle.restart()
    check(settle.visibility == 0 && settle.step(camera: SpatialCameraState(), dt: 1.0 / 60) == 0, "restart hides the glass until the view settles")
    for _ in 0..<60 { _ = settle.step(camera: SpatialCameraState(), dt: 1.0 / 60) }
    check(settle.visibility == 1, "glass returns after the restart settles")

    // Performance readout: shape updates per second.
    var meter = GlassPerfMeter()
    var total = 0
    for f in 0..<120 { if f % 4 == 0 { total += 1 }; meter.frame(dt: 1.0 / 60, publishes: total) }
    check(abs(meter.framesPerSecond - 60) < 1 && abs(meter.publishesPerSecond - 15) < 1.5, "meter counts frames and glass updates per second (\(meter.publishesPerSecond))")
    print("RPG v1.78 glass: \(checks) total checks passed")
}

print("RPG complete: \(checks) total checks passed")
