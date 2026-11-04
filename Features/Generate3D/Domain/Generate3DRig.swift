import Foundation

// P2 (experimental) automatic rig for humanoid depth models: 2D body joints
// from the source picture → 3D skeleton inside the mesh → skin weights →
// procedural clips (idle, walk, run, wave) → linear blend skinning, plus a
// validator that actually deforms the mesh and checks the result. Pure
// Swift (tested on Linux). A rig is only offered when the validator passes,
// and stays labelled experimental until verified on a real device.

// MARK: Math

/// Column-major 4×4 matrix (just what skinning needs).
struct Mat4: Equatable, Sendable {
    var m: [Float]
    static let identity = Mat4(m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    static func translation(_ t: [Float]) -> Mat4 { var r = identity; r.m[12] = t[0]; r.m[13] = t[1]; r.m[14] = t[2]; return r }
    /// Rotation by `angle` radians about a unit axis (Rodrigues).
    static func rotation(axis a: [Float], angle: Float) -> Mat4 {
        let l = (a[0] * a[0] + a[1] * a[1] + a[2] * a[2]).squareRoot()
        guard l > 0 else { return identity }
        let x = a[0] / l, y = a[1] / l, z = a[2] / l, c = cos(angle), s = sin(angle), t = 1 - c
        return Mat4(m: [t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0,
                        t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0,
                        t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0,
                        0, 0, 0, 1])
    }
    static func * (a: Mat4, b: Mat4) -> Mat4 {
        var r = [Float](repeating: 0, count: 16)
        for col in 0..<4 { for row in 0..<4 {
            var sum: Float = 0
            for k in 0..<4 { sum += a.m[k * 4 + row] * b.m[col * 4 + k] }
            r[col * 4 + row] = sum
        } }
        return Mat4(m: r)
    }
    func point(_ p: [Float]) -> [Float] {
        [m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12], m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13], m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14]]
    }
    func direction(_ d: [Float]) -> [Float] {
        [m[0] * d[0] + m[4] * d[1] + m[8] * d[2], m[1] * d[0] + m[5] * d[1] + m[9] * d[2], m[2] * d[0] + m[6] * d[1] + m[10] * d[2]]
    }
    /// Rotation `r` about the point `pivot`.
    static func rotation(about pivot: [Float], _ r: Mat4) -> Mat4 { translation(pivot) * r * translation(pivot.map { -$0 }) }
}

// MARK: Skeleton

/// Body joints as Vision names them, in picture coordinates (u right,
/// v down, 0…1) with confidence.
struct BodyJoints2D: Codable, Equatable, Sendable {
    struct Point: Codable, Equatable, Sendable { var u: Double; var v: Double; var confidence: Double }
    var points: [String: Point]

    func point(_ name: String, minimum: Double = 0.3) -> Point? { points[name].flatMap { $0.confidence >= minimum ? $0 : nil } }
}

/// Ten bones; the torso is the root.
enum RigBone: Int, CaseIterable, Codable, Sendable {
    case torso, head, rightUpperArm, rightForearm, leftUpperArm, leftForearm, rightThigh, rightShin, leftThigh, leftShin

    var parent: RigBone? {
        switch self {
        case .torso: nil
        case .head, .rightUpperArm, .leftUpperArm, .rightThigh, .leftThigh: .torso
        case .rightForearm: .rightUpperArm
        case .leftForearm: .leftUpperArm
        case .rightShin: .rightThigh
        case .leftShin: .leftThigh
        }
    }
    /// Body region for region colours: 0 head, 1 torso, 2 arms, 3 legs.
    var region: Int {
        switch self {
        case .head: 0
        case .torso: 1
        case .rightUpperArm, .rightForearm, .leftUpperArm, .leftForearm: 2
        case .rightThigh, .rightShin, .leftThigh, .leftShin: 3
        }
    }
}

