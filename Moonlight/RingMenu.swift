import SwiftUI
import UIKit

struct RingItem: Identifiable {
    let id = UUID()
    var title: String
    var systemImage: String
    var children: [RingItem] = []
    var enabled: Bool = true
    var action: () -> Void = {}
}

struct MenuGroup: Identifiable {
    let id = UUID()
    var title: String
    var danger: Bool = false
    var items: [RingItem]
}

struct RingSession: Identifiable {
    let id = UUID()
    var origin: CGPoint
    var items: [RingItem]
    var groups: [MenuGroup]
    var style: RingAnim
    var backdrop: MenuBackdrop
    var select: MenuSelect
    var overMedia: Bool
    var starSpeed: Float
    var started = Date()
}

@MainActor
final class RingController: ObservableObject {
    @Published var session: RingSession?
    @Published var fingerDown = false
    @Published var finger = CGPoint.zero
    @Published var expanded: UUID?
    @Published var sheet: [MenuGroup]?
    @Published var sheetDark = false
    @Published var closing = false
    @Published var settled = false
    @Published var closeStarted: Date?
    private var closeTask: Task<Void, Never>?
    private var landed: Set<Int> = []

    func present(origin: CGPoint, items: [RingItem], groups: [MenuGroup], settings: AppSettings, overMedia: Bool = false, styleOverride: RingAnim? = nil) {
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
        session = RingSession(
            origin: origin,
            items: Array(items.prefix(4)),
            groups: groups,
            style: style,
            backdrop: settings.menuBackdrop,
            select: settings.menuSelect,
            overMedia: overMedia,
            starSpeed: RingMotion.clampSpeed(settings.starSpeed)
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
            self?.session = nil
            self?.closing = false
            self?.expanded = nil
            self?.settled = false
            self?.closeStarted = nil
            then?()
        }
    }

