import Foundation

// v1.90: the universal base body. One parametric humanoid, built on the
// standard 27-joint skeleton, with a FIXED topology (the same vertices and
// triangles for every body shape) and weights that are authored, not
// guessed. Photos and videos only change its shape, paint it and give it
// motion; the rig, the weights and every library animation are known good.
//
// Conventions as the automatic rig: y up, the body faces +z, its right side
// is −x, A-pose (arms 45° down), feet on y = 0. Pure Swift (tested on Linux).

/// Proportions of a body, as ratios of its height (and girth multipliers),
/// so a fitted photo needs no real-world scale.
struct BodyShape: Codable, Equatable, Sendable {
    /// Metres, 0.8…2.4.
    var height: Float = 1.7
    /// Head (chin to top) / height: 0.11 adult … 0.2 chibi.
    var headRatio: Float = 0.13
    /// Shoulder joint to shoulder joint / height.
    var shoulderWidth: Float = 0.23
    /// Width at the hips / height.
    var hipWidth: Float = 0.19
    /// Hip joint height / height (leg length).
    var legRatio: Float = 0.48
    /// Shoulder to fingertip / height.
    var armRatio: Float = 0.44
    /// Girth multipliers, 0.7…1.5.
    var chest: Float = 1
    var waist: Float = 1
    var hips: Float = 1
    var limbs: Float = 1

    static let standard = BodyShape()

    var clamped: BodyShape {
        func c(_ v: Float, _ lo: Float, _ hi: Float, _ fallback: Float) -> Float { v.isFinite ? min(hi, max(lo, v)) : fallback }
        var s = self
        s.height = c(height, 0.8, 2.4, 1.7)
        s.headRatio = c(headRatio, 0.11, 0.2, 0.13)
        s.shoulderWidth = c(shoulderWidth, 0.17, 0.32, 0.23)
        s.hipWidth = c(hipWidth, 0.14, 0.28, 0.19)
        s.legRatio = c(legRatio, 0.38, 0.56, 0.48)
        s.armRatio = c(armRatio, 0.34, 0.5, 0.44)
        s.chest = c(chest, 0.7, 1.5, 1); s.waist = c(waist, 0.7, 1.5, 1); s.hips = c(hips, 0.7, 1.5, 1); s.limbs = c(limbs, 0.7, 1.5, 1)
        return s
    }
}

/// What a vertex of the base body is part of: the bone segment it sits on,
/// how far along it (0…1) and where around it (radians; 0 = the body's
/// right-hand side of the segment, π/2 = its front). Photos are projected
/// through this, so a fitted texture follows the body, not the mesh.
struct BaseBodyVertex: Equatable, Sendable {
    var from: JointTag
    var to: JointTag
    var along: Float
    var angle: Float
    /// The vertex faces the camera side (+z) of the body.
    var front: Bool
}

struct BaseBodyModel: Sendable {
    var shape: BodyShape
    var skeleton: SkeletonDefinition
    var mesh: GeneratedMesh
    var skin: SkinInfluences
    var vertices: [BaseBodyVertex]
}

enum BaseBody {
    /// Vertices around every ring.
    static let ringSides = 16

    // MARK: Joints

