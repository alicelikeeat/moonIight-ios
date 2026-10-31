import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum MoonStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let accent = Color(red: 0.48, green: 0.45, blue: 0.30)
    static let muted = Color.secondary
    static let cardRadius: CGFloat = 24
}

// Keep the generator alive between touch-down and recognition. Creating a
// generator at the instant a long press begins is unreliable on device: the
// Taptic Engine may not have time to prepare before the menu animation starts.
@MainActor
private final class LongPressHapticFeedback {
    static let shared = LongPressHapticFeedback()
    private let generator = UIImpactFeedbackGenerator(style: .medium)
    private var lastImpact = Date.distantPast

    private init() {}

    func prepare() {
        generator.prepare()
    }

    func menuOpened() {
        let now = Date()
        // A card and its enclosing global observer can recognize the same
        // stationary hold. Coalesce that edge case into one deliberate tap.
        guard now.timeIntervalSince(lastImpact) > 0.18 else { return }
        generator.impactOccurred(intensity: 0.82)
        lastImpact = now
        generator.prepare()
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var backgroundStore: BackgroundStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedMedia: PhotosPickerItem?
    @State private var selectedImage: Image?
    @State private var activeSheet: RootSheet?
    @State private var activePlayer: MediaEntry?
    @State private var discoveryQuery = ""
    @State private var discoverySourcesPresented = false
    @ObservedObject private var interactions = InteractionPreferences.shared
    @State private var captureRequest: CameraRequest?
    @State private var rootImporter = false
    @State private var rootNotice: String?
    @State private var reelsRequest: ReelsRequest?
    @State private var deleteCoverConfirmation = false
    @State private var bottomRefreshing = false
    @State private var bottomRefreshCount = 0
    @State private var bottomFeedTab: AppTab?
    @State private var assistantLaunch: AssistantLaunch?
    @State private var assistantFocused = false
    @AppStorage("moonlight.navigation.hideDelay") private var navigationHideDelay = 5.0
    @AppStorage("moonlight.blindMode") private var blindMode = false
    @State private var navigationVisible = true
    @State private var navigationHideTask: Task<Void, Never>?
    @State private var blindExitVisible = false
    @AppStorage("moonlight.button.tint") private var buttonTint = "moon"
    @AppStorage("moonlight.button.tint.red") private var customTintRed = 0.55
    @AppStorage("moonlight.button.tint.green") private var customTintGreen = 0.50
    @AppStorage("moonlight.button.tint.blue") private var customTintBlue = 0.27

    private var isGestureUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests")
    }

    // UI tests launch in a fresh process where @AppStorage and the shared
    // preferences object can be initialized in either order. An environment
    // marker is deterministic across the XCTest/app process boundary, while
    // remaining unreachable from normal App Store launches.
    private var activeButtonTint: Color {
        switch buttonTint {
        case "blue": return .blue
        case "pink": return .pink
        case "mint": return .mint
        case "orange": return .orange
        case "custom": return Color(red: customTintRed, green: customTintGreen, blue: customTintBlue)
        default: return MoonStyle.accent
        }
    }

    private var effectiveNavigationMode: BottomNavigationMode {
        let process = ProcessInfo.processInfo
        if process.environment["MOONLIGHT_ASSISTANT_DOCK_UI_TESTS"] == "1"
            || process.arguments.contains("--assistant-dock-ui-tests") {
            return .assistant
        }
        return interactions.navigationMode
    }

    var body: some View {
        ZStack {
            PageBackground(target: .page(for: model.selectedTab))
                .ignoresSafeArea()
            ZStack(alignment: .bottom) {
                Group {
                    switch model.selectedTab {
                    case .home: refreshable(.home) { HomeView(onSelect: { activePlayer = $0 }) }
                    case .discover:
                        refreshable(.discover) {
                            DiscoverView(query: $discoveryQuery, onSelect: { activePlayer = $0 }, onSources: {
                                model.activeLongPressMenu = nil
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) { discoverySourcesPresented = true }
                            })
                        }
                        .overlay {
                            if discoverySourcesPresented {
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture {
                                            withAnimation { discoverySourcesPresented = false }
                                        }
                                        DiscoverySourcePanel(query: $discoveryQuery, onClose: {
                                            withAnimation { discoverySourcesPresented = false }
                                        })
                                        .frame(width: min(380, geometry.size.width * 0.86), height: geometry.size.height)
                                        .shadow(color: .black.opacity(0.12), radius: 24, x: 6)
                                        .transition(.move(edge: .leading))
                                    }
                                }
                            }
                        }
                    case .camera: CameraView()
                    case .moments: MomentsView(onSelect: { activePlayer = $0 }, onCompose: { activeSheet = .composer(nil) })
                    case .me: MeView(selectedImage: selectedImage, selection: $selectedMedia, onSelect: { activePlayer = $0 })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(blindMode ? 0 : 1)
                .allowsHitTesting(!blindMode)
                .accessibilityHidden(blindMode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "moonlight-root")
        .overlay(alignment: .topTrailing) {
            if blindMode {
                Group {
                    if blindExitVisible {
                        Button("退出盲盒") {
                            withAnimation(.easeOut(duration: 0.22)) {
                                blindMode = false
                                blindExitVisible = false
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 13).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35)))
                        .buttonStyle(.plain)
                        .accessibilityLabel("退出盲盒")
                        .accessibilityIdentifier("blind-mode-exit-button")
                    } else {
                        Color.clear.frame(width: 86, height: 86)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 3) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { blindExitVisible = true }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .accessibilityLabel("显示退出盲盒")
                            .accessibilityIdentifier("blind-mode-exit-trigger")
                    }
                }
                .padding(.top, 8).padding(.trailing, 8)
            }
        }
        .onChange(of: model.selectedTab) { _ in
            discoverySourcesPresented = false
            revealNavigation()
        }
        .onChange(of: blindMode) { enabled in
            blindExitVisible = false
            if enabled {
                activeSheet = nil
                activePlayer = nil
                discoverySourcesPresented = false
                model.activeLongPressMenu = nil
                navigationHideTask?.cancel()
                navigationVisible = false
            } else {
                revealNavigation()
            }
        }
        .onChange(of: navigationHideDelay) { _ in scheduleNavigationHide() }
        .task { scheduleNavigationHide() }
        .onChange(of: model.command) { request in if let request { route(request.action, context: request.context) } }
        // Custom controls opt into one glass surface explicitly. A global
        // button style would wrap circular/panel controls a second time.
        // Full-blind mode hides the page layer itself. Search and the explicit
        // exit control remain readable when they are intentionally revealed.
        .buttonStyle(MoonInteractiveButtonStyle(blind: false))
        .tint(activeButtonTint)
        .overlay {
            GeometryReader { geometry in
                if let menu = model.activeLongPressMenu {
                    LongPressRingOverlay(
                        menu: menu,
                        actions: interactions.actions("media").map(RingAction.command),
                        style: model.longPressStyle,
                        selectionMode: model.longPressSelectionMode,
                        onAction: { action in
                            if let mediaAction = action.mediaAction, let entry = menu.entry { performQuickAction(mediaAction, for: entry) }
                            else if case .command(let command) = action { model.activeLongPressMenu = nil; model.send(command, context: "media") }
                        },
                        onMore: {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            model.activeLongPressMenu = nil
                            if let entry = menu.entry {
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    activeSheet = .quickActions(entry)
                                }
                            }
                        },
                        onDismiss: { model.activeLongPressMenu = nil }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: model.activeLongPressMenu != nil)
        }
        .universalLongPress(target: .page(for: model.selectedTab))
        .overlay(alignment: .bottom) {
            tabBar.zIndex(100)
                .opacity(navigationVisible && !blindMode ? 1 : 0)
                .offset(y: navigationVisible ? 0 : 28)
                .allowsHitTesting(navigationVisible && !blindMode)
                .animation(.easeOut(duration: 0.28), value: navigationVisible)
        }
        // The visible circles are deliberately decorative so their glass can
        // stay lightweight. This final transparent layer owns the real hit
        // targets and sits above the long-press scrim in every state.
        .overlay(alignment: .bottom) {
            priorityNavigationLayer.zIndex(1_000)
                .opacity(navigationVisible && !blindMode ? 1 : 0)
                .allowsHitTesting(navigationVisible && !blindMode)
                .animation(.easeOut(duration: 0.28), value: navigationVisible)
        }
        // Observe taps without covering the feed with an invisible hit target.
        .background {
            PageTapObserver {
                NotificationCenter.default.post(name: .init("moonlight.assistantDockDismiss"), object: nil)
                if !navigationVisible { revealNavigation() }
            }.allowsHitTesting(false)
        }
        .edgeToEdgeScrolling()
        .photosPicker(isPresented: $rootImporter, selection: $selectedMedia, matching: .any(of: [.images, .videos]))
        .alert("提示", isPresented: Binding(get: { rootNotice != nil }, set: { if !$0 { rootNotice = nil } })) {
            Button("好", role: .cancel) { rootNotice = nil }
        } message: { Text(rootNotice ?? "") }
        .confirmationDialog("删除朋友圈横幅？", isPresented: $deleteCoverConfirmation, titleVisibility: .visible) {
            Button("删除横幅", role: .destructive) {
                backgroundStore.reset(.cover)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("只移除当前横幅设置，媒体文件仍保留在背景库中。")
        }
        .fullScreenCover(item: $captureRequest) { request in
            CameraCaptureView(captureVideo: request.video, onCapture: { image in
                if let data = image.jpegData(compressionQuality: 0.92) { model.mediaStore.importImage(data, title: "拍摄的照片") }
            }, onCaptureVideo: { model.mediaStore.importVideoFile($0, title: "拍摄的视频") }).ignoresSafeArea()
        }
        .fullScreenCover(item: $reelsRequest) { request in ReelsView(source: request.source) }
        .sheet(item: $assistantLaunch) { launch in
            NavigationStack {
                AssistantChatView(initialPrompt: launch.prompt, deepThinking: launch.deepThinking)
            }
        }
        .fullScreenCover(item: $activePlayer) { entry in
            MediaPlayerView(entry: entry, onShareToMoments: {
                activePlayer = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    activeSheet = .composer(entry)
                }
            }, onQueueAdvance: { next in
                activePlayer = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    activePlayer = next
                }
            }).universalLongPress(target: .home)
        }
        .sheet(item: $activeSheet) { destination in
            Group { switch destination {
            case .composer(let entry):
                MomentComposerView(initialAttachment: entry) { text, attachment in
                    model.publishMoment(text: text, attachment: attachment)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .quickActions(let entry):
                QuickActionsPanel(entry: entry, onPlay: {
                    activeSheet = nil
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        activePlayer = entry
                    }
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .share(let entry):
                ActivityShareSheet(items: [entry.remoteURL?.absoluteString ?? entry.title])
            case .destination(let action):
                NavigationStack {
                    commandDestination(action)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { activeSheet = nil } } }
                }
            } }.universalLongPress(target: .actionsPanel)
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--background-ui-tests") { await backgroundStore.prepareUITestMedia() }
            if ProcessInfo.processInfo.arguments.contains("--reels-ui-tests") {
                await backgroundStore.prepareUITestMedia()
                if let video = backgroundStore.assets.first(where: { $0.id == "ui-test-background-video" }),
                   let image = backgroundStore.assets.first(where: { $0.id == "ui-test-background-image" }) {
                    model.mediaStore.prepareReelsUITest(videoURL: backgroundStore.url(for: video), imageURL: backgroundStore.url(for: image))
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--moments-width-ui-tests") {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 220)).image { context in
                    UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 220))
                }
                if let data = image.jpegData(compressionQuality: 0.85) {
                    model.mediaStore.importImage(data, title: "宽幅图片回归测试")
                    if let entry = model.mediaStore.items.first { model.prepareWideMomentUITest(entry) }
                }
                model.selectedTab = .moments
            }
            #endif
            guard !ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests") else { return }
            await model.mediaStore.refreshDiscover()
        }
        .overlay(alignment: .topLeading) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--background-ui-tests") {
                Text(backgroundStore.uiTestReady ? "背景测试就绪" : "背景准备中")
                    .font(.caption2).foregroundStyle(.secondary).allowsHitTesting(false)
                    .accessibilityIdentifier("background-test-state")
            }
            #endif
        }
        .overlay(alignment: .topTrailing) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--async-discovery-ui-tests") {
                VStack {
                    Button("模拟异步内容") {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            model.mediaStore.insertAsyncUITestEntry()
                        }
                    }.padding(12).background(.regularMaterial).accessibilityIdentifier("simulate-data-update")
                }.padding(.top, 80)
            }
            #endif
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.runVirtualActivityLoop()
        }
        .task(id: selectedMedia) {
            guard let selectedMedia,
                  let data = try? await selectedMedia.loadTransferable(type: Data.self) else { return }
            if let image = UIImage(data: data) {
                selectedImage = Image(uiImage: image)
                model.mediaStore.importImage(data, title: "导入的照片")
            } else if let type = selectedMedia.supportedContentTypes.first, type.conforms(to: .movie) {
                model.mediaStore.importMedia(data, title: "导入的视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
            }
        }
    }

    private func refreshable<Content: View>(_ tab: AppTab, @ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 1).id("feed-top-\(tab.rawValue)")
                        content()
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height, alignment: .topLeading)
                        HStack(spacing: 6) {
                            if bottomRefreshing { ProgressView() }
                            else { Image(systemName: "arrow.up") }
                            Text(bottomRefreshing ? "正在刷新" : "继续上拉刷新")
                                .accessibilityIdentifier("bottom-refresh-state-\(tab.rawValue)")
                                .accessibilityValue("\(bottomRefreshCount)")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 76)
                    }
                    .background {
                        BottomRefreshObserver(
                            onRefresh: {
                                guard !bottomRefreshing else { return }
                                bottomRefreshing = true
                                bottomRefreshCount += 1
                                defer { bottomRefreshing = false }
                                await refreshFeed(tab)
                            },
                            onNearBottom: { nearBottom in
                                guard !bottomRefreshing else { return }
                                if nearBottom { bottomFeedTab = tab }
                                else if bottomFeedTab == tab { bottomFeedTab = nil }
                            }
                        )
                        .frame(width: 0, height: 0)
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("feed-scroll-\(tab.rawValue)")
                .refreshable { await refreshFeed(tab) }
                .overlay(alignment: .bottomTrailing) {
                    if bottomFeedTab == tab && !bottomRefreshing {
                        Button {
                            withAnimation(.easeOut(duration: 0.28)) {
                                proxy.scrollTo("feed-top-\(tab.rawValue)", anchor: .top)
                                bottomFeedTab = nil
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.32)))
                                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                        }
                        .accessibilityLabel("返回顶部")
                        .accessibilityIdentifier("feed-scroll-top-\(tab.rawValue)")
                        .padding(.trailing, 16)
                        .padding(.bottom, navigationVisible ? 104 : 16)
                        .transition(.scale(scale: 0.75).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if bottomRefreshing {
                        ProgressView().padding(10)
                            .background(.regularMaterial, in: Circle())
                            .padding(.bottom, 82)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func refreshFeed(_ tab: AppTab) async {
        if tab == .discover, !discoveryQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await model.mediaStore.searchDiscover(discoveryQuery)
        } else { await model.refresh(tab) }
    }

    private func performQuickAction(_ action: QuickActionID, for entry: MediaEntry) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        model.activeLongPressMenu = nil
        switch action {
        case .play:
            activePlayer = entry
        case .favorite:
            model.mediaStore.toggleFavorite(entry)
        case .library:
            model.mediaStore.appendToLibrary([entry])
        case .share:
            activeSheet = .share(entry)
        }
    }

    private var tabBar: some View {
        Group {
        if effectiveNavigationMode == .slider {
            SlidingTabSurface(selected: model.selectedTab, onSelect: selectTab)
                .frame(height: 64).padding(.horizontal, 8).padding(.bottom, 4)
        } else if effectiveNavigationMode == .assistant {
            AssistantDock(onFocusChange: { focused in
                assistantFocused = focused
                if focused { navigationHideTask?.cancel(); navigationVisible = true }
                else { scheduleNavigationHide() }
            }) { prompt, deepThinking in
                model.activeLongPressMenu = nil
                assistantLaunch = AssistantLaunch(prompt: prompt, deepThinking: deepThinking)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        } else {
        GeometryReader { geometry in
            // Five independent, native-glass circles: a compact Telegram-like
            // floating dock without a second bar or an enclosing glass plate.
            let diameter = min(60, max(54, (geometry.size.width - 72) / 5))
            let dockWidth = min(geometry.size.width - 36, 390)
            HStack(spacing: 0) {
                ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .scaleEffect(model.selectedTab == tab ? 1.10 : 1)
                            .rotationEffect(.degrees(model.selectedTab == tab ? 3 : 0))
                            .opacity(blindMode ? 0.01 : 1)
                            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: model.selectedTab)
                            .frame(width: diameter, height: diameter)
                            .moonGlassCircle(.button(for: tab))
                            .overlay(Circle().strokeBorder(model.selectedTab == tab ? activeButtonTint.opacity(0.62) : .clear, lineWidth: 1).allowsHitTesting(false))
                        Text(tab.title).font(.system(size: 10, weight: model.selectedTab == tab ? .semibold : .medium))
                            .opacity(blindMode ? 0.01 : 1)
                    }
                    .foregroundStyle(backgroundStore.resolved(.button(for: tab))?.veil.foreground ?? (model.selectedTab == tab ? activeButtonTint : .secondary))
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(width: dockWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 78).padding(.horizontal, 18).padding(.bottom, 8)
        }
        }
    }

    @ViewBuilder private var priorityNavigationLayer: some View {
        if effectiveNavigationMode == .circles {
            GeometryReader { geometry in
                let width = min(geometry.size.width - 36, 390)
                let diameter = min(60, max(54, (geometry.size.width - 72) / 5))
                ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button {
                        model.activeLongPressMenu = nil
                        NotificationCenter.default.post(name: .init("moonlight.navigationTapped"), object: nil)
                        UISelectionFeedbackGenerator().selectionChanged()
                        selectTab(tab)
                    } label: { Color.clear.contentShape(Circle()) }
                    .buttonStyle(.plain)
                    .frame(width: diameter + 4, height: diameter + 4)
                    .position(x: (geometry.size.width - width) / 2 + width * (CGFloat(index) + 0.5) / 5,
                              y: diameter / 2 + 1)
                    .accessibilityLabel(tab.title)
                    .accessibilityIdentifier("navigation-\(tab.rawValue)")
                }
            }
            .frame(height: 78)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    private func selectTab(_ tab: AppTab) {
        revealNavigation()
        if tab == .camera { openCamera(video: false) }
        else { withAnimation(.easeOut(duration: 0.16)) { model.selectedTab = tab } }
    }

    private func revealNavigation() {
        navigationHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { navigationVisible = true }
        scheduleNavigationHide()
    }

    private func scheduleNavigationHide() {
        navigationHideTask?.cancel()
        guard (!isGestureUITest || ProcessInfo.processInfo.arguments.contains("--hidden-dock-ui-tests")),
              !assistantFocused, navigationHideDelay > 0 else {
            navigationVisible = true
            return
        }
        navigationHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(navigationHideDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.34)) { navigationVisible = false }
        }
    }

    private func openCamera(video: Bool) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            rootNotice = "当前设备没有可用相机。你可以长按拍摄按钮，选择从照片图库导入。"; return
        }
        captureRequest = CameraRequest(video: video)
    }

    private func route(_ action: AppCommand, context: String) {
        switch action {
        case .home: selectTab(.home)
        case .discover: selectTab(.discover)
        case .moments: selectTab(.moments)
        case .me: selectTab(.me)
        case .photo: openCamera(video: false)
        case .video: openCamera(video: true)
        case .importMedia: rootImporter = true
        case .reelsLibrary: reelsRequest = ReelsRequest(source: .library)
        case .reelsSources: reelsRequest = ReelsRequest(source: .sources)
        case .compose: activeSheet = .composer(nil)
        case .avatar, .cover: model.selectedTab = .moments
        case .deleteCover: deleteCoverConfirmation = true
        case .refresh:
            Task {
                if model.selectedTab == .discover && !discoveryQuery.isEmpty { await model.mediaStore.searchDiscover(discoveryQuery) }
                else { await model.refresh(model.selectedTab) }
            }
        case .sources:
            model.selectedTab = .discover
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                discoverySourcesPresented = true
            }
        case .layout:
            model.selectedTab = .discover
            let old = UserDefaults.standard.integer(forKey: "discover_columns")
            UserDefaults.standard.set(old == 1 ? 2 : 1, forKey: "discover_columns")
        case .random10, .random15, .random20:
            Task { await model.mediaStore.addRandom(count: action == .random10 ? 10 : action == .random15 ? 15 : 20) }
        case .portrait: model.portraitPlaybackOnly.toggle()
        case .virtualFriends: model.virtualActivityEnabled.toggle()
        case .navigationMode: interactions.navigationMode = interactions.navigationMode == .circles ? .slider : .circles
        case .library, .selectAll, .favorites, .downloads, .settings, .friends, .messages, .profile:
            model.selectedTab = .me
        case .playMedia, .favoriteMedia, .saveMedia, .shareMedia:
            activeSheet = .destination(action)
        default: activeSheet = .destination(action)
        }
    }

    @ViewBuilder private func commandDestination(_ action: AppCommand) -> some View {
        switch action {
        case .settings: SettingsView()
        case .menuSettings: ContextMenuSettingsView()
        case .background, .backgrounds, .backgroundLibrary: BackgroundSettingsView()
        case .friends: VirtualFriendsView(onSelect: { activeSheet = nil; activePlayer = $0 })
        case .messages: VirtualMessagesView()
        case .profile: ProfileEditView()
        case .gestures: GestureHelpView()
        case .playMedia, .favoriteMedia, .saveMedia, .shareMedia:
            List {
                Section("选择要操作的媒体") {
                    ForEach(model.mediaStore.items) { entry in
                        Button(entry.title) {
                            activeSheet = nil
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                if let operation = action.mediaAction { performQuickAction(operation, for: entry) }
                            }
                        }
                    }
                    if model.mediaStore.items.isEmpty { Text("请先向库中导入媒体。") }
                }
            }.navigationTitle(action.title)
        default: LibraryView(selectedImage: selectedImage, selection: $selectedMedia, onPlay: { activeSheet = nil; activePlayer = $0 })
        }
    }
}

