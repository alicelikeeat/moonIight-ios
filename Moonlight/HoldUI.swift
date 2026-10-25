import SwiftUI
import UIKit

struct RingCatalog {
    var items: [RingItem] = []
    var groups: [MenuGroup] = []
    var context: HoldContext?
    var title: String?
    var overMedia = false
}

struct MasterPanel: Identifiable {
    let id = UUID()
    var sections: [PanelSection]
    var overMedia: Bool
}

struct PanelSection: Identifiable {
    let id = UUID()
    var title: String
    var tiles: [RingItem]
}

/// Drives HoldMachine from a recognized long-press through lift, including the readout and 全部按键.
@MainActor
final class HoldController: ObservableObject {
    let machine = HoldMachine()
    @Published var showing = false
    @Published var elapsedMs: Int64 = 0
    @Published var progress: Float = 0
    @Published var tier: HoldTier = .none
    @Published var anchor: CGPoint = .zero
    @Published var panel: MasterPanel?
    private var timer: Timer?
    private var catalog = RingCatalog()
    private var pendingRelease: (() -> Void)?
    private var pendingFired = false
    private var onDeferredOpen: (() -> Void)?
    weak var app: AppModel?
    weak var ring: RingController?

    var engaged: Bool { machine.phase != .idle }

    func arm(
        origin: CGPoint,
        settings: AppSettings,
        catalog: RingCatalog,
        onRelease: (() -> Void)? = nil,
        onDeferredOpen: (() -> Void)? = nil
    ) {
        let now = Self.clock()
        let bounds = UIScreen.main.bounds
        machine.cfg = HoldConfig.from(settings)
        machine.down(now - machine.cfg.longMs, Float(origin.x), Float(origin.y), Float(bounds.width), Float(bounds.height))
        _ = machine.tick(now)
        let assigned = catalog.context.flatMap { settings.timedAssign[$0.rawValue] }
        machine.ring(catalog.context, assigned, deferred: onDeferredOpen != nil)
        self.catalog = catalog
        self.pendingRelease = onRelease
        self.pendingFired = false
        self.onDeferredOpen = onDeferredOpen
        anchor = origin
        refresh(now)
        startTimer()
    }

    func move(_ point: CGPoint) {
        guard engaged else { return }
        anchor = point
        if machine.move(Float(point.x), Float(point.y)) != nil {
            refresh(Self.clock())
        }
    }

    @discardableResult
    func lift() -> HoldOutcome {
        guard engaged else { return .long }
        let now = Self.clock()
        let out = machine.up(now)
        stopTimer()
        if let pendingRelease, !pendingFired, out == .long || out == .cancelled || out == .tap {
            pendingRelease()
        }
        pendingRelease = nil
        onDeferredOpen = nil
        showing = false
        return out
    }

