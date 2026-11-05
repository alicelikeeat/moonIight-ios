import SwiftUI
import UIKit

/// Backgrounds for judging refraction.
enum GlassShapeBackground: String, CaseIterable, Sendable {
    case gradient, scenery, textList, solid, stripes
    var title: String {
        switch self {
        case .gradient: L10n.t("渐变", "Gradient")
        case .scenery: L10n.t("风景插画", "Scenery")
        case .textList: L10n.t("文字列表", "Text List")
        case .solid: L10n.t("纯色", "Solid")
        case .stripes: L10n.t("条纹", "Stripes")
        }
    }
}

/// Tint choices (empty hex: no tint).
struct GlassShapeTint: Hashable {
    let hex: String, zh: String, en: String
    static let options = [
        GlassShapeTint(hex: "", zh: "无", en: "None"), GlassShapeTint(hex: "0A84FF", zh: "蓝", en: "Blue"),
        GlassShapeTint(hex: "FF375F", zh: "粉", en: "Pink"), GlassShapeTint(hex: "FF9F0A", zh: "橙", en: "Orange"),
        GlassShapeTint(hex: "30D158", zh: "绿", en: "Green"), GlassShapeTint(hex: "BF5AF2", zh: "紫", en: "Purple"),
    ]
}

/// Editor state: the shape, selection, undo, view options and text-to-shape.
@available(iOS 26.0, *)
@MainActor @Observable final class GlassShapeEditorModel {
    enum Drag { case anchor(Int), handle(Int, ShapeHandle), canvas(CGSize) }

    var document: ShapeDocument
    private(set) var history = ShapeHistory()
    var selected: Int?
    var preview = false
    var background = GlassShapeBackground.gradient
    var showGrid = false
    var snap = false
    var dark = false
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var generating = false
    var partialPoints: [ShapePoint] = []
    var message: String?
    let store: GlassShapeStore

    init(store: GlassShapeStore) {
        self.store = store
        document = store.currentOrNew()
    }

    static let gridStep = 0.05

    var glass: Glass {
        var value: Glass = document.material == .clear ? .clear : .regular
        if let hex = document.tintHex { value = value.tint(Color(uiColor: UIColor(rpgHex: hex)).opacity(0.6)) }
        if document.interactive { value = value.interactive() }
        return value
    }

    var warnings: [String] {
        var list: [String] = []
        if document.outline.selfIntersects { list.append(L10n.t("形状自相交，玻璃折射会很乱", "The outline crosses itself; refraction will look messy")) }
        let sharp = document.outline.sharpCorners()
        if !sharp.isEmpty { list.append(L10n.t("有 \(sharp.count) 个锚点夹角过小", "\(sharp.count) anchor(s) form a very sharp corner")) }
        return list
    }

    // MARK: Changes. Each public change is one undo step.

    private func change(_ body: (inout ShapeDocument) -> Bool) {
        var next = document
        guard body(&next), next != document else { return }
        history.record(document); document = next; store.update(document)
    }
    func snapped(_ point: ShapePoint) -> ShapePoint { snap ? document.outline.snapped(point, step: Self.gridStep) : point.clamped }

    func addAnchor(at point: ShapePoint) {
        var inserted: Int?
        change { doc in inserted = doc.outline.insertAnchor(at: snapped(point)); return inserted != nil }
        if let inserted { selected = inserted } else if document.outline.anchors.count >= ShapeOutline.maximumAnchors {
            message = L10n.t("最多 \(ShapeOutline.maximumAnchors) 个锚点", "At most \(ShapeOutline.maximumAnchors) anchors")
        }
    }
    func removeAnchor(_ index: Int) {
        guard document.outline.anchors.count > ShapeOutline.minimumAnchors else { message = L10n.t("至少保留 3 个锚点", "Keep at least 3 anchors"); return }
        change { $0.outline.removeAnchor(index) }
        selected = nil
    }
    func toggleSmooth(_ index: Int) { change { $0.outline.toggleSmooth(index); return true }; selected = index }
    func apply(_ template: ShapeTemplate) { change { $0.outline = template.outline; return true }; selected = nil }
    func setMaterial(_ material: GlassShapeMaterial) { change { $0.material = material; return true } }
    func setTint(_ hex: String?) { change { $0.tintHex = hex; return true } }
    func setInteractive(_ on: Bool) { change { $0.interactive = on; return true } }

