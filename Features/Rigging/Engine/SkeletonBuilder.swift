import Foundation

// v1.73 M03: the standard 27-joint humanoid skeleton from estimated joint
// positions, with joint limits, attachment sockets and validation.

enum SkeletonBuilder {
    /// Parent of each standard joint (nil = root). Order is parent-first.
    static let hierarchy: [(JointTag, JointTag?)] = [
        (.pelvis, nil), (.spine, .pelvis), (.spine1, .spine), (.chest, .spine1), (.neck, .chest), (.head, .neck), (.headEnd, .head),
        (.rightClavicle, .chest), (.rightUpperArm, .rightClavicle), (.rightForearm, .rightUpperArm), (.rightHand, .rightForearm), (.rightHandEnd, .rightHand),
        (.leftClavicle, .chest), (.leftUpperArm, .leftClavicle), (.leftForearm, .leftUpperArm), (.leftHand, .leftForearm), (.leftHandEnd, .leftHand),
        (.rightThigh, .pelvis), (.rightShin, .rightThigh), (.rightFoot, .rightShin), (.rightToe, .rightFoot), (.rightToeEnd, .rightToe),
        (.leftThigh, .pelvis), (.leftShin, .leftThigh), (.leftFoot, .leftShin), (.leftToe, .leftFoot), (.leftToeEnd, .leftToe),
    ]

    /// Rotation limits (degrees, x / y / z) relative to the bind pose.
    /// x bends forward (negative) / back (positive); z raises sideways.
    static func limit(_ tag: JointTag) -> JointLimit {
        switch tag {
        case .pelvis: JointLimit(min: [-60, -90, -45], max: [60, 90, 45])
        case .spine, .spine1, .chest: JointLimit(min: [-40, -45, -30], max: [30, 45, 30])
        case .neck: JointLimit(min: [-45, -60, -35], max: [40, 60, 35])
        case .head: JointLimit(min: [-40, -70, -35], max: [40, 70, 35])
        case .rightClavicle, .leftClavicle: JointLimit(min: [-20, -20, -25], max: [20, 20, 25])
        case .rightUpperArm, .leftUpperArm: JointLimit(min: [-175, -100, -175], max: [80, 100, 175])
        case .rightForearm, .leftForearm: JointLimit(min: [-155, -90, -15], max: [10, 90, 15])
        case .rightHand, .leftHand: JointLimit(min: [-80, -60, -45], max: [80, 60, 45])
        case .rightThigh, .leftThigh: JointLimit(min: [-125, -45, -60], max: [45, 45, 60])
        case .rightShin, .leftShin: JointLimit(min: [-5, -10, -5], max: [155, 10, 5])
        case .rightFoot, .leftFoot: JointLimit(min: [-45, -30, -30], max: [45, 30, 30])
        case .rightToe, .leftToe: JointLimit(min: [-45, -5, -5], max: [45, 5, 5])
        default: JointLimit(min: [0, 0, 0], max: [0, 0, 0])
        }
    }

    static func build(_ estimate: JointEstimate) -> SkeletonDefinition {
        var joints: [RigJoint] = []
        for (tag, parent) in hierarchy {
            let world = estimate.positions[tag] ?? .zero
            let local = world - (parent.flatMap { estimate.positions[$0] } ?? .zero)
            joints.append(RigJoint(jointID: tag.rawValue, parentID: parent?.rawValue, restTransform: RigXform.translation(local).matrix,
                                   inverseBindMatrix: RigXform.identity.matrix, jointLimit: limit(tag), semanticTag: tag,
                                   confidence: estimate.confidence[tag] ?? 0.5))
        }
        var skeleton = SkeletonDefinition(joints: joints)
        skeleton.refreshBindMatrices()
        return skeleton
    }

    /// Moves one joint to a new model-space position (children stay put).
    static func moving(_ skeleton: SkeletonDefinition, joint: Int, to position: SIMD3<Float>) -> SkeletonDefinition {
        var world = skeleton.worldRest.map(\.origin)
        world[joint] = position
        var s = skeleton.withWorldOrigins(world)
        s.joints[joint].confidence = 1
        return s
    }

