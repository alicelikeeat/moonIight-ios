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
                            Text(tool.title).font(.system(size: 10)).lineLimit(1).fixedSize()
                        }
                        .frame(minWidth: 46, minHeight: 44).padding(.horizontal, 2)
                        .foregroundStyle(session.editorTool == tool ? Color.accentColor : Color.primary)
                        .background(session.editorTool == tool ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("rpg-editor-tool-" + tool.rawValue)
                    .accessibilityValue(session.editorTool == tool ? L10n.t("已选", "Selected") : L10n.t("未选", "Not selected"))
                }
            }.padding(.horizontal, 6).padding(.vertical, 4)
        }
        .editorSurface(radius: 16)
    }
}

/// Options for the current tool: brush material or content, terrain type,
/// and the multi-select actions.
struct RPGEditorOptionsBar: View {
    @ObservedObject var session: RPGSession
    /// Opens the glass shape editor (iOS 26+); nil hides the button.
    var openShapeEditor: (() -> Void)? = nil

    var body: some View {
        Group {
            switch session.editorTool {
            case .brush, .fill: brushOptions
            case .terrain: terrainOptions
            case .multi: areaOptions
            case .shape: shapeOptions
            default: EmptyView()
            }
        }
    }

    private var brushOptions: some View {
        HStack(spacing: 8) {
            Text(session.editorTool == .fill ? L10n.t("拖出矩形填充：", "Drag a rectangle to fill:") : L10n.t("画笔：", "Brush:")).font(.caption)
            Menu {
                ForEach(BlockDefinition.all) { definition in
                    Button(definition.name) { session.brushPayload = .block(definition.id) }
                }
            } label: { Label(materialTitle, systemImage: "cube") }
                .accessibilityIdentifier("rpg-editor-brush-material")
            Button {
                if let entity = session.selectedEntity, let binding = session.mediaBinding(for: .entity(entity.id)) { session.brushPayload = .content(binding) }
            } label: { Label(L10n.t("用选中格内容", "Use Selected Content"), systemImage: "eyedropper") }
                .disabled(session.selectedEntity.flatMap { session.mediaBinding(for: .entity($0.id)) } == nil)
                .accessibilityIdentifier("rpg-editor-brush-content")
            Text(session.brushPayload.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).editorSurface(radius: 14)
    }

    private var materialTitle: String {
        if case .block(let id) = session.brushPayload { return BlockDefinition.find(id)?.name ?? id }
        return L10n.t("方块材质", "Block Material")
    }

    private var shapeOptions: some View {
        HStack(spacing: 10) {
            Text(L10n.t("形状画笔：", "Shape brush:")).font(.caption)
            RPGShapeMenu(selection: session.shapeBrush) { session.shapeBrush = $0 } label: {
                HStack(spacing: 6) {
                    ShapeThumbnail(outline: session.shapeBrush, size: 20)
                    Text(RPGShapeName.of(session.shapeBrush)).font(.caption).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
            }
            .accessibilityIdentifier("rpg-editor-shape-brush")
            if let openShapeEditor {
                Button { openShapeEditor() } label: { Label(L10n.t("设计形状", "Design"), systemImage: "scribble.variable") }
                    .font(.caption).accessibilityIdentifier("rpg-editor-shape-designer")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).editorSurface(radius: 14)
    }

    private var terrainOptions: some View {
        HStack(spacing: 6) {
            Text(L10n.t("地形：", "Terrain:")).font(.caption)
            ForEach(RPGTerrain.allCases, id: \.self) { terrain in
                Button(terrain.title) { session.terrainBrush = terrain }
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(session.terrainBrush == terrain ? Color.accentColor.opacity(0.28) : .clear, in: Capsule())
                    .buttonStyle(.plain).accessibilityIdentifier("rpg-editor-terrain-" + String(terrain.rawValue))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6).editorSurface(radius: 14)
    }

    private var areaOptions: some View {
        ScrollView(.horizontal, showsIndicators: false) { areaButtons.padding(.horizontal, 10).padding(.vertical, 6) }
            .fixedSize(horizontal: false, vertical: true).editorSurface(radius: 14)
    }

    private var areaButtons: some View {
        HStack(spacing: 12) {
            Text(session.area.map { L10n.t("选区 \($0.count) 格", "\($0.count) cells") } ?? L10n.t("拖动框选区域", "Drag to select an area")).font(.caption)
            Group {
                Button(L10n.t("擦除", "Erase")) { session.eraseArea() }.accessibilityIdentifier("rpg-editor-area-erase")
                Button(L10n.t("填充", "Fill")) { session.fillArea() }.accessibilityIdentifier("rpg-editor-area-fill")
                Button(L10n.t("复制", "Copy")) { session.copyArea() }.accessibilityIdentifier("rpg-editor-area-copy")
                Button(L10n.t("同类替换", "Replace")) { session.replaceInArea() }.accessibilityIdentifier("rpg-editor-area-replace")
                Button(L10n.t("套用形状", "Apply Shape")) { session.shapeArea() }.accessibilityIdentifier("rpg-editor-area-shape")
                Button(L10n.t("取消选区", "Deselect")) { session.clearArea() }
            }.disabled(session.area == nil)
            Button(L10n.t("粘贴到选中格", "Paste at Selection")) { if let point = session.selected { session.pastePreview(at: point) } }
                .disabled(!session.hasClipboard || session.selected == nil).accessibilityIdentifier("rpg-editor-area-paste")
        }
        .font(.caption)
    }
}

/// The unconfirmed draft: what it would do, confirm, cancel (task E5).
struct RPGDraftBar: View {
    @ObservedObject var session: RPGSession

    var body: some View {
        if let draft = session.draft {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("预览 · ", "Preview · ") + draft.payload.title).font(.caption.weight(.semibold))
                    Text(session.draftPlan?.summary ?? L10n.t("正在计算影响范围…", "Calculating affected cells…")).font(.caption2).foregroundStyle(blocked ? .orange : .secondary)
                        .accessibilityIdentifier("rpg-draft-summary")
                    if draft.truncated { Text(L10n.t("一次最多 \(RPGWorldEditing.maximumBatch) 格，超出部分未加入。", "Up to \(RPGWorldEditing.maximumBatch) cells at once; the rest was left out.")).font(.caption2).foregroundStyle(.orange) }
                    if blocked { Text(L10n.t("超出角色建造范围：切换到自由编辑，或取消后重新选择。", "Out of build range: switch to Free Edit, or cancel and select again.")).font(.caption2).foregroundStyle(.orange) }
                }
                Spacer(minLength: 4)
                Button(L10n.t("取消", "Cancel")) { session.discardDraft() }.accessibilityIdentifier("rpg-draft-cancel")
                Button(L10n.t("确认", "Confirm")) { session.confirmDraft() }.fontWeight(.semibold)
                    .disabled(blocked || session.working || (session.draftPlan?.cells.isEmpty ?? true))
                    .accessibilityIdentifier("rpg-draft-confirm")
            }
            .padding(.horizontal, 12).padding(.vertical, 8).editorSurface(radius: 16)
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
                    Text(L10n.t("格子", "Cell") + " x \(point.x) · z \(point.z)").font(.subheadline.weight(.semibold)).accessibilityIdentifier("rpg-panel-coordinate")
                    Text(materialLine(entity))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("rpg-panel-material")
                }
                Spacer()
                RPGShapeMenu(selection: entity?.outline) { session.applyOutline($0, at: point) } label: {
                    ShapeThumbnail(outline: entity?.outline, size: 20).frame(width: 32, height: 32)
                }
                .accessibilityLabel(L10n.t("格子形状", "Cell Shape")).accessibilityIdentifier("rpg-panel-shape")
                if entity != nil {
                    Button { session.eraseCell(point); onClose() } label: { Image(systemName: "eraser").frame(width: 32, height: 32) }
                        .accessibilityLabel(L10n.t("擦除方块", "Erase Block")).accessibilityIdentifier("rpg-panel-erase")
                }
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).frame(width: 32, height: 32) }
                    .accessibilityLabel(L10n.t("关闭面板", "Close Panel")).accessibilityIdentifier("rpg-panel-close")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            NavigationStack {
                RPGCellEditorView(session: session, store: store, entity: entity, point: point, initialKind: session.panelKind, onClose: onClose)
            }
            // System button look inside the panel: the world's glass capsule
            // style made 取消 / 确认 wrap in the narrow navigation bar.
            .buttonStyle(.automatic)
            // A new identity per cell resets the draft when another cell is picked.
            .id("\(point.x),\(point.z),\(entity?.mediaBindingID ?? "-"),\(session.panelKind?.rawValue ?? "-")")
        }
        // Opaque so the map and toolbars never show through the form.
        .background(Color(uiColor: .systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rpg-cell-panel")
    }

    private func materialLine(_ entity: WorldEntity?) -> String {
        let terrain: String = session.terrain(at: point)?.title ?? "—"
        var block = L10n.t("无方块", "No block")
        if let entity, let definition = BlockDefinition.find(entity.definitionID) { block = definition.name }
        return L10n.t("地形 ", "Terrain ") + terrain + " · " + block
    }
}