struct RigSkeleton: Codable, Equatable, Sendable {
    struct Bone: Codable, Equatable, Sendable {
        var bone: RigBone
        /// Rotation pivot (the joint) and the far end, model space.
        var head: [Float]
        var tail: [Float]
    }
    var bones: [Bone]
    func bone(_ b: RigBone) -> Bone? { bones.first { $0.bone == b } }
}

/// Per vertex: up to two bones and the first bone's weight (second = 1 − w).
struct SkinWeights: Equatable, Sendable {
    var bone0: [UInt8]
    var bone1: [UInt8]
    var weight0: [Float]

    var count: Int { weight0.count }
    var valid: Bool { bone0.count == count && bone1.count == count && weight0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } }

    /// Binary: "SKN1", count, then bone0, bone1, weight0.
    func encoded() -> Data {
        var data = Data("SKN1".utf8)
        withUnsafeBytes(of: UInt32(count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: bone0); data.append(contentsOf: bone1)
        for w in weight0 { withUnsafeBytes(of: w.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }
    static func decode(_ data: Data) -> SkinWeights? {
        let b = [UInt8](data)
        guard b.count >= 8, Array(b[0..<4]) == Array("SKN1".utf8) else { return nil }
        let n = Int(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)
        guard n < 50_000_000, b.count == 8 + n * 6 else { return nil }
        let bone0 = Array(b[8..<(8 + n)]), bone1 = Array(b[(8 + n)..<(8 + 2 * n)])
        let base = 8 + 2 * n
        let weights = (0..<n).map { i -> Float in
            let o = base + i * 4
            return Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        let skin = SkinWeights(bone0: bone0, bone1: bone1, weight0: weights)
        return skin.valid ? skin : nil
    }
}

enum AutoRig {
    enum Failure: Error, Equatable {
        /// Neck, both shoulders and both hips are needed.
        case notHumanoid
        case mappingFailed
        case emptyMesh
    }

    /// Picture (u, v) → model (x, y) is linear for depth reliefs (every
    /// vertex keeps its picture coordinate); fitted by least squares.
    static func uvToXY(_ mesh: GeneratedMesh) -> (ax: Float, bx: Float, ay: Float, by: Float)? {
        func fit(_ input: (Int) -> Float, _ output: (Int) -> Float) -> (Float, Float)? {
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, n = 0.0
            // Front surface only (z > 0): back vertices may use another part
            // of the texture (v1.69 back atlas).
            let sample = Array(stride(from: 0, to: mesh.vertexCount, by: max(1, mesh.vertexCount / 4000)))
            let front = sample.filter { mesh.positions[$0 * 3 + 2] > 0 }
            for i in front.count >= 8 ? front : sample {
                let x = Double(input(i)), y = Double(output(i))
                sx += x; sy += y; sxx += x * x; sxy += x * y; n += 1
            }
            let d = n * sxx - sx * sx
            guard n >= 2, abs(d) > 1e-12 else { return nil }
            let a = (n * sxy - sx * sy) / d
            return (Float(a), Float((sy - a * sx) / n))
        }
        // uv's v is 1 at the top of the picture; joints use v = 0 at the top.
        guard let x = fit({ mesh.uvs[$0 * 2] }, { mesh.positions[$0 * 3] }),
              let y = fit({ 1 - mesh.uvs[$0 * 2 + 1] }, { mesh.positions[$0 * 3 + 1] }) else { return nil }
        return (x.0, x.1, y.0, y.1)
    }

    /// Joint depth: midway between the front surface and the back near (x, y).
    static func depth(at x: Float, _ y: Float, in mesh: GeneratedMesh, radius: Float) -> Float? {
        var front = -Float.infinity, back = Float.infinity
        for i in 0..<mesh.vertexCount {
            let dx = mesh.positions[i * 3] - x, dy = mesh.positions[i * 3 + 1] - y
            guard dx * dx + dy * dy <= radius * radius else { continue }
            let z = mesh.positions[i * 3 + 2]
            front = max(front, z); back = min(back, z)
        }
        return front.isFinite && back.isFinite ? (front + back) / 2 : nil
    }

    static func skeleton(for mesh: GeneratedMesh, joints: BodyJoints2D) throws -> RigSkeleton {
        guard mesh.vertexCount > 0 else { throw Failure.emptyMesh }
        guard let neck2 = joints.point("neck_1_joint") ?? joints.point("neck"), let rs = joints.point("right_shoulder_1_joint"), let ls = joints.point("left_shoulder_1_joint"),
              let rh = joints.point("right_upLeg_joint"), let lh = joints.point("left_upLeg_joint") else { throw Failure.notHumanoid }
        guard let map = uvToXY(mesh) else { throw Failure.mappingFailed }
        let b = mesh.bounds
        let radius = max(0.02, (b.max[1] - b.min[1]) * 0.04)
        func place(_ p: BodyJoints2D.Point) -> [Float] {
            let x = map.ax * Float(p.u) + map.bx, y = map.ay * Float(p.v) + map.by
            return [x, y, depth(at: x, y, in: mesh, radius: radius) ?? (b.min[2] + b.max[2]) / 2]
        }
        func mid(_ a: [Float], _ c: [Float]) -> [Float] { [(a[0] + c[0]) / 2, (a[1] + c[1]) / 2, (a[2] + c[2]) / 2] }
        func extend(_ from: [Float], _ to: [Float], _ k: Float) -> [Float] { (0..<3).map { to[$0] + (to[$0] - from[$0]) * k } }

        let neck = place(neck2), rShoulder = place(rs), lShoulder = place(ls), rHip = place(rh), lHip = place(lh)
        let hips = joints.point("root").map(place) ?? mid(rHip, lHip)
        var bones = [RigSkeleton.Bone(bone: .torso, head: hips, tail: neck)]
        let headTop: [Float] = joints.point("head_joint").map { extend(neck, place($0), 0.6) }
            ?? [neck[0], neck[1] + (neck[1] - hips[1]) * 0.45, neck[2]]
        bones.append(.init(bone: .head, head: neck, tail: headTop))
        func limb(_ upper: RigBone, _ lower: RigBone, root: [Float], mid midName: String, end endName: String) {
            guard let m = joints.point(midName).map(place) else { return }
            bones.append(.init(bone: upper, head: root, tail: m))
            if let e = joints.point(endName).map(place) { bones.append(.init(bone: lower, head: m, tail: extend(m, e, 0.25))) }
        }
        limb(.rightUpperArm, .rightForearm, root: rShoulder, mid: "right_forearm_joint", end: "right_hand_joint")
        limb(.leftUpperArm, .leftForearm, root: lShoulder, mid: "left_forearm_joint", end: "left_hand_joint")
        limb(.rightThigh, .rightShin, root: rHip, mid: "right_leg_joint", end: "right_foot_joint")
        limb(.leftThigh, .leftShin, root: lHip, mid: "left_leg_joint", end: "left_foot_joint")
        return RigSkeleton(bones: bones)
    }

    static func distance(_ p: [Float], toSegment a: [Float], _ c: [Float], depthWeight: Float = 0.5) -> Float {
        let ab = (0..<3).map { c[$0] - a[$0] }, ap = (0..<3).map { p[$0] - a[$0] }
        let len2 = ab.reduce(0) { $0 + $1 * $1 }
        let t = len2 > 0 ? max(0, min(1, zip(ab, ap).reduce(0) { $0 + $1.0 * $1.1 } / len2)) : 0
        let q = (0..<3).map { a[$0] + ab[$0] * t }
        // Depth matters less in a relief: weigh z at half.
        let dx = p[0] - q[0], dy = p[1] - q[1], dz = (p[2] - q[2]) * depthWeight
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    /// Skin weights from distance measured along the mesh surface
    /// (geodesic): each bone spreads from the vertices on its own centre
    /// line, so an arm hanging beside the body does not pull the torso. Then
    /// smoothed over neighbours, reduced to the two strongest bones.
    static func weights(for mesh: GeneratedMesh, skeleton: RigSkeleton, smoothing: Int = 6) -> SkinWeights {
        let n = mesh.vertexCount, bones = skeleton.bones.count
        guard n > 0, bones > 0 else { return SkinWeights(bone0: [], bone1: [], weight0: []) }
        func point(_ i: Int) -> [Float] { [mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2]] }
        // Neighbours with surface edge lengths (depth weighed at half).
        var neighbours = [[(Int32, Float)]](repeating: [], count: n)
        for t in 0..<mesh.triangleCount {
            let tri = [Int(mesh.indices[t * 3]), Int(mesh.indices[t * 3 + 1]), Int(mesh.indices[t * 3 + 2])]
            for (a, b) in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])] {
                let dx = mesh.positions[a * 3] - mesh.positions[b * 3], dy = mesh.positions[a * 3 + 1] - mesh.positions[b * 3 + 1]
                let dz = (mesh.positions[a * 3 + 2] - mesh.positions[b * 3 + 2]) * 0.5
                let l = (dx * dx + dy * dy + dz * dz).squareRoot()
                neighbours[a].append((Int32(b), l)); neighbours[b].append((Int32(a), l))
            }
        }
        let height = max(0.01, mesh.bounds.max[1] - mesh.bounds.min[1])
        let seedRadius = height * 0.03
        var geo = [Float](repeating: .infinity, count: n * bones)
        for (b, bone) in skeleton.bones.enumerated() {
            var distance = [Float](repeating: .infinity, count: n)
            var heap = MinHeap()
            var nearest = (Float.infinity, -1)
            for i in 0..<n {
                // Seeds by picture-plane distance: in a relief the bone's
                // depth is only an estimate.
                let d = AutoRig.distance(point(i), toSegment: bone.head, bone.tail, depthWeight: 0)
                if d < nearest.0 { nearest = (d, i) }
                if d <= seedRadius { distance[i] = d; heap.push(d, Int32(i)) }
            }
            if heap.isEmpty, nearest.1 >= 0 { distance[nearest.1] = nearest.0; heap.push(nearest.0, Int32(nearest.1)) }
            while let (d, v) = heap.pop() {
                let i = Int(v)
                guard d <= distance[i] else { continue }
                for (j, l) in neighbours[i] where d + l < distance[Int(j)] { distance[Int(j)] = d + l; heap.push(d + l, j) }
            }
            for i in 0..<n { geo[i * bones + b] = distance[i] }
        }
        // Unreached parts (separate pieces) fall back to straight distance.
        var w = [Float](repeating: 0, count: n * bones)
        for i in 0..<n {
            let reached = (0..<bones).contains { geo[i * bones + $0].isFinite }
            var sum: Float = 0
            for (b, bone) in skeleton.bones.enumerated() {
                let d = reached ? geo[i * bones + b] : AutoRig.distance(point(i), toSegment: bone.head, bone.tail)
                let v: Float = d.isFinite ? 1 / pow(d + 0.01, 4) : 0
                w[i * bones + b] = v; sum += v
            }
            if sum > 0 { for b in 0..<bones { w[i * bones + b] /= sum } }
        }
        for _ in 0..<max(0, smoothing) {
            var next = w
            for i in 0..<n where !neighbours[i].isEmpty {
                let k = 0.5 / Float(neighbours[i].count)
                for b in 0..<bones {
                    var s: Float = 0
                    for (j, _) in neighbours[i] { s += w[Int(j) * bones + b] }
                    next[i * bones + b] = w[i * bones + b] * 0.5 + s * k
                }
            }
            w = next
        }
        var b0 = [UInt8](repeating: 0, count: n), b1 = b0, w0 = [Float](repeating: 1, count: n)
        for i in 0..<n {
            var first = 0
            for b in 1..<bones where w[i * bones + b] > w[i * bones + first] { first = b }
            var second = -1
            for b in 0..<bones where b != first && (second < 0 || w[i * bones + b] > w[i * bones + second]) { second = b }
            let a = w[i * bones + first], c = second >= 0 ? w[i * bones + second] : 0
            b0[i] = UInt8(skeleton.bones[first].bone.rawValue)
            b1[i] = UInt8(skeleton.bones[second >= 0 ? second : first].bone.rawValue)
            w0[i] = a + c > 0 ? a / (a + c) : 1
        }
        return SkinWeights(bone0: b0, bone1: b1, weight0: w0)
    }
}

