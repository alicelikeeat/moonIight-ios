import Foundation

// v1.73 M02 level 1: humanoid joints from the 3D mesh itself (not from a
// 2D picture pose). The mesh, in the rig frame (feet at y = 0, height 1,
// centred), is cut into horizontal slices; each slice splits into pieces
// along x. Two pieces at the bottom are legs, pieces outside the torso are
// arms, the narrowest slice under the head is the neck. Joints sit at the
// centre of each cross-section, so they are inside the body in depth too.
// A very wide band at shoulder height means arms held out (T / A pose).

struct JointEstimate: Equatable, Sendable {
    var positions: [JointTag: SIMD3<Float>]
    var confidence: [JointTag: Float]
    var pose: MeshAnalysis.PoseType
    /// Whole-body humanoid confidence 0…1.
    var humanoid: Float
    var notes: [String]
}

enum JointEstimator {
    struct Piece: Equatable { var minX: Float; var maxX: Float; var x: Float; var z: Float; var count: Int; var minZ: Float; var maxZ: Float }
    struct Slice { var y: Float; var pieces: [Piece] }

    static let sliceCount = 64

    /// Where the plane `axis = value` cuts the surface: intervals along
    /// `along`, each with the depth range (third axis) of its cut points.
    static func section(_ mesh: GeneratedMesh, axis: Int, value: Float, along: Int, tolerance: Float) -> [Piece] {
        let depth = 3 - axis - along
        var spans: [(lo: Float, hi: Float, zlo: Float, zhi: Float)] = []
        let p = mesh.positions
        for t in 0..<mesh.triangleCount {
            let i = [Int(mesh.indices[t * 3]), Int(mesh.indices[t * 3 + 1]), Int(mesh.indices[t * 3 + 2])]
            let h = i.map { p[$0 * 3 + axis] - value }
            if (h[0] > 0 && h[1] > 0 && h[2] > 0) || (h[0] < 0 && h[1] < 0 && h[2] < 0) { continue }
            var a: [Float] = [], d: [Float] = []
            for (u, v) in [(0, 1), (1, 2), (2, 0)] where (h[u] <= 0) != (h[v] <= 0) || h[u] == 0 {
                let f = h[u] == h[v] ? 0 : h[u] / (h[u] - h[v])
                a.append(p[i[u] * 3 + along] + (p[i[v] * 3 + along] - p[i[u] * 3 + along]) * f)
                d.append(p[i[u] * 3 + depth] + (p[i[v] * 3 + depth] - p[i[u] * 3 + depth]) * f)
            }
            guard let lo = a.min(), let hi = a.max(), let zl = d.min(), let zh = d.max() else { continue }
            spans.append((lo, hi, zl, zh))
        }
        spans.sort { $0.lo < $1.lo }
        var pieces: [Piece] = []
        for s in spans {
            if var last = pieces.last, s.lo <= last.maxX + tolerance {
                last.maxX = max(last.maxX, s.hi); last.minZ = min(last.minZ, s.zlo); last.maxZ = max(last.maxZ, s.zhi); last.count += 1
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(Piece(minX: s.lo, maxX: s.hi, x: 0, z: 0, count: 1, minZ: s.zlo, maxZ: s.zhi))
            }
        }
        return pieces.map { var q = $0; q.x = (q.minX + q.maxX) / 2; q.z = (q.minZ + q.maxZ) / 2; return q }
    }

    /// Horizontal cross-sections, bottom to top.
    static func slices(_ mesh: GeneratedMesh, gap: Float) -> [Slice] {
        (0..<sliceCount).map { s in
            let y = (Float(s) + 0.5) / Float(sliceCount)
            return Slice(y: y, pieces: section(mesh, axis: 1, value: y, along: 0, tolerance: gap))
        }
    }

    /// Pieces closer than this merge (1% of height; parts of a body are
    /// separated by visible gaps).
    static func gap(for mesh: GeneratedMesh, meanEdge: Float) -> Float { 0.004 }

