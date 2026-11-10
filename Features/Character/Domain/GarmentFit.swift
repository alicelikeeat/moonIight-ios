import Foundation

// v1.93: body and clothes kept apart. The body is always a base body
// (clean topology, reliable bending); clothes, hair and shoes can be any
// mesh — an AI 3D model or an imported file — fitted onto it:
//   1. placed on the slot's band of the body (top: hips to neck, bottom:
//      ankles to waist, shoes, hair, or the whole body) with one uniform
//      scale, centred, plus the user's adjustments;
//   2. the sleeve angle is measured (AI clothes usually come in an A-pose
//      or with arms down) and the base body's arms are posed to match;
//   3. every garment point is pushed out of the posed body by a small gap
//      and takes the weights of the nearest body points;
//   4. the garment is un-posed with those weights back to the T-pose bind,
//      so it moves with every shared motion like the built-in outfit.
// Pure Swift (tested on Linux).

struct GarmentAdjust: Codable, Equatable, Sendable {
    /// Extra uniform scale on top of the automatic one.
    var scale: Float = 1
    /// Up / down and forward / back, as a share of the body height.
    var lift: Float = 0
    var forward: Float = 0
    /// Quarter turns about the vertical axis (models that do not face +z).
    var quarterTurns: Int = 0
    /// Sleeve angle below horizontal in degrees; nil: measured.
    var armDrop: Float? = nil
    /// Gap between the skin and the garment, metres (for a 1.75 m body).
    var gap: Float = 0.008

    var clamped: GarmentAdjust {
        func c(_ v: Float, _ lo: Float, _ hi: Float, _ d: Float) -> Float { v.isFinite ? min(hi, max(lo, v)) : d }
        var a = self
        a.scale = c(scale, 0.5, 1.6, 1); a.lift = c(lift, -0.3, 0.3, 0); a.forward = c(forward, -0.2, 0.2, 0)
        a.quarterTurns = ((quarterTurns % 4) + 4) % 4
        a.armDrop = armDrop.map { c($0, 0, 85, 0) }
        a.gap = c(gap, 0, 0.05, 0.008)
        return a
    }
}

/// A garment from a model, worn on a base body. The source mesh lives in the
/// character package (Garments/), its texture in Textures/.
struct CustomGarment: Codable, Equatable, Identifiable, Sendable {
    enum Slot: String, Codable, CaseIterable, Sendable, Identifiable {
        case top, bottom, shoes, hair, full
        var id: Self { self }
        var title: String {
            switch self {
            case .top: L10n.t("上衣", "Top"); case .bottom: L10n.t("下装", "Bottom"); case .shoes: L10n.t("鞋子", "Shoes")
            case .hair: L10n.t("头发", "Hair"); case .full: L10n.t("整套（全身）", "Full outfit")
            }
        }
        /// Built-in outfit slots this garment takes the place of.
        var replaces: [OutfitSlot] {
            switch self { case .top: [.top]; case .bottom: [.bottom]; case .shoes: [.shoes]; case .hair: [.hair]; case .full: OutfitSlot.allCases }
        }
    }
    var id: String
    var name: String
    var slot: Slot
    /// File in the package's Garments/ folder (GeneratedMeshCodec).
    var mesh: String
    /// File in the package's Textures/ folder; nil: a plain colour.
    var texture: String?
    /// Surface maps made from the texture (Textures/): detail normals and roughness.
    var normal: String? = nil
    var roughness: String? = nil
    var color = SIMD3<Float>(0.8, 0.8, 0.82)
    var adjust = GarmentAdjust()
    /// The AI 3D / imported model it came from.
    var sourceModelID: String?
}

struct GarmentFitResult: Sendable {
    var part: SkinnedPart
    /// Sleeve angle used (degrees below horizontal).
    var armDrop: Float
    /// Uniform scale applied to the source.
    var scale: Float
    /// Points moved out of the body.
    var pushed: Int
    var notes: [String]
}