    /// Joint positions for a shape (model space, metres).
    static func joints(_ raw: BodyShape) -> [JointTag: SIMD3<Float>] {
        let s = raw.clamped, h = s.height
        let headLength = s.headRatio * h
        let chin = h - headLength
        let shoulderY = chin - 0.06 * h
        let hipY = s.legRatio * h
        let halfShoulder = s.shoulderWidth * h / 2
        let hipJointX = s.hipWidth * h * 0.27
        var p: [JointTag: SIMD3<Float>] = [:]
        p[.pelvis] = SIMD3(0, hipY + 0.02 * h, 0)
        let torso = shoulderY - (hipY + 0.02 * h)
        p[.spine] = SIMD3(0, hipY + 0.02 * h + torso * 0.3, 0)
        p[.spine1] = SIMD3(0, hipY + 0.02 * h + torso * 0.55, 0)
        p[.chest] = SIMD3(0, hipY + 0.02 * h + torso * 0.8, 0)
        p[.neck] = SIMD3(0, shoulderY + 0.025 * h, 0)
        p[.head] = SIMD3(0, chin + 0.015 * h, 0.005 * h)
        p[.headEnd] = SIMD3(0, h, 0.005 * h)
        // Arms in an A-pose: 45° down and out from the shoulders.
        let arm = s.armRatio * h
        for (side, prefix) in [(Float(-1), "right"), (Float(1), "left")] {
            let shoulder = SIMD3<Float>(side * halfShoulder, shoulderY, 0)
            let down = SIMD3<Float>(side * 0.7071, -0.7071, 0)
            let elbow = shoulder + down * (arm * 0.43)
            let wrist = elbow + down * (arm * 0.39)
            let tip = wrist + down * (arm * 0.18)
            p[tag(prefix, "Clavicle")] = SIMD3(side * 0.035 * h, shoulderY + 0.005 * h, 0.01 * h)
            p[tag(prefix, "UpperArm")] = shoulder
            p[tag(prefix, "Forearm")] = elbow
            p[tag(prefix, "Hand")] = wrist
            p[tag(prefix, "HandEnd")] = tip
            let hip = SIMD3<Float>(side * hipJointX, hipY, 0)
            let ankleY = 0.045 * h
            let knee = SIMD3<Float>(side * hipJointX * 0.95, ankleY + (hipY - ankleY) * 0.49, 0.005 * h)
            let ankle = SIMD3<Float>(side * hipJointX * 0.9, ankleY, -0.01 * h)
            let foot = 0.15 * h
            p[tag(prefix, "Thigh")] = hip
            p[tag(prefix, "Shin")] = knee
            p[tag(prefix, "Foot")] = ankle
            p[tag(prefix, "Toe")] = SIMD3(ankle.x, 0.015 * h, ankle.z + foot * 0.68)
            p[tag(prefix, "ToeEnd")] = SIMD3(ankle.x, 0.01 * h, ankle.z + foot * 0.92)
        }
        return p
    }

    private static func tag(_ prefix: String, _ name: String) -> JointTag { JointTag(rawValue: prefix + name) ?? .other }

    static func skeleton(_ shape: BodyShape) -> SkeletonDefinition {
        let positions = joints(shape)
        let estimate = JointEstimate(positions: positions, confidence: positions.mapValues { _ in 1 }, pose: .aPose, humanoid: 1, notes: [])
        return SkeletonBuilder.build(estimate)
    }

    // MARK: Body

    /// One ring: centre, axis it faces along, the two radii (across the
    /// body's sides / front-to-back), and the joints it follows.
    private struct Ring {
        var center: SIMD3<Float>
        var radius: SIMD2<Float>
        var weights: [(JointTag, Float)]
        var along: Float
    }
    private struct Tube {
        var from: JointTag
        var to: JointTag
        var axis: SIMD3<Float>
        var rings: [Ring]
        var capStart: Bool
        var capEnd: Bool
    }

