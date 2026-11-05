import SwiftUI

struct RPGStoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: RPGSession
    @EnvironmentObject private var model:AppModel
    let travel: (RPGAnchorID) -> Void
    var backTitle="返回工具"
    private var graph: RPGStoryGraph { session.world.story.activeGraph }
    private var progress: RPGStoryProgress? { session.world.story.activeProgress }
    private var node: RPGStoryNode? { graph.nodes.first{$0.id == (progress?.current ?? graph.start)} }
    var body: some View {
        List { Group {
            Section(graph.title) {
                if let node {
                    Text(node.text.isEmpty ? node.kind.rawValue : node.text).accessibilityIdentifier("rpg-story-text")
                    if node.kind == .media,let binding=node.mediaBindingID {
                        RPGCutsceneView(world:session.world,bindingID:binding,store:model.mediaStore,seconds:session.world.story.mediaPositions[graph.id+":"+node.id,default:0],loop:node.mediaLoop,muted:node.mediaMuted,progress:{session.recordStoryMedia(node.id,seconds:$0)}).id(node.id)
                    }
                    if progress?.ended == true {
                        Text("本段剧情已完成，奖励与选择已存入当前世界。").accessibilityIdentifier("rpg-story-ended")
                    } else if node.kind == .choice {
                        ForEach(node.choices) { choice in
                            Button(choice.text) { session.advanceStory(choice:choice.id) }
                                .disabled(!available(choice.condition))
                                .accessibilityIdentifier("rpg-story-choice-"+choice.id)
                        }
                    } else {
                        Button(node.kind == .media ? "跳过 / 继续" : node.condition == nil ? "继续" : "检查任务条件") { session.advanceStory() }
                            .accessibilityIdentifier("rpg-story-next")
                        if let condition = node.condition, !available(condition) {
                            Text("等待任务条件满足，可关闭面板继续探索。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let condition = node.condition, condition.kind == .nearAnchor {
                        Button("沿通路前往"+condition.anchor.title) { travel(condition.anchor) }.accessibilityIdentifier("rpg-story-travel")
                    }
                }
            }
            if let progress {
                Section("任务与选择") {
                    ForEach(progress.quests.keys.sorted(),id:\.self) { key in
                        Text("\(key)：\(progress.quests[key] == 2 ? "完成":"进行中")")
                    }
                    Text("已完成 \(progress.completed.count) 个节点 · 分支 \(progress.choices.count)")
                        .font(.caption).accessibilityIdentifier("rpg-story-progress")
                }
            }
            Section("本地剧情") {
                Button("继续官方主线") { session.beginStory(RPGOfficialStory.graph.id) }
                ForEach(session.world.story.customGraphs) { graph in
                    Button(graph.title) { session.beginStory(graph.id) }
                }
            }
            }.listRowBackground(MoonLiquidRowBackground())
        }.moonLiquidList().navigationTitle("剧情与任务").buttonStyle(MoonGlassButtonStyle())
            .navigationBarBackButtonHidden(true)
            .toolbar { ToolbarItem(placement:.navigationBarLeading) { Button(backTitle) { dismiss() }.accessibilityIdentifier("rpg-story-back") } }
            .onAppear { session.prepareStory() }
    }
    private func available(_ condition: RPGStoryCondition?) -> Bool {
        guard let condition else { return true }
        guard let progress else { return false }
        return RPGStoryRuntime.condition(condition,world:session.world,progress:progress,graph:graph,generator:session.generator)
    }
}
