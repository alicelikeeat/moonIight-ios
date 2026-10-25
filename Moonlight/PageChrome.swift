import SwiftUI
import UIKit

struct BackdropFill: View {
    var settings: AppSettings

    var body: some View {
        let video = settings.backdropMode == .video
        let stored = video ? settings.backdropVideo : settings.backdropPhoto
        let focus = video ? settings.backdropVideoFocus : settings.backdropPhotoFocus
        let blurOn = video ? settings.backdropVideoBlur : settings.backdropPhotoBlur
        let file = BackdropFiles.path(stored)
        GeometryReader { geo in
            ZStack {
                Color.black
                if settings.backdropMode != .black, let file {
                    Group {
                        if video {
                            LoopFilm(ref: file)
                        } else if let image = UIImage(contentsOfFile: file) {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .frame(width: geo.size.width * 1.35, height: geo.size.height * 1.35)
                    .scaleEffect(CGFloat(max(1, focus.scale)))
                    .offset(x: CGFloat(focus.x - 0.5) * geo.size.width, y: CGFloat(focus.y - 0.5) * geo.size.height)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: blurOn ? 28 : 0)
                    Color.black.opacity(blurOn ? 0.5 : 0.18)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct PageBackdrop: View {
    var page: BackdropPage
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if app.settings.showsBackdrop(page) {
                ScreenPinnedFill { BackdropFill(settings: app.settings) }
            }
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

/// Pins a fill to the physical screen, including the Dynamic Island and the home indicator.
/// The background layer is the only thing that ignores the safe area.
struct ScreenPinnedFill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global)
            let screen = UIScreen.main.bounds
            content()
                .frame(width: screen.width, height: screen.height)
                .position(x: screen.midX - global.minX, y: screen.midY - global.minY)
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

struct ScreenBackdrop: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if app.settings.showsBackdrop(app.visibleBackdrop) {
                ScreenPinnedFill { BackdropFill(settings: app.settings) }
            }
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

struct GlassIcon: View {
    var symbol: String
    var tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: Circle())
    }
}

enum GlassTint {
    static let green = Color(red: 0.33, green: 0.70, blue: 0.52)
    static let pink = Color(red: 0.91, green: 0.42, blue: 0.52)
    static let purple = Color(red: 0.56, green: 0.46, blue: 0.86)
    static let blue = Color(red: 0.34, green: 0.54, blue: 0.92)
    static let orange = Color(red: 0.93, green: 0.62, blue: 0.28)
    static let gray = Color(red: 0.45, green: 0.48, blue: 0.55)
    static let red = Color(red: 0.86, green: 0.28, blue: 0.28)
}

struct GlassGroup<Content: View>: View {
    var title: String
    var colors: MoonColors
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(colors.textDim)
                .padding(.leading, 14)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 4)
                .moonGlass(colors, radius: 22)
        }
    }
}

struct GlassLine: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    var colors: MoonColors
    var showChevron = true

