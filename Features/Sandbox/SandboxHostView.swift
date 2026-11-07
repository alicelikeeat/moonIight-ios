import SwiftUI

/// A page inside the sandbox that search or a shortcut can open directly.
enum RPGEntryPage: String, Hashable { case world, story, editor, diagnostics }

extension AppCommand {
    var rpgPage: RPGEntryPage? { switch self { case .rpg: .world; case .rpgStory: .story; case .rpgEditor: .editor; case .rpgDiagnostics: .diagnostics; default: nil } }
}

/// v1.88: the sandbox is the 3D world. This view only opens the save
/// (loading, choosing between recovered copies, a failed load) and runs the
/// session's lifecycle; everything else is in the 3D world. The 3D screen
/// is rebuilt when another world is opened.
struct SandboxHostView: View {
    @ObservedObject var session: RPGSession
    /// Leaves the sandbox for the previous page (after saving).
    var onExit: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var prologue: WorldPrologue?
    /// A page requested from outside (search), opened once the world is ready.
    @State private var page: RPGEntryPage?

    var body: some View {
        ZStack {
            if session.ready {
                Glass3DScreen(session: session, startInDesign: designAtLaunch, page: $page) {
                    Task { if await session.saveBeforeExit() { onExit() } }
                }
                .id(session.world.id)
            } else {
                opening
            }
            if let prologue { WorldPrologueView(prologue: prologue) { self.prologue = nil } }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            session.attachMediaStore(model.mediaStore); session.setReducedMotion(reducedMotion); session.activate()
            if let requested = WorldHost.shared.pendingPage { WorldHost.shared.pendingPage = nil; page = requested == .world ? nil : requested }
            // The widget's 3D link needs nothing more: the sandbox is the 3D world.
            WorldHost.shared.pendingGlassWorld = false
            showPrologueIfNeeded()
        }
        .onDisappear { session.pause() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.pause() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.activate() }
        .onReceive(NotificationCenter.default.publisher(for: WorldHost.openGlassWorldNotification)) { _ in
            WorldHost.shared.pendingGlassWorld = false; prologue = nil
        }
        .onChange(of: session.ready) { _, ready in if ready { showPrologueIfNeeded() } }
        .onChange(of: session.world.id) { _, _ in showPrologueIfNeeded() }
        .onChange(of: reducedMotion) { _, on in session.setReducedMotion(on) }
    }

    /// Once per app launch the 3D world can open in design mode (setting in
    /// the ⋯ panel). Read once per screen, not on every redraw.
    private var designAtLaunch: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--scroll-ui-tests") || arguments.contains("--rpg-ui-tests") { return false }
        #endif
        guard Glass3DLaunch.shouldOpen else { return false }
        Glass3DLaunch.opened = true
        return true
    }

    @ViewBuilder private var opening: some View {
        if !session.recoveryChoices.isEmpty {
            ScrollView {
                VStack(spacing: 12) {
                    Text(L10n.t("选择保留的世界", "Choose a Saved World")).font(.headline)
                    ForEach(session.recoveryChoices) { choice in
                        Button((choice.creative ? L10n.t("创作副本", "Creative Copy") : L10n.t("原世界", "Original World")) + " · Seed \(choice.seed) · " + L10n.t("修订", "Revision") + " \(choice.revision)") {
                            session.recoverWorld(choice.id)
                        }
                        .accessibilityIdentifier("rpg-recover-" + choice.id)
                    }
                }
                .padding()
            }
            .buttonStyle(MoonGlassButtonStyle())
        } else if let error = session.loadError {
            // No blank screen: explain and offer a way forward. Creating a
            // world never deletes the unreadable one.
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(L10n.t("世界无法打开", "Can't open the world")).font(.headline).accessibilityIdentifier("world-load-failed")
                Text(error).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.t("重试", "Retry")) { session.loadWorld() }.accessibilityIdentifier("world-load-retry")
                    Button(L10n.t("创建新世界", "Create New World")) { session.createWorld() }.accessibilityIdentifier("world-load-create")
                }
                Button(L10n.t("返回", "Back")) { onExit() }.accessibilityIdentifier("world-load-back")
                Text(L10n.t("原存档文件会保留，不会被覆盖。", "The original save file is kept and never overwritten.")).font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(MoonGlassButtonStyle())
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
        } else {
            ProgressView(L10n.t("正在打开最近的世界…", "Opening your latest world…"))
                .tint(.white).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("world-loading")
        }
    }

    private func showPrologueIfNeeded() {
        guard session.ready, prologue == nil, WorldHost.shared.needsPrologue(session.world.id) else { return }
        WorldHost.shared.markPrologue(session.world.id)
        #if DEBUG
        // UI tests act on the world straight away; only opted-in tests see the prologue.
        let arguments = ProcessInfo.processInfo.arguments
        if (arguments.contains("--scroll-ui-tests") || arguments.contains("--rpg-ui-tests")) && !arguments.contains("--prologue-ui-tests") { return }
        #endif
        prologue = WorldPrologue(title: session.worldTitle, quest: session.questSummary, mode: session.modeTitle, perspective: session.perspectiveTitle)
    }
}

