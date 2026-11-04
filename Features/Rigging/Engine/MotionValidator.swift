import Foundation

// v1.73 M07: motion clips for the 27-joint skeleton and the automatic
// motion test. Every rigged character is really deformed through eight
// test motions; numbers (stretch, tearing, joint limits, ground contact,
// approximate self-intersection, trajectories) decide pass / warning /
// fail. Automatic checks cannot judge visual quality; a person still has
// to look.

/// Looping procedural clip: each channel turns one joint about x / y / z
/// with a sine wave; root channels move the whole body.
struct MotionClip: Codable, Equatable, Identifiable, Sendable {
    struct Channel: Codable, Equatable, Sendable {
        var joint: JointTag
        /// 0 = x, 1 = y, 2 = z.
        var axis: Int
        /// Degrees.
        var amplitude: Float
        /// Turns (0…1).
        var phase: Float = 0
        var bias: Float = 0
        var cycles: Float = 1
    }
    struct RootChannel: Codable, Equatable, Sendable {
        var axis: Int
        /// Model units (the model is 1 tall).
        var amplitude: Float
        var phase: Float = 0
        var bias: Float = 0
        var cycles: Float = 1
        /// |sin|: a hop that never goes below the bias.
        var rectified = false
    }
    var id: String
    var name: String
    var period: Float
    var channels: [Channel]
    var root: [RootChannel] = []
    /// v1.76: keyframed animation from a model file; when set it drives the
    /// pose (period = its duration) and the sine channels are unused.
    var keyframes: KeyframeClip? = nil

    func value(amplitude: Float, phase: Float, bias: Float, cycles: Float, rectified: Bool = false, at t: Float) -> Float {
        let s = sin(2 * .pi * (cycles * t / max(0.01, period) + phase))
        return bias + amplitude * (rectified ? abs(s) : s)
    }
    func pose(_ skeleton: SkeletonDefinition, at t: Float) -> SkeletonPose {
        var pose = SkeletonPose.rest(skeleton)
        if let keyframes {
            pose.locals = keyframes.locals(skeleton, at: t)
            return pose
        }
        for c in channels {
            guard let j = skeleton.index(c.joint), (0..<3).contains(c.axis) else { continue }
            pose.rotations[j][c.axis] += value(amplitude: c.amplitude, phase: c.phase, bias: c.bias, cycles: c.cycles, at: t)
        }
        for r in root where (0..<3).contains(r.axis) {
            pose.rootOffset[r.axis] += value(amplitude: r.amplitude, phase: r.phase, bias: r.bias, cycles: r.cycles, rectified: r.rectified, at: t)
        }
        return pose
    }

    // MARK: Library

    /// The eight test motions (spec M07), in order.
    static let testIDs = ["rest", "raiseArms", "bendElbows", "squat", "walk", "jump", "twist", "swordSwing"]