    /// Manual + automatic: joints the user placed (`locked`) stay; the
    /// others take the automatic positions; a joint between two placed
    /// joints on a limb is put between them in proportion; with `mirror`,
    /// an untouched joint copies its placed counterpart across the body.
    static func assisted(_ s: SkeletonDefinition, automatic: [JointTag: SIMD3<Float>], locked: Set<JointTag>, mirror: Bool) -> SkeletonDefinition {
        let world = s.worldRest.map(\.origin)
        var p: [JointTag: SIMD3<Float>] = [:]
        for (i, j) in s.joints.enumerated() { p[j.semanticTag] = world[i] }
        let original = p
        for tag in p.keys where !locked.contains(tag) { if let a = automatic[tag] { p[tag] = a } }
        var fixed = locked
        if mirror, let centre = p[.pelvis]?.x {
            for tag in locked { if let m = tag.mirror, !locked.contains(m), let q = p[tag] { p[m] = SIMD3(2 * centre - q.x, q.y, q.z); fixed.insert(m) } }
        }
        let chains: [[JointTag]] = [[.rightUpperArm, .rightForearm, .rightHand, .rightHandEnd], [.leftUpperArm, .leftForearm, .leftHand, .leftHandEnd],
                                    [.rightThigh, .rightShin, .rightFoot], [.leftThigh, .leftShin, .leftFoot], [.pelvis, .spine, .spine1, .chest, .neck]]
        for chain in chains {
            let anchors = chain.indices.filter { fixed.contains(chain[$0]) }
            for (a, b) in zip(anchors, anchors.dropFirst()) where b - a > 1 {
                // Keep the automatic (or original) spacing between the anchors.
                let ref = chain.map { automatic[$0] ?? original[$0] ?? .zero }
                var lengths: [Float] = [0]
                for k in (a + 1)...b { lengths.append(lengths.last! + rigLength(ref[k] - ref[k - 1])) }
                let total = max(1e-5, lengths.last!)
                guard let start = p[chain[a]], let end = p[chain[b]] else { continue }
                for k in (a + 1)..<b { p[chain[k]] = start + (end - start) * (lengths[k - a] / total) }
            }
        }
        var out = s.withWorldOrigins(s.joints.indices.map { p[s.joints[$0].semanticTag] ?? world[$0] })
        for i in out.joints.indices where fixed.contains(out.joints[i].semanticTag) { out.joints[i].confidence = 1 }
        do { try out.validate() } catch { return s }
        return out
    }

    /// Standard sockets for the skill editor.
    static func sockets(_ skeleton: SkeletonDefinition) -> [AttachmentSocket] {
        func offset(_ from: JointTag, _ to: JointTag, _ f: Float) -> [Float] {
            guard let a = skeleton.position(from), let b = skeleton.position(to) else { return [0, 0, 0] }
            let d = (b - a) * f
            return [d.x, d.y, d.z]
        }
        return [
            AttachmentSocket(kind: .rightHandWeapon, jointID: JointTag.rightHand.rawValue, offset: offset(.rightHand, .rightHandEnd, 0.6)),
            AttachmentSocket(kind: .leftHandShield, jointID: JointTag.leftHand.rawValue, offset: offset(.leftHand, .leftHandEnd, 0.4)),
            AttachmentSocket(kind: .back, jointID: JointTag.chest.rawValue, offset: [0, 0, -0.06]),
            AttachmentSocket(kind: .rightFoot, jointID: JointTag.rightFoot.rawValue, offset: offset(.rightFoot, .rightToe, 0.4).enumerated().map { $0.offset == 1 ? -0.04 : $0.element }),
            AttachmentSocket(kind: .leftFoot, jointID: JointTag.leftFoot.rawValue, offset: offset(.leftFoot, .leftToe, 0.4).enumerated().map { $0.offset == 1 ? -0.04 : $0.element }),
            AttachmentSocket(kind: .head, jointID: JointTag.headEnd.rawValue, offset: [0, 0.03, 0]),
        ]
    }
}

// MARK: Posing

/// Per-joint rotation (degrees, x / y / z about the joint) plus a root
/// offset (model units).
struct SkeletonPose: Equatable, Sendable {
    var rotations: [SIMD3<Float>]
    var rootOffset: SIMD3<Float> = .zero
    /// v1.76: full local transforms (keyframed clips from model files);
    /// when set, rotations and the root offset are not used.
    var locals: [RigXform]? = nil
    static func rest(_ skeleton: SkeletonDefinition) -> SkeletonPose { SkeletonPose(rotations: Array(repeating: .zero, count: skeleton.joints.count)) }

    /// Model-space joint transforms. Rotations turn each joint about its own
    /// rest frame (identity for the built-in skeletons).
    func world(_ skeleton: SkeletonDefinition) -> [RigXform] {
        if let locals, locals.count == skeleton.joints.count { return skeleton.worldTransforms(local: locals) }
        let deg: Float = .pi / 180
        let local = skeleton.joints.indices.map { i -> RigXform in
            var rest = skeleton.joints[i].rest
            if skeleton.joints[i].parentID == nil { rest.tx += rootOffset.x; rest.ty += rootOffset.y; rest.tz += rootOffset.z }
            return rest * RigXform.euler(rotations[i] * deg)
        }
        return skeleton.worldTransforms(local: local)
    }
    /// Skinning matrices: posed × inverse bind.
    func skinning(_ skeleton: SkeletonDefinition) -> [RigXform] {
        zip(world(skeleton), skeleton.joints).map { $0 * (RigXform(matrix: $1.inverseBindMatrix) ?? .identity) }
    }
}
