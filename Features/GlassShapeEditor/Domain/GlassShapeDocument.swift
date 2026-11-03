import Foundation

/// System glass only (the plan keeps refraction, blur and highlights to
/// the system): regular or clear, an optional tint, and interactive.
enum GlassShapeMaterial: String, Codable, CaseIterable, Sendable {
    case regular, clear
    var title: String { self == .regular ? "Regular" : "Clear" }
}

/// One designed shape: name, outline and glass settings.
struct ShapeDocument: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var outline: ShapeOutline
    var material = GlassShapeMaterial.regular
    /// 6-digit hex, nil for no tint.
    var tintHex: String?
    var interactive = false
    var updated = Date(timeIntervalSince1970: 0)

    init(id: String = UUID().uuidString, name: String, outline: ShapeOutline) {
        self.id = id; self.name = name; self.outline = outline
    }

    var valid: Bool {
        !id.isEmpty && id.count <= 128 && (1...64).contains(name.count) && outline.valid &&
            (tintHex.map { $0.count == 6 && $0.allSatisfy(\.isHexDigit) } ?? true)
    }
}

/// Undo and redo for the editor. One drag is one step: the caller records
/// the state when a gesture starts, not on every move.
struct ShapeHistory: Equatable, Sendable {
    static let limit = 60
    private(set) var past: [ShapeDocument] = []
    private(set) var future: [ShapeDocument] = []

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

    /// Remember `state` before changing it.
    mutating func record(_ state: ShapeDocument) {
        if past.last == state { return }
        past.append(state)
        if past.count > Self.limit { past.removeFirst(past.count - Self.limit) }
        future = []
    }
    mutating func undo(_ current: ShapeDocument) -> ShapeDocument? {
        guard let previous = past.popLast() else { return nil }
        future.append(current); return previous
    }
    mutating func redo(_ current: ShapeDocument) -> ShapeDocument? {
        guard let next = future.popLast() else { return nil }
        past.append(current); return next
    }
    mutating func clear() { past = []; future = [] }
}

/// Saved shapes plus the one being edited.
struct ShapeLibrary: Codable, Equatable, Sendable {
    static let version = 1
    static let capacity = 200
    var version = Self.version
    var currentID: String?
    var shapes: [ShapeDocument] = []

    var current: ShapeDocument? { shapes.first { $0.id == currentID } ?? shapes.first }

    mutating func upsert(_ document: ShapeDocument) {
        if let index = shapes.firstIndex(where: { $0.id == document.id }) { shapes[index] = document }
        else { shapes.insert(document, at: 0); if shapes.count > Self.capacity { shapes.removeLast(shapes.count - Self.capacity) } }
        currentID = document.id
    }
    mutating func remove(_ id: String) {
        shapes.removeAll { $0.id == id }
        if currentID == id { currentID = shapes.first?.id }
    }
    mutating func duplicate(_ id: String, suffix: String) -> ShapeDocument? {
        guard let original = shapes.first(where: { $0.id == id }) else { return nil }
        var copy = original; copy.id = UUID().uuidString; copy.name = String((original.name + suffix).prefix(64))
        upsert(copy); return copy
    }

    static func decode(_ data: Data) -> ShapeLibrary? {
        guard var library = try? JSONDecoder().decode(ShapeLibrary.self, from: data), library.version == Self.version else { return nil }
        library.shapes = library.shapes.filter(\.valid)
        return library
    }
}

// MARK: Export

enum ShapeCodeExporter {
    /// A Swift type name from the shape's name: ASCII letters and digits,
    /// starting with a capital, ending in "Shape".
    static func typeName(_ name: String) -> String {
        let words = name.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map { word in word.prefix(1).uppercased() + word.dropFirst() }
        var base = words.joined()
        if base.isEmpty || base.first!.isNumber { base = "Glass" + base }
        if !base.hasSuffix("Shape") { base += "Shape" }
        return String(base.prefix(60))
    }