/// Binary min-heap of (distance, vertex) for the geodesic search.
struct MinHeap {
    private var items: [(Float, Int32)] = []
    var isEmpty: Bool { items.isEmpty }
    mutating func push(_ key: Float, _ value: Int32) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 { let p = (i - 1) / 2; if items[p].0 <= items[i].0 { break }; items.swapAt(p, i); i = p }
    }
    mutating func pop() -> (Float, Int32)? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = i * 2 + 1, r = l + 1
                var m = i
                if l < items.count && items[l].0 < items[m].0 { m = l }
                if r < items.count && items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(i, m); i = m
            }
        }
        return top
    }
}

// MARK: Animation

/// A procedural clip: each channel turns one bone about an axis with a
/// sine wave. Saved as JSON (Animations/).
struct RigClip: Codable, Equatable, Identifiable, Sendable {
    struct Channel: Codable, Equatable, Sendable {
        var bone: RigBone
        var axis: [Float]
        /// Radians.
        var amplitude: Float
        var phase: Float = 0
        var bias: Float = 0
        /// Cycles per clip period (2 = twice as fast).
        var frequency: Float = 1
    }
    var id: String
    var name: String
    var period: Float
    var channels: [Channel]

    /// Which standard clip plays for a character action in the world.
    static func id(for action: CharacterAction) -> String {
        switch action {
        case .walk: "walk"
        case .run, .jump, .dodge: "run"
        case .attack, .skill, .transform, .interact: "wave"
        case .idle, .fall, .hurt, .death: "idle"
        }
    }

