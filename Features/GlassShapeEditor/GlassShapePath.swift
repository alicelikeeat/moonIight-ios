import SwiftUI
import CoreGraphics

extension ShapePoint {
    func cgPoint(in rect: CGRect) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
}

extension ShapeOutline {
    /// The outline in `rect`, y down (SwiftUI and UIKit). Built from the same
    /// segment list as the exported code.
    func cgPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let segments = cubics
        guard let first = segments.first else { return path }
        path.move(to: first.from.cgPoint(in: rect))
        for cubic in segments {
            path.addCurve(to: cubic.to.cgPoint(in: rect), control1: cubic.c1.cgPoint(in: rect), control2: cubic.c2.cgPoint(in: rect))
        }
        path.closeSubpath()
        return path
    }

    /// For SpriteKit (y up), centred on the node: a cell of `size` points.
    func spriteKitPath(size: CGSize) -> CGPath {
        // Flipping y turns the SwiftUI outline the right way up in the scene.
        var flip = CGAffineTransform(translationX: -size.width / 2, y: size.height / 2).scaledBy(x: 1, y: -1)
        return cgPath(in: CGRect(origin: .zero, size: size)).copy(using: &flip) ?? cgPath(in: CGRect(origin: .zero, size: size))
    }
}

/// Draws a `ShapeOutline` at any size. The editor preview, the cell panel
/// and the selection ring use this; exported code draws the same curve.
struct EditableShape: Shape {
    var outline: ShapeOutline
    func path(in rect: CGRect) -> Path { Path(outline.cgPath(in: rect)) }
}

/// The selected cell's shape, or a rounded square for square cells.
struct CellOutlineShape: InsettableShape {
    var outline: ShapeOutline?
    var cornerRatio: CGFloat = 0.22
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        if let outline { return EditableShape(outline: outline).path(in: box) }
        return RoundedRectangle(cornerRadius: max(4, box.width * cornerRatio), style: .continuous).path(in: box)
    }
    func inset(by amount: CGFloat) -> CellOutlineShape { var copy = self; copy.inset += amount; return copy }
}

/// A small thumbnail of an outline, for menus and pickers.
struct ShapeThumbnail: View {
    let outline: ShapeOutline?
    var size: CGFloat = 18
    var body: some View {
        CellOutlineShape(outline: outline, cornerRatio: 0.12)
            .stroke(Color.primary, lineWidth: 1.5)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The sandbox's single way in: shows the editor on iOS 26+, nothing before.
struct GlassShapeEditorEntry: View {
    static var available: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
    var onApply: ((ShapeOutline) -> Void)?
    var onClose: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassShapeEditorView(onApply: onApply, onClose: onClose)
        } else {
            VStack(spacing: 12) {
                Text(L10n.t("形状编辑器需要 iOS 26 或更高版本。", "The shape editor needs iOS 26 or later."))
                Button(L10n.t("关闭", "Close"), action: onClose)
            }.padding()
        }
    }
}
