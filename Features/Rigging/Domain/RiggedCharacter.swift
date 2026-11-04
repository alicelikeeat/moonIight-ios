import Foundation

// v1.73 rigging data layer. Independent of SwiftUI and RealityKit so the
// engine (local or cloud) can change without touching the editor, and so
// the next skill editor can read skeleton, weights and sockets directly.
// Pure Swift, tested on Linux.

// MARK: Transform

/// Affine transform: 3×3 rotation/scale (column-major a…i) and translation.
/// Stored on disk as a column-major 4×4 matrix (16 floats).
struct RigXform: Equatable, Sendable {
    var a: Float = 1, b: Float = 0, c: Float = 0   // column 0
    var d: Float = 0, e: Float = 1, f: Float = 0   // column 1
    var g: Float = 0, h: Float = 0, i: Float = 1   // column 2
    var tx: Float = 0, ty: Float = 0, tz: Float = 0

    static let identity = RigXform()
    static func translation(_ x: Float, _ y: Float, _ z: Float) -> RigXform { var r = RigXform(); r.tx = x; r.ty = y; r.tz = z; return r }
    static func translation(_ p: SIMD3<Float>) -> RigXform { translation(p.x, p.y, p.z) }

    /// Rotation by `angle` radians about a unit axis.
    static func rotation(axis: SIMD3<Float>, angle: Float) -> RigXform {
        let l = (axis * axis).sum().squareRoot()
        guard l > 0, angle != 0 else { return identity }
        let x = axis.x / l, y = axis.y / l, z = axis.z / l, cs = cos(angle), sn = sin(angle), t = 1 - cs
        var r = RigXform()
        r.a = t * x * x + cs; r.b = t * x * y + sn * z; r.c = t * x * z - sn * y
        r.d = t * x * y - sn * z; r.e = t * y * y + cs; r.f = t * y * z + sn * x
        r.g = t * x * z + sn * y; r.h = t * y * z - sn * x; r.i = t * z * z + cs
        return r
    }
    /// X then Y then Z rotations (radians) about the joint origin.
    static func euler(_ v: SIMD3<Float>) -> RigXform {
        rotation(axis: [0, 0, 1], angle: v.z) * rotation(axis: [0, 1, 0], angle: v.y) * rotation(axis: [1, 0, 0], angle: v.x)
    }

    static func * (l: RigXform, r: RigXform) -> RigXform {
        var o = RigXform()
        o.a = l.a * r.a + l.d * r.b + l.g * r.c; o.b = l.b * r.a + l.e * r.b + l.h * r.c; o.c = l.c * r.a + l.f * r.b + l.i * r.c
        o.d = l.a * r.d + l.d * r.e + l.g * r.f; o.e = l.b * r.d + l.e * r.e + l.h * r.f; o.f = l.c * r.d + l.f * r.e + l.i * r.f
        o.g = l.a * r.g + l.d * r.h + l.g * r.i; o.h = l.b * r.g + l.e * r.h + l.h * r.i; o.i = l.c * r.g + l.f * r.h + l.i * r.i
        let t = l.point(SIMD3(r.tx, r.ty, r.tz))
        o.tx = t.x; o.ty = t.y; o.tz = t.z
        return o
    }
    func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a * p.x + d * p.y + g * p.z + tx, b * p.x + e * p.y + h * p.z + ty, c * p.x + f * p.y + i * p.z + tz)
    }
    func direction(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a * v.x + d * v.y + g * v.z, b * v.x + e * v.y + h * v.z, c * v.x + f * v.y + i * v.z)
    }
    var origin: SIMD3<Float> { SIMD3(tx, ty, tz) }
    var determinant: Float { a * (e * i - h * f) - d * (b * i - h * c) + g * (b * f - e * c) }
    var finite: Bool { matrix.allSatisfy(\.isFinite) }

    /// Inverse (nil when singular).
    var inverse: RigXform? {
        let det = determinant
        guard abs(det) > 1e-30, det.isFinite else { return nil }
        var r = RigXform()
        r.a = (e * i - h * f) / det; r.b = (h * c - b * i) / det; r.c = (b * f - e * c) / det
        r.d = (g * f - d * i) / det; r.e = (a * i - g * c) / det; r.f = (d * c - a * f) / det
        r.g = (d * h - g * e) / det; r.h = (g * b - a * h) / det; r.i = (a * e - d * b) / det
        let t = r.direction(SIMD3(tx, ty, tz))
        r.tx = -t.x; r.ty = -t.y; r.tz = -t.z
        return r
    }

    /// Column-major 4×4.
    var matrix: [Float] { [a, b, c, 0, d, e, f, 0, g, h, i, 0, tx, ty, tz, 1] }
    init() {}
    init?(matrix m: [Float]) {
        guard m.count == 16, m.allSatisfy(\.isFinite) else { return nil }
        a = m[0]; b = m[1]; c = m[2]; d = m[4]; e = m[5]; f = m[6]; g = m[8]; h = m[9]; i = m[10]; tx = m[12]; ty = m[13]; tz = m[14]
    }
}