    var body: some View {
        HStack(spacing: 12) {
            GlassIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundColor(colors.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundColor(colors.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showChevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(colors.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct BackdropPagesSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moon) private var colors

    private var ink: MoonColors { app.settings.showsBackdrop(.settings) ? .media : colors }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        quick("全选") { app.settings.backdropPages = BackdropPages.selectAll(); app.saveSettings() }
                        quick("仅首页") { app.settings.backdropPages = BackdropPages.selectHome(); app.saveSettings() }
                    }
                    VStack(spacing: 0) {
                        ForEach(BackdropPage.allCases) { page in
                            Button {
                                var pages = app.settings.backdropPages
                                if pages.contains(page.rawValue) { pages.removeAll { $0 == page.rawValue } }
                                else { pages.append(page.rawValue) }
                                app.settings.backdropPages = BackdropPages.normalize(pages)
                                app.saveSettings()
                            } label: {
                                HStack {
                                    Text(page.label).font(.system(size: 16, weight: .medium)).foregroundColor(ink.text)
                                    Spacer()
                                    Image(systemName: app.settings.backdropPages.contains(page.rawValue) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(app.settings.backdropPages.contains(page.rawValue) ? ink.accent : ink.textDim)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("backdrop.page.\(page.rawValue)")
                        }
                    }
                    .moonGlass(ink, radius: 22)
                    Text("没选中的页面用主题背景。")
                        .font(.system(size: 12))
                        .foregroundColor(ink.textDim)
                }
                .padding(16)
            }
            .background {
                if app.settings.showsBackdrop(.settings) { PageBackdrop(page: .settings) }
                else { SystemGlassFill(dark: colors.dark) }
            }
            .navigationTitle("应用到页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func quick(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(ink.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .moonGlass(ink, radius: 14)
    }
}

/// Forces a dark scheme when a page backdrop is showing, without reading
/// `colorScheme` in the same view that writes it. That cycle drops later updates.
struct BackdropScheme: ViewModifier {
    @EnvironmentObject private var app: AppModel
    var page: BackdropPage

    func body(content: Content) -> some View {
        if app.settings.showsBackdrop(page) {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}

enum CaptureSlots {
    static let items: [(title: String, symbol: String, id: String)] = [
        ("拍照", "camera.fill", "capture.photo"),
        ("录像", "video.fill", "capture.video"),
        ("导入", "photo.on.rectangle", "capture.import"),
        ("发朋友圈", "square.and.pencil", "capture.compose"),
    ]
}

enum CaptureFanLayout {
    static func geometry(origin: CGPoint, size: CGSize) -> RadialResult {
        let margin = 16.0
        return RadialGeometry.layout(
            originX: Double(origin.x), originY: Double(origin.y), n: CaptureSlots.items.count,
            left: margin,
            top: Double(ScreenInsets.top) + 72,
            right: Double(size.width) - margin,
            bottom: Double(size.height) - Double(ScreenInsets.bottom) - 28,
            radius: 128,
            itemR: 42
        )
    }

    static func hitIndex(finger: CGPoint, origin: CGPoint, size: CGSize) -> Int? {
        let geo = geometry(origin: origin, size: size)
        return RadialGeometry.hit(geo, x: Double(finger.x), y: Double(finger.y), hitR: 48)
    }
}

struct CaptureFanOverlay: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let fan = app.fan
            let origin = fan?.origin ?? CGPoint(x: size.width / 2, y: size.height - 80)
            let finger = fan?.finger ?? origin
            let geo = CaptureFanLayout.geometry(origin: origin, size: size)
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                let dim = fan.map { Self.dim(for: $0, at: timeline.date) } ?? 1
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).opacity(dim)
                    Color.black.opacity(0.22 * dim)
                        .contentShape(Rectangle())
                        .onTapGesture { app.closeFan(animated: true) }
                    // Not an ancestor of the bubbles: a parent identifier replaces theirs on iOS 26.
                    Color.clear
                        .frame(width: 4, height: 4)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("capture.fan")
                        .accessibilityLabel("拍摄")
                        .allowsHitTesting(false)
                    Text("拍摄")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .moonCapsule(overMedia: true)
                        .opacity(dim)
                        .accessibilityIdentifier("capture.pill")
                        .offset(y: ScreenInsets.top + 28 - size.height / 2)
                    ForEach(Array(CaptureSlots.items.enumerated()), id: \.offset) { index, item in
                        let spot = geo.pos(index)
                        let dest = CGPoint(x: spot.0, y: spot.1)
                        let pose = Self.pose(index: index, dest: dest, origin: origin, fan: fan, at: timeline.date)
                        let near = hypot(finger.x - pose.point.x, finger.y - pose.point.y) < 54 && (fan?.down == true)
                        fanBubble(item, near: near, pose: pose) { app.fireCapture(index) }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }

    private func fanBubble(_ item: (title: String, symbol: String, id: String), near: Bool, pose: FanPose, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 58, height: 58)
                    .moonDisc(overMedia: true)
                    .overlay(Circle().stroke(Color.white.opacity(near ? 0.95 : 0.45), lineWidth: near ? 1.8 : 0.8))
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
                    .scaleEffect(near ? 1.08 : 1)
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .moonCapsule(overMedia: true)
            }
            .scaleEffect(pose.scale)
            .opacity(pose.alpha)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityIdentifier(item.id)
        // Padding participates in layout, so the hit target matches the drawn bubble.
        // offset and position leave the control's hit target somewhere else.
        .padding(.leading, max(0, pose.point.x - 40))
        .padding(.top, max(0, pose.point.y - 46))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .zIndex(2)
    }

    private struct FanPose {
        var point: CGPoint
        var scale: CGFloat
        var alpha: Double
    }

    /// Bubbles leave the 拍摄 button along the arc. 减弱动态效果 only fades them in place.
    private static func pose(index: Int, dest: CGPoint, origin: CGPoint, fan: FanGesture?, at date: Date) -> FanPose {
        guard let fan else { return FanPose(point: dest, scale: 1, alpha: 1) }
        let elapsed = date.timeIntervalSince(fan.started)
        if UIAccessibility.isReduceMotionEnabled {
            let alpha = fan.closing ? max(0, 1 - elapsed / 0.16) : min(1, elapsed / 0.16)
            return FanPose(point: dest, scale: 1, alpha: alpha)
        }
        if fan.closing {
            let t = min(1, max(0, elapsed / 0.26))
            let p = CGFloat(t * t)
            return FanPose(
                point: CGPoint(x: dest.x + (origin.x - dest.x) * p, y: dest.y + (origin.y - dest.y) * p),
                scale: 1 - 0.65 * p,
                alpha: Double(1 - t)
            )
        }
        let delay = 0.045 * Double(index)
        let u = min(1, max(0, (elapsed - delay) / 0.36))
        let sprung = CGFloat(RingMotion.backOut(Float(u), 1.45))
        let travel = min(1, max(0, sprung))
        return FanPose(
            point: CGPoint(x: origin.x + (dest.x - origin.x) * travel, y: origin.y + (dest.y - origin.y) * travel),
            scale: max(0.2, 0.55 + 0.45 * min(1.12, sprung)),
            alpha: Double(min(1, u * 1.6))
        )
    }

    private static func dim(for fan: FanGesture, at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(fan.started)
        if UIAccessibility.isReduceMotionEnabled {
            return fan.closing ? max(0, 1 - elapsed / 0.16) : min(1, elapsed / 0.16)
        }
        if fan.closing { return max(0, 1 - elapsed / 0.26) }
        return min(1, elapsed / 0.2)
    }
}

/// Fills a ring on 拍摄 while the finger is down. It does not take the touch, so the tap and the long-press still fire.
struct CaptureHoldMeter: UIViewRepresentable {
    var onProgress: (CGFloat) -> Void

    func makeUIView(context: Context) -> MeterView {
        let view = MeterView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        view.onProgress = onProgress
        return view
    }

    func updateUIView(_ uiView: MeterView, context: Context) {
        uiView.onProgress = onProgress
    }

    final class MeterView: UIView, UIGestureRecognizerDelegate {
        var onProgress: ((CGFloat) -> Void)?
        private var recognizer: UILongPressGestureRecognizer?
        private var began: Date?
        private var link: CADisplayLink?

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
                recognizer = nil
                stop()
                return
            }
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        private func install() {
            guard recognizer == nil, let window else { return }
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(press(_:)))
            hold.minimumPressDuration = 0
            hold.allowableMovement = 64
            hold.cancelsTouchesInView = false
            hold.delaysTouchesBegan = false
            hold.delaysTouchesEnded = false
            hold.delegate = self
            window.addGestureRecognizer(hold)
            recognizer = hold
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window else { return false }
            let rect = convert(bounds, to: window)
            guard rect.width > 1, rect.height > 1 else { return false }
            return rect.contains(touch.location(in: window))
        }

        @objc private func press(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                began = Date()
                start()
                onProgress?(0)
            case .changed:
                report()
            case .ended, .cancelled, .failed:
                stop()
                began = nil
                onProgress?(0)
            default:
                break
            }
        }

        private func start() {
            link?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick() { report() }

        private func report() {
            guard let began else { return }
            onProgress?(min(1, CGFloat(Date().timeIntervalSince(began) / 0.45)))
        }

        private func stop() {
            link?.invalidate()
            link = nil
        }

        deinit {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            stop()
        }
    }
}
