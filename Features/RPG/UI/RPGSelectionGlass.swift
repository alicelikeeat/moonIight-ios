import SwiftUI

/// Marks the selected cell on top of the SpriteKit world. One instance is
/// reused and moved; it never takes touches, so movement, building and
/// world taps still reach the scene underneath. The block's own texture is
/// untouched.
struct RPGSelectionGlass: View {
    let rect: CGRect

    static var usesNativeGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(4, rect.width * 0.22), style: .continuous)
        let size = CGSize(width: rect.width + 10, height: rect.height + 10)
        Group {
            if #available(iOS 26.0, *) {
                // Clear glass keeps the cell's picture, GIF or video visible
                // through the lens.
                Color.clear.frame(width: size.width, height: size.height)
                    .glassEffect(.clear, in: shape)
            } else {
                shape.fill(.ultraThinMaterial).opacity(0.35)
                    .overlay(shape.strokeBorder(Color.yellow, lineWidth: 2))
                    .frame(width: size.width, height: size.height)
            }
        }
        // Accessibility first so its frame is the glass, not the overlay.
        .accessibilityElement()
        .accessibilityLabel("选中格")
        .accessibilityIdentifier("rpg-selection-glass")
        .accessibilityValue(Self.usesNativeGlass ? "native" : "fallback")
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}