private struct CameraRequest: Identifiable { let id = UUID(); var video: Bool }
private struct ReelsRequest: Identifiable { let id = UUID(); let source: ReelsSource }

// Transparent gaps pass touches through to the feed. Each visible circle owns
// one native button, above media surfaces, with a minimum 48 pt touch target.
private struct PriorityTabSurface: UIViewRepresentable {
    var onSelect: (AppTab) -> Void
    func makeUIView(context: Context) -> PriorityTabView { PriorityTabView() }
    func updateUIView(_ view: PriorityTabView, context: Context) { view.onSelect = onSelect }
}

// Slider mode shows the actual UIKit segmented control. The recognizer below
// adds cross-segment dragging while UIKit keeps its native tint and layout.
private struct SlidingTabSurface: View {
    let selected: AppTab
    var onSelect: (AppTab) -> Void
    var body: some View {
        NativeSlidingTabSurface(selected: selected, onSelect: onSelect)
    }
}

// Slider mode deliberately uses UITabBar instead of drawing a second glass
// control. That gives the reference iOS spacing, accessibility, safe-area
// behavior and larger native hit regions while a horizontal pan remains a
// convenient way to switch tabs.
private struct NativeSlidingTabSurface: UIViewRepresentable {
    let selected: AppTab
    var onSelect: (AppTab) -> Void
    func makeUIView(context: Context) -> NativeSlidingTabBar { NativeSlidingTabBar() }
    func updateUIView(_ view: NativeSlidingTabBar, context: Context) {
        view.onSelect = onSelect
        view.setSelected(selected)
    }
}

private final class NativeSlidingTabBar: UITabBar, UITabBarDelegate, UIGestureRecognizerDelegate {
    var onSelect: ((AppTab) -> Void)?
    private let slidePan = UIPanGestureRecognizer()
    private var isApplyingSelection = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "navigation-slider"
        accessibilityLabel = "原生底部导航"
        delegate = self
        items = AppTab.allCases.enumerated().map { UITabBarItem(title: $0.element.title, image: UIImage(systemName: $0.element.symbol), tag: $0.offset) }
        itemPositioning = .fill
        itemWidth = 0
        itemSpacing = 0
        isTranslucent = true
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        appearance.backgroundColor = .clear
        let selectedColor = UIColor(MoonStyle.accent)
        appearance.stackedLayoutAppearance.selected.iconColor = selectedColor
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
        appearance.stackedLayoutAppearance.normal.iconColor = .secondaryLabel
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.secondaryLabel]
        standardAppearance = appearance
        scrollEdgeAppearance = appearance
        slidePan.addTarget(self, action: #selector(slid(_:)))
        slidePan.delegate = self
        addGestureRecognizer(slidePan)
        setSelected(.home)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ tab: AppTab) {
        guard !isApplyingSelection else { return }
        selectedItem = items?.first(where: { $0.tag == (AppTab.allCases.firstIndex(of: tab) ?? 0) })
    }

    func tab(at point: CGPoint) -> AppTab {
        let width = max(1, bounds.width / CGFloat(AppTab.allCases.count))
        let index = min(AppTab.allCases.count - 1, max(0, Int(point.x / width)))
        return AppTab.allCases[index]
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard !isApplyingSelection, let tab = AppTab.allCases[safe: item.tag] else { return }
        activate(tab)
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === slidePan else { return true }
        let velocity = slidePan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func slid(_ recognizer: UIPanGestureRecognizer) {
        let tab = tab(at: recognizer.location(in: self))
        if recognizer.state == .began || recognizer.state == .changed {
            if selectedItem?.tag != (AppTab.allCases.firstIndex(of: tab) ?? 0) {
                UISelectionFeedbackGenerator().selectionChanged()
                setSelected(tab)
                activate(tab)
            }
        }
    }

    private func activate(_ tab: AppTab) {
        NotificationCenter.default.post(name: .init("moonlight.navigationTapped"), object: nil)
        onSelect?(tab)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class PriorityTabView: UIView {
    var onSelect: ((AppTab) -> Void)?
    private var buttons: [UIButton] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for (index, tab) in AppTab.allCases.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.accessibilityLabel = tab.title
            button.accessibilityIdentifier = "navigation-\(tab.rawValue)"
            button.addTarget(self, action: #selector(selected(_:)), for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width, 540)
        let diameter = min(50, max(44, (bounds.width - 80) / 6))
        let step = (width - diameter) / 4
        for (index, button) in buttons.enumerated() {
            let center = CGPoint(x: (bounds.width - width) / 2 + diameter / 2 + CGFloat(index) * step, y: bounds.midY)
            let hitSize = max(48, diameter)
            button.frame = CGRect(x: center.x - hitSize / 2, y: center.y - hitSize / 2, width: hitSize, height: hitSize)
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
    @objc private func selected(_ sender: UIButton) {
        guard AppTab.allCases.indices.contains(sender.tag) else { return }
        onSelect?(AppTab.allCases[sender.tag])
    }
}

private extension View {
    func universalLongPress(target: BackgroundTarget) -> some View {
        modifier(UniversalHoldScope(target: target))
    }
}

private enum HoldDestination: Identifiable {
    case background(BackgroundTarget), backgrounds, guide, more, menus, backgroundLibrary
    var id: String {
        switch self { case .background(let target): target.rawValue; case .backgrounds: "backgrounds"; case .guide: "guide"; case .more: "more"; case .menus: "menus"; case .backgroundLibrary: "backgroundLibrary" }
    }
}

private struct UniversalHoldScope: ViewModifier {
    let target: BackgroundTarget
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismissPresentation
    @ObservedObject private var interactions = InteractionPreferences.shared
    @State private var menu: ActiveLongPressMenu?
    @State private var heldTarget: BackgroundTarget?
    @State private var destination: HoldDestination?
    @State private var globalSearch: GlobalSearchPresentation?
    @State private var assistantLaunch: AssistantLaunch?
    @State private var confirmBottomSearch = false
    @State private var pendingSearchLocation = CGPoint.zero
    @AppStorage("moonlight.globalSearch.enabled") private var globalSearchEnabled = false
    @AppStorage("moonlight.blindMode") private var blindMode = false

    private var isGestureUITest: Bool {
        ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests")
    }

    func body(content: Content) -> some View {
        content
            .background {
                GlobalHoldObserver(enabled: menu == nil && globalSearch == nil && model.activeLongPressMenu == nil,
                    onBegin: { point, buttonTarget in
                        heldTarget = buttonTarget ?? target
                        LongPressHapticFeedback.shared.menuOpened()
                        if (globalSearchEnabled || blindMode) && (!isGestureUITest || blindMode) {
                            pendingSearchLocation = point
                            if interactions.navigationMode == .assistant && !blindMode {
                                confirmBottomSearch = true
                            } else {
                                globalSearch = GlobalSearchPresentation(location: point)
                            }
                        } else {
                            menu = ActiveLongPressMenu(entry: nil, location: point, fingerLocation: point)
                        }
                    }, onMove: { point in
                        guard var current = menu, current.fingerDown else { return }
                        current.fingerLocation = point
                        if model.longPressStyle != .popover { current.location = point }
                        menu = current
                    }, onEnd: { menu?.fingerDown = false })
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay {
                Group {
                    if let search = globalSearch {
                        GlobalAssistantSearchOverlay(
                            presentation: search,
                            onDismiss: { globalSearch = nil },
                            onCommand: { command in
                                globalSearch = nil
                                model.send(command, context: "global-search")
                            },
                            onChat: { prompt in
                                globalSearch = nil
                                assistantLaunch = AssistantLaunch(prompt: prompt, deepThinking: false)
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .zIndex(20)
                    }
                    if let menu {
                        LongPressRingOverlay(menu: menu, actions: interactions.actions((heldTarget ?? target).rawValue).map(RingAction.command),
                            style: model.longPressStyle, selectionMode: model.longPressSelectionMode,
                            onAction: perform, onMore: { self.menu = nil; destination = .more },
                            onDismiss: { self.menu = nil })
                            .accessibilityIdentifier("global-long-press-menu")
                    }
                }
            }
            .onChange(of: model.selectedTab) { _ in menu = nil; globalSearch = nil; confirmBottomSearch = false }
            .onReceive(NotificationCenter.default.publisher(for: .init("moonlight.navigationTapped"))) { _ in menu = nil; globalSearch = nil; confirmBottomSearch = false }
            .confirmationDialog("直接使用底部输入栏？", isPresented: $confirmBottomSearch, titleVisibility: .visible) {
                Button("直接使用下面") {
                    NotificationCenter.default.post(name: .init("moonlight.assistantDockFocus"), object: nil)
                }
                Button("进入全局搜索") {
                    globalSearch = GlobalSearchPresentation(location: pendingSearchLocation)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("底部已经是智能输入栏，可直接继续输入；也可以打开悬浮搜索。")
            }
            .sheet(item: $assistantLaunch) { launch in
                NavigationStack { AssistantChatView(initialPrompt: launch.prompt, deepThinking: launch.deepThinking) }
            }
            .sheet(item: $destination) { item in
                NavigationStack {
                    Group {
                        switch item {
                        case .background(let selected): BackgroundEditorView(target: selected)
                        case .backgrounds: BackgroundSettingsView()
                        case .guide: GestureHelpView()
                        case .menus: ContextMenuSettingsView()
                        case .backgroundLibrary: BackgroundSettingsView()
                        case .more:
                            List {
                                Section((heldTarget ?? target).title) {
                                    ForEach(interactions.actions((heldTarget ?? target).rawValue)) { action in
                                        Button { destination = nil; perform(.command(action)) } label: { Label(action.title, systemImage: action.symbol) }
                                    }
                                }
                                Section("外观") {
                                    Button("调整当前背景") { destination = .background(heldTarget ?? target) }
                                    Button("页面与按键背景") { destination = .backgrounds }
                                }
                                Section("操作") {
                                    Button("配置长按菜单") { destination = .menus }
                                    Button("手势说明") { destination = .guide }
                                }
                            }.navigationTitle("更多操作")
                        }
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { destination = nil } } }
                }.universalLongPress(target: .settings).presentationDragIndicator(.visible)
            }
    }

    private func perform(_ action: RingAction) {
        menu = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard case .command(let command) = action else { return }
        switch command {
        case .background: destination = .background(heldTarget ?? target)
        case .backgrounds: destination = .backgrounds
        case .backgroundLibrary: destination = .backgroundLibrary
        case .gestures: destination = .guide
        case .menuSettings: destination = .menus
        default:
            destination = nil
            dismissPresentation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                model.send(command, context: (heldTarget ?? target).rawValue)
            }
        }
    }

    private var holdGuide: some View {
        List {
            Label("先移动手指：优先滚动，不触发点按或长按", systemImage: "arrow.up.and.down")
            Label("静止按住：触感反馈，圆环旋转打开", systemImage: "hand.point.up.left")
            Label("松手后圆环保持打开，再点按执行", systemImage: "hand.tap")
            Label("媒体卡片显示播放、收藏、加入库和分享", systemImage: "play.rectangle")
            Label("页面空白和按键显示背景、刷新等常用操作", systemImage: "square.grid.2x2")
            Label("中心 … 打开更多操作；点空白处或下滑收起", systemImage: "ellipsis.circle")
            Label("输入框与系统照片选择器保留系统手势", systemImage: "keyboard")
        }.navigationTitle("手势说明")
    }
}

// Watch the existing native pan at the end of the feed. Adding a target to its
// recognizer does not compete with card taps, holds, or scroll deceleration.
private struct BottomRefreshObserver: UIViewRepresentable {
    let onRefresh: () async -> Void
    let onNearBottom: (Bool) -> Void
    func makeUIView(context: Context) -> BottomRefreshMarker { BottomRefreshMarker() }
    func updateUIView(_ view: BottomRefreshMarker, context: Context) {
        view.onRefresh = onRefresh
        view.onNearBottom = onNearBottom
        view.installIfNeeded()
    }
    static func dismantleUIView(_ view: BottomRefreshMarker, coordinator: ()) { view.detach() }
}

private final class BottomRefreshMarker: UIView {
    var onRefresh: (() async -> Void)?
    var onNearBottom: ((Bool) -> Void)?
    private weak var scrollView: UIScrollView?
    private var armed = false
    private var nearBottom = false
    private var refreshing = false
    private var observations: [NSKeyValueObservation] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); installIfNeeded() }
    func installIfNeeded() {
        guard window != nil else { detach(); return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                guard scrollView !== scroll else { return }
                detach()
                scrollView = scroll
                scroll.alwaysBounceVertical = true
                scroll.canCancelContentTouches = true
                scroll.clipsToBounds = false
                scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                observations = [
                    scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.updateBottomVisibility() }
                    },
                    scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.updateBottomVisibility() }
                    },
                    scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.updateBottomVisibility() }
                    }
                ]
                return
            }
            ancestor = view.superview
        }
    }
    func detach() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        scrollView = nil
        armed = false
        nearBottom = false
    }
    private func updateBottomVisibility() {
        guard let scroll = scrollView, window != nil else { return }
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let visible = bottom > 80 && scroll.contentOffset.y >= bottom - 56
        guard visible != nearBottom else { return }
        nearBottom = visible
        onNearBottom?(visible)
    }
    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        guard let scroll = scrollView, !refreshing else { return }
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let overscroll = scroll.contentOffset.y - bottom
        updateBottomVisibility()
        switch pan.state {
        case .changed:
            if overscroll > 65 { armed = true }
            else if overscroll < 20 { armed = false }
        case .ended:
            guard armed else { return }
            armed = false
            refreshing = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.onRefresh?()
                self.refreshing = false
            }
        case .cancelled, .failed:
            armed = false
        default: break
        }
    }
}

