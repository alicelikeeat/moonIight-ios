import PhotosUI
import SwiftUI
import UIKit

struct RingItem: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var children: [RingItem] = []
    var enabled: Bool = true
    var key: String?
    /// Accessibility id when this bubble is not addressed as `ring.标题`.
    var accessID: String? = nil
    var destructive: Bool = false
    var action: () -> Void = {}
}

struct MenuGroup: Identifiable {
    let id = UUID()
    var title: String
    var danger: Bool = false
    var items: [RingItem]
}

/// Captured menu for the more sheet. The groups travel with the item so the sheet
/// is never built from a binding that SwiftUI clears while it is presenting.
struct RingSheet: Identifiable {
    let id = UUID()
    var groups: [MenuGroup]
    var dark: Bool
}

struct RingSession: Identifiable {
    let id = UUID()
    var origin: CGPoint
    var items: [RingItem]
    var groups: [MenuGroup]
    var style: RingAnim
    var backdrop: MenuBackdrop
    var select: MenuSelect
    /// 水滴选择. Off unless the setting is on. Taps still work either way.
    var drop: Bool
    var overMedia: Bool
    var starSpeed: Float
    var started = Date()
    /// Extra test id, drawn beside the ring so it does not replace the bubbles' ids.
    var marker: String? = nil
}

/// The ring that opened 更多, so 按键背景 can bring the same buttons back into edit mode.
struct RingSnap {
    var origin: CGPoint
    var items: [RingItem]
    var groups: [MenuGroup]
    var overMedia: Bool
    var settings: AppSettings
    var marker: String? = nil
}

@MainActor
final class RingController: ObservableObject {
    @Published var session: RingSession?
    @Published var fingerDown = false
    @Published var finger = CGPoint.zero
    @Published var expanded: UUID?
    @Published var menu: RingSheet?
    @Published var closing = false
    @Published var settled = false
    @Published var closeStarted: Date?
    @Published var bubbleLive = false
    /// Quick edit: taps select ring buttons instead of running them. 水滴 and drag-release do not fire.
    @Published var skinEdit = false
    @Published var skinPicked = Set<String>()
    @Published var pendingSkin: ButtonSkin?
    var overlayOrigin = CGPoint.zero
    /// 更多 › 长按动画. The ring stores the choice; the app saves it.
    var onPickAnim: ((String) -> Void)?
    let bubbles = BubbleField()
    private var closeTask: Task<Void, Never>?
    private var landed: Set<Int> = []
    private var lastSnap: RingSnap?

    func present(origin: CGPoint, items: [RingItem], groups: [MenuGroup], settings: AppSettings, overMedia: Bool = false, styleOverride: RingAnim? = nil, marker: String? = nil, editing: Bool = false) {
        // A second long-press must not replace the ring while button skins are being chosen.
        if skinEdit && !editing { return }
        closeTask?.cancel()
        let reduce = UIAccessibility.isReduceMotionEnabled
        let picked = styleOverride ?? RingAnimPick.pick(
            setting: settings.ringAnim,
            enabled: RingAnimPick.parseSet(settings.ringAnimSet),
            animatorScale: reduce ? 0 : 1
        )
        let style: RingAnim = reduce ? .fade : picked
        landed = []
        expanded = nil
        closing = false
        settled = false
        bubbleLive = false
        if editing {
            skinEdit = true
        } else {
            skinEdit = false
            skinPicked = []
            pendingSkin = nil
        }
        bubbles.reset()
        bubbles.onNearest = { _ in Haptics.tick() }
        let storedGroups = withAnimAction(Self.withSkinAction(groups) { [weak self] in
            self?.beginSkinEdit()
        }, current: settings.ringAnim)
        let shown = Array(items.prefix(5))
        lastSnap = RingSnap(origin: origin, items: shown, groups: storedGroups, overMedia: overMedia, settings: settings, marker: marker)
        session = RingSession(
            origin: origin,
            items: shown,
            groups: storedGroups,
            style: style,
            backdrop: settings.menuBackdrop,
            select: settings.menuSelect == .drop ? .tap : settings.menuSelect,
            drop: settings.dropSelect || settings.menuSelect == .drop,
            overMedia: overMedia,
            starSpeed: RingMotion.clampSpeed(settings.starSpeed),
            marker: marker
        )
        Haptics.light()
    }

    func noteLanded(_ index: Int) {
        if landed.insert(index).inserted { Haptics.light() }
    }