    static func estimate(_ mesh: GeneratedMesh, meanEdge: Float) -> JointEstimate {
        let s = slices(mesh, gap: gap(for: mesh, meanEdge: meanEdge))
        var notes: [String] = []
        var conf: [JointTag: Float] = [:]
        var p: [JointTag: SIMD3<Float>] = [:]
        let n = s.count
        func sliceIndex(_ y: Float) -> Int { min(n - 1, max(0, Int(y * Float(n)))) }
        func main(_ slice: Slice) -> Piece? {
            // Piece nearest the centre line, the biggest when tied.
            slice.pieces.min { abs($0.x) - Float($0.count) * 1e-6 < abs($1.x) - Float($1.count) * 1e-6 }
        }

        // Legs: from the bottom, slices where pieces sit on both sides of x = 0.
        func legsSplit(_ slice: Slice) -> (Piece, Piece)? {
            // Nothing may cross the centre line (that would be the torso).
            if slice.pieces.contains(where: { $0.minX < -0.004 && $0.maxX > 0.004 }) { return nil }
            let right = slice.pieces.filter { $0.maxX < 0 }, left = slice.pieces.filter { $0.minX > 0 }
            guard let r = right.max(by: { $0.maxX < $1.maxX }), let l = left.min(by: { $0.minX < $1.minX }) else { return nil }
            return (r, l)
        }
        var crotch: Float = 0.47, legsFound = false
        var rightLeg: [(Float, Piece)] = [], leftLeg: [(Float, Piece)] = []
        var i = 0
        while i < n && s[i].pieces.isEmpty { i += 1 }
        let bottom = i
        while i < n * 7 / 10, let pair = legsSplit(s[i]) { rightLeg.append((s[i].y, pair.0)); leftLeg.append((s[i].y, pair.1)); i += 1 }
        if i - bottom >= n / 6 { crotch = Float(i) / Float(n); legsFound = true }
        else { notes.append(L10n.t("没有找到分开的双腿，按比例估计", "Legs not separated; estimated from proportions")); rightLeg = []; leftLeg = [] }

        // Torso width a little above the crotch.
        let waist = main(s[sliceIndex(crotch + 0.12)])
        let torsoMin = waist?.minX ?? -0.12, torsoMax = waist?.maxX ?? 0.12, torsoWidth = max(0.05, torsoMax - torsoMin)

        // Arms held out: a band much wider than the torso above the waist.
        var pose = MeshAnalysis.PoseType.unknown
        var outBand: [Int] = []
        for k in sliceIndex(crotch + 0.15)..<sliceIndex(0.92) {
            let width = (s[k].pieces.map(\.maxX).max() ?? 0) - (s[k].pieces.map(\.minX).min() ?? 0)
            if width > torsoWidth * 2.4 { outBand.append(k) }
        }
        var rightArm: [SIMD3<Float>] = [], leftArm: [SIMD3<Float>] = []
        var armpit: Float = 0
        if !outBand.isEmpty {
            // Arms out: walk outwards along x inside the wide band.
            let lo = s[outBand.first!].y - 0.5 / Float(n), hi = s[outBand.last!].y + 0.5 / Float(n)
            let step: Float = 0.015
            var x = torsoMax + 0.01
            let reach = (s[outBand.first!].pieces.map(\.maxX).max() ?? 0.5)
            while x < reach + step {
                for side: Float in [-1, 1] {
                    let cut = section(mesh, axis: 0, value: side * x, along: 1, tolerance: 0.004)
                        .filter { $0.maxX >= lo - 0.1 && $0.minX <= hi + 0.03 }
                    guard let piece = cut.max(by: { $0.count < $1.count }) else { continue }
                    let c = SIMD3(side * x, piece.x, piece.z)
                    if side < 0 { rightArm.append(c) } else { leftArm.append(c) }
                }
                x += step
            }
            // Ordered shoulder → hand.
            rightArm.sort { $0.x > $1.x }; leftArm.sort { $0.x < $1.x }
            armpit = lo
            let drop = (rightArm.last.map { $0.y } ?? lo)
            pose = drop < lo - 0.04 ? .aPose : .tPose
        } else {
            // Arms down: pieces outside the torso, above the crotch (and
            // the outermost ones below it, beside the legs).
            var top = -1
            for k in bottom..<sliceIndex(0.95) {
                let pieces = s[k].pieces
                let above = s[k].y > crotch
                let side: (Piece) -> Bool = { above ? ($0.maxX < torsoMin + 0.005 || $0.minX > torsoMax - 0.005) : true }
                guard pieces.count >= (above ? 3 : 4) else { continue }
                if let r = pieces.first, r.maxX < 0, side(r), (above || r.maxX < (rightLeg.first?.1.minX ?? -1)) { rightArm.append(SIMD3(r.x, s[k].y, r.z)); top = max(top, k) }
                if let l = pieces.last, l.minX > 0, side(l), (above || l.minX > (leftLeg.first?.1.maxX ?? 1)) { leftArm.append(SIMD3(l.x, s[k].y, l.z)); top = max(top, k) }
            }
            rightArm.sort { $0.y > $1.y }; leftArm.sort { $0.y > $1.y }
            if top >= 0 { armpit = s[top].y; pose = .armsDown }
        }
        let armsFound = rightArm.count >= 4 && leftArm.count >= 4
        if !armsFound { notes.append(L10n.t("手臂与身体连在一起，按比例估计", "Arms joined to the body; estimated from proportions")) }

        // Neck: narrowest slice between the shoulders and the top.
        var top = n - 1
        while top > 0 && s[top].pieces.isEmpty { top -= 1 }
        let topY = s[top].y + 0.5 / Float(n)
        let shoulderY = armsFound ? (pose == .armsDown ? armpit + 0.04 : armpit + 0.03) : 0.8
        var neckY: Float = 0.86, neckFound = false
        var best = Float.infinity
        let head0 = max(sliceIndex(shoulderY + 0.01), sliceIndex(0.7)), head1 = sliceIndex(topY - 0.06)
        if head0 < head1 {
            var widths: [(Int, Float)] = []
            for k in head0...head1 { if let m = main(s[k]) { widths.append((k, m.maxX - m.minX)) } }
            for (k, w) in widths where w < best { best = w; neckY = s[k].y }
            let headWidth = widths.filter { s[$0.0].y > neckY }.map(\.1).max() ?? 0
            neckFound = headWidth > best * 1.15
        }
        if !neckFound { neckY = min(topY - 0.12, max(shoulderY + 0.03, 0.86 * topY)); notes.append(L10n.t("颈部不明显，按比例估计", "Neck unclear; estimated from proportions")) }

        func z(at y: Float) -> Float { main(s[sliceIndex(y)])?.z ?? 0 }
        func centre(_ y: Float) -> SIMD3<Float> { SIMD3(main(s[sliceIndex(y)])?.x ?? 0, y, z(at: y)) }

        // Spine.
        let pelvisY = crotch + 0.04
        p[.pelvis] = centre(pelvisY)
        let chain = neckY - pelvisY
        p[.spine] = centre(pelvisY + chain * 0.28)
        p[.spine1] = centre(pelvisY + chain * 0.55)
        p[.chest] = centre(pelvisY + chain * 0.8)
        p[.neck] = centre(neckY)
        p[.head] = centre(neckY + (topY - neckY) * 0.3)
        p[.headEnd] = SIMD3(p[.head]!.x, topY, p[.head]!.z)
        for tag in [JointTag.pelvis, .spine, .spine1, .chest] { conf[tag] = legsFound ? 0.85 : 0.5 }
        conf[.neck] = neckFound ? 0.85 : 0.45; conf[.head] = conf[.neck]; conf[.headEnd] = 0.9

        // Arms.
        func arm(_ points: [SIMD3<Float>], side: Float, prefix: String) {
            let tag = { (name: String) in JointTag(rawValue: prefix + name)! }
            let shoulderPoint: SIMD3<Float>
            var path = points
            if armsFound {
                if pose == .armsDown {
                    // Top of the hanging arm is the armpit; the shoulder is a little above.
                    shoulderPoint = SIMD3(path[0].x - side * 0.01, shoulderY, path[0].z)
                } else {
                    shoulderPoint = SIMD3((side < 0 ? torsoMin : torsoMax) + side * 0.015, path[0].y, path[0].z)
                }
                path.insert(shoulderPoint, at: 0)
            } else {
                let x = (side < 0 ? torsoMin : torsoMax) + side * 0.03
                shoulderPoint = SIMD3(x, shoulderY, z(at: shoulderY))
                path = [shoulderPoint, SIMD3(x + side * 0.02, crotch, z(at: shoulderY))]
            }
            let length = zip(path, path.dropFirst()).map { rigLength($1 - $0) }.reduce(0, +)
            func along(_ f: Float) -> SIMD3<Float> {
                var remain = f * length
                for (a, b) in zip(path, path.dropFirst()) {
                    let l = rigLength(b - a)
                    if remain <= l { return a + (b - a) * (l > 0 ? remain / l : 0) }
                    remain -= l
                }
                return path.last!
            }
            p[tag("Clavicle")] = SIMD3(side * 0.025, shoulderY - 0.005, z(at: shoulderY))
            p[tag("UpperArm")] = shoulderPoint
            p[tag("Forearm")] = along(0.46)
            p[tag("Hand")] = along(0.84)
            p[tag("HandEnd")] = along(1)
            let c: Float = armsFound ? 0.8 : 0.35
            for name in ["Clavicle", "UpperArm", "Forearm", "Hand", "HandEnd"] { conf[tag(name)] = c }
        }
        arm(rightArm, side: -1, prefix: "right")
        arm(leftArm, side: 1, prefix: "left")

        // Legs.
        func leg(_ pieces: [(Float, Piece)], side: Float, prefix: String) {
            let tag = { (name: String) in JointTag(rawValue: prefix + name)! }
            let groundY = s[bottom].y - 0.5 / Float(n)
            let hip: SIMD3<Float>, ankle: SIMD3<Float>
            if let top = pieces.last, let low = pieces.first(where: { $0.0 >= groundY + 0.045 }) ?? pieces.first {
                hip = SIMD3(top.1.x, crotch - 0.01, top.1.z)
                ankle = SIMD3(low.1.x, groundY + 0.045, low.1.z)
            } else {
                hip = SIMD3(side * torsoWidth * 0.25, crotch - 0.01, z(at: crotch))
                ankle = SIMD3(side * torsoWidth * 0.25, groundY + 0.045, z(at: crotch))
            }
            // Toe: the front-most point of this foot near the ground.
            var toeZ = ankle.z, toeX = ankle.x
            for v in 0..<mesh.vertexCount {
                let y = mesh.positions[v * 3 + 1], x = mesh.positions[v * 3]
                guard y < groundY + 0.04, x * side > 0, abs(x - ankle.x) < max(0.015, abs(ankle.x) * 0.8) else { continue }
                if mesh.positions[v * 3 + 2] > toeZ { toeZ = mesh.positions[v * 3 + 2]; toeX = x }
            }
            let footLength = max(0.02, toeZ - ankle.z)
            p[tag("Thigh")] = hip
            p[tag("Shin")] = SIMD3((hip.x + ankle.x) / 2, (hip.y + ankle.y) / 2, (hip.z + ankle.z) / 2 + 0.005)
            p[tag("Foot")] = ankle
            p[tag("Toe")] = SIMD3(toeX, groundY + 0.02, ankle.z + footLength * 0.7)
            p[tag("ToeEnd")] = SIMD3(toeX, groundY + 0.015, max(toeZ, ankle.z + footLength))
            let c: Float = legsFound ? 0.85 : 0.35
            for name in ["Thigh", "Shin", "Foot", "Toe", "ToeEnd"] { conf[tag(name)] = c }
        }
        leg(rightLeg, side: -1, prefix: "right")
        leg(leftLeg, side: 1, prefix: "left")

        // Overall: legs, arms, neck found and mirror-like proportions.
        var score: Float = 0.2
        if legsFound { score += 0.3 }
        if armsFound { score += 0.3 }
        if neckFound { score += 0.1 }
        if let r = p[.rightHand], let l = p[.leftHand], abs(r.y - l.y) < 0.08, abs(r.x + l.x) < 0.1 { score += 0.1 }
        return JointEstimate(positions: p, confidence: conf, pose: armsFound ? pose : .unknown, humanoid: min(1, score), notes: notes)
    }
}

@inline(__always) func rigLength(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
