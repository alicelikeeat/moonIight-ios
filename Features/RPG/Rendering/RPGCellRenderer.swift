import SpriteKit
import UIKit

/// Draws icon, number and text cells into SpriteKit textures. Each distinct
/// style is drawn once and shared by every cell that uses it, so a world
/// full of labels costs one texture per label, not one view per cell.
@MainActor enum RPGCellRenderer {
    private static var cache: [String: SKTexture] = [:]
    private static var order: [String] = []
    private static let capacity = 256
    /// Points per cell texture side; drawn at 2x for sharpness.
    static let side: CGFloat = 64

    /// Glyph cells are drawn here; everything else comes from a library file.
    static func isGlyph(_ binding: MediaBinding) -> Bool {
        switch binding.kind {
        case .number, .text: true
        case .icon: binding.mediaID.isEmpty
        case .image, .video, .gif: false
        }
    }

    static func texture(for binding: MediaBinding) -> SKTexture {
        let style = binding.style ?? RPGCellStyle()
        let key = "\(binding.kind.rawValue)|\(style.value)|\(style.colorHex)|\(style.backgroundHex ?? "-")|\(style.size)|\(style.design.rawValue)|\(style.alignment.rawValue)|\(style.bold)"
        if let texture = cache[key] { return texture }
        let texture = SKTexture(image: image(kind: binding.kind, style: style))
        texture.filteringMode = .linear
        cache[key] = texture; order.append(key)
        if order.count > capacity { cache[order.removeFirst()] = nil }
        return texture
    }

    /// Shown in place of a library file that is missing or unreadable.
    static var placeholder: SKTexture {
        texture(for: MediaBinding(id: "placeholder", mediaID: "", kind: .icon,
                                  style: RPGCellStyle(value: "photo.badge.exclamationmark", colorHex: "FFD60A", backgroundHex: "3A3A3C", size: 0.7)))
    }

    static func image(kind: RPGMediaKind, style: RPGCellStyle) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = false
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { _ in
            if let hex = style.backgroundHex {
                UIColor(rpgHex: hex).setFill()
                UIBezierPath(roundedRect: bounds, cornerRadius: side * 0.14).fill()
            }
            let color = UIColor(rpgHex: style.colorHex)
            let content = bounds.insetBy(dx: side * 0.08, dy: side * 0.08)
            if kind == .icon {
                let configuration = UIImage.SymbolConfiguration(pointSize: side * style.size, weight: style.bold ? .bold : .regular)
                let symbol = UIImage(systemName: style.value, withConfiguration: configuration)
                    ?? UIImage(systemName: "questionmark.square.dashed", withConfiguration: configuration)
                guard let glyph = symbol?.withTintColor(color, renderingMode: .alwaysOriginal) else { return }
                let fit = min(content.width / glyph.size.width, content.height / glyph.size.height, 1)
                let size = CGSize(width: glyph.size.width * fit, height: glyph.size.height * fit)
                glyph.draw(in: CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2, width: size.width, height: size.height))
            } else {
                drawText(style.value, style: style, color: color, in: content)
            }
        }
    }

    private static func drawText(_ text: String, style: RPGCellStyle, color: UIColor, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch style.alignment { case .leading: .left; case .center: .center; case .trailing: .right }
        paragraph.lineBreakMode = .byWordWrapping
        var pointSize = side * style.size * 0.8
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = CGRect.zero
        // Shrink until the text fits the cell rather than clipping it.
        while true {
            attributes = [.font: font(pointSize, style: style), .foregroundColor: color, .paragraphStyle: paragraph]
            measured = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            if measured.height <= rect.height || pointSize <= 6 { break }
            pointSize *= 0.9
        }
        let height = min(measured.height, rect.height)
        (text as NSString).draw(with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
    }

    private static func font(_ size: CGFloat, style: RPGCellStyle) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        let design: UIFontDescriptor.SystemDesign = switch style.design {
        case .rounded: .rounded; case .standard: .default; case .serif: .serif; case .monospaced: .monospaced
        }
        return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    /// Sizes a library texture inside the cell box. `nil` keeps the schema 6
    /// behaviour (stretch to the box); `.fill` crops to the box's shape;
    /// `.fit` shrinks the sprite so the whole picture shows.
    static func layout(binding: MediaBinding, base: SKTexture, box: CGSize) -> (rect: CGRect, size: CGSize) {
        var rect = CGRect(x: binding.cropX, y: binding.cropY, width: binding.cropWidth, height: binding.cropHeight)
        let pixels = base.size()
        guard let fit = binding.fit, pixels.width > 0, pixels.height > 0, box.width > 0, box.height > 0 else { return (rect, box) }
        let contentAspect = (pixels.width * rect.width) / (pixels.height * rect.height)
        let boxAspect = box.width / box.height
        switch fit {
        case .fill:
            if contentAspect > boxAspect {
                let width = rect.width * boxAspect / contentAspect
                rect.origin.x += (rect.width - width) / 2; rect.size.width = width
            } else {
                let height = rect.height * contentAspect / boxAspect
                rect.origin.y += (rect.height - height) / 2; rect.size.height = height
            }
            return (rect, box)
        case .fit:
            let size = contentAspect > boxAspect
                ? CGSize(width: box.width, height: box.width / contentAspect)
                : CGSize(width: box.height * contentAspect, height: box.height)
            return (rect, size)
        }
    }
}

extension UIColor {
    /// "RRGGBB"; invalid input falls back to white.
    convenience init(rpgHex hex: String) {
        let value = RPGCellStyle.validHex(hex) ? UInt32(hex, radix: 16) ?? 0xFFFFFF : 0xFFFFFF
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
