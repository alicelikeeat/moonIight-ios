import Foundation

// v1.91: HumanBase, the universal base body (MakeHuman hm08, CC0) shaped by
// parameters. Two kinds of change, both carried through to the skeleton:
//   - shape channels (morph targets: build, muscle, gender, shoulders, …),
//     which move the surface AND the joints that sit inside it;
//   - bone lengths (legs, arms, torso) and head size, applied as a skinned
//     scale per joint, so vertices, joints, sockets and colliders all move
//     together (never a scaled outer entity with stale bones).
// The result is re-grounded and scaled to the requested height; LODs share
// the same skeleton and weights.

/// Body parameters. Morph values are −1…1; lengths and head size are factors.
struct HumanShape: Codable, Equatable, Sendable {
    /// Metres, 0.8…2.4.
    var height: Float = 1.75
    /// −1 slim … +1 heavy.
    var build: Float = 0
    var muscle: Float = 0
    /// −1 feminine … +1 masculine (0: the neutral mannequin).
    var gender: Float = 0
    var shoulders: Float = 0
    var hips: Float = 0
    /// Belly / waist girth.
    var waist: Float = 0
    var neck: Float = 0
    /// Bone-length factors.
    var legLength: Float = 1
    var armLength: Float = 1
    var torsoLength: Float = 1
    /// 1 = adult; up to 1.9 for a chibi head.
    var headSize: Float = 1
    var hands: Float = 0
    var feet: Float = 0
    var faceOval: Float = 0
    var faceRound: Float = 0
    var faceSquare: Float = 0

    static let standard = HumanShape()
    static let tall = HumanShape(height: 2.0, build: -0.3, muscle: 0.4, gender: 0.6, shoulders: 0.5, legLength: 1.12, armLength: 1.05, faceOval: 0.6)
    static let chibi = HumanShape(height: 1.05, build: 0.3, gender: -0.4, hips: 0.2, legLength: 0.68, armLength: 0.8, torsoLength: 0.85, headSize: 1.85, hands: 0.6, feet: 0.6, faceRound: 1)
    static let strong = HumanShape(height: 1.85, build: 0.4, muscle: 1, gender: 1, shoulders: 1, neck: 0.4, faceSquare: 0.8)
    static let slim = HumanShape(height: 1.68, build: -0.8, muscle: -0.3, gender: -0.6, hips: 0.3, legLength: 1.04, faceOval: 0.8)

    var clamped: HumanShape {
        func c(_ v: Float, _ lo: Float, _ hi: Float, _ fallback: Float) -> Float { v.isFinite ? min(hi, max(lo, v)) : fallback }
        var s = self
        s.height = c(height, 0.8, 2.4, 1.75)
        for path in [\HumanShape.build, \.muscle, \.gender, \.shoulders, \.hips, \.waist, \.neck, \.hands, \.feet] { s[keyPath: path] = c(s[keyPath: path], -1, 1, 0) }
        for path in [\HumanShape.faceOval, \.faceRound, \.faceSquare] { s[keyPath: path] = c(s[keyPath: path], 0, 1, 0) }
        s.legLength = c(legLength, 0.55, 1.35, 1); s.armLength = c(armLength, 0.6, 1.3, 1); s.torsoLength = c(torsoLength, 0.7, 1.3, 1)
        s.headSize = c(headSize, 0.8, 1.9, 1)
        return s
    }

    /// Morph channel values by the names in the HumanBase file.
    var channelValues: [String: Float] {
        let s = clamped
        return ["weight": s.build, "muscle": s.muscle, "gender": s.gender, "shoulders": s.shoulders, "hips": s.hips, "belly": s.waist,
                "neck": s.neck, "hands": s.hands, "feet": s.feet, "faceOval": s.faceOval, "faceRound": s.faceRound, "faceSquare": s.faceSquare]
    }
}

/// One shaped body at one level of detail.
struct HumanBody: Sendable {
    var shape: HumanShape
    var lod: Int
    var skeleton: SkeletonDefinition
    var mesh: GeneratedMesh
    var skin: SkinInfluences
    /// Render vertex → HumanBase surface vertex.
    var master: [Int]
    /// What each render vertex is part of (for photo painting).
    var vertices: [BaseBodyVertex]

    /// Ratios of this body (for photo fitting and the older base-body code).
    var bodyShape: BodyShape {
        var p: [JointTag: SIMD3<Float>] = [:]
        let world = skeleton.worldRest
        for (i, j) in skeleton.joints.enumerated() where j.semanticTag != .other { p[j.semanticTag] = world[i].origin }
        var s = BaseBodyTransfer.shape(from: p) ?? .standard
        s.height = shape.clamped.height
        return s
    }
    /// The same body in the shape older code (photo paint, transfer) takes.
    var model: BaseBodyModel { BaseBodyModel(shape: bodyShape, skeleton: skeleton, mesh: mesh, skin: skin, vertices: vertices) }
}

