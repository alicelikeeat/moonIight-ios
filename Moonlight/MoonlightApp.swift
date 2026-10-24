import SwiftUI
import UIKit

final class MoonAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGRefresh.install()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        TransferHub.completions[identifier] = completionHandler
        TransferHub.center?.wake(identifier)
    }
}

@main
struct MoonlightApp: App {
    @UIApplicationDelegateAdaptor(MoonAppDelegate.self) var delegate
    @StateObject private var app = AppModel()
    @StateObject private var ring = RingController()
    @StateObject private var hold = HoldController()

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(app)
                .environmentObject(ring)
                .environmentObject(hold)
        }
    }
}

struct AppRoot: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Reading colorScheme in the same view that sets preferredColorScheme cycles
        // AttributeGraph on iOS 18+. The cycle renders once, then drops later updates,
        // so every button looks tappable and nothing on screen changes.
        ThemeRoot()
            .preferredColorScheme(app.settings.theme.preferred)
            .moonOnChange(of: scenePhase) { phase in
                if phase != .active {
                    NotificationCenter.default.post(name: .moonPauseAll, object: nil)
                    Task { await app.flush() }
                } else {
                    NotificationCenter.default.post(name: .moonResumeFeed, object: nil)
                }
            }
    }
}

private struct ThemeRoot: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RootView()
            .environment(\.moon, app.settings.theme.colors(system: colorScheme))
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @EnvironmentObject private var hold: HoldController
    @Environment(\.moon) private var colors

    var body: some View {
        Group {
            if app.settings.tabLens {
                systemTabs
            } else {
                page(app.tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !feedChromeHidden {
                            MoonTabBar(suppressed: ring.session != nil)
                        }
                    }
            }
        }
        .background {
            GlobalLongPress(
                onBegan: { point in beganPress(point) },
                onChanged: { point in
                    hold.move(point)
                    ring.finger = point
                    ring.fingerDown = true
                },
                onEnded: { point in endedPress(point) }
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if ring.session != nil {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .ignoresSafeArea(edges: .bottom)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if ring.session != nil {
                RingOverlay(ring: ring)
            }
        }
        .overlay {
            if hold.showing || hold.panel != nil {
                HoldChrome()
                    .allowsHitTesting(hold.panel != nil)
            }
        }
        .overlay(alignment: .top) {
            RecordPill(recorder: app.recorder) { app.nudgeChrome(); app.toggleRecording() }
                .padding(.top, 8)
                .opacity(feedChromeHidden ? 0 : 1)
                .allowsHitTesting(!feedChromeHidden)
                .animation(.easeInOut(duration: 0.28), value: app.feedChrome)
        }
        .overlay {
            if let title = app.shredTitle {
                ShredderCurtain(title: title)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastBar(text: toast, undo: app.undo)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                    .opacity(feedChromeHidden ? 0 : 1)
                    .allowsHitTesting(!feedChromeHidden)
            }
        }
        .sheet(isPresented: $app.showTrash) { TrashView() }
        .sheet(isPresented: Binding(get: { ring.sheet != nil }, set: { if !$0 { ring.sheet = nil } })) {
            if let groups = ring.sheet {
                MoreSheet(groups: groups, forceDark: ring.sheetDark) { ring.sheet = nil }
            }
        }
        .sheet(item: $app.composer) { draft in
            ComposerSheet(draft: draft)
        }
        .sheet(item: $app.fullPlayer) { entry in
            FullPlayerView(entry: entry)
        }
        .onAppear {
            hold.app = app
            hold.ring = ring
            paintWindow()
        }
        .onDisappear { TabChrome.setSuspended(false) }
    }

    /// Home feed is full screen while a video is playing and the buttons are tucked away.
    private var feedChromeHidden: Bool { app.tab == .home && !app.feedChrome }

    private var systemTabs: some View {
        TabView(selection: Binding(get: { app.tab }, set: { newValue in
            app.nudgeChrome()
            if newValue == .home && app.tab == .home { app.feedIndex = 0 }
            app.tab = newValue
            Haptics.tick()
        })) {
            page(.home).tabItem { Label("首页", systemImage: "moon.stars") }.tag(AppTab.home)
            page(.discover).tabItem { Label("发现", systemImage: "magnifyingglass") }.tag(AppTab.discover)
            page(.capture).tabItem { Label("拍摄", systemImage: "circle.fill") }.tag(AppTab.capture)
            page(.moments).tabItem { Label("朋友圈", systemImage: "person.2") }.tag(AppTab.moments)
            page(.me).tabItem { Label("我", systemImage: "person") }.tag(AppTab.me)
        }
        .tint(app.tab == .home ? MoonColors.media.accent : colors.accent)
        .moonTabBarVisible(!feedChromeHidden)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(feedChromeHidden ? .hidden : .visible, for: .tabBar)
        .toolbarColorScheme(app.tab == .home ? ColorScheme.dark : nil, for: .tabBar)
        .background(TabBarHider(hidden: feedChromeHidden))
        .animation(.easeInOut(duration: 0.28), value: app.feedChrome)
    }

    @ViewBuilder private func page(_ tab: AppTab) -> some View {
        switch tab {
        case .home: FeedView()
        case .discover: DiscoverView()
        case .capture: CaptureView()
        case .moments: MomentsView()
        case .me: MeView()
        }
    }

    /// Long-press anywhere that does not already own a press (feed media, a video).
    /// A short tap still reaches the button; this recognizer does not cancel it.
    private func beganPress(_ point: CGPoint) {
        TabChrome.setSuspended(true)
        PressGate.begin()
        app.nudgeChrome()
        let overMedia = app.tab == .home && !app.feedItems.isEmpty
        let items = [
            RingItem(title: "筛选", systemImage: "line.3.horizontal.decrease", children: FeedScope.allCases.map { scope in
                RingItem(title: scope.label, systemImage: "circle") { app.setScope(scope) }
            }) {},
            RingItem(title: "随机一条", systemImage: "shuffle", key: "random") { app.randomItem() },
            RingItem(title: "重新洗牌", systemImage: "arrow.triangle.2.circlepath", key: "reshuffle") { app.shuffleFeed() },
            RingItem(title: "回到顶部", systemImage: "arrow.up", key: "top") { app.feedIndex = 0 },
        ]
        let groups = [
            MenuGroup(title: "声音", items: [
                RingItem(title: app.settings.feedMuted ? "打开声音" : "静音", systemImage: "speaker", key: "mute") {
                    app.settings.feedMuted.toggle()
                    app.feedPlayer.isMuted = app.settings.feedMuted
                    app.saveSettings()
                },
            ]),
            MenuGroup(title: "全局", items: [
                RingItem(title: "录屏", systemImage: "record.circle", key: "record") { app.toggleRecording() },
                RingItem(title: "发动态", systemImage: "square.and.pencil", key: "compose") { app.composer = ComposerDraft(authorId: app.social.selfId) },
                RingItem(title: "设置", systemImage: "gearshape", key: "settings") { app.tab = .me; app.requestSettings = true },
                RingItem(title: "最近删除", systemImage: "trash", key: "recent") { app.showTrash = true },
            ]),
        ]
        ring.present(origin: point, items: items, groups: groups, settings: app.settings, overMedia: overMedia)
        hold.arm(origin: point, settings: app.settings, catalog: RingCatalog(items: items, groups: groups, context: .tab, title: app.tab.title, overMedia: overMedia))
    }

    private func endedPress(_ point: CGPoint) {
        let outcome = hold.lift()
        ring.fingerDown = false
        ring.finger = point
        if outcome != .timed && outcome != .center {
            if ring.session?.drop == true {
                ring.releaseFinger(at: point)
            } else if ring.session?.select == .drag || ring.session?.select == .slider {
                ring.selectDrag(at: point)
            }
        }
        TabChrome.setSuspended(false)
        app.nudgeChrome()
        PressGate.end()
    }

    /// Fills the window behind the system glass without expanding the SwiftUI safe area.
    private func paintWindow() {
        let style = UITraitCollection.current.userInterfaceStyle
        let dark = app.settings.theme == .dark || (app.settings.theme == .system && style == .dark)
        let color = dark
            ? UIColor(red: 0.027, green: 0.031, blue: 0.043, alpha: 1)
            : UIColor(red: 0.969, green: 0.961, blue: 0.937, alpha: 1)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.backgroundColor = color }
    }
}

