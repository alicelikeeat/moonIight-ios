import Foundation

// v1.90: every humanoid mesh made on the 3D modeling page (photo, video,
// text, multi-view, imports without a rig) borrows the base body's
// weights instead of having them guessed. The base body is given the
// mesh's proportions, posed onto the mesh's joints (A-pose, T-pose or
// anything in between), and each vertex of the mesh takes the weights of
// the base-body surface nearest to it, smoothed over the mesh. Pure Swift.

enum BaseBodyTransfer {
    /// The joint each bone points at (its direction comes from this pair).
    static let toward: [JointTag: JointTag] = [
        .pelvis: .spine, .spine: .spine1, .spine1: .chest, .chest: .neck, .neck: .head, .head: .headEnd,
        .rightClavicle: .rightUpperArm, .rightUpperArm: .rightForearm, .rightForearm: .rightHand, .rightHand: .rightHandEnd,
        .leftClavicle: .leftUpperArm, .leftUpperArm: .leftForearm, .leftForearm: .leftHand, .leftHand: .leftHandEnd,
        .rightThigh: .rightShin, .rightShin: .rightFoot, .rightFoot: .rightToe, .rightToe: .rightToeEnd,
        .leftThigh: .leftShin, .leftShin: .leftFoot, .leftFoot: .leftToe, .leftToe: .leftToeEnd,
    ]

    // MARK: Proportions

    /// The base body's shape from a body's joints (any pose: limb lengths
    /// are measured along the bones, heights only on the standing axis).
    static func shape(from p: [JointTag: SIMD3<Float>]) -> BodyShape? {
        guard let top = p[.headEnd], let head = p[.head], let rs = p[.rightUpperArm], let ls = p[.leftUpperArm],
              let rh = p[.rightThigh], let lh = p[.leftThigh] else { return nil }
        let toes = [p[.rightToeEnd], p[.leftToeEnd], p[.rightFoot], p[.leftFoot]].compactMap { $0?.y }
        guard let lowest = toes.min() else { return nil }
        let ground = lowest - 0.01 * (top.y - lowest)
        let h = top.y - ground
        guard h > 1e-4, h.isFinite else { return nil }
        var s = BodyShape()
        s.height = h
        s.headRatio = (top.y - head.y) / h + 0.015
        s.shoulderWidth = dist(rs, ls) / h
        s.hipWidth = dist(rh, lh) / h / 0.54
        s.legRatio = ((rh.y + lh.y) / 2 - ground) / h
        let arms = [("right"), ("left")].compactMap { side -> Float? in
            guard let a = p[JointTag(rawValue: side + "UpperArm") ?? .other], let b = p[JointTag(rawValue: side + "Forearm") ?? .other],
                  let c = p[JointTag(rawValue: side + "Hand") ?? .other], let d = p[JointTag(rawValue: side + "HandEnd") ?? .other] else { return nil }
            return dist(a, b) + dist(b, c) + dist(c, d)
        }
        if let arm = arms.max() { s.armRatio = arm / h }
        // The clamp keeps a very small mesh (the rig frame is about 1 tall) a body.
        var clamped = s.clamped
        clamped.height = h
        return clamped
    }

    // MARK: Posing the base body onto a skeleton

