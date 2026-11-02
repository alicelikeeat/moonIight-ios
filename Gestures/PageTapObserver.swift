import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// A recognizer on the existing host sees completed taps, but never owns a
// full-screen transparent view or delays/cancels scrolling and controls.
struct PageTapObserver: UIViewRepresentable {
    var onTap: () -> Void
    func makeUIView(context: Context) -> PageTapMarker { PageTapMarker() }
    func updateUIView(_ view: PageTapMarker, context: Context) {
        view.onTap = onTap
        view.install()
    }
    static func dismantleUIView(_ view: PageTapMarker, coordinator: ()) { view.detach() }
}

final class PageTapMarker: UIView, UIGestureRecognizerDelegate {
    var onTap: (() -> Void)?
    private let tap = UITapGestureRecognizer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        tap.addTarget(self, action: #selector(tapped))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); install() }
    func install() {
        guard window != nil else { detach(); return }
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                if tap.view !== controller.view { detach(); controller.view.addGestureRecognizer(tap) }
                return
            }
            responder = current.next
        }
    }
    func detach() { tap.view?.removeGestureRecognizer(tap) }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var ancestor = touch.view
        while let view = ancestor {
            if view is UITextField || view is UITextView || view is UIControl { return false }
            ancestor = view.superview
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func tapped() { onTap?() }
}