/// Glass tab bar with no drag-to-switch lens. Used when 底栏滑块 is off.
struct MoonTabBar: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors
    @Environment(\.colorScheme) private var scheme
    var suppressed: Bool

    var body: some View {
        let ink = app.tab == .home ? MoonColors.media : colors
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    guard !PressGate.suppressTap, !suppressed else { return }
                    app.nudgeChrome()
                    if tab == .home && app.tab == .home { app.feedIndex = 0 }
                    app.tab = tab
                    Haptics.tick()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: tab == .capture ? 22 : 17, weight: .semibold))
                        Text(tab.title).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 48)
                    .foregroundColor(app.tab == tab ? ink.accent : ink.textDim)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(app.tab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .moonGlass(ink, radius: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .environment(\.colorScheme, app.tab == .home ? .dark : scheme)
        .accessibilityElement(children: .contain)
        .modifier(TabBarTrait())
        .accessibilityIdentifier("moon.tabs")
        .allowsHitTesting(!suppressed)
        .opacity(suppressed ? 0.45 : 1)
        .background(TabBarFrameMark(active: true))
    }
}

/// `.isTabBar` arrived in iOS 17. The custom bar still has an identifier on iOS 16.
private struct TabBarTrait: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.accessibilityAddTraits(.isTabBar)
        } else {
            content
        }
    }
}

