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
    /// A media-grid piece: its row and column of the group's picture,
    /// filling the cell. Other cells use the binding's own layout.
    static func layout(binding: MediaBinding, region: RPGMediaRegion?, base: SKTexture, box: CGSize) -> (rect: CGRect, size: CGSize) {
        guard let region else { return layout(binding: binding, base: base, box: box) }
        let crop = CGRect(x: binding.cropX, y: binding.cropY, width: binding.cropWidth, height: binding.cropHeight)
        let group = RPGMediaRegion.groupRect(crop: crop, pixels: base.size(), rows: region.rows, columns: region.columns, stretch: region.stretch == true)
        return (region.subRect(of: group), box)
    }

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

/// Option A of the glass lab: a glass-look tile (soft fill, top highlight,
/// thin light edge, darker lower edge) laid over every cell as a tile map.
/// One shared texture, batched by SpriteKit; this is a drawn imitation,
/// not system Liquid Glass.
@MainActor enum RPGGlassTexture {
    static let tileSet: SKTileSet = {
        let side: CGFloat = 24
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cell = CGRect(x: 1.5, y: 1.5, width: side - 3, height: side - 3)
            let shape = UIBezierPath(roundedRect: cell, cornerRadius: 5)
            UIColor.white.withAlphaComponent(0.07).setFill(); shape.fill()
            context.cgContext.saveGState(); shape.addClip()
            let colors = [UIColor.white.withAlphaComponent(0.32).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: cell.minX, y: cell.minY), end: CGPoint(x: cell.minX, y: cell.midY), options: [])
            }
            context.cgContext.restoreGState()
            UIColor.white.withAlphaComponent(0.42).setStroke(); shape.lineWidth = 0.75; shape.stroke()
            let lower = UIBezierPath(); lower.move(to: CGPoint(x: cell.minX + 4, y: cell.maxY - 0.6)); lower.addLine(to: CGPoint(x: cell.maxX - 4, y: cell.maxY - 0.6))
            UIColor.black.withAlphaComponent(0.18).setStroke(); lower.lineWidth = 1; lower.stroke()
        }
        let definition = SKTileDefinition(texture: SKTexture(image: image), size: CGSize(width: side, height: side))
        return SKTileSet(tileGroups: [SKTileGroup(tileDefinition: definition)])
    }()

    static func map(columns: Int, rows: Int) -> SKTileMapNode {
        let map = SKTileMapNode(tileSet: tileSet, columns: columns, rows: rows, tileSize: CGSize(width: 24, height: 24))
        map.anchorPoint = .zero
        map.fill(with: tileSet.tileGroups.first)
        // V2.2: the base glass sits on the ground, under blocks and media,
        // so pictures stay clear; their own glass rim is drawn on top.
        map.zPosition = 1
        map.name = "glass-texture"
        map.shader = RPGGlassShader.shader
        return map
    }
}

/// One shader shared by every glass tile map: base glass plus a slow
/// moving highlight and a brighter rim. The highlight strength follows the
/// quality level; at "performance" only the static base glass is drawn.
@MainActor enum RPGGlassShader {
    private static let sheen = SKUniform(name: "u_sheen", float: Float(RPGGlassQuality.standard.sheen))
    static let shader: SKShader = {
        let source = """
        void main() {
            vec4 base = texture2D(u_texture, v_tex_coord);
            vec2 uv = v_tex_coord;
            float phase = fract(uv.x * 0.55 + uv.y * 0.45 - u_time * 0.08);
            float band = 1.0 - smoothstep(0.0, 0.16, abs(phase - 0.5));
            float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
            float rim = 1.0 - smoothstep(0.0, 0.1, edge);
            gl_FragColor = base + vec4(base.a) * u_sheen * (band + rim * 0.6);
        }
        """
        return SKShader(source: source, uniforms: [sheen])
    }()
    private(set) static var quality = RPGGlassQuality.standard
    static func apply(_ value: RPGGlassQuality) {
        quality = value
        sheen.floatValue = Float(value.sheen)
    }
}
