import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Feed cards register only their geometry. These markers never participate in
// hit testing, so UIScrollView receives a drag without an intervening UIView.
@MainActor final class MediaCardHitRegistry {
    static var markers = NSHashTable<MediaCardHitMarker>.weakObjects()

    static func contains(_ point: CGPoint, in window: UIWindow) -> Bool {
        // A card rectangle can extend underneath the floating tab bar. Only a
        // touch whose frontmost view actually belongs to that card should
        // keep the global hold out of the scroll view's arbitration.
        let hit = window.hitTest(point, with: nil)
        return markers.allObjects.contains { marker in
            guard marker.window === window, marker.active, !marker.isHidden else { return false }
            let frame = marker.convert(marker.bounds, to: window)
            guard frame.width > 1, frame.height > 1, frame.contains(point) else { return false }
            guard let hit else { return true }
            return hitIsOnCard(hit, marker: marker)
        }
    }

    private static func hitIsOnCard(_ hit: UIView, marker: UIView) -> Bool {
        if hit === marker || hit.isDescendant(of: marker) || marker.isDescendant(of: hit) { return true }
        var host: UIView? = marker.superview
        while let view = host, !(view is UIWindow) {
            if hit === view || hit.isDescendant(of: view) {
                guard let window = view.window else { return false }
                let hostArea = view.convert(view.bounds, to: window).width * view.convert(view.bounds, to: window).height
                let markerFrame = marker.convert(marker.bounds, to: window)
                let markerArea = max(1, markerFrame.width * markerFrame.height)
                return hostArea <= markerArea * 2.2
            }
            host = view.superview
        }
        return false
    }

    static func center(for id: String) -> CGPoint? {
        // 推荐 and 发现 stay mounted together and can show the same entry; only
        // the feed on screen counts.
        guard let marker = markers.allObjects.first(where: { $0.entryID == id && $0.active }), let window = marker.window else { return nil }
        let frame = marker.convert(marker.bounds, to: window)
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}

final class MediaCardHitMarker: UIView {
    var entryID = ""
    /// False while the card's feed is mounted but hidden (opacity 0).
    var active = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        MediaCardHitRegistry.markers.add(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct MediaCardHitAnchor: UIViewRepresentable {
    let entryID: String
    var active = true
    func makeUIView(context: Context) -> MediaCardHitMarker { MediaCardHitMarker() }
    func updateUIView(_ view: MediaCardHitMarker, context: Context) { view.entryID = entryID; view.active = active }
}

/// Whether the feed a card sits in is the one on screen. 首页 keeps 推荐 and
/// 发现 mounted together (opacity 0 for the hidden one, to keep its scroll
/// position), so a hidden card must leave the accessibility tree and the hit
/// registry itself: a container's accessibilityHidden does not reach it.
private struct MoonlightFeedActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var moonlightFeedActive: Bool {
        get { self[MoonlightFeedActiveKey.self] }
        set { self[MoonlightFeedActiveKey.self] = newValue }
    }
}

struct NativeMediaCardInteractions: ViewModifier {
    let holdEnabled: Bool
    let onTap: () -> Void
    let onHold: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if holdEnabled {
            content
                .gesture(
                    LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
                        .exclusively(before: TapGesture())
                        .onEnded { result in
                            switch result {
                            case .first:
                                onHold()
                            case .second:
                                onTap()
                            }
                        }
                )
        } else {
            content.onTapGesture(perform: onTap)
        }
    }
}

// Used only by full-screen experiences such as Reels. Feed cards deliberately
// avoid this UIView surface so their enclosing UIScrollView receives pans
// directly, including a follow-up touch during deceleration.
struct CardGestureSurface: UIViewRepresentable {
    var holdEnabled = true
    var onTap: () -> Void
    var onHoldBegan: (CGPoint) -> Void
    var onHoldMoved: (CGPoint) -> Void
    var onHoldEnded: () -> Void
    var onDoubleTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> CardGestureView {
        let view = CardGestureView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: CardGestureView, context: Context) {
        view.holdEnabled = holdEnabled
        view.onTap = onTap
        view.onHoldBegan = onHoldBegan
        view.onHoldMoved = onHoldMoved
        view.onHoldEnded = onHoldEnded
        view.onDoubleTap = onDoubleTap
    }