    // Drags record one undo step when they start, then move freely.
    func beginDrag() { history.record(document) }
    func dragAnchor(_ index: Int, to point: ShapePoint) { _ = document.outline.moveAnchor(index, to: snapped(point)) }
    func dragHandle(_ index: Int, _ handle: ShapeHandle, to point: ShapePoint) { _ = document.outline.moveHandle(index, handle, to: snapped(point)) }
    func endDrag() { store.update(document) }

    func undo() { if let previous = history.undo(document) { document = previous; store.update(document); selected = nil } }
    func redo() { if let next = history.redo(document) { document = next; store.update(document); selected = nil } }

    func open(_ id: String) {
        guard let shape = store.shapes.first(where: { $0.id == id }) else { return }
        store.select(id); document = shape; history.clear(); selected = nil
    }
    func newShape() {
        let shape = ShapeDocument(name: L10n.t("形状 \(store.shapes.count + 1)", "Shape \(store.shapes.count + 1)"), outline: ShapeTemplate.circle.outline)
        store.update(shape); document = shape; history.clear(); selected = nil
    }

    /// Text to shape: anchors appear as they stream in; the result is one
    /// undo step.
    func generate(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !generating else { return }
        generating = true; partialPoints = []; message = nil; preview = false
        Task { [weak self] in
            let result = await GlassShapeAI.generate(text) { points in self?.partialPoints = points }
            guard let self else { return }
            self.generating = false; self.partialPoints = []
            switch result {
            case .success(let outline):
                self.change { $0.outline = outline; return true }; self.selected = nil
                self.message = L10n.t("已生成，可继续手动微调；不满意可撤销。", "Generated. Fine-tune by hand, or undo.")
            case .failure(let failure):
                self.message = failure.message
            }
        }
    }
}

