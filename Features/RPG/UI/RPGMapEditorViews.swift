import SwiftUI

/// Bottom toolbar (task E3). Choosing another tool with an unconfirmed
/// draft goes through `requestTool`, which asks first.
struct RPGEditorToolBar: View {
    @ObservedObject var session: RPGSession
    let requestTool: (RPGEditorTool) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(RPGEditorTool.allCases, id: \.self) { tool in
                    Button { requestTool(tool) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tool.symbol).font(.system(size: 16, weight: .semibold))
                            Text(tool.title).font(.system(size: 10))
                        }
                        .frame(width: 46, height: 44)
                        .background(session.editorTool == tool ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rpg-editor-tool-" + tool.rawValue)
                    .accessibilityValue(session.editorTool == tool ? "已选" : "未选")
                }
            }.padding(.horizontal, 6).padding(.vertical, 4)
        }
        .worldGlass(radius: 16)
    }
}

/// Options for the current tool: brush material or content, terrain type,
/// and the multi-select actions.
struct RPGEditorOptionsBar: View {
    @ObservedObject var session: RPGSession

    var body: some View {
        Group {
            switch session.editorTool {
            case .brush, .fill: brushOptions
            case .terrain: terrainOptions
            case .multi: areaOptions
            default: EmptyView()
            }
        }
    }

    private var brushOptions: some View {
        HStack(spacing: 8) {
            Text(session.editorTool == .fill ? "拖出矩形填充：" : "画笔：").font(.caption)
            Menu {
                ForEach(BlockDefinition.all) { definition in
                    Button(definition.title) { session.brushPayload = .block(definition.id) }
                }
            } label: { Label(materialTitle, systemImage: "cube") }
                .accessibilityIdentifier("rpg-editor-brush-material")
            Button {
                if let entity = session.selectedEntity, let binding = session.mediaBinding(for: .entity(entity.id)) { session.brushPayload = .content(binding) }
            } label: { Label("用选中格内容", systemImage: "eyedropper") }
                .disabled(session.selectedEntity.flatMap { session.mediaBinding(for: .entity($0.id)) } == nil)
                .accessibilityIdentifier("rpg-editor-brush-content")
            Text(session.brushPayload.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).worldGlass(radius: 14)
    }

    private var materialTitle: String {
        if case .block(let id) = session.brushPayload { return BlockDefinition.find(id)?.title ?? id }
        return "方块材质"
    }

    private var terrainOptions: some View {
        HStack(spacing: 6) {
            Text("地形：").font(.caption)
            ForEach(RPGTerrain.allCases, id: \.self) { terrain in
                Button(terrain.title) { session.terrainBrush = terrain }
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(session.terrainBrush == terrain ? Color.accentColor.opacity(0.28) : .clear, in: Capsule())
                    .buttonStyle(.plain).accessibilityIdentifier("rpg-editor-terrain-" + String(terrain.rawValue))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).worldGlass(radius: 14)
    }

    private var areaOptions: some View {
        HStack(spacing: 8) {
            Text(session.area.map { "选区 \($0.count) 格" } ?? "拖动框选区域").font(.caption)
            Group {
                Button("擦除") { session.eraseArea() }.accessibilityIdentifier("rpg-editor-area-erase")
                Button("填充") { session.fillArea() }.accessibilityIdentifier("rpg-editor-area-fill")
                Button("复制") { session.copyArea() }.accessibilityIdentifier("rpg-editor-area-copy")
                Button("同类替换") { session.replaceInArea() }.accessibilityIdentifier("rpg-editor-area-replace")
                Button("取消选区") { session.clearArea() }
            }.disabled(session.area == nil)
            Button("粘贴到选中格") { if let point = session.selected { session.pastePreview(at: point) } }
                .disabled(!session.hasClipboard || session.selected == nil).accessibilityIdentifier("rpg-editor-area-paste")
        }
        .font(.caption).padding(.horizontal, 10).padding(.vertical, 6).worldGlass(radius: 14)
    }
}

/// The unconfirmed draft: what it would do, confirm, cancel (task E5).
struct RPGDraftBar: View {
    @ObservedObject var session: RPGSession

    var body: some View {
        if let draft = session.draft {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("预览 · " + draft.payload.title).font(.caption.weight(.semibold))
                    Text(session.draftPlan?.summary ?? "正在计算影响范围…").font(.caption2).foregroundStyle(blocked ? .orange : .secondary)
                        .accessibilityIdentifier("rpg-draft-summary")
                    if draft.truncated { Text("一次最多 \(RPGWorldEditing.maximumBatch) 格，超出部分未加入。").font(.caption2).foregroundStyle(.orange) }
                    if blocked { Text("超出角色建造范围：切换到自由编辑，或取消后重新选择。").font(.caption2).foregroundStyle(.orange) }
                }
                Spacer(minLength: 4)
                Button("取消") { session.discardDraft() }.accessibilityIdentifier("rpg-draft-cancel")
                Button("确认") { session.confirmDraft() }
                    .disabled(blocked || session.working || (session.draftPlan?.cells.isEmpty ?? true))
                    .accessibilityIdentifier("rpg-draft-confirm")
            }
            .padding(.horizontal, 12).padding(.vertical, 8).worldGlass(radius: 16)
        }
    }

    private var blocked: Bool { (session.draftPlan?.outOfRange ?? 0) > 0 }
}

/// Floating, non-modal property panel for one cell (task E3). The map
/// stays visible and usable beside it.
struct RPGCellPanel: View {
    @ObservedObject var session: RPGSession
    let store: MediaStore
    let point: SurfacePoint
    let onClose: () -> Void

    var body: some View {
        let entity = session.entity(at: point)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("格子 x \(point.x) · z \(point.z)").font(.subheadline.weight(.semibold)).accessibilityIdentifier("rpg-panel-coordinate")
                    Text(materialLine(entity))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("rpg-panel-material")
                }
                Spacer()
                if entity != nil {
                    Button { session.eraseCell(point); onClose() } label: { Image(systemName: "eraser") }
                        .accessibilityLabel("擦除方块").accessibilityIdentifier("rpg-panel-erase")
                }
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("关闭面板").accessibilityIdentifier("rpg-panel-close")
            }
            .padding(12)
            Divider()
            NavigationStack {
                RPGCellEditorView(session: session, store: store, entity: entity, point: point, initialKind: session.panelKind, onClose: onClose)
            }
            // A new identity per cell resets the draft when another cell is picked.
            .id("\(point.x),\(point.z),\(entity?.mediaBindingID ?? "-"),\(session.panelKind?.rawValue ?? "-")")
        }
        .worldGlass(radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rpg-cell-panel")
    }

    private func materialLine(_ entity: WorldEntity?) -> String {
        let terrain: String = session.terrain(at: point)?.title ?? "—"
        var block = "无方块"
        if let entity, let definition = BlockDefinition.find(entity.definitionID) { block = definition.title }
        return "地形 \(terrain) · \(block)"
    }
}
