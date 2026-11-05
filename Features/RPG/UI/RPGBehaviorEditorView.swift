import SwiftUI

struct RPGBehaviorEditorView:View {
    @ObservedObject var session:RPGSession
    let target:WorldEntity
    @State private var trigger=RPGBehaviorTrigger.tap
    @State private var graphID=RPGOfficialStory.graph.id
    @State private var radius=2
    @State private var delay=5
    @State private var event="blockDestroyed"
    @State private var requiresWood=false
    var body:some View {
        Form { Group {
            Text("方块 "+target.id).font(.caption)
            Picker("触发器",selection:$trigger){ForEach(RPGBehaviorTrigger.allCases,id:\.self){Text($0.rawValue).tag($0)}}
            Picker("剧情与白名单动作",selection:$graphID){
                Text(RPGOfficialStory.graph.title).tag(RPGOfficialStory.graph.id)
                ForEach(session.world.story.customGraphs){Text($0.title).tag($0.id)}
            }
            Stepper("接近半径：\(radius)",value:$radius,in:1...8)
            Stepper("计时：\(delay) 秒",value:$delay,in:1...60)
            TextField("剧情事件键",text:$event)
            HStack{Text("条件：至少 1 木材");Spacer();Toggle("条件：至少 1 木材",isOn:$requiresWood).labelsHidden().frame(width:51,height:44)}
            Button("绑定所选触发器"){
                let binding=RPGBehaviorBinding(entityID:target.id,graphID:graphID,trigger:trigger,condition:requiresWood ? .init(kind:.resource,key:"wood",value:1):nil,radius:radius,delay:Double(delay),eventKey:event)
                session.bindBehavior(binding,target:target)
            }.accessibilityIdentifier("rpg-bind-behavior")
            Button("清除此方块行为",role:.destructive){session.clearBehaviors(target.id)}
            Text("触发器启动受校验的剧情图，由同一白名单事务执行动作。每个绑定只触发一次，既有剧情回执不重置；不支持脚本。").font(.caption)
            Text(session.notice).font(.caption)
            }.listRowBackground(MoonLiquidRowBackground())
        }.moonLiquidList().navigationTitle("方块行为").buttonStyle(MoonGlassButtonStyle())
    }
}