/// The glass shape editor (iOS 26+). Entry point for the sandbox; pass
/// `onApply` to offer "use on cells".
@available(iOS 26.0, *)
struct GlassShapeEditorView: View {
    var onApply: ((ShapeOutline) -> Void)?
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = GlassShapeEditorModel(store: .shared)
    @State private var library = false
    @State private var asking = false
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            ZStack {
                GlassShapeBackdrop(kind: model.background).ignoresSafeArea()
                GlassShapeCanvas(model: model)
                VStack(spacing: 6) {
                    if !model.preview { ForEach(model.warnings, id: \.self) { banner($0, symbol: "exclamationmark.triangle.fill", tint: .orange) } }
                    if let message = model.message { banner(message, symbol: "info.circle.fill", tint: .accentColor).onTapGesture { model.message = nil } }
                    if model.generating { banner(L10n.t("正在生成…", "Generating…"), symbol: "sparkles", tint: .purple) }
                    Spacer()
                    if !model.preview { Text(hint).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6).moonLiquidSurface(.capsule) }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                .allowsHitTesting(model.message != nil)
            }
            .environment(\.colorScheme, model.dark ? .dark : .light)
            .navigationTitle(model.document.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { topBar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(isPresented: $library) { GlassShapeLibraryView(model: model) }
            .sheet(isPresented: $asking) { promptSheet.presentationDetents([.height(300)]) }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.store.flush() } }
        .onDisappear { model.store.flush() }
        .accessibilityIdentifier("glass-shape-editor")
    }

    private var hint: String {
        if model.selected != nil { return L10n.t("拖动锚点或控制柄 · 双击切换平滑/尖角 · 长按删除", "Drag anchors or handles · double-tap: smooth/corner · long-press: delete") }
        return L10n.t("轻点空白处添加锚点 · 拖动空白处平移 · 双指缩放", "Tap empty space to add an anchor · drag to pan · pinch to zoom")
    }

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .moonLiquidSurface(.capsule)
    }

    private func close() { model.store.flush(); if let onClose { onClose() } else { dismiss() } }

    @ToolbarContentBuilder private var topBar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.t("完成", "Done")) { close() }.accessibilityIdentifier("glass-shape-close")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.history.canUndo).accessibilityLabel(L10n.t("撤销", "Undo")).accessibilityIdentifier("glass-shape-undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.history.canRedo).accessibilityLabel(L10n.t("重做", "Redo")).accessibilityIdentifier("glass-shape-redo")
            if let onApply {
                Button(L10n.t("用于格子", "Use on Cells")) { model.store.flush(); onApply(model.document.outline) }
                    .fontWeight(.semibold).disabled(!model.document.outline.valid).accessibilityIdentifier("glass-shape-apply")
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            barButton(model.preview ? "pencil.and.outline" : "eye", model.preview ? L10n.t("编辑", "Edit") : L10n.t("预览", "Preview"), id: "glass-shape-mode") {
                model.preview.toggle(); model.selected = nil
            }
            Menu {
                Picker(L10n.t("背景", "Background"), selection: $model.background) {
                    ForEach(GlassShapeBackground.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(L10n.t("深色外观", "Dark Appearance"), isOn: $model.dark)
            } label: { barLabel("photo.on.rectangle", L10n.t("背景", "Background")) }
                .accessibilityIdentifier("glass-shape-background")
            Menu {
                Picker(L10n.t("材质", "Material"), selection: Binding(get: { model.document.material }, set: { model.setMaterial($0) })) {
                    ForEach(GlassShapeMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker(L10n.t("着色", "Tint"), selection: Binding(get: { model.document.tintHex ?? "" }, set: { model.setTint($0.isEmpty ? nil : $0) })) {
                    ForEach(GlassShapeTint.options, id: \.self) { option in Text(L10n.t(option.zh, option.en)).tag(option.hex) }
                }
                Toggle(L10n.t("可交互 (.interactive)", "Interactive"), isOn: Binding(get: { model.document.interactive }, set: { model.setInteractive($0) }))
            } label: { barLabel("drop.halffull", L10n.t("材质", "Material")) }
                .accessibilityIdentifier("glass-shape-material")
            Menu {
                Section(L10n.t("模板", "Templates")) {
                    ForEach(ShapeTemplate.allCases, id: \.self) { template in
                        Button { model.apply(template) } label: { Label(template.title, systemImage: template.symbol) }
                    }
                }
                Toggle(L10n.t("显示网格", "Show Grid"), isOn: $model.showGrid)
                Toggle(L10n.t("吸附网格", "Snap to Grid"), isOn: $model.snap)
                Button(L10n.t("重置视图", "Reset View")) { model.zoom = 1; model.pan = .zero }
            } label: { barLabel("square.on.circle", L10n.t("形状", "Shape")) }
                .accessibilityIdentifier("glass-shape-templates")
            if GlassShapeAI.isAvailable {
                barButton("sparkles", L10n.t("文字生成", "Describe"), id: "glass-shape-ai") { asking = true }
                    .disabled(model.generating)
            }
            Menu {
                Button { UIPasteboard.general.string = ShapeCodeExporter.swift(model.document); model.message = L10n.t("Swift 代码已复制", "Swift code copied") } label: { Label(L10n.t("复制 Swift 代码", "Copy Swift Code"), systemImage: "swift") }
                ShareLink(item: ShapeCodeExporter.swift(model.document), preview: SharePreview(ShapeCodeExporter.typeName(model.document.name) + ".swift")) {
                    Label(L10n.t("分享 Swift 代码", "Share Swift Code"), systemImage: "square.and.arrow.up")
                }
                Button { UIPasteboard.general.string = ShapeCodeExporter.svg(model.document); model.message = L10n.t("SVG 已复制", "SVG copied") } label: { Label(L10n.t("复制 SVG", "Copy SVG"), systemImage: "doc.on.doc") }
                ShareLink(item: ShapeCodeExporter.svg(model.document), preview: SharePreview(model.document.name + ".svg")) {
                    Label(L10n.t("分享 SVG", "Share SVG"), systemImage: "square.and.arrow.up.on.square")
                }
            } label: { barLabel("chevron.left.forwardslash.chevron.right", L10n.t("导出", "Export")) }
                .accessibilityIdentifier("glass-shape-export")
            barButton("square.grid.2x2", L10n.t("作品库", "Library"), id: "glass-shape-library") { library = true }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func barLabel(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
            Text(title).font(.system(size: 9)).lineLimit(1)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    private func barButton(_ symbol: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(symbol, title) }.buttonStyle(.moonJelly).accessibilityIdentifier(id)
    }

    private var promptSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L10n.t("例如：圆润的水滴形，底部略尖", "e.g. a rounded droplet, slightly pointed at the bottom"), text: $prompt, axis: .vertical)
                    .lineLimit(2...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("glass-shape-prompt")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(examples, id: \.self) { example in
                            Button(example) { prompt = example }.buttonStyle(.moonLiquid).font(.caption)
                        }
                    }
                }
                Text(L10n.t("在设备上用 Apple 智能生成，不上传数据。结果可继续手动调整，也可撤销。", "Generated on device with Apple Intelligence; nothing is uploaded. Adjust the result by hand or undo it."))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle(L10n.t("文字生成形状", "Describe a Shape")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("取消", "Cancel")) { asking = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("生成", "Generate")) { asking = false; model.generate(prompt) }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("glass-shape-generate")
                }
            }
        }
    }

    private var examples: [String] {
        L10n.isEnglish ? ["rounded droplet", "leaf", "wavy blob", "capsule", "five-point star", "cloud"]
            : ["圆润的水滴形", "叶子", "波浪形的云朵", "胶囊", "五角星", "爱心"]
    }
}