    static let library: [MotionClip] = [
        MotionClip(id: "rest", name: L10n.t("绑定姿态", "Bind Pose"), period: 1, channels: []),
        MotionClip(id: "raiseArms", name: L10n.t("抬手", "Raise Arms"), period: 2, channels: [
            .init(joint: .rightUpperArm, axis: 2, amplitude: 40, phase: 0.75, bias: -40), .init(joint: .leftUpperArm, axis: 2, amplitude: 40, phase: 0.75, bias: 40),
        ]),
        MotionClip(id: "bendElbows", name: L10n.t("弯肘", "Bend Elbows"), period: 1.6, channels: [
            .init(joint: .rightForearm, axis: 0, amplitude: 50, phase: 0.75, bias: -50), .init(joint: .leftForearm, axis: 0, amplitude: 50, phase: 0.75, bias: -50),
        ]),
        MotionClip(id: "squat", name: L10n.t("下蹲", "Squat"), period: 2.2, channels: [
            .init(joint: .rightThigh, axis: 0, amplitude: 37, phase: 0.75, bias: -37), .init(joint: .leftThigh, axis: 0, amplitude: 37, phase: 0.75, bias: -37),
            .init(joint: .rightShin, axis: 0, amplitude: 50, phase: 0.75, bias: 50), .init(joint: .leftShin, axis: 0, amplitude: 50, phase: 0.75, bias: 50),
            .init(joint: .rightFoot, axis: 0, amplitude: 13, phase: 0.75, bias: -13), .init(joint: .leftFoot, axis: 0, amplitude: 13, phase: 0.75, bias: -13),
            .init(joint: .spine, axis: 0, amplitude: 10, phase: 0.75, bias: -10),
            .init(joint: .rightUpperArm, axis: 0, amplitude: 30, phase: 0.75, bias: -30), .init(joint: .leftUpperArm, axis: 0, amplitude: 30, phase: 0.75, bias: -30),
        ], root: [.init(axis: 1, amplitude: 0.085, phase: 0.25, bias: -0.085)]),
        MotionClip(id: "walk", name: L10n.t("行走", "Walk"), period: 1.1, channels: [
            .init(joint: .rightThigh, axis: 0, amplitude: 24), .init(joint: .leftThigh, axis: 0, amplitude: 24, phase: 0.5),
            .init(joint: .rightShin, axis: 0, amplitude: 14, phase: 0.8, bias: 14), .init(joint: .leftShin, axis: 0, amplitude: 14, phase: 0.3, bias: 14),
            .init(joint: .rightUpperArm, axis: 0, amplitude: 16, phase: 0.5), .init(joint: .leftUpperArm, axis: 0, amplitude: 16),
            .init(joint: .rightForearm, axis: 0, amplitude: 0, bias: -12), .init(joint: .leftForearm, axis: 0, amplitude: 0, bias: -12),
            .init(joint: .spine, axis: 1, amplitude: 4, phase: 0.5),
        ], root: [.init(axis: 1, amplitude: 0.008, phase: 0.25, cycles: 2)]),
        MotionClip(id: "jump", name: L10n.t("跳跃", "Jump"), period: 1, channels: [
            .init(joint: .rightThigh, axis: 0, amplitude: 12, phase: 0.25, bias: -12, cycles: 2), .init(joint: .leftThigh, axis: 0, amplitude: 12, phase: 0.25, bias: -12, cycles: 2),
            .init(joint: .rightShin, axis: 0, amplitude: 16, phase: 0.25, bias: 16, cycles: 2), .init(joint: .leftShin, axis: 0, amplitude: 16, phase: 0.25, bias: 16, cycles: 2),
            .init(joint: .rightUpperArm, axis: 2, amplitude: 25, phase: 0.75, bias: -25, cycles: 2), .init(joint: .leftUpperArm, axis: 2, amplitude: 25, phase: 0.75, bias: 25, cycles: 2),
        ], root: [.init(axis: 1, amplitude: 0.16, rectified: true)]),
        MotionClip(id: "twist", name: L10n.t("转身", "Twist"), period: 2, channels: [
            .init(joint: .spine, axis: 1, amplitude: 12), .init(joint: .spine1, axis: 1, amplitude: 12), .init(joint: .chest, axis: 1, amplitude: 12),
            .init(joint: .head, axis: 1, amplitude: -10),
        ]),
        MotionClip(id: "swordSwing", name: L10n.t("挥剑", "Sword Swing"), period: 1.4, channels: [
            .init(joint: .rightUpperArm, axis: 0, amplitude: 60, phase: 0.25, bias: -80), .init(joint: .rightUpperArm, axis: 2, amplitude: 0, bias: -12),
            .init(joint: .rightForearm, axis: 0, amplitude: 20, phase: 0.25, bias: -25), .init(joint: .rightHand, axis: 0, amplitude: 25, phase: 0.3),
            .init(joint: .chest, axis: 1, amplitude: 10, phase: 0.25), .init(joint: .leftUpperArm, axis: 2, amplitude: 0, bias: 20),
        ]),
        MotionClip(id: "idle", name: L10n.t("待机", "Idle"), period: 3, channels: [
            .init(joint: .chest, axis: 0, amplitude: 1.5), .init(joint: .head, axis: 2, amplitude: 2.5, phase: 0.15),
            .init(joint: .rightUpperArm, axis: 2, amplitude: 2.5, phase: 0.1), .init(joint: .leftUpperArm, axis: 2, amplitude: 2.5, phase: 0.6),
        ], root: [.init(axis: 1, amplitude: 0.003, cycles: 2)]),
        MotionClip(id: "run", name: L10n.t("奔跑", "Run"), period: 0.7, channels: [
            .init(joint: .rightThigh, axis: 0, amplitude: 36), .init(joint: .leftThigh, axis: 0, amplitude: 36, phase: 0.5),
            .init(joint: .rightShin, axis: 0, amplitude: 28, phase: 0.8, bias: 34), .init(joint: .leftShin, axis: 0, amplitude: 28, phase: 0.3, bias: 34),
            .init(joint: .rightUpperArm, axis: 0, amplitude: 26, phase: 0.5), .init(joint: .leftUpperArm, axis: 0, amplitude: 26),
            .init(joint: .rightForearm, axis: 0, amplitude: 0, bias: -70), .init(joint: .leftForearm, axis: 0, amplitude: 0, bias: -70),
            .init(joint: .spine, axis: 0, amplitude: 0, bias: -8),
        ], root: [.init(axis: 1, amplitude: 0.02, phase: 0.25, cycles: 2)]),
        MotionClip(id: "wave", name: L10n.t("挥手", "Wave"), period: 1.2, channels: [
            .init(joint: .rightUpperArm, axis: 2, amplitude: 0, bias: -150), .init(joint: .rightForearm, axis: 2, amplitude: 22, cycles: 2),
            .init(joint: .head, axis: 2, amplitude: 4),
        ]),
    ]
    static func standard(_ id: String) -> MotionClip? { library.first { $0.id == id } }