// MARK: Skeleton

/// Semantic names for the standard humanoid (27 joints). "right" is the
/// character's right, which is the viewer's left (−x).
enum JointTag: String, Codable, CaseIterable, Sendable {
    case pelvis, spine, spine1, chest, neck, head, headEnd
    case rightClavicle, rightUpperArm, rightForearm, rightHand, rightHandEnd
    case leftClavicle, leftUpperArm, leftForearm, leftHand, leftHandEnd
    case rightThigh, rightShin, rightFoot, rightToe, rightToeEnd
    case leftThigh, leftShin, leftFoot, leftToe, leftToeEnd
    case other

    /// Unknown names (e.g. from a cloud engine) read as `.other`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JointTag(rawValue: raw) ?? .other
    }

    var title: String {
        switch self {
        case .pelvis: L10n.t("骨盆", "Pelvis"); case .spine: L10n.t("腰椎", "Spine"); case .spine1: L10n.t("胸椎", "Spine 1")
        case .chest: L10n.t("胸部", "Chest"); case .neck: L10n.t("颈部", "Neck"); case .head: L10n.t("头部", "Head"); case .headEnd: L10n.t("头顶", "Head Top")
        case .rightClavicle: L10n.t("右锁骨", "R Clavicle"); case .rightUpperArm: L10n.t("右肩", "R Shoulder"); case .rightForearm: L10n.t("右肘", "R Elbow")
        case .rightHand: L10n.t("右手腕", "R Wrist"); case .rightHandEnd: L10n.t("右手尖", "R Hand Tip")
        case .leftClavicle: L10n.t("左锁骨", "L Clavicle"); case .leftUpperArm: L10n.t("左肩", "L Shoulder"); case .leftForearm: L10n.t("左肘", "L Elbow")
        case .leftHand: L10n.t("左手腕", "L Wrist"); case .leftHandEnd: L10n.t("左手尖", "L Hand Tip")
        case .rightThigh: L10n.t("右髋", "R Hip"); case .rightShin: L10n.t("右膝", "R Knee"); case .rightFoot: L10n.t("右脚踝", "R Ankle")
        case .rightToe: L10n.t("右脚掌", "R Ball"); case .rightToeEnd: L10n.t("右脚尖", "R Toe Tip")
        case .leftThigh: L10n.t("左髋", "L Hip"); case .leftShin: L10n.t("左膝", "L Knee"); case .leftFoot: L10n.t("左脚踝", "L Ankle")
        case .leftToe: L10n.t("左脚掌", "L Ball"); case .leftToeEnd: L10n.t("左脚尖", "L Toe Tip")
        case .other: L10n.t("其他", "Other")
        }
    }
    /// The same joint on the other side (nil for the centre line).
    var mirror: JointTag? {
        let name = rawValue
        if name.hasPrefix("right") { return JointTag(rawValue: "left" + name.dropFirst(5)) }
        if name.hasPrefix("left") { return JointTag(rawValue: "right" + name.dropFirst(4)) }
        return nil
    }
    /// End joints only mark where a bone ends; they carry no weights.
    var isEnd: Bool { [.headEnd, .rightHandEnd, .leftHandEnd, .rightToeEnd, .leftToeEnd].contains(self) }
    /// Body region for colours and diagnostics: 0 head, 1 torso, 2 arms, 3 legs.
    var region: Int {
        switch self {
        case .neck, .head, .headEnd: 0
        case .pelvis, .spine, .spine1, .chest, .rightClavicle, .leftClavicle, .other: 1
        case .rightUpperArm, .rightForearm, .rightHand, .rightHandEnd, .leftUpperArm, .leftForearm, .leftHand, .leftHandEnd: 2
        default: 3
        }
    }
}