// Observe the hosting view instead of laying a touch-swallowing layer over it.
// There is no pan recognizer: movement cancels a hold at 7 pt, leaving UIScrollView
// in charge. Native pickers, text editing and media-card recognizers stay local.
private struct GlobalHoldObserver: UIViewRepresentable {
    var enabled: Bool
    var onBegin: (CGPoint, BackgroundTarget?) -> Void
    var onMove: (CGPoint) -> Void
    var onEnd: () -> Void
    func makeUIView(context: Context) -> GlobalHoldMarker { GlobalHoldMarker() }
    func updateUIView(_ view: GlobalHoldMarker, context: Context) {
        view.canBegin = enabled
        view.onBegin = onBegin; view.onMove = onMove; view.onEnd = onEnd
        view.installIfNeeded()
    }
    static func dismantleUIView(_ view: GlobalHoldMarker, coordinator: ()) { view.detach() }
}

private final class GlobalHoldMarker: UIView, UIGestureRecognizerDelegate {
    var canBegin = true
    var onBegin: ((CGPoint, BackgroundTarget?) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    private weak var owner: UIViewController?
    private let hold = UILongPressGestureRecognizer()
    private var heldTarget: BackgroundTarget?
    private weak var touchedView: UIView?
    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        hold.minimumPressDuration = 0.48; hold.allowableMovement = 10
        // A completed global hold owns the stationary touch and must prevent
        // the underlying button from also firing on release. A moving touch
        // exceeds allowableMovement before recognition, so ScrollView keeps
        // its native pan without a failure dependency.
        hold.cancelsTouchesInView = true
        hold.delaysTouchesBegan = false; hold.delaysTouchesEnded = false
        hold.delegate = self; hold.addTarget(self, action: #selector(held(_:)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); installIfNeeded() }
    func installIfNeeded() {
        guard window != nil else { detach(); return }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                if owner !== controller {
                    detach(); owner = controller; controller.view.addGestureRecognizer(hold)
                }
                return
            }
            responder = current.next
        }
    }
    func detach() { hold.view?.removeGestureRecognizer(hold); owner = nil }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard canBegin, owner?.presentedViewController == nil else { return false }
        if let window, MediaCardHitRegistry.contains(touch.location(in: window), in: window),
           !touchHitsNavigationChrome(touch) {
            // Media cards own their native SwiftUI tap/hold. Keeping the root
            // hold out of this touch removes a second recognizer from the
            // scroll view's arbitration graph. A card rect can extend under
            // the floating tab bar; that finger still belongs to the bar.
            return false
        }
        LongPressHapticFeedback.shared.prepare()
        touchedView = touch.view
        heldTarget = window.flatMap { BackgroundHitRegistry.target(at: touch.location(in: $0), in: $0) }
        var ancestor = touch.view
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                // Preserve UIScrollView's native arbitration. Setting this to
                // false is sticky: one hold attempt on a header used to make
                // every later card receive touches before the feed pan, which
                // is why a follow-up flick could stop on a content banner.
                scroll.delaysContentTouches = true
                scroll.canCancelContentTouches = true
                // A new touch during momentum belongs to the scroll view. Do
                // not add a button/hold failure dependency to that new stroke.
                if scroll.isDecelerating { return false }
            }
            // Keep Apple's value controls in charge of their own short taps.
            // A global hold on a switch delays or cancels the state transition
            // on some devices, while ordinary buttons and page backgrounds
            // continue to participate in the contextual hold menu.
            if view is CardGestureView || view is UITextField || view is UITextView || view is UISlider || view is UISwitch { return false }
            if let slider = view as? NativeSlidingTabBar { heldTarget = .button(for: slider.tab(at: touch.location(in: slider))) }
            if let identifier = view.accessibilityIdentifier,
               identifier.hasPrefix("moment-post-card-") { return false }
            if let identifier = view.accessibilityIdentifier,
               identifier.hasPrefix("navigation-"),
               let tab = AppTab(rawValue: String(identifier.dropFirst("navigation-".count))) {
                heldTarget = .button(for: tab)
            }
            ancestor = view.superview
        }
        return true
    }
    /// The feed draws underneath the dock, so a card's window rect often
    /// contains a tab-bar point. The touch view is the control that was
    /// actually hit; only that control decides whether this is a card.
    private func touchHitsNavigationChrome(_ touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is NativeSlidingTabBar || current is PriorityTabView { return true }
            if let identifier = current.accessibilityIdentifier,
               identifier == "navigation-slider" || identifier.hasPrefix("navigation-") {
                return true
            }
            view = current.superview
        }
        return false
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Feed-card touches are rejected in shouldReceive before this hold can
        // enter their arbitration graph. Elsewhere, SwiftUI button presses must
        // wait for the global hold so a stationary hold cannot tap through.
        // Pans, including the tab bar's drag-to-switch, must never wait.
        !(otherGestureRecognizer is UIPanGestureRecognizer)
            && !(otherGestureRecognizer is UILongPressGestureRecognizer)
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canBegin else { return false }
        var ancestor = touchedView
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isDragging || scroll.isDecelerating { return false }
            ancestor = view.superview
        }
        return true
    }
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            LongPressHapticFeedback.shared.menuOpened()
            onBegin?(point, heldTarget)
        case .changed: onMove?(point)
        case .ended: onMove?(point); onEnd?()
        case .cancelled: onEnd?()
        default: break
        }
    }
}

private enum RootSheet: Identifiable {
    case composer(MediaEntry?)
    case quickActions(MediaEntry)
    case share(MediaEntry)
    case destination(AppCommand)
    var id: String {
        switch self {
        case .composer(let entry): "composer-\(entry?.id ?? "new")"
        case .quickActions(let entry): "quick-actions-\(entry.id)"
        case .share(let entry): "share-\(entry.id)"
        case .destination(let action): "destination-\(action.rawValue)"
        }
    }
}

private struct LongPressRingOverlay: View {
    let menu: ActiveLongPressMenu
    let actions: [RingAction]
    let style: LongPressStyle
    let selectionMode: LongPressSelectionMode
    let onAction: (RingAction) -> Void
    let onMore: () -> Void
    let onDismiss: () -> Void
    @State private var ringAppeared = false

    var body: some View {
        GeometryReader { geometry in
            let center = clamped(menu.location, to: geometry.size)
            let highlightedAction = dragHighlightedAction(center: center)
            let bubbleOrigin = bubbleStartOffset(center: center, size: geometry.size)
            ZStack {
                Color.black.opacity(menu.fingerDown ? 0.035 : 0.015)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 14).onEnded { value in
                            if value.translation.height > 28 { onDismiss() }
                        }
                    )
                glassTabContainer {
                    ZStack {
                        ForEach(Array(actions.prefix(4).enumerated()), id: \.element) { item in
                            let index = item.offset
                            let action = item.element
                            let offset = actionOffsets(for: actions.count)[index]
                            ringButton(action)
                                .scaleEffect(style == .bubble && !ringAppeared ? 0.32 : isHighlighted(index, center: center) ? 1.14 : 1)
                                .opacity(style == .bubble && !ringAppeared ? 0.55 : 1)
                                .position(x: center.x + (style == .bubble && !ringAppeared ? bubbleOrigin.x : offset.x),
                                          y: center.y + (style == .bubble && !ringAppeared ? bubbleOrigin.y : offset.y))
                                .animation(.spring(response: 0.42, dampingFraction: 0.7).delay(Double(index) * 0.055), value: ringAppeared)
                        }
                        Image(systemName: "ellipsis")
                                .font(.system(size: 21, weight: .bold))
                                .frame(width: 54, height: 54)
                                .moonGlassCircle(.ringCenter)
                                .allowsHitTesting(false).accessibilityHidden(true)
                                .overlay {
                                    RingTouchButton(title: "打开全部操作", identifier: "打开全部操作", onActivate: onMore)
                                        .frame(width: 54, height: 54)
                                }
                        .position(center)
                        .scaleEffect(style == .bubble && !ringAppeared ? 0.84 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.68), value: ringAppeared)
                    }
                }
                .scaleEffect(style == .bubble ? 1 : ringAppeared ? 1 : 0.72,
                             anchor: UnitPoint(x: center.x / max(geometry.size.width, 1), y: center.y / max(geometry.size.height, 1)))
                .rotationEffect(.degrees(style == .bubble ? 0 : ringAppeared ? 0 : -90),
                                anchor: UnitPoint(x: center.x / max(geometry.size.width, 1), y: center.y / max(geometry.size.height, 1)))
                .opacity(style == .bubble ? 1 : ringAppeared ? 1 : 0)
                .scaleEffect(style == .droplet ? menu.dropletScale : 1)
                .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.62), value: menu.dropletScale)
                .animation(.interactiveSpring(response: 0.16, dampingFraction: 0.78), value: menu.location)
            }
            .onAppear {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) { ringAppeared = true }
            }
            .onChange(of: menu.fingerDown) { fingerDown in
                guard !fingerDown, selectionMode == .drag,
                      let index = hitAction(at: menu.fingerLocation, center: center, count: min(4, actions.count)) else { return }
                onAction(actions[index])
            }
            .onChange(of: highlightedAction) { action in
                guard action != nil else { return }
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func ringButton(_ action: RingAction) -> some View {
        let isFavorite = menu.entry?.isFavorite ?? false
        return VStack(spacing: 3) {
                Image(systemName: action.mediaAction == .favorite && isFavorite ? "heart.slash.fill" : action.symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(action.mediaAction == .favorite && isFavorite ? "取消收藏" : action.title)
                    .font(.system(size: 9, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.8)
            }
            .frame(width: 58, height: 58)
            .moonGlassCircle(action.background)
            .allowsHitTesting(false).accessibilityHidden(true)
            .overlay {
                RingTouchButton(title: action.title, identifier: "ring-action-\(action.symbol)", onActivate: { onAction(action) })
                    .frame(width: 58, height: 58)
            }
    }

    private func globalTitle(_ action: QuickActionID) -> String {
        switch action { case .play: "刷新"; case .favorite: "当前背景"; case .library: "全部背景"; case .share: "手势说明" }
    }

    private func globalSymbol(_ action: QuickActionID) -> String {
        switch action { case .play: "arrow.clockwise"; case .favorite: "photo"; case .library: "square.grid.2x2"; case .share: "hand.draw" }
    }

    private func actionOffsets(for count: Int) -> [CGPoint] {
        switch count {
        case 1: [CGPoint(x: 0, y: -66)]
        case 2: [CGPoint(x: -54, y: 0), CGPoint(x: 54, y: 0)]
        case 3: [CGPoint(x: -48, y: -42), CGPoint(x: 48, y: -42), CGPoint(x: 0, y: 62)]
        default: [CGPoint(x: -48, y: -48), CGPoint(x: 48, y: -48), CGPoint(x: 48, y: 48), CGPoint(x: -48, y: 48)]
        }
    }

    private func bubbleStartOffset(center: CGPoint, size: CGSize) -> CGPoint {
        if center.y > size.height * 0.62 { return CGPoint(x: 0, y: -18) }
        if center.x > size.width * 0.66 { return CGPoint(x: -18, y: 0) }
        if center.x < size.width * 0.34 { return CGPoint(x: 18, y: 0) }
        return CGPoint(x: 18, y: -10)
    }

    private func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, 82), max(82, size.width - 82)),
                y: min(max(point.y, 100), max(100, size.height - 150)))
    }

    private func isHighlighted(_ index: Int, center: CGPoint) -> Bool {
        guard menu.fingerDown, index < min(4, actions.count) else { return false }
        let offset = actionOffsets(for: actions.count)[index]
        return selectionMode == .drag && hypot(menu.fingerLocation.x - center.x - offset.x, menu.fingerLocation.y - center.y - offset.y) < 36
    }

    private func dragHighlightedAction(center: CGPoint) -> RingAction? {
        guard selectionMode == .drag, menu.fingerDown,
              let index = hitAction(at: menu.fingerLocation, center: center, count: min(4, actions.count)) else { return nil }
        return actions[index]
    }

    private func hitAction(at point: CGPoint, center: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return actionOffsets(for: count).enumerated().first { item in
            hypot(point.x - center.x - item.element.x, point.y - center.y - item.element.y) < 34
        }?.offset
    }
}

// Keep glass rendering separate from touch delivery. Plain SwiftUI image labels
// can expose a larger accessibility frame than their painted hit region while
// rotating, sending a center tap to the dismissal scrim instead of the button.
private struct RingTouchButton: UIViewRepresentable {
    let title: String
    let identifier: String
    let onActivate: () -> Void
    func makeUIView(context: Context) -> RingTouchControl { RingTouchControl() }
    func updateUIView(_ view: RingTouchControl, context: Context) {
        view.accessibilityLabel = title
        view.accessibilityIdentifier = identifier
        view.onActivate = onActivate
    }
}

private final class RingTouchControl: UIButton {
    var onActivate: (() -> Void)?
    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(activate), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        UIBezierPath(ovalIn: bounds).contains(point)
    }
    @objc private func activate() { onActivate?() }
}

