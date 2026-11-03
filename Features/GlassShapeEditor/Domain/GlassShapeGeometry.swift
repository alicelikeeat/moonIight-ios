import Foundation

/// A point in relative shape space: 0–1 on both axes, y pointing down
/// (the SwiftUI convention). Shapes keep these coordinates everywhere, so a
/// shape scales to any size without distortion.
struct ShapePoint: Codable, Equatable, Hashable, Sendable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    static func + (a: Self, b: Self) -> Self { .init(a.x + b.x, a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { .init(a.x - b.x, a.y - b.y) }
    static func * (a: Self, k: Double) -> Self { .init(a.x * k, a.y * k) }
    var length: Double { (x * x + y * y).squareRoot() }
    var finite: Bool { x.isFinite && y.isFinite }
    var inUnit: Bool { finite && (0...1).contains(x) && (0...1).contains(y) }
    var clamped: Self { .init(min(1, max(0, x.isFinite ? x : 0.5)), min(1, max(0, y.isFinite ? y : 0.5))) }
    func distance(to other: Self) -> Double { (self - other).length }
    static func lerp(_ a: Self, _ b: Self, _ t: Double) -> Self { a + (b - a) * t }
}

/// One anchor of a closed Bézier outline. Handles are absolute positions in
/// the same 0–1 space. Smooth anchors keep their two handles symmetric;
/// corner anchors move them independently.
struct ShapeAnchor: Codable, Equatable, Sendable {
    var point: ShapePoint
    var handleIn: ShapePoint
    var handleOut: ShapePoint
    var smooth: Bool

    init(_ point: ShapePoint, handleIn: ShapePoint? = nil, handleOut: ShapePoint? = nil, smooth: Bool = false) {
        self.point = point; self.handleIn = handleIn ?? point; self.handleOut = handleOut ?? point; self.smooth = smooth
    }
    var valid: Bool { point.inUnit && handleIn.inUnit && handleOut.inUnit }
}

/// One cubic segment: from → (c1, c2) → to.
struct ShapeCubic: Equatable, Sendable {
    var from: ShapePoint, c1: ShapePoint, c2: ShapePoint, to: ShapePoint
    func point(at t: Double) -> ShapePoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return .init(from.x * a + c1.x * b + c2.x * c + to.x * d, from.y * a + c1.y * b + c2.y * c + to.y * d)
    }
    /// De Casteljau split at t: the curve is unchanged, with a new anchor at t.
    func split(at t: Double) -> (left: ShapeCubic, right: ShapeCubic) {
        let p01 = ShapePoint.lerp(from, c1, t), p12 = ShapePoint.lerp(c1, c2, t), p23 = ShapePoint.lerp(c2, to, t)
        let p012 = ShapePoint.lerp(p01, p12, t), p123 = ShapePoint.lerp(p12, p23, t)
        let mid = ShapePoint.lerp(p012, p123, t)
        return (.init(from: from, c1: p01, c2: p012, to: mid), .init(from: mid, c1: p123, c2: p23, to: to))
    }
}

enum ShapeHandle: String, Sendable { case incoming, outgoing }

/// A closed outline made of cubic Bézier segments. It is always closed:
/// the last anchor connects back to the first.
struct ShapeOutline: Codable, Equatable, Sendable {
    static let minimumAnchors = 3
    static let maximumAnchors = 24

    var anchors: [ShapeAnchor]

    init(anchors: [ShapeAnchor]) { self.anchors = anchors }

    var valid: Bool {
        (Self.minimumAnchors...Self.maximumAnchors).contains(anchors.count) && anchors.allSatisfy(\.valid)
    }

    /// The closed list of segments. Rendering, hit testing and every export
    /// use this one list, so the editor and exported code draw the same curve.
    var cubics: [ShapeCubic] {
        guard anchors.count >= 2 else { return [] }
        return anchors.indices.map { index in
            let a = anchors[index], b = anchors[(index + 1) % anchors.count]
            return ShapeCubic(from: a.point, c1: a.handleOut, c2: b.handleIn, to: b.point)
        }
    }

    /// The outline as a polygon (for hit testing and self-intersection).
    func polyline(samples: Int = 12) -> [ShapePoint] {
        cubics.flatMap { cubic in (0..<samples).map { cubic.point(at: Double($0) / Double(samples)) } }
    }

