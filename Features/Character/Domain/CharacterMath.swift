import Foundation

// v1.91 (Moonlight Universal Character System): small math for characters
// that works on Linux too (no simd module there): unit quaternions for joint
// rotations, conversions to the rig's RigXform, and vector helpers.

/// Unit quaternion (x, y, z, w). Codable so motions can be saved.
struct Quat: Codable, Equatable, Sendable {
    var x: Float = 0, y: Float = 0, z: Float = 0, w: Float = 1

    static let identity = Quat()

    init(x: Float = 0, y: Float = 0, z: Float = 0, w: Float = 1) { self.x = x; self.y = y; self.z = z; self.w = w }

    /// Rotation by `angle` radians about `axis` (any length; zero → identity).
    init(axis: SIMD3<Float>, angle: Float) {
        let l = cLength(axis)
        guard l > 1e-9, angle.isFinite else { self = .identity; return }
        let s = sin(angle / 2) / l
        self.init(x: axis.x * s, y: axis.y * s, z: axis.z * s, w: cos(angle / 2))
    }

    /// The same rotation as `RigXform.euler` (Z · Y · X), from degrees.
    init(eulerDegrees e: SIMD3<Float>) {
        let k = Float.pi / 180
        self = Quat(axis: SIMD3(0, 0, 1), angle: e.z * k) * Quat(axis: SIMD3(0, 1, 0), angle: e.y * k) * Quat(axis: SIMD3(1, 0, 0), angle: e.x * k)
    }

    /// Shortest rotation taking direction `a` to direction `b`.
    static func between(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Quat {
        let la = cLength(a), lb = cLength(b)
        guard la > 1e-9, lb > 1e-9 else { return .identity }
        let u = a / la, v = b / lb
        let d = cDot(u, v)
        if d > 0.999999 { return .identity }
        if d < -0.999999 {
            var axis = cCross(SIMD3(1, 0, 0), u)
            if cLength(axis) < 1e-4 { axis = cCross(SIMD3(0, 1, 0), u) }
            return Quat(axis: axis, angle: .pi)
        }
        let c = cCross(u, v)
        return Quat(x: c.x, y: c.y, z: c.z, w: 1 + d).normalized
    }

    static func * (l: Quat, r: Quat) -> Quat {
        Quat(x: l.w * r.x + l.x * r.w + l.y * r.z - l.z * r.y,
             y: l.w * r.y - l.x * r.z + l.y * r.w + l.z * r.x,
             z: l.w * r.z + l.x * r.y - l.y * r.x + l.z * r.w,
             w: l.w * r.w - l.x * r.x - l.y * r.y - l.z * r.z)
    }

    var conjugate: Quat { Quat(x: -x, y: -y, z: -z, w: w) }
    var length: Float { (x * x + y * y + z * z + w * w).squareRoot() }
    var finite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
    var normalized: Quat {
        let l = length
        guard l > 1e-9, l.isFinite else { return .identity }
        return Quat(x: x / l, y: y / l, z: z / l, w: w / l)
    }
    /// Angle of the rotation, radians (0…π).
    var angle: Float { 2 * acos(min(1, abs(normalized.w))) }

    func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let q = SIMD3(x, y, z)
        let t = cCross(q, v) * 2
        return v + t * w + cCross(q, t)
    }

    static func dot(_ a: Quat, _ b: Quat) -> Float { a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w }

    /// Spherical interpolation along the shorter arc.
    static func slerp(_ a: Quat, _ b: Quat, _ t: Float) -> Quat {
        var b = b
        var d = dot(a, b)
        if d < 0 { b = Quat(x: -b.x, y: -b.y, z: -b.z, w: -b.w); d = -d }
        if d > 0.9995 {
            return Quat(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t, w: a.w + (b.w - a.w) * t).normalized
        }
        let theta = acos(min(1, d)), s = sin(theta)
        let wa = sin((1 - t) * theta) / s, wb = sin(t * theta) / s
        return Quat(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb, z: a.z * wa + b.z * wb, w: a.w * wa + b.w * wb)
    }

    /// Same rotation as a RigXform (no translation).
    var xform: RigXform {
        let q = normalized
        var r = RigXform()
        r.a = 1 - 2 * (q.y * q.y + q.z * q.z); r.b = 2 * (q.x * q.y + q.z * q.w); r.c = 2 * (q.x * q.z - q.y * q.w)
        r.d = 2 * (q.x * q.y - q.z * q.w); r.e = 1 - 2 * (q.x * q.x + q.z * q.z); r.f = 2 * (q.y * q.z + q.x * q.w)
        r.g = 2 * (q.x * q.z + q.y * q.w); r.h = 2 * (q.y * q.z - q.x * q.w); r.i = 1 - 2 * (q.x * q.x + q.y * q.y)
        return r
    }

    /// Rotation part of a RigXform (assumed orthonormal).
    init(_ m: RigXform) {
        let trace = m.a + m.e + m.i
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            self.init(x: (m.f - m.h) / s, y: (m.g - m.c) / s, z: (m.b - m.d) / s, w: s / 4)
        } else if m.a > m.e && m.a > m.i {
            let s = (1 + m.a - m.e - m.i).squareRoot() * 2
            self.init(x: s / 4, y: (m.d + m.b) / s, z: (m.g + m.c) / s, w: (m.f - m.h) / s)
        } else if m.e > m.i {
            let s = (1 + m.e - m.a - m.i).squareRoot() * 2
            self.init(x: (m.d + m.b) / s, y: s / 4, z: (m.h + m.f) / s, w: (m.g - m.c) / s)
        } else {
            let s = (1 + m.i - m.a - m.e).squareRoot() * 2
            self.init(x: (m.g + m.c) / s, y: (m.h + m.f) / s, z: s / 4, w: (m.b - m.d) / s)
        }
        self = normalized
    }
}

// Vector helpers with names that cannot clash with simd's.
@inline(__always) func cDot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
@inline(__always) func cCross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
@inline(__always) func cLength(_ v: SIMD3<Float>) -> Float { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
@inline(__always) func cUnit(_ v: SIMD3<Float>, fallback: SIMD3<Float> = SIMD3(0, 1, 0)) -> SIMD3<Float> {
    let l = cLength(v)
    return l > 1e-9 && l.isFinite ? v / l : fallback
}
@inline(__always) func cFinite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