/// The shape on its glass, grid, handles and the touch handling.
@available(iOS 26.0, *)
private struct GlassShapeCanvas: View {
    @Bindable var model: GlassShapeEditorModel
    @State private var drag: GlassShapeEditorModel.Drag?
    @State private var moved = false
    @State private var pressTask: Task<Void, Never>?
    @State private var longPressed = false
    @State private var lastTap: (index: Int, time: Date)?
    @State private var zoomStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let rect = frame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                if model.showGrid && !model.preview { GridLines(rect: rect, step: GlassShapeEditorModel.gridStep) }
                Color.clear.frame(width: rect.width, height: rect.height)
                    .glassEffect(model.glass, in: EditableShape(outline: model.document.outline))
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityElement().accessibilityIdentifier("glass-shape-preview")
                    .accessibilityValue("anchors=\(model.document.outline.anchors.count)")
                if !model.preview {
                    HandleOverlay(outline: model.document.outline, selected: model.selected, rect: rect).allowsHitTesting(false)
                }
                ForEach(Array(model.partialPoints.enumerated()), id: \.offset) { _, point in
                    Circle().fill(Color.purple).frame(width: 10, height: 10).position(point.cgPoint(in: rect))
                }
            }
            .contentShape(Rectangle())
            .gesture(touches(rect: rect))
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                let start = zoomStart ?? model.zoom; zoomStart = start
                model.zoom = min(3, max(0.5, start * value.magnification))
            }.onEnded { _ in zoomStart = nil })
        }
    }

    private func frame(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height) * 0.78 * model.zoom
        return CGRect(x: (size.width - side) / 2 + model.pan.width, y: (size.height - side) / 2 + model.pan.height, width: side, height: side)
    }
    private func unit(_ location: CGPoint, _ rect: CGRect) -> ShapePoint {
        ShapePoint(Double((location.x - rect.minX) / rect.width), Double((location.y - rect.minY) / rect.height))
    }

    private func touches(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if drag == nil { begin(at: value.startLocation, rect: rect) }
                let distance = hypot(value.translation.width, value.translation.height)
                if !moved && distance > 6 {
                    moved = true; pressTask?.cancel()
                    if case .anchor = drag { model.beginDrag() }
                    if case .handle = drag { model.beginDrag() }
                }
                guard moved, !longPressed, !model.preview || isCanvas else { return }
                switch drag {
                case .anchor(let index): model.dragAnchor(index, to: unit(value.location, rect))
                case .handle(let index, let handle): model.dragHandle(index, handle, to: unit(value.location, rect))
                case .canvas(let start): model.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                case nil: break
                }
            }
            .onEnded { value in
                pressTask?.cancel()
                defer { drag = nil; moved = false; longPressed = false }
                if longPressed { return }
                if moved {
                    if case .canvas = drag {} else { model.endDrag() }
                    return
                }
                guard !model.preview else { return }
                switch drag {
                case .anchor(let index):
                    if let last = lastTap, last.index == index, Date().timeIntervalSince(last.time) < 0.35 {
                        model.toggleSmooth(index); lastTap = nil
                    } else { model.selected = index; lastTap = (index, Date()) }
                case .canvas:
                    let point = unit(value.location, rect)
                    if point.inUnit { model.addAnchor(at: point) } else { model.selected = nil }
                default: break
                }
            }
    }

    private var isCanvas: Bool { if case .canvas = drag { return true }; return false }

    private func begin(at location: CGPoint, rect: CGRect) {
        moved = false; longPressed = false
        let point = unit(location, rect), radius = Double(24 / rect.width)
        let outline = model.document.outline
        if !model.preview, let selected = model.selected, let handle = outline.handle(of: selected, near: point, radius: radius) {
            drag = .handle(selected, handle)
        } else if !model.preview, let index = outline.anchor(near: point, radius: radius) {
            drag = .anchor(index)
            // Long press on an anchor deletes it.
            pressTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard !Task.isCancelled, !moved, case .anchor(let held)? = drag, held == index else { return }
                longPressed = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                model.removeAnchor(index)
            }
        } else {
            drag = .canvas(model.pan)
        }
    }
}