struct QuickActionsPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: MediaEntry
    let onPlay: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section("内容信息") {
                    LabeledContent("来源", value: entry.platform)
                    if !entry.author.isEmpty { LabeledContent("作者", value: entry.author) }
                    LabeledContent("位置", value: model.mediaStore.folders.first(where: { $0.id == model.mediaStore.folderID(for: entry) })?.name ?? "未分类")
                    if let progress = model.mediaStore.progress(for: entry), progress.position > 0 {
                        LabeledContent("观看进度", value: "\(Int(progress.position / 60)):\(String(format: "%02d", Int(progress.position) % 60))")
                    }
                }
                Section("已配置的更多操作") {
                    ForEach(InteractionPreferences.shared.actions("media").filter { $0.mediaAction == nil }) { action in
                        Button {
                            if let media = action.mediaAction {
                                switch media {
                                case .play: onPlay()
                                case .favorite: model.mediaStore.toggleFavorite(entry)
                                case .library: model.mediaStore.appendToLibrary([entry])
                                case .share: model.send(.shareMedia, context: "media")
                                }
                            } else {
                                dismiss()
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 350_000_000)
                                    model.send(action, context: "media")
                                }
                            }
                        } label: { Label(action.title, systemImage: action.symbol).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                        .accessibilityElement(children: .ignore).accessibilityLabel(action.title)
                        .accessibilityIdentifier("configured-action-\(action.rawValue)")
                    }
                }
                Section("播放与分享") {
                    Button(action: onPlay) { Label("播放 / 打开", systemImage: "play.fill") }
                    ShareLink(item: entry.remoteURL?.absoluteString ?? entry.title, preview: SharePreview(entry.title)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                Section("保存与整理") {
                    Button {
                        model.mediaStore.toggleFavorite(entry)
                    } label: {
                        Label(entry.isFavorite ? "取消收藏" : "收藏", systemImage: entry.isFavorite ? "heart.slash" : "heart")
                    }
                    Button {
                        model.mediaStore.appendToLibrary([entry])
                    } label: {
                        Label("加入库", systemImage: "plus.rectangle.on.folder")
                    }
                    Button {
                        model.mediaStore.enqueue([entry])
                    } label: {
                        Label("加入播放队列", systemImage: "text.badge.play")
                    }
                }
                Section("危险操作") {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .pageBackground(.actionsPanel)
            .navigationTitle("更多操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }
        .confirmationDialog("从库中删除这条内容？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.mediaStore.delete(entry)
                dismiss()
            }
            Button("取消", role: .cancel) { }
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    @State private var batchSize = 10
    private let sizes = [10, 15, 20]

    var body: some View {
            LazyVStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "月淡", subtitle: "为你留一段安静的时间", symbol: "moon.stars.fill")
            HStack {
                Text("最近内容").font(.title3.bold())
                Spacer()
                Menu {
                    ForEach(sizes, id: \.self) { count in
                        Button {
                            batchSize = count
                            Task { await model.mediaStore.addRandom(count: count) }
                        } label: { Label("随机添加 \(count) 条", systemImage: "shuffle") }
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44).moonGlassCircle()
                }
                .accessibilityLabel("随便看看")
                .accessibilityIdentifier("home-random-menu")
            }
            if model.mediaStore.items.isEmpty {
                EmptyPanel(title: "内容会出现在这里", detail: "下拉刷新，或从内容源随机添加内容。", symbol: "play.rectangle")
            } else {
                ForEach(model.mediaStore.items) { entry in MediaEntryCard(entry: entry, height: 210, onSelect: { onSelect(entry) }) }
            }
            if let notice = model.mediaStore.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
    }
}

private struct DiscoverView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var query: String
    let onSelect: (MediaEntry) -> Void
    let onSources: () -> Void
    @AppStorage("discover_columns") private var columns = 2
    @AppStorage("discover_banner_scale") private var bannerScale = 1.0
    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let cardGradients: [[Color]] = [
        [.indigo.opacity(0.72), .purple.opacity(0.35)], [.orange.opacity(0.68), .pink.opacity(0.3)],
        [.teal.opacity(0.7), .blue.opacity(0.32)], [.brown.opacity(0.58), .orange.opacity(0.3)]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "发现", subtitle: "探索新的内容源", symbol: "safari") {
                Button(action: onSources) {
                    Image(systemName: "line.3.horizontal.decrease").font(.headline)
                        .frame(width: 42, height: 42).moonGlassCircle(.discoverSources)
                }.buttonStyle(.plain).accessibilityLabel("内容源").accessibilityIdentifier("discover-sources")
                Button { columns = columns == 1 ? 2 : 1 } label: {
                    Image(systemName: columns == 1 ? "rectangle.grid.2x2" : "rectangle.grid.1x2")
                        .font(.headline).frame(width: 42, height: 42).moonGlassCircle(.discoverLayout)
                }.buttonStyle(.plain).accessibilityLabel("切换单双列").accessibilityIdentifier("discover-layout")
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索所选内容源或粘贴链接", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await model.mediaStore.searchDiscover(query) } }
                if !query.isEmpty {
                    Button { query = ""; model.mediaStore.clearDiscoverySearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 15).frame(height: 50)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("横幅大小").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(Int(bannerScale * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $bannerScale, in: 0.75...1.35)
            }
            HStack {
                Text(query.isEmpty ? "推荐内容" : "搜索结果").font(.title3.bold())
                Spacer()
                Button {
                    Task {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await model.mediaStore.refreshDiscover() }
                        else { await model.mediaStore.searchDiscover(query) }
                    }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass").font(.subheadline.weight(.medium))
                }.buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
            }
            let results = query.isEmpty ? model.mediaStore.discoverItems : model.mediaStore.searchResults
            if results.isEmpty {
                EmptyPanel(title: query.isEmpty ? "还没有推荐内容" : "没有搜索结果", detail: model.mediaStore.notice ?? "打开内容源选择分类并查看加载状态。", symbol: "safari")
                Button(action: onSources) { Label("查看内容源", systemImage: "slider.horizontal.3") }.buttonStyle(MoonGlassButtonStyle())
            } else {
                LazyVGrid(columns: columns == 1 ? [GridItem(.flexible())] : grid, spacing: 14) {
                    ForEach(results) { entry in
                        MediaEntryCard(entry: entry, height: CGFloat(columns == 1 ? 220 : 155) * bannerScale, onSelect: { onSelect(entry) })
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if !query.isEmpty && model.mediaStore.hasMoreYouTubeResults {
                Button("换一批") { Task { await model.mediaStore.searchDiscover(query, nextPage: true) } }.buttonStyle(MoonGlassButtonStyle())
            }
            if !query.isEmpty, !model.mediaStore.youtubeKeyConfigured,
               model.mediaStore.enabledSources.contains(where: { $0.kind == "youtube" && $0.enabled }) {
                YouTubeSearchFallback(query: query)
            }
            if model.mediaStore.isSearching || model.mediaStore.isRefreshing { ProgressView().frame(maxWidth: .infinity) }
            if let notice = model.mediaStore.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
        .onChange(of: query) { value in if value.isEmpty { model.mediaStore.clearDiscoverySearch() } }
    }
}

private struct DiscoverTile: View {
    let gradient: [Color]
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(.ultraThinMaterial, in: Circle()).padding(12)
            }
            .frame(height: compact ? 155 : 220)
            VStack(alignment: .leading, spacing: 5) {
                Text("精选内容源").font(.caption.weight(.semibold)).foregroundStyle(MoonStyle.accent)
                Text("发现值得收藏的新内容")
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(2)
            }.padding(13)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(.white.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }
}

/// One root-level interaction style keeps button feedback consistent without
/// adding another material layer. In full blind mode only the rendered label
/// disappears; layout and hit testing stay intact.
private struct MoonInteractiveButtonStyle: ButtonStyle {
    let blind: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(blind ? 0.01 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

// Feed cards register only their geometry. These markers never participate in
// hit testing, so UIScrollView receives a drag without an intervening UIView.
@MainActor private final class MediaCardHitRegistry {
    static var markers = NSHashTable<MediaCardHitMarker>.weakObjects()

    static func contains(_ point: CGPoint, in window: UIWindow) -> Bool {
        markers.allObjects.contains {
            $0.window === window && !$0.isHidden && $0.convert($0.bounds, to: window).contains(point)
        }
    }

    static func center(for id: String) -> CGPoint? {
        guard let marker = markers.allObjects.first(where: { $0.entryID == id }), let window = marker.window else { return nil }
        let frame = marker.convert(marker.bounds, to: window)
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

private final class MediaCardHitMarker: UIView {
    var entryID = ""
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        MediaCardHitRegistry.markers.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct MediaCardHitAnchor: UIViewRepresentable {
    let entryID: String
    func makeUIView(context: Context) -> MediaCardHitMarker { MediaCardHitMarker() }
    func updateUIView(_ view: MediaCardHitMarker, context: Context) { view.entryID = entryID }
}

private struct NativeMediaCardInteractions: ViewModifier {
    let holdEnabled: Bool
    let onTap: () -> Void
    let onHold: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if holdEnabled {
            content
                .gesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                        .exclusively(before: TapGesture())
                        .onEnded { result in
                            switch result {
                            case .first:
                                onHold()
                            case .second:
                                onTap()
                            }
                        }
                )
        } else {
            content.onTapGesture(perform: onTap)
        }
    }
}

// Used only by full-screen experiences such as Reels. Feed cards deliberately
// avoid this UIView surface so their enclosing UIScrollView receives pans
// directly, including a follow-up touch during deceleration.
struct CardGestureSurface: UIViewRepresentable {
    var holdEnabled = true
    var onTap: () -> Void
    var onHoldBegan: (CGPoint) -> Void
    var onHoldMoved: (CGPoint) -> Void
    var onHoldEnded: () -> Void
    var onDoubleTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> CardGestureView {
        let view = CardGestureView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: CardGestureView, context: Context) {
        view.holdEnabled = holdEnabled
        view.onTap = onTap
        view.onHoldBegan = onHoldBegan
        view.onHoldMoved = onHoldMoved
        view.onHoldEnded = onHoldEnded
        view.onDoubleTap = onDoubleTap
    }

    static func dismantleUIView(_ view: CardGestureView, coordinator: ()) {
        view.cancelHold()
    }
}

final class CardGestureView: UIView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    var onHoldBegan: ((CGPoint) -> Void)?
    var onHoldMoved: ((CGPoint) -> Void)?
    var onHoldEnded: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    private let hold = UILongPressGestureRecognizer()
    private var holdActive = false
    private var suppressTapFromHold = false
    private var delayedTapWorkItem: DispatchWorkItem?
    private var touchOrigin: CGPoint?
    private var touchMoved = false
    var holdEnabled = true {
        didSet {
            if holdEnabled {
                if hold.view == nil { addGestureRecognizer(hold) }
                hold.isEnabled = true
            } else {
                finishHold()
                hold.isEnabled = false
                if hold.view != nil { removeGestureRecognizer(hold) }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        isUserInteractionEnabled = true

        // Do not install a tap recognizer over the whole card. A recognizer on
        // every row remains in UIKit's arbitration graph while a second flick
        // starts and can turn that flick into a mere deceleration stop. Plain
        // UIView touch delivery is cancelled natively as soon as UIScrollView's
        // pan wins, while a stationary touch still opens the card on release.
        hold.delegate = self
        hold.minimumPressDuration = 0.50
        hold.allowableMovement = 10
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.addTarget(self, action: #selector(held(_:)))

        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var enclosingScrollViews: [UIScrollView] {
        var result: [UIScrollView] = []
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { result.append(scroll) }
            ancestor = view.superview
        }
        return result
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if enclosingScrollViews.contains(where: { $0.isDragging || $0.isDecelerating }) {
            delayedTapWorkItem?.cancel()
            delayedTapWorkItem = nil
            return false
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !enclosingScrollViews.contains(where: { $0.isDragging || $0.isDecelerating }) else { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A card must not prevent the feed from starting another scroll.
        // Movement beyond allowableMovement cancels an unrecognized hold.
        enclosingScrollViews.contains {
            $0.panGestureRecognizer === otherGestureRecognizer
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        touchOrigin = touch.location(in: self)
        touchMoved = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let origin = touchOrigin else { return }
        let point = touch.location(in: self)
        if hypot(point.x - origin.x, point.y - origin.y) > 7 {
            touchMoved = true
            delayedTapWorkItem?.cancel()
            delayedTapWorkItem = nil
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        defer { resetTouchTracking() }
        guard !touchMoved, !holdActive,
              !enclosingScrollViews.contains(where: { $0.isDragging || $0.isDecelerating }) else { return }
        if suppressTapFromHold {
            suppressTapFromHold = false
            return
        }
        triggerTap()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        delayedTapWorkItem?.cancel()
        delayedTapWorkItem = nil
        resetTouchTracking()
    }

    private func resetTouchTracking() {
        touchOrigin = nil
        touchMoved = false
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            holdActive = true
            suppressTapFromHold = true
            LongPressHapticFeedback.shared.menuOpened()
            onHoldBegan?(point)
        case .changed:
            if holdActive { onHoldMoved?(point) }
        case .ended:
            if holdActive { onHoldMoved?(point); finishHold() }
        case .cancelled, .failed:
            finishHold()
        default:
            break
        }
    }

    private func triggerTap() {
        guard onDoubleTap != nil else { onTap?(); return }
        if delayedTapWorkItem != nil {
            delayedTapWorkItem?.cancel()
            delayedTapWorkItem = nil
            onDoubleTap?()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.onTap?()
            self?.delayedTapWorkItem = nil
        }
        delayedTapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func finishHold() {
        guard holdActive else { return }
        holdActive = false
        onHoldEnded?()
        DispatchQueue.main.async { [weak self] in self?.suppressTapFromHold = false }
    }

    func cancelHold() {
        delayedTapWorkItem?.cancel()
        delayedTapWorkItem = nil
        hold.isEnabled = false
        hold.isEnabled = true
        finishHold()
        resetTouchTracking()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelHold(); return }
        for scroll in enclosingScrollViews {
            // Keep the native delay so the scroll view decides whether this is
            // a pan before delivering a stationary tap to card content.
            scroll.delaysContentTouches = true
            scroll.canCancelContentTouches = true
        }
    }
}

private struct MediaEntryCard: View {
    @EnvironmentObject private var model: AppModel
    let entry: MediaEntry
    let height: CGFloat
    var isSelected = false
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    GeometryReader { proxy in
                        thumbnail
                            .frame(width: proxy.size.width, height: height)
                            .clipped()
                    }
                    .frame(height: height)
                    .clipped()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, MoonStyle.accent)
                            .padding(9)
                    }
                    Text(model.mediaStore.enabledSources.first(where: { $0.id == entry.source })?.name ?? MediaSource.defaults.first(where: { $0.kind == entry.platform })?.name ?? entry.platform)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                    Text(entry.author.isEmpty ? entry.platform : entry.author)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(isSelected ? MoonStyle.accent : .white.opacity(0.55), lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background { MediaCardHitAnchor(entryID: entry.id).allowsHitTesting(false).accessibilityHidden(true) }
        .modifier(NativeMediaCardInteractions(
            holdEnabled: model.cardLongPressEnabled,
            onTap: onSelect,
            onHold: {
                LongPressHapticFeedback.shared.menuOpened()
                let location = MediaCardHitRegistry.center(for: entry.id) ?? CGPoint(x: 180, y: 360)
                activateLongPress(at: location)
                finishLongPress()
            }
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityIdentifier("media-card-\(entry.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }

    private func activateLongPress(at location: CGPoint) {
        model.activeLongPressMenu = ActiveLongPressMenu(entry: entry, location: location, fingerLocation: location)
    }

    private func finishLongPress() {
        if var menu = model.activeLongPressMenu, menu.entry?.id == entry.id {
            menu.fingerDown = false
            model.activeLongPressMenu = menu
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if entry.kind == .image, let url = entry.remoteURL, url.isFileURL {
            LocalMediaImage(url: url, fill: true)
        } else if entry.kind == .video, let url = entry.remoteURL, url.isFileURL {
            LocalVideoPoster(url: url)
        } else if let url = entry.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: fallback
                case .empty: ZStack { fallback; ProgressView().tint(.white) }
                @unknown default: fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        LinearGradient(colors: [MoonStyle.accent.opacity(0.72), Color.indigo.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "play.rectangle.fill").font(.system(size: 32)).foregroundStyle(.white.opacity(0.75)))
    }
}

private struct LocalVideoPoster: View {
    let url: URL
    @State private var poster: UIImage?
    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [MoonStyle.accent.opacity(0.65), .indigo.opacity(0.36)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            if let result = try? await generator.image(at: .zero) { poster = UIImage(cgImage: result.image) }
        }
    }
}

struct MediaPlayerView: View {
    let entry: MediaEntry
    let onShareToMoments: () -> Void
    let onQueueAdvance: (MediaEntry) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var controlsVisible = true
    @State private var currentTime = 0.0
    @State private var duration = 1.0
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                if entry.kind == .embed, let url = entry.embedURL {
                    WebEmbedView(url: url)
                } else if entry.kind == .video, let player {
                    FillVideoPlayer(player: player, showsControls: false)
                } else if entry.kind == .video {
                    ProgressView().tint(.white)
                } else if entry.kind == .image, let url = entry.remoteURL {
                    FullBleedImage(url: url)
                } else if let url = entry.coverURL ?? entry.remoteURL {
                    FullBleedImage(url: url)
                } else {
                    EmptyPanel(title: "无法打开内容", detail: "这个条目没有可用的媒体地址。", symbol: "exclamationmark.triangle")
                        .padding(24)
                }
            }
            .ignoresSafeArea()
            // Exit remains available even when immersive controls fade.
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline.weight(.bold))
                            .frame(width: 46, height: 46)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("退出播放")
                    .accessibilityIdentifier("player-close")
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 10)
                Spacer()
            }
            if controlsVisible {
            VStack {
                HStack(spacing: 12) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    // Keep a first-party fallback when YouTube declines an
                    // embedded WebView client (for example Error 153).
                    if entry.platform == "youtube", let url = entry.remoteURL {
                        Link(destination: url) {
                            Image(systemName: "play.rectangle.fill")
                        }
                        .accessibilityLabel("在 YouTube 打开")
                    }
                    if entry.kind != .embed, let url = entry.remoteURL,
                       ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        Button {
                            Task { await model.mediaStore.downloadDirectFile(entry) }
                        } label: {
                            if model.mediaStore.downloadingIDs.contains(entry.id) { ProgressView() }
                            else { Image(systemName: "arrow.down.to.line") }
                        }.accessibilityLabel("下载")
                    }
                    Button { onShareToMoments(); dismiss() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }.accessibilityLabel("朋友圈")
                    if !model.mediaStore.queueItems.isEmpty {
                        Button {
                            if let next = model.mediaStore.nextQueued(after: entry) { onQueueAdvance(next) }
                        } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("播放队列下一条")
                    }
                }
                .padding(12)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
                Spacer()
                if entry.kind == .video, player != nil {
                    VStack(spacing: 7) {
                        HStack {
                            Text(playerClock(currentTime)).monospacedDigit().font(.caption.weight(.semibold))
                            Spacer()
                            Text(playerClock(duration)).monospacedDigit().font(.caption.weight(.semibold))
                        }
                        PlayerTimeline(value: $currentTime, duration: max(1, duration), isScrubbing: $isScrubbing) { seconds in
                            player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                        }
                        .frame(height: 52)
                        .accessibilityLabel("播放进度")
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                }
            }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { controlsVisible.toggle() } }
        .preferredColorScheme(.dark)
        .task(id: entry.id) {
            if entry.kind == .video, let url = entry.remoteURL {
                player = AVPlayer(url: url)
                let resume = model.mediaStore.resumePosition(for: entry)
                if resume > 0 { player?.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
                player?.play()
            } else {
                model.mediaStore.markOpened(entry)
            }
        }
        .task(id: "playback-clock-\(entry.id)") {
            while !Task.isCancelled {
                if !isScrubbing, let player {
                    let itemDuration = player.currentItem?.duration.seconds ?? 0
                    if itemDuration.isFinite && itemDuration > 0 { duration = itemDuration }
                    let time = player.currentTime().seconds
                    if time.isFinite && time >= 0 { currentTime = min(time, max(1, duration)) }
                }
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
        .task(id: "controls-\(entry.id)") {
            // UI fixtures include embedded and remote cards whose content
            // surface may legitimately consume a synthetic tap. Keep the
            // navigation controls available for that regression harness; the
            // shipped player still enters its normal immersive auto-hide mode.
            guard !ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests") else { return }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            model.mediaStore.recordPlayback(entry, position: max(0, item.duration.seconds), duration: item.duration.seconds)
            if let next = model.mediaStore.nextQueued(after: entry) { onQueueAdvance(next) }
        }
        .onAppear {
            MoonlightOrientationDelegate.playerAllowsLandscape = !model.portraitPlaybackOnly
        }
        .onDisappear {
            if let player {
                let duration = player.currentItem?.duration.seconds ?? 0
                model.mediaStore.recordPlayback(entry, position: player.currentTime().seconds, duration: duration)
            }
            player?.pause(); player = nil
            MoonlightOrientationDelegate.playerAllowsLandscape = false
        }
    }

    private func playerClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
}

private struct PlayerTimeline: UIViewRepresentable {
    @Binding var value: Double
    let duration: Double
    @Binding var isScrubbing: Bool
    let onSeek: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    func makeUIView(context: Context) -> ExpandedPlaybackSlider {
        let slider = ExpandedPlaybackSlider()
        slider.minimumTrackTintColor = .systemPink
        slider.maximumTrackTintColor = .systemGray3
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchDown(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.touchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: ExpandedPlaybackSlider, context: Context) {
        context.coordinator.owner = self
        slider.minimumValue = 0
        slider.maximumValue = Float(max(1, duration))
        if !isScrubbing { slider.value = Float(min(value, duration)) }
    }
    final class Coordinator: NSObject {
        var owner: PlayerTimeline
        init(owner: PlayerTimeline) { self.owner = owner }
        @objc func touchDown(_ sender: UISlider) { owner.isScrubbing = true }
        @objc func changed(_ sender: UISlider) {
            owner.value = Double(sender.value)
            owner.onSeek(Double(sender.value))
        }
        @objc func touchUp(_ sender: UISlider) {
            owner.onSeek(Double(sender.value))
            owner.isScrubbing = false
        }
    }
}

private final class ExpandedPlaybackSlider: UISlider {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -22).contains(point)
    }
}

struct FillVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsControls = false
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.videoGravity = .resizeAspectFill
        controller.showsPlaybackControls = showsControls
        controller.view.backgroundColor = .black
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.videoGravity = .resizeAspectFill
        controller.showsPlaybackControls = showsControls
    }
}

struct FullBleedImage: View {
    let url: URL
    var body: some View {
        GeometryReader { geometry in
            Group {
                if url.isFileURL { LocalMediaImage(url: url, fill: true) }
                else {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                        placeholder: { ProgressView().tint(.white) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .background(.black)
    }
}

struct WebEmbedView: UIViewRepresentable {
    let url: URL
    var scrolling = true

    final class Coordinator { var requestedURL: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private func isYouTubeEmbed(_ value: URL) -> Bool {
        let host = value.host?.lowercased() ?? ""
        return (host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com"))
            && value.path.hasPrefix("/embed/")
    }

    private func escapedHTMLURL(_ value: URL) -> String {
        value.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func load(_ value: URL, in view: WKWebView) {
        guard isYouTubeEmbed(value) else {
            view.load(URLRequest(url: value))
            return
        }

        // A direct /embed request from WKWebView has no document context and
        // can be rejected by YouTube as Error 153. Use the documented iframe
        // player in a page context while retaining inline playback.
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>html,body,iframe{margin:0;width:100%;height:100%;background:#000;border:0;overflow:hidden}</style></head>
        <body><iframe src="\(escapedHTMLURL(value))" title="YouTube video player" allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen></iframe></body></html>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com/"))
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.applicationNameForUserAgent = "MoonDan/1.1"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.underPageBackgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.scrollView.isScrollEnabled = scrolling
        context.coordinator.requestedURL = url
        load(url, in: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        view.scrollView.isScrollEnabled = scrolling
        if context.coordinator.requestedURL != url {
            context.coordinator.requestedURL = url
            load(url, in: view)
        }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(function(v){v.pause()})", completionHandler: nil)
        view.stopLoading(); view.loadHTMLString("", baseURL: nil)
    }
}

private struct YouTubeSearchFallback: View {
    let query: String
    private var searchURL: URL? {
        var components = URLComponents(string: "https://www.youtube.com/results")
        components?.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return components?.url
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("YouTube 网页搜索", systemImage: "globe")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let searchURL {
                Link(destination: searchURL) {
                    Label("在 YouTube 打开搜索", systemImage: "arrow.up.right.square")
                }.buttonStyle(MoonGlassButtonStyle())
                Text("App 内的 YouTube 关键词结果需要在内容源中配置 API Key。").font(.caption).foregroundStyle(.secondary)
            } else {
                EmptyPanel(title: "搜索链接无效", detail: "请检查搜索词后重试。", symbol: "exclamationmark.triangle")
            }
        }
    }
}

private struct MomentsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let onSelect: (MediaEntry) -> Void
    let onCompose: () -> Void
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    @State private var avatarSelection: PhotosPickerItem?
    @State private var coverSelection: PhotosPickerItem?
    @State private var avatarPickerPresented = false
    @State private var coverPickerPresented = false
    @State private var commentTargetID: String?
    @State private var commentDraft = ""
    @State private var showingCommentPrompt = false
    @State private var deletingMoment: String?
    @State private var momentActionsID: String?
    @State private var activeVideoID: String?
    @State private var timelineFilter = "全部"
    @AppStorage("moonlight.glass.bannerSize") private var bannerSizeRaw = GlassSurfaceSize.balanced.rawValue
    private var bannerSize: GlassSurfaceSize { GlassSurfaceSize(rawValue: bannerSizeRaw) ?? .balanced }

    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ZStack(alignment: .bottomLeading) {
                    Button { coverPickerPresented = true } label: {
                        ProfileBackgroundMedia(target: .cover)
                        .frame(height: 190 * bannerSize.bannerScale).frame(maxWidth: .infinity).clipped()
                        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom))
                        .overlay(alignment: .topLeading) {
                            HStack {
                                Text("朋友圈").font(.title2.bold())
                                Spacer()
                            }.foregroundStyle(.white).padding(14)
                        }
                        .overlay(Color.clear.contentShape(Rectangle()))
                    }
                    .contentShape(Rectangle()).buttonStyle(.plain).accessibilityLabel("更换朋友圈横幅")
                    .photosPicker(isPresented: $coverPickerPresented, selection: $coverSelection, matching: .any(of: [.images, .videos]))
                    HStack(spacing: 12) {
                        Button { avatarPickerPresented = true } label: {
                            ProfileBackgroundMedia(target: .avatar)
                            .frame(width: 60, height: 60).clipShape(Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .overlay(Color.clear.contentShape(Circle()))
                        }.contentShape(Circle()).buttonStyle(.plain).accessibilityLabel("更换朋友圈头像")
                        .photosPicker(isPresented: $avatarPickerPresented, selection: $avatarSelection, matching: .any(of: [.images, .videos]))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName).font(.headline).foregroundStyle(.white)
                            Text("点击头像或横幅更换媒体").font(.caption).foregroundStyle(.white.opacity(0.82))
                        }
                        Spacer()
                        Button(action: onCompose) {
                            Image(systemName: "square.and.pencil").font(.title3).frame(width: 42, height: 42).moonGlassCircle()
                        }.accessibilityLabel("发布动态")
                    }.padding(14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                HStack {
                    Text("最近动态").font(.title3.bold())
                    Spacer()
                    Menu {
                        ForEach(["全部", "我的动态", "虚拟好友", "含媒体"], id: \.self) { option in
                            Button(option) { timelineFilter = option }
                        }
                    } label: { Label(timelineFilter, systemImage: "line.3.horizontal.decrease.circle") }
                    .buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
                }
                let filteredMoments = model.moments.filter { moment in
                    switch timelineFilter {
                    case "我的动态": return !moment.isVirtual
                    case "虚拟好友": return moment.isVirtual
                    case "含媒体": return moment.attachment != nil
                    default: return true
                    }
                }
                if filteredMoments.isEmpty {
                    EmptyPanel(title: "还没有动态", detail: "写下近况，发布后会保存在本机朋友圈。", symbol: "person.2")
                } else {
                    ForEach(filteredMoments) { moment in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                Group {
                                    if moment.isVirtual {
                                        Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                                            .foregroundStyle(MoonStyle.accent)
                                    } else {
                                        ProfileBackgroundMedia(target: .avatar, paused: true)
                                    }
                                }
                                .frame(width: 38, height: 38).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(moment.authorName).font(.subheadline.weight(.semibold))
                                    HStack(spacing: 6) {
                                        Text(moment.date.formatted(date: .abbreviated, time: .shortened))
                                        if moment.isVirtual { Text("虚拟好友") }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                            }
                            if !moment.text.isEmpty {
                                Text(moment.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if let attachment = moment.attachment {
                                Button { onSelect(attachment) } label: {
                                    MomentAttachmentPreview(entry: attachment, isPlaying: activeVideoID == moment.id && scenePhase == .active)
                                }
                                    .buttonStyle(.plain)
                                    .background {
                                        if attachment.kind == .video, attachment.remoteURL != nil {
                                            GeometryReader { geometry in
                                                Color.clear.preference(key: MomentVideoFramesKey.self,
                                                    value: [moment.id: geometry.frame(in: .named("moments-feed"))])
                                            }
                                        }
                                    }
                            }
                            HStack(spacing: 8) {
                                Button { model.toggleMomentLike(moment.id) } label: {
                                    Label("\(moment.likes)", systemImage: moment.likedByMe ? "heart.fill" : "heart")
                                }
                                .foregroundStyle(moment.likedByMe ? .pink : MoonStyle.accent).accessibilityIdentifier("moment-like-\(moment.id)")
                                if !moment.comments.isEmpty {
                                    Button {
                                        commentTargetID = moment.id
                                        showingCommentPrompt = true
                                    } label: {
                                        Label("\(moment.comments.count)", systemImage: "bubble.right")
                                    }.foregroundStyle(.secondary).accessibilityIdentifier("moment-comment-\(moment.id)")
                                } else {
                                    Button {
                                        commentTargetID = moment.id
                                        showingCommentPrompt = true
                                    } label: { Label("评论", systemImage: "bubble.right") }
                                        .foregroundStyle(.secondary).accessibilityIdentifier("moment-comment-\(moment.id)")
                                }
                                if moment.reposts > 0 {
                                    Label("\(moment.reposts)", systemImage: "arrow.2.squarepath")
                                        .foregroundStyle(.secondary)
                                }
                                Button { model.repostMoment(moment.id) } label: {
                                    Image(systemName: "arrow.2.squarepath")
                                }.foregroundStyle(.secondary).accessibilityLabel("转发动态")
                            }.font(.subheadline)
                            if let comment = moment.comments.last {
                                Text("\(moment.isVirtual ? "好友评论" : "评论")：\(comment)")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                        .contentShape(RoundedRectangle(cornerRadius: 22))
                        .accessibilityElement(children: .contain)
                        // This is deliberately simultaneous: a vertical drag
                        // remains owned by the feed, while a stationary hold
                        // opens actions that are specific to this post.
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.48, maximumDistance: 7).onEnded { _ in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            momentActionsID = moment.id
                        })
                        .accessibilityIdentifier("moment-post-card-\(moment.id)")
                        .transition(.opacity)
                    }
                }
            }.frame(width: max(0, viewport.size.width - 36))
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 96)
        }.coordinateSpace(name: "moments-feed")
            .onPreferenceChange(MomentVideoFramesKey.self) { frames in
                let visible = CGRect(x: 0, y: 0, width: viewport.size.width, height: max(0, viewport.size.height - 80))
                activeVideoID = frames.map { (id: $0.key, area: $0.value.intersection(visible).height) }
                    .filter { $0.area > 100 }
                    .max(by: { $0.area < $1.area })?.id
            }
            .scrollIndicators(.hidden).pageBackground(.moments)
            .task(id: model.command?.id) {
                if model.command?.action == .avatar { avatarPickerPresented = true; model.command = nil }
                if model.command?.action == .cover { coverPickerPresented = true; model.command = nil }
            }
            .task(id: avatarSelection) {
                if let path = await saveProfileMedia(avatarSelection, name: "avatar") { avatarPath = path }
            }
            .task(id: coverSelection) {
                if let path = await saveProfileMedia(coverSelection, name: "cover") { coverPath = path }
            }
            .alert("评论动态", isPresented: $showingCommentPrompt) {
                TextField("写下评论…", text: $commentDraft)
                Button("取消", role: .cancel) { commentDraft = "" }
                Button("发送") {
                    if let commentTargetID { model.addMomentComment(commentTargetID, text: commentDraft) }
                    commentDraft = ""
                }.disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("动态操作", isPresented: Binding(get: { momentActionsID != nil }, set: { if !$0 { momentActionsID = nil } }), titleVisibility: .visible) {
                if let id = momentActionsID, let moment = model.moments.first(where: { $0.id == id }) {
                    Button(moment.likedByMe ? "取消点赞" : "点赞") { model.toggleMomentLike(id); momentActionsID = nil }
                    Button("评论") { commentTargetID = id; commentDraft = ""; momentActionsID = nil; showingCommentPrompt = true }
                    Button("转发") { model.repostMoment(id); momentActionsID = nil }
                    if !moment.isVirtual {
                        Button("删除动态", role: .destructive) { deletingMoment = id; momentActionsID = nil }
                    }
                }
                Button("取消", role: .cancel) { momentActionsID = nil }
            } message: {
                Text("点赞、评论和转发会作用于当前这条动态；只有自己的动态可以删除。")
            }
            .confirmationDialog("删除这条朋友圈动态？", isPresented: Binding(get: { deletingMoment != nil }, set: { if !$0 { deletingMoment = nil } }), titleVisibility: .visible) {
                Button("删除动态", role: .destructive) {
                    if let id = deletingMoment { model.deleteMoment(id) }
                    deletingMoment = nil
                }.buttonStyle(.automatic).accessibilityIdentifier("confirm-delete-moment")
                Button("取消", role: .cancel) { deletingMoment = nil }
            }
        }
    }
}

private struct MomentVideoFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private func saveProfileMedia(_ item: PhotosPickerItem?, name: String) async -> String? {
    guard let item else { return nil }
    let store = BackgroundStore.shared
    guard let asset = try? await store.importSelection(item, for: name == "avatar" ? .avatar : .cover) else { return nil }
    return store.url(for: asset).path
}

private struct MomentAttachmentPreview: View {
    let entry: MediaEntry
    var isPlaying = false
    var body: some View {
        GeometryReader { bounds in
        ZStack(alignment: .bottomLeading) {
            if entry.kind == .image, let url = entry.remoteURL, url.isFileURL {
                LocalMediaImage(url: url, fill: true).frame(width: bounds.size.width, height: 210).clipped()
            } else if entry.kind == .video, let url = entry.remoteURL {
                if isPlaying {
                    MomentInlineVideo(url: url, isPlaying: true)
                        .frame(width: bounds.size.width, height: 210).clipped()
                } else if url.isFileURL {
                    LocalVideoPoster(url: url).frame(width: bounds.size.width, height: 210).clipped()
                } else if let cover = entry.coverURL {
                    AsyncImage(url: cover) { image in image.resizable().scaledToFill() } placeholder: { attachmentFallback }
                        .frame(width: bounds.size.width, height: 210).clipped()
                } else { attachmentFallback.frame(height: 210) }
            } else if let cover = entry.coverURL {
                AsyncImage(url: cover) { image in image.resizable().scaledToFill() } placeholder: { attachmentFallback }
                    .frame(width: bounds.size.width, height: 210).clipped()
            } else { attachmentFallback.frame(height: 210) }
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.platform == "bili" ? "哔哩哔哩" : entry.platform == "youtube" ? "YouTube" : "月淡库")
                    .font(.caption.weight(.semibold))
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }.foregroundStyle(.white).padding(12)
            if entry.kind == .image || !isPlaying {
                Image(systemName: entry.kind == .image ? "photo" : "play.fill")
                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            }
        }
        .frame(width: bounds.size.width, height: 210).clipped()
        }.frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.16), value: isPlaying)
    }
    private var attachmentFallback: some View {
        LinearGradient(colors: [MoonStyle.accent.opacity(0.72), .indigo.opacity(0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.white.opacity(0.82)))
    }
}

private struct MomentInlineVideo: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    func makeUIView(context: Context) -> MomentInlineVideoView { MomentInlineVideoView() }
    func updateUIView(_ view: MomentInlineVideoView, context: Context) { view.configure(url: url, playing: isPlaying) }
    static func dismantleUIView(_ view: MomentInlineVideoView, coordinator: ()) { view.stop() }
}

private final class MomentInlineVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentURL: URL?
    private var playing = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        (layer as? AVPlayerLayer)?.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(url: URL, playing: Bool) {
        if currentURL != url {
            stop()
            currentURL = url
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            player = queue
            (layer as? AVPlayerLayer)?.player = queue
        }
        self.playing = playing
        if playing && window != nil { player?.play() } else { player?.pause() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if playing && window != nil { player?.play() } else { player?.pause() }
    }
    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()
        player = nil
        currentURL = nil
        playing = false
        (layer as? AVPlayerLayer)?.player = nil
    }
}

private struct MomentComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var attachment: MediaEntry?
    let initialAttachment: MediaEntry?
    let onPublish: (String, MediaEntry?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("此刻") { TextField("分享此刻…", text: $text, axis: .vertical).lineLimit(3...7) }
                Section("照片或视频") {
                    if let attachment {
                        MomentAttachmentPreview(entry: attachment).frame(height: 180)
                        Button("移除附件", role: .destructive) { self.attachment = nil }
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .any(of: [.images, .videos])) {
                        Label("选择照片或视频", systemImage: "photo.badge.plus")
                    }
                }
                if initialAttachment != nil {
                    Section { Text("来自内容流的条目会以可打开的链接预览显示在动态中。").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("发布动态")
            .scrollContentBackground(.hidden).pageBackground(.composer)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") {
                        onPublish(text.trimmingCharacters(in: .whitespacesAndNewlines), attachment)
                        dismiss()
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil)
                }
            }
            .task { if attachment == nil { attachment = initialAttachment } }
            .task(id: photoPickerItem) { await loadAttachment() }
        }
    }

    @MainActor private func loadAttachment() async {
        guard let photoPickerItem, let data = try? await photoPickerItem.loadTransferable(type: Data.self) else { return }
        if let image = UIImage(data: data) {
            attachment = model.mediaStore.importMedia(data, title: "朋友圈照片", kind: .image, fileExtension: photoPickerItem.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg")
            _ = image
        } else if let type = photoPickerItem.supportedContentTypes.first, type.conforms(to: .movie) {
            attachment = model.mediaStore.importMedia(data, title: "朋友圈视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
        }
    }
}

private struct MeView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.bio") private var profileBio = "分享生活里的灵感"
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    let selectedImage: Image?
    @Binding var selection: PhotosPickerItem?
    let onSelect: (MediaEntry) -> Void
    @State private var commandPath = NavigationPath()
    var body: some View {
        NavigationStack(path: $commandPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: "我", subtitle: "个人空间", symbol: "person.crop.circle") {
                        NavigationLink(value: AppCommand.settings) {
                            Image(systemName: "gearshape").font(.title3).frame(width: 42, height: 42).moonGlassCircle()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-entry")
                    }
                    if !coverPath.isEmpty {
                        ProfileBackgroundMedia(target: .cover).frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                    NavigationLink(value: AppCommand.profile) {
                        HStack(spacing: 14) {
                            ProfileBackgroundMedia(target: .avatar).frame(width: 58, height: 58).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(displayName).font(.title3.bold()).foregroundStyle(.primary)
                                Text(profileBio).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain)
                    HStack(spacing: 10) {
                        StatCard(value: "\(model.moments.count)", label: "动态")
                        StatCard(value: "\(VirtualFriendRoster.names.count)", label: "好友")
                        StatCard(value: "\(model.mediaStore.items.count)", label: "库")
                        StatCard(value: "\(model.mediaStore.items.filter(\.isFavorite).count)", label: "收藏")
                    }
                    VStack(spacing: 0) {
                        NavigationLink(value: AppCommand.library) { MenuRow(symbol: "square.grid.2x2.fill", title: "库", color: .orange) }
                        Divider().padding(.leading, 56)
                        NavigationLink(value: AppCommand.friends) { MenuRow(symbol: "person.2.fill", title: "朋友", color: .green) }
                        Divider().padding(.leading, 56)
                        NavigationLink(value: AppCommand.messages) { MenuRow(symbol: "bubble.left.and.bubble.right.fill", title: "消息", color: .purple) }
                    }
                    .buttonStyle(.plain).padding(.horizontal, 14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 96)
            }
            .scrollIndicators(.hidden)
            .pageBackground(.me)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppCommand.self) { action in
                switch action {
                case .settings: SettingsView()
                case .profile: ProfileEditView()
                case .friends: VirtualFriendsView(onSelect: onSelect)
                case .messages: VirtualMessagesView()
                default: LibraryView(selectedImage: selectedImage, selection: $selection, onPlay: onSelect, initialAction: action)
                }
            }
        }
        .task(id: model.command?.id) {
            guard let action = model.command?.action,
                  [.library, .selectAll, .favorites, .downloads, .settings, .friends, .messages, .profile].contains(action) else { return }
            commandPath = NavigationPath([action])
            model.command = nil
        }
    }
}

private struct VirtualFriendsView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    var body: some View {
        List {
            Section("虚拟好友 · 本机") {
                ForEach(Array(VirtualFriendRoster.names.enumerated()), id: \.offset) { item in
                    let index = item.offset
                    let name = item.element
                    NavigationLink {
                        ScrollView {
                            VStack(spacing: 14) {
                                ForEach(model.moments.filter { $0.authorName == name }) { post in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text(post.text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                                        if let entry = post.attachment {
                                            Button { onSelect(entry) } label: { MomentAttachmentPreview(entry: entry) }.buttonStyle(.plain)
                                        }
                                        Label("\(post.likes) 赞 · \(post.comments.count) 评论 · \(post.reposts) 转发", systemImage: "heart")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                                }
                                if model.moments.allSatisfy({ $0.authorName != name }) {
                                    EmptyPanel(title: "还没有动态", detail: "开启虚拟好友自动动态后，这里会显示其分享。", symbol: "person.crop.circle")
                                }
                            }.padding(16)
                        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline).pageBackground(.friends)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.system(size: 38))
                                .foregroundStyle([Color.blue, .orange, .purple, .pink, .teal, .green][index % 6])
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name).font(.body.weight(.semibold))
                                Text(model.moments.first(where: { $0.authorName == name })?.date.formatted(.relative(presentation: .named)) ?? "等待分享")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.navigationTitle("朋友").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).pageBackground(.friends)
    }
}

private struct VirtualMessagesView: View {
    @EnvironmentObject private var model: AppModel
    private var recentInteractions: [MomentPost] { model.moments.filter { $0.isVirtual && !$0.comments.isEmpty } }
    var body: some View {
        List {
            if recentInteractions.isEmpty {
                EmptyPanel(title: "还没有新消息", detail: "虚拟好友发布动态或评论后，互动摘要会显示在这里。", symbol: "bubble.left.and.bubble.right")
            } else {
                ForEach(recentInteractions) { post in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(post.authorName).font(.subheadline.weight(.semibold))
                        Text(post.comments.last ?? post.text).font(.body).lineLimit(2)
                        Text(post.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle("消息").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).pageBackground(.messages)
    }
}

private struct ProfileEditView: View {
    @State private var avatar: PhotosPickerItem?
    @State private var cover: PhotosPickerItem?
    @AppStorage("moonlight.profile.avatarPath") private var avatarPath = ""
    @AppStorage("moonlight.profile.coverPath") private var coverPath = ""
    @AppStorage("moonlight.profile.displayName") private var displayName = "我的朋友"
    @AppStorage("moonlight.profile.bio") private var profileBio = "分享生活里的灵感"

    var body: some View {
        Form {
            Section("个人资料") {
                TextField("昵称", text: $displayName).textInputAutocapitalization(.never)
                TextField("签名", text: $profileBio, axis: .vertical).lineLimit(1...3)
            }
            Section("个人头像") {
                ProfileBackgroundMedia(target: .avatar).frame(width: 88, height: 88).clipShape(Circle())
                PhotosPicker(selection: $avatar, matching: .any(of: [.images, .videos])) {
                    Label("选择头像照片或视频", systemImage: "person.crop.circle")
                }
                NavigationLink("调整头像画面与背景") { BackgroundEditorView(target: .avatar) }
            }
            Section("顶部封面") {
                ProfileBackgroundMedia(target: .cover).frame(height: 130).clipShape(RoundedRectangle(cornerRadius: 16))
                PhotosPicker(selection: $cover, matching: .any(of: [.images, .videos])) {
                    Label("选择顶部封面照片或视频", systemImage: "rectangle.fill")
                }
                NavigationLink("调整顶部横幅画面与背景") { BackgroundEditorView(target: .cover) }
            }
        }.navigationTitle("编辑资料").scrollContentBackground(.hidden).pageBackground(.profile)
            .task(id: avatar) { await save(avatar, key: "avatar") }
            .task(id: cover) { await save(cover, key: "cover") }
    }

    @MainActor
    private func save(_ item: PhotosPickerItem?, key: String) async {
        guard let path = await saveProfileMedia(item, name: key) else { return }
        if key == "avatar" { avatarPath = path } else { coverPath = path }
    }
}

private func isMoviePath(_ path: String) -> Bool {
    ["mov", "mp4", "m4v", "mpeg", "mpg"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
}

private struct CameraView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCamera = false
    @State private var showPicker = false
    @State private var captureVideo = false
    @State private var capturedImage: UIImage?
    @State private var cameraError: String?
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                PageHeader(title: "拍摄", subtitle: "捕捉此刻", symbol: "camera")
                if let capturedImage {
                    Image(uiImage: capturedImage).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .frame(maxHeight: 420)
                    Button {
                        if let data = capturedImage.jpegData(compressionQuality: 0.92) {
                            model.mediaStore.importImage(data, title: "拍摄的照片")
                        }
                        self.capturedImage = nil
                    } label: {
                        Label("保存到库", systemImage: "square.and.arrow.down")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(MoonGlassButtonStyle(prominent: true)).tint(MoonStyle.accent)
                } else {
                    EmptyPanel(title: "准备好记录此刻了吗？", detail: "拍摄或从照片图库导入，内容会保存到库。", symbol: "camera")
                    Button {
                        captureVideo = false
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { cameraError = "当前设备没有可用的相机，请从照片图库导入。" }
                    } label: {
                        Label("打开相机", systemImage: "camera.fill")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }.buttonStyle(MoonGlassButtonStyle(prominent: true)).tint(MoonStyle.accent)
                    Button {
                        captureVideo = true
                        if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                        else { cameraError = "当前设备没有可用的相机，请从照片图库导入视频。" }
                    } label: {
                        Label("录制视频", systemImage: "video.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(MoonGlassButtonStyle())
                    Button { showPicker = true } label: {
                        Label("从照片图库导入", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(MoonGlassButtonStyle())
                }
            }
            .padding(.horizontal, 18).padding(.top, 12)
            .alert("提示", isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
                Button("好", role: .cancel) { cameraError = nil }
            } message: { Text(cameraError ?? "") }
            .sheet(isPresented: $showCamera) {
                CameraCaptureView(captureVideo: captureVideo, onCapture: { image in
                    capturedImage = image
                }, onCaptureVideo: { url in
                    model.mediaStore.importVideoFile(url, title: "拍摄的视频")
                })
                    .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPicker, selection: $selectedPhoto, matching: .any(of: [.images, .videos]))
            .task(id: selectedPhoto) {
                guard let selectedPhoto,
                      let data = try? await selectedPhoto.loadTransferable(type: Data.self) else { return }
                if let image = UIImage(data: data) { capturedImage = image }
                else if let type = selectedPhoto.supportedContentTypes.first, type.conforms(to: .movie) {
                    model.mediaStore.importMedia(data, title: "导入的视频", kind: .video, fileExtension: type.preferredFilenameExtension ?? "mov")
                }
            }
        }
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let captureVideo: Bool
    let onCapture: (UIImage) -> Void
    let onCaptureVideo: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture, onCaptureVideo: onCaptureVideo, dismiss: dismiss) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [captureVideo ? UTType.movie.identifier : UTType.image.identifier]
        picker.cameraCaptureMode = captureVideo ? .video : .photo
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 300
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCaptureVideo: (URL) -> Void
        let dismiss: DismissAction
        init(onCapture: @escaping (UIImage) -> Void, onCaptureVideo: @escaping (URL) -> Void, dismiss: DismissAction) {
            self.onCapture = onCapture; self.onCaptureVideo = onCaptureVideo; self.dismiss = dismiss
        }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onCapture(image) }
            if let url = info[.mediaURL] as? URL { onCaptureVideo(url) }
            dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { dismiss() }
    }
}

private struct LibraryView: View {
    let selectedImage: Image?
    @Binding var selection: PhotosPickerItem?
    let onPlay: (MediaEntry) -> Void
    var initialAction: AppCommand? = nil
    @EnvironmentObject private var model: AppModel
    @State private var selectionMode = false
    @State private var selectedIDs = Set<String>()
    @State private var filter = "全部"
    @State private var selectedFolderID: String?
    @State private var folderName = ""
    @State private var showingCreateFolder = false
    @State private var showingRenameFolder = false
    @State private var showingDeleteFolder = false
    @State private var reelsFolder: LibraryFolder?
    @State private var reelsQueue = false
    @State private var reelsSmartPlaylist: SmartPlaylistKind?
    @State private var showingTreasureMap = false
    @State private var folderImportSelection: PhotosPickerItem?

    private var selectedFolder: LibraryFolder? {
        model.mediaStore.folders.first { $0.id == selectedFolderID }
    }

    private var visibleItems: [MediaEntry] {
        if let selectedFolderID {
            return model.mediaStore.items.filter { model.mediaStore.folderAssignments[$0.id] == selectedFolderID }
        }
        switch filter {
        case "收藏": return model.mediaStore.items.filter(\.isFavorite)
        case "下载": return model.mediaStore.items.filter { $0.source == "download" }
        case "继续观看": return model.mediaStore.continueWatching
        case "未观看": return model.mediaStore.unwatchedItems
        default: return model.mediaStore.items
        }
    }

    private var canDownloadSelection: Bool {
        visibleItems.contains { entry in
            guard selectedIDs.contains(entry.id), entry.kind != .embed,
                  let scheme = entry.remoteURL?.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
    }

    var body: some View {
        ScrollView { libraryContent.padding(.top, 24) }.scrollIndicators(.hidden).pageBackground(.library)
            .navigationTitle("库")
            .alert("新建文件夹", isPresented: $showingCreateFolder) {
                TextField("文件夹名称", text: $folderName)
                Button("创建") {
                    if let folder = model.mediaStore.createFolder(named: folderName) { selectedFolderID = folder.id }
                    folderName = ""
                }
                Button("取消", role: .cancel) { folderName = "" }
            } message: { Text("把想看的内容归纳在一起。") }
            .alert("重命名文件夹", isPresented: $showingRenameFolder) {
                TextField("文件夹名称", text: $folderName)
                Button("保存") {
                    if let selectedFolder { model.mediaStore.renameFolder(selectedFolder, to: folderName) }
                }
                Button("取消", role: .cancel) { }
            }
            .confirmationDialog("删除文件夹？", isPresented: $showingDeleteFolder) {
                Button("删除文件夹", role: .destructive) {
                    if let selectedFolder { model.mediaStore.deleteFolder(selectedFolder) }
                    selectedFolderID = nil
                }
            } message: { Text("媒体仍保留在库中，只取消文件夹分类。") }
            .fullScreenCover(item: $reelsFolder) { folder in
                ReelsView(source: .folder(folder.id)).environmentObject(model)
            }
            .fullScreenCover(isPresented: $reelsQueue) {
                ReelsView(source: .queue).environmentObject(model)
            }
            .fullScreenCover(item: $reelsSmartPlaylist) { playlist in
                ReelsView(source: .smart(playlist)).environmentObject(model)
            }
            .sheet(isPresented: $showingTreasureMap) {
                NavigationStack { MoonTreasureMapView().environmentObject(model) }
            }
            .task(id: model.command?.id) {
                switch initialAction ?? model.command?.action {
                case .selectAll: selectionMode = true; selectedIDs = Set(visibleItems.map(\.id))
                case .favorites: filter = "收藏"
                case .downloads: filter = "下载"
                default: break
                }
            }
            .task(id: folderImportSelection) {
                await importIntoCurrentFolder()
            }
    }

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(selectionMode ? "取消" : "选择") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectionMode.toggle()
                        selectedIDs.removeAll()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MoonStyle.accent)
                if selectionMode {
                    Button("全选") { selectedIDs = Set(visibleItems.map(\.id)) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MoonStyle.accent)
                }
                Spacer()
                Text("库").font(.title2.bold())
                Spacer()
                Menu {
                    Button("打开月藏图") { showingTreasureMap = true }
                    Button("将当前列表加入队列") { model.mediaStore.enqueue(visibleItems) }
                    Button("替换播放队列") { model.mediaStore.enqueue(visibleItems, replacing: true) }
                    if !model.mediaStore.queueItems.isEmpty {
                        Button("播放队列") { reelsQueue = true }
                        Button("清空播放队列", role: .destructive) { model.mediaStore.clearQueue() }
                    }
                } label: {
                    Image(systemName: "text.badge.play").font(.subheadline.weight(.semibold))
                }.buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
                PhotosPicker(selection: $folderImportSelection, matching: .any(of: [.images, .videos])) {
                    Label(selectedFolder == nil ? "导入" : "导入到文件夹", systemImage: "plus").font(.subheadline.weight(.semibold))
                }.buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
            }
            if selectedFolder == nil {
                Button { showingTreasureMap = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles.rectangle.stack.fill")
                            .font(.title3).foregroundStyle(.yellow)
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.18), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("月藏图").font(.headline)
                            Text("把图片和视频堆进可拨动的月光宝库").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("打开").font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right").font(.caption.weight(.bold))
                    }
                    .padding(14)
                    .foregroundStyle(.primary)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-treasure-map")
                smartPlaylistSection
            }
            folderSection
            if let selectedFolder {
                HStack(spacing: 10) {
                    Button { selectedFolderID = nil; selectedIDs.removeAll(); selectionMode = false } label: {
                        Label("全部内容", systemImage: "chevron.left")
                    }
                    Spacer()
                    Button { reelsFolder = selectedFolder } label: {
                        Label("播放此文件夹", systemImage: "play.rectangle.fill")
                    }.disabled(visibleItems.isEmpty)
                    Menu {
                        Button("重命名") { folderName = selectedFolder.name; showingRenameFolder = true }
                        Button("删除文件夹", role: .destructive) { showingDeleteFolder = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }.font(.subheadline.weight(.medium)).buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
            } else {
                Menu {
                    ForEach(["全部", "继续观看", "未观看", "收藏", "下载"], id: \.self) { choice in
                        Button(choice) { filter = choice }
                    }
                } label: {
                    Label(filter, systemImage: "line.3.horizontal.decrease.circle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("library-filter-menu")
            }
            if selectionMode {
                VStack(spacing: 10) {
                    HStack {
                        Text("已选 \(selectedIDs.count) 项").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(model.mediaStore.folders) { folder in
                                Button(folder.name) { moveSelection(to: folder) }
                            }
                            if selectedFolderID != nil { Button("移出文件夹") { moveSelection(to: nil) } }
                        } label: { Label("移至文件夹", systemImage: "folder") }
                        .disabled(selectedIDs.isEmpty || model.mediaStore.folders.isEmpty)
                    }
                    HStack {
                        Button(filter == "收藏" && selectedFolderID == nil ? "取消收藏" : "收藏") {
                            withAnimation(.easeOut(duration: 0.2)) {
                                for entry in visibleItems where selectedIDs.contains(entry.id) {
                                    let shouldRemove = filter == "收藏" && selectedFolderID == nil
                                    if entry.isFavorite == shouldRemove { model.mediaStore.toggleFavorite(entry) }
                                }
                                selectedIDs.removeAll()
                            }
                        }
                        Button("下载") {
                            let chosen = visibleItems.filter { selectedIDs.contains($0.id) }
                            selectedIDs.removeAll()
                            Task { for entry in chosen { await model.mediaStore.downloadDirectFile(entry) } }
                        }
                        .disabled(!canDownloadSelection)
                        Spacer()
                        Button("删除", role: .destructive) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                for entry in visibleItems where selectedIDs.contains(entry.id) { model.mediaStore.delete(entry) }
                                selectedIDs.removeAll()
                            }
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                }.font(.subheadline.weight(.medium))
            }
            if visibleItems.isEmpty {
                if let selectedImage {
                    selectedImage.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    EmptyPanel(title: selectedFolder != nil ? "文件夹还是空的" : filter == "下载" ? "还没有下载内容" : "媒体会显示在这里", detail: selectedFolder != nil ? "返回全部内容，选择条目后移入此文件夹。" : "导入照片或视频，或从首页随机添加内容。", symbol: "photo.on.rectangle.angled")
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(visibleItems) { entry in
                        MediaEntryCard(entry: entry, height: 120, isSelected: selectedIDs.contains(entry.id)) {
                            if selectionMode {
                                if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) }
                                else { selectedIDs.insert(entry.id) }
                            } else { onPlay(entry) }
                        }
                        .transition(.opacity)
                        .overlay(alignment: .topLeading) {
                            if let progress = model.mediaStore.progress(for: entry), progress.position > 0, !progress.isFinished {
                                Text("继续 \(timeLabel(progress.position))")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(7)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
        .padding(.bottom, 72)
        .animation(.easeOut(duration: 0.22), value: visibleItems.map(\.id))
    }

    private func timeLabel(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("文件夹").font(.headline)
                Spacer()
                Button { folderName = ""; showingCreateFolder = true } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.semibold))
                }.buttonStyle(.plain).foregroundStyle(MoonStyle.accent)
            }
            if model.mediaStore.folders.isEmpty {
                Text("新建文件夹，将喜欢的内容放在一起。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(model.mediaStore.folders) { folder in
                        Button {
                            selectedFolderID = folder.id
                            selectionMode = false
                            selectedIDs.removeAll()
                        } label: {
                            folderCard(folder)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("library-folder-\(folder.id)")
                    }
                }
            }
        }
    }

    private var smartPlaylistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("智能片单").font(.headline)
                Spacer()
                Text("自动更新").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(SmartPlaylistKind.allCases) { playlist in
                        let count = model.mediaStore.items(for: playlist).count
                        Button { reelsSmartPlaylist = playlist } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Image(systemName: playlist.symbol).font(.headline)
                                    Spacer()
                                    Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                                }
                                Text(playlist.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(playlist.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(width: 142, height: 100, alignment: .leading)
                            .padding(12)
                            .foregroundStyle(.primary)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.32)))
                        }
                        .buttonStyle(.plain)
                        .disabled(count == 0)
                        .opacity(count == 0 ? 0.58 : 1)
                        .accessibilityIdentifier("smart-playlist-\(playlist.id)")
                    }
                }
            }
        }
    }

    private func folderCard(_ folder: LibraryFolder) -> some View {
        let contents = Array(model.mediaStore.items(in: folder).prefix(2))
        return ZStack(alignment: .bottomLeading) {
            HStack(spacing: 2) {
                ForEach(0..<2, id: \.self) { index in
                    Group {
                        if contents.indices.contains(index) {
                            folderThumbnail(contents[index])
                        } else {
                            LinearGradient(colors: [MoonStyle.accent.opacity(0.75), .indigo.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                }
            }
            .frame(height: 118).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 17, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text("\(model.mediaStore.items(in: folder).count) 项").font(.caption2).opacity(0.83)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white).padding(12)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selectedFolderID == folder.id ? MoonStyle.accent : .white.opacity(0.3), lineWidth: selectedFolderID == folder.id ? 2 : 0.7))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
        .accessibilityLabel("\(folder.name)，\(model.mediaStore.items(in: folder).count) 项")
    }

    @ViewBuilder
    private func folderThumbnail(_ entry: MediaEntry) -> some View {
        if let url = entry.coverURL ?? (entry.kind == .image ? entry.remoteURL : nil) {
            if url.isFileURL { LocalMediaImage(url: url, fill: true) }
            else {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                    placeholder: { Color.gray.opacity(0.4) }
            }
        } else {
            LinearGradient(colors: [.indigo.opacity(0.65), MoonStyle.accent.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func moveSelection(to folder: LibraryFolder?) {
        model.mediaStore.moveItems(selectedIDs, to: folder)
        selectedIDs.removeAll()
        selectionMode = false
    }

    @MainActor private func importIntoCurrentFolder() async {
        guard let picker = folderImportSelection,
              let data = try? await picker.loadTransferable(type: Data.self) else { return }
        let type = picker.supportedContentTypes.first
        let kind: MediaKind = type?.conforms(to: .movie) == true ? .video : .image
        let name = kind == .video ? "导入的视频" : "导入的照片"
        let ext = type?.preferredFilenameExtension ?? (kind == .video ? "mov" : "jpg")
        guard let entry = model.mediaStore.importMedia(data, title: name, kind: kind, fileExtension: ext) else { return }
        if let selectedFolder { model.mediaStore.moveItems([entry.id], to: selectedFolder) }
        folderImportSelection = nil
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
            Form {
                Section("外观与媒体") {
                    NavigationLink { ContextMenuSettingsView() } label: { Label("长按菜单与底栏", systemImage: "hand.point.up.left") }
                        .accessibilityIdentifier("context-menu-settings-entry")
                    NavigationLink { BackgroundSettingsView() } label: {
                        Label("背景与按键", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("backgrounds-entry")
                    Text("各页面、底部按键、长按圆环、头像和横幅的素材、应用范围及播放顺序统一在这里设置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("播放") {
                    Toggle("视频保持竖屏", isOn: $model.portraitPlaybackOnly)
                    Text(model.portraitPlaybackOnly ? "关闭后，视频播放页可跟随设备方向横屏。" : "横屏仅在视频播放页启用，其他页面保持竖屏。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("内容源") {
                    ForEach(model.mediaStore.enabledSources) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { model.mediaStore.enabledSources.first(where: { $0.id == source.id })?.enabled ?? false },
                            set: { model.mediaStore.setSourceEnabled(source.id, enabled: $0) }
                        ))
                    }
                }
                Section("智能对话") {
                    NavigationLink { AssistantSettingsView() } label: {
                        Label("智能体与 API", systemImage: "sparkles")
                    }
                    Text("输入栏模式可在“长按菜单与底栏”中切换。API Key 仅保存到本机钥匙串；建议使用项目密钥并设置额度限制。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("YouTube 搜索") {
                    SecureField("YouTube API Key", text: $model.mediaStore.youtubeAPIKeyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("安全保存 API Key") {
                        model.mediaStore.setYouTubeAPIKey(model.mediaStore.youtubeAPIKeyDraft)
                    }
                    Text("频道推荐不需 API Key；关键词搜索需要 YouTube Data API v3。密钥保存在本机 Keychain。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("长按菜单") {
                    Toggle("卡片长按交互", isOn: $model.cardLongPressEnabled)
                        .accessibilityIdentifier("card-long-press-toggle")
                    Text("关闭后卡片只保留点按和滚动，可用于判断实机停顿是否来自长按手势竞争。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("菜单样式", selection: $model.longPressStyle) {
                        ForEach(LongPressStyle.allCases) { style in Text(style.title).tag(style) }
                    }
                    Text("玻璃气泡分离会从长按位置的一侧依次弹出操作按键，并自动避开屏幕边缘。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("选择方式", selection: $model.longPressSelectionMode) {
                        ForEach(LongPressSelectionMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                }
                Section("圆环快捷键") {
                    NavigationLink("按页面和按键自定义操作") { ContextMenuSettingsView() }
                    Text("松开只会保留圆环，不会误触。点按模式需再点圆环按钮；拖动模式可划到按钮上松开执行。“…”打开完整操作面板，删除只在面板中。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("虚拟好友") {
                    Toggle("自动生成朋友圈动态", isOn: $model.virtualActivityEnabled)
                    Picker("发布间隔", selection: $model.virtualIntervalMinutes) {
                        ForEach([15, 30, 60, 240], id: \.self) { minutes in
                            Text(minutes < 60 ? "每 \(minutes) 分钟" : "每 \(minutes / 60) 小时").tag(minutes)
                        }
                    }.disabled(!model.virtualActivityEnabled)
                    Text("开启后会从已启用的内容源读取推荐条目，在应用前台按间隔生成本机动态，并模拟点赞、评论和转发。不会发布到外部社交平台。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("AI 文案服务", selection: $model.virtualAIProvider) {
                        ForEach(VirtualAIProvider.allCases) { provider in Text(provider.title).tag(provider) }
                    }
                    SecureField("\(model.virtualAIProvider.title) API Key（可选）", text: $model.virtualAIKeyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("安全保存 API Key") { model.saveVirtualAIKey() }
                    Text("密钥保存在本机钥匙串。启用后，仅把内容标题和作者发送给所选服务生成文案；未配置时使用本地模板。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("手势说明") {
                    Label("静止抬起才算点按；纵向滑动优先滚动", systemImage: "arrow.up.and.down")
                    Label("点按媒体卡片：打开播放或预览", systemImage: "hand.tap")
                    Label("长按有触感反馈和弹性展开；手指周围最多 4 个快捷键", systemImage: "hand.point.up.left")
                    Label("松开后圆环保留；点按按钮执行，或在设置中启用拖动选择", systemImage: "circle.grid.2x2")
                    Label("圆环中心“…”：打开播放、分享、保存、整理和删除面板", systemImage: "ellipsis.circle")
                    Label("点空白处或下滑：收起圆环", systemImage: "arrow.down")
                    Label("下拉首页或发现：刷新内容源", systemImage: "arrow.down")
                    Label("播放方向：可在播放设置中开启横屏", systemImage: "rectangle.landscape")
                }
            }
            .scrollContentBackground(.hidden)
            .pageBackground(.settings)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
    }
}


private struct GlobalSearchPresentation: Identifiable {
    let id = UUID()
    let location: CGPoint
}

private struct GlobalAssistantSearchOverlay: View {
    let presentation: GlobalSearchPresentation
    let onDismiss: () -> Void
    let onCommand: (AppCommand) -> Void
    let onChat: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }
    private var matches: [AppCommand] { AssistantCommands.matching(query) }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.12).ignoresSafeArea().onTapGesture(perform: onDismiss)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        AssistantProviderPicker()
                        TextField("搜索功能或询问 \(provider.title)", text: $query, axis: .vertical)
                            .lineLimit(1...3)
                            .focused($focused)
                            .submitLabel(.send)
                            .onSubmit { if !cleanQuery.isEmpty { onChat(cleanQuery) } }
                        Button(action: onDismiss) {
                            Image(systemName: "xmark").font(.footnote.weight(.bold))
                                .frame(width: 28, height: 28).background(.thinMaterial, in: Circle())
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.34)))

                    if !cleanQuery.isEmpty {
                        FlowLayout(spacing: 9) {
                            Button { onChat(cleanQuery) } label: {
                                Label("问 \(provider.title)", systemImage: "bubble.left.and.bubble.right.fill")
                            }.globalSearchBubble(tint: MoonStyle.accent)

                            ForEach(matches) { command in
                                Button { onCommand(command) } label: {
                                    Label(command.title, systemImage: command.symbol)
                                }.globalSearchBubble(tint: .blue)
                            }
                        }
                        .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                    }
                }
                .padding(16)
                .frame(width: min(proxy.size.width - 32, 430), alignment: .leading)
                .position(x: proxy.size.width / 2,
                          y: min(max(presentation.location.y, 138), max(138, proxy.size.height - 250)))
                .animation(.spring(response: 0.34, dampingFraction: 0.78), value: matches.map(\.rawValue))
            }
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .accessibilityIdentifier("global-assistant-search")
    }
}

private extension View {
    func globalSearchBubble(tint: Color) -> some View {
        self.font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.36)))
            .shadow(color: tint.opacity(0.18), radius: 9, y: 4)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


// A recognizer on the existing host sees completed taps, but never owns a
// full-screen transparent view or delays/cancels scrolling and controls.
private struct PageTapObserver: UIViewRepresentable {
    var onTap: () -> Void
    func makeUIView(context: Context) -> PageTapMarker { PageTapMarker() }
    func updateUIView(_ view: PageTapMarker, context: Context) {
        view.onTap = onTap
        view.install()
    }
    static func dismantleUIView(_ view: PageTapMarker, coordinator: ()) { view.detach() }
}

private final class PageTapMarker: UIView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    private let tap = UITapGestureRecognizer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        tap.addTarget(self, action: #selector(tapped))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); install() }
    func install() {
        guard window != nil else { detach(); return }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                if tap.view !== controller.view { detach(); controller.view.addGestureRecognizer(tap) }
                return
            }
            responder = current.next
        }
    }
    func detach() { tap.view?.removeGestureRecognizer(tap) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var ancestor = touch.view
        while let view = ancestor {
            if view is UITextField || view is UITextView || view is UIControl { return false }
            ancestor = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func tapped() { onTap?() }
}

private enum AssistantProvider: String, CaseIterable, Identifiable, Sendable {
    case openAI, doubao, gemini, grok
    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "GPT"
        case .doubao: "豆包"
        case .gemini: "Gemini"
        case .grok: "Grok"
        }
    }
    var endpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1/responses"
        case .doubao: "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .grok: "https://api.x.ai/v1/chat/completions"
        }
    }
    var keyAccount: String { self == .openAI ? "moonlight_openai_chat" : "moonlight_assistant_" + rawValue }
    var modelKey: String { self == .openAI ? "moonlight.assistant.model" : "moonlight.assistant.model." + rawValue }
    var configuredModel: String {
        UserDefaults.standard.string(forKey: modelKey) ?? (self == .openAI ? "gpt-4.1-mini" : "")
    }
    var modelHint: String { self == .doubao ? "豆包模型 ID 或 ep- 推理接入点" : "填写此账户已开通的模型 ID" }
}

private struct AssistantProviderPicker: View {
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    var body: some View {
        Menu {
            Picker("选择智能体", selection: $providerRaw) {
                ForEach(AssistantProvider.allCases) { provider in
                    Text(provider.title).tag(provider.rawValue)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text((AssistantProvider(rawValue: providerRaw) ?? .openAI).title)
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption.weight(.semibold))
                .padding(.horizontal, 10).frame(minHeight: 36)
                .background(.thinMaterial, in: Capsule())
        }
        .accessibilityLabel("选择智能体")
        .accessibilityIdentifier("assistant-provider")
    }
}

private enum AssistantCommands {
    static func matching(_ query: String) -> [AppCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        // Media-specific commands require a selected item; showing them in
        // page search would produce inert buttons.
        let available = AppCommand.allCases.filter { $0.mediaAction == nil }
        return Array(available.filter {
            $0.title.lowercased().contains(needle) || $0.rawValue.lowercased().contains(needle)
        }.sorted { lhs, rhs in
            if (lhs.title == needle) != (rhs.title == needle) { return lhs.title == needle }
            return lhs.title.count < rhs.title.count
        }.prefix(6))
    }
}

private struct AssistantLaunch: Identifiable {
    let id = UUID()
    let prompt: String
    let deepThinking: Bool
}

private struct AssistantDock: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    @State private var draft = ""
    @State private var deepThinking = false
    @FocusState private var focused: Bool
    var onFocusChange: (Bool) -> Void
    let onOpen: (String, Bool) -> Void
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }
    private var matches: [AppCommand] { focused ? AssistantCommands.matching(draft) : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if focused {
                HStack {
                    AssistantProviderPicker()
                    Spacer()
                    Button {
                        focused = false
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 36, height: 36)
                    }.accessibilityLabel("收起输入栏")
                }
            }
            if !matches.isEmpty {
                FlowLayout(spacing: 9) {
                    ForEach(matches) { command in
                        Button {
                            focused = false
                            draft = ""
                            model.send(command, context: "assistant-search")
                        } label: {
                            Label(command.title, systemImage: command.symbol)
                        }
                        .globalSearchBubble(tint: MoonStyle.accent)
                        .accessibilityIdentifier("assistant-command-" + command.rawValue)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                Menu {
                    Button { model.send(.photo) } label: { Label("相机", systemImage: "camera") }
                    Button { model.send(.importMedia) } label: { Label("照片或视频", systemImage: "photo") }
                    Divider()
                    Picker("智能体", selection: $providerRaw) {
                        ForEach(AssistantProvider.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("深入思考", isOn: $deepThinking)
                } label: {
                    Image(systemName: "plus").font(.title3.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.clear, in: Circle())
                }
                TextField("搜索功能或询问 \(provider.title)", text: $draft, axis: .vertical)
                    .focused($focused).lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send).onSubmit(submit)
                    .accessibilityIdentifier("assistant-input")
                Button(action: submit) {
                    Image(systemName: "arrow.up").font(.headline.weight(.bold))
                        .foregroundStyle(MoonStyle.accent).frame(width: 38, height: 38)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("发送给 " + provider.title)
            }
            .padding(8).background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.28)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: matches.map(\.rawValue))
        .animation(.easeOut(duration: 0.2), value: focused)
        // Keep the input and command bubbles as separate accessibility elements.
        .accessibilityElement(children: .contain)
        .onChange(of: focused) { onFocusChange($0) }
        .onDisappear { onFocusChange(false) }
        .onReceive(NotificationCenter.default.publisher(for: .init("moonlight.assistantDockFocus"))) { _ in
            DispatchQueue.main.async { focused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("moonlight.assistantDockDismiss"))) { _ in
            focused = false
        }
    }

    private func submit() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        focused = false
        onOpen(prompt, deepThinking)
        draft = ""
    }
}

private struct AssistantMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID().uuidString
    var role: Role
    var text: String
}