enum HumanBase {
    /// Joints scaled along their bone by a length factor, and the child that bone points at.
    private static let lengthJoints: [(String, String, KeyPath<HumanShape, Float>)] = [
        ("spine", "spine1", \.torsoLength), ("spine1", "chest", \.torsoLength), ("chest", "neck", \.torsoLength),
        ("rightUpperArm", "rightForearm", \.armLength), ("rightForearm", "rightHand", \.armLength),
        ("leftUpperArm", "leftForearm", \.armLength), ("leftForearm", "leftHand", \.armLength),
        ("rightThigh", "rightShin", \.legLength), ("rightShin", "rightFoot", \.legLength),
        ("leftThigh", "leftShin", \.legLength), ("leftShin", "leftFoot", \.legLength),
    ]
    /// Joints that grow with the head.
    private static let headJoints: Set<String> = ["head", "headEnd", "ext.jaw", "ext.rightEye", "ext.leftEye"]

    /// Shaped surface (every HumanBase vertex) and joints, metres, feet on y = 0.
    static func shaped(_ raw: HumanShape, asset: HumanBaseAsset) -> (positions: [SIMD3<Float>], joints: [SIMD3<Float>]) {
        let shape = raw.clamped
        var p = asset.positions
        var j = asset.joints.map(\.position)
        // 1. Morph channels.
        for (name, value) in shape.channelValues where value != 0 {
            guard let channel = asset.channel(name) else { continue }
            let side = value > 0 ? channel.positive : channel.negative, k = abs(value)
            for (i, d) in zip(side.indices, side.deltas) { p[i] += d * k }
            for i in j.indices { j[i] += side.joints[i] * k }
        }
        // 2. Bone lengths and head size: a scale per joint, blended by the weights.
        var scale = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)](repeating: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)), count: j.count)
        func index(_ name: String) -> Int? { asset.jointIndex(name) }
        for (name, child, path) in lengthJoints {
            guard let a = index(name), let b = index(child) else { continue }
            let f = shape[keyPath: path]
            guard f != 1 else { continue }
            let d = cUnit(j[b] - j[a])
            // I + (f − 1) d dᵀ, as columns.
            scale[a] = (SIMD3(1, 0, 0) + d * ((f - 1) * d.x), SIMD3(0, 1, 0) + d * ((f - 1) * d.y), SIMD3(0, 0, 1) + d * ((f - 1) * d.z))
        }
        if shape.headSize != 1 {
            for name in headJoints { if let a = index(name) { let s = shape.headSize; scale[a] = (SIMD3(s, 0, 0), SIMD3(0, s, 0), SIMD3(0, 0, s)) } }
        }
        func apply(_ m: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), _ v: SIMD3<Float>) -> SIMD3<Float> { m.0 * v.x + m.1 * v.y + m.2 * v.z }
        // New joint positions, parents first: each child rides its parent's scale.
        var moved = j
        for (i, joint) in asset.joints.enumerated() {
            guard let parent = joint.parent else { continue }
            moved[i] = moved[parent] + apply(scale[parent], j[i] - j[parent])
        }
        if moved != j || scale.contains(where: { $0.0 != SIMD3(1, 0, 0) || $0.1 != SIMD3(0, 1, 0) || $0.2 != SIMD3(0, 0, 1) }) {
            for v in p.indices {
                var out = SIMD3<Float>.zero, total: Float = 0
                for k in 0..<4 {
                    let w = asset.influenceWeights[v * 4 + k]
                    guard w > 0 else { continue }
                    let ji = Int(asset.influenceJoints[v * 4 + k])
                    out += (moved[ji] + apply(scale[ji], p[v] - j[ji])) * w
                    total += w
                }
                if total > 0 { p[v] = out / total }
            }
            j = moved
        }
        // 3. Feet on the ground, the requested height.
        var lo = Float.infinity, hi = -Float.infinity
        for v in p { lo = min(lo, v.y); hi = max(hi, v.y) }
        let k = shape.height / max(0.01, hi - lo)
        let origin = SIMD3<Float>(0, lo, 0)
        return (p.map { ($0 - origin) * k }, j.map { ($0 - origin) * k })
    }

    /// The skeleton for shaped joints: the 27 standard joints first (same
    /// ids and tags as every Moonlight rig), then the extension joints.
    static func skeleton(_ joints: [SIMD3<Float>], asset: HumanBaseAsset) -> SkeletonDefinition {
        var out: [RigJoint] = []
        for (i, joint) in asset.joints.enumerated() {
            let tag = JointTag(rawValue: joint.name) ?? .other
            let parentPosition = joint.parent.map { joints[$0] } ?? .zero
            out.append(RigJoint(jointID: joint.name, parentID: joint.parent.map { asset.joints[$0].name }, restTransform: RigXform.translation(joints[i] - parentPosition).matrix,
                                inverseBindMatrix: RigXform.identity.matrix, jointLimit: tag == .other ? extensionLimit(joint.name) : SkeletonBuilder.limit(tag),
                                semanticTag: tag, confidence: 1, source: .authored))
        }
        var skeleton = SkeletonDefinition(joints: out)
        skeleton.refreshBindMatrices()
        return skeleton
    }

    static func extensionLimit(_ name: String) -> JointLimit {
        if name.contains("Finger1") { return JointLimit(min: [-60, -40, -40], max: [20, 40, 40]) }
        if name.contains("Finger") { return JointLimit(min: [-100, -15, -20], max: [10, 15, 20]) }
        if name == "ext.jaw" { return JointLimit(min: [0, -8, -5], max: [30, 8, 5]) }
        if name.hasSuffix("Eye") { return JointLimit(min: [-30, -40, -5], max: [30, 40, 5]) }
        return .free
    }

    /// The body at a level of detail (0 = full, 1, 2). Nil without the asset.
    static func build(_ shape: HumanShape, lod: Int = 0, asset: HumanBaseAsset? = HumanBaseAsset.shared) -> HumanBody? {
        guard let asset, !asset.lods.isEmpty else { return nil }
        let level = asset.lods[min(max(0, lod), asset.lods.count - 1)]
        let (p, j) = shaped(shape, asset: asset)
        let skeleton = skeleton(j, asset: asset)
        var mesh = GeneratedMesh()
        mesh.positions.reserveCapacity(level.master.count * 3)
        for m in level.master { mesh.positions += [p[m].x, p[m].y, p[m].z] }
        mesh.uvs = level.uvs
        mesh.indices = level.indices
        // Smooth normals over the surface (by surface vertex, so UV seams do not show).
        var acc = [SIMD3<Float>](repeating: .zero, count: asset.vertexCount)
        for t in 0..<level.triangleCount {
            let a = level.master[Int(level.indices[t * 3])], b = level.master[Int(level.indices[t * 3 + 1])], c = level.master[Int(level.indices[t * 3 + 2])]
            let n = cCross(p[b] - p[a], p[c] - p[a])
            acc[a] += n; acc[b] += n; acc[c] += n
        }
        mesh.normals.reserveCapacity(level.master.count * 3)
        for m in level.master { let n = cUnit(acc[m]); mesh.normals += [n.x, n.y, n.z] }
        var joints: [UInt8] = [], weights: [Float] = []
        for m in level.master {
            joints += asset.influenceJoints[m * 4 ..< m * 4 + 4].enumerated().map { asset.influenceWeights[m * 4 + $0.offset] > 0 ? $0.element : 255 }
            weights += asset.influenceWeights[m * 4 ..< m * 4 + 4]
        }
        let skin = SkinInfluences(joints: joints, weights: weights)
        return HumanBody(shape: shape.clamped, lod: lod, skeleton: skeleton, mesh: mesh, skin: skin, master: level.master,
                         vertices: parts(mesh: mesh, skin: skin, skeleton: skeleton))
    }

    /// Body part of every vertex: its strongest joint's segment (fingers,
    /// jaw and eyes count as hand / head), how far along it and which side.
    static func parts(mesh: GeneratedMesh, skin: SkinInfluences, skeleton: SkeletonDefinition) -> [BaseBodyVertex] {
        let next: [JointTag: JointTag] = [.pelvis: .spine, .spine: .spine1, .spine1: .chest, .chest: .neck, .neck: .head, .head: .headEnd,
                                          .rightClavicle: .rightUpperArm, .rightUpperArm: .rightForearm, .rightForearm: .rightHand, .rightHand: .rightHandEnd,
                                          .leftClavicle: .leftUpperArm, .leftUpperArm: .leftForearm, .leftForearm: .leftHand, .leftHand: .leftHandEnd,
                                          .rightThigh: .rightShin, .rightShin: .rightFoot, .rightFoot: .rightToe, .rightToe: .rightToeEnd,
                                          .leftThigh: .leftShin, .leftShin: .leftFoot, .leftFoot: .leftToe, .leftToe: .leftToeEnd]
        func standard(_ i: Int) -> JointTag {
            let j = skeleton.joints[i]
            if j.semanticTag != .other { return j.semanticTag }
            if j.jointID.contains("right") && j.jointID.contains("Finger") { return .rightHand }
            if j.jointID.contains("left") && j.jointID.contains("Finger") { return .leftHand }
            return .head
        }
        return (0..<mesh.vertexCount).map { v in
            var best = 0, bestWeight: Float = -1
            for k in 0..<4 where skin.joints[v * 4 + k] != 255 && skin.weights[v * 4 + k] > bestWeight { best = Int(skin.joints[v * 4 + k]); bestWeight = skin.weights[v * 4 + k] }
            let from = standard(best), to = next[from] ?? from
            let p = SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2])
            let a = skeleton.position(from) ?? .zero, b = skeleton.position(to) ?? a
            let axis = b - a, l2 = max(1e-8, cDot(axis, axis))
            let along = min(1, max(0, cDot(p - a, axis) / l2))
            let foot = a + axis * along, r = p - foot
            let n = SIMD3(mesh.normals[v * 3], mesh.normals[v * 3 + 1], mesh.normals[v * 3 + 2])
            return BaseBodyVertex(from: from, to: to, along: along, angle: atan2(r.z, r.x), front: n.z > 0)
        }
    }
}
