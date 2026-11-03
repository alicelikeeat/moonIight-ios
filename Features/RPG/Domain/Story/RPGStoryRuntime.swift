import Foundation

enum RPGStoryRuntime {
    static func enemyID(graphID:String,key:String)->String {
        var hash:UInt64=14695981039346656037
        for byte in graphID.utf8 {hash=(hash ^ UInt64(byte)) &* 1099511628211}
        return "story:\(hash):\(key.prefix(80))"
    }
    static func condition(_ test:RPGStoryCondition,world:WorldState,progress:RPGStoryProgress,graph:RPGStoryGraph,generator:RPGWorldGenerator)->Bool {
        switch test.kind {
        case .always:return true
        case .variable:return progress.variables[test.key,default:0]>=test.value
        case .resource:return world.inventory[test.key,default:0]>=test.value
        case .event:return world.story.eventCounts[test.key,default:0]>=test.value || world.events.filter{$0.kind==test.key}.count>=test.value
        case .nearAnchor:
            let p=generator.anchor(test.anchor);return world.player.perspective == .topDown && abs(world.player.surface.x-p.x)+abs(world.player.surface.z-p.z)<=4
        case .quest:return progress.quests[test.key,default:0]>=test.value
        case .enemyDefeated:return world.combat.defeatedIDs.contains(enemyID(graphID:graph.id,key:test.key))
        }
    }
    static func recordEvents(world:inout WorldState) {
        let ids=world.events.map(\.id)
        guard ids != world.story.observedEventIDs else{return}
        var seen=Set(world.story.observedEventIDs)
        for event in world.events where seen.insert(event.id).inserted {
            if world.story.eventCounts[event.kind] != nil || world.story.eventCounts.count<512 {world.story.eventCounts[event.kind]=min(1_000_000,world.story.eventCounts[event.kind,default:0]+1)}
        }
        world.story.observedEventIDs=ids;world.revision+=1
    }
    static func start(graphID:String,world:inout WorldState)throws {
        guard !world.player.inCombat else{throw RPGStoryError.combat}
        var next=world
        guard let graph=([RPGOfficialStory.graph]+next.story.customGraphs).first(where:{$0.id==graphID}) else{throw RPGStoryError.invalidGraph}
        try graph.validate();next.story.activeGraphID=graphID
        if let saved=next.story.progress.first(where:{$0.id==graphID}) {guard saved.version==graph.version else{throw RPGStoryError.version}}
        else {guard next.story.progress.count<32 else{throw RPGStoryError.invalidGraph};next.story.progress.append(.init(id:graph.id,version:graph.version,current:graph.start))}
        next.revision+=1;try next.validate();world=next
    }
    /// Visible node and its finite automatic successors commit atomically.
    static func advance(choiceID:String?=nil,world:inout WorldState,generator:RPGWorldGenerator)throws {
        var next=world
        recordEvents(world:&next)
        let graph=next.story.activeGraph;try graph.validate()
        if !next.story.progress.contains(where:{$0.id==graph.id}) {try start(graphID:graph.id,world:&next)}
        guard let index=next.story.progress.firstIndex(where:{$0.id==graph.id}) else{throw RPGStoryError.invalidGraph}
        var progress=next.story.progress[index]
        guard progress.version==graph.version else{throw RPGStoryError.version}
        if progress.ended{return}
        var first=true
        for _ in 0..<256 {
            guard let node=graph.nodes.first(where:{$0.id==progress.current}) else{throw RPGStoryError.invalidGraph}
            let visited=progress.receipts.contains(node.id)
            if !visited {
                for action in node.actions {try execute(action,node:node,graph:graph,world:&next,progress:&progress,generator:generator)}
                progress.receipts.append(node.id)
            }
            if node.kind == .end {progress.ended=true;break}
            let visible=[RPGStoryNodeKind.dialogue,.choice,.media].contains(node.kind) || !node.text.isEmpty
            if !visited && visible {break}
            if !first && visible {break}
            var target=node.next
            if let test=node.condition,!condition(test,world:next,progress:progress,graph:graph,generator:generator) {
                guard let failure=node.failure else{break};target=failure
            }
            if node.kind == .choice {
                guard let choiceID,let selected=node.choices.first(where:{$0.id==choiceID}),selected.condition.map({condition($0,world:next,progress:progress,graph:graph,generator:generator)}) ?? true else{throw RPGStoryError.choice}
                progress.choices[node.id]=choiceID;target=selected.target
            }
            if !progress.completed.contains(node.id){progress.completed.append(node.id)}
            guard let target else{progress.ended=true;break}
            progress.current=target;first=false
        }
        next.story.progress[index]=progress;recordEvents(world:&next);next.revision+=1;try next.validate();world=next
    }
    private static func execute(_ action:RPGStoryAction,node:RPGStoryNode,graph:RPGStoryGraph,world:inout WorldState,progress:inout RPGStoryProgress,generator:RPGWorldGenerator)throws {
        switch action.kind {
        case .setVariable:progress.variables[action.key]=action.value
        case .giveItem:
            guard world.inventory[action.key,default:0]<=1_000_000-action.value else{throw RPGStoryError.resource}
            world.inventory[action.key,default:0]+=action.value
        case .takeItem:
            guard world.inventory[action.key,default:0]>=action.value else{throw RPGStoryError.resource};world.inventory[action.key,default:0]-=action.value
        case .setQuest:progress.quests[action.key]=action.value
        case .emitEvent:
            world.events.append(.init(id:"story-event:"+UUID().uuidString,kind:action.key,entityID:graph.id,definitionID:node.id));world.events=Array(world.events.suffix(256))
        case .placeBlock:
            guard let point=action.point else{throw RPGStoryError.invalidGraph}
            try RPGWorldEditing.place([.init(point:point,definitionID:action.key)],world:&world,generator:generator)
        case .removeBlock:
            guard let point=action.point else{throw RPGStoryError.invalidGraph}
            try RPGWorldEditing.hit(point,world:&world,generator:generator,force:world.player.mode == .creative)
        case .setBackground:
            guard world.mediaBindings.contains(where:{$0.id==action.key}) else{throw RPGWorldError.missingReference};world.backgroundBindingIDs=[action.key]
        case .spawnEnemy:
            let id=enemyID(graphID:graph.id,key:action.key)
            if world.combat.enemies.contains(where:{$0.id==id}){return}
            guard world.combat.enemies.count<128 else{throw RPGStoryError.resource}
            let anchor=generator.anchor(action.anchor)
            let p=action.point ?? SurfacePoint(x:anchor.x+2,z:anchor.z)
            guard p.valid,RPGWorldTerrain.passable(p,world:world,generator:generator),RPGWorldEditing.entity(at:p,world:world,generator:generator)?.physics.topDownSolid != true else{throw RPGStoryError.condition}
            world.combat.enemies.append(.init(id:id,surface:p,health:max(1,min(500,action.value)),maximumHealth:max(1,min(500,action.value)),aggro:true));world.player.inCombat=true
        }
    }
}