private enum AssistantAPIError: LocalizedError {
    case missingKey, disabled, server(String), invalidResponse
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在智能体设置中保存当前服务的 API Key。"
        case .disabled: "请先在设置中启用 API 对话。"
        case .server(let reason): reason
        case .invalidResponse: "服务没有返回可显示的回答。"
        }
    }
}

private enum AssistantAPI {
    static func answer(history: [AssistantMessage], provider: AssistantProvider,
                       model: String, apiKey: String, deepThinking: Bool) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AssistantAPIError.missingKey }
        guard !modelID.isEmpty else {
            throw AssistantAPIError.server("请在设置中填写 \(provider.title) 的模型 ID；豆包也可填写 ep- 推理接入点。")
        }
        guard let endpoint = URL(string: provider.endpoint) else { throw AssistantAPIError.invalidResponse }
        let instruction = deepThinking
            ? "你是月淡中的智能助手。请仔细分析，再给出清晰、准确、可执行的中文回答。"
            : "你是月淡中的智能助手。请用清晰、简洁、友好的中文回答。"
        let messages = history.suffix(16).map { ["role": $0.role.rawValue, "content": $0.text] }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        let body: [String: Any]
        if provider == .openAI {
            body = ["model": modelID, "instructions": instruction, "input": messages, "store": false]
        } else {
            body = ["model": modelID,
                    "messages": [["role": "system", "content": instruction]] + messages,
                    "stream": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = (json?["error"] as? [String: Any])?["message"] as? String ?? "请检查密钥、模型权限及网络连接。"
            throw AssistantAPIError.server("\(provider.title) 请求失败（\(status)）：\(reason)")
        }
        if provider != .openAI,
           let choices = json?["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let text = message["content"] as? String, !text.isEmpty { return text }
        if let text = json?["output_text"] as? String, !text.isEmpty { return text }
        if let output = json?["output"] as? [[String: Any]] {
            let text = output.flatMap { ($0["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        throw AssistantAPIError.invalidResponse
    }
}

private struct AssistantChatView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("moonlight.assistant.enabled") private var enabled = false
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }
    let initialPrompt: String
    let initialDeepThinking: Bool
    @State private var messages: [AssistantMessage] = []
    @State private var draft = ""
    @State private var deepThinking = false
    @State private var sending = false
    @State private var errorText: String?
    @State private var didSeed = false
    @State private var settingsPresented = false

    init(initialPrompt: String, deepThinking: Bool) {
        self.initialPrompt = initialPrompt
        self.initialDeepThinking = deepThinking
        _deepThinking = State(initialValue: deepThinking)
    }

    var body: some View {
        VStack(spacing: 0) {
            if messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(MoonStyle.accent)
                    Text(provider.title).font(.title3.weight(.semibold))
                    Text("可向它提问、整理观看计划或解释内容。").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                HStack {
                                    if message.role == .assistant {
                                        Text(message.text).padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                        Spacer(minLength: 42)
                                    } else {
                                        Spacer(minLength: 42)
                                        Text(message.text).foregroundStyle(.white).padding(12).background(MoonStyle.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    }
                                }.id(message.id)
                            }
                            if sending { HStack { ProgressView(); Text("正在思考…").foregroundStyle(.secondary); Spacer() } }
                        }.padding()
                    }
                    .onChange(of: messages.count) { _ in if let id = messages.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                }
            }
            if let errorText {
                HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(errorText).font(.footnote); Spacer(); Button("配置") { settingsPresented = true } }
                    .padding(.horizontal).padding(.vertical, 8).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Menu {
                    Toggle("深入思考", isOn: $deepThinking)
                    Button("清除本次对话", role: .destructive) { messages.removeAll() }
                } label: { Image(systemName: "plus").frame(width: 38, height: 38).background(.thinMaterial, in: Circle()) }
                TextField("询问 \(provider.title)", text: $draft, axis: .vertical)
                    .lineLimit(1...5).submitLabel(.send).onSubmit { Task { await send() } }
                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up").foregroundStyle(.white).frame(width: 38, height: 38).background(MoonStyle.accent, in: Circle())
                }.disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10).background(.regularMaterial, in: Capsule()).padding()
        }
        .navigationTitle(provider.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { AssistantProviderPicker().disabled(sending) }
            ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
        }
        .onChange(of: providerRaw) { _ in
            // Start a fresh conversation rather than silently forwarding one
            // provider's existing conversation to a different company.
            messages.removeAll()
            errorText = nil
        }
        .task {
            guard !didSeed else { return }; didSeed = true
            draft = initialPrompt
            if !initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await send() }
        }
        .sheet(isPresented: $settingsPresented) { NavigationStack { AssistantSettingsView() } }
    }

    @MainActor private func send() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !sending else { return }
        guard enabled else { errorText = AssistantAPIError.disabled.errorDescription; return }
        let selectedProvider = provider
        let selectedModel = selectedProvider.configuredModel
        let key = SecureSettings.read(selectedProvider.keyAccount) ?? ""
        guard !key.isEmpty else { errorText = AssistantAPIError.missingKey.errorDescription; return }
        errorText = nil; draft = ""; sending = true
        messages.append(AssistantMessage(role: .user, text: question))
        do {
            let answer = try await AssistantAPI.answer(history: messages, provider: selectedProvider, model: selectedModel, apiKey: key, deepThinking: deepThinking)
            messages.append(AssistantMessage(role: .assistant, text: answer))
        } catch {
            errorText = error.localizedDescription
        }
        sending = false
    }
}