    /// The base body's vertices moved onto the target joints: each joint's
    /// bone turned to the target bone's direction and scaled to its length,
    /// blended by the base body's own weights.
    /// `size`: the target body's real height; the base body (built within
    /// its 0.8–2.4 m range) is scaled to it first, so a mesh in any unit fits.
    static func posedPositions(_ base: BaseBodyModel, onto target: [JointTag: SIMD3<Float>], size: Float? = nil) -> [Float] {
        let k = (size ?? base.shape.height) / max(1e-6, base.shape.height)
        let rest = BaseBody.joints(base.shape).mapValues { $0 * k }
        let parent = Dictionary(uniqueKeysWithValues: SkeletonBuilder.hierarchy.compactMap { child, parent in parent.map { (child, $0) } })
        var transforms: [JointTag: (pivot: SIMD3<Float>, to: SIMD3<Float>, rotation: Rot3, scale: Float)] = [:]
        for (tag, _) in SkeletonBuilder.hierarchy {
            guard let b = rest[tag] else { continue }
            let t = target[tag] ?? b
            if let child = toward[tag], let bc = rest[child], let tc = target[child], dist(bc, b) > 1e-5, dist(tc, t) > 1e-5 {
                let s = min(2.5, max(0.4, dist(tc, t) / dist(bc, b)))
                transforms[tag] = (b, t, Rot3.between(bc - b, tc - t), s)
            } else if let up = parent[tag], let p = transforms[up] {
                // A bone end: the parent's turn, around its own position.
                transforms[tag] = (b, t, p.rotation, p.scale)
            } else {
                transforms[tag] = (b, t, .identity, 1)
            }
        }
        let tags = base.skeleton.joints.map(\.semanticTag)
        var out = base.mesh.positions
        for v in 0..<base.mesh.vertexCount {
            let p = SIMD3(base.mesh.positions[v * 3], base.mesh.positions[v * 3 + 1], base.mesh.positions[v * 3 + 2]) * k
            var q = SIMD3<Float>.zero, total: Float = 0
            for k in 0..<4 {
                let j = Int(base.skin.joints[v * 4 + k]), w = base.skin.weights[v * 4 + k]
                guard j != 255, j < tags.count, w > 0, let x = transforms[tags[j]] else { continue }
                q += (x.to + x.rotation.apply(p - x.pivot) * x.scale) * w; total += w
            }
            if total > 0 { q /= total } else { q = p }
            out[v * 3] = q.x; out[v * 3 + 1] = q.y; out[v * 3 + 2] = q.z
        }
        return out
    }

    // MARK: Transfer

    /// Weights for `mesh` on `skeleton` (built by SkeletonBuilder from the
    /// same joints), borrowed from the base body posed onto those joints.
    /// nil when the joints do not describe a body.
    static func weights(for mesh: GeneratedMesh, skeleton: SkeletonDefinition, neighbours: Int = 4, smoothing: Int = 2) -> SkinInfluences? {
        let world = skeleton.worldRest.map(\.origin)
        var joints: [JointTag: SIMD3<Float>] = [:]
        for (i, joint) in skeleton.joints.enumerated() where joint.semanticTag != .other { joints[joint.semanticTag] = world[i] }
        guard mesh.vertexCount > 0, let shape = shape(from: joints) else { return nil }
        let base = BaseBody.build(shape)
        let posed = posedPositions(base, onto: joints, size: shape.height)
        let jointCount = skeleton.joints.count
        // Base joint index → the target skeleton's index for the same joint.
        let remap = base.skeleton.joints.map { skeleton.index($0.semanticTag) ?? -1 }
        let h = max(1e-4, shape.height), floor = (0.01 * h) * (0.01 * h)
        let baseCount = base.mesh.vertexCount
        var dense = [Float](repeating: 0, count: mesh.vertexCount * jointCount)
        var nearest = [(Float, Int)](repeating: (.infinity, -1), count: neighbours)
        for v in 0..<mesh.vertexCount {
            let p = SIMD3(mesh.positions[v * 3], mesh.positions[v * 3 + 1], mesh.positions[v * 3 + 2])
            for k in 0..<neighbours { nearest[k] = (.infinity, -1) }
            for b in 0..<baseCount {
                let dx = posed[b * 3] - p.x, dy = posed[b * 3 + 1] - p.y, dz = posed[b * 3 + 2] - p.z
                let d = dx * dx + dy * dy + dz * dz
                guard d < nearest[neighbours - 1].0 else { continue }
                var k = neighbours - 1
                while k > 0 && nearest[k - 1].0 > d { nearest[k] = nearest[k - 1]; k -= 1 }
                nearest[k] = (d, b)
            }
            for (d, b) in nearest where b >= 0 {
                let w = 1 / (d + floor)
                for k in 0..<4 {
                    let j = Int(base.skin.joints[b * 4 + k])
                    guard j != 255, j < remap.count, remap[j] >= 0 else { continue }
                    dense[v * jointCount + remap[j]] += w * base.skin.weights[b * 4 + k]
                }
            }
            normalise(&dense, v, jointCount)
        }
        // Smoothing over the mesh's edges: no hard seams where neighbours
        // found different parts of the base body.
        if smoothing > 0 {
            var links = [[Int32]](repeating: [], count: mesh.vertexCount)
            for t in 0..<mesh.triangleCount {
                let a = Int(mesh.indices[t * 3]), b = Int(mesh.indices[t * 3 + 1]), c = Int(mesh.indices[t * 3 + 2])
                links[a] += [Int32(b), Int32(c)]; links[b] += [Int32(a), Int32(c)]; links[c] += [Int32(a), Int32(b)]
            }
            for _ in 0..<smoothing {
                var next = dense
                for v in 0..<mesh.vertexCount where !links[v].isEmpty {
                    let share = 0.5 / Float(links[v].count)
                    for j in 0..<jointCount {
                        var sum: Float = 0
                        for n in links[v] { sum += dense[Int(n) * jointCount + j] }
                        next[v * jointCount + j] = dense[v * jointCount + j] * 0.5 + sum * share
                    }
                }
                dense = next
            }
        }
        // The four strongest joints per vertex, summing to 1.
        var skin = SkinInfluences(count: mesh.vertexCount)
        for v in 0..<mesh.vertexCount {
            let row = (0..<jointCount).map { (j: $0, w: dense[v * jointCount + $0]) }.filter { $0.w > 1e-4 && $0.w.isFinite }
                .sorted { $0.w > $1.w }.prefix(SkinInfluences.maxInfluences)
            let total = row.reduce(0) { $0 + $1.w }
            if total <= 0 {
                // Nothing near: the pelvis carries it (never a vertex without a joint).
                skin.joints[v * 4] = UInt8(skeleton.index(.pelvis) ?? 0); skin.weights[v * 4] = 1; continue
            }
            for (k, entry) in row.enumerated() { skin.joints[v * 4 + k] = UInt8(entry.j); skin.weights[v * 4 + k] = entry.w / total }
        }
        return skin
    }