/// Allowed rotation per axis, degrees, relative to the bind pose.
struct JointLimit: Codable, Equatable, Sendable {
    var min: [Float]
    var max: [Float]
    static let free = JointLimit(min: [-180, -180, -180], max: [180, 180, 180])
    func contains(_ degrees: SIMD3<Float>, slack: Float = 0) -> Bool {
        (0..<3).allSatisfy { degrees[$0] >= min[$0] - slack && degrees[$0] <= max[$0] + slack }
    }
}

struct RigJoint: Codable, Equatable, Identifiable, Sendable {
    var jointID: String
    var parentID: String?
    /// Bind pose relative to the parent, column-major 4×4.
    var restTransform: [Float]
    /// Inverse of the bind pose in model space, column-major 4×4.
    var inverseBindMatrix: [Float]
    var jointLimit: JointLimit
    var semanticTag: JointTag
    /// 0…1: how sure the estimator was about this joint's position.
    var confidence: Float
    var id: String { jointID }

    var rest: RigXform { RigXform(matrix: restTransform) ?? .identity }
}

enum SkeletonError: Error, Equatable {
    case empty, duplicateID(String), missingParent(String), cycle(String), roots(Int), badMatrix(String), inverseMismatch(String), asymmetric(String), misplaced(String)
}

struct SkeletonDefinition: Codable, Equatable, Sendable {
    /// Parents always come before children.
    var joints: [RigJoint]

    func index(_ id: String) -> Int? { joints.firstIndex { $0.jointID == id } }
    func index(_ tag: JointTag) -> Int? { joints.firstIndex { $0.semanticTag == tag } }
    func parentIndex(_ i: Int) -> Int? { joints[i].parentID.flatMap(index) }
    func children(_ i: Int) -> [Int] { joints.indices.filter { joints[$0].parentID == joints[i].jointID } }

    /// Model-space bind transform of every joint.
    var worldRest: [RigXform] { worldTransforms(local: joints.map(\.rest)) }
    func worldTransforms(local: [RigXform]) -> [RigXform] {
        var world = local
        for i in joints.indices { if let p = parentIndex(i), p < i { world[i] = world[p] * local[i] } }
        return world
    }
    func position(_ tag: JointTag) -> SIMD3<Float>? { index(tag).map { worldRest[$0].origin } }

    /// Recomputes inverse bind matrices from the rest transforms.
    mutating func refreshBindMatrices() {
        let world = worldRest
        for i in joints.indices { joints[i].inverseBindMatrix = (world[i].inverse ?? .identity).matrix }
    }

