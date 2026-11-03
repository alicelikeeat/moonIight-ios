import SwiftUI

/// Full-screen control center over the live world: world management on
/// the left, app pages in the middle, world functions on the right. The
/// world stays visible behind floating glass modules.
struct WorldControlCenterView: View {
    @ObservedObject var session: RPGSession
    let onClose: () -> Void
    /// Opens the map editor (task E).
    let onMapEditor: () -> Void
    let onNavigate: (AppTab) -> Void
    /// Opens the sandbox tools, optionally at a page (story, editor…).
    let onTools: (RPGEntryPage?) -> Void
    let onAppSettings: () -> Void
    /// Glass shape editor; nil before iOS 26.
    var onShapeEditor: (() -> Void)? = nil
    @AppStorage("moonlight.world.edgeSwipe") private var edgeSwipe = true
    @AppStorage(L10n.key) private var language = AppLanguage.zh.rawValue
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var worlds: [RPGRecoveryChoice] = []
    @State private var confirmCreate = false
    @State private var shown = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                // Takes the touches meant for the world while the center is open.
                Color.clear.contentShape(Rectangle()).onTapGesture { }.ignoresSafeArea()
                VStack(spacing: 12) {
                    topBar
                    if landscape {
                        HStack(alignment: .top, spacing: 12) {
                            module(0) { worldColumn }
                            module(1) { navigationColumn }
                            module(2) { functionColumn }
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 12) {
                                module(0) { worldColumn }
                                module(1) { navigationColumn }
                                module(2) { functionColumn }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("world-control-center")
        .task {
            withAnimation(reducedMotion ? nil : .easeOut(duration: 0.3)) { shown = true }
            worlds = await session.listWorlds()
        }
        .confirmationDialog(L10n.t("创建新世界？", "Create a new world?"), isPresented: $confirmCreate, titleVisibility: .visible) {
            Button(L10n.t("保存当前世界并创建", "Save Current World and Create")) { onClose(); session.createWorld() }.accessibilityIdentifier("world-create-confirm")
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        } message: { Text(L10n.t("当前世界会先保存，并保留在世界列表中。", "The current world is saved first and kept in the world list.")) }
    }

    private var topBar: some View {
        HStack {
            Label(L10n.t("世界控制中心", "World Control Center"), systemImage: "square.grid.2x2").font(.headline)
            Spacer()
            Button(L10n.t("继续世界", "Resume World")) { onClose() }.accessibilityIdentifier("world-continue")
                .padding(.horizontal, 14).frame(minHeight: 40).worldGlass(radius: 20)
            Button { onClose() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                .accessibilityLabel(L10n.t("关闭", "Close")).accessibilityIdentifier("world-control-close").worldGlass(radius: 20)
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
    }

    /// Modules enter one after another; with Reduce Motion they just appear.
    private func module<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .worldGlass(radius: 22)
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reducedMotion ? 0 : 12)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.28).delay(0.06 * Double(index)), value: shown)
    }

    private var worldColumn: some View {
        Group {
            sectionTitle(L10n.t("世界", "World"))
            Text(session.worldTitle).font(.headline).accessibilityIdentifier("world-title")
            Text("\(session.modeTitle) · \(session.perspectiveTitle)").font(.caption)
            Text(session.questSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(L10n.t("存档修订 \(session.world.revision) · 自建 \(session.world.entities.count)", "Revision \(session.world.revision) · \(session.world.entities.count) built")).font(.caption2).foregroundStyle(.secondary)
            Divider()
            sectionTitle(L10n.t("切换世界", "Switch World"))
            let others = worlds.filter { $0.id != session.world.id }
            if others.isEmpty { Text(L10n.t("暂无其他世界", "No other worlds yet")).font(.caption).foregroundStyle(.secondary) }
            ForEach(others.prefix(4)) { choice in
                row((choice.creative ? L10n.t("创作副本", "Creative Copy") : L10n.t("原世界", "Original World")) + " · Seed \(choice.seed)", symbol: "globe") {
                    onClose(); session.switchWorld(choice.id)
                }.accessibilityIdentifier("world-switch-" + choice.id)
            }
            row(L10n.t("创建世界", "Create World"), symbol: "plus") { confirmCreate = true }.accessibilityIdentifier("world-create")
        }
    }

    private var navigationColumn: some View {
        Group {
            sectionTitle("App")
            row(L10n.t("首页 · 推荐", "Home · For You"), symbol: AppTab.home.symbol) { onNavigate(.home) }.accessibilityIdentifier("world-nav-home")
            row(L10n.t("首页 · 发现", "Home · Discover"), symbol: AppTab.discover.symbol) { onNavigate(.discover) }.accessibilityIdentifier("world-nav-discover")
            row(L10n.t("拍摄", "Camera"), symbol: AppTab.camera.symbol) { onNavigate(.camera) }.accessibilityIdentifier("world-nav-camera")
            row(L10n.t("朋友圈", "Moments"), symbol: AppTab.moments.symbol) { onNavigate(.moments) }.accessibilityIdentifier("world-nav-moments")
            row(L10n.t("我", "Me"), symbol: AppTab.me.symbol) { onNavigate(.me) }.accessibilityIdentifier("world-nav-me")
        }
    }

    private var functionColumn: some View {
        Group {
            sectionTitle(L10n.t("世界功能", "World Functions"))
            row(L10n.t("地图编辑", "Map Editor"), symbol: "square.grid.3x3.square") { onMapEditor() }.accessibilityIdentifier("world-fn-map-editor")
            if let onShapeEditor {
                row(L10n.t("形状编辑器", "Shape Editor"), symbol: "scribble.variable") { onShapeEditor() }.accessibilityIdentifier("world-fn-shape-editor")
            }
            row(L10n.t("建造", "Build"), symbol: "hammer") { onTools(nil) }.accessibilityIdentifier("world-fn-build")
            row(L10n.t("剧情", "Story"), symbol: "book") { onTools(.story) }.accessibilityIdentifier("world-fn-story")
            row(L10n.t("媒体", "Media"), symbol: "photo.on.rectangle") { onTools(nil) }.accessibilityIdentifier("world-fn-media")
            row(L10n.t("世界设置", "World Settings"), symbol: "slider.horizontal.3") { onTools(nil) }.accessibilityIdentifier("world-fn-settings")
            row(L10n.t("应用设置", "App Settings"), symbol: "gearshape") { onAppSettings() }.accessibilityIdentifier("world-fn-app-settings")
            Toggle(L10n.t("左边缘滑动打开", "Open with Left-Edge Swipe"), isOn: $edgeSwipe).font(.caption).accessibilityIdentifier("world-edge-swipe")
            Picker(selection: $language) {
                ForEach(AppLanguage.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            } label: { Label(L10n.t("语言", "Language"), systemImage: "globe") }
                .pickerStyle(.menu).font(.caption).accessibilityIdentifier("world-language")
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func row(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(session.working)
    }
}

extension View {
    /// Native Liquid Glass on iOS 26+, a light material with a thin edge on
    /// iOS 16-25. The fallback is a material, not system Liquid Glass.
    func worldGlass(radius: CGFloat) -> some View {
        // V2.2: control center modules use the adaptive HUD glass (clear,
        // thicker with Increase Contrast, solid with Reduce Transparency).
        hudGlass(.light, radius: radius)
    }
}