    /// Clip a world action plays.
    /// Clips from a model file, named after the standard motion they match
    /// (idle / walk / run / jump / attack / wave) so world actions find them.
    static func fromFile(_ clips: [KeyframeClip]) -> [MotionClip] {
        let rules: [(String, [String])] = [("idle", ["idle", "待机", "stand", "breath"]), ("walk", ["walk", "行走", "走"]), ("run", ["run", "sprint", "奔跑", "跑"]),
                                           ("jump", ["jump", "跳"]), ("swordSwing", ["attack", "slash", "swing", "punch", "hit", "攻击", "砍"]), ("wave", ["wave", "挥手", "greet"])]
        var used = Set<String>(), out: [MotionClip] = []
        for (i, k) in clips.enumerated() {
            let name = k.name.lowercased()
            var id = "file-\(i)"
            if let rule = rules.first(where: { r in !used.contains(r.0) && r.1.contains { name.contains($0) } }) { id = rule.0; used.insert(id) }
            out.append(MotionClip(id: id, name: k.name, period: max(0.04, k.duration), channels: [], keyframes: k))
        }
        return out
    }

    /// The clip for a world action: a matching clip, else the file's first
    /// clip (a file skeleton cannot use the built-in motions), else built-in.
    static func resolve(_ id: String, in clips: [MotionClip]) -> MotionClip? {
        let file = clips.filter { $0.keyframes != nil }
        if !file.isEmpty { return file.first { $0.id == id } ?? file[0] }
        return clips.first { $0.id == id } ?? standard(id)
    }

    static func id(for action: CharacterAction) -> String {
        switch action {
        case .walk: "walk"
        case .run, .dodge: "run"
        case .jump, .fall: "jump"
        case .attack, .skill, .transform: "swordSwing"
        case .interact: "wave"
        case .idle, .hurt, .death: "idle"
        }
    }
}

enum MotionValidator {
    static let frames = 12

    struct Context {
        var mesh: GeneratedMesh
        var skeleton: SkeletonDefinition
        var skin: SkinInfluences
        var edges: [(Int, Int)]
        var restLengths: [Float]
        var dominantRegion: [Int]
        var restMinY: Float
        var torsoRadius: Float
    }

