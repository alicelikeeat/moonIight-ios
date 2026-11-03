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
var faller = SpatialPlayer(); faller.position = SpatialVector(60.5, 60.5, -9); faller.lastSafe = SpatialVector(61.5, 61.5, 0); faller.grounded = false
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

print("RPG complete: \(checks) total checks passed")
