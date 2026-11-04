import Foundation

// v1.76: keyframed animations as stored in model files (glTF / FBX):
// per joint translation, rotation (quaternion) and scale tracks. Joints
// without a track keep their base pose from the file. Evaluates to local
// joint transforms, so skeletons with rotated rest poses (imported rigs)
// animate exactly as authored.

struct KeyframeTrack: Codable, Equatable, Sendable {
    enum Path: String, Codable, Sendable { case translation, rotation, scale }
    var joint: Int
    var path: Path
    var times: [Float]
    /// 3 values per key (translation, scale) or 4 (rotation x, y, z, w).
    var values: [Float]
    var step = false
}

struct KeyframeClip: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var duration: Float
    var tracks: [KeyframeTrack]
    /// Base pose per joint (t xyz, r xyzw, s xyz); nil for joints that are
    /// not driven by the file (they keep their rest transform).
    var base: [[Float]?]
    /// Transform before the joint's own TRS (the file's non-joint parents).
    var pre: [Int: [Float]] = [:]

    /// Local transforms of every joint at time t (looping).
    func locals(_ skeleton: SkeletonDefinition, at time: Float) -> [RigXform] {
        let t = duration > 0 ? time.truncatingRemainder(dividingBy: duration) : 0
        var trs: [[Float]?] = base
        for track in tracks where track.joint < trs.count && trs[track.joint] != nil {
            let width = track.path == .rotation ? 4 : 3
            guard let v = Self.sample(track, at: t, width: width) else { continue }
            let o = track.path == .translation ? 0 : track.path == .rotation ? 3 : 7
            for k in 0..<width { trs[track.joint]![o + k] = v[k] }
        }
        return skeleton.joints.indices.map { j in
            guard j < trs.count, let p = trs[j] else { return skeleton.joints[j].rest }
            let local = Self.compose(p)
            if let m = pre[j], let x = RigXform(matrix: m) { return x * local }
            return local
        }
    }

    static func sample(_ track: KeyframeTrack, at t: Float, width: Int) -> [Float]? {
        let n = track.times.count
        guard n > 0, track.values.count >= n * width else { return nil }
        func key(_ i: Int) -> [Float] { Array(track.values[(i * width)..<(i * width + width)]) }
        if t <= track.times[0] || n == 1 { return key(0) }
        if t >= track.times[n - 1] { return key(n - 1) }
        var lo = 0, hi = n - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if track.times[mid] <= t { lo = mid } else { hi = mid } }
        if track.step { return key(lo) }
        let span = track.times[hi] - track.times[lo]
        let f = span > 0 ? (t - track.times[lo]) / span : 0
        let a = key(lo), b = key(hi)
        if width == 4 { return slerp(a, b, f) }
        return (0..<width).map { a[$0] + (b[$0] - a[$0]) * f }
    }

    static func slerp(_ a: [Float], _ bIn: [Float], _ t: Float) -> [Float] {
        var b = bIn
        var dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
        if dot < 0 { b = b.map { -$0 }; dot = -dot }
        var out: [Float]
        if dot > 0.9995 {
            out = (0..<4).map { a[$0] + (b[$0] - a[$0]) * t }
        } else {
            let theta = acos(min(1, dot)), s = sin(theta)
            let wa = sin((1 - t) * theta) / s, wb = sin(t * theta) / s
            out = (0..<4).map { a[$0] * wa + b[$0] * wb }
        }
        let l = (out.map { $0 * $0 }.reduce(0, +)).squareRoot()
        return l > 0 ? out.map { $0 / l } : [0, 0, 0, 1]
    }

    /// T · R · S from (t xyz, r xyzw, s xyz).
    static func compose(_ p: [Float]) -> RigXform {
        var x = GLBCodec.quaternion([p[3], p[4], p[5], p[6]])
        x.a *= p[7]; x.b *= p[7]; x.c *= p[7]
        x.d *= p[8]; x.e *= p[8]; x.f *= p[8]
        x.g *= p[9]; x.h *= p[9]; x.i *= p[9]
        x.tx = p[0]; x.ty = p[1]; x.tz = p[2]
        return x
    }

    /// (t, r, s) of an affine transform without shear.
    static func decompose(_ m: RigXform) -> [Float] {
        let sx = (m.a * m.a + m.b * m.b + m.c * m.c).squareRoot(), sy = (m.d * m.d + m.e * m.e + m.f * m.f).squareRoot()
        var sz = (m.g * m.g + m.h * m.h + m.i * m.i).squareRoot()
        if m.determinant < 0 { sz = -sz }
        let r00 = m.a / sx, r10 = m.b / sx, r20 = m.c / sx, r01 = m.d / sy, r11 = m.e / sy, r21 = m.f / sy, r02 = m.g / sz, r12 = m.h / sz, r22 = m.i / sz
        var q: [Float]
        let trace = r00 + r11 + r22
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = [(r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s, s / 4]
        } else if r00 > r11 && r00 > r22 {
            let s = (1 + r00 - r11 - r22).squareRoot() * 2
            q = [s / 4, (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s]
        } else if r11 > r22 {
            let s = (1 + r11 - r00 - r22).squareRoot() * 2
            q = [(r01 + r10) / s, s / 4, (r12 + r21) / s, (r02 - r20) / s]
        } else {
            let s = (1 + r22 - r00 - r11).squareRoot() * 2
            q = [(r02 + r20) / s, (r12 + r21) / s, s / 4, (r10 - r01) / s]
        }
        return [m.tx, m.ty, m.tz] + q + [sx, sy, sz]
    }
}