    func angle(_ c: Channel, at t: Float) -> Float { c.bias + c.amplitude * sin(2 * .pi * c.frequency * t / max(0.01, period) + c.phase) }

    /// Idle, walk, run and wave for the ten-bone skeleton. x axis swings
    /// limbs forward / back (towards the viewer), z raises sideways.
    static let standard: [RigClip] = {
        let x: [Float] = [1, 0, 0], z: [Float] = [0, 0, 1]
        let deg: Float = .pi / 180
        return [
            RigClip(id: "idle", name: L10n.t("待机", "Idle"), period: 3, channels: [
                .init(bone: .torso, axis: z, amplitude: 1.5 * deg),
                .init(bone: .head, axis: z, amplitude: 3 * deg, phase: 0.8),
                .init(bone: .rightUpperArm, axis: z, amplitude: 3 * deg, phase: 0.4),
                .init(bone: .leftUpperArm, axis: z, amplitude: 3 * deg, phase: 0.4 + .pi),
            ]),
            RigClip(id: "walk", name: L10n.t("行走", "Walk"), period: 1.1, channels: [
                .init(bone: .rightThigh, axis: x, amplitude: 24 * deg), .init(bone: .leftThigh, axis: x, amplitude: 24 * deg, phase: .pi),
                .init(bone: .rightShin, axis: x, amplitude: 14 * deg, phase: -1.2, bias: -14 * deg), .init(bone: .leftShin, axis: x, amplitude: 14 * deg, phase: .pi - 1.2, bias: -14 * deg),
                .init(bone: .rightUpperArm, axis: x, amplitude: 14 * deg, phase: .pi), .init(bone: .leftUpperArm, axis: x, amplitude: 14 * deg),
                .init(bone: .torso, axis: z, amplitude: 2 * deg, frequency: 2),
            ]),
            RigClip(id: "run", name: L10n.t("奔跑", "Run"), period: 0.7, channels: [
                .init(bone: .rightThigh, axis: x, amplitude: 34 * deg), .init(bone: .leftThigh, axis: x, amplitude: 34 * deg, phase: .pi),
                .init(bone: .rightShin, axis: x, amplitude: 24 * deg, phase: -1.2, bias: -26 * deg), .init(bone: .leftShin, axis: x, amplitude: 24 * deg, phase: .pi - 1.2, bias: -26 * deg),
                .init(bone: .rightUpperArm, axis: x, amplitude: 22 * deg, phase: .pi), .init(bone: .leftUpperArm, axis: x, amplitude: 22 * deg),
                .init(bone: .rightForearm, axis: x, amplitude: 0, bias: 45 * deg), .init(bone: .leftForearm, axis: x, amplitude: 0, bias: 45 * deg),
                .init(bone: .torso, axis: x, amplitude: 2 * deg, bias: 8 * deg, frequency: 2),
            ]),
            RigClip(id: "wave", name: L10n.t("挥手", "Wave"), period: 1.2, channels: [
                .init(bone: .rightUpperArm, axis: z, amplitude: 0, bias: -70 * deg),
                .init(bone: .rightForearm, axis: z, amplitude: 25 * deg, frequency: 2),
                .init(bone: .head, axis: z, amplitude: 4 * deg),
            ]),
        ]
    }()
}

