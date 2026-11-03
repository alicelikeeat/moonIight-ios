import SwiftUI

/// Full-screen control center over the live world: world management on
/// the left, app pages in the middle, world functions on the right. The
/// world stays visible behind floating glass modules.
struct WorldControlCenterView: View {
    @ObservedObject var session: RPGSession
    let onClose: () -> Void
    let onNavigate: (AppTab) -> Void
    /// Opens the sandbox tools, optionally at a page (story, editor…).
    let onTools: (RPGEntryPage?) -> Void
    let onAppSettings: () -> Void
    @AppStorage("moonlight.world.edgeSwipe") private var edgeSwipe = true
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
        .confirmationDialog("创建新世界？", isPresented: $confirmCreate, titleVisibility: .visible) {
            Button("保存当前世界并创建") { onClose(); session.createWorld() }.accessibilityIdentifier("world-create-confirm")
            Button("取消", role: .cancel) {}
        } message: { Text("当前世界会先保存，并保留在世界列表中。") }
    }

    private var topBar: some View {
        HStack {
            Label("世界控制中心", systemImage: "square.grid.2x2").font(.headline)
            Spacer()
            Button("继续世界") { onClose() }.accessibilityIdentifier("world-continue")
                .padding(.horizontal, 14).frame(minHeight: 40).worldGlass(radius: 20)
            Button { onClose() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }
                .accessibilityLabel("关闭").accessibilityIdentifier("world-control-close").worldGlass(radius: 20)
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
            sectionTitle("世界")
            Text(session.worldTitle).font(.headline).accessibilityIdentifier("world-title")
            Text("\(session.modeTitle) · \(session.perspectiveTitle)").font(.caption)
            Text(session.questSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text("存档修订 \(session.world.revision) · 自建 \(session.world.entities.count)").font(.caption2).foregroundStyle(.secondary)
            Divider()
            sectionTitle("切换世界")
            let others = worlds.filter { $0.id != session.world.id }
            if others.isEmpty { Text("暂无其他世界").font(.caption).foregroundStyle(.secondary) }
            ForEach(others.prefix(4)) { choice in
                row((choice.creative ? "创作副本" : "原世界") + " · Seed \(choice.seed)", symbol: "globe") {
                    onClose(); session.switchWorld(choice.id)
                }.accessibilityIdentifier("world-switch-" + choice.id)
            }
            row("创建世界", symbol: "plus") { confirmCreate = true }.accessibilityIdentifier("world-create")
        }
    }

    private var navigationColumn: some View {
        Group {
            sectionTitle("App")
            row("首页 · 推荐", symbol: AppTab.home.symbol) { onNavigate(.home) }.accessibilityIdentifier("world-nav-home")
            row("首页 · 发现", symbol: AppTab.discover.symbol) { onNavigate(.discover) }.accessibilityIdentifier("world-nav-discover")
            row("拍摄", symbol: AppTab.camera.symbol) { onNavigate(.camera) }.accessibilityIdentifier("world-nav-camera")
            row("朋友圈", symbol: AppTab.moments.symbol) { onNavigate(.moments) }.accessibilityIdentifier("world-nav-moments")
            row("我", symbol: AppTab.me.symbol) { onNavigate(.me) }.accessibilityIdentifier("world-nav-me")
        }
    }

    private var functionColumn: some View {
        Group {
            sectionTitle("世界功能")
            row("建造", symbol: "hammer") { onTools(nil) }.accessibilityIdentifier("world-fn-build")
            row("剧情", symbol: "book") { onTools(.story) }.accessibilityIdentifier("world-fn-story")
            row("媒体", symbol: "photo.on.rectangle") { onTools(nil) }.accessibilityIdentifier("world-fn-media")
            row("世界设置", symbol: "slider.horizontal.3") { onTools(nil) }.accessibilityIdentifier("world-fn-settings")
            row("应用设置", symbol: "gearshape") { onAppSettings() }.accessibilityIdentifier("world-fn-app-settings")
            Toggle("左边缘滑动打开", isOn: $edgeSwipe).font(.caption).accessibilityIdentifier("world-edge-swipe")
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
    @ViewBuilder func worldGlass(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.clear, in: shape)
        } else {
            self.background(.ultraThinMaterial.opacity(0.75), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
        }
    }
}