    /// The whole model for a shape. The same vertex and triangle order for
    /// every shape, so weights, UV layout and saved edits carry over.
    static func build(_ raw: BodyShape) -> BaseBodyModel {
        let s = raw.clamped, h = s.height
        let p = joints(s)
        func at(_ t: JointTag) -> SIMD3<Float> { p[t] ?? .zero }
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        var tubes: [Tube] = []

        // Torso: crotch to the base of the neck, along +y.
        let pelvis = at(.pelvis), neck = at(.neck), shoulderY = at(.rightUpperArm).y
        let hipHalf = s.hipWidth * h * 0.5 * s.hips, shoulderHalf = s.shoulderWidth * h * 0.5
        let crotchY = at(.rightThigh).y - 0.03 * h
        let torsoLevels: [(Float, Float, Float, [(JointTag, Float)])] = [
            (crotchY, hipHalf * 0.72, 0.6, [(.pelvis, 1)]),
            (at(.rightThigh).y, hipHalf, 0.62, [(.pelvis, 1)]),
            (pelvis.y + (at(.spine).y - pelvis.y) * 0.6, hipHalf * 0.96, 0.6, [(.pelvis, 0.5), (.spine, 0.5)]),
            (at(.spine1).y, shoulderHalf * 0.74 * s.waist, 0.62, [(.spine, 0.5), (.spine1, 0.5)]),
            (mix(at(.spine1), at(.chest), 0.5).y, shoulderHalf * 0.86 * s.chest, 0.64, [(.spine1, 0.5), (.chest, 0.5)]),
            (at(.chest).y, shoulderHalf * 0.98 * s.chest, 0.62, [(.chest, 1)]),
            (shoulderY, shoulderHalf * 1.02, 0.5, [(.chest, 1)]),
            (neck.y - 0.005 * h, 0.06 * h, 0.75, [(.chest, 0.5), (.neck, 0.5)]),
        ]
        tubes.append(Tube(from: .pelvis, to: .neck, axis: SIMD3(0, 1, 0), rings: torsoLevels.enumerated().map { i, level in
            Ring(center: SIMD3(0, level.0, 0), radius: SIMD2(level.1, level.1 * level.2), weights: level.3, along: Float(i) / Float(torsoLevels.count - 1))
        }, capStart: true, capEnd: false))

        // Neck and head along +y.
        let neckRadius = 0.033 * h
        tubes.append(Tube(from: .neck, to: .head, axis: SIMD3(0, 1, 0), rings: [
            Ring(center: SIMD3(0, neck.y - 0.01 * h, 0), radius: SIMD2(neckRadius, neckRadius * 0.95), weights: [(.neck, 1)], along: 0),
            Ring(center: SIMD3(0, at(.head).y, 0.003 * h), radius: SIMD2(neckRadius * 0.92, neckRadius * 0.9), weights: [(.neck, 0.5), (.head, 0.5)], along: 1),
        ], capStart: false, capEnd: false))
        let headLength = s.headRatio * h, chin = h - headLength
        let headLevels: [Float] = [0.0, 0.12, 0.3, 0.5, 0.7, 0.86, 0.96]
        tubes.append(Tube(from: .head, to: .headEnd, axis: SIMD3(0, 1, 0), rings: headLevels.enumerated().map { i, f in
            // An egg: widest a little above the middle, rounded at both ends.
            let bulge = sin(Float.pi * min(1, max(0.08, f * 1.05)))
            let width = headLength * 0.42 * (0.55 + 0.45 * bulge)
            return Ring(center: SIMD3(0, chin + headLength * f, 0.012 * h), radius: SIMD2(width, width * 1.08),
                        weights: i == 0 ? [(.head, 0.7), (.neck, 0.3)] : [(.head, 1)], along: Float(i) / Float(headLevels.count - 1))
        }, capStart: true, capEnd: true))

        // Arms and hands, legs and feet, right then left.
        let limb = s.limbs
        for prefix in ["right", "left"] {
            let shoulder = at(tag(prefix, "UpperArm")), elbow = at(tag(prefix, "Forearm")), wrist = at(tag(prefix, "Hand")), tip = at(tag(prefix, "HandEnd"))
            let upper = 0.045 * h * limb, fore = 0.036 * h * limb, wristR = 0.026 * h * limb
            let armAxis = simd_normalize_safe(wrist - shoulder)
            tubes.append(Tube(from: tag(prefix, "UpperArm"), to: tag(prefix, "Hand"), axis: armAxis, rings: [
                Ring(center: shoulder - armAxis * (0.01 * h), radius: SIMD2(upper * 1.1, upper * 1.1), weights: [(tag(prefix, "UpperArm"), 0.6), (tag(prefix, "Clavicle"), 0.4)], along: 0),
                Ring(center: mix(shoulder, elbow, 0.5), radius: SIMD2(upper, upper * 0.95), weights: [(tag(prefix, "UpperArm"), 1)], along: 0.25),
                Ring(center: mix(shoulder, elbow, 0.9), radius: SIMD2(upper * 0.86, upper * 0.84), weights: [(tag(prefix, "UpperArm"), 0.65), (tag(prefix, "Forearm"), 0.35)], along: 0.45),
                Ring(center: mix(elbow, wrist, 0.1), radius: SIMD2(fore * 1.02, fore), weights: [(tag(prefix, "Forearm"), 0.65), (tag(prefix, "UpperArm"), 0.35)], along: 0.55),
                Ring(center: mix(elbow, wrist, 0.5), radius: SIMD2(fore, fore * 0.92), weights: [(tag(prefix, "Forearm"), 1)], along: 0.75),
                Ring(center: wrist, radius: SIMD2(wristR, wristR * 0.8), weights: [(tag(prefix, "Forearm"), 0.5), (tag(prefix, "Hand"), 0.5)], along: 1),
            ], capStart: false, capEnd: false))
            let handAxis = simd_normalize_safe(tip - wrist)
            tubes.append(Tube(from: tag(prefix, "Hand"), to: tag(prefix, "HandEnd"), axis: handAxis, rings: [
                Ring(center: mix(wrist, tip, 0.15), radius: SIMD2(wristR * 1.25, wristR * 0.6), weights: [(tag(prefix, "Hand"), 1)], along: 0),
                Ring(center: mix(wrist, tip, 0.6), radius: SIMD2(wristR * 1.3, wristR * 0.5), weights: [(tag(prefix, "Hand"), 1)], along: 0.6),
                Ring(center: mix(wrist, tip, 0.95), radius: SIMD2(wristR * 0.8, wristR * 0.4), weights: [(tag(prefix, "Hand"), 1)], along: 1),
            ], capStart: false, capEnd: true))

            let hip = at(tag(prefix, "Thigh")), knee = at(tag(prefix, "Shin")), ankle = at(tag(prefix, "Foot"))
            let thigh = s.hipWidth * h * 0.3 * s.hips * limb, shin = 0.042 * h * limb, ankleR = 0.028 * h * limb
            let legAxis = simd_normalize_safe(ankle - hip)
            tubes.append(Tube(from: tag(prefix, "Thigh"), to: tag(prefix, "Foot"), axis: legAxis, rings: [
                Ring(center: hip + SIMD3(0, 0.015 * h, 0), radius: SIMD2(thigh * 1.05, thigh), weights: [(tag(prefix, "Thigh"), 0.5), (.pelvis, 0.5)], along: 0),
                Ring(center: mix(hip, knee, 0.45), radius: SIMD2(thigh * 0.88, thigh * 0.86), weights: [(tag(prefix, "Thigh"), 1)], along: 0.25),
                Ring(center: mix(hip, knee, 0.9), radius: SIMD2(shin * 1.1, shin * 1.05), weights: [(tag(prefix, "Thigh"), 0.65), (tag(prefix, "Shin"), 0.35)], along: 0.45),
                Ring(center: mix(knee, ankle, 0.1), radius: SIMD2(shin * 1.05, shin * 1.05), weights: [(tag(prefix, "Shin"), 0.65), (tag(prefix, "Thigh"), 0.35)], along: 0.55),
                Ring(center: mix(knee, ankle, 0.45), radius: SIMD2(shin, shin * 1.08), weights: [(tag(prefix, "Shin"), 1)], along: 0.75),
                Ring(center: ankle + SIMD3(0, 0.01 * h, 0), radius: SIMD2(ankleR, ankleR), weights: [(tag(prefix, "Shin"), 0.5), (tag(prefix, "Foot"), 0.5)], along: 1),
            ], capStart: false, capEnd: false))
            // Foot: heel to toes along +z. Along +z the ring's first radius is
            // vertical (u = −y) and the second across the foot (w = +x).
            let toe = at(tag(prefix, "Toe")), toeEnd = at(tag(prefix, "ToeEnd"))
            let footY = 0.03 * h, footW = 0.034 * h * limb
            tubes.append(Tube(from: tag(prefix, "Foot"), to: tag(prefix, "ToeEnd"), axis: SIMD3(0, 0, 1), rings: [
                Ring(center: SIMD3(ankle.x, footY, ankle.z - 0.03 * h), radius: SIMD2(footY * 0.95, footW * 0.8), weights: [(tag(prefix, "Foot"), 1)], along: 0),
                Ring(center: SIMD3(ankle.x, footY, ankle.z + 0.02 * h), radius: SIMD2(footY, footW), weights: [(tag(prefix, "Foot"), 1)], along: 0.35),
                Ring(center: SIMD3(toe.x, footY * 0.8, toe.z), radius: SIMD2(footY * 0.75, footW * 1.05), weights: [(tag(prefix, "Foot"), 0.5), (tag(prefix, "Toe"), 0.5)], along: 0.7),
                Ring(center: SIMD3(toeEnd.x, footY * 0.6, toeEnd.z), radius: SIMD2(footY * 0.5, footW * 0.8), weights: [(tag(prefix, "Toe"), 1)], along: 1),
            ], capStart: true, capEnd: true))
        }

        let skeleton = skeleton(s)
        return assemble(tubes, skeleton: skeleton, height: h, shape: s)
    }