enum GarmentFit {
    static let maxVertices = 60_000

    /// Quarter turns about y (same sense as RasterCamera's yaw).
    static func turned(_ mesh: GeneratedMesh, _ turns: Int) -> GeneratedMesh {
        let t = ((turns % 4) + 4) % 4
        guard t != 0 else { return mesh }
        let a = Float(t) * .pi / 2, c = Float(Int(cos(a).rounded())), s = Float(Int(sin(a).rounded()))
        var m = mesh
        for i in 0..<m.vertexCount {
            let x = m.positions[i * 3], z = m.positions[i * 3 + 2]
            m.positions[i * 3] = x * c + z * s; m.positions[i * 3 + 2] = -x * s + z * c
            if m.normals.count == m.positions.count {
                let nx = m.normals[i * 3], nz = m.normals[i * 3 + 2]
                m.normals[i * 3] = nx * c + nz * s; m.normals[i * 3 + 2] = -nx * s + nz * c
            }
        }
        return m
    }

    /// The vertical band of the body a slot covers, and which end anchors the garment.
    static func band(_ slot: CustomGarment.Slot, body: HumanBody) -> (low: Float, high: Float, anchorTop: Bool) {
        let s = body.skeleton, crown = body.mesh.bounds.max[1], h = max(0.3, crown)
        let neck = s.position(.neck)?.y ?? 0.85 * h, pelvis = s.position(.pelvis)?.y ?? 0.53 * h, ankle = s.position(.rightFoot)?.y ?? 0.05 * h
        switch slot {
        case .full: return (0, crown, false)
        case .top: return (pelvis - 0.06 * h, neck + 0.03 * h, true)
        case .bottom: return (ankle, pelvis + 0.05 * h, true)
        case .shoes: return (0, ankle + 0.07 * h, false)
        case .hair: return (neck, crown + 0.015 * h, true)
        }
    }

    /// Sleeve angle below horizontal (degrees) of a garment placed on the body:
    /// the direction from the shoulder to the points well outside it.
    static func measureArmDrop(_ positions: [Float], body: HumanBody) -> Float {
        guard let shoulder = body.skeleton.position(.leftUpperArm), let pelvis = body.skeleton.position(.pelvis) else { return 0 }
        let reach = abs(shoulder.x) * 1.15
        var sx: Float = 0, sy: Float = 0, n = 0
        for i in 0..<(positions.count / 3) {
            let x = abs(positions[i * 3]), y = positions[i * 3 + 1]
            guard x > reach, y > pelvis.y else { continue }
            sx += x - abs(shoulder.x); sy += shoulder.y - y; n += 1
        }
        guard n * 100 >= positions.count / 3, sx > 0 else { return 0 }
        return min(85, max(0, atan2(sy / Float(n), sx / Float(n)) * 180 / .pi))
    }

