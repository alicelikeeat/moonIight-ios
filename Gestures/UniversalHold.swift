import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Keep the generator alive between touch-down and recognition. Creating a
// generator at the instant a long press begins is unreliable on device: the
// Taptic Engine may not have time to prepare before the menu animation starts.
@MainActor
final class LongPressHapticFeedback {
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

extension View {
    func universalLongPress(target: BackgroundTarget) -> some View {
        modifier(UniversalHoldScope(target: target))
    }
}

enum HoldDestination: Identifiable {
    case background(BackgroundTarget), backgrounds, guide, more, menus, backgroundLibrary
    var id: String {
        switch self { case .background(let target): target.rawValue; case .backgrounds: "backgrounds"; case .guide: "guide"; case .more: "more"; case .menus: "menus"; case .backgroundLibrary: "backgroundLibrary" }
    }
}

struct UniversalHoldScope: ViewModifier {
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
                GlobalHoldObserver(enabled: menu == nil && globalSearch == nil && model.activeLongPressMenu == nil && model.selectedTab != .sandbox,
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
            .onReceive(NotificationCenter.default.publisher(for: .init("moonlight.navigationHeld"))) { note in
                let raw = note.userInfo?["tab"] as? String
                if let raw, let tab = AppTab(rawValue: raw) { heldTarget = .button(for: tab) }
                func coordinate(_ key: String) -> CGFloat? {
                    if let value = note.userInfo?[key] as? CGFloat { return value }
                    if let value = note.userInfo?[key] as? Double { return CGFloat(value) }
                    if let value = note.userInfo?[key] as? NSNumber { return CGFloat(truncating: value) }
                    return nil
                }
                let point = CGPoint(x: coordinate("x") ?? 200, y: coordinate("y") ?? 640)
                LongPressHapticFeedback.shared.menuOpened()
                var opened = ActiveLongPressMenu(entry: nil, location: point, fingerLocation: point)
                opened.fingerDown = false
                menu = opened
            }
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
                            List { Group {
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
                                }.listRowBackground(MoonLiquidRowBackground())
                            }.moonLiquidList().navigationTitle("更多操作")
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
        List { Group {
            Label("先移动手指：优先滚动，不触发点按或长按", systemImage: "arrow.up.and.down")
            Label("静止按住：触感反馈，圆环旋转打开", systemImage: "hand.point.up.left")
            Label("松手后圆环保持打开，再点按执行", systemImage: "hand.tap")
            Label("媒体卡片显示播放、收藏、加入库和分享", systemImage: "play.rectangle")
            Label("页面空白和按键显示背景、刷新等常用操作", systemImage: "square.grid.2x2")
            Label("中心 … 打开更多操作；点空白处或下滑收起", systemImage: "ellipsis.circle")
            Label("输入框与系统照片选择器保留系统手势", systemImage: "keyboard")
            }.listRowBackground(MoonLiquidRowBackground())
        }.moonLiquidList().navigationTitle("手势说明")
    }
}

// Observe the hosting view instead of laying a touch-swallowing layer over it.
// There is no pan recognizer: movement cancels a hold at 7 pt, leaving UIScrollView
// in charge. Native pickers, text editing and media-card recognizers stay local.
struct GlobalHoldObserver: UIViewRepresentable {
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

final class GlobalHoldMarker: UIView, UIGestureRecognizerDelegate {
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
        // The tab controls own tap versus long-press. Leaving this recognizer
        // out of that touch keeps a hold from being cancelled or turned into a tab switch.
        if touchHitsNavigationChrome(touch) { return false }
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
        if navigationChrome(touch.view) { return true }
        guard let window = touch.window ?? self.window else { return false }
        return navigationChrome(window.hitTest(touch.location(in: window), with: nil))
    }
    private func navigationChrome(_ view: UIView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is NativeSlidingTabBar || candidate is PriorityTabView { return true }
            if let identifier = candidate.accessibilityIdentifier,
               identifier == "navigation-slider" || identifier.hasPrefix("navigation-") {
                return true
            }
            current = candidate.superview
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

struct LongPressRingOverlay: View {
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
struct RingTouchButton: UIViewRepresentable {
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

final class RingTouchControl: UIButton {
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