/// Worlds kept on disk: switch, create, creative copy, back to the original.
struct SandboxWorldsView: View {
    @ObservedObject var session: RPGSession
    @Environment(\.dismiss) private var dismiss
    @State private var worlds: [RPGRecoveryChoice] = []
    @State private var confirmCreate = false

    var body: some View {
        Form { Group {
            Section(L10n.t("当前世界", "This World")) {
                Text(session.worldTitle).font(.headline).accessibilityIdentifier("world-title")
                Text(session.questSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(L10n.t("存档修订 \(session.world.revision)", "Revision \(session.world.revision)")).font(.caption2).foregroundStyle(.secondary)
                Button(L10n.t("保存世界", "Save World")) { session.save() }.accessibilityIdentifier("rpg-save")
            }
            Section(L10n.t("切换世界", "Switch World")) {
                let others = worlds.filter { $0.id != session.world.id }
                if others.isEmpty { Text(L10n.t("暂无其他世界", "No other worlds yet")).font(.caption).foregroundStyle(.secondary) }
                ForEach(others) { choice in
                    Button((choice.creative ? L10n.t("创作副本", "Creative Copy") : L10n.t("原世界", "Original World")) + " · Seed \(choice.seed)") {
                        dismiss(); session.switchWorld(choice.id)
                    }
                    .accessibilityIdentifier("world-switch-" + choice.id)
                }
                Button(L10n.t("创建世界", "Create World")) { confirmCreate = true }.accessibilityIdentifier("world-create")
            }
            Section {
                Button(L10n.t("创建独立创作副本", "Create Creative Copy")) { dismiss(); session.creativeCopy() }.accessibilityIdentifier("rpg-creative-copy")
                if session.world.parentWorldID != nil {
                    Button(L10n.t("返回原世界", "Back to Original World")) { dismiss(); session.returnToOriginal() }.accessibilityIdentifier("rpg-return-original")
                }
            } header: { Text(L10n.t("存档与保护", "Saves & Protection")) } footer: {
                Text(L10n.t("官方剧情地点受保护；创作副本是一份独立的世界，可以随意修改，原世界不受影响。", "Official story places are protected; a creative copy is a separate world you can change freely without touching the original."))
            }
        }.listRowBackground(MoonLiquidRowBackground()) }
        .moonLiquidList()
        .disabled(!session.ready || session.working)
        .navigationTitle(L10n.t("世界与存档", "Worlds & Saves"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() }.accessibilityIdentifier("sandbox-worlds-done") } }
        .confirmationDialog(L10n.t("创建新世界？", "Create a new world?"), isPresented: $confirmCreate, titleVisibility: .visible) {
            Button(L10n.t("保存当前世界并创建", "Save Current World and Create")) { dismiss(); session.createWorld() }.accessibilityIdentifier("world-create-confirm")
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        }
        .task { worlds = await session.listWorlds() }
    }
}
