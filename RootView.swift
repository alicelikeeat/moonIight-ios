import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var backgroundStore: BackgroundStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedMedia: PhotosPickerItem?
    @State private var selectedImage: Image?
    @State private var activeSheet: RootSheet?
    @State private var activePlayer: MediaEntry?
    @State private var treasureRoute: AppCommand?
    @State private var discoveryQuery = ""
    @State private var discoverySourcesPresented = false
    /// 发现 is mounted the first time it is shown and then kept, so 推荐 and
    /// 发现 each keep their own scroll position.
    @State private var discoverMounted = false
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
    /// v1.82: the liquid selection blob that flows between tabs.
    @Namespace private var liquidSelection
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
            if model.selectedTab == .sandbox { Color.black.ignoresSafeArea() }
            else { PageBackground(target: .page(for: model.selectedTab)).ignoresSafeArea() }
            ZStack(alignment: .bottom) {
                Group {
                    switch model.selectedTab {
                    case .sandbox:
                        RPGShellView(session: WorldHost.shared.session,
                                     onExit: { leaveSandbox(to: WorldHost.shared.returnTab) },
                                     onNavigate: { leaveSandbox(to: $0) })
                    // Both segments share this branch, so switching between
                    // them keeps the same views and their scroll positions.
                    case .home, .discover: homeFeeds
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
                        .moonLiquidSurface(.capsule)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.35)))
                        .buttonStyle(.moonJelly)
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
        .onChange(of: model.selectedTab) { tab in
            discoverySourcesPresented = false
            if tab == .discover { discoverMounted = true }
            if tab != .sandbox { WorldHost.shared.returnTab = tab }
            MoonlightOrientationDelegate.setSandboxLandscape(tab == .sandbox)
            revealNavigation()
        }
        .onAppear {
            if model.selectedTab == .discover { discoverMounted = true }
            MoonlightOrientationDelegate.setSandboxLandscape(model.selectedTab == .sandbox)
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
        // Explicit .plain styles preserve existing single-glass circles and
        // media covers; shared containers keep their inner controls clear.
        // Full-blind mode hides the page layer itself. Search and the explicit
        // exit control remain readable when they are intentionally revealed.
        .buttonStyle(MoonInteractiveButtonStyle(blind: false))
        .environment(\.moonlightMediaSuspended, model.selectedTab == .sandbox)
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
            // The sandbox is full screen: its own control center replaces the bar.
            tabBar.zIndex(100)
                .opacity(navigationVisible && !blindMode && model.selectedTab != .sandbox ? 1 : 0)
                .offset(y: navigationVisible ? 0 : 28)
                .allowsHitTesting(navigationVisible && !blindMode && model.selectedTab != .sandbox)
                .accessibilityHidden(model.selectedTab == .sandbox)
                .animation(.easeOut(duration: 0.28), value: navigationVisible)
        }
        // The visible circles are deliberately decorative so their glass can
        // stay lightweight. This final transparent layer owns the real hit
        // targets and sits above the long-press scrim in every state.
        .overlay(alignment: .bottom) {
            priorityNavigationLayer.zIndex(1_000)
                .opacity(navigationVisible && !blindMode && model.selectedTab != .sandbox ? 1 : 0)
                .allowsHitTesting(navigationVisible && !blindMode && model.selectedTab != .sandbox)
                .accessibilityHidden(model.selectedTab == .sandbox)
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
        .fullScreenCover(item: $treasureRoute, onDismiss: { revealNavigation() }) { command in
            NavigationStack {
                MoonTreasureMapView(openVideoWall: command == .treasurePlayback, openLandlord: command == .landlord)
            }
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
            if ProcessInfo.processInfo.arguments.contains("--reels-ui-tests") || ProcessInfo.processInfo.arguments.contains("--treasure-video-ui-tests") || ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") {
                await backgroundStore.prepareUITestMedia(applyBackgrounds: !ProcessInfo.processInfo.arguments.contains("--treasure-video-ui-tests") && !ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests"))
                if let video = backgroundStore.assets.first(where: { $0.id == "ui-test-background-video" }),
                   let image = backgroundStore.assets.first(where: { $0.id == "ui-test-background-image" }) {
                    model.mediaStore.prepareReelsUITest(videoURL: backgroundStore.url(for: video), imageURL: backgroundStore.url(for: image))
                    if ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") {
                        for key in ["landlord-game-v241", "landlord-media-v241", "landlord-scores-v241"] { UserDefaults.standard.removeObject(forKey: key) }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--treasure-video-ui-tests") || ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") {
                        model.mediaStore.prepareTreasureVideoUITest(videoURL: backgroundStore.url(for: video), count: ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") ? 11 : 5)
                        if ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") || ProcessInfo.processInfo.arguments.contains("--rpg-media-ui-tests") { model.mediaStore.prepareCardImageUITest(imageURL: backgroundStore.url(for: image)) }
                    }
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
            if ProcessInfo.processInfo.arguments.contains("--sandbox-launch-ui-tests") {
                // Layout orientation as the app sees it, for the navigation tests.
                // The reader must span the window: a 2×2 frame around it always read as portrait.
                GeometryReader { geometry in
                    Text("方向").font(.system(size: 1)).opacity(0.01).frame(width: 2, height: 2)
                        .accessibilityIdentifier("app-orientation")
                        .accessibilityValue(geometry.size.width > geometry.size.height ? "landscape" : "portrait")
                }.ignoresSafeArea().allowsHitTesting(false)
            }
            if ProcessInfo.processInfo.arguments.contains("--background-ui-tests") || ProcessInfo.processInfo.arguments.contains("--treasure-video-ui-tests") || ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") {
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
                                .moonLiquidSurface(.circle)
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
                            .moonLiquidSurface(.circle)
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
                ForEach(Array(AppTab.bar.enumerated()), id: \.element) { index, tab in
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .scaleEffect(model.selectedTab.barTab == tab ? 1.10 : 1)
                            .rotationEffect(.degrees(model.selectedTab.barTab == tab ? 3 : 0))
                            .opacity(blindMode ? 0.01 : 1)
                            .animation(.spring(response: 0.28, dampingFraction: 0.62), value: model.selectedTab)
                            .frame(width: diameter, height: diameter)
                            .background {
                                // v1.82: a drop of tinted light under the chosen tab; it
                                // flows to the next tab and wobbles into place.
                                if model.selectedTab.barTab == tab && !blindMode {
                                    Circle().fill(RadialGradient(colors: [activeButtonTint.opacity(0.55), activeButtonTint.opacity(0)], center: .center, startRadius: 4, endRadius: diameter * 0.75))
                                        .frame(width: diameter * 1.45, height: diameter * 1.45)
                                        .matchedGeometryEffect(id: "tab-blob", in: liquidSelection)
                                        .allowsHitTesting(false)
                                }
                            }
                            .moonGlassCircle(.button(for: tab))
                            .overlay(Circle().strokeBorder(model.selectedTab.barTab == tab ? activeButtonTint.opacity(0.62) : .clear, lineWidth: 1).allowsHitTesting(false))
                            .animation(MoonLiquidMotion.morph, value: model.selectedTab)
                        Text(tab.title).font(.system(size: 10, weight: model.selectedTab.barTab == tab ? .semibold : .medium))
                            .opacity(blindMode ? 0.01 : 1)
                    }
                    .foregroundStyle(backgroundStore.resolved(.button(for: tab))?.veil.foreground ?? (model.selectedTab.barTab == tab ? activeButtonTint : .secondary))
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
                ForEach(Array(AppTab.bar.enumerated()), id: \.element) { index, tab in
                    GeometryReader { proxy in
                        Color.clear
                            .contentShape(Circle())
                            .gesture(
                                LongPressGesture(minimumDuration: 0.48, maximumDistance: 12)
                                    .exclusively(before: TapGesture())
                                    .onEnded { result in
                                        switch result {
                                        case .first:
                                            let frame = proxy.frame(in: .global)
                                            NotificationCenter.default.post(
                                                name: .init("moonlight.navigationHeld"),
                                                object: nil,
                                                userInfo: ["tab": tab.rawValue, "x": frame.midX, "y": frame.midY]
                                            )
                                        case .second:
                                            model.activeLongPressMenu = nil
                                            NotificationCenter.default.post(name: .init("moonlight.navigationTapped"), object: nil)
                                            UISelectionFeedbackGenerator().selectionChanged()
                                            selectTab(tab)
                                        }
                                    }
                            )
                    }
                    .frame(width: diameter + 4, height: diameter + 4)
                    .position(x: (geometry.size.width - width) / 2 + width * (CGFloat(index) + 0.5) / 5,
                              y: diameter / 2 + 1)
                    .accessibilityLabel(tab.title)
                    .accessibilityIdentifier("navigation-\(tab.rawValue)")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .frame(height: 78)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
    }

    /// 首页: 推荐 and 发现 as two segments. Each feed is its own scroll view and
    /// stays mounted while hidden, so neither reloads nor loses its place.
    private var homeFeeds: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                homeSegment("推荐", tab: .home, identifier: "home-segment-recommend")
                homeSegment("发现", tab: .discover, identifier: "navigation-discover")
            }
            .padding(4).moonSingleGlass(radius: 18)
            .padding(.top, 2)
            ZStack {
                refreshable(.home) { HomeView(onSelect: { activePlayer = $0 }) }
                    .opacity(model.selectedTab == .home ? 1 : 0)
                    .allowsHitTesting(model.selectedTab == .home)
                    .accessibilityHidden(model.selectedTab != .home)
                    .environment(\.moonlightFeedActive, model.selectedTab == .home)
                if discoverMounted || model.selectedTab == .discover {
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
                    .opacity(model.selectedTab == .discover ? 1 : 0)
                    .allowsHitTesting(model.selectedTab == .discover)
                    .accessibilityHidden(model.selectedTab != .discover)
                    .environment(\.moonlightFeedActive, model.selectedTab == .discover)
                }
            }
        }
    }

    private func homeSegment(_ title: String, tab: AppTab, identifier: String) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.16)) { model.selectedTab = tab }
        } label: {
            Text(title).font(.subheadline.weight(model.selectedTab == tab ? .semibold : .regular))
                .frame(width: 72, height: 32)
                .background {
                    if model.selectedTab == tab {
                        Capsule().fill(Color.accentColor.opacity(0.18))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.7))
                            .matchedGeometryEffect(id: "home-segment", in: liquidSelection)
                    }
                }
                .animation(MoonLiquidMotion.morph, value: model.selectedTab)
        }
        .buttonStyle(.moonJelly)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
    }

    /// Leaves the sandbox for a portrait page. The world was already saved
    /// and paused by the sandbox; the camera opens over the previous page.
    private func leaveSandbox(to tab: AppTab) {
        if tab == .camera {
            let back = WorldHost.shared.returnTab == .sandbox ? .home : WorldHost.shared.returnTab
            withAnimation(.easeOut(duration: 0.16)) { model.selectedTab = back }
            openCamera(video: false)
        } else {
            withAnimation(.easeOut(duration: 0.16)) { model.selectedTab = tab == .sandbox ? .home : tab }
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
        case .searchMedia:
            model.selectedTab = .discover
            let intent = model.pendingMediaSearch
            model.pendingMediaSearch = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                var values: [String: String] = [:]
                if let intent { values["query"] = intent.query; values["kind"] = intent.kind }
                NotificationCenter.default.post(name: .init("moonlight.focusMediaSearch"), object: nil, userInfo: values)
            }
        case .treasureMap, .treasurePlayback, .landlord: treasureRoute = action
        case .rpg, .rpgStory, .rpgEditor, .rpgDiagnostics:
            // Every way into the world lands in the one sandbox tab.
            WorldHost.shared.pendingPage = action.rpgPage
            selectTab(.sandbox)
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
        case .rpg, .rpgStory, .rpgEditor, .rpgDiagnostics:
            Button("进入沙盒世界") { activeSheet = nil; model.send(action) }
        case .treasureMap, .treasurePlayback, .landlord: MoonTreasureMapView(openVideoWall: action == .treasurePlayback, openLandlord: action == .landlord)
        case .searchMedia: Text("请返回发现页搜索媒体。")
        case .settings: SettingsView()
        case .menuSettings: ContextMenuSettingsView()
        case .background, .backgrounds, .backgroundLibrary: BackgroundSettingsView()
        case .friends: VirtualFriendsView(onSelect: { activeSheet = nil; activePlayer = $0 })
        case .messages: VirtualMessagesView()
        case .profile: ProfileEditView()
        case .gestures: GestureHelpView()
        case .playMedia, .favoriteMedia, .saveMedia, .shareMedia:
            List { Group {
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
                }.listRowBackground(MoonLiquidRowBackground())
            }.moonLiquidList().navigationTitle(action.title)
        default: LibraryView(selectedImage: selectedImage, selection: $selectedMedia, onPlay: { activeSheet = nil; activePlayer = $0 })
        }
    }
}

struct CameraRequest: Identifiable { let id = UUID(); var video: Bool }
struct ReelsRequest: Identifiable { let id = UUID(); let source: ReelsSource }

enum RootSheet: Identifiable {
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
