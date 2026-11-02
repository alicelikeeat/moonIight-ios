import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Transparent gaps pass touches through to the feed. Each visible circle owns
// one native button, above media surfaces, with a minimum 48 pt touch target.
struct PriorityTabSurface: UIViewRepresentable {
    var onSelect: (AppTab) -> Void
    func makeUIView(context: Context) -> PriorityTabView { PriorityTabView() }
    func updateUIView(_ view: PriorityTabView, context: Context) { view.onSelect = onSelect }
}

// Slider mode shows the actual UIKit segmented control. The recognizer below
// adds cross-segment dragging while UIKit keeps its native tint and layout.
struct SlidingTabSurface: View {
    let selected: AppTab
    var onSelect: (AppTab) -> Void
    var body: some View {
        NativeSlidingTabSurface(selected: selected, onSelect: onSelect)
    }
}

// Slider mode deliberately uses UITabBar instead of drawing a second glass
// control. That gives the reference iOS spacing, accessibility, safe-area
// behavior and larger native hit regions while a horizontal pan remains a
// convenient way to switch tabs.
struct NativeSlidingTabSurface: UIViewRepresentable {
    let selected: AppTab
    var onSelect: (AppTab) -> Void
    func makeUIView(context: Context) -> NativeSlidingTabBar { NativeSlidingTabBar() }
    func updateUIView(_ view: NativeSlidingTabBar, context: Context) {
        view.onSelect = onSelect
        view.setSelected(selected)
    }
}

final class NativeSlidingTabBar: UITabBar, UITabBarDelegate, UIGestureRecognizerDelegate {
    var onSelect: ((AppTab) -> Void)?
    private let slidePan = UIPanGestureRecognizer()
    private var isApplyingSelection = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "navigation-slider"
        accessibilityLabel = "原生底部导航"
        delegate = self
        items = AppTab.allCases.enumerated().map { UITabBarItem(title: $0.element.title, image: UIImage(systemName: $0.element.symbol), tag: $0.offset) }
        itemPositioning = .fill
        itemWidth = 0
        itemSpacing = 0
        isTranslucent = true
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        appearance.backgroundColor = .clear
        let selectedColor = UIColor(MoonStyle.accent)
        appearance.stackedLayoutAppearance.selected.iconColor = selectedColor
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]
        appearance.stackedLayoutAppearance.normal.iconColor = .secondaryLabel
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.secondaryLabel]
        standardAppearance = appearance
        scrollEdgeAppearance = appearance
        slidePan.addTarget(self, action: #selector(slid(_:)))
        slidePan.delegate = self
        addGestureRecognizer(slidePan)
        setSelected(.home)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ tab: AppTab) {
        guard !isApplyingSelection else { return }
        selectedItem = items?.first(where: { $0.tag == (AppTab.allCases.firstIndex(of: tab) ?? 0) })
    }

    func tab(at point: CGPoint) -> AppTab {
        let width = max(1, bounds.width / CGFloat(AppTab.allCases.count))
        let index = min(AppTab.allCases.count - 1, max(0, Int(point.x / width)))
        return AppTab.allCases[index]
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard !isApplyingSelection, let tab = AppTab.allCases[safe: item.tag] else { return }
        activate(tab)
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === slidePan else { return true }
        let velocity = slidePan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func slid(_ recognizer: UIPanGestureRecognizer) {
        let tab = tab(at: recognizer.location(in: self))
        if recognizer.state == .began || recognizer.state == .changed {
            if selectedItem?.tag != (AppTab.allCases.firstIndex(of: tab) ?? 0) {
                UISelectionFeedbackGenerator().selectionChanged()
                setSelected(tab)
                activate(tab)
            }
        }
    }

    private func activate(_ tab: AppTab) {
        NotificationCenter.default.post(name: .init("moonlight.navigationTapped"), object: nil)
        onSelect?(tab)
    }
}

final class PriorityTabView: UIView {
    var onSelect: ((AppTab) -> Void)?
    private var buttons: [UIButton] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for (index, tab) in AppTab.allCases.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.accessibilityLabel = tab.title
            button.accessibilityIdentifier = "navigation-\(tab.rawValue)"
            button.addTarget(self, action: #selector(selected(_:)), for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width, 540)
        let diameter = min(50, max(44, (bounds.width - 80) / 6))
        let step = (width - diameter) / 4
        for (index, button) in buttons.enumerated() {
            let center = CGPoint(x: (bounds.width - width) / 2 + diameter / 2 + CGFloat(index) * step, y: bounds.midY)
            let hitSize = max(48, diameter)
            button.frame = CGRect(x: center.x - hitSize / 2, y: center.y - hitSize / 2, width: hitSize, height: hitSize)
        }
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
    @objc private func selected(_ sender: UIButton) {
        guard AppTab.allCases.indices.contains(sender.tag) else { return }
        onSelect?(AppTab.allCases[sender.tag])
    }
}
