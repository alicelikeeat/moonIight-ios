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
        VStack(spacing: 0) {
            Group {
                switch app.tab {
                case .home: FeedView()
                case .discover: DiscoverView()
                case .capture: CaptureView()
                case .moments: MomentsView()
                case .me: MeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(app.tab)
            tabBar
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

    /// Fills the status-bar gap without ignoresSafeArea, which cycles layout against the tab bar.
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

    private var tabBar: some View {
        HStack(spacing: 0) {
            tab(.home)
            tab(.discover)
            capture
            tab(.moments)
            tab(.me)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, max(8, ScreenInsets.bottom > 0 ? 4 : 10))
        .moonGlass(app.tab == .home ? MoonColors.media : colors, radius: 28)
        .padding(.horizontal, 12)
        .padding(.bottom, ScreenInsets.bottom > 0 ? 6 : 10)
    }

    @ViewBuilder
    private func tab(_ item: AppTab) -> some View {
        if item == .home {
            tabButton(item).holdTrack(onBegan: { point in
            let origin = CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.height - 120)
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
            ring.present(origin: origin, items: items, groups: groups, settings: app.settings, overMedia: app.tab == .home && !app.feedItems.isEmpty)
            hold.arm(origin: point, settings: app.settings, catalog: RingCatalog(items: items, groups: groups, context: .tab, title: "首页", overMedia: app.tab == .home && !app.feedItems.isEmpty))
        }, onChanged: { point in
            hold.move(point)
            ring.finger = point
        }, onEnded: { _ in
            let outcome = hold.lift()
            ring.fingerDown = false
            if outcome != .timed && outcome != .center && app.settings.menuSelect == .drag {
                ring.selectDrag(at: ring.finger)
            }
        })
        } else {
            tabButton(item)
        }
    }

    private func tabButton(_ item: AppTab) -> some View {
        Button {
            if app.tab == item && item == .home { app.feedIndex = 0 }
            app.tab = item
            Haptics.tick()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18, weight: app.tab == item ? .semibold : .regular))
                Text(item.title).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(app.tab == item ? (app.tab == .home ? MoonColors.media.accent : colors.accent) : (app.tab == .home ? Color.white.opacity(0.72) : colors.textDim))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(item.rawValue)")
    }

    private var capture: some View {
        Button {
            app.tab = .capture
            Haptics.light()
        } label: {
            ZStack {
                Circle()
                    .fill(app.tab == .capture ? colors.accent : Color.white.opacity(0.16))
                    .frame(width: 46, height: 46)
                Circle()
                    .fill(app.tab == .capture ? colors.onAccent : colors.accent)
                    .frame(width: 16, height: 16)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.capture")
    }
}