private struct AssistantSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("moonlight.assistant.enabled") private var enabled = false
    @AppStorage("moonlight.assistant.provider") private var providerRaw = AssistantProvider.openAI.rawValue
    @State private var modelDraft = ""
    @State private var keyDraft = ""
    @State private var saved = false
    private var provider: AssistantProvider { AssistantProvider(rawValue: providerRaw) ?? .openAI }

    var body: some View {
        Form {
            Section("智能体") {
                Toggle("启用 API 对话", isOn: $enabled)
                Picker("当前服务", selection: $providerRaw) {
                    ForEach(AssistantProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section(provider.title + " API") {
                SecureField("API Key", text: $keyDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(provider.modelHint, text: $modelDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(provider.endpoint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(saved ? "已保存" : "保存当前服务配置") {
                    let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.isEmpty { SecureSettings.delete(provider.keyAccount) }
                    else { SecureSettings.write(key, account: provider.keyAccount) }
                    UserDefaults.standard.set(modelDraft.trimmingCharacters(in: .whitespacesAndNewlines), forKey: provider.modelKey)
                    saved = true
                }
                if provider == .doubao {
                    Text("使用火山方舟 API Key 和已开通的豆包模型 ID，或 ep- 开头的推理接入点 ID。豆包 App 登录信息不能代替 API Key。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("使用说明") {
                Text("在底部输入栏或长按搜索条选择智能体。输入功能名称会出现直达气泡，点击气泡执行功能；发送文字则进入 AI 对话。")
                Text("每个服务独立保存模型和密钥。切换服务前请保存；切换聊天服务将开始新对话。")
                Label("密钥只保存在此设备的钥匙串，不会写入 IPA 或 GitHub。", systemImage: "key.fill")
                Text("API 按各服务的账户单独计费。“深入思考”是更仔细回答的提示，不会擅自切换模型。")
            }
        }
        .navigationTitle("智能体与 API")
        .onAppear(perform: loadConfiguration)
        .onChange(of: providerRaw) { _ in loadConfiguration() }
        .onChange(of: keyDraft) { _ in saved = false }
        .onChange(of: modelDraft) { _ in saved = false }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
    }

    private func loadConfiguration() {
        keyDraft = SecureSettings.read(provider.keyAccount) ?? ""
        modelDraft = provider.configuredModel
        saved = false
    }
}

private struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    init(title: String, subtitle: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold()).tracking(-0.5).accessibilityIdentifier("page-title-\(title)")
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyPanel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(MoonStyle.accent)
                .frame(width: 66, height: 66).background(MoonStyle.accent.opacity(0.1), in: Circle())
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 5) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct MenuRow: View {
    let symbol: String
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(color.gradient, in: Circle())
            Text(title).font(.body.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 13).padding(.horizontal, 8)
    }
}






@MainActor
@ViewBuilder
private func glassTabContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: 10) { content() }
    } else {
        content()
    }
}

private extension View {
    @ViewBuilder
    func moonGlassCircle(_ target: BackgroundTarget = .allButtons) -> some View {
        modifier(MediaGlassCircle(target: target))
    }
}