    static func fit(_ source: GeneratedMesh, slot: CustomGarment.Slot, on body: HumanBody, adjust: GarmentAdjust = GarmentAdjust()) -> GarmentFitResult? {
        guard source.vertexCount > 0, source.triangleCount > 0, source.vertexCount <= maxVertices,
              source.positions.allSatisfy(\.isFinite), source.indices.allSatisfy({ Int($0) < source.vertexCount }) else { return nil }
        let a = adjust.clamped
        let bodyMesh = body.mesh, skeleton = body.skeleton
        let crown = bodyMesh.bounds.max[1], h = max(0.3, crown)
        var notes: [String] = []

        // 1. Place.
        var m = turned(source, a.quarterTurns)
        let gb = m.bounds
        let gh = gb.max[1] - gb.min[1]
        guard gh > 1e-6 else { return nil }
        let region = band(slot, body: body)
        let k = (region.high - region.low) / gh * a.scale
        var zs: [Float] = []
        for v in 0..<bodyMesh.vertexCount where bodyMesh.positions[v * 3 + 1] >= region.low && bodyMesh.positions[v * 3 + 1] <= region.high { zs.append(bodyMesh.positions[v * 3 + 2]) }
        let zc = zs.isEmpty ? 0 : ((zs.min() ?? 0) + (zs.max() ?? 0)) / 2
        let gx = (gb.min[0] + gb.max[0]) / 2, gz = (gb.min[2] + gb.max[2]) / 2
        let gAnchor = region.anchorTop ? gb.max[1] : gb.min[1], bAnchor = (region.anchorTop ? region.high : region.low) + a.lift * h
        for i in 0..<m.vertexCount {
            m.positions[i * 3] = (m.positions[i * 3] - gx) * k
            m.positions[i * 3 + 1] = (m.positions[i * 3 + 1] - gAnchor) * k + bAnchor
            m.positions[i * 3 + 2] = (m.positions[i * 3 + 2] - gz) * k + zc + a.forward * h
        }

        // 2. Pose the body's arms like the garment's sleeves.
        let drop = a.armDrop ?? ((slot == .top || slot == .full) ? measureArmDrop(m.positions, body: body) : 0)
        var sample = MotionSample()
        if drop > 0.5 {
            let q = MotionLibrary.rz(drop)
            sample.rotations["rightUpperArm"] = q; sample.rotations["leftUpperArm"] = MotionLibrary.mirror(q)
            notes.append(L10n.t(String(format: "袖子约下垂 %.0f°：先把底模手臂摆成同样角度再贴合，然后还原成 T-Pose。", drop),
                                String(format: "The sleeves hang about %.0f°: the base's arms were posed the same way for the fit, then returned to the T-pose.", drop)))
        }
        let mats = RigPoser.skinning(sample, skeleton: skeleton)
        func blend(_ joints: ArraySlice<UInt8>, _ weights: ArraySlice<Float>) -> RigXform {
            var r = RigXform(); r.a = 0; r.e = 0; r.i = 0
            var total: Float = 0
            for (j, w) in zip(joints, weights) where j != 255 && Int(j) < mats.count && w > 0 {
                let x = mats[Int(j)]
                r.a += x.a * w; r.b += x.b * w; r.c += x.c * w; r.d += x.d * w; r.e += x.e * w; r.f += x.f * w
                r.g += x.g * w; r.h += x.h * w; r.i += x.i * w; r.tx += x.tx * w; r.ty += x.ty * w; r.tz += x.tz * w
                total += w
            }
            return total > 0 ? r : RigXform()
        }
        var posed: [SIMD3<Float>] = [], posedNormals: [SIMD3<Float>] = []
        posed.reserveCapacity(bodyMesh.vertexCount); posedNormals.reserveCapacity(bodyMesh.vertexCount)
        for v in 0..<bodyMesh.vertexCount {
            let x = blend(body.skin.joints[v * 4 ..< v * 4 + 4], body.skin.weights[v * 4 ..< v * 4 + 4])
            posed.append(x.point(SIMD3(bodyMesh.positions[v * 3], bodyMesh.positions[v * 3 + 1], bodyMesh.positions[v * 3 + 2])))
            let n = x.direction(SIMD3(bodyMesh.normals[v * 3], bodyMesh.normals[v * 3 + 1], bodyMesh.normals[v * 3 + 2]))
            let l = cLength(n)
            posedNormals.append(l > 1e-6 ? n / l : SIMD3(0, 0, 1))
        }

        // 3. Push out and take weights from the nearest body points.
        let grid = PointGrid(points: posed, cell: 0.035 * h)
        let gap = a.gap * h / 1.75
        var joints: [UInt8] = [], weights: [Float] = []
        joints.reserveCapacity(m.vertexCount * 4); weights.reserveCapacity(m.vertexCount * 4)
        var pushed = 0
        for i in 0..<m.vertexCount {
            var p = SIMD3(m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2])
            let near = grid.nearest(p, k: 4)
            guard let first = near.first else { joints += [255, 255, 255, 255]; weights += [0, 0, 0, 0]; continue }
            let n = posedNormals[first.0], q = posed[first.0]
            let d = cDot(p - q, n)
            if d < gap { p += n * (gap - d); pushed += 1 }
            var acc: [UInt8: Float] = [:]
            for (v, d2) in near {
                let w = 1 / (d2 + 1e-6)
                for j in 0..<4 where body.skin.joints[v * 4 + j] != 255 { acc[body.skin.joints[v * 4 + j], default: 0] += w * body.skin.weights[v * 4 + j] }
            }
            let top = Array(acc.sorted { $0.value > $1.value }.prefix(4))
            let sum = top.reduce(Float(0)) { $0 + $1.value }
            for j in 0..<4 {
                if j < top.count, sum > 0 { joints.append(top[j].key); weights.append(top[j].value / sum) }
                else { joints.append(255); weights.append(0) }
            }
            m.positions[i * 3] = p.x; m.positions[i * 3 + 1] = p.y; m.positions[i * 3 + 2] = p.z
        }