    func dismissPanel() { panel = nil }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = Self.clock()
        if let event = machine.tick(now) {
            handle(event)
        }
        refresh(now)
        if machine.phase == .idle || machine.phase == .fired || machine.phase == .cancelled {
            if machine.phase != .cancelled { stopTimer() }
            if machine.phase == .fired { showing = false }
        }
    }

    private func handle(_ event: HoldEvent) {
        switch event {
        case .long, .cancelled:
            break
        case .center:
            pendingFired = true
            Haptics.confirm()
            panel = makePanel()
            ring?.menu = nil
            ring?.dismiss()
        case .timed(_, let key, let deferred):
            if deferred { onDeferredOpen?() }
            let item = TimedActions.resolve(items: catalog.items, groups: catalog.groups, context: catalog.context, key: key)
            if let item {
                pendingFired = true
                ring?.dismiss()
                item.action()
                let reversible = catalog.context.flatMap { TimedActions.option($0, key)?.reversible } ?? false
                if reversible {
                    app?.showToast("定时长按 · \(item.title)", undo: item.action)
                } else {
                    app?.showToast("定时长按 · \(item.title)")
                }
                Haptics.confirm()
            } else {
                Haptics.tick()
            }
        }
    }

    private func refresh(_ now: Int64) {
        elapsedMs = machine.elapsed(now)
        progress = machine.progress(now)
        tier = machine.tier()
        let wants = app?.settings.timedOn == true || app?.settings.centerPanel == true
        showing = machine.showing && wants
    }

    private func makePanel() -> MasterPanel {
        var sections: [PanelSection] = []
        let current = PanelFlatten.tiles(items: catalog.items, groups: catalog.groups)
        if !current.isEmpty {
            let name = catalog.title.map { "当前内容 · \($0)" } ?? "当前内容"
            sections.append(PanelSection(title: name, tiles: current))
        }
        let page = pageTiles()
        if !page.isEmpty { sections.append(PanelSection(title: "页面", tiles: page)) }
        sections.append(PanelSection(title: "全局", tiles: globalTiles()))
        return MasterPanel(sections: sections, overMedia: catalog.overMedia)
    }

    private func pageTiles() -> [RingItem] {
        guard let app else { return [] }
        switch app.tab {
        case .home:
            return [
                RingItem(title: "随机一条", systemImage: "shuffle", key: "random") { [weak app] in app?.randomItem() },
                RingItem(title: "重新洗牌", systemImage: "arrow.triangle.2.circlepath", key: "reshuffle") { [weak app] in app?.shuffleFeed() },
                RingItem(title: "回到顶部", systemImage: "arrow.up", key: "top") { [weak app] in app?.feedIndex = 0 },
                RingItem(title: app.settings.feedMuted ? "打开声音" : "静音", systemImage: "speaker", key: "mute") { [weak app] in
                    guard let app else { return }
                    app.settings.feedMuted.toggle()
                    app.feedPlayer.isMuted = app.settings.feedMuted
                    app.saveSettings()
                },
            ]
        case .moments:
            return [
                RingItem(title: "发动态", systemImage: "square.and.pencil", key: "compose") { [weak app] in
                    guard let app else { return }
                    app.composer = ComposerDraft(authorId: app.social.selfId)
                },
            ]
        case .discover, .capture, .me:
            return []
        }
    }

    private func globalTiles() -> [RingItem] {
        [
            RingItem(title: "录屏", systemImage: "record.circle", key: "record") { [weak self] in
                self?.app?.toggleRecording()
            },
            RingItem(title: "设置", systemImage: "gearshape", key: "settings") { [weak self] in
                self?.app?.tab = .me
                self?.app?.requestSettings = true
            },
            RingItem(title: "外观", systemImage: "circle.lefthalf.filled") { [weak self] in
                guard let app = self?.app else { return }
                switch app.settings.theme {
                case .system: app.settings.theme = .dark
                case .dark: app.settings.theme = .light
                case .light: app.settings.theme = .system
                }
                app.saveSettings()
                app.showToast("外观 · \(app.settings.theme.label)")
            },
            RingItem(title: "拍摄", systemImage: "circle.fill") { [weak self] in self?.app?.tab = .capture },
            RingItem(title: "筛选", systemImage: "line.3.horizontal.decrease") { [weak self] in
                guard let app = self?.app else { return }
                let order = FeedScope.allCases
                let idx = order.firstIndex(of: app.feedScope) ?? 0
                app.setScope(order[(idx + 1) % order.count])
            },
            RingItem(title: "最近删除", systemImage: "trash", key: "recent") { [weak self] in
                self?.app?.showTrash = true
            },
        ]
    }

    private static func clock() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

struct HoldChrome: View {
    @EnvironmentObject private var hold: HoldController
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors

    var body: some View {
        ZStack {
            if hold.showing { indicator }
            if hold.panel != nil { panel }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // The countdown is visual only. An idle or counting full-screen layer must not eat taps.
        .allowsHitTesting(hold.panel != nil)
    }

    private var indicator: some View {
        let tier = hold.tier
        let progress = CGFloat(hold.progress)
        let accent = tier == .center ? Color(red: 0.812, green: 0.859, blue: 1) : Color(red: 1, green: 0.824, blue: 0.478)
        let r: CGFloat = tier == .center ? 28 : 46
        return ZStack {
            if app.settings.timedCountdown {
                countdown(tier: tier, progress: progress, radius: r, accent: accent)
                    .position(hold.anchor)
            }
            if app.settings.timedShowTime {
                let seconds = Double(hold.elapsedMs) / 1000
                let label = (tier == .center ? "全部按键 · " : "") + String(format: "%.1fs", seconds)
                let toRight = hold.anchor.x < UIScreen.main.bounds.width / 2
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .overlay(Capsule().stroke(accent.opacity(0.7), lineWidth: 0.5))
                    .position(x: hold.anchor.x + (toRight ? r + 54 : -(r + 54)), y: hold.anchor.y)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func countdown(tier: HoldTier, progress: CGFloat, radius: CGFloat, accent: Color) -> some View {
        if tier == .center {
            moon(progress: progress, radius: radius, accent: accent)
        } else {
            ZStack {
                Circle().stroke(Color.white.opacity(0.30), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                ZStack {
                    Circle().fill(Color.white).frame(width: 8, height: 8).offset(y: -radius)
                }
                .rotationEffect(.degrees(360 * progress))
            }
            .frame(width: radius * 2, height: radius * 2)
        }
    }

    private func moon(progress: CGFloat, radius: CGFloat, accent: Color) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.16)).frame(width: radius * 2, height: radius * 2)
            Circle().fill(accent.opacity(0.92)).frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(Color(red: 0.102, green: 0.125, blue: 0.200).opacity(0.92 * (1 - progress)))
                .frame(width: radius * 2.04, height: radius * 2.04)
                .offset(x: radius * 2.1 * progress)
        }
        .frame(width: radius * 2, height: radius * 2)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1))
    }

    private var panel: some View {
        let spec = hold.panel
        let ink = (spec?.overMedia == true) ? MoonColors.media : colors
        return ZStack {
            Color.black.opacity(ink.dark ? 0.45 : 0.25)
                .onTapGesture { hold.dismissPanel() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "square.grid.2x2")
                        Text("全部按键").font(.system(size: 22, weight: .semibold))
                        Spacer()
                        Button("关闭") { hold.dismissPanel() }
                            .font(.system(size: 15, weight: .semibold))
                    }
                    ForEach(spec?.sections ?? []) { section in
                        Text(section.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(ink.textDim)
                        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(section.tiles) { tile in
                                Button {
                                    guard tile.enabled else { return }
                                    Haptics.tick()
                                    hold.dismissPanel()
                                    tile.action()
                                } label: {
                                    VStack(spacing: 6) {
                                        SkinBadge(systemImage: tile.systemImage, key: tile.key, title: tile.title, skins: app.settings.buttonSkins, ink: tile.destructive ? ink.danger : ink.text)
                                            .frame(width: 28, height: 28)
                                        Text(tile.title)
                                            .font(.system(size: 11))
                                            .multilineTextAlignment(.center)
                                            .lineLimit(2)
                                    }
                                    .foregroundColor(tile.enabled ? (tile.destructive ? ink.danger : ink.text) : ink.textDim)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 78)
                                    .background(ink.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .disabled(!tile.enabled)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .foregroundColor(ink.text)
            .moonGlass(ink, radius: 30)
            .padding(.horizontal, 16)
            .padding(.vertical, 28)
        }
    }
}

/// Set while a long-press is active so the button's touch-up does not also run.
enum PressGate {
    static var suppressTap = false
    static func begin() { suppressTap = true }
    static func end() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { suppressTap = false }
    }
}

/// Splits the screen with the system tab bar.
/// A touch that begins inside the bar (including the home-indicator strip) belongs to the system.
/// Once a ring or droplet session is active, the bar's own gestures are suspended so that same touch
/// cannot switch tabs, and they are restored on release.
enum TabChrome {
    /// Top of the custom glass bar, in window coordinates, when 底栏滑块 is off.
    static var customTop: CGFloat?
    private static var saved: [Suspended] = []

    private struct Suspended {
        weak var view: UIView?
        var interaction: Bool
        var gestures: [(UIGestureRecognizer, Bool)]
    }

    /// Full-width strip from the top of the tab bar through the bottom of the window.
    static func region(tabTop: CGFloat, window: CGRect) -> CGRect {
        guard window.width > 1, window.height > 1, tabTop < window.maxY - 1, tabTop > window.minY else { return .null }
        return CGRect(x: window.minX, y: tabTop, width: window.width, height: window.maxY - tabTop)
    }

    static func contains(_ point: CGPoint, tabTop: CGFloat, window: CGRect) -> Bool {
        region(tabTop: tabTop, window: window).contains(point)
    }

    static func blocks(_ point: CGPoint, in window: UIWindow) -> Bool {
        if let top = customTop, contains(point, tabTop: top, window: window.bounds) { return true }
        for bar in visibleBars(in: window) {
            let rect = bar.convert(bar.bounds, to: window)
            if contains(point, tabTop: rect.minY, window: window.bounds) { return true }
        }
        return false
    }

    /// The system tab bar stays in the tree when SwiftUI's toolbar visibility does not stick.
    /// Hidden bars are not hittable, which is what the immersive playback test watches.
    /// Forcing a visible bar back on while a sheet is presenting cancels that sheet, so a bar
    /// that is already showing is left alone, and so is any bar under a presented controller.
    static func setBarHidden(_ hidden: Bool) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            guard let bar = anyTabBar(window.rootViewController) else { continue }
            if !hidden {
                let alreadyShown = !bar.isHidden && bar.alpha > 0.99
                if alreadyShown || isPresenting(window.rootViewController) { continue }
            }
            if bar.isHidden != hidden { bar.isHidden = hidden }
            let alpha: CGFloat = hidden ? 0 : 1
            if abs(bar.alpha - alpha) > 0.01 { bar.alpha = alpha }
        }
    }

    private static func isPresenting(_ vc: UIViewController?) -> Bool {
        guard let vc else { return false }
        if vc.presentedViewController != nil { return true }
        return vc.children.contains { isPresenting($0) }
    }

    private static func anyTabBar(_ vc: UIViewController?) -> UITabBar? {
        if let tabs = vc as? UITabBarController { return tabs.tabBar }
        for child in vc?.children ?? [] {
            if let found = anyTabBar(child) { return found }
        }
        if let presented = vc?.presentedViewController { return anyTabBar(presented) }
        return nil
    }

    static func setSuspended(_ suspended: Bool) {
        if !suspended {
            for item in saved {
                item.view?.isUserInteractionEnabled = item.interaction
                for (gesture, enabled) in item.gestures { gesture.isEnabled = enabled }
            }
            saved.removeAll()
            return
        }
        guard saved.isEmpty else { return }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        for window in windows {
            for bar in visibleBars(in: window) {
                var gestures: [(UIGestureRecognizer, Bool)] = []
                for host in gestureHosts(around: bar) {
                    for gesture in host.gestureRecognizers ?? [] {
                        gestures.append((gesture, gesture.isEnabled))
                        gesture.isEnabled = false
                    }
                }
                saved.append(Suspended(view: bar, interaction: bar.isUserInteractionEnabled, gestures: gestures))
                bar.isUserInteractionEnabled = false
            }
        }
    }

    private static func visibleBars(in window: UIWindow) -> [UIView] {
        var found = bars(in: window)
        if let bar = tabController(window.rootViewController)?.tabBar,
           isTabBar(bar),
           !found.contains(where: { $0 === bar }) {
            found.append(bar)
        }
        return found
    }

    private static func tabController(_ vc: UIViewController?) -> UITabBarController? {
        if let tabs = vc as? UITabBarController { return tabs }
        for child in vc?.children ?? [] {
            if let found = tabController(child) { return found }
        }
        if let presented = vc?.presentedViewController, let found = tabController(presented) { return found }
        return nil
    }

    private static func bars(in view: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ view: UIView) {
            if isTabBar(view) { found.append(view) }
            for sub in view.subviews { walk(sub) }
        }
        walk(view)
        return found
    }

    private static func isTabBar(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.5 else { return false }
        guard view.bounds.height > 20, view.bounds.height < 280, view.bounds.width > 80 else { return false }
        if view is UITabBar { return true }
        let name = String(describing: type(of: view))
        return name.contains("TabBar") && !name.contains("Controller") && !name.contains("Item")
    }

    /// The bar itself, its short container, and any ancestor gesture whose type is the tab switcher.
    private static func gestureHosts(around bar: UIView) -> [UIView] {
        var hosts: [UIView] = [bar]
        if let parent = bar.superview,
           !(parent is UIWindow),
           parent.bounds.height > 1, parent.bounds.height < 320, parent.bounds.width > 80 {
            hosts.append(parent)
        }
        var ancestor = bar.superview
        var hops = 0
        while let current = ancestor, hops < 5, !(current is UIWindow) {
            let switches = (current.gestureRecognizers ?? []).contains { gesture in
                let name = String(describing: type(of: gesture))
                return name.contains("Tab") || name.contains("Switch")
            }
            if switches { hosts.append(current) }
            ancestor = current.superview
            hops += 1
        }
        return hosts
    }
}

