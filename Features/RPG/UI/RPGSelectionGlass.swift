import SwiftUI

/// Marks the selected cell on top of the SpriteKit world. One instance is
/// reused and moved; it never takes touches, so movement, building and
/// world taps still reach the scene underneath. The block's own texture is
/// untouched.
///
/// v1.78: on iOS 26 the mark is a thin ring of real system Liquid Glass
/// (the middle is open, so the cell's content stays sharp); the outline
/// strokes stay on top for contrast. Reduce Transparency and older systems
/// draw the strokes only and report "fallback".
struct RPGSelectionGlass: View {
    let rect: CGRect
    /// The cell's curve (schema 9); nil for a square cell.
    var outline: ShapeOutline? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Width of the glass band around the cell.
    static let band: CGFloat = 6

    static var nativeGlassAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    /// Whether this instance actually draws native glass.
    var usesNativeGlass: Bool { Self.nativeGlassAvailable && !reduceTransparency }

    var body: some View {
        let shape = CellOutlineShape(outline: outline)
        let size = CGSize(width: rect.width + 10, height: rect.height + 10)
        ZStack {
            if usesNativeGlass, #available(iOS 26.0, *) {
                // A ring, not a filled lens: a filled glass square rendered
                // as a white block over the map and hid the cell's content.
                Color.clear.glassEffect(.clear, in: SelectionRingShape(outline: outline, band: Self.band))
            }
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
        .accessibilityValue(usesNativeGlass ? "native" : "fallback")
        .position(x: rect.midX, y: rect.midY)
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}

/// The cell outline minus the same outline `band` points further in.
struct SelectionRingShape: Shape {
    var outline: ShapeOutline?
    var band: CGFloat
    func path(in rect: CGRect) -> Path {
        let outer = CellOutlineShape(outline: outline).path(in: rect)
        let inner = CellOutlineShape(outline: outline, inset: band).path(in: rect)
        if #available(iOS 17.0, *) { return outer.subtracting(inner) }
        var ring = outer
        ring.addPath(inner)
        return ring
    }
}
