import SwiftUI
import UniformTypeIdentifiers

struct RPGStoryDocument:FileDocument {
    static var readableContentTypes:[UTType]{[.json]}
    var data:Data
    init(data:Data){self.data=data}
    init(configuration:ReadConfiguration)throws {
        guard let data=configuration.file.regularFileContents,data.count<=RPGStoryCodec.maximumBytes else{throw RPGStoryError.tooLarge}
        _=try RPGStoryCodec.decode(data);self.data=data
    }
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{FileWrapper(regularFileWithContents:data)}
}
struct RPGStoryEditorView:View {
    @ObservedObject var session:RPGSession
    @EnvironmentObject private var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingTitle:Bool
    @State private var graph=RPGStoryAuthoring.template()
    @State private var bindings:[MediaBinding]=[]
    @State private var message="编辑后先校验，可在隔离预览中测试。保存会创建新剧情，保留旧进度。"
    @State private var importing=false
    @State private var exporting=false
    @State private var previewing=false
    @State private var document=RPGStoryDocument(data:Data())
    var body:some View {
        List {
            Section("剧情") {
                TextField("标题",text:$graph.title).focused($editingTitle).submitLabel(.done).onSubmit{editingTitle=false}.accessibilityIdentifier("rpg-story-title")
                Picker("起始节点",selection:$graph.start){ForEach(graph.nodes){Text($0.id).tag($0.id)}}
                Text(message).font(.caption).accessibilityIdentifier("rpg-editor-status")
            }
            Section("节点列表") {
                ForEach(graph.nodes){node in
                    NavigationLink {
                        RPGStoryNodeEditor(node:node,nodes:graph.nodes,media:model.mediaStore.items,bindings:session.world.mediaBindings+bindings){node,entry,loop,muted in
                            var node=node
                            var binding:MediaBinding?
                            if let entry {binding = .init(id:UUID().uuidString,mediaID:entry.id,kind:entry.kind == .video ? .video:.image)}
                            else if let original=(session.world.mediaBindings+bindings).first(where:{$0.id==node.mediaBindingID}) {binding=original;binding?.id=UUID().uuidString}
                            if var binding {binding.loop=loop;binding.muted=true;bindings.append(binding);node.mediaBindingID=binding.id}
                            if let index=graph.nodes.firstIndex(where:{$0.id==node.id}){graph.nodes[index]=node}
                            let used=Set(graph.nodes.compactMap(\.mediaBindingID));bindings.removeAll{!used.contains($0.id)}
                        }
                    } label:{VStack(alignment:.leading){Text(node.id+" · "+node.kind.rawValue);Text(node.text).lineLimit(1).font(.caption)}}
                    .accessibilityIdentifier("rpg-edit-node-"+node.id)
                }.onDelete{graph.nodes.remove(atOffsets:$0)}
                Button("添加节点"){if graph.nodes.count<256{graph.nodes.append(.init(id:"node-"+UUID().uuidString.prefix(8),text:"新节点"))}}
            }
            Section("校验与游玩") {
                Button("校验断链与循环"){validate()}.accessibilityIdentifier("rpg-story-validate")
                Button("隔离预览"){if validate(){previewing=true}}.accessibilityIdentifier("rpg-story-preview")
                Button("保存为新剧情"){
                    guard validate() else{return}
                    var published=graph;published.id="custom."+UUID().uuidString;published.version=1
                    if session.installStory(published,bindings:bindings){message="已保存："+published.title+"。可在剧情与任务中开始。"}
                }.accessibilityIdentifier("rpg-story-publish")
            }
            Section("JSON") {
                Button("导入 JSON"){importing=true}.accessibilityIdentifier("rpg-story-import")
                Button("导出 JSON"){
                    do{document = .init(data:try RPGStoryCodec.encode(graph));exporting=true}catch{message=error.localizedDescription}
                }.accessibilityIdentifier("rpg-story-export")
                Text("只导出节点和媒体引用，不打包视频。缺失媒体保留字幕；不执行脚本。").font(.caption)
            }
        }.navigationTitle("剧情编辑器").buttonStyle(MoonGlassButtonStyle())
            .navigationBarBackButtonHidden(true)
            .toolbar{ToolbarItem(placement:.navigationBarLeading){Button("返回工具"){dismiss()}.accessibilityIdentifier("rpg-editor-back")}}
            .fileImporter(isPresented:$importing,allowedContentTypes:[.json]){result in
                do {
                    let url=try result.get(),access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
                    let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
                    guard size<=RPGStoryCodec.maximumBytes else{throw RPGStoryError.tooLarge}
                    graph=try RPGStoryCodec.decode(Data(contentsOf:url));bindings=[];message="已导入，尚未保存到世界。"
                }catch{message=error.localizedDescription}
            }
            .fileExporter(isPresented:$exporting,document:document,contentType:.json,defaultFilename:"Moonlight-Story"){result in
                switch result{case .success:message="JSON 已导出。";case .failure(let error):message=error.localizedDescription}
            }
            .sheet(isPresented:$previewing){NavigationStack{RPGStoryPreviewView(graph:graph,bindings:bindings,source:session.world)}}
    }
    @discardableResult private func validate()->Bool {
        do{try graph.validate();message="校验通过：\(graph.nodes.count) 个节点，无断链或循环。";return true}catch{message=error.localizedDescription;return false}
    }
}