    private static func normalise(_ dense: inout [Float], _ v: Int, _ count: Int) {
        var total: Float = 0
        for j in 0..<count { total += dense[v * count + j] }
        guard total > 0, total.isFinite else { return }
        for j in 0..<count { dense[v * count + j] /= total }
    }

    fileprivate static func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b; return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }
}

/// A 3 × 3 rotation (rows), small and Linux-friendly.
struct Rot3: Equatable, Sendable {
    var r0: SIMD3<Float>, r1: SIMD3<Float>, r2: SIMD3<Float>
    static let identity = Rot3(r0: SIMD3(1, 0, 0), r1: SIMD3(0, 1, 0), r2: SIMD3(0, 0, 1))

    func apply(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(r0.x * v.x + r0.y * v.y + r0.z * v.z, r1.x * v.x + r1.y * v.y + r1.z * v.z, r2.x * v.x + r2.y * v.y + r2.z * v.z)
    }

    /// The shortest turn taking direction `a` to direction `b`.
    static func between(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Rot3 {
        func unit(_ v: SIMD3<Float>) -> SIMD3<Float>? {
            let l = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
            return l > 1e-8 && l.isFinite ? v / l : nil
        }
        guard let u = unit(a), let w = unit(b) else { return .identity }
        let c = u.x * w.x + u.y * w.y + u.z * w.z
        let axis = SIMD3(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
        if c > 1 - 1e-6 { return .identity }
        if c < -1 + 1e-6 {
            // Opposite: half a turn about any axis at right angles to u.
            let side = abs(u.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            guard let k = unit(SIMD3(u.y * side.z - u.z * side.y, u.z * side.x - u.x * side.z, u.x * side.y - u.y * side.x)) else { return .identity }
            return rodrigues(k, sin: 0, cos: -1)
        }
        let s = (axis.x * axis.x + axis.y * axis.y + axis.z * axis.z).squareRoot()
        return rodrigues(axis / s, sin: s, cos: c)
    }

    private static func rodrigues(_ k: SIMD3<Float>, sin s: Float, cos c: Float) -> Rot3 {
        let t = 1 - c
        return Rot3(r0: SIMD3(c + k.x * k.x * t, k.x * k.y * t - k.z * s, k.x * k.z * t + k.y * s),
                    r1: SIMD3(k.y * k.x * t + k.z * s, c + k.y * k.y * t, k.y * k.z * t - k.x * s),
                    r2: SIMD3(k.z * k.x * t - k.y * s, k.z * k.y * t + k.x * s, c + k.z * k.z * t))
    }
}
