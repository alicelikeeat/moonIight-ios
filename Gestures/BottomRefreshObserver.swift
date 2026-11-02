import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Watch the existing native pan at the end of the feed. Adding a target to its
// recognizer does not compete with card taps, holds, or scroll deceleration.
struct BottomRefreshObserver: UIViewRepresentable {
    let onRefresh: () async -> Void
    let onNearBottom: (Bool) -> Void
    func makeUIView(context: Context) -> BottomRefreshMarker { BottomRefreshMarker() }
    func updateUIView(_ view: BottomRefreshMarker, context: Context) {
        view.onRefresh = onRefresh
        view.onNearBottom = onNearBottom
        view.installIfNeeded()
    }
    static func dismantleUIView(_ view: BottomRefreshMarker, coordinator: ()) { view.detach() }
}

final class BottomRefreshMarker: UIView {
    var onRefresh: (() async -> Void)?
    var onNearBottom: ((Bool) -> Void)?
    private weak var scrollView: UIScrollView?
    private var armed = false
    private var nearBottom = false
    private var refreshing = false
    private var observations: [NSKeyValueObservation] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); installIfNeeded() }
    func installIfNeeded() {
        guard window != nil else { detach(); return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                guard scrollView !== scroll else { return }
                detach()
                scrollView = scroll
                scroll.alwaysBounceVertical = true
                scroll.canCancelContentTouches = true
                scroll.clipsToBounds = false
                scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
                observations = [
                    scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.updateBottomVisibility() }
                    },
                    scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.updateBottomVisibility() }
                    },
                    scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in self?.updateBottomVisibility() }
                    }
                ]
                return
            }
            ancestor = view.superview
        }
    }
    func detach() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        scrollView = nil
        armed = false
        nearBottom = false
    }
    private func updateBottomVisibility() {
        guard let scroll = scrollView, window != nil else { return }
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let visible = bottom > 80 && scroll.contentOffset.y >= bottom - 56
        guard visible != nearBottom else { return }
        nearBottom = visible
        onNearBottom?(visible)
    }
    @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
        guard let scroll = scrollView, !refreshing else { return }
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let overscroll = scroll.contentOffset.y - bottom
        updateBottomVisibility()
        switch pan.state {
        case .changed:
            if overscroll > 65 { armed = true }
            else if overscroll < 20 { armed = false }
        case .ended:
            guard armed else { return }
            armed = false
            refreshing = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.onRefresh?()
                self.refreshing = false
            }
        case .cancelled, .failed:
            armed = false
        default: break
        }
    }
}