private struct RPGStoryNodeEditor:View {
    @Environment(\.dismiss) private var dismiss
    @State var node:RPGStoryNode
    let nodes:[RPGStoryNode]
    let media:[MediaEntry]
    let bindings:[MediaBinding]
    let save:(RPGStoryNode,MediaEntry?,Bool,Bool)->Void
    @State private var loop=false
    @State private var muted=true
    @State private var selectedMedia=""
    var body:some View {
        Form {
            properties; conditions; choices; actions; mediaSection
            Button("应用节点修改"){
                if selectedMedia=="clear"{node.mediaBindingID=nil}
                if node.kind == .end {node.next=nil;node.failure=nil;node.choices=[]}
                node.mediaLoop=loop;node.mediaMuted=muted
                save(node,media.first{$0.id==selectedMedia},loop,muted);dismiss()
            }.accessibilityIdentifier("rpg-node-apply")
        }.navigationTitle("节点表单").buttonStyle(MoonGlassButtonStyle())
            .onAppear{if let binding=bindings.first(where:{$0.id==node.mediaBindingID}){loop=node.mediaLoop ?? binding.loop;muted=node.mediaMuted ?? binding.muted}}
    }

    private var properties:some View {
            Section("属性") {
                Text(node.id).font(.caption)
                Picker("节点类型",selection:$node.kind){ForEach(RPGStoryNodeKind.allCases,id:\.self){Text($0.rawValue).tag($0)}}
                TextEditor(text:$node.text).frame(minHeight:100).accessibilityIdentifier("rpg-node-text")
                target("下一节点",value:$node.next)
            }
    }
    private var conditions:some View {
            Section("条件") {
                Toggle("启用条件",isOn:Binding(get:{node.condition != nil},set:{node.condition=$0 ? .init():nil}))
                if node.condition != nil {
                    Picker("条件类型",selection:condition(\.kind)){ForEach(RPGStoryConditionKind.allCases,id:\.self){Text($0.rawValue).tag($0)}}
                    TextField("变量 / 物品 / 事件 / 敌人键",text:condition(\.key))
                    Stepper("阈值 \(node.condition?.value ?? 1)",value:condition(\.value),in:-1000...1000)
                    Picker("锚点",selection:condition(\.anchor)){ForEach(RPGAnchorID.allCases,id:\.self){Text($0.title).tag($0)}}
                    target("失败分支（空为等待）",value:$node.failure)
                }
            }
    }
    @ViewBuilder private var choices:some View {
            if node.kind == .choice {
                Section("选项") {
                    ForEach(node.choices.indices,id:\.self){index in
                        TextField("选项文字",text:$node.choices[index].text)
                        Picker("目标",selection:$node.choices[index].target){ForEach(nodes){Text($0.id).tag($0.id)}}
                        Toggle("需要物品",isOn:Binding(get:{node.choices[index].condition != nil},set:{node.choices[index].condition=$0 ? .init(kind:.resource,key:"wood",value:1):nil}))
                        if node.choices[index].condition != nil {
                            TextField("物品键",text:Binding(get:{node.choices[index].condition?.key ?? ""},set:{node.choices[index].condition?.key=$0}))
                        }
                        Button("删除选项",role:.destructive){node.choices.remove(at:index)}
                    }
                    Button("添加选项"){if node.choices.count<8{node.choices.append(.init(id:UUID().uuidString,text:"新选项",target:nodes.last?.id ?? node.id))}}
                }
            }
    }
    private var actions:some View {
            Section("白名单动作") {
                ForEach(node.actions.indices,id:\.self){index in
                    Picker("动作",selection:$node.actions[index].kind){ForEach(RPGStoryActionKind.allCases,id:\.self){Text($0.rawValue).tag($0)}}
                    TextField("变量 / 物品 / 方块 / 媒体绑定键",text:$node.actions[index].key)
                    Stepper("数值 \(node.actions[index].value)",value:$node.actions[index].value,in:-1000...1000)
                    Picker("敌人锚点",selection:$node.actions[index].anchor){ForEach(RPGAnchorID.allCases,id:\.self){Text($0.title).tag($0)}}
                    Toggle("指定地表坐标",isOn:Binding(get:{node.actions[index].point != nil},set:{node.actions[index].point=$0 ? .init(x:16,z:16):nil}))
                    if let p=node.actions[index].point {
                        Stepper("x \(p.x)",value:Binding(get:{node.actions[index].point?.x ?? 0},set:{node.actions[index].point?.x=$0}),in:0...255)
                        Stepper("z \(p.z)",value:Binding(get:{node.actions[index].point?.z ?? 0},set:{node.actions[index].point?.z=$0}),in:0...255)
                    }
                    Button("删除动作",role:.destructive){node.actions.remove(at:index)}
                }
                Button("添加动作"){if node.actions.count<32{node.actions.append(.init(kind:.setVariable,key:"flag"))}}
            }
    }
    private var mediaSection:some View {
            Section("媒体演出") {
                Picker("本地素材",selection:$selectedMedia){
                    Text("保留当前绑定").tag("")
                    Text("清除绑定").tag("clear")
                    ForEach(media.filter{$0.kind != .embed}){Text($0.title).tag($0.id)}
                }.pickerStyle(.menu).accessibilityIdentifier("rpg-node-media")
                HStack{Text("循环演出");Spacer();Toggle("循环演出",isOn:$loop).labelsHidden().frame(width:51,height:44)}
                HStack{Text("静音");Spacer();Toggle("静音",isOn:$muted).labelsHidden().frame(width:51,height:44)}
                Text("节点文字同时作为字幕；用户可跳过，媒体缺失时仍能继续。").font(.caption)
            }
    }
    private func condition<T>(_ key:WritableKeyPath<RPGStoryCondition,T>)->Binding<T>{
        Binding(get:{(node.condition ?? .init())[keyPath:key]},set:{node.condition?[keyPath:key]=$0})
    }
    private func target(_ title:String,value:Binding<String?>)->some View{
        Picker(title,selection:value){Text("无").tag(String?.none);ForEach(nodes.filter{$0.id != node.id}){Text($0.id).tag(Optional($0.id))}}
    }
}