    /// Drag-mode release. Recomputes the same full-screen layout the overlay uses.
    func selectDrag(at global: CGPoint) {
        guard let session, session.select == .drag else { return }
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

    func openSheet() {
        let groups = session?.groups ?? []
        sheetDark = session?.overMedia ?? false
        beginClose()
        if !groups.isEmpty { sheet = groups }
    }
}

struct RingOverlay: View {
    @ObservedObject var ring: RingController
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            ZStack {
                ZStack { backdrop }
                    .contentShape(Rectangle())
                    .onTapGesture { ring.dismiss() }
                if let session = ring.session {
                    ringBody(session, localOrigin: CGPoint(x: session.origin.x - frame.minX, y: session.origin.y - frame.minY), size: geo.size)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!(ring.fingerDown && ring.session?.select == .drag))
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
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: ring.settled && !ring.closing)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(session.started)
            let closingT = ring.closing ? min(1, max(0, elapsed > 0 ? closeProgress(session) : 0)) : 0
            ZStack {
                if session.style == .moon {
                    moon(size: size, lit: ring.closing ? 0.3 : 1)
                }
                Canvas { context, _ in
                    guard session.style == .star else { return }
                    for i in session.items.indices {
                        let pose = buttonPose(session, index: i, elapsed: elapsed, closing: closingT)
                        drawTrail(context: context, geo: geo, index: i, pose: pose, size: size, session: session, elapsed: elapsed)
                    }
                }
                .allowsHitTesting(false)
                ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                    let pose = buttonPose(session, index: index, elapsed: elapsed, closing: closingT)
                    let center = buttonCenter(geo: geo, index: index, pose: pose, size: size)
                    ringButton(item, pose: pose, center: center, session: session, parentAngle: geo.angles[index], radius: geo.radius)
                        .onAppear { }
                        .moonOnChange(of: pose.fx2) { value in
                            if value > 0.2 { ring.noteLanded(index) }
                        }
                }
                moreButton(session, geo: geo, elapsed: elapsed, closing: closingT, size: size)
            }
            .moonOnChange(of: timeline.date) { _ in
                if !ring.closing && elapsed >= deadline { ring.settled = true }
            }
            .moonOnChange(of: ring.finger) { point in
                guard ring.fingerDown, session.select == .drag else { return }
                let local = CGPoint(x: point.x - (session.origin.x - localOrigin.x), y: point.y - (session.origin.y - localOrigin.y))
                _ = local
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
        let spinFlight = 0.62
        switch session.style {
        case .star:
            let speed = Double(RingMotion.clampSpeed(session.starSpeed))
            let local = elapsed - (stagger / speed) * Double(index)
            let o = Float(min(1, max(0, local / (flight / speed))))
            let cl = Float(ring.closing ? closeClock() : 1)
            return RingMotion.pose(.star, ring.closing ? 1 : o, cl, ring.closing, depth: RingMotion.starDepth(index))
        case .spin:
            let raw = (elapsed - 0.02 * Double(index)) / spinFlight
            let o = Float(min(1.15, max(0, raw)))
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

    private func ringButton(_ item: RingItem, pose: RingMotion.Pose, center: CGPoint, session: RingSession, parentAngle: Double, radius: Double) -> some View {
        let highlighted = ring.fingerDown && session.select == .drag && near(ring.finger, session: session, center: center)
        let ink: Color = session.overMedia ? .white : Color.primary
        let plate = session.overMedia ? MoonColors.media.glassTint : Color.primary.opacity(0.08)
        return ZStack {
            if session.style == .lotus {
                lotus(pose: pose)
            }
            VStack(spacing: 6) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(ink)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Circle().fill(highlighted ? Color.white.opacity(0.28) : plate))
                    .overlay(Circle().stroke(session.overMedia ? Color.white.opacity(0.55) : Color.primary.opacity(0.18), lineWidth: 0.8))
                    .overlay {
                        if pose.fx3 > 0.05 {
                            Circle()
                                .trim(from: 0.05, to: 0.28)
                                .stroke(Color.white.opacity(Double(pose.fx3)), lineWidth: 2)
                                .rotationEffect(.degrees(Double(pose.fx3) * 220))
                                .padding(2)
                        }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .rotationEffect(.degrees(Double(pose.rot)))
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(ink)
                    .shadow(color: .black.opacity(session.backdrop.labelShadow || !session.overMedia ? 0.35 : 0.8), radius: 3, y: 1)
                    .opacity(Double(pose.label))
            }
            .scaleEffect(max(0.05, CGFloat(pose.scale)))
            .opacity(Double(pose.alpha))
            .onTapGesture {
                guard item.enabled else { return }
                Haptics.tick()
                if item.children.isEmpty {
                    item.action()
                    ring.dismiss()
                } else if item.children.count > 6 {
                    ring.sheetDark = session.overMedia
                    ring.sheet = [MenuGroup(title: item.title, items: item.children)]
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
                    guard child.enabled else { return }
                    Haptics.confirm()
                    child.action()
                    ring.dismiss()
                } label: {
                    Text(child.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor((ring.session?.overMedia ?? false) ? .white : Color.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 0.6))
                }
                .offset(x: 92 * CGFloat(cos(rad)), y: 92 * CGFloat(sin(rad)))
                .opacity(child.enabled ? 1 : 0.4)
            }
        }
    }

    private func lotus(pose: RingMotion.Pose) -> some View {
        let inner = CGFloat(RingMotion.lotusInner(pose.fx))
        let outer = CGFloat(RingMotion.lotusOuter(pose.fx))
        return ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 16, height: 34)
                    .offset(y: -30 * outer)
                    .rotationEffect(.degrees(Double(i) / 8 * 360))
                    .scaleEffect(max(0.2, outer))
            }
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color(red: 0.95, green: 0.9, blue: 0.78).opacity(0.28))
                    .frame(width: 14, height: 26)
                    .offset(y: -22 * inner)
                    .rotationEffect(.degrees(Double(i) / 5 * 360 + 18))
                    .scaleEffect(max(0.2, inner))
            }
        }
        .allowsHitTesting(false)
    }

    private func moon(size: CGSize, lit: Double) -> some View {
        Circle()
            .fill(Color(red: 0.96, green: 0.94, blue: 0.86))
            .frame(width: 84, height: 84)
            .shadow(color: Color(red: 0.95, green: 0.9, blue: 0.7).opacity(0.8 * lit), radius: 30)
            .position(x: size.width - 78, y: ScreenInsets.top + 70)
            .opacity(lit)
            .allowsHitTesting(false)
    }

    private func moreButton(_ session: RingSession, geo: RadialResult, elapsed: TimeInterval, closing: Double, size: CGSize) -> some View {
        let pose = buttonPose(session, index: 0, elapsed: elapsed, closing: closing)
        let has = !session.groups.isEmpty
        return Button {
            Haptics.tick()
            ring.openSheet()
        } label: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Color.white.opacity(0.12))
                if has {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Circle().fill(Color.white.opacity(0.85)).frame(width: 6, height: 6)
                }
            }
            .frame(width: 36, height: 36)
            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 0.7))
            .scaleEffect(max(0.2, CGFloat(pose.scale)))
            .opacity(Double(pose.alpha))
        }
        .position(x: geo.centerX, y: geo.centerY)
        .disabled(!has)
    }

    private func near(_ global: CGPoint, session: RingSession, center: CGPoint) -> Bool {
        hypot(global.x - center.x, global.y - center.y) < 46
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
                                            Image(systemName: item.systemImage)
                                                .frame(width: 24)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.title).font(.system(size: 16, weight: .medium))
                                            }
                                            Spacer()
                                        }
                                        .foregroundColor(item.enabled ? (group.danger ? colors.danger : colors.text) : colors.textDim)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 12)
                                    }
                                    .disabled(!item.enabled)
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
            .background(MoonBackground(colors: colors))
            .navigationTitle("更多")
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