    /// Hierarchy without cycles, one root, valid matrices that agree with
    /// the inverse binds, and (for humanoids) sensible left / right sides.
    func validate(humanoid: Bool = true) throws {
        guard !joints.isEmpty else { throw SkeletonError.empty }
        var ids = Set<String>()
        for j in joints { guard ids.insert(j.jointID).inserted else { throw SkeletonError.duplicateID(j.jointID) } }
        let roots = joints.filter { $0.parentID == nil }.count
        guard roots == 1 else { throw SkeletonError.roots(roots) }
        for j in joints { if let p = j.parentID, !ids.contains(p) { throw SkeletonError.missingParent(j.jointID) } }
        // Cycle check: walking up from every joint must reach the root.
        let parent = Dictionary(uniqueKeysWithValues: joints.map { ($0.jointID, $0.parentID) })
        for j in joints {
            var seen = Set<String>(), cursor: String? = j.jointID
            while let c = cursor { guard seen.insert(c).inserted else { throw SkeletonError.cycle(j.jointID) }; cursor = parent[c] ?? nil }
        }
        for (i, j) in joints.enumerated() {
            if let p = parentIndex(i), p >= i { throw SkeletonError.cycle(j.jointID) }
            guard let rest = RigXform(matrix: j.restTransform), abs(rest.determinant) > 1e-30, RigXform(matrix: j.inverseBindMatrix) != nil else { throw SkeletonError.badMatrix(j.jointID) }
        }
        let world = worldRest
        for (i, j) in joints.enumerated() {
            let inv = RigXform(matrix: j.inverseBindMatrix)!
            let check = world[i] * inv
            let off = abs(check.a - 1) + abs(check.e - 1) + abs(check.i - 1) + abs(check.tx) + abs(check.ty) + abs(check.tz)
            if off > 1e-3 { throw SkeletonError.inverseMismatch(j.jointID) }
        }
        guard humanoid else { return }
        // Character's right side sits at −x, left at +x; mirrored joints at
        // a similar height.
        let height = max(0.01, (world.map(\.origin.y).max() ?? 1) - (world.map(\.origin.y).min() ?? 0))
        for (i, j) in joints.enumerated() {
            guard let m = j.semanticTag.mirror, let k = index(m) else { continue }
            let p = world[i].origin, q = world[k].origin
            if j.semanticTag.rawValue.hasPrefix("right") && !j.semanticTag.rawValue.hasSuffix("Clavicle") && p.x >= q.x { throw SkeletonError.asymmetric(j.jointID) }
            if abs(p.y - q.y) > height * 0.15 { throw SkeletonError.asymmetric(j.jointID) }
        }
        // Expected order from top to bottom.
        if let head = position(.head), let pelvis = position(.pelvis), let foot = position(.rightFoot) {
            if !(head.y > pelvis.y && pelvis.y > foot.y) { throw SkeletonError.misplaced("vertical order") }
        }
    }
}

// MARK: Skin

/// Up to four joint influences per vertex; weights non-negative, sum 1.
struct SkinInfluences: Equatable, Sendable {
    static let maxInfluences = 4
    /// 4 entries per vertex (joint index; 255 = unused).
    var joints: [UInt8]
    var weights: [Float]
    var count: Int { joints.count / 4 }

    init(count: Int) { joints = [UInt8](repeating: 255, count: count * 4); weights = [Float](repeating: 0, count: count * 4) }
    init(joints: [UInt8], weights: [Float]) { self.joints = joints; self.weights = weights }

    func influences(_ v: Int) -> [(joint: Int, weight: Float)] {
        var out: [(joint: Int, weight: Float)] = []
        for k in 0..<4 {
            let j: UInt8 = joints[v * 4 + k]
            if j != 255 { out.append((joint: Int(j), weight: weights[v * 4 + k])) }
        }
        return out
    }
    /// Main joint of a vertex.
    func dominant(_ v: Int) -> Int? { influences(v).max { $0.weight < $1.weight }?.joint }

    /// Weights legal for `jointCount` joints: ≤4, ≥0, sum ≈ 1, valid indices.
    func valid(jointCount: Int, vertexCount: Int) -> Bool {
        guard joints.count == vertexCount * 4, weights.count == vertexCount * 4 else { return false }
        for v in 0..<vertexCount {
            var sum: Float = 0, any = false
            for k in 0..<4 {
                let j = joints[v * 4 + k], w = weights[v * 4 + k]
                guard w.isFinite, w >= 0 else { return false }
                if j == 255 { guard w == 0 else { return false }; continue }
                guard Int(j) < jointCount else { return false }
                sum += w; any = true
            }
            guard any, abs(sum - 1) < 1e-3 else { return false }
        }
        return true
    }