private struct RPGStoryPreviewView:View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model:AppModel
    let graph:RPGStoryGraph,bindings:[MediaBinding],source:WorldState
    @State private var world:WorldState?
    @State private var message=""
    var body:some View {
        List {
            Text("隔离创造副本预览，原世界和官方进度不会改变。").font(.caption)
            if let world,let progress=world.story.activeProgress,let node=world.story.activeGraph.nodes.first(where:{$0.id==progress.current}) {
                Text(node.text).accessibilityIdentifier("rpg-preview-text")
                if node.kind == .media,let binding=node.mediaBindingID {
                    RPGCutsceneView(world:world,bindingID:binding,store:model.mediaStore,seconds:0,loop:node.mediaLoop,muted:node.mediaMuted,progress:{_ in}).id(node.id)
                }
                if !progress.ended {
                    if node.kind == .choice {
                        ForEach(node.choices){choice in Button(choice.text){advance(choice.id)}.accessibilityIdentifier("rpg-preview-choice-"+choice.id)}
                    }else{Button("继续 / 检查条件"){advance()}.accessibilityIdentifier("rpg-preview-next")}
                }else{Text("预览结束").accessibilityIdentifier("rpg-preview-ended")}
                Text("木材 \(world.inventory["wood",default:0]) · 月晶 \(world.inventory["moon-shard",default:0])")
                Section("预览事件模拟") {
                    Button("模拟方块破坏事件"){mutate{world in world.events.append(.init(id:UUID().uuidString,kind:"blockDestroyed",entityID:"preview",definitionID:"wood"))}}
                    Button("模拟抵达条件锚点"){if let condition=node.condition{mutate{$0.player.surface=RPGWorldGenerator(seed:$0.seed).anchor(condition.anchor)}}}
                    Button("模拟战斗胜利"){mutate{world in
                        for i in world.combat.enemies.indices where world.combat.enemies[i].health>0 {world.combat.enemies[i].health=0;if !world.combat.defeatedIDs.contains(world.combat.enemies[i].id){world.combat.defeatedIDs.append(world.combat.enemies[i].id)}}
                        world.player.inCombat=false
                    }}
                }
            }
            Text(message).font(.caption)
        }.navigationTitle("隔离预览").buttonStyle(MoonGlassButtonStyle())
            .toolbar{ToolbarItem(placement:.confirmationAction){Button("结束预览"){dismiss()}.accessibilityIdentifier("rpg-preview-close")}}
            .onAppear{do{world=try RPGStoryAuthoring.preview(graph,bindings:bindings,source:source)}catch{message=error.localizedDescription}}
    }
    private func mutate(_ action:(inout WorldState)->Void){if var value=world{action(&value);world=value}}
    private func advance(_ choice:String?=nil){
        guard var value=world else{return}
        do{try RPGStoryRuntime.advance(choiceID:choice,world:&value,generator:RPGWorldGenerator(seed:value.seed));world=value}catch{message=error.localizedDescription}
    }
}
