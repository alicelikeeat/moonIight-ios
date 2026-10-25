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
                    app.dismissCaptureSession()
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
        ZStack(alignment: .bottom) {
            page(app.tab == .capture ? .home : app.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !feedChromeHidden {
                MoonTabBar(suppressed: ring.session != nil || app.fan != nil)
                    .padding(.bottom, 4)
            }
        }
        .background { ScreenBackdrop() }
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
        .fullScreenCover(item: $app.camera, onDismiss: { app.releaseGestureChrome() }) { mode in
            MoonCamera(
                video: mode.video,
                onImage: { image in
                    app.camera = nil
                    if let data = image.jpegData(compressionQuality: 0.9) {
                        app.importImageData(data, title: "拍摄", source: "camera")
                    }
                },
                onVideo: { url in
                    app.camera = nil
                    app.importFile(at: url, kind: .video, title: "录像", source: "camera")
                },
                onCancel: { app.camera = nil }
            )
            .ignoresSafeArea()
        }
        .overlay {
            if app.fan != nil { CaptureFanOverlay() }
        }
        .sheet(isPresented: $app.showTrash) { TrashView() }
        .sheet(item: $ring.menu) { menu in
            MoreSheet(groups: menu.groups, forceDark: menu.dark) { ring.menu = nil }
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
            ring.onPickAnim = { raw in
                app.settings.ringAnim = RingAnimPick.normalize(raw)
                app.saveSettings()
                let name = raw == RingAnim.random ? RingAnimPick.randomLabel : RingAnim.of(raw).label
                app.showToast("长按动画：\(name)")
            }
            paintWindow()
        }
        .onDisappear { TabChrome.setSuspended(false) }
    }

    /// Home feed is full screen while a video is playing and the buttons are tucked away.
    private var feedChromeHidden: Bool { app.tab == .home && !app.feedChrome }

    @ViewBuilder private func page(_ tab: AppTab) -> some View {
        switch tab {
        case .home, .capture: FeedView()
        case .discover: DiscoverView()
        case .moments: MomentsView()
        case .me: MeView()
        }
    }

    /// Long-press anywhere that does not already own a press (feed media, a video).
    /// A short tap still reaches the button; this recognizer does not cancel it.
    private func beganPress(_ point: CGPoint) {
        if ring.skinEdit { return }
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

/// Glass tab bar. The selection pill slides to the current tab and follows a finger drag when 底栏滑块 is on.
struct MoonTabBar: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors
    @Environment(\.colorScheme) private var scheme
    var suppressed: Bool
    /// Fractional slot while a finger is dragging along the bar. Nil snaps to the selected tab.
    @State private var dragSlot: CGFloat?
    /// Center of 拍摄 in window coordinates, so a long-press still anchors the fan if the window probe misses.
    @State private var captureCenter = CGPoint.zero
    /// 0…1 while the finger is down on 拍摄, before and as the fan opens.
    @State private var holdProgress: CGFloat = 0

    var body: some View {
        let ink = app.tab == .home ? MoonColors.media : colors
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                if tab == .capture {
                    captureButton(ink)
                } else {
                    Button {
                        guard !PressGate.suppressTap, !suppressed else { return }
                        app.nudgeChrome()
                        if tab == .home && app.tab == .home { app.feedIndex = 0 }
                        app.tab = tab
                        Haptics.tick()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 17, weight: .semibold))
                            Text(tab.title).font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .foregroundColor(app.tab == tab ? ink.accent : ink.textDim)
                        .contentShape(Rectangle())
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tab.title)
                    .accessibilityIdentifier("tab.\(tab.rawValue)")
                    .accessibilityAddTraits(app.tab == tab ? [.isButton, .isSelected] : [.isButton])
                }
            }
        }
        .background {
            ZStack {
                selectionPill(ink)
                TabDragSurface(enabled: app.settings.tabLens && app.fan == nil && !suppressed) { fraction, commit in
                    if commit {
                        if let fraction { snap(to: fraction) }
                        dragSlot = nil
                    } else if let fraction {
                        dragSlot = fraction
                    }
                }
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

    private func selectionPill(_ ink: MoonColors) -> some View {
        let tabs = AppTab.allCases
        let index = CGFloat(tabs.firstIndex(of: app.tab) ?? 0)
        let slot = dragSlot ?? index
        return GeometryReader { geo in
            let width = geo.size.width / CGFloat(tabs.count)
            Capsule()
                .fill(Color.clear)
                .frame(width: max(44, width - 8), height: max(40, geo.size.height - 6))
                .moonCapsule(overMedia: app.tab == .home)
                .overlay(Capsule().stroke(ink.glassStroke.opacity(0.7), lineWidth: 0.6))
                .offset(x: slot * width + 4, y: 3)
                .animation(dragSlot == nil ? .spring(response: 0.34, dampingFraction: 0.78) : nil, value: slot)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("tab.pill")
    }

    private func snap(to fraction: CGFloat) {
        let tabs = AppTab.allCases
        var index = Int(round(fraction))
        index = min(tabs.count - 1, max(0, index))
        var next = tabs[index]
        if next == .capture {
            let lower = max(0, index - 1)
            let upper = min(tabs.count - 1, index + 1)
            next = abs(fraction - CGFloat(lower)) <= abs(fraction - CGFloat(upper)) ? tabs[lower] : tabs[upper]
            if next == .capture { next = fraction < CGFloat(index) ? .home : .moments }
        }
        guard next != app.tab else { return }
        app.nudgeChrome()
        app.tab = next
        Haptics.tick()
    }

    private func captureButton(_ ink: MoonColors) -> some View {
        Button {
            guard !PressGate.suppressTap, app.fan == nil else { return }
            app.nudgeChrome()
            app.openCamera(false)
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.2)).frame(width: 46, height: 46)
                    Circle().stroke(Color.white.opacity(0.55), lineWidth: 1).frame(width: 46, height: 46)
                    Circle()
                        .trim(from: 0, to: holdProgress)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 52, height: 52)
                        .opacity(holdProgress > 0.02 ? 1 : 0)
                    Image(systemName: "camera.fill").font(.system(size: 18, weight: .semibold))
                }
                .scaleEffect(UIAccessibility.isReduceMotionEnabled ? 1 : 1 + 0.08 * holdProgress)
                .offset(y: -8)
                Text("拍摄").font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .foregroundColor(ink.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            ZStack {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { captureCenter = Self.mid(geo) }
                        .moonOnChange(of: geo.frame(in: .global).midY) { _ in captureCenter = Self.mid(geo) }
                }
                CaptureHoldMeter { holdProgress = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .simultaneousGesture(captureHold)
        .holdTrack(onBegan: { point in
            app.beginFan(origin: point, finger: point)
        }, onChanged: { point in
            app.beginFan(origin: point, finger: point)
        }, onEnded: { point in
            finishCaptureHold(at: point)
        }, cancelsTap: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("拍摄")
        .accessibilityIdentifier("tab.capture")
        .accessibilityAddTraits(.isButton)
    }

    /// Lives on the button itself. A window-level probe can miss the press, and the button's tap would then open the camera.
    private var captureHold: some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 48)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                let point = drag?.location ?? captureCenter
                let origin = captureCenter == .zero ? point : captureCenter
                app.beginFan(origin: origin, finger: point)
            }
            .onEnded { value in
                let point: CGPoint
                if case .second(true, let drag) = value {
                    point = drag?.location ?? captureCenter
                } else {
                    point = captureCenter
                }
                finishCaptureHold(at: point)
            }
    }

    private func finishCaptureHold(at point: CGPoint) {
        let release = FanAim.firesOnRelease(select: app.settings.menuSelect, drop: app.settings.dropSelect)
        if release, let fan = app.fan, let hit = CaptureFanLayout.hitIndex(finger: point, origin: fan.origin, size: UIScreen.main.bounds.size) {
            app.fireCapture(hit)
        } else if app.fan != nil {
            app.fan?.finger = point
            app.fan?.down = false
        }
        TabChrome.setSuspended(false)
        PressGate.end()
    }

    private static func mid(_ geo: GeometryProxy) -> CGPoint {
        let frame = geo.frame(in: .global)
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

/// Drag along the glass bar switches tabs. A drag that starts on 拍摄 does not.
private struct TabDragSurface: UIViewRepresentable {
    var enabled: Bool
    /// fraction is nil when the drag should snap back. commit is true on release.
    var onDrag: (CGFloat?, Bool) -> Void

    func makeUIView(context: Context) -> TabDragView {
        let view = TabDragView()
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.onDrag = onDrag
        view.dragEnabled = enabled
        return view
    }

    func updateUIView(_ uiView: TabDragView, context: Context) {
        uiView.onDrag = onDrag
        uiView.dragEnabled = enabled
    }
}

private final class TabDragView: UIView, UIGestureRecognizerDelegate {
    var onDrag: ((CGFloat?, Bool) -> Void)?
    var dragEnabled = true
    private var pan: UIPanGestureRecognizer?
    private var tracking = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            pan = nil
            return
        }
        DispatchQueue.main.async { [weak self] in self?.install() }
    }

    private func install() {
        guard pan == nil, let window else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        window.addGestureRecognizer(pan)
        self.pan = pan
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// Only a drag that starts on the bar, and not on 拍摄, can change pages.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard dragEnabled, let window = touch.window else { return false }
        let bar = convert(bounds, to: window)
        guard bar.width > 1, bar.height > 1, bar.contains(touch.location(in: window)) else { return false }
        return slot(at: touch.location(in: window), bar: bar) != .capture
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard dragEnabled, let window else { return }
        let moved = gesture.translation(in: window)
        let bar = convert(bounds, to: window)
        guard bar.width > 1 else { return }
        let slotWidth = bar.width / CGFloat(AppTab.allCases.count)
        let fraction = (gesture.location(in: window).x - bar.minX) / slotWidth
        switch gesture.state {
        case .began:
            tracking = false
        case .changed:
            if abs(moved.x) > 18 || abs(moved.y) > 18 { tracking = true }
            if tracking { onDrag?(fraction, false) }
        case .ended:
            onDrag?(tracking ? fraction : nil, true)
            tracking = false
        case .cancelled, .failed:
            onDrag?(nil, true)
            tracking = false
        default:
            break
        }
    }

    private func slot(at point: CGPoint, bar: CGRect) -> AppTab? {
        let local = point.x - bar.minX
        let width = bar.width / CGFloat(AppTab.allCases.count)
        guard width > 1 else { return nil }
        let index = Int(local / width)
        guard AppTab.allCases.indices.contains(index) else { return nil }
        return AppTab.allCases[index]
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

