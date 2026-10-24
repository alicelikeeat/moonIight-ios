import SwiftUI
import UIKit

@main
struct MoonlightApp: App {
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
        TabView(selection: Binding(get: { app.tab }, set: { newValue in
            if newValue == .home && app.tab == .home { app.feedIndex = 0 }
            app.tab = newValue
            Haptics.tick()
        })) {
            FeedView()
                .tabItem { Label("首页", systemImage: "moon.stars") }
                .tag(AppTab.home)
            DiscoverView()
                .tabItem { Label("发现", systemImage: "magnifyingglass") }
                .tag(AppTab.discover)
            CaptureView()
                .tabItem { Label("拍摄", systemImage: "circle.fill") }
                .tag(AppTab.capture)
            MomentsView()
                .tabItem { Label("朋友圈", systemImage: "person.2") }
                .tag(AppTab.moments)
            MeView()
                .tabItem { Label("我", systemImage: "person") }
                .tag(AppTab.me)
        }
        .tint(app.tab == .home ? MoonColors.media.accent : colors.accent)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(app.tab == .home ? ColorScheme.dark : nil, for: .tabBar)
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
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastBar(text: toast, undo: app.undo)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        }
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
    }

    /// Long-press anywhere that does not already own a press (feed media, a video).
    /// A short tap still reaches the button; this recognizer does not cancel it.
    private func beganPress(_ point: CGPoint) {
        PressGate.begin()
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
                RingItem(title: "录屏", systemImage: "record.circle", key: "record") { app.showToast("录屏在下一版用系统 ReplayKit，只录本应用") },
                RingItem(title: "发动态", systemImage: "square.and.pencil", key: "compose") { app.composer = ComposerDraft(authorId: app.social.selfId) },
                RingItem(title: "设置", systemImage: "gearshape", key: "settings") { app.tab = .me; app.requestSettings = true },
            ]),
        ]
        ring.present(origin: point, items: items, groups: groups, settings: app.settings, overMedia: overMedia)
        hold.arm(origin: point, settings: app.settings, catalog: RingCatalog(items: items, groups: groups, context: .tab, title: app.tab.title, overMedia: overMedia))
    }

    private func endedPress(_ point: CGPoint) {
        let outcome = hold.lift()
        ring.fingerDown = false
        ring.finger = point
        if outcome != .timed && outcome != .center && app.settings.menuSelect == .drag {
            ring.selectDrag(at: point)
        }
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