extension SkeletonDefinition {
    /// Same joints, new model-space origins; rotations and children's
    /// model-space placement are kept (works for rotated rest poses).
    func withWorldOrigins(_ origins: [SIMD3<Float>]) -> SkeletonDefinition {
        var world = worldRest
        for i in world.indices where i < origins.count { world[i].tx = origins[i].x; world[i].ty = origins[i].y; world[i].tz = origins[i].z }
        var s = self
        for i in s.joints.indices {
            let local = parentIndex(i).flatMap { world[$0].inverse }.map { $0 * world[i] } ?? world[i]
            s.joints[i].restTransform = local.matrix
        }
        s.refreshBindMatrices()
        return s
    }
}

/// Joint names from common rigs (Mixamo, Blender, Tripo and others) to the
/// standard humanoid tags, so imported characters get sockets and labels.
enum JointNames {
    static func tag(_ raw: String) -> JointTag {
        var n = raw.lowercased()
        for prefix in ["mixamorig:", "mixamorig_", "bip001 ", "bip01 ", "armature|", "def-", "def_", "j_bip_c_", "j_bip_l_", "j_bip_r_"] where n.hasPrefix(prefix) { n.removeFirst(prefix.count) }
        n = n.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ".", with: "")
        var side: String?
        if n.hasPrefix("left") { side = "left"; n.removeFirst(4) } else if n.hasPrefix("right") { side = "right"; n.removeFirst(5) }
        else if n.hasSuffix("l") && n.count > 3, raw.lowercased().contains(".l") || raw.lowercased().hasSuffix("_l") || raw.lowercased().hasSuffix(" l") { side = "left"; n.removeLast() }
        else if n.hasSuffix("r") && n.count > 3, raw.lowercased().contains(".r") || raw.lowercased().hasSuffix("_r") || raw.lowercased().hasSuffix(" r") { side = "right"; n.removeLast() }
        else if raw.lowercased().hasPrefix("l_") || raw.lowercased().hasPrefix("j_bip_l_") { side = "left" }
        else if raw.lowercased().hasPrefix("r_") || raw.lowercased().hasPrefix("j_bip_r_") { side = "right" }
        if let side {
            let limb: [(Set<String>, String)] = [
                (["shoulder", "clavicle", "collar"], "Clavicle"), (["arm", "upperarm", "uparm"], "UpperArm"), (["forearm", "lowerarm", "elbow"], "Forearm"),
                (["hand", "wrist"], "Hand"), (["upleg", "thigh", "upperleg", "hip"], "Thigh"), (["leg", "shin", "calf", "lowerleg", "knee"], "Shin"),
                (["foot", "ankle"], "Foot"), (["toebase", "toe", "ball"], "Toe"), (["toeend", "toetip"], "ToeEnd"), (["handend", "handtip"], "HandEnd"),
            ]
            for (names, suffix) in limb where names.contains(n) { return JointTag(rawValue: side + suffix) ?? .other }
            return .other
        }
        switch n {
        case "hips", "pelvis", "root", "hip": return .pelvis
        case "spine", "spine0": return .spine
        case "spine1", "spine01": return .spine1
        case "spine2", "chest", "upperchest", "spine02", "spine3": return .chest
        case "neck", "neck1": return .neck
        case "head": return .head
        case "headtopend", "headend", "headtop": return .headEnd
        default: return .other
        }
    }
}