        // 4. Back to the bind pose.
        if drop > 0.5 {
            for i in 0..<m.vertexCount {
                let x = blend(joints[i * 4 ..< i * 4 + 4], weights[i * 4 ..< i * 4 + 4])
                if let inv = x.inverse {
                    let p = inv.point(SIMD3(m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]))
                    m.positions[i * 3] = p.x; m.positions[i * 3 + 1] = p.y; m.positions[i * 3 + 2] = p.z
                }
            }
        }
        m.computeNormals()
        if m.uvs.count != m.vertexCount * 2 || !m.uvs.allSatisfy(\.isFinite) { m.uvs = [Float](repeating: 0, count: m.vertexCount * 2) }
        guard m.positions.allSatisfy(\.isFinite) else { return nil }
        if pushed * 3 > m.vertexCount {
            notes.append(L10n.t("\(pushed) 个点原本陷在身体里，已推到体表外：如果衣服看起来太紧，可以把「大小」调大一点。",
                                "\(pushed) points were inside the body and were pushed out: if it looks tight, make it a little larger."))
        }
        return GarmentFitResult(part: SkinnedPart(mesh: m, skin: SkinInfluences(joints: joints, weights: weights)), armDrop: drop, scale: k, pushed: pushed, notes: notes)
    }
}

/// Nearest points by a uniform grid.
struct PointGrid {
    let cell: Float
    let points: [SIMD3<Float>]
    private var buckets: [SIMD3<Int32>: [Int32]] = [:]

    init(points: [SIMD3<Float>], cell: Float) {
        self.cell = max(1e-4, cell); self.points = points
        for (i, p) in points.enumerated() { buckets[key(p), default: []].append(Int32(i)) }
    }

    private func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
    }

    /// The k nearest points (index, squared distance), nearest first.
    func nearest(_ p: SIMD3<Float>, k: Int) -> [(Int, Float)] {
        let c = key(p)
        var found: [(Int, Float)] = []
        for r in 0...6 {
            for dx in -r...r { for dy in -r...r { for dz in -r...r where max(abs(dx), abs(dy), abs(dz)) == r {
                guard let bucket = buckets[c &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] else { continue }
                for i in bucket { let d = points[Int(i)] - p; found.append((Int(i), cDot(d, d))) }
            } } }
            if found.count >= k {
                found.sort { $0.1 < $1.1 }
                let reach = Float(r) * cell
                if found[k - 1].1 <= reach * reach || r == 6 { return Array(found.prefix(k)) }
            }
        }
        if found.isEmpty {
            // Far from everything (a badly placed garment): look at every point.
            found = points.enumerated().map { ($0.offset, cDot($0.element - p, $0.element - p)) }
        }
        found.sort { $0.1 < $1.1 }
        return Array(found.prefix(k))
    }
}
