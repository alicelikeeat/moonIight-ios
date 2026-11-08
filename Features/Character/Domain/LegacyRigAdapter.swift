import Foundation

// v1.91: older rigs through the one skeleton interface, without touching
// their files. The P2 ten-bone rig (RigPackage + two-bone SkinWeights) is
// mapped onto the standard 27 joints: the bones it has are "legacyMapped",
// the joints it never had (spine segments, clavicles, hand / toe ends) are
// placed by rule and marked "inferred" with zero confidence, so a filled-in
// joint never passes for a recognised one. At rest the converted rig
// deforms the mesh exactly like the original (both are the bind pose), and
// its clips convert with MotionAdapters. v1.73 27-joint rigs already use
// SkeletonDefinition; they only gain a source mark when it is missing.

struct LegacyConversion: Sendable {
    var skeleton: SkeletonDefinition
    var skin: SkinInfluences
    var motions: [UniversalMotion]
    /// Joints placed by rule (not in the old rig).
    var inferred: [String]
    var notes: [String]
}

enum LegacyRigAdapter {
    static func convert(_ package: RigPackage, skin: SkinWeights, vertexCount: Int) -> LegacyConversion? {
        guard skin.valid, skin.count == vertexCount, vertexCount > 0 else { return nil }
        func head(_ b: RigBone) -> SIMD3<Float>? { package.skeleton.bone(b).flatMap { $0.head.count == 3 ? SIMD3($0.head[0], $0.head[1], $0.head[2]) : nil } }
        func tail(_ b: RigBone) -> SIMD3<Float>? { package.skeleton.bone(b).flatMap { $0.tail.count == 3 ? SIMD3($0.tail[0], $0.tail[1], $0.tail[2]) : nil } }
        guard let pelvis = head(.torso), let neck = tail(.torso), let skull = head(.head), let crown = tail(.head),
              let rs = head(.rightUpperArm), let re = head(.rightForearm), let rw = tail(.rightForearm),
              let ls = head(.leftUpperArm), let le = head(.leftForearm), let lw = tail(.leftForearm),
              let rh = head(.rightThigh), let rk = head(.rightShin), let ra = tail(.rightShin),
              let lh = head(.leftThigh), let lk = head(.leftShin), let la = tail(.leftShin) else { return nil }
        guard [pelvis, neck, skull, crown, rs, re, rw, ls, le, lw, rh, rk, ra, lh, lk, la].allSatisfy(cFinite) else { return nil }
        var p: [JointTag: SIMD3<Float>] = [:]
        let mapped: Set<JointTag> = [.pelvis, .neck, .head, .headEnd, .rightUpperArm, .rightForearm, .rightHand, .leftUpperArm, .leftForearm, .leftHand,
                                     .rightThigh, .rightShin, .rightFoot, .leftThigh, .leftShin, .leftFoot]
        p[.pelvis] = pelvis; p[.neck] = neck; p[.head] = skull; p[.headEnd] = crown
        p[.rightUpperArm] = rs; p[.rightForearm] = re; p[.rightHand] = rw
        p[.leftUpperArm] = ls; p[.leftForearm] = le; p[.leftHand] = lw
        p[.rightThigh] = rh; p[.rightShin] = rk; p[.rightFoot] = ra
        p[.leftThigh] = lh; p[.leftShin] = lk; p[.leftFoot] = la
        // Inferred by rule.
        let torso = neck - pelvis
        p[.spine] = pelvis + torso * 0.25; p[.spine1] = pelvis + torso * 0.5; p[.chest] = pelvis + torso * 0.75
        p[.rightClavicle] = neck + (rs - neck) * 0.25; p[.leftClavicle] = neck + (ls - neck) * 0.25
        p[.rightHandEnd] = rw + (rw - re) * 0.4; p[.leftHandEnd] = lw + (lw - le) * 0.4
        let footLength = cLength(rk - ra) * 0.3
        p[.rightToe] = ra + SIMD3(0, 0, footLength * 0.7); p[.rightToeEnd] = ra + SIMD3(0, 0, footLength)
        p[.leftToe] = la + SIMD3(0, 0, footLength * 0.7); p[.leftToeEnd] = la + SIMD3(0, 0, footLength)
        let confidence = package.joints.points.values.map { Float($0.confidence) }
        let mean = confidence.isEmpty ? 0.5 : confidence.reduce(0, +) / Float(confidence.count)
        var skeleton = SkeletonBuilder.build(JointEstimate(positions: p, confidence: p.mapValues { _ in mean }, pose: .unknown, humanoid: 1, notes: []))
        var inferred: [String] = []
        for i in skeleton.joints.indices {
            let tag = skeleton.joints[i].semanticTag
            if mapped.contains(tag) { skeleton.joints[i].source = .legacyMapped }
            else { skeleton.joints[i].source = .inferred; skeleton.joints[i].confidence = 0; inferred.append(skeleton.joints[i].jointID) }
        }
        // Weights: the two old bones per vertex onto their standard joints.
        var joints: [UInt8] = [], weights: [Float] = []
        joints.reserveCapacity(vertexCount * 4); weights.reserveCapacity(vertexCount * 4)
        for v in 0..<vertexCount {
            let b0 = RigBone(rawValue: Int(skin.bone0[v])), b1 = RigBone(rawValue: Int(skin.bone1[v]))
            let j0 = b0.flatMap { skeleton.index(MotionAdapters.joint(for: $0)) }, j1 = b1.flatMap { skeleton.index(MotionAdapters.joint(for: $0)) }
            let w0 = skin.weight0[v]
            var slots: [(UInt8, Float)] = []
            if let j0 { slots.append((UInt8(j0), w0)) }
            if let j1, 1 - w0 > 0 {
                if let k = slots.firstIndex(where: { $0.0 == UInt8(j1) }) { slots[k].1 += 1 - w0 } else { slots.append((UInt8(j1), 1 - w0)) }
            }
            let total = slots.reduce(0) { $0 + $1.1 }
            if slots.isEmpty || total <= 1e-6 { slots = [(UInt8(skeleton.index(.pelvis) ?? 0), 1)] }
            else { slots = slots.map { ($0.0, $0.1 / total) } }
            while slots.count < 4 { slots.append((255, 0)) }
            for s in slots { joints.append(s.0); weights.append(s.1) }
        }
        let motions = package.clips.map { MotionAdapters.from($0) }
        let notes = [L10n.t("旧版 10 骨骼角色已映射到标准骨骼：\(16) 个关节来自原骨骼，\(inferred.count) 个按规则补齐（标记为推断）。原文件未改动。",
                            "Old ten-bone character mapped to the standard skeleton: 16 joints from the original, \(inferred.count) placed by rule (marked inferred). The original files are unchanged.")]
        return LegacyConversion(skeleton: skeleton, skin: SkinInfluences(joints: joints, weights: weights), motions: motions, inferred: inferred, notes: notes)
    }

    /// A v1.73 rig in the unified form: joints without a source become "estimated".
    static func upgrade(_ character: RiggedCharacter) -> SkeletonDefinition {
        var s = character.skeleton
        for i in s.joints.indices where s.joints[i].source == nil { s.joints[i].source = .estimated }
        return s
    }
}