    func beginClose(then: (() -> Void)? = nil) {
        guard session != nil, !closing else { return }
        closeStarted = Date()
        closing = true
        settled = false
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard let self, !Task.isCancelled else { return }
            self.session = nil
            self.closing = false
            self.expanded = nil
            self.settled = false
            self.closeStarted = nil
            self.skinEdit = false
            self.skinPicked = []
            then?()
        }
    }

    /// Reopens the ring that was just closed into the more sheet, in button-skin edit mode.
    func beginSkinEdit() {
        guard let snap = lastSnap else { return }
        skinPicked = []
        pendingSkin = nil
        present(origin: snap.origin, items: snap.items, groups: snap.groups, settings: snap.settings, overMedia: snap.overMedia, marker: snap.marker, editing: true)
    }

    func endSkinEdit() {
        skinEdit = false
        skinPicked = []
        pendingSkin = nil
        dismiss()
    }

    func toggleSkin(_ id: ButtonSkinID) {
        if skinPicked.contains(id.rawValue) { skinPicked.remove(id.rawValue) }
        else { skinPicked.insert(id.rawValue) }
        Haptics.tick()
    }

    /// One glass group in 更多. Each row is a style; the current one wears a check.
    private func withAnimAction(_ groups: [MenuGroup], current: String) -> [MenuGroup] {
        guard onPickAnim != nil else { return groups }
        if groups.contains(where: { $0.items.contains { ($0.key ?? "").hasPrefix("anim.") } }) { return groups }
        let currentNorm = RingAnimPick.normalize(current)
        let rows: [(String, String, String)] = RingAnim.choices.map { ($0.rawValue, $0.label, Self.animSymbol($0)) }
            + [(RingAnim.random, RingAnimPick.randomLabel, "dice")]
        let items = rows.map { raw, title, symbol in
            RingItem(
                title: title,
                systemImage: currentNorm == raw ? "checkmark.circle.fill" : symbol,
                key: "anim.\(raw.lowercased())"
            ) { [weak self] in
                self?.onPickAnim?(raw)
            }
        }
        var copy = groups
        copy.append(MenuGroup(title: "长按动画", items: items))
        return copy
    }

    private static func animSymbol(_ style: RingAnim) -> String {
        switch style {
        case .spin: return "arrow.triangle.2.circlepath"
        case .lotus: return "camera.macro"
        case .star: return "sparkles"
        case .moon: return "moon.stars"
        case .fade: return "circle.dotted"
        }
    }

    private static func withSkinAction(_ groups: [MenuGroup], action: @escaping () -> Void) -> [MenuGroup] {
        if groups.contains(where: { $0.items.contains { $0.key == "skins" } }) { return groups }
        var copy = groups
        copy.append(MenuGroup(title: "按键", items: [
            RingItem(title: "按键背景", systemImage: "circle.grid.2x2.fill", key: "skins", action: action),
        ]))
        return copy
    }

    /// Drag-mode release. Recomputes the same full-screen layout the overlay uses.
    func selectDrag(at global: CGPoint) {
        guard !skinEdit else { return }
        guard let session, session.select == .drag || session.select == .slider, !session.drop else { return }
        let size = UIScreen.main.bounds.size
        let n = session.items.count
        let margin = 16.0
        let radius = n <= 2 ? 100.0 : 118.0
        let geo = RadialGeometry.layout(
            originX: Double(session.origin.x), originY: Double(session.origin.y), n: n,
            left: margin, top: Double(ScreenInsets.top) + margin,
            right: Double(size.width) - margin,
            bottom: Double(size.height) - Double(ScreenInsets.bottom) - margin - 28,
            radius: radius, itemR: 58
        )
        if hypot(global.x - geo.centerX, global.y - geo.centerY) < 30 {
            openSheet()
            return
        }
        var best: Int?
        var bestD = 48.0
        for i in session.items.indices {
            let (x, y) = geo.pos(i)
            let d = hypot(global.x - x, global.y - y)
            if d < bestD { bestD = d; best = i }
        }
        if let best {
            let item = session.items[best]
            if item.children.isEmpty {
                item.action()
                Haptics.confirm()
                dismiss()
            } else {
                expanded = item.id
                Haptics.tick()
            }
        }
    }

    func dismiss() { beginClose() }

    /// Lift while 水滴选择 is on. The button under the droplet fires; empty space cancels; a still finger leaves the ring up.
    func releaseFinger(at global: CGPoint) {
        guard !skinEdit else { return }
        guard let session, session.drop else { return }
        let local = CGPoint(x: global.x - overlayOrigin.x, y: global.y - overlayOrigin.y)
        if !bubbles.lastCenters.isEmpty {
            bubbles.step(
                target: local,
                centers: bubbles.lastCenters,
                now: Date().timeIntervalSinceReferenceDate + 0.05,
                tracking: true,
                force: true
            )
        }
        let moved = hypot(Double(global.x - session.origin.x), Double(global.y - session.origin.y))
        guard let hit = bubbles.nearest, session.items.indices.contains(hit) else {
            if case .cancel = DropAim.decide(hit: nil, destructive: false, hasUndo: false, moved: moved) {
                dismiss()
            }
            return
        }
        let item = session.items[hit]
        let decision = DropAim.decide(hit: hit, destructive: item.destructive, hasUndo: true, moved: moved)
        switch decision {
        case .fire:
            guard item.enabled else { return }
            if item.children.isEmpty {
                // Destructive actions are deleteEntry, which already toasts 撤销. Nothing silent.
                item.action()
                if item.destructive { Haptics.warn() } else { Haptics.confirm() }
                dismiss()
            } else {
                expanded = item.id
                Haptics.tick()
            }
        case .cancel:
            dismiss()
        case .stay:
            break
        }
    }

    func openSheet() {
        let groups = session?.groups ?? []
        let dark = session?.overMedia ?? false
        beginClose()
        guard !groups.isEmpty else { return }
        menu = RingSheet(groups: groups, dark: dark)
    }
}

