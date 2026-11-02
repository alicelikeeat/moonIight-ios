import Foundation

enum RPGStoryAuthoring {
    static func template()->RPGStoryGraph {
        .init(id:"custom."+UUID().uuidString,title:"我的月光故事",start:"intro",nodes:[
            .init(id:"intro",text:"你的故事从这里开始。",next:"choice"),
            .init(id:"choice",kind:.choice,text:"选择一条路。",choices:[
                .init(id:"build",text:"完成一次方块事件",target:"block"),
                .init(id:"watch",text:"观看媒体演出",target:"media")]),
            .init(id:"block",kind:.quest,text:"破坏任意方块，再检查任务。",next:"end",condition:.init(kind:.event,key:"blockDestroyed")),
            .init(id:"media",kind:.media,text:"可在节点表单中绑定图片或视频；这里是字幕。",next:"end"),
            .init(id:"end",kind:.end,text:"创作剧情完成。",actions:[.init(kind:.giveItem,key:"wood",value:1)])
        ])
    }
    static func install(_ graph:RPGStoryGraph,bindings:[MediaBinding],world:inout WorldState)throws {
        try graph.validate()
        guard graph.id != RPGOfficialStory.graph.id,!world.story.customGraphs.contains(where:{$0.id==graph.id}),world.story.customGraphs.count<16 else{throw RPGStoryError.invalidGraph}
        var next=world
        for binding in bindings where !next.mediaBindings.contains(where:{$0.id==binding.id}) {next.mediaBindings.append(binding)}
        next.story.customGraphs.append(graph);next.revision+=1;try next.validate();world=next
    }
    static func preview(_ graph:RPGStoryGraph,bindings:[MediaBinding],source:WorldState)throws->WorldState {
        var copy=source
        copy.id=UUID().uuidString;copy.parentWorldID=source.id;copy.isCreativeCopy=true;copy.player.mode = .creative
        copy.player.inCombat=false;copy.player.health=100;copy.undo=[];copy.redo=[]
        for index in copy.combat.enemies.indices{copy.combat.enemies[index].aggro=false}
        // A preview has its own graph identity and never consumes official progress.
        var graph=graph;graph.id="preview."+UUID().uuidString
        copy.story=RPGStoryState();copy.events=[]
        try install(graph,bindings:bindings,world:&copy);try RPGStoryRuntime.start(graphID:graph.id,world:&copy)
        try RPGStoryRuntime.advance(world:&copy,generator:RPGWorldGenerator(seed:copy.seed));return copy
    }
}
