import SwiftUI

/// Marks the selected cell on top of the SpriteKit world. One instance is
/// reused and moved; it never takes touches, so movement, building and
/// world taps still reach the scene underneath. The block's own texture is
/// untouched.
struct RPGSelectionGlass: View {
    let rect: CGRect
    /// The cell's curve (schema 9); nil for a square cell.
    var outline: ShapeOutline? = nil

    static var usesNativeGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    var body: some View {
        let shape = CellOutlineShape(outline: outline)
        let size = CGSize(width: rect.width + 10, height: rect.height + 10)
        // A ring, not a filled lens: a filled glass square rendered as a
        // white block over the SpriteKit map and hid the cell's content.
        ZStack {
            shape.strokeBorder(Color.black.opacity(0.35), lineWidth: 4)
            shape.strokeBorder(Color.white, lineWidth: 2.5)
            shape.inset(by: 2.5).strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: Color.accentColor.opacity(0.6), radius: 4)
        // Accessibility first so its frame is the glass, not the overlay.
        .accessibilityElement()
        .accessibilityLabel(L10n.t("选中格", "Selected Cell"))
        .accessibilityIdentifier("rpg-selection-glass")
        .accessibilityValue(Self.usesNativeGlass ? "native" : "fallback")
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}