/// Re-applies tab-bar visibility after SwiftUI lays the bar back out.
struct TabBarHider: UIViewRepresentable {
    var hidden: Bool

    func makeUIView(context: Context) -> TabBarHiderView {
        let view = TabBarHiderView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: TabBarHiderView, context: Context) {
        uiView.barHidden = hidden
        uiView.apply()
    }
}

final class TabBarHiderView: UIView {
    var barHidden = false
    private var ticket = 0

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    func apply() {
        ticket += 1
        let ticket = ticket
        let hidden = barHidden
        TabChrome.setBarHidden(hidden)
        DispatchQueue.main.async { [weak self] in
            guard let self, ticket == self.ticket else { return }
            TabChrome.setBarHidden(hidden)
        }
    }
}

struct TabBarFrameMark: UIViewRepresentable {
    var active: Bool

    func makeUIView(context: Context) -> TabBarMarkView {
        let view = TabBarMarkView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: TabBarMarkView, context: Context) {
        uiView.active = active
        uiView.report()
    }
}

final class TabBarMarkView: UIView {
    var active = true

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { TabChrome.customTop = nil }
        else { report() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    func report() {
        guard active, let window, bounds.height > 1 else {
            if !active { TabChrome.customTop = nil }
            return
        }
        TabChrome.customTop = convert(bounds, to: window).minY
    }
}

enum HitTags {
    static let media = 7701
}

/// Long-press that does not cancel the Button underneath.
/// The recognizer lives on the window, ignores touches outside this control, and never
/// cancels or delays the button's tap.
struct HoldTrack: ViewModifier {
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var ownsLarge = false
    var cancelsTap = false