enum RigPose {
    /// World transform of every bone (indexed by RigBone.rawValue) at time t.
    static func matrices(_ skeleton: RigSkeleton, clip: RigClip?, time t: Float) -> [Mat4] {
        var local = [Mat4](repeating: .identity, count: RigBone.allCases.count)
        if let clip {
            for channel in clip.channels {
                guard let bone = skeleton.bone(channel.bone) else { continue }
                local[channel.bone.rawValue] = local[channel.bone.rawValue] * Mat4.rotation(about: bone.head, Mat4.rotation(axis: channel.axis, angle: clip.angle(channel, at: t)))
            }
        }
        var world = [Mat4](repeating: .identity, count: RigBone.allCases.count)
        // allCases is parent-first order.
        for bone in RigBone.allCases {
            world[bone.rawValue] = bone.parent.map { world[$0.rawValue] } .map { $0 * local[bone.rawValue] } ?? local[bone.rawValue]
        }
        return world
    }

    /// Linear blend skinning of positions and normals.
    static func deform(_ mesh: GeneratedMesh, skin: SkinWeights, matrices: [Mat4]) -> (positions: [Float], normals: [Float]) {
        var positions = mesh.positions, normals = mesh.normals
        for i in 0..<min(mesh.vertexCount, skin.count) {
            let p = [mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2]]
            let n = [mesh.normals[i * 3], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2]]
            let a = matrices[Int(skin.bone0[i])], c = matrices[Int(skin.bone1[i])], w = skin.weight0[i]
            let pa = a.point(p), pc = c.point(p), na = a.direction(n), nc = c.direction(n)
            var nx = na[0] * w + nc[0] * (1 - w), ny = na[1] * w + nc[1] * (1 - w), nz = na[2] * w + nc[2] * (1 - w)
            let l = (nx * nx + ny * ny + nz * nz).squareRoot()
            if l > 0 { nx /= l; ny /= l; nz /= l }
            for k in 0..<3 { positions[i * 3 + k] = pa[k] * w + pc[k] * (1 - w) }
            normals[i * 3] = nx; normals[i * 3 + 1] = ny; normals[i * 3 + 2] = nz
        }
        return (positions, normals)
    }

    /// Body region (0 head, 1 torso, 2 arms, 3 legs) of every triangle,
    /// from its first vertex's main bone.
    static func triangleRegions(_ mesh: GeneratedMesh, skin: SkinWeights) -> [UInt8] {
        (0..<mesh.triangleCount).map { t in
            let v = Int(mesh.indices[t * 3])
            let bone = RigBone(rawValue: Int(skin.weight0[v] >= 0.5 ? skin.bone0[v] : skin.bone1[v])) ?? .torso
            return UInt8(bone.region)
        }
    }
}

