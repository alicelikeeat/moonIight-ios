import SwiftUI
import UIKit
import WebKit

struct RemoteOrLocalImage: View {
    var url: URL?
    var art: String?
    var mode: ContentMode = .fill
    var body: some View {
        if let seed = artSeed(art) ?? artSeed(url?.absoluteString) {
            ArtPlate(seed: seed)
        } else if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: mode)
                case .failure:
                    Color.black.overlay(Image(systemName: "photo").foregroundColor(.white.opacity(0.7)))
                default:
                    Color.black.opacity(0.3)
                }
            }
        } else {
            Color.black
        }
    }
}

struct WebEmbedView: UIViewRepresentable {
    var url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url { uiView.load(URLRequest(url: url)) }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct MediaTouchLayer: UIViewRepresentable {
    var identifier: String = ""
    var onSingle: () -> Void
    var onDouble: () -> Void
    var onLongBegan: (CGPoint) -> Void
    var onLongChanged: (CGPoint) -> Void
    var onLongEnded: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.tag = HitTags.media
        view.accessibilityIdentifier = identifier
        view.isAccessibilityElement = !identifier.isEmpty
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.single(_:)))
        single.numberOfTapsRequired = 1
        single.cancelsTouchesInView = false
        single.delaysTouchesBegan = false
        single.delaysTouchesEnded = false
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.double(_:)))
        double.numberOfTapsRequired = 2
        double.cancelsTouchesInView = false
        double.delaysTouchesBegan = false
        double.delaysTouchesEnded = false
        let hold = FriendlyLongPress(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        LongPressInstall.configure(hold)
        hold.minimumPressDuration = 0.45
        view.addGestureRecognizer(single)
        view.addGestureRecognizer(double)
        view.addGestureRecognizer(hold)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        uiView.accessibilityIdentifier = identifier
        uiView.isAccessibilityElement = !identifier.isEmpty
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: MediaTouchLayer
        init(_ parent: MediaTouchLayer) { self.parent = parent }
        private var generation = 0
        private var blockSingle = false
        @objc func single(_ g: UITapGestureRecognizer) {
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                guard gen == self.generation, !self.blockSingle else { return }
                self.parent.onSingle()
            }
        }
        @objc func double(_ g: UITapGestureRecognizer) {
            generation += 1
            parent.onDouble()
        }
        @objc func hold(_ g: UILongPressGestureRecognizer) {
            let point = g.location(in: g.view?.window)
            switch g.state {
            case .began:
                blockSingle = true
                generation += 1
                PressGate.begin()
                setScrollEnabled(false, from: g.view)
                parent.onLongBegan(point)
            case .changed:
                parent.onLongChanged(point)
            default:
                setScrollEnabled(true, from: g.view)
                parent.onLongEnded(point)
                PressGate.end()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.blockSingle = false }
            }
        }
        private func setScrollEnabled(_ enabled: Bool, from view: UIView?) {
            var current = view?.superview
            while let view = current {
                if let scroll = view as? UIScrollView {
                    scroll.isScrollEnabled = enabled
                    return
                }
                current = view.superview
            }
        }
    }
}

struct VerticalPager: UIViewRepresentable {
    var count: Int
    @Binding var index: Int
    var page: (Int) -> AnyView

    func makeUIView(context: Context) -> PagerScroll {
        let scroll = PagerScroll()
        scroll.isPagingEnabled = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bounces = true
        scroll.alwaysBounceVertical = true
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator
        scroll.decelerationRate = .fast
        context.coordinator.scroll = scroll
        scroll.onLayout = { [weak coord = context.coordinator] in coord?.ensure() }
        return scroll
    }

    func updateUIView(_ uiView: PagerScroll, context: Context) {
        context.coordinator.parent = self
        context.coordinator.ensure()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: VerticalPager
        weak var scroll: PagerScroll?
        var hosts: [Int: UIHostingController<AnyView>] = [:]
        var busy = false
        init(_ parent: VerticalPager) { self.parent = parent }

        func ensure() {
            guard let scroll, !busy else { return }
            busy = true
            defer { busy = false }
            let h = scroll.bounds.height
            let w = scroll.bounds.width
            guard h > 2, w > 2 else { return }
            if parent.count == 0 {
                hosts.values.forEach { $0.view.removeFromSuperview() }
                hosts.removeAll()
                scroll.contentSize = .zero
                return
            }
            scroll.contentSize = CGSize(width: w, height: h * CGFloat(parent.count))
            let visible = Int(round(scroll.contentOffset.y / h))
            let needed = Set((visible - 1)...(visible + 1)).filter { $0 >= 0 && $0 < parent.count }
            for key in Array(hosts.keys) where !needed.contains(key) {
                hosts[key]?.view.removeFromSuperview()
                hosts[key] = nil
            }
            for i in needed.sorted() {
                let root = parent.page(i)
                let host: UIHostingController<AnyView>
                if let existing = hosts[i] {
                    existing.rootView = root
                    host = existing
                } else {
                    host = UIHostingController(rootView: root)
                    host.view.backgroundColor = .clear
                    if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                    scroll.addSubview(host.view)
                    hosts[i] = host
                }
                host.view.frame = CGRect(x: 0, y: CGFloat(i) * h, width: w, height: h)
            }
            if !scroll.isDragging && !scroll.isDecelerating {
                let y = CGFloat(max(0, min(parent.count - 1, parent.index))) * h
                if abs(scroll.contentOffset.y - y) > 1 {
                    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { ensure() }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { publish(scrollView) }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { publish(scrollView) }
        }
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { publish(scrollView) }

        private func publish(_ scrollView: UIScrollView) {
            let h = scrollView.bounds.height
            guard h > 2, parent.count > 0 else { return }
            let idx = max(0, min(parent.count - 1, Int(round(scrollView.contentOffset.y / h))))
            if parent.index != idx { parent.index = idx }
        }
    }
}

final class PagerScroll: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var video: Bool
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
            picker.mediaTypes = video ? ["public.movie"] : ["public.image"]
            picker.cameraCaptureMode = video ? .video : .photo
            if video { picker.videoQuality = .typeHigh }
        } else {
            DispatchQueue.main.async { onCancel() }
        }
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { parent.onVideo(url) }
            else if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            else { parent.onCancel() }
        }
    }
}

struct ToastBar: View {
    var text: String
    var undo: (() -> Void)?
    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.system(size: 14, weight: .medium))
            if let undo {
                Button("撤销", action: undo).font(.system(size: 14, weight: .semibold))
            }
        }
        .foregroundColor(MoonColors.dark.text)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .moonGlass(MoonColors.media, radius: 18)
        .padding(.bottom, 92)
    }
}