    func body(content: Content) -> some View {
        content.background(HoldProbe(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded, ownsLarge: ownsLarge, cancelsTap: cancelsTap))
    }
}

extension View {
    func holdTrack(
        onBegan: @escaping (CGPoint) -> Void,
        onChanged: @escaping (CGPoint) -> Void,
        onEnded: @escaping (CGPoint) -> Void,
        ownsLarge: Bool = false,
        cancelsTap: Bool = false
    ) -> some View {
        modifier(HoldTrack(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded, ownsLarge: ownsLarge, cancelsTap: cancelsTap))
    }
}

/// A long-press that must not block SwiftUI Button taps on the same control.
final class FriendlyLongPress: UILongPressGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

enum LongPressInstall {
    /// Movement allowed before the press is recognized. A scroll that travels farther than this
    /// fails the recognizer and keeps going. Once the ring has opened, UIKit no longer applies
    /// this limit, so the finger can still drag onto a button or across the tab bar.
    static let slop: CGFloat = 32

    static func configure(_ hold: UILongPressGestureRecognizer) {
        hold.minimumPressDuration = 0.5
        hold.allowableMovement = slop
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
    }
}

private final class ProbeRegions {
    static let shared = ProbeRegions()
    let probes = NSHashTable<HoldProbeView>.weakObjects()
    func owns(_ point: CGPoint, window: UIWindow) -> Bool {
        for case let probe as HoldProbeView in probes.allObjects {
            guard probe.window === window else { continue }
            let rect = probe.convert(probe.bounds, to: window)
            if !probe.ownsLarge, rect.width > window.bounds.width * 0.9, rect.height > window.bounds.height * 0.4 { continue }
            if rect.width > 1, rect.height > 1, rect.contains(point) { return true }
        }
        return false
    }

    /// A smaller control inside a large card keeps the press. The card does not steal it.
    func smallerClaim(_ point: CGPoint, than probe: HoldProbeView, window: UIWindow) -> Bool {
        let mine = probe.convert(probe.bounds, to: window)
        let mineArea = mine.width * mine.height
        guard mineArea > 1 else { return false }
        for case let other as HoldProbeView in probes.allObjects {
            if other === probe || other.window !== window { continue }
            let rect = other.convert(other.bounds, to: window)
            let area = rect.width * rect.height
            if area > 1, area < mineArea * 0.85, rect.contains(point) { return true }
        }
        return false
    }
}

struct GlobalLongPress: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void