struct RingOverlay: View {
    @ObservedObject var ring: RingController
    @EnvironmentObject private var app: AppModel
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            ZStack {
                ZStack { backdrop }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !ring.skinEdit else { return }
                        ring.dismiss()
                    }
                if let session = ring.session {
                    ringBody(session, localOrigin: CGPoint(x: session.origin.x - frame.minX, y: session.origin.y - frame.minY), size: geo.size)
                }
                Text("圆环")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.02))
                    .accessibilityIdentifier("ring.root")
                    .frame(width: 48, height: 24)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let marker = ring.session?.marker {
                    Color.clear
                        .frame(width: 4, height: 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier(marker)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if ring.skinEdit {
                SkinEditBar(ring: ring)
                    .padding(.horizontal, 16)
                    .padding(.bottom, ScreenInsets.bottom + 16)
            }
        }
        .allowsHitTesting(!(ring.fingerDown && ring.session?.drop == true && !ring.skinEdit))
    }

    @ViewBuilder private var backdrop: some View {
        let session = ring.session
        let style = session?.style ?? .fade
        let dim = session?.backdrop.dim ?? 0
        if style == .moon {
            Color.black.opacity(0.95 * (ring.closing ? 0.4 : 1))
        } else if dim <= 0 {
            Color.clear
        } else if (session?.backdrop ?? .blur) == .light {
            Rectangle().fill(.ultraThinMaterial).opacity(0.45 * dim)
            Color.black.opacity(0.18 * dim)
        } else {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.28 * dim)
        }
    }

    private func ringBody(_ session: RingSession, localOrigin: CGPoint, size: CGSize) -> some View {
        let n = max(session.items.count, 1)
        let margin: Double = 16
        let itemR: Double = 36
        let radius: Double = n <= 2 ? 100 : 118
        let top = Double(ScreenInsets.top) + margin
        let bottom = size.height - Double(ScreenInsets.bottom) - margin - 28
        let geo = RadialGeometry.layout(
            originX: Double(localOrigin.x), originY: Double(localOrigin.y), n: session.items.count,
            left: margin, top: top, right: Double(size.width) - margin, bottom: bottom,
            radius: radius, itemR: itemR + 22
        )
        let deadline = Double(RingMotion.openMs(session.style, session.items.count, session.starSpeed)) / 1000 + 0.08
        let paused = ring.settled && !ring.closing && !ring.fingerDown && !ring.bubbleLive
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(session.started)
            let closingT = ring.closing ? min(1, max(0, elapsed > 0 ? closeProgress(session) : 0)) : 0
            let poses = session.items.indices.map { buttonPose(session, index: $0, elapsed: elapsed, closing: closingT) }
            let centers = poses.indices.map { buttonCenter(geo: geo, index: $0, pose: poses[$0], size: size) }
            let overlayOrigin = CGPoint(x: session.origin.x - localOrigin.x, y: session.origin.y - localOrigin.y)
            let localFinger = CGPoint(x: ring.finger.x - overlayOrigin.x, y: ring.finger.y - overlayOrigin.y)
            let _ = {
                ring.overlayOrigin = overlayOrigin
                ring.bubbles.step(
                    target: localFinger,
                    centers: centers,
                    now: timeline.date.timeIntervalSinceReferenceDate,
                    tracking: ring.fingerDown
                )
            }()
            ZStack {
                if session.style == .moon {
                    moon(size: size, lit: ring.closing ? 0.3 : 1)
                }
                Canvas { context, _ in
                    guard session.style == .star else { return }
                    for i in session.items.indices {
                        drawTrail(context: context, geo: geo, index: i, pose: poses[i], size: size, session: session, elapsed: elapsed)
                    }
                }
                .allowsHitTesting(false)
                ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                    ringButton(
                        item,
                        pose: poses[index],
                        center: centers[index],
                        session: session,
                        parentAngle: geo.angles[index],
                        radius: geo.radius,
                        influence: ring.bubbles.influence(index),
                        finger: ring.bubbles.finger,
                        time: Float(elapsed),
                        index: index
                    )
                    .moonOnChange(of: poses[index].fx2) { value in
                        if value > 0.2 { ring.noteLanded(index) }
                    }
                }
                if ring.fingerDown && session.drop {
                    FingerLens()
                        .position(ring.bubbles.finger)
                        .allowsHitTesting(false)
                }
                moreButton(session, geo: geo, elapsed: elapsed, closing: closingT, size: size)
            }
            .moonOnChange(of: timeline.date) { _ in
                if !ring.closing && elapsed >= deadline { ring.settled = true }
                let live = ring.bubbles.live
                if ring.bubbleLive != live { ring.bubbleLive = live }
            }
        }
    }

    private func closeProgress(_ session: RingSession) -> Double {
        _ = session
        // Closing uses a fresh clock stored by flipping `closing`; approximate with 300ms from now-ish.
        // The controller sleeps 320ms. We animate cl with a local state instead.
        return 1
    }

    private func buttonPose(_ session: RingSession, index: Int, elapsed: TimeInterval, closing _: Double) -> RingMotion.Pose {
        if ring.settled && !ring.closing {
            return RingMotion.pose(session.style, 1, 1, false)
        }
        let n = session.items.count
        let stagger = Double(RingMotion.starStaggerMs(n)) / 1000
        let flight = Double(RingMotion.starFlightMs) / 1000
        switch session.style {
        case .star:
            let speed = Double(RingMotion.clampSpeed(session.starSpeed))
            let local = elapsed - (stagger / speed) * Double(index)
            let o = Float(min(1, max(0, local / (flight / speed))))
            let cl = Float(ring.closing ? closeClock() : 1)
            return RingMotion.pose(.star, ring.closing ? 1 : o, cl, ring.closing, depth: RingMotion.starDepth(index))
        case .spin:
            let rate = Double(RingMotion.clampSpeed(session.starSpeed))
            let flight = Double(RingMotion.spinFlightMs) / 1000 / rate
            let stagger = Double(RingMotion.spinStaggerMs) / 1000 / rate
            let raw = (elapsed - stagger * Double(index)) / flight
            let o = Float(min(1, max(0, raw)))
            return RingMotion.pose(.spin, ring.closing ? 1 : o, Float(ring.closing ? closeClock() : 1), ring.closing)
        case .lotus:
            let o = Float(min(1, max(0, (elapsed - 0.038 * Double(index)) / 0.52)))
            return RingMotion.pose(.lotus, ring.closing ? 1 : o, Float(ring.closing ? closeClock() : 1), ring.closing)
        case .moon:
            let o = Float(min(1, max(0, (elapsed - 0.06 * Double(index)) / 0.46)))
            return RingMotion.pose(.moon, ring.closing ? 1 : o, Float(ring.closing ? closeClock() : 1), ring.closing)
        case .fade:
            let o = Float(min(1, max(0, elapsed / 0.16)))
            return RingMotion.pose(.fade, ring.closing ? 1 : o, Float(ring.closing ? closeClock() : 1), ring.closing)
        }
    }

    private func closeClock() -> Double {
        guard let start = ring.closeStarted else { return 1 }
        return min(1, max(0, 1 - Date().timeIntervalSince(start) / 0.30))
    }

    private func buttonCenter(geo: RadialResult, index: Int, pose: RingMotion.Pose, size: CGSize) -> CGPoint {
        let r = geo.radius * Double(pose.rf)
        let (x, y) = geo.pos(index, r: r, extraDeg: Double(pose.ang))
        let lift = Double(pose.lift) * (Double(size.height) * 0.92 + 40)
        let sink = Double(pose.sink) * 48
        return CGPoint(x: x, y: y - lift + sink)
    }

    private func drawTrail(context: GraphicsContext, geo: RadialResult, index: Int, pose: RingMotion.Pose, size: CGSize, session: RingSession, elapsed: TimeInterval) {
        guard session.style == .star else { return }
        let speed = Double(RingMotion.clampSpeed(session.starSpeed))
        let stagger = Double(RingMotion.starStaggerMs(session.items.count)) / 1000 / speed
        let flight = Double(RingMotion.starFlightMs) / 1000 / speed
        let o = Float(min(1, max(0, (elapsed - stagger * Double(index)) / flight)))
        let travel = RingMotion.starTravel(ring.closing ? 1 : o)
        guard pose.fx > 0.02 || pose.lift > 0.02 || pose.fx2 > 0.02 else { return }
        var dot = RingMotion.Pose()
        let steps = 16
        for s in 0..<steps {
            let back = Float(s) / Float(steps)
            let u = max(0, travel - back * 0.42)
            RingMotion.starOrbit(u, &dot)
            dot.lift *= (1.15 - 0.15 * RingMotion.starDepth(index))
            let center = buttonCenter(geo: geo, index: index, pose: dot, size: size)
            let fade = Double(steps - s) / Double(steps)
            let alpha = Double(max(pose.fx, 0.15)) * fade
            let cool = 11.0 * fade + 2
            let warm = 6.5 * fade + 1.4
            let core = 2.4 * fade + 0.8
            func blob(_ radius: Double, _ color: Color) {
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
            blob(cool, Color(red: 0.62, green: 0.74, blue: 0.95).opacity(alpha * 0.28))
            blob(warm, Color(red: 0.98, green: 0.78, blue: 0.45).opacity(alpha * 0.55))
            blob(core, Color.white.opacity(alpha * 0.9))
        }
        let center = buttonCenter(geo: geo, index: index, pose: pose, size: size)
        if pose.fx2 > 0.02 {
            let burst = 18 + Double(pose.fx2) * 46
            let ring = CGRect(x: center.x - burst, y: center.y - burst, width: burst * 2, height: burst * 2)
            context.stroke(Path(ellipseIn: ring), with: .color(Color(red: 1, green: 0.94, blue: 0.78).opacity(Double(pose.fx2) * 0.85)), lineWidth: 2)
            context.fill(Path(ellipseIn: ring.insetBy(dx: burst * 0.35, dy: burst * 0.35)), with: .color(Color.white.opacity(Double(pose.fx2) * 0.35)))
            for k in 0..<8 {
                let a = Double(k) / 8 * Double.pi * 2 + Double(pose.fx2)
                let dist = 16 + Double(pose.fx2) * 28
                let spark = CGRect(x: center.x + cos(a) * dist - 1.6, y: center.y + sin(a) * dist - 1.6, width: 3.2, height: 3.2)
                context.fill(Path(ellipseIn: spark), with: .color(Color.white.opacity(Double(pose.fx2) * 0.9)))
            }
        }
    }

    private func ringButton(_ item: RingItem, pose: RingMotion.Pose, center: CGPoint, session: RingSession, parentAngle: Double, radius: Double, influence: Float = 0, finger: CGPoint = .zero, time: Float = 0, index: Int = 0) -> some View {
        let highlighted = ring.fingerDown && ring.bubbles.nearest == index
        let skinID = ButtonSkins.identify(key: item.key, title: item.title)
        let selected = ring.skinEdit && skinID.map { ring.skinPicked.contains($0.rawValue) } == true
        let lift = influence
        let ink: Color = session.overMedia ? .white : Color.primary
        let plate = session.overMedia ? MoonColors.media.glassTint : Color.primary.opacity(0.08)
        let boost = CGFloat(pose.scale) * CGFloat(BubbleMotion.scaleBoost(lift))
        var shift = BubbleMotion.offset(from: center, to: finger, influence: lift)
        shift.height += BubbleMotion.bob(influence: lift, time: time, index: index)
        let wobble = BubbleMotion.wobbleDegrees(influence: lift, time: time, index: index)
        return ZStack {
            if session.style == .lotus {
                lotus(pose: pose)
            }
            VStack(spacing: 6) {
                SkinBadge(systemImage: item.systemImage, key: item.key, title: item.title, skins: app.settings.buttonSkins, ink: ink)
                    .frame(width: 56, height: 56)
                    .moonDisc(overMedia: session.overMedia)
                    .background(Circle().fill(highlighted ? Color.white.opacity(0.34) : plate))
                    .overlay(Circle().stroke(session.overMedia ? Color.white.opacity(0.55) : Color.primary.opacity(0.18), lineWidth: highlighted ? 1.6 : 0.8))
                    .overlay {
                        Circle()
                            .fill(Color.white.opacity(Double(BubbleMotion.highlight(lift)) * 0.55))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        if pose.fx3 > 0.05 {
                            Circle()
                                .trim(from: 0.05, to: 0.28)
                                .stroke(Color.white.opacity(Double(pose.fx3)), lineWidth: 2)
                                .rotationEffect(.degrees(Double(pose.fx3) * 220))
                                .padding(2)
                        }
                    }
                    .shadow(color: .black.opacity(0.18 + 0.32 * Double(lift)), radius: 8 + 14 * CGFloat(lift), y: 4 + 6 * CGFloat(lift))
                    .overlay {
                        if selected {
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                                .background(Circle().fill(Color.white.opacity(0.22)))
                                .frame(width: 56, height: 56)
                                .allowsHitTesting(false)
                        }
                    }
                    .rotationEffect(.degrees(Double(pose.rot)))
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .moonCapsule(overMedia: session.overMedia || session.style == .moon || session.style == .lotus)
                    .shadow(color: .black.opacity(session.backdrop.labelShadow || !session.overMedia ? 0.35 : 0.8), radius: 3, y: 1)
                    .opacity(Double(pose.label))
            }
            .scaleEffect(max(0.05, boost))
            .rotationEffect(.degrees(Double(wobble)))
            .opacity(Double(pose.alpha))
            .offset(shift)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.title)
            .accessibilityIdentifier(item.accessID ?? "ring.\(item.title)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
            .onTapGesture {
                if ring.skinEdit {
                    if let skinID { ring.toggleSkin(skinID) }
                    return
                }
                guard item.enabled else { return }
                app.nudgeChrome()
                Haptics.tick()
                if item.children.isEmpty {
                    item.action()
                    ring.dismiss()
                } else if item.children.count > 6 {
                    ring.menu = RingSheet(groups: [MenuGroup(title: item.title, items: item.children)], dark: session.overMedia)
                    ring.beginClose()
                } else {
                    ring.expanded = ring.expanded == item.id ? nil : item.id
                }
            }
            if ring.expanded == item.id {
                subArc(item, parentAngle: parentAngle, radius: radius + 74, center: center)
            }
        }
        .position(center)
    }

    private func subArc(_ item: RingItem, parentAngle: Double, radius: Double, center _: CGPoint) -> some View {
        let angles = RadialGeometry.subArc(parentDeg: parentAngle, k: item.children.count, r: radius, chipGap: 64)
        return ZStack {
            ForEach(Array(item.children.enumerated()), id: \.element.id) { i, child in
                let rad = angles[i] * .pi / 180
                Button {
                    guard !ring.skinEdit, child.enabled else { return }
                    Haptics.confirm()
                    child.action()
                    ring.dismiss()
                } label: {
                    Text(child.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor((ring.session?.overMedia ?? false) ? .white : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .moonCapsule(overMedia: ring.session?.overMedia ?? false)
                        .overlay(Capsule().stroke(Color.white.opacity(0.45), lineWidth: 0.6))
                }
                .offset(x: 92 * CGFloat(cos(rad)), y: 92 * CGFloat(sin(rad)))
                .opacity(child.enabled ? 1 : 0.4)
            }
        }
    }

    private func lotus(pose: RingMotion.Pose) -> some View {
        let inner = CGFloat(RingMotion.lotusInner(pose.fx))
        let outer = CGFloat(RingMotion.lotusOuter(pose.fx))
        let petals = ZStack {
            ForEach(0..<8, id: \.self) { i in
                glassPetal(width: 16, height: 34)
                    .offset(y: -30 * outer)
                    .rotationEffect(.degrees(Double(i) / 8 * 360))
                    .scaleEffect(max(0.2, outer))
            }
            ForEach(0..<5, id: \.self) { i in
                glassPetal(width: 14, height: 26, warm: true)
                    .offset(y: -22 * inner)
                    .rotationEffect(.degrees(Double(i) / 5 * 360 + 18))
                    .scaleEffect(max(0.2, inner))
            }
        }
        .allowsHitTesting(false)
        return Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 10) { petals }
            } else {
                petals
            }
        }
    }

    @ViewBuilder private func glassPetal(width: CGFloat, height: CGFloat, warm: Bool = false) -> some View {
        let tint = warm ? Color(red: 0.98, green: 0.91, blue: 0.72) : Color.white
        if #available(iOS 26.0, *) {
            Color.clear
                .frame(width: width, height: height)
                .glassEffect(.regular.tint(tint.opacity(0.45)), in: Capsule())
        } else {
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(width: width, height: height)
                .overlay(Capsule().fill(tint.opacity(0.28)))
                .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.6))
        }
    }

    private func moon(size: CGSize, lit: Double) -> some View {
        ZStack {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: 84, height: 84)
                    .glassEffect(.regular.tint(Color(red: 0.96, green: 0.93, blue: 0.82).opacity(0.7)), in: Circle())
            } else {
                Circle().fill(.ultraThinMaterial).frame(width: 84, height: 84)
                Circle().fill(Color(red: 0.96, green: 0.94, blue: 0.86).opacity(0.62)).frame(width: 84, height: 84)
            }
            Circle()
                .fill(LinearGradient(colors: [Color.white.opacity(0.85), Color.white.opacity(0.05)], startPoint: .topLeading, endPoint: .center))
                .frame(width: 28, height: 28)
                .offset(x: -16, y: -18)
            Circle().stroke(Color.white.opacity(0.55), lineWidth: 1).frame(width: 84, height: 84)
        }
        .shadow(color: Color(red: 0.95, green: 0.9, blue: 0.7).opacity(0.85 * lit), radius: 28)
        .position(x: size.width - 78, y: ScreenInsets.top + 70)
        .opacity(lit)
        .allowsHitTesting(false)
    }

    private func moreButton(_ session: RingSession, geo: RadialResult, elapsed: TimeInterval, closing: Double, size: CGSize) -> some View {
        let pose = buttonPose(session, index: 0, elapsed: elapsed, closing: closing)
        let has = !session.groups.isEmpty
        return Button {
            guard !ring.skinEdit else { return }
            Haptics.tick()
            ring.openSheet()
        } label: {
            ZStack {
                if has {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(session.overMedia ? .white : Color.primary)
                } else {
                    Circle().fill(Color.white.opacity(0.85)).frame(width: 6, height: 6)
                }
            }
            .frame(width: 36, height: 36)
            .moonDisc(overMedia: session.overMedia)
            .overlay(Circle().stroke(Color.white.opacity(session.overMedia ? 0.45 : 0.28), lineWidth: 0.7))
            .scaleEffect(max(0.2, CGFloat(pose.scale)))
            .opacity(Double(pose.alpha))
        }
        .position(x: geo.centerX, y: geo.centerY)
        .disabled(!has)
        .accessibilityIdentifier("ring.more")
        .accessibilityLabel("更多")
    }

    private func near(_ global: CGPoint, session: RingSession, center: CGPoint) -> Bool {
        hypot(global.x - center.x, global.y - center.y) < 46
    }
}