    // Binary file: "MLSK", version, vertex count, then indices and weights.
    static let magic: [UInt8] = Array("MLSK".utf8)
    func encoded() -> Data {
        var data = Data(Self.magic)
        var version = UInt32(1).littleEndian, n = UInt32(count).littleEndian
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
        data.append(contentsOf: joints)
        for w in weights { var bits = w.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) } }
        return data
    }
    static func decode(_ data: Data) -> SkinInfluences? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[0..<4]) == magic else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24 }
        guard u32(4) == 1 else { return nil }
        let n = Int(u32(8))
        guard bytes.count == 12 + n * 4 + n * 16 else { return nil }
        let joints = Array(bytes[12..<(12 + n * 4)])
        var weights = [Float](repeating: 0, count: n * 4)
        for k in 0..<(n * 4) { weights[k] = Float(bitPattern: u32(12 + n * 4 + k * 4)) }
        return SkinInfluences(joints: joints, weights: weights)
    }
}

// MARK: Sockets, diagnostics, character

/// Attachment points for weapons, shields and effects (for the skill editor).
struct AttachmentSocket: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case rightHandWeapon, leftHandShield, back, rightFoot, leftFoot, head }
    var id: String { kind.rawValue }
    var kind: Kind
    var jointID: String
    /// Offset in the joint's frame (model units).
    var offset: [Float]
    var title: String {
        switch kind {
        case .rightHandWeapon: L10n.t("右手武器", "Right-hand weapon"); case .leftHandShield: L10n.t("左手盾牌", "Left-hand shield")
        case .back: L10n.t("背部装饰", "Back"); case .rightFoot: L10n.t("右脚底特效", "Right foot effect")
        case .leftFoot: L10n.t("左脚底特效", "Left foot effect"); case .head: L10n.t("头部特效", "Head effect")
        }
    }
}

enum DiagnosticStatus: String, Codable, Sendable, Comparable {
    case pass, warning, fail
    static func < (a: DiagnosticStatus, b: DiagnosticStatus) -> Bool { a.rank < b.rank }
    private var rank: Int { switch self { case .pass: 0; case .warning: 1; case .fail: 2 } }
}

struct DiagnosticResult: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var status: DiagnosticStatus
    /// Numbers behind the verdict (for the report and the UI).
    var metrics: [String: Float]
    var notes: [String]
}

struct RiggingDiagnostics: Codable, Equatable, Sendable {
    var results: [DiagnosticResult] = []
    /// Automatic repairs applied (what and how much they helped).
    var repairs: [String] = []
    var overall: DiagnosticStatus { results.map(\.status).max() ?? .pass }
}

struct RiggedCharacterMetadata: Codable, Equatable, Sendable {
    var engine: String
    var engineVersion: String
    /// "local" or "cloud".
    var route: String
    var createdAt: Date
    var poseType: String
    var notes: [String] = []
}

/// One rigged character: what the world, the editor and the next skill
/// editor read. The source mesh is never overwritten; an optimised copy is
/// stored only when the original was too dense.
struct RiggedCharacter: Codable, Equatable, Sendable {
    static let formatVersion = 1
    var formatVersion: Int = RiggedCharacter.formatVersion
    var modelID: String
    /// Mesh file the weights belong to (the original or an optimised copy).
    var meshFile: String
    var optimizedMeshFile: String?
    var skinFile: String
    var vertexCount: Int
    var skeleton: SkeletonDefinition
    var clips: [MotionClip]
    var sockets: [AttachmentSocket]
    var diagnostics: RiggingDiagnostics
    var metadata: RiggedCharacterMetadata

    enum LoadError: Error, Equatable { case newerFormat(Int), unreadable }

    /// Reads a saved character; refuses files from a newer format instead
    /// of guessing (an older app leaves them untouched).
    static func decode(_ data: Data) throws -> RiggedCharacter {
        struct Header: Decodable { var formatVersion: Int }
        guard let header = try? JSONDecoder.rig.decode(Header.self, from: data) else { throw LoadError.unreadable }
        guard header.formatVersion <= formatVersion else { throw LoadError.newerFormat(header.formatVersion) }
        guard let value = try? JSONDecoder.rig.decode(RiggedCharacter.self, from: data) else { throw LoadError.unreadable }
        return value
    }
    func encoded() throws -> Data { try JSONEncoder.rig.encode(self) }
}

extension JSONEncoder {
    static var rig: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
extension JSONDecoder {
    static var rig: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
