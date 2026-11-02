import Foundation

enum RPGStoryNodeKind:String,Codable,CaseIterable,Sendable { case dialogue,choice,condition,variable,quest,media,world,combat,end }
enum RPGStoryConditionKind:String,Codable,CaseIterable,Sendable { case always,variable,resource,event,nearAnchor,quest,enemyDefeated }
struct RPGStoryCondition:Codable,Equatable,Sendable {
    var kind=RPGStoryConditionKind.always
    var key=""
    var value=1
    var anchor=RPGAnchorID.spawn
}
enum RPGStoryActionKind:String,Codable,CaseIterable,Sendable { case setVariable,giveItem,takeItem,setQuest,placeBlock,removeBlock,spawnEnemy,emitEvent,setBackground }
struct RPGStoryAction:Codable,Equatable,Sendable {
    var kind:RPGStoryActionKind
    var key=""
    var value=1
    var point:SurfacePoint?
    var anchor=RPGAnchorID.village
}
struct RPGStoryChoice:Codable,Equatable,Identifiable,Sendable {
    var id:String
    var text:String
    var target:String
    var condition:RPGStoryCondition?
}
struct RPGStoryNode:Codable,Equatable,Identifiable,Sendable {
    var id:String
    var kind=RPGStoryNodeKind.dialogue
    var text=""
    var next:String?
    var failure:String?
    var choices:[RPGStoryChoice]=[]
    var condition:RPGStoryCondition?
    var actions:[RPGStoryAction]=[]
    var mediaBindingID:String?
    var mediaLoop:Bool?
    var mediaMuted:Bool?
}
struct RPGStoryGraph:Codable,Equatable,Identifiable,Sendable {
    var id:String
    var version=1
    var title:String
    var start:String
    var nodes:[RPGStoryNode]
    func validate()throws {
        guard !id.isEmpty,id.count<=128,(1...1_000_000).contains(version),!title.isEmpty,title.count<=128,!nodes.isEmpty,nodes.count<=256,
              Set(nodes.map(\.id)).count==nodes.count,nodes.contains(where:{$0.id==start}) else{throw RPGStoryError.invalidGraph}
        let ids=Set(nodes.map(\.id))
        func edges(_ node:RPGStoryNode)->[String]{[node.next,node.failure].compactMap{$0}+node.choices.map(\.target)}
        for node in nodes {
            guard !node.id.isEmpty,node.id.count<=128,node.text.count<=8000,(node.mediaBindingID?.count ?? 0)<=128,node.choices.count<=8,node.actions.count<=32,
                  Set(node.choices.map(\.id)).count==node.choices.count,edges(node).allSatisfy({ids.contains($0)}),
                  node.choices.allSatisfy({!$0.id.isEmpty && $0.id.count<=128 && !$0.text.isEmpty && $0.text.count<=512}),
                  node.kind != .choice || !node.choices.isEmpty,
                  node.kind != .condition || node.condition != nil,
                  node.kind != .end || edges(node).isEmpty else{throw RPGStoryError.invalidGraph}
            for condition in [node.condition].compactMap({$0})+node.choices.compactMap(\.condition) {
                guard condition.key.count<=128,([RPGStoryConditionKind.always,.nearAnchor].contains(condition.kind) || !condition.key.isEmpty),(-1_000_000...1_000_000).contains(condition.value) else{throw RPGStoryError.invalidGraph}
            }
            for action in node.actions {
                guard !action.key.isEmpty,action.key.count<=128,(-1_000_000...1_000_000).contains(action.value),action.point == nil || action.point?.valid == true else{throw RPGStoryError.invalidGraph}
                if [.giveItem,.takeItem].contains(action.kind) {
                    guard ["wood","stone","moon-shard","moonBlade","stoneArmor"].contains(action.key),(1...100).contains(action.value) else{throw RPGStoryError.invalidGraph}
                }
                if action.kind == .spawnEnemy {guard action.key.count<=80,(1...500).contains(action.value) else{throw RPGStoryError.invalidGraph}}
                if action.kind == .removeBlock {guard action.point != nil else{throw RPGStoryError.invalidGraph}}
                if action.kind == .placeBlock {guard BlockDefinition.find(action.key) != nil,action.point != nil else{throw RPGStoryError.invalidGraph}}
            }
        }
        // Include unreachable nodes: importing a hidden cycle is also rejected.
        var visiting=Set<String>(),done=Set<String>()
        let byID=Dictionary(uniqueKeysWithValues:nodes.map{($0.id,$0)})
        func visit(_ id:String)throws {
            if visiting.contains(id){throw RPGStoryError.cycle}
            if done.contains(id){return};visiting.insert(id)
            for next in edges(byID[id]!) {try visit(next)}
            visiting.remove(id);done.insert(id)
        }
        for node in nodes {try visit(node.id)}
    }
}
struct RPGStoryProgress:Codable,Equatable,Identifiable,Sendable {
    var id:String
    var version:Int
    var current:String
    var completed:[String]=[]
    var choices:[String:String]=[:]
    var variables:[String:Int]=[:]
    var quests:[String:Int]=[:]
    var receipts:[String]=[]
    var ended=false
    var valid:Bool{!id.isEmpty && id.count<=128 && version>0 && current.count<=128 && completed.count<=256 && Set(completed).count==completed.count && choices.count<=256 && variables.count<=256 && quests.count<=256 && receipts.count<=256 && Set(receipts).count==receipts.count && (Array(variables.values)+Array(quests.values)).allSatisfy{(-1_000_000...1_000_000).contains($0)}}
}
struct RPGStoryState:Codable,Equatable,Sendable {
    var activeGraphID=RPGOfficialStory.graph.id
    var mediaPositions:[String:Double]=[:]
    var eventCounts:[String:Int]=[:]
    var observedEventIDs:[String]=[]
    var progress:[RPGStoryProgress]=[]
    var customGraphs:[RPGStoryGraph]=[]
    func validate()throws {
        guard mediaPositions.count<=4096,mediaPositions.values.allSatisfy({$0.isFinite && (0...10_000_000).contains($0)}),eventCounts.count<=512,eventCounts.values.allSatisfy({(0...1_000_000).contains($0)}),observedEventIDs.count<=256,Set(observedEventIDs).count==observedEventIDs.count,progress.count<=32,customGraphs.count<=16,Set(progress.map(\.id)).count==progress.count,Set(customGraphs.map(\.id)).count==customGraphs.count,
              progress.allSatisfy(\.valid),!customGraphs.contains(where:{$0.id==RPGOfficialStory.graph.id}) else{throw RPGStoryError.invalidGraph}
        for graph in customGraphs{try graph.validate()}
        let graphs=[RPGOfficialStory.graph]+customGraphs
        guard graphs.contains(where:{$0.id==activeGraphID}) else{throw RPGStoryError.invalidGraph}
        for saved in progress {
            guard let graph=graphs.first(where:{$0.id==saved.id}),saved.version==graph.version,graph.nodes.contains(where:{$0.id==saved.current}),
                  saved.completed.allSatisfy({id in graph.nodes.contains{$0.id==id} && saved.receipts.contains(id)}),
                  saved.choices.allSatisfy({key,value in graph.nodes.contains{$0.id==key && $0.kind == .choice && $0.choices.contains{$0.id==value}}}),
                  (Array(saved.variables.keys)+Array(saved.quests.keys)).allSatisfy({!$0.isEmpty && $0.count<=128}),saved.receipts.allSatisfy({id in graph.nodes.contains{$0.id==id}}) else{throw RPGStoryError.invalidGraph}
        }
    }
    var activeGraph:RPGStoryGraph {customGraphs.first{$0.id==activeGraphID} ?? RPGOfficialStory.graph}
    var activeProgress:RPGStoryProgress? {progress.first{$0.id==activeGraphID}}
}
enum RPGStoryError:Error,LocalizedError {
    case invalidGraph,cycle,condition,choice,resource,version,tooLarge,combat
    var errorDescription:String? {
        switch self {
        case .invalidGraph:"剧情存在无效节点、断链或字段。"
        case .cycle:"剧情含循环，请用有限节点表达重复过程。"
        case .condition:"任务条件尚未满足。"
        case .choice:"该选项暂不可用。"
        case .resource:"剧情所需材料不足。"
        case .version:"剧情版本与进度不匹配，保留原进度。"
        case .tooLarge:"剧情 JSON 超过 1 MB。"
        case .combat:"战斗期间不能开始其他剧情。"
        }
    }
}
enum RPGStoryCodec {
    static let maximumBytes=1024*1024
    static func encode(_ graph:RPGStoryGraph)throws->Data {
        try graph.validate();let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(graph);guard data.count<=maximumBytes else{throw RPGStoryError.tooLarge};return data
    }
    static func decode(_ data:Data)throws->RPGStoryGraph {
        guard data.count<=maximumBytes else{throw RPGStoryError.tooLarge};let graph=try JSONDecoder().decode(RPGStoryGraph.self,from:data);try graph.validate();return graph
    }
}