/// Glass droplet used only while 水滴选择 is on. It does not take taps.
struct FingerLens: View {
    var body: some View {
        let side: CGFloat = 72
        ZStack {
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(Color.clear)
                    .frame(width: side, height: side)
                    .glassEffect(.regular, in: Circle())
            } else {
                Circle().fill(.ultraThinMaterial).frame(width: side, height: side)
                Circle().stroke(Color.white.opacity(0.5), lineWidth: 1).frame(width: side, height: side)
            }
            Circle()
                .fill(LinearGradient(colors: [Color.white.opacity(0.82), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .center))
                .frame(width: side * 0.32, height: side * 0.32)
                .offset(x: -side * 0.16, y: -side * 0.18)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
        .accessibilityIdentifier("ring.drop")
        .allowsHitTesting(false)
    }
}

/// Shown on the open ring while choosing which buttons receive a photo or video.
private struct SkinEditBar: View {
    @ObservedObject var ring: RingController
    @EnvironmentObject private var app: AppModel
    @State private var item: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .frame(width: 4, height: 4)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("skins.edit")
                .accessibilityLabel("按键背景")
                .allowsHitTesting(false)
            Text(ring.skinPicked.isEmpty ? "点圆环上的按键，再选图片或视频" : "已选 \(ring.skinPicked.count) 个按键")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                Text("选图片或视频")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .moonGlass(MoonColors.media, radius: 14)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("skins.edit.pick")
            HStack(spacing: 8) {
                editAction("用在全部", "skins.edit.all") { applyAll() }
                editAction("清除", "skins.edit.clear") { clearSelected() }
                editAction("完成", "skins.edit.done") { ring.endSkinEdit() }
            }
        }
        .padding(14)
        .moonGlass(MoonColors.media, radius: 22)
        .moonOnChange(of: item) { picked in
            guard let picked else { return }
            Task { await importAndApply(picked) }
        }
    }

    private func editAction(_ title: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .moonGlass(MoonColors.media, radius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func importAndApply(_ picked: PhotosPickerItem) async {
        let saved = await PickedMedia.load(picked, folder: MediaStore.skins).map { ButtonSkin(path: $0.name, video: $0.video) }
        await MainActor.run {
            item = nil
            guard let saved else {
                app.showToast("没能保存这个背景")
                return
            }
            ring.pendingSkin = saved
            let ids = ButtonSkinID.allCases.filter { ring.skinPicked.contains($0.rawValue) }
            guard !ids.isEmpty else {
                app.showToast(saved.video ? "已选一段视频，再点要套上的按键" : "已选一张图片，再点要套上的按键")
                return
            }
            var skins = app.settings.buttonSkins
            ButtonSkins.assign(ids, skin: saved, into: &skins)
            app.settings.buttonSkins = skins
            app.saveSettings()
            app.showToast("已套到 \(ids.count) 个按键")
        }
    }

    private func applyAll() {
        guard let skin = ring.pendingSkin ?? app.settings.buttonSkins.values.first else {
            app.showToast("先选一张图片或一段视频")
            return
        }
        var skins = app.settings.buttonSkins
        ButtonSkins.assignAll(skin, into: &skins)
        app.settings.buttonSkins = skins
        app.saveSettings()
        app.showToast("已套到全部 29 个按键")
    }

    private func clearSelected() {
        var ids = ButtonSkinID.allCases.filter { ring.skinPicked.contains($0.rawValue) }
        if ids.isEmpty, let session = ring.session {
            ids = session.items.compactMap { ButtonSkins.identify(key: $0.key, title: $0.title) }
        }
        var skins = app.settings.buttonSkins
        ButtonSkins.clear(ids, skins: &skins)
        app.settings.buttonSkins = skins
        app.saveSettings()
        ring.skinPicked = []
        app.showToast(ids.isEmpty ? "没有可清除的按键" : "已清除")
    }
}

struct MoreSheet: View {
    var groups: [MenuGroup]
    var forceDark: Bool
    var onClose: () -> Void
    @Environment(\.moon) private var theme
    private var colors: MoonColors { forceDark ? .media : theme }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(group.danger ? colors.danger : colors.textDim)
                                .padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                ForEach(group.items) { item in
                                    Button {
                                        guard item.enabled else { return }
                                        item.action()
                                        onClose()
                                    } label: {
                                        HStack(spacing: 12) {
                                            GlassIcon(symbol: item.systemImage, tint: (item.destructive || group.danger) ? colors.danger : GlassTint.blue)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title).font(.system(size: 16, weight: .medium))
                                                if !item.enabled {
                                                    Text("现在不能用").font(.system(size: 11))
                                                }
                                            }
                                            Spacer()
                                        }
                                        .foregroundColor(item.enabled ? ((item.destructive || group.danger) ? colors.danger : colors.text) : colors.textDim)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                    }
                                    .disabled(!item.enabled)
                                    .accessibilityLabel(item.title)
                                    .accessibilityIdentifier(item.key.map { "more.\($0)" } ?? "more.\(item.title)")
                                    if item.id != group.items.last?.id {
                                        Divider().opacity(0.3).padding(.leading, 50)
                                    }
                                }
                            }
                            .moonGlass(group.danger ? colors : colors, radius: 16)
                        }
                    }
                }
                .padding(16)
            }
            .background { SystemGlassFill(dark: colors.dark) }
            .navigationTitle("更多")
            .accessibilityIdentifier("more.sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
