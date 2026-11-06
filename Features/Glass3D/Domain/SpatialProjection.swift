import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The 3D camera as plain maths: world (x, y map, z up) to screen points
/// and screen points to rays. RealityKit's camera is set from the same
/// eye, target and field of view, so taps, the native glass layer and the
/// rendered world line up, and all of it is unit tested.
struct SpatialProjection: Equatable, Sendable {
    var eye: SpatialVector
    var target: SpatialVector
    /// Vertical field of view, degrees.
    var fieldOfView: Double
    var viewSize: CGSize
    /// Camera turn (degrees): decides screen "up" when looking straight down.
    var yaw: Double = 0
    /// Set for the pixel RPG camera. Nil keeps the perspective projection.
    var orthographicSpan: Double? = nil

    private var basis: (forward: SpatialVector, right: SpatialVector, up: SpatialVector) {
        let forward = Self.normalize(target - eye)
        // Looking straight down has no "up" from z; use map north then.
        var right = Self.cross(forward, SpatialVector(0, 0, 1))
        if (right.x * right.x + right.y * right.y + right.z * right.z) < 1e-10 {
            right = SpatialVector(cos(yaw * .pi / 180), sin(yaw * .pi / 180), 0)
        }
        right = Self.normalize(right)
        let up = Self.cross(right, forward)
        return (forward, right, up)
    }

    /// Screen point (y down) and distance along the view direction, or nil
    /// behind the camera.
    func project(_ point: SpatialVector) -> (point: CGPoint, depth: Double)? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let (forward, right, up) = basis
        let d = point - eye
        let z = Self.dot(d, forward)
        guard z > 0.05 else { return nil }
        let aspect = Double(viewSize.width / viewSize.height)
        let x: Double
        let y: Double
        if let span = orthographicSpan, span > 0.5 {
            let halfV = span / 2, halfH = halfV * max(aspect, 0.001)
            x = Self.dot(d, right) / halfH
            y = Self.dot(d, up) / halfV
        } else {
            let f = 1 / tan(fieldOfView * .pi / 360)
            x = Self.dot(d, right) / z * f / max(aspect, 0.001)
            y = Self.dot(d, up) / z * f
        }
        return (CGPoint(x: (x + 1) / 2 * Double(viewSize.width), y: (1 - y) / 2 * Double(viewSize.height)), z)
    }

    /// The ray from the eye through a screen point. Orthographic rays stay parallel.
    func ray(through point: CGPoint) -> (origin: SpatialVector, direction: SpatialVector) {
        let (forward, right, up) = basis
        let aspect = Double(viewSize.width / max(1, viewSize.height))
        let nx = Double(point.x / max(1, viewSize.width)) * 2 - 1, ny = 1 - Double(point.y / max(1, viewSize.height)) * 2
        if let span = orthographicSpan, span > 0.5 {
            let halfV = span / 2, halfH = halfV * aspect
            return (eye + right * (nx * halfH) + up * (ny * halfV), forward)
        }
        let f = 1 / tan(fieldOfView * .pi / 360)
        let direction = Self.normalize(forward + right * (nx * aspect / f) + up * (ny / f))
        return (eye, direction)
    }

    static func dot(_ a: SpatialVector, _ b: SpatialVector) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func cross(_ a: SpatialVector, _ b: SpatialVector) -> SpatialVector { SpatialVector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x) }
    static func normalize(_ v: SpatialVector) -> SpatialVector {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return length > 0 ? v * (1 / length) : v
    }
}

/// What a tap hit in the 3D world.
struct SpatialHit: Equatable, Sendable {
    enum Kind: String, Sendable { case block, creature, chest, ground }
    var kind: Kind
    var id: String
    var point: SpatialVector
    var distance: Double
    var cell: SurfacePoint { SurfacePoint(x: min(255, max(0, Int(point.x.rounded(.down)))), z: min(255, max(0, Int(point.y.rounded(.down))))) }
}

enum SpatialPicking {
    /// Ray against an axis-aligned box; distance to the entry point.
    static func intersect(origin: SpatialVector, direction: SpatialVector, minimum: SpatialVector, maximum: SpatialVector) -> Double? {
        var near = -Double.infinity, far = Double.infinity
        for (o, d, lo, hi) in [(origin.x, direction.x, minimum.x, maximum.x), (origin.y, direction.y, minimum.y, maximum.y), (origin.z, direction.z, minimum.z, maximum.z)] {
            if abs(d) < 1e-12 { if o < lo || o > hi { return nil }; continue }
            var t1 = (lo - o) / d, t2 = (hi - o) / d
            if t1 > t2 { (t1, t2) = (t2, t1) }
            near = max(near, t1); far = min(far, t2)
            if near > far || far < 0 { return nil }
        }
        return near >= 0 ? near : far
    }

    /// Everything along the ray, nearest first: blocks (by their placed
    /// corners), creatures and chests (as small boxes) and the glass ground.
    static func pick(origin: SpatialVector, direction: SpatialVector, blocks: [SpatialBlock], frames: [String: GroupFrame],
                     creatures: [CreatureEntity], pickups: [PickupEntity], groundHoles: Set<Int> = [], maxDistance: Double = 400) -> [SpatialHit] {
        var hits: [SpatialHit] = []
        for block in blocks {
            let corners = SpatialFaces.corners(block, frame: block.groupID.flatMap { frames[$0] })
            let lo = SpatialVector(corners.map(\.x).min()!, corners.map(\.y).min()!, corners.map(\.z).min()!)
            let hi = SpatialVector(corners.map(\.x).max()!, corners.map(\.y).max()!, corners.map(\.z).max()!)
            if let t = intersect(origin: origin, direction: direction, minimum: lo, maximum: hi), t <= maxDistance {
                hits.append(SpatialHit(kind: .block, id: block.id, point: origin + direction * t, distance: t))
            }
        }
        for creature in creatures where creature.alive {
            let r = creature.kind == .boss ? 1.1 : creature.kind == .miniBoss ? 0.7 : 0.4, h = creature.kind == .boss ? 2.8 : 1.4
            let p = creature.position
            if let t = intersect(origin: origin, direction: direction, minimum: SpatialVector(p.x - r, p.y - r, p.z), maximum: SpatialVector(p.x + r, p.y + r, p.z + h)), t <= maxDistance {
                hits.append(SpatialHit(kind: .creature, id: creature.id, point: origin + direction * t, distance: t))
            }
        }
        for pickup in pickups where !pickup.collected {
            let p = pickup.position
            if let t = intersect(origin: origin, direction: direction, minimum: SpatialVector(p.x - 0.3, p.y - 0.3, p.z), maximum: SpatialVector(p.x + 0.3, p.y + 0.3, p.z + 0.5)), t <= maxDistance {
                hits.append(SpatialHit(kind: .chest, id: pickup.id, point: origin + direction * t, distance: t))
            }
        }
        if direction.z < -1e-9 {
            let t = -origin.z / direction.z
            let point = origin + direction * t
            let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
            if t <= maxDistance, (0..<256).contains(x), (0..<256).contains(y), !groundHoles.contains(y * 256 + x) {
                hits.append(SpatialHit(kind: .ground, id: "", point: point, distance: t))
            }
        }
        return hits.sorted { $0.distance < $1.distance }
    }
}