    static func context(_ mesh: GeneratedMesh, skeleton: SkeletonDefinition, skin: SkinInfluences) -> Context {
        var edges: [(Int, Int)] = []
        let stride = max(1, mesh.triangleCount / 4000)
        for t in Swift.stride(from: 0, to: mesh.triangleCount, by: stride) {
            edges.append((Int(mesh.indices[t * 3]), Int(mesh.indices[t * 3 + 1])))
            edges.append((Int(mesh.indices[t * 3 + 1]), Int(mesh.indices[t * 3 + 2])))
        }
        let rest = edges.map { MeshAnalyzer.distance(mesh, $0.0, $0.1) }
        let region = (0..<mesh.vertexCount).map { v in skin.dominant(v).map { skeleton.joints[$0].semanticTag.region } ?? 1 }
        let world = skeleton.worldRest.map(\.origin)
        var radii: [Float] = []
        if let pelvis = skeleton.index(.pelvis), let neck = skeleton.index(.neck) {
            for v in 0..<mesh.vertexCount where region[v] == 1 {
                let p = SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2])
                radii.append(SkinWeightSolver.segmentDistance(SIMD3(p.x, p.y, p.z), world[pelvis], world[neck]))
            }
        }
        radii.sort()
        let torso = radii.isEmpty ? 0.08 : radii[radii.count / 2]
        return Context(mesh: mesh, skeleton: skeleton, skin: skin, edges: edges, restLengths: rest, dominantRegion: region,
                       restMinY: mesh.bounds.min[1], torsoRadius: torso)
    }

    static func run(_ c: Context, clips: [MotionClip]) -> [DiagnosticResult] {
        clips.map { test(c, clip: $0) }
    }

    static func test(_ c: Context, clip: MotionClip) -> DiagnosticResult {
        var notes: [String] = []
        var status = DiagnosticStatus.pass
        func worse(_ s: DiagnosticStatus, _ note: String) { status = max(status, s); notes.append(note) }
        let mesh = c.mesh, s = c.skeleton
        var worstStretch: Float = 1, broken = 0, collapsed = 0, moved: Float = 0, limitHits = 0, inside = 0, armSamples = 0
        var minY = Float.infinity, apexMinY = -Float.infinity
        var socketPath: [SIMD3<Float>] = []
        var thighPhase: [(Float, Float)] = []
        let world0 = s.worldRest.map(\.origin)
        let pelvis = s.index(.pelvis), neck = s.index(.neck)
        for f in 0..<frames {
            let t = clip.period * Float(f) / Float(frames)
            let pose = clip.pose(s, at: t)
            for (i, j) in s.joints.enumerated() where !j.jointLimit.contains(pose.rotations[i], slack: 5) && !j.semanticTag.isEnd { limitHits += 1 }
            let posed = SkinWeightSolver.deform(mesh, skin: c.skin, matrices: pose.skinning(s)).positions
            guard posed.allSatisfy(\.isFinite) else { return DiagnosticResult(id: clip.id, title: clip.name, status: .fail, metrics: [:], notes: [L10n.t("矩阵或变形结果无效", "Invalid matrices or deformation")]) }
            for (k, e) in c.edges.enumerated() where c.restLengths[k] > 0.002 {
                let dx = posed[e.0 * 3] - posed[e.1 * 3], dy = posed[e.0 * 3 + 1] - posed[e.1 * 3 + 1], dz = posed[e.0 * 3 + 2] - posed[e.1 * 3 + 2]
                let r = (dx * dx + dy * dy + dz * dz).squareRoot() / c.restLengths[k]
                worstStretch = max(worstStretch, r)
                if r > 2.5 { broken += 1 }
                if r < 0.2 { collapsed += 1 }
            }
            var frameMin = Float.infinity
            let world = pose.world(s)
            for v in Swift.stride(from: 0, to: mesh.vertexCount, by: max(1, mesh.vertexCount / 3000)) {
                let d = SIMD3(posed[v * 3] - mesh.positions[v * 3], posed[v * 3 + 1] - mesh.positions[v * 3 + 1], posed[v * 3 + 2] - mesh.positions[v * 3 + 2])
                moved = max(moved, rigLength(d))
                frameMin = min(frameMin, posed[v * 3 + 1])
                // Arm vertices inside the torso (approximate self-intersection).
                if c.dominantRegion[v] == 2, let pelvis, let neck {
                    armSamples += 1
                    let p = SIMD3(posed[v * 3], posed[v * 3 + 1], posed[v * 3 + 2])
                    if SkinWeightSolver.segmentDistance(p, world[pelvis].origin, world[neck].origin) < c.torsoRadius * 0.6 { inside += 1 }
                }
            }
            minY = min(minY, frameMin)
            if clip.id == "jump" && abs(t - clip.period / 2) < clip.period / Float(frames) { apexMinY = frameMin }
            if clip.id == "swordSwing", let hand = s.index(.rightHand), let end = s.index(.rightHandEnd) {
                socketPath.append(world[hand].origin + (world[end].origin - world[hand].origin) * 0.6)
            }
            if clip.id == "walk", let r = s.index(.rightThigh), let l = s.index(.leftThigh) { thighPhase.append((pose.rotations[r].x, pose.rotations[l].x)) }
        }
        let samples = Float(max(1, c.edges.count * frames))
        let tear = Float(broken) / samples, collapse = Float(collapsed) / samples
        var metrics: [String: Float] = ["maxStretch": worstStretch, "tearShare": tear, "collapseShare": collapse, "maxMove": moved, "limitHits": Float(limitHits)]
        if tear > 0.01 { worse(.fail, L10n.t("网格撕裂 \(pct(tear))", "Mesh tears \(pct(tear))")) } else if tear > 0.002 { worse(.warning, L10n.t("局部拉伸 \(pct(tear))", "Local stretching \(pct(tear))")) }
        if collapse > 0.03 { worse(.warning, L10n.t("关节处挤压 \(pct(collapse))", "Joint pinching \(pct(collapse))")) }
        if limitHits > 0 { worse(.warning, L10n.t("超出关节限制 \(limitHits) 次", "Joint limits exceeded \(limitHits)×")) }
        let penetration = Float(inside) / Float(max(1, armSamples))
        metrics["armInsideTorso"] = penetration
        if penetration > 0.04 && clip.id != "rest" { worse(.warning, L10n.t("手臂可能穿入身体 \(pct(penetration))（近似检测）", "Arms may pass into the body \(pct(penetration)) (approximate)")) }
        let ground = c.restMinY
        metrics["minY"] = minY - ground
        switch clip.id {
        case "rest":
            if moved > 1e-4 { worse(.fail, L10n.t("绑定姿态下模型发生了移动", "The model moves in the bind pose")) }
            do { try s.validate() } catch { worse(.fail, L10n.t("骨骼结构检查未通过：\(error)", "Skeleton check failed: \(error)")) }
        case "walk":
            let opposite = thighPhase.filter { abs($0.0) > 5 }.allSatisfy { $0.0 * $0.1 < 0 }
            metrics["legsOpposite"] = opposite ? 1 : 0
            if !opposite { worse(.warning, L10n.t("双腿没有交替", "Legs do not alternate")) }
            if minY < ground - 0.03 { worse(.warning, L10n.t("脚穿过地面 \(String(format: "%.3f", ground - minY))", "Feet go through the ground by \(String(format: "%.3f", ground - minY))")) }
        case "jump":
            metrics["apexClearance"] = apexMinY - ground
            if apexMinY - ground < 0.03 { worse(.warning, L10n.t("最高点双脚没有离地", "Feet stay on the ground at the top")) }
        case "squat":
            if moved < 0.05 { worse(.fail, L10n.t("下蹲几乎没有动作", "Squat barely moves")) }
        case "swordSwing":
            let length = zip(socketPath, socketPath.dropFirst()).map { rigLength($1 - $0) }.reduce(0, +)
            let jump = zip(socketPath, socketPath.dropFirst()).map { rigLength($1 - $0) }.max() ?? 0
            metrics["weaponPath"] = length; metrics["weaponStep"] = jump
            if length < 0.25 { worse(.warning, L10n.t("武器挂点轨迹太短", "Weapon socket path too short")) }
            if jump > 0.3 { worse(.fail, L10n.t("武器挂点轨迹跳变", "Weapon socket path jumps")) }
        default:
            if moved < 0.015 { worse(.fail, L10n.t("相关部位几乎没有动", "The parts barely move")) }
        }
        _ = world0
        return DiagnosticResult(id: clip.id, title: clip.name, status: status, metrics: metrics, notes: notes)
    }

    /// Joints whose vertices stretch most in a clip (repair targets).
    static func stretchedJoints(_ c: Context, clip: MotionClip) -> [Int] {
        var count = [Int](repeating: 0, count: c.skeleton.joints.count)
        for f in 0..<frames {
            let pose = clip.pose(c.skeleton, at: clip.period * Float(f) / Float(frames))
            let posed = SkinWeightSolver.deform(c.mesh, skin: c.skin, matrices: pose.skinning(c.skeleton)).positions
            for (k, e) in c.edges.enumerated() where c.restLengths[k] > 0.002 {
                let dx = posed[e.0 * 3] - posed[e.1 * 3], dy = posed[e.0 * 3 + 1] - posed[e.1 * 3 + 1], dz = posed[e.0 * 3 + 2] - posed[e.1 * 3 + 2]
                if (dx * dx + dy * dy + dz * dz).squareRoot() / c.restLengths[k] > 2.5 {
                    for v in [e.0, e.1] { for (j, _) in c.skin.influences(v) { count[j] += 1 } }
                }
            }
        }
        return count.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.prefix(4).map(\.offset)
    }

    static func pct(_ x: Float) -> String { String(format: "%.2f%%", x * 100) }
}