    /// Up to four decimals, no trailing zeros ("0.5", "0.1234", "1").
    static func number(_ value: Double) -> String {
        let rounded = (value * 10000).rounded() / 10000
        var text = String(format: "%.4f", rounded == 0 ? 0 : rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// A complete SwiftUI `Shape`. Coordinates are relative (0–1), so it
    /// scales to any frame without distortion.
    static func swift(_ document: ShapeDocument) -> String {
        let name = typeName(document.name)
        func p(_ point: ShapePoint) -> String { "p(\(number(point.x)), \(number(point.y)))" }
        var lines = [
            "import SwiftUI",
            "",
            "/// \(document.name.replacingOccurrences(of: "\n", with: " ")) — exported from Moonlight Glass Shape Editor.",
            "/// Relative coordinates (0–1); use it at any size, e.g.",
            "/// `.glassEffect(\(glassExpression(document)), in: \(name)())`",
            "struct \(name): Shape {",
            "    func path(in rect: CGRect) -> Path {",
            "        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {",
            "            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)",
            "        }",
            "        var path = Path()",
        ]
        let cubics = document.outline.cubics
        if let first = cubics.first {
            lines.append("        path.move(to: \(p(first.from)))")
            for cubic in cubics {
                lines.append("        path.addCurve(to: \(p(cubic.to)), control1: \(p(cubic.c1)), control2: \(p(cubic.c2)))")
            }
            lines.append("        path.closeSubpath()")
        }
        lines += ["        return path", "    }", "}", ""]
        return lines.joined(separator: "\n")
    }

    static func glassExpression(_ document: ShapeDocument) -> String {
        var text = "." + document.material.rawValue
        if let tint = document.tintHex {
            let r = Int(tint.prefix(2), radix: 16) ?? 0, g = Int(tint.dropFirst(2).prefix(2), radix: 16) ?? 0, b = Int(tint.suffix(2), radix: 16) ?? 0
            text += ".tint(Color(red: \(number(Double(r) / 255)), green: \(number(Double(g) / 255)), blue: \(number(Double(b) / 255))))"
        }
        if document.interactive { text += ".interactive()" }
        return text
    }

    /// A standard SVG path in a 100 × 100 view box (P1: back to Figma).
    static func svg(_ document: ShapeDocument) -> String {
        func p(_ point: ShapePoint) -> String { "\(number(point.x * 100)) \(number(point.y * 100))" }
        let cubics = document.outline.cubics
        guard let first = cubics.first else { return "" }
        var d = "M \(p(first.from))"
        for cubic in cubics { d += " C \(p(cubic.c1)) \(p(cubic.c2)) \(p(cubic.to))" }
        d += " Z"
        let title = document.name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <title>\(title)</title>
          <path d="\(d)" fill="#000000"/>
        </svg>

        """
    }
}

// MARK: Text-to-shape results

/// One anchor as the language model returns it.
struct GeneratedShapeAnchor: Equatable, Sendable {
    var x: Double
    var y: Double
    var smooth: Bool
}

enum ShapeGenerationProblem: Error, Equatable, Sendable {
    case tooFewAnchors, outOfRange, selfIntersecting
    var message: String {
        switch self {
        case .tooFewAnchors: L10n.t("生成的锚点太少", "Too few anchors")
        case .outOfRange: L10n.t("坐标超出范围", "Coordinates out of range")
        case .selfIntersecting: L10n.t("形状自相交", "The outline crosses itself")
        }
    }
}

/// Turns model output into an editable outline and checks it: closed (by
/// construction), coordinates in range, no self-intersection. Handles are
/// computed from the points, so the model only places anchors.
enum ShapeGeneration {
    static let anchorRange = 3...16

    static func outline(from anchors: [GeneratedShapeAnchor]) -> Result<ShapeOutline, ShapeGenerationProblem> {
        guard anchors.count >= anchorRange.lowerBound else { return .failure(.tooFewAnchors) }
        let usable = Array(anchors.prefix(anchorRange.upperBound))
        // Small overshoots are clamped; anything far outside is refused.
        guard usable.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (-0.05...1.05).contains($0.x) && (-0.05...1.05).contains($0.y) }) else { return .failure(.outOfRange) }
        var points = usable.map { ShapePoint($0.x, $0.y).clamped }
        // Drop consecutive duplicates, which would make zero-length segments.
        points = points.enumerated().filter { index, point in index == 0 || point.distance(to: points[index - 1]) > 0.01 }.map(\.1)
        if let first = points.first, let last = points.last, points.count > 1, first.distance(to: last) <= 0.01 { points.removeLast() }
        guard points.count >= anchorRange.lowerBound else { return .failure(.tooFewAnchors) }
        let flags = usable.map(\.smooth)
        let outline = ShapeOutline.through(points, smooth: flags).fitted()
        guard outline.valid else { return .failure(.outOfRange) }
        guard !outline.selfIntersects else { return .failure(.selfIntersecting) }
        return .success(outline)
    }

    /// Partial output while streaming: the anchors that already have both
    /// coordinates, as dots on the canvas.
    static func partialPoints(_ values: [(Double?, Double?)]) -> [ShapePoint] {
        values.compactMap { x, y in
            guard let x, let y, x.isFinite, y.isFinite else { return nil }
            return ShapePoint(x, y).clamped
        }
    }

    static let instructions = """
    You design closed 2D outlines for an iPhone glass shape editor. \
    Place the outline's anchor points on a unit square: x from 0 (left) to 1 (right), y from 0 (top) to 1 (bottom). \
    List anchors in clockwise order around the outline, starting at the top. Use between 4 and 12 anchors, spread around the whole outline, \
    and make the shape fill most of the square. The outline must not cross itself. \
    Mark an anchor smooth for a rounded curve, or not smooth for a sharp point or corner.
    """
}