    static func dismantleUIView(_ view: CardGestureView, coordinator: ()) {
        view.cancelHold()
    }
}

final class CardGestureView: UIView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    var onHoldBegan: ((CGPoint) -> Void)?
    var onHoldMoved: ((CGPoint) -> Void)?
    var onHoldEnded: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    private let hold = UILongPressGestureRecognizer()
    private var holdActive = false
    private var suppressTapFromHold = false
    private var delayedTapWorkItem: DispatchWorkItem?
    private var touchOrigin: CGPoint?
    private var touchMoved = false
    var holdEnabled = true {
        didSet {
            if holdEnabled {
                if hold.view == nil { addGestureRecognizer(hold) }
                hold.isEnabled = true
            } else {
                finishHold()
                hold.isEnabled = false
                if hold.view != nil { removeGestureRecognizer(hold) }
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        isUserInteractionEnabled = true

        // Do not install a tap recognizer over the whole card. A recognizer on
        // every row remains in UIKit's arbitration graph while a second flick
        // starts and can turn that flick into a mere deceleration stop. Plain
        // UIView touch delivery is cancelled natively as soon as UIScrollView's
        // pan wins, while a stationary touch still opens the card on release.
        hold.delegate = self
        hold.minimumPressDuration = 0.50
        hold.allowableMovement = 10
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.addTarget(self, action: #selector(held(_:)))

        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var enclosingScrollViews: [UIScrollView] {
        var result: [UIScrollView] = []
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { result.append(scroll) }
            ancestor = view.superview
        }
        return result
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if enclosingScrollViews.contains(where: { $0.isDragging || $0.isDecelerating }) {
            delayedTapWorkItem?.cancel()
            delayedTapWorkItem = nil
            return false
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !enclosingScrollViews.contains(where: { $0.isDragging || $0.isDecelerating }) else { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A card must not prevent the feed from starting another scroll.
        // Movement beyond allowableMovement cancels an unrecognized hold.
        enclosingScrollViews.contains {
            $0.panGestureRecognizer === otherGestureRecognizer
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        touchOrigin = touch.location(in: self)
        touchMoved = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first, let origin = touchOrigin else { return }
        let point = touch.location(in: self)
        if hypot(point.x - origin.x, point.y - origin.y) > 7 {
            touchMoved = true
            delayedTapWorkItem?.cancel()
            delayedTapWorkItem = nil
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        defer { resetTouchTracking() }
        guard !touchMoved, !holdActive,
              !enclosingScrollViews.contains(where: { $0.isDragging || $0.isDecelerating }) else { return }
        if suppressTapFromHold {
            suppressTapFromHold = false
            return
        }
        triggerTap()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        delayedTapWorkItem?.cancel()
        delayedTapWorkItem = nil
        resetTouchTracking()
    }

    private func resetTouchTracking() {
        touchOrigin = nil
        touchMoved = false
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            holdActive = true
            suppressTapFromHold = true
            LongPressHapticFeedback.shared.menuOpened()
            onHoldBegan?(point)
        case .changed:
            if holdActive { onHoldMoved?(point) }
        case .ended:
            if holdActive { onHoldMoved?(point); finishHold() }
        case .cancelled, .failed:
            finishHold()
        default:
            break
        }
    }

    private func triggerTap() {
        guard onDoubleTap != nil else { onTap?(); return }
        if delayedTapWorkItem != nil {
            delayedTapWorkItem?.cancel()
            delayedTapWorkItem = nil
            onDoubleTap?()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.onTap?()
            self?.delayedTapWorkItem = nil
        }
        delayedTapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
    }

    private func finishHold() {
        guard holdActive else { return }
        holdActive = false
        onHoldEnded?()
        DispatchQueue.main.async { [weak self] in self?.suppressTapFromHold = false }
    }

    func cancelHold() {
        delayedTapWorkItem?.cancel()
        delayedTapWorkItem = nil
        hold.isEnabled = false
        hold.isEnabled = true
        finishHold()
        resetTouchTracking()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelHold(); return }
        for scroll in enclosingScrollViews {
            // Keep the native delay so the scroll view decides whether this is
            // a pan before delivering a stationary tap to card content.
            scroll.delaysContentTouches = true
            scroll.canCancelContentTouches = true
        }
    }
}