    // MARK: Assembly

    private static func simd_normalize_safe(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return l > 1e-6 && l.isFinite ? v / l : SIMD3(0, 1, 0)
    }
    private static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    private static func assemble(_ tubes: [Tube], skeleton: SkeletonDefinition, height: Float, shape: BodyShape) -> BaseBodyModel {
        var positions: [Float] = [], uvs: [Float] = [], indices: [UInt32] = [], joints: [UInt8] = [], weights: [Float] = []
        var info: [BaseBodyVertex] = []
        let n = ringSides
        func addVertex(_ p: SIMD3<Float>, _ w: [(JointTag, Float)], _ v: BaseBodyVertex, u: Float) {
            positions += [p.x, p.y, p.z]
            uvs += [u, min(1, max(0, p.y / height))]
            let total = max(1e-6, w.reduce(0) { $0 + $1.1 })
            var slots: [(UInt8, Float)] = w.prefix(SkinInfluences.maxInfluences).map { (UInt8(skeleton.index($0.0) ?? 0), $0.1 / total) }
            while slots.count < SkinInfluences.maxInfluences { slots.append((255, 0)) }
            for slot in slots { joints.append(slot.0); weights.append(slot.1) }
            info.append(v)
        }
        for tube in tubes {
            let d = tube.axis
            // Across the body's sides (u) and front-to-back (w): u ⟂ d, w = d × u.
            let reference: SIMD3<Float> = abs(d.z) > 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1)
            let u = simd_normalize_safe(cross(reference, d)), w = cross(d, u)
            let base = UInt32(positions.count / 3)
            for ring in tube.rings {
                for i in 0..<n {
                    let a = Float(i) / Float(n) * 2 * .pi
                    let point = ring.center + u * (cos(a) * ring.radius.x) + w * (sin(a) * ring.radius.y)
                    let front = (point.z - ring.center.z) > 1e-5 || (abs(d.z) > 0.9 && point.y > ring.center.y)
                    addVertex(point, ring.weights, BaseBodyVertex(from: tube.from, to: tube.to, along: ring.along, angle: a, front: front), u: Float(i) / Float(n))
                }
            }
            for r in 0..<(tube.rings.count - 1) {
                for i in 0..<n {
                    let a = base + UInt32(r * n + i), b = base + UInt32(r * n + (i + 1) % n)
                    let c = base + UInt32((r + 1) * n + (i + 1) % n), e = base + UInt32((r + 1) * n + i)
                    indices += [a, b, e, b, c, e]
                }
            }
            if tube.capStart, let first = tube.rings.first {
                let center = UInt32(positions.count / 3)
                addVertex(first.center - d * (min(first.radius.x, first.radius.y) * 0.35), first.weights,
                          BaseBodyVertex(from: tube.from, to: tube.to, along: 0, angle: 0, front: false), u: 0.5)
                for i in 0..<n { indices += [center, base + UInt32((i + 1) % n), base + UInt32(i)] }
            }
            if tube.capEnd, let last = tube.rings.last {
                let center = UInt32(positions.count / 3), ring0 = base + UInt32((tube.rings.count - 1) * n)
                addVertex(last.center + d * (min(last.radius.x, last.radius.y) * 0.35), last.weights,
                          BaseBodyVertex(from: tube.from, to: tube.to, along: 1, angle: 0, front: false), u: 0.5)
                for i in 0..<n { indices += [center, ring0 + UInt32(i), ring0 + UInt32((i + 1) % n)] }
            }
        }
        var mesh = GeneratedMesh(positions: positions, normals: [], uvs: uvs, indices: indices)
        mesh.normals = smoothNormals(mesh)
        return BaseBodyModel(shape: shape, skeleton: skeleton, mesh: mesh, skin: SkinInfluences(joints: joints, weights: weights), vertices: info)
    }

    /// Area-weighted vertex normals; a vertex with no area gets (0, 1, 0).
    static func smoothNormals(_ mesh: GeneratedMesh) -> [Float] {
        var normals = [Float](repeating: 0, count: mesh.positions.count)
        func v(_ i: UInt32) -> SIMD3<Float> { let k = Int(i) * 3; return SIMD3(mesh.positions[k], mesh.positions[k + 1], mesh.positions[k + 2]) }
        for t in 0..<mesh.triangleCount {
            let a = mesh.indices[t * 3], b = mesh.indices[t * 3 + 1], c = mesh.indices[t * 3 + 2]
            let n = cross(v(b) - v(a), v(c) - v(a))
            for i in [a, b, c] { let k = Int(i) * 3; normals[k] += n.x; normals[k + 1] += n.y; normals[k + 2] += n.z }
        }
        for i in 0..<mesh.vertexCount {
            let k = i * 3, l = (normals[k] * normals[k] + normals[k + 1] * normals[k + 1] + normals[k + 2] * normals[k + 2]).squareRoot()
            if l > 1e-9 && l.isFinite { normals[k] /= l; normals[k + 1] /= l; normals[k + 2] /= l } else { normals[k] = 0; normals[k + 1] = 1; normals[k + 2] = 0 }
        }
        return normals
    }
}
