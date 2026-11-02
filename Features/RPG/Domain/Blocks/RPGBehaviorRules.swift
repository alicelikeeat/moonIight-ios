import Foundation

enum RPGBehaviorTrigger:String,Codable,CaseIterable,Sendable {case tap,proximity,attack,timer,storyEvent}
struct RPGBehaviorBinding:Codable,Equatable,Identifiable,Sendable {
    var id=UUID().uuidString
    var entityID:String
    var graphID:String
    var trigger=RPGBehaviorTrigger.tap
    var condition:RPGStoryCondition?
    var radius=2
    var delay=5.0
    var createdAt=0.0
    var eventKey="blockDestroyed"
    var eventBaseline=0
}
struct RPGBehaviorState:Codable,Equatable,Sendable {
    var bindings:[RPGBehaviorBinding]=[]
    var firedIDs:[String]=[]
    func validate(graphIDs:Set<String>)throws {
        guard bindings.count<=256,firedIDs.count<=256,Set(bindings.map(\.id)).count==bindings.count,Set(firedIDs).count==firedIDs.count,
              firedIDs.allSatisfy({id in bindings.contains{$0.id==id}}) else{throw RPGWorldError.invalidState}
        for binding in bindings {
            guard !binding.id.isEmpty,binding.id.count<=128,!binding.entityID.isEmpty,binding.entityID.count<=128,graphIDs.contains(binding.graphID),
                  (1...8).contains(binding.radius),binding.delay.isFinite,(1...3600).contains(binding.delay),binding.createdAt.isFinite,(0...1e10).contains(binding.createdAt),
                  !binding.eventKey.isEmpty,binding.eventKey.count<=128,(0...1_000_000).contains(binding.eventBaseline) else{throw RPGWorldError.invalidState}
            if let condition=binding.condition {
                let graph=RPGStoryGraph(id:"validation",title:"condition",start:"test",nodes:[.init(id:"test",kind:.condition,next:"end",condition:condition),.init(id:"end",kind:.end)])
                try graph.validate()
            }
        }
    }
}
enum RPGBehaviorRules {
    static func bind(_ binding:RPGBehaviorBinding,target:WorldEntity,world:inout WorldState,generator:RPGWorldGenerator)throws {
        guard target.id==binding.entityID else{throw RPGWorldError.missingReference}
        if let p=target.surface,!world.isCreativeCopy,generator.protected(p){throw RPGEditError.protectedArea}
        if let p=target.side,!world.isCreativeCopy,let region=world.sideRegions.first(where:{$0.id==p.regionID}),generator.protected(.init(x:region.origin.x+p.horizontal,z:region.origin.z)){throw RPGEditError.protectedArea}
        var next=world,binding=binding
        binding.createdAt=world.combat.clock;binding.eventBaseline=world.story.eventCounts[binding.eventKey,default:0]
        let replaced=Set(next.behaviors.bindings.filter{$0.entityID==binding.entityID && $0.trigger==binding.trigger}.map(\.id))
        next.behaviors.bindings.removeAll{replaced.contains($0.id)};next.behaviors.firedIDs.removeAll{replaced.contains($0)}
        next.behaviors.bindings.append(binding);next.revision+=1;try next.validate();world=next
    }
    @discardableResult static func fire(_ trigger:RPGBehaviorTrigger,targetID:String?=nil,entities:[WorldEntity],world:inout WorldState,generator:RPGWorldGenerator)throws->Bool {
        guard !world.player.inCombat,world.player.health>0 else{return false}
        let graphList=[RPGOfficialStory.graph]+world.story.customGraphs
        for binding in world.behaviors.bindings.sorted(by:{$0.id<$1.id}) where binding.trigger==trigger && !world.behaviors.firedIDs.contains(binding.id) {
            guard let target=entities.first(where:{$0.id==binding.entityID}),targetID==nil || targetID==target.id,
                  let graph=graphList.first(where:{$0.id==binding.graphID}) else{continue}
            let progress=world.story.progress.first{$0.id==graph.id} ?? .init(id:graph.id,version:graph.version,current:graph.start)
            if let condition=binding.condition,!RPGStoryRuntime.condition(condition,world:world,progress:progress,graph:graph,generator:generator){continue}
            switch trigger {
            case .tap,.attack:guard targetID==target.id else{continue}
            case .timer:guard world.combat.clock-binding.createdAt>=binding.delay else{continue}
            case .storyEvent:guard world.story.eventCounts[binding.eventKey,default:0]>binding.eventBaseline else{continue}
            case .proximity:
                if world.player.perspective == .side {
                    guard let p=world.player.side,let e=target.side,p.regionID==e.regionID,abs(p.horizontal-e.horizontal)+abs(p.height-e.height)<=binding.radius else{continue}
                }else{guard let e=target.surface,abs(e.x-world.player.surface.x)+abs(e.z-world.player.surface.z)<=binding.radius else{continue}}
            }
            var next=world
            let first=next.story.progress.allSatisfy{$0.id != graph.id}
            try RPGStoryRuntime.start(graphID:graph.id,world:&next)
            if first{try RPGStoryRuntime.advance(world:&next,generator:generator)}
            next.behaviors.firedIDs.append(binding.id);next.revision+=1;try next.validate();world=next;return true
        }
        return false
    }
}