/// Anchors (circle: smooth, square: corner), the selected anchor's handles
/// and a dashed guide along the outline. Hidden in preview mode.
private struct HandleOverlay: View {
    let outline: ShapeOutline
    let selected: Int?
    let rect: CGRect

    var body: some View {
        Canvas { context, _ in
            context.stroke(Path(outline.cgPath(in: rect)), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if let selected, outline.anchors.indices.contains(selected) {
                let anchor = outline.anchors[selected], center = anchor.point.cgPoint(in: rect)
                for handle in [anchor.handleIn, anchor.handleOut] where handle.distance(to: anchor.point) > 1e-6 {
                    let end = handle.cgPoint(in: rect)
                    var line = Path(); line.move(to: center); line.addLine(to: end)
                    context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
                    let knob = Path(ellipseIn: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12))
                    context.fill(knob, with: .color(.white)); context.stroke(knob, with: .color(.accentColor), lineWidth: 2)
                }
            }
            for (index, anchor) in outline.anchors.enumerated() {
                let c = anchor.point.cgPoint(in: rect), size: CGFloat = index == selected ? 16 : 12
                let box = CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
                let mark = anchor.smooth ? Path(ellipseIn: box) : Path(box)
                context.fill(mark, with: .color(index == selected ? .accentColor : .white))
                context.stroke(mark, with: .color(index == selected ? .white : .black.opacity(0.6)), lineWidth: 1.5)
            }
        }
        .accessibilityElement().accessibilityIdentifier("glass-shape-handles")
        .accessibilityValue(selected.map { "selected=\($0)" } ?? "none")
    }
}