// MARK: Validation

/// Deforms the mesh through every clip and checks it really moves the
/// right parts without tearing. Only a passing rig is offered.
struct RigValidation: Codable, Equatable, Sendable {
    var passed: Bool
    /// Largest vertex movement per clip, share of the model height.
    var clips: [String: Float]
    var maxStretch: Float
    var problems: [String]
    /// Share of sampled edges stretched over 4× per clip (seams where
    /// limbs touch the body in the picture).
    var seamStretch: [String: Float] = [:]

    static let tearLimit: Float = 0.025

    static func run(_ mesh: GeneratedMesh, skeleton: RigSkeleton, skin: SkinWeights, clips: [RigClip] = RigClip.standard) -> RigValidation {
        var problems: [String] = []
        if !skin.valid || skin.count != mesh.vertexCount { problems.append("weights") }
        let required: [RigBone] = [.torso, .head, .rightUpperArm, .leftUpperArm, .rightThigh, .leftThigh]
        for bone in required where skeleton.bone(bone) == nil { problems.append("missing \(bone)") }
        // Edges sampled for stretch checks.
        var edges: [(Int, Int)] = []
        let stride = max(1, mesh.triangleCount / 3000)
        for t in Swift.stride(from: 0, to: mesh.triangleCount, by: stride) { edges.append((Int(mesh.indices[t * 3]), Int(mesh.indices[t * 3 + 1]))) }
        func length(_ p: [Float], _ a: Int, _ b: Int) -> Float {
            let dx = p[a * 3] - p[b * 3], dy = p[a * 3 + 1] - p[b * 3 + 1], dz = p[a * 3 + 2] - p[b * 3 + 2]
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
        var movement: [String: Float] = [:], seams: [String: Float] = [:], worst: Float = 1
        let height = max(0.01, mesh.bounds.max[1] - mesh.bounds.min[1])
        for clip in clips where problems.isEmpty {
            var clipWorst: Float = 1, moved: Float = 0, broken = 0
            for step in 0..<8 {
                let t = clip.period * Float(step) / 8
                let deformed = RigPose.deform(mesh, skin: skin, matrices: RigPose.matrices(skeleton, clip: clip, time: t)).positions
                if !deformed.allSatisfy(\.isFinite) { problems.append("\(clip.id): not finite"); break }
                for i in Swift.stride(from: 0, to: mesh.vertexCount, by: max(1, mesh.vertexCount / 2000)) {
                    let d = (0..<3).map { deformed[i * 3 + $0] - mesh.positions[i * 3 + $0] }
                    moved = max(moved, (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).squareRoot())
                }
                for (a, b) in edges {
                    let rest = length(mesh.positions, a, b)
                    guard rest > height * 0.002 else { continue }
                    let ratio = length(deformed, a, b) / rest
                    clipWorst = max(clipWorst, ratio)
                    if ratio > 4 { broken += 1 }
                }
            }
            movement[clip.id] = moved / height
            worst = max(worst, clipWorst)
            // Idle is a gentle sway; the other clips must move limbs clearly.
            if moved / height < (clip.id == "idle" ? 0.004 : 0.02) { problems.append("\(clip.id): parts barely move") }
            let share = Float(broken) / Float(max(1, edges.count * 8))
            seams[clip.id] = share
            if share > tearLimit { problems.append("\(clip.id): mesh tears") }
        }
        return RigValidation(passed: problems.isEmpty, clips: movement, maxStretch: worst, problems: problems, seamStretch: seams)
    }
}

/// Everything saved for a rigged model.
struct RigPackage: Codable, Equatable, Sendable {
    var skeleton: RigSkeleton
    var joints: BodyJoints2D
    var clips: [RigClip]
    var validation: RigValidation
}