    // MARK: Checks

    /// True when the outline crosses itself; such shapes refract messily.
    var selfIntersects: Bool {
        let points = polyline(samples: 10)
        let count = points.count
        guard count >= 4 else { return false }
        for i in 0..<count {
            let a1 = points[i], a2 = points[(i + 1) % count]
            for j in stride(from: i + 2, to: count, by: 1) {
                if i == 0 && j == count - 1 { continue } // neighbours through the closing edge
                let b1 = points[j], b2 = points[(j + 1) % count]
                if Self.segmentsCross(a1, a2, b1, b2) { return true }
            }
        }
        return false
    }

    /// Segments that cross or touch (non-neighbouring segments only).
    private static func segmentsCross(_ p1: ShapePoint, _ p2: ShapePoint, _ q1: ShapePoint, _ q2: ShapePoint) -> Bool {
        func cross(_ o: ShapePoint, _ a: ShapePoint, _ b: ShapePoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        func sign(_ v: Double) -> Int { v > 1e-12 ? 1 : v < -1e-12 ? -1 : 0 }
        func within(_ o: ShapePoint, _ a: ShapePoint, _ b: ShapePoint) -> Bool {
            min(o.x, a.x) - 1e-12 <= b.x && b.x <= max(o.x, a.x) + 1e-12 && min(o.y, a.y) - 1e-12 <= b.y && b.y <= max(o.y, a.y) + 1e-12
        }
        let d1 = sign(cross(q1, q2, p1)), d2 = sign(cross(q1, q2, p2)), d3 = sign(cross(p1, p2, q1)), d4 = sign(cross(p1, p2, q2))
        if d1 != d2 && d3 != d4 && d1 * d2 <= 0 && d3 * d4 <= 0 { return true }
        return (d1 == 0 && within(q1, q2, p1)) || (d2 == 0 && within(q1, q2, p2)) || (d3 == 0 && within(p1, p2, q1)) || (d4 == 0 && within(p1, p2, q2))
    }

    /// Anchors whose corner is sharper than `degrees` (a warning, not an error).
    func sharpCorners(below degrees: Double = 20) -> [Int] {
        anchors.indices.filter { index in
            let a = anchors[index]
            let previous = anchors[(index + anchors.count - 1) % anchors.count].point
            let next = anchors[(index + 1) % anchors.count].point
            // Incoming and outgoing directions; a zero handle falls back to the neighbour.
            let incoming = a.handleIn.distance(to: a.point) > 1e-6 ? a.handleIn : previous
            let outgoing = a.handleOut.distance(to: a.point) > 1e-6 ? a.handleOut : next
            let u = incoming - a.point, v = outgoing - a.point
            guard u.length > 1e-6, v.length > 1e-6 else { return false }
            let cosine = max(-1, min(1, (u.x * v.x + u.y * v.y) / (u.length * v.length)))
            return acos(cosine) * 180 / .pi < degrees
        }
    }

    /// Bounding box of the curve (approximate, from samples).
    var bounds: (min: ShapePoint, max: ShapePoint) {
        let points = polyline(samples: 8)
        guard let first = points.first else { return (.init(0, 0), .init(1, 1)) }
        return points.reduce((first, first)) { box, p in
            (.init(min(box.0.x, p.x), min(box.0.y, p.y)), .init(max(box.1.x, p.x), max(box.1.y, p.y)))
        }
    }

    /// Even-odd point-in-shape test on the sampled outline.
    func contains(_ point: ShapePoint) -> Bool {
        let polygon = polyline(samples: 10)
        var inside = false, j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: Hit testing

    /// The anchor within `radius` of `point`, nearest first.
    func anchor(near point: ShapePoint, radius: Double) -> Int? {
        anchors.indices.map { ($0, anchors[$0].point.distance(to: point)) }.filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }

    /// The handle of anchor `index` within `radius`, ignoring handles that
    /// sit on their anchor.
    func handle(of index: Int, near point: ShapePoint, radius: Double) -> ShapeHandle? {
        guard anchors.indices.contains(index) else { return nil }
        let a = anchors[index]
        let candidates: [(ShapeHandle, ShapePoint)] = [(.incoming, a.handleIn), (.outgoing, a.handleOut)]
        return candidates.filter { $0.1.distance(to: a.point) > 1e-6 && $0.1.distance(to: point) <= radius }
            .min { $0.1.distance(to: point) < $1.1.distance(to: point) }?.0
    }

    /// The segment and curve parameter closest to `point`.
    func nearestSegment(to point: ShapePoint) -> (index: Int, t: Double, distance: Double)? {
        var best: (Int, Double, Double)?
        for (index, cubic) in cubics.enumerated() {
            for step in 0...40 {
                let t = Double(step) / 40, d = cubic.point(at: t).distance(to: point)
                if best == nil || d < best!.2 { best = (index, t, d) }
            }
        }
        return best.map { (index: $0.0, t: $0.1, distance: $0.2) }
    }

    // MARK: Editing (each returns false when nothing changed)

    /// Adds an anchor. Near the outline it splits that segment without
    /// changing the curve; elsewhere it goes into the nearest segment as a
    /// corner at the tapped point.
    @discardableResult
    mutating func insertAnchor(at point: ShapePoint, splitRadius: Double = 0.04) -> Int? {
        guard anchors.count < Self.maximumAnchors, point.finite, let nearest = nearestSegment(to: point) else { return nil }
        let index = nearest.index, next = (index + 1) % anchors.count
        let target = point.clamped
        if nearest.distance <= splitRadius, nearest.t > 0.02, nearest.t < 0.98 {
            let halves = cubics[index].split(at: nearest.t)
            anchors[index].handleOut = halves.left.c1
            anchors[next].handleIn = halves.right.c2
            let anchor = ShapeAnchor(halves.left.to, handleIn: halves.left.c2, handleOut: halves.right.c1, smooth: anchors[index].smooth || anchors[next].smooth)
            anchors.insert(anchor, at: index + 1)
        } else {
            anchors.insert(ShapeAnchor(target), at: index + 1)
        }
        return index + 1
    }

    @discardableResult
    mutating func removeAnchor(_ index: Int) -> Bool {
        guard anchors.indices.contains(index), anchors.count > Self.minimumAnchors else { return false }
        anchors.remove(at: index); return true
    }

    /// Moves an anchor and its handles together, kept inside the unit square.
    @discardableResult
    mutating func moveAnchor(_ index: Int, to point: ShapePoint) -> Bool {
        guard anchors.indices.contains(index), point.finite else { return false }
        let a = anchors[index]
        var delta = point - a.point
        // Shrink the move so neither the anchor nor its handles leave 0–1.
        for p in [a.point, a.handleIn, a.handleOut] {
            delta.x = min(max(delta.x, -p.x), 1 - p.x)
            delta.y = min(max(delta.y, -p.y), 1 - p.y)
        }
        guard delta.length > 0 else { return false }
        anchors[index].point = a.point + delta
        anchors[index].handleIn = a.handleIn + delta
        anchors[index].handleOut = a.handleOut + delta
        return true
    }

    /// Moves one handle. A smooth anchor mirrors the other handle at the
    /// same length (对称控制柄).
    @discardableResult
    mutating func moveHandle(_ index: Int, _ handle: ShapeHandle, to point: ShapePoint) -> Bool {
        guard anchors.indices.contains(index), point.finite else { return false }
        var a = anchors[index]
        let target = point.clamped
        switch handle {
        case .incoming: a.handleIn = target
        case .outgoing: a.handleOut = target
        }
        if a.smooth {
            let mirrored = (a.point - target) + a.point
            if handle == .incoming { a.handleOut = Self.clampAlong(a.point, mirrored) } else { a.handleIn = Self.clampAlong(a.point, mirrored) }
        }
        guard a != anchors[index] else { return false }
        anchors[index] = a; return true
    }

    /// Smooth ↔ corner. Turning smooth lines the handles up symmetrically
    /// (and gives a bare corner handles along its neighbours).
    mutating func toggleSmooth(_ index: Int) {
        guard anchors.indices.contains(index) else { return }
        var a = anchors[index]
        a.smooth.toggle()
        if a.smooth {
            let previous = anchors[(index + anchors.count - 1) % anchors.count].point
            let next = anchors[(index + 1) % anchors.count].point
            var direction = a.handleOut - a.handleIn
            if direction.length < 1e-6 { direction = next - previous }
            if direction.length < 1e-6 { direction = .init(1, 0) }
            let unit = direction * (1 / direction.length)
            var length = (a.handleIn.distance(to: a.point) + a.handleOut.distance(to: a.point)) / 2
            if length < 1e-6 { length = min(previous.distance(to: a.point), next.distance(to: a.point)) / 3 }
            a.handleOut = Self.clampAlong(a.point, a.point + unit * length)
            a.handleIn = Self.clampAlong(a.point, a.point - unit * length)
        }
        anchors[index] = a
    }

    /// Snaps every anchor and handle to a grid of `step`.
    func snapped(_ point: ShapePoint, step: Double) -> ShapePoint {
        guard step > 0 else { return point }
        func snap(_ v: Double) -> Double { ((v / step).rounded() * step * 1_000_000).rounded() / 1_000_000 }
        return .init(snap(point.x), snap(point.y)).clamped
    }

    /// Keeps a handle on its ray from the anchor but inside 0–1.
    private static func clampAlong(_ origin: ShapePoint, _ target: ShapePoint) -> ShapePoint {
        let d = target - origin
        var t = 1.0
        if d.x > 0 { t = min(t, (1 - origin.x) / d.x) } else if d.x < 0 { t = min(t, -origin.x / d.x) }
        if d.y > 0 { t = min(t, (1 - origin.y) / d.y) } else if d.y < 0 { t = min(t, -origin.y / d.y) }
        return (origin + d * max(0, t)).clamped
    }

    // MARK: Building

    /// A smooth closed curve through `points` (Catmull-Rom handles). Corner
    /// points get handles pointing at their neighbours instead.
    static func through(_ points: [ShapePoint], smooth: [Bool]? = nil, tension: Double = 1) -> ShapeOutline {
        let n = points.count
        let anchors = points.indices.map { index -> ShapeAnchor in
            let p = points[index], previous = points[(index + n - 1) % n], next = points[(index + 1) % n]
            let isSmooth = smooth.map { $0.indices.contains(index) ? $0[index] : true } ?? true
            if isSmooth {
                let tangent = (next - previous) * (tension / 6)
                return ShapeAnchor(p, handleIn: clampAlong(p, p - tangent), handleOut: clampAlong(p, p + tangent), smooth: true)
            }
            return ShapeAnchor(p, handleIn: ShapePoint.lerp(p, previous, 0.25), handleOut: ShapePoint.lerp(p, next, 0.25), smooth: false)
        }
        return ShapeOutline(anchors: anchors)
    }

    /// Scales and centres the outline to fill the unit square with `margin`.
    func fitted(margin: Double = 0.04) -> ShapeOutline {
        let box = bounds
        let width = box.max.x - box.min.x, height = box.max.y - box.min.y
        guard width > 1e-6, height > 1e-6 else { return self }
        let scale = (1 - 2 * margin) / max(width, height)
        let offset = ShapePoint((1 - width * scale) / 2, (1 - height * scale) / 2)
        func map(_ p: ShapePoint) -> ShapePoint { (ShapePoint((p.x - box.min.x) * scale, (p.y - box.min.y) * scale) + offset).clamped }
        return ShapeOutline(anchors: anchors.map { ShapeAnchor(map($0.point), handleIn: map($0.handleIn), handleOut: map($0.handleOut), smooth: $0.smooth) })
    }
}


/// Built-in starting shapes, available on every iOS version.
enum ShapeTemplate: String, CaseIterable, Sendable {
    case square, circle, capsule, droplet, leaf, heart, star, wave

    var title: String {
        switch self {
        case .square: L10n.t("方形", "Square")
        case .circle: L10n.t("圆形", "Circle")
        case .capsule: L10n.t("胶囊", "Capsule")
        case .droplet: L10n.t("水滴", "Droplet")
        case .leaf: L10n.t("叶子", "Leaf")
        case .heart: L10n.t("心形", "Heart")
        case .star: L10n.t("星形", "Star")
        case .wave: L10n.t("波浪", "Wave")
        }
    }
    var symbol: String {
        switch self {
        case .square: "square"; case .circle: "circle"; case .capsule: "capsule"; case .droplet: "drop"
        case .leaf: "leaf"; case .heart: "heart"; case .star: "star"; case .wave: "water.waves"
        }
    }

    var outline: ShapeOutline {
        switch self {
        case .square:
            return ShapeOutline(anchors: [ShapePoint(0.08, 0.08), ShapePoint(0.92, 0.08), ShapePoint(0.92, 0.92), ShapePoint(0.08, 0.92)].map { ShapeAnchor($0) })
        case .circle:
            // Four anchors with the standard 0.5523 handle ratio.
            let k = 0.5523 * 0.46, c = 0.5, r = 0.46
            return ShapeOutline(anchors: [
                ShapeAnchor(.init(c, c - r), handleIn: .init(c - k, c - r), handleOut: .init(c + k, c - r), smooth: true),
                ShapeAnchor(.init(c + r, c), handleIn: .init(c + r, c - k), handleOut: .init(c + r, c + k), smooth: true),
                ShapeAnchor(.init(c, c + r), handleIn: .init(c + k, c + r), handleOut: .init(c - k, c + r), smooth: true),
                ShapeAnchor(.init(c - r, c), handleIn: .init(c - r, c + k), handleOut: .init(c - r, c - k), smooth: true),
            ])
        case .capsule:
            let k = 0.5523 * 0.25
            return ShapeOutline(anchors: [
                ShapeAnchor(.init(0.27, 0.25), handleIn: .init(0.27 - k, 0.25)),
                ShapeAnchor(.init(0.73, 0.25), handleOut: .init(0.73 + k, 0.25)),
                ShapeAnchor(.init(0.98, 0.5), handleIn: .init(0.98, 0.5 - k), handleOut: .init(0.98, 0.5 + k), smooth: true),
                ShapeAnchor(.init(0.73, 0.75), handleIn: .init(0.73 + k, 0.75)),
                ShapeAnchor(.init(0.27, 0.75), handleOut: .init(0.27 - k, 0.75)),
                ShapeAnchor(.init(0.02, 0.5), handleIn: .init(0.02, 0.5 + k), handleOut: .init(0.02, 0.5 - k), smooth: true),
            ])
        case .droplet:
            return ShapeOutline(anchors: [
                ShapeAnchor(.init(0.5, 0.04), handleIn: .init(0.42, 0.18), handleOut: .init(0.58, 0.18)),
                ShapeAnchor(.init(0.86, 0.62), handleIn: .init(0.8, 0.42), handleOut: .init(0.88, 0.8), smooth: true),
                ShapeAnchor(.init(0.5, 0.96), handleIn: .init(0.72, 0.96), handleOut: .init(0.28, 0.96), smooth: true),
                ShapeAnchor(.init(0.14, 0.62), handleIn: .init(0.12, 0.8), handleOut: .init(0.2, 0.42), smooth: true),
            ])
        case .leaf:
            return ShapeOutline.through([.init(0.06, 0.94), .init(0.24, 0.3), .init(0.94, 0.06), .init(0.7, 0.76)], smooth: [false, true, false, true], tension: 1.2)
        case .heart:
            return ShapeOutline(anchors: [
                ShapeAnchor(.init(0.5, 0.28), handleIn: .init(0.42, 0.1), handleOut: .init(0.58, 0.1)),
                ShapeAnchor(.init(0.94, 0.34), handleIn: .init(0.9, 0.06), handleOut: .init(0.98, 0.6), smooth: true),
                ShapeAnchor(.init(0.5, 0.94), handleIn: .init(0.78, 0.74), handleOut: .init(0.22, 0.74)),
                ShapeAnchor(.init(0.06, 0.34), handleIn: .init(0.02, 0.6), handleOut: .init(0.1, 0.06), smooth: true),
            ])
        case .star:
            let points = (0..<10).map { index -> ShapePoint in
                let angle = -Double.pi / 2 + Double(index) * Double.pi / 5, radius = index.isMultiple(of: 2) ? 0.48 : 0.2
                return ShapePoint(0.5 + cos(angle) * radius, 0.52 + sin(angle) * radius).clamped
            }
            return ShapeOutline(anchors: points.map { ShapeAnchor($0) })
        case .wave:
            return ShapeOutline.through([
                .init(0.04, 0.3), .init(0.27, 0.18), .init(0.5, 0.3), .init(0.73, 0.18), .init(0.96, 0.3),
                .init(0.96, 0.82), .init(0.04, 0.82),
            ], smooth: [false, true, true, true, false, false, false])
        }
    }
}