private struct GridLines: View {
    let rect: CGRect
    let step: Double
    var body: some View {
        Canvas { context, _ in
            var path = Path()
            let count = Int((1 / step).rounded())
            for i in 0...count {
                let t = CGFloat(Double(i) * step)
                path.move(to: CGPoint(x: rect.minX + t * rect.width, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX + t * rect.width, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + t * rect.height)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + t * rect.height))
            }
            context.stroke(path, with: .color(.primary.opacity(0.18)), lineWidth: 0.5)
            context.stroke(Path(rect), with: .color(.primary.opacity(0.35)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Backgrounds behind the glass. "Scenery" is drawn, not a photo.
struct GlassShapeBackdrop: View {
    let kind: GlassShapeBackground
    var body: some View {
        switch kind {
        case .gradient:
            LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .scenery:
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.35, green: 0.62, blue: 0.95), Color(red: 0.98, green: 0.78, blue: 0.55)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color.yellow.opacity(0.9)).frame(width: 120).offset(x: 80, y: -380)
                Ellipse().fill(Color(red: 0.2, green: 0.45, blue: 0.3)).frame(width: 700, height: 360).offset(x: -160, y: 120)
                Ellipse().fill(Color(red: 0.15, green: 0.35, blue: 0.25)).frame(width: 640, height: 300).offset(x: 200, y: 140)
            }
        case .textList:
            ZStack {
                Color(uiColor: .systemBackground)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<40, id: \.self) { index in
                        Text(L10n.t("列表第 \(index + 1) 行 · 玻璃会折射下方的文字", "Row \(index + 1) · glass refracts the text below"))
                            .font(index.isMultiple(of: 5) ? .headline : .body).foregroundStyle(index.isMultiple(of: 3) ? Color.accentColor : .primary)
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        case .solid:
            Color(red: 0.12, green: 0.5, blue: 0.55)
        case .stripes:
            Canvas { context, size in
                let width: CGFloat = 22
                var x: CGFloat = -size.height
                var index = 0
                while x < size.width {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: 0)); stripe.addLine(to: CGPoint(x: x + width, y: 0))
                    stripe.addLine(to: CGPoint(x: x + width + size.height, y: size.height)); stripe.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    context.fill(stripe, with: .color(index.isMultiple(of: 2) ? .black : .white))
                    x += width; index += 1
                }
            }
        }
    }
}

/// Saved shapes: open, rename, duplicate, delete, new.
@available(iOS 26.0, *)
private struct GlassShapeLibraryView: View {
    @Bindable var model: GlassShapeEditorModel
    @ObservedObject private var store = GlassShapeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: ShapeDocument?
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List { Group {
                ForEach(store.shapes) { shape in
                    Button { model.open(shape.id); dismiss() } label: {
                        HStack {
                            ShapeThumbnail(outline: shape.outline, size: 28)
                            Text(shape.name).lineLimit(1)
                            Spacer()
                            if shape.id == model.document.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button(role: .destructive) { store.remove(shape.id); if shape.id == model.document.id { model.open(store.library.current?.id ?? "") } } label: { Label(L10n.t("删除", "Delete"), systemImage: "trash") }
                            .disabled(store.shapes.count <= 1)
                        Button { if let copy = store.duplicate(shape.id) { model.open(copy.id) } } label: { Label(L10n.t("复制", "Duplicate"), systemImage: "plus.square.on.square") }
                            .tint(.blue)
                        Button { renaming = shape; name = shape.name } label: { Label(L10n.t("重命名", "Rename"), systemImage: "pencil") }
                            .tint(.orange)
                    }
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }.moonLiquidList()
            .navigationTitle(L10n.t("作品库", "Library")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("完成", "Done")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.newShape(); dismiss() } label: { Image(systemName: "plus") }.accessibilityLabel(L10n.t("新建形状", "New Shape"))
                }
            }
            .alert(L10n.t("重命名", "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L10n.t("名称", "Name"), text: $name)
                Button(L10n.t("取消", "Cancel"), role: .cancel) { renaming = nil }
                Button(L10n.t("保存", "Save")) {
                    if let shape = renaming {
                        store.rename(shape.id, to: name)
                        if shape.id == model.document.id, let updated = store.shapes.first(where: { $0.id == shape.id }) { model.document = updated }
                    }
                    renaming = nil
                }
            }
        }
    }
}