    func makeUIView(context: Context) -> GlobalPressView {
        let view = GlobalPressView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: GlobalPressView, context: Context) {
        context.coordinator.parent = self
        uiView.coordinator = context.coordinator
        uiView.isUserInteractionEnabled = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: GlobalLongPress
        init(_ parent: GlobalLongPress) { self.parent = parent }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: gesture.view?.window)
            switch gesture.state {
            case .began:
                PressGate.begin()
                parent.onBegan(point)
            case .changed:
                parent.onChanged(point)
            case .ended, .cancelled, .failed:
                parent.onEnded(point)
                PressGate.end()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current.tag == HitTags.media { return false }
                view = current.superview
            }
            guard let window = touch.window else { return true }
            let point = touch.location(in: window)
            if TabChrome.blocks(point, in: window) { return false }
            return !ProbeRegions.shared.owns(point, window: window)
        }
    }
}

final class GlobalPressView: UIView {
    weak var coordinator: GlobalLongPress.Coordinator?
    private var recognizer: FriendlyLongPress?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            return
        }
        DispatchQueue.main.async { [weak self] in self?.install() }
    }

    private func install() {
        guard recognizer == nil, let coordinator, let window else { return }
        let hold = FriendlyLongPress(target: coordinator, action: #selector(GlobalLongPress.Coordinator.hold(_:)))
        LongPressInstall.configure(hold)
        hold.delegate = coordinator
        window.addGestureRecognizer(hold)
        recognizer = hold
    }

    deinit {
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
    }
}

private struct HoldProbe: UIViewRepresentable {
    var onBegan: (CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var ownsLarge: Bool
    var cancelsTap: Bool

    func makeUIView(context: Context) -> HoldProbeView {
        let view = HoldProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.ownsLarge = ownsLarge
        view.cancelsTap = cancelsTap
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: HoldProbeView, context: Context) {
        context.coordinator.parent = self
        uiView.coordinator = context.coordinator
        uiView.ownsLarge = ownsLarge
        uiView.cancelsTap = cancelsTap
        uiView.recognizer?.cancelsTouchesInView = cancelsTap
        uiView.isUserInteractionEnabled = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: HoldProbe
        init(_ parent: HoldProbe) { self.parent = parent }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: gesture.view?.window)
            switch gesture.state {
            case .began:
                PressGate.begin()
                parent.onBegan(point)
            case .changed:
                parent.onChanged(point)
            case .ended, .cancelled, .failed:
                parent.onEnded(point)
                PressGate.end()
            default:
                break
            }
        }
    }
}

private final class HoldProbeView: UIView {
    weak var coordinator: HoldProbe.Coordinator?
    var recognizer: FriendlyLongPress?
    var ownsLarge = false
    var cancelsTap = false
    private var gate: ProbeGate?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            ProbeRegions.shared.probes.remove(self)
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            return
        }
        ProbeRegions.shared.probes.add(self)
        DispatchQueue.main.async { [weak self] in self?.install() }
    }

    private func install() {
        guard recognizer == nil, let coordinator, let window else { return }
        let gate = ProbeGate(probe: self)
        self.gate = gate
        let hold = FriendlyLongPress(target: coordinator, action: #selector(HoldProbe.Coordinator.hold(_:)))
        LongPressInstall.configure(hold)
        hold.cancelsTouchesInView = cancelsTap
        hold.delegate = gate
        window.addGestureRecognizer(hold)
        recognizer = hold
    }

    deinit {
        ProbeRegions.shared.probes.remove(self)
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
    }
}

/// Receives a touch only when it lands on this control, and never when SwiftUI stretched the probe over the screen.
private final class ProbeGate: NSObject, UIGestureRecognizerDelegate {
    weak var probe: HoldProbeView?
    init(probe: HoldProbeView) { self.probe = probe }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let probe, let window = probe.window else { return false }
        let rect = probe.convert(probe.bounds, to: window)
        if !probe.ownsLarge, rect.width > window.bounds.width * 0.9, rect.height > window.bounds.height * 0.4 { return false }
        guard rect.width > 1, rect.height > 1 else { return false }
        let point = touch.location(in: window)
        guard rect.contains(point) else { return false }
        return !ProbeRegions.shared.smallerClaim(point, than: probe, window: window)
    }
}