extension View {
    /// Editor bars: denser than the world's clear glass so labels stay
    /// readable over a busy map.
    @ViewBuilder func editorSurface(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
        }
    }
}

/// Picks a cell outline: square, the built-in templates, or a shape saved
/// in the glass shape editor.
struct RPGShapeMenu<Label: View>: View {
    let selection: ShapeOutline?
    let choose: (ShapeOutline?) -> Void
    @ViewBuilder let label: () -> Label
    @ObservedObject private var store = GlassShapeStore.shared

    init(selection: ShapeOutline?, choose: @escaping (ShapeOutline?) -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.selection = selection; self.choose = choose; self.label = label
    }

    var body: some View {
        Menu {
            Button { choose(nil) } label: { SwiftUI.Label(L10n.t("方形（默认）", "Square (default)"), systemImage: selection == nil ? "checkmark" : "square") }
            Section(L10n.t("模板", "Templates")) {
                ForEach(ShapeTemplate.allCases.filter { $0 != .square }, id: \.self) { template in
                    Button { choose(template.outline) } label: {
                        SwiftUI.Label(template.title, systemImage: selection == template.outline ? "checkmark" : template.symbol)
                    }
                }
            }
            if !store.shapes.isEmpty {
                Section(L10n.t("我的形状", "My Shapes")) {
                    ForEach(store.shapes.prefix(20)) { shape in
                        Button { choose(shape.outline) } label: {
                            SwiftUI.Label(shape.name, systemImage: selection == shape.outline ? "checkmark" : "scribble.variable")
                        }
                    }
                }
            }
        } label: { label() }
    }
}

/// A readable name for a cell outline: square, a template, or a saved shape.
@MainActor enum RPGShapeName {
    static func of(_ outline: ShapeOutline?) -> String {
        guard let outline else { return L10n.t("方形", "Square") }
        if let template = ShapeTemplate.allCases.first(where: { $0 != .square && $0.outline == outline }) { return template.title }
        if let saved = GlassShapeStore.shared.shapes.first(where: { $0.outline == outline }) { return saved.name }
        return L10n.t("曲线", "Curve")
    }
}
