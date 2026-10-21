import SwiftUI
import UIKit

@main
struct MoonlightApp: App {
    @StateObject private var app = AppModel()
    @StateObject private var ring = RingController()

    var body: some Scene {
        WindowGroup {
            AppRoot()
                .environmentObject(app)
                .environmentObject(ring)
        }
    }
}

struct AppRoot: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environment(\.moon, app.settings.theme.colors(system: colorScheme))
            .preferredColorScheme(app.settings.theme.preferred)
            .moonOnChange(of: scenePhase) { phase in
                if phase != .active {
                    NotificationCenter.default.post(name: .moonPauseAll, object: nil)
                    Task { await app.flush() }
                }
            }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var colors

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch app.tab {
                case .home: FeedView().ignoresSafeArea()
                case .discover: DiscoverView()
                case .capture: CaptureView()
                case .moments: MomentsView()
                case .me: MeView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if ring.session != nil {
                RingOverlay(ring: ring)
            }
            tabBar
            if let toast = app.toast {
                ToastBar(text: toast, undo: app.undo)
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

    private func tab(_ item: AppTab) -> some View {
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
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            guard item == .home else { return }
            let origin = CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.height - 120)
            ring.present(origin: origin, items: [
                RingItem(title: "筛选", systemImage: "line.3.horizontal.decrease", children: FeedScope.allCases.map { scope in
                    RingItem(title: scope.label, systemImage: "circle") { app.setScope(scope) }
                }) {},
                RingItem(title: "随机一条", systemImage: "shuffle") { app.randomItem() },
                RingItem(title: "重新洗牌", systemImage: "arrow.triangle.2.circlepath") { app.shuffleFeed() },
                RingItem(title: "回到顶部", systemImage: "arrow.up") { app.feedIndex = 0 },
            ], groups: [
                MenuGroup(title: "声音", items: [
                    RingItem(title: app.settings.feedMuted ? "打开声音" : "静音", systemImage: "speaker") {
                        app.settings.feedMuted.toggle()
                        app.feedPlayer.isMuted = app.settings.feedMuted
                        app.saveSettings()
                    },
                ]),
            ], settings: app.settings, overMedia: app.tab == .home && !app.feedItems.isEmpty)
        })
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
        }
    }
}

