import Foundation

// v1.76: binary FBX (7.x) reader: meshes (positions, UVs, normals),
// embedded textures, skin clusters → skeleton + weights, and animation
// stacks → keyframe clips. Transforms use T · Rpre · R · Rpost⁻¹ · S
// (rotation and scaling pivots are ignored). ASCII FBX is not supported.

enum FBXImporter {
    indirect enum Value {
        case int(Int64), double(Double), string(String), bytes([UInt8]), ints([Int64]), doubles([Double]), bools([Bool])
        var double: Double? { switch self { case .double(let d): d; case .int(let i): Double(i); default: nil } }
        var int: Int64? { switch self { case .int(let i): i; case .double(let d): Int64(d); default: nil } }
        var string: String? { if case .string(let s) = self { s } else { nil } }
        var doubles: [Double] { switch self { case .doubles(let d): d; case .ints(let i): i.map(Double.init); default: [] } }
        var ints: [Int64] { switch self { case .ints(let i): i; case .doubles(let d): d.map { Int64($0) }; default: [] } }
    }
    final class Node {
        var name: String
        var props: [Value]
        var children: [Node] = []
        init(name: String, props: [Value]) { self.name = name; self.props = props }
        func child(_ n: String) -> Node? { children.first { $0.name == n } }
        func all(_ n: String) -> [Node] { children.filter { $0.name == n } }
        /// Properties70 entry (P "name", type, subtype, flags, values…).
        func property(_ n: String) -> [Value]? {
            child("Properties70")?.all("P").first { $0.props.first?.string == n }.map { Array($0.props.dropFirst(4)) }
        }
        func vector(_ n: String, _ fallback: SIMD3<Double>) -> SIMD3<Double> {
            guard let v = property(n), v.count >= 3, let x = v[0].double, let y = v[1].double, let z = v[2].double else { return fallback }
            return SIMD3(x, y, z)
        }
    }

    // MARK: Binary parsing

    static func parse(_ data: Data) throws -> Node {
        let b = [UInt8](data)
        guard b.count > 27, String(decoding: b[0..<18], as: UTF8.self) == "Kaydara FBX Binary" else {
            if String(decoding: b.prefix(200), as: UTF8.self).contains("FBXHeaderExtension") { throw ImportError.unsupported("ASCII FBX") }
            throw ImportError.damaged("not an FBX file")
        }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
        let version = Int(u32(23))
        let wide = version >= 7500
        var pos = 27
        func node(_ depth: Int) throws -> Node? {
            guard depth < 64 else { throw ImportError.damaged("FBX nesting") }
            let header = wide ? 25 : 13
            guard pos + header <= b.count else { throw ImportError.damaged("truncated") }
            let end = wide ? Int(u64(pos)) : Int(u32(pos))
            let count = wide ? Int(u64(pos + 8)) : Int(u32(pos + 4))
            let nameLen = Int(b[pos + (wide ? 24 : 12)])
            if end == 0 { pos += header; return nil }
            guard end <= b.count, end > pos else { throw ImportError.damaged("node end") }
            pos += header
            let name = String(decoding: b[pos..<(pos + nameLen)], as: UTF8.self)
            pos += nameLen
            var props: [Value] = []
            for _ in 0..<count {
                guard pos < b.count else { throw ImportError.damaged("property") }
                let type = b[pos]; pos += 1
                func f64(_ o: Int) -> Double { Double(bitPattern: u64(o)) }
                switch type {
                case UInt8(ascii: "Y"): props.append(.int(Int64(Int16(bitPattern: UInt16(b[pos]) | UInt16(b[pos + 1]) << 8)))); pos += 2
                case UInt8(ascii: "C"): props.append(.int(Int64(b[pos]))); pos += 1
                case UInt8(ascii: "I"): props.append(.int(Int64(Int32(bitPattern: u32(pos))))); pos += 4
                case UInt8(ascii: "F"): props.append(.double(Double(Float(bitPattern: u32(pos))))); pos += 4
                case UInt8(ascii: "D"): props.append(.double(f64(pos))); pos += 8
                case UInt8(ascii: "L"): props.append(.int(Int64(bitPattern: u64(pos)))); pos += 8
                case UInt8(ascii: "S"), UInt8(ascii: "R"):
                    let len = Int(u32(pos)); pos += 4
                    guard pos + len <= b.count else { throw ImportError.damaged("string") }
                    let raw = Array(b[pos..<(pos + len)]); pos += len
                    props.append(type == UInt8(ascii: "S") ? .string(String(decoding: raw, as: UTF8.self)) : .bytes(raw))
                case UInt8(ascii: "f"), UInt8(ascii: "d"), UInt8(ascii: "l"), UInt8(ascii: "i"), UInt8(ascii: "b"):
                    let n = Int(u32(pos)), encoding = u32(pos + 4), len = Int(u32(pos + 8)); pos += 12
                    guard pos + len <= b.count, n < 200_000_000 else { throw ImportError.damaged("array") }
                    var raw = Array(b[pos..<(pos + len)]); pos += len
                    if encoding == 1 { raw = try Inflate.zlib(raw) }
                    func r32(_ o: Int) -> UInt32 { UInt32(raw[o]) | UInt32(raw[o + 1]) << 8 | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24 }
                    func r64(_ o: Int) -> UInt64 { UInt64(r32(o)) | UInt64(r32(o + 4)) << 32 }
                    let size = type == UInt8(ascii: "d") || type == UInt8(ascii: "l") ? 8 : type == UInt8(ascii: "b") ? 1 : 4
                    guard raw.count >= n * size else { throw ImportError.damaged("array size") }
                    switch type {
                    case UInt8(ascii: "f"): props.append(.doubles((0..<n).map { Double(Float(bitPattern: r32($0 * 4))) }))
                    case UInt8(ascii: "d"): props.append(.doubles((0..<n).map { Double(bitPattern: r64($0 * 8)) }))
                    case UInt8(ascii: "l"): props.append(.ints((0..<n).map { Int64(bitPattern: r64($0 * 8)) }))
                    case UInt8(ascii: "i"): props.append(.ints((0..<n).map { Int64(Int32(bitPattern: r32($0 * 4))) }))
                    default: props.append(.bools(raw.prefix(n).map { $0 != 0 }))
                    }
                default: throw ImportError.damaged("property type \(type)")
                }
            }
            let n = Node(name: name, props: props)
            while pos < end { if let c = try node(depth + 1) { n.children.append(c) } else { break } }
            pos = end
            return n
        }
        let root = Node(name: "", props: [])
        while pos + (wide ? 25 : 13) <= b.count { guard let n = try node(0) else { break }; root.children.append(n) }
        return root
    }

    // MARK: Transforms

    static func euler(_ d: SIMD3<Double>, order: Int = 0) -> RigXform {
        let k = Double.pi / 180
        let x = RigXform.rotation(axis: [1, 0, 0], angle: Float(d.x * k)), y = RigXform.rotation(axis: [0, 1, 0], angle: Float(d.y * k)), z = RigXform.rotation(axis: [0, 0, 1], angle: Float(d.z * k))
        switch order {   // FBX EulerXYZ … SphericXYZ
        case 1: return y * z * x   // XZY
        case 2: return x * z * y   // YZX
        case 3: return z * x * y   // YXZ
        case 4: return x * y * z   // ZXY
        case 5: return y * x * z   // ZYX
        default: return z * y * x  // XYZ
        }
    }
    struct Model { var node: Node; var kind: String; var name: String }
    static func local(_ m: Node, t: SIMD3<Double>? = nil, r: SIMD3<Double>? = nil, s: SIMD3<Double>? = nil) -> (RigXform, rot: RigXform) {
        let order = Int(m.property("RotationOrder")?.first?.int ?? 0)
        let pre = euler(m.vector("PreRotation", .zero)), post = euler(m.vector("PostRotation", .zero))
        let rot = pre * euler(r ?? m.vector("Lcl Rotation", .zero), order: order) * (post.inverse ?? .identity)
        let tv = t ?? m.vector("Lcl Translation", .zero), sv = s ?? m.vector("Lcl Scaling", SIMD3(1, 1, 1))
        var x = rot
        x.a *= Float(sv.x); x.b *= Float(sv.x); x.c *= Float(sv.x)
        x.d *= Float(sv.y); x.e *= Float(sv.y); x.f *= Float(sv.y)
        x.g *= Float(sv.z); x.h *= Float(sv.z); x.i *= Float(sv.z)
        x.tx = Float(tv.x); x.ty = Float(tv.y); x.tz = Float(tv.z)
        return (x, rot)
    }
    static func matrix(_ v: [Double]) -> RigXform? { v.count == 16 ? RigXform(matrix: v.map(Float.init)) : nil }

    // MARK: Scene

    static func read(_ data: Data) throws -> ImportedModel {
        let root = try parse(data)
        guard let objects = root.child("Objects") else { throw ImportError.empty }
        var byID: [Int64: Node] = [:]
        for o in objects.children { if let id = o.props.first?.int { byID[id] = o } }
        var parentsOf: [Int64: [(Int64, String?)]] = [:], childrenOf: [Int64: [(Int64, String?)]] = [:]
        for c in root.child("Connections")?.all("C") ?? [] {
            guard c.props.count >= 3, let child = c.props[1].int, let parent = c.props[2].int else { continue }
            let prop = c.props.count > 3 ? c.props[3].string : nil
            parentsOf[child, default: []].append((parent, prop)); childrenOf[parent, default: []].append((child, prop))
        }
        func kind(_ n: Node) -> String { n.props.count > 2 ? (n.props[2].string ?? "") : "" }
        func name(_ n: Node) -> String { (n.props.count > 1 ? n.props[1].string ?? "" : "").components(separatedBy: "\u{0}").first ?? "" }
        func modelParent(_ id: Int64) -> Int64? { parentsOf[id]?.first { byID[$0.0]?.name == "Model" }?.0 }
        var worldCache: [Int64: RigXform] = [:]
        func world(_ id: Int64, depth: Int = 0) -> RigXform {
            if let w = worldCache[id] { return w }
            guard let n = byID[id], n.name == "Model" else { return .identity }
            let l = local(n).0
            let w = (depth < 128 ? modelParent(id).map { world($0, depth: depth + 1) } : nil).map { $0 * l } ?? l
            worldCache[id] = w
            return w
        }

        // Axis: make y up (UpAxis 1); z-up files are turned.
        var axis = RigXform.identity
        if let settings = root.child("GlobalSettings"), let up = settings.property("UpAxis")?.first?.int, up == 2 {
            let sign = Float(settings.property("UpAxisSign")?.first?.int ?? 1)
            axis = RigXform.rotation(axis: [1, 0, 0], angle: -.pi / 2 * sign)
        }

        // Skeleton: limb nodes used by clusters, plus their limb ancestors.
        var clusterOfBone: [Int64: Node] = [:]
        for (id, n) in byID where n.name == "Deformer" && kind(n) == "Cluster" {
            if let bone = childrenOf[id]?.first(where: { byID[$0.0]?.name == "Model" })?.0 { clusterOfBone[bone] = n }
        }
        var jointIDs = Set(clusterOfBone.keys)
        for b in clusterOfBone.keys {
            var p = modelParent(b)
            while let x = p, let n = byID[x], kind(n) == "LimbNode" || kind(n) == "Root" || kind(n) == "Null" && childrenOf[x]?.contains(where: { jointIDs.contains($0.0) }) == true {
                if kind(n) == "LimbNode" { jointIDs.insert(x) }
                p = modelParent(x)
            }
        }
        var skeleton: SkeletonDefinition?
        var jointIndex: [Int64: Int] = [:]
        var pre: [Int: [Float]] = [:]
        var baseTRS: [[Float]?] = []
        if !jointIDs.isEmpty {
            func depth(_ id: Int64) -> Int { var d = 0, p = modelParent(id); while let x = p, d < 256 { d += 1; p = modelParent(x) }; return d }
            let ordered = jointIDs.sorted { (depth($0), $0) < (depth($1), $1) }
            var joints = [RigJoint(jointID: "moonlight-root", parentID: nil, restTransform: axis.matrix, inverseBindMatrix: RigXform.identity.matrix, jointLimit: .free, semanticTag: .other, confidence: 1)]
            baseTRS = [nil]
            var bind: [Int64: RigXform] = [:]
            var used = Set(["moonlight-root"])
            for id in ordered {
                guard let n = byID[id] else { continue }
                let bw = clusterOfBone[id]?.child("TransformLink").flatMap { matrix($0.props.first?.doubles ?? []) } ?? world(id)
                bind[id] = bw
                var ancestor = modelParent(id)
                while let a = ancestor, !jointIDs.contains(a) { ancestor = modelParent(a) }
                let parentBind = ancestor.flatMap { bind[$0] } ?? .identity
                var jn = name(n); if jn.isEmpty { jn = "joint\(joints.count)" }
                while used.contains(jn) { jn += "_" }
                used.insert(jn)
                jointIndex[id] = joints.count
                joints.append(RigJoint(jointID: jn, parentID: ancestor.flatMap { jointIndex[$0] }.map { joints[$0].jointID } ?? "moonlight-root",
                                       restTransform: ((parentBind.inverse ?? .identity) * bw).matrix, inverseBindMatrix: RigXform.identity.matrix,
                                       jointLimit: .free, semanticTag: JointNames.tag(jn), confidence: 1))
                let l = local(n)
                baseTRS.append(KeyframeClip.decompose(l.0))
                if let p = modelParent(id), p != ancestor {
                    let chain = ancestor.flatMap { world($0).inverse }.map { $0 * world(p) } ?? world(p)
                    pre[joints.count - 1] = chain.matrix
                }
            }
            var s = SkeletonDefinition(joints: joints)
            s.refreshBindMatrices()
            skeleton = s
        }

        // Meshes.
        var out = GeneratedMesh()
        var rows: [[(Int, Float)]] = []
        for (gid, g) in byID where g.name == "Geometry" && kind(g) == "Mesh" {
            guard let verts = g.child("Vertices")?.props.first?.doubles, let poly = g.child("PolygonVertexIndex")?.props.first?.ints, !verts.isEmpty else { continue }
            let model = parentsOf[gid]?.first { byID[$0.0]?.name == "Model" }?.0
            // Skin of this geometry: control point → weights.
            var weights: [Int: [(Int, Float)]] = [:]
            var meshBind: RigXform?
            if let skinID = childrenOf[gid]?.first(where: { byID[$0.0]?.name == "Deformer" && kind(byID[$0.0]!) == "Skin" })?.0 {
                for (cid, _) in childrenOf[skinID] ?? [] {
                    guard let c = byID[cid], kind(c) == "Cluster", let bone = childrenOf[cid]?.first(where: { byID[$0.0]?.name == "Model" })?.0, let j = jointIndex[bone] else { continue }
                    let idx = c.child("Indexes")?.props.first?.ints ?? [], w = c.child("Weights")?.props.first?.doubles ?? []
                    for (k, i) in idx.enumerated() where k < w.count { weights[Int(i), default: []].append((j, Float(w[k]))) }
                    if meshBind == nil { meshBind = c.child("Transform").flatMap { matrix($0.props.first?.doubles ?? []) } }
                }
            }
            let geometric = byID[model ?? -1].map { m -> RigXform in
                var x = euler(m.vector("GeometricRotation", .zero))
                let s = m.vector("GeometricScaling", SIMD3(1, 1, 1)), t = m.vector("GeometricTranslation", .zero)
                x.a *= Float(s.x); x.b *= Float(s.x); x.c *= Float(s.x); x.d *= Float(s.y); x.e *= Float(s.y); x.f *= Float(s.y); x.g *= Float(s.z); x.h *= Float(s.z); x.i *= Float(s.z)
                x.tx = Float(t.x); x.ty = Float(t.y); x.tz = Float(t.z)
                return x
            } ?? .identity
            let skinned = !weights.isEmpty && skeleton != nil
            let placement = (skinned ? (meshBind ?? model.map { world($0) } ?? .identity) : axis * (model.map { world($0) } ?? .identity)) * geometric
            var holder = model
            while let h = holder, jointIndex[h] == nil { holder = modelParent(h) }
            let rigid = holder.flatMap { jointIndex[$0] } ?? 0
            func layer(_ n: String, _ v: String, _ i: String) -> (values: [Double], index: [Int64], mapping: String, reference: String)? {
                guard let l = g.child(n), let values = l.child(v)?.props.first?.doubles else { return nil }
                return (values, l.child(i)?.props.first?.ints ?? [], l.child("MappingInformationType")?.props.first?.string ?? "", l.child("ReferenceInformationType")?.props.first?.string ?? "")
            }
            let uvLayer = layer("LayerElementUV", "UV", "UVIndex"), nLayer = layer("LayerElementNormal", "Normals", "NormalsIndex")
            func lookup(_ l: (values: [Double], index: [Int64], mapping: String, reference: String)?, corner: Int, point: Int, width: Int) -> [Double]? {
                guard let l else { return nil }
                var i = l.mapping.hasPrefix("ByPolygonVertex") ? corner : point
                if l.reference == "IndexToDirect" || l.reference == "Index" { guard i < l.index.count else { return nil }; i = Int(l.index[i]) }
                guard i >= 0, (i + 1) * width <= l.values.count else { return nil }
                return Array(l.values[(i * width)..<((i + 1) * width)])
            }
            var polygon: [UInt32] = []
            let base = out.vertexCount
            var cache: [String: UInt32] = [:]
            for (corner, raw) in poly.enumerated() {
                let point = Int(raw < 0 ? ~raw : raw)
                guard (point + 1) * 3 <= verts.count else { continue }
                let uv = lookup(uvLayer, corner: corner, point: point, width: 2), nv = lookup(nLayer, corner: corner, point: point, width: 3)
                let key = "\(point)|\(uv.map { "\($0[0]),\($0[1])" } ?? "")"
                let id: UInt32
                if let e = cache[key] { id = e } else {
                    id = UInt32(out.vertexCount)
                    cache[key] = id
                    let p = placement.point(SIMD3(Float(verts[point * 3]), Float(verts[point * 3 + 1]), Float(verts[point * 3 + 2])))
                    out.positions += [p.x, p.y, p.z]
                    if let nv { var q = placement.direction(SIMD3(Float(nv[0]), Float(nv[1]), Float(nv[2]))); let len = rigLength(q); if len > 0 { q /= len }; out.normals += [q.x, q.y, q.z] }
                    else { out.normals += [.nan, .nan, .nan] }
                    out.uvs += uv.map { [Float($0[0]), Float($0[1])] } ?? [0, 0]
                    let fallback: [(Int, Float)] = [(skinned ? 0 : rigid, Float(1))]
                    let row = skinned ? (weights[point] ?? fallback) : fallback
                    rows.append(row)
                }
                polygon.append(id)
                if raw < 0 {
                    if polygon.count >= 3 { for k in 1..<(polygon.count - 1) { out.indices += [polygon[0], polygon[k], polygon[k + 1]] } }
                    polygon = []
                }
            }
            if placement.determinant < 0 { var t = base; while t + 2 < out.indices.count { out.indices.swapAt(t + 1, t + 2); t += 3 } }
        }
        guard out.triangleCount > 0 else { throw ImportError.empty }
        if out.normals.contains(where: { $0.isNaN }) { out.computeNormals() }

        // Texture: embedded video content, else the file name.
        var texture: Data?, textureName: String?
        for n in objects.all("Video") { if let content = n.child("Content")?.props.first, case .bytes(let raw) = content, raw.count > 16 { texture = Data(raw); break } }
        if texture == nil, let t = objects.all("Texture").first { textureName = (t.child("RelativeFilename") ?? t.child("FileName"))?.props.first?.string }

        // Animations.
        var rig: ImportedRig?
        if var skeleton {
            var skin = SkinInfluences(count: out.vertexCount)
            for (v, row) in rows.enumerated() {
                SkinWeightSolver.write(Array(row.sorted { $0.1 > $1.1 }.prefix(4)), into: &skin, vertex: v)
                if skin.influences(v).isEmpty { skin.joints[v * 4] = 0; skin.weights[v * 4] = 1 }
            }
            var clips: [KeyframeClip] = []
            let tick = 46_186_158_000.0
            for (sid, stack) in byID where stack.name == "AnimationStack" {
                var tracks: [KeyframeTrack] = [], duration: Float = 0
                let layers = (childrenOf[sid] ?? []).compactMap { byID[$0.0]?.name == "AnimationLayer" ? $0.0 : nil }
                var perJoint: [Int: [String: (node: Int64, comps: [String: (times: [Double], values: [Double])])]] = [:]
                for layer in layers {
                    for (cnid, _) in childrenOf[layer] ?? [] where byID[cnid]?.name == "AnimationCurveNode" {
                        guard let (bone, prop) = parentsOf[cnid]?.first(where: { byID[$0.0]?.name == "Model" && $0.1 != nil }).map({ ($0.0, $0.1!) }), let j = jointIndex[bone] else { continue }
                        var comps: [String: (times: [Double], values: [Double])] = [:]
                        for (cid, axisName) in childrenOf[cnid] ?? [] {
                            guard let c = byID[cid], c.name == "AnimationCurve", let axisName else { continue }
                            let times = (c.child("KeyTime")?.props.first?.ints ?? []).map { Double($0) / tick }
                            let values = c.child("KeyValueFloat")?.props.first?.doubles ?? []
                            if !times.isEmpty && times.count == values.count { comps[axisName] = (times, values) }
                        }
                        perJoint[j, default: [:]][prop] = (bone, comps)
                    }
                }
                for (j, props) in perJoint {
                    guard let bone = props.values.first?.node, let n = byID[bone] else { continue }
                    let allTimes = Array(Set(props.values.flatMap { $0.comps.values.flatMap(\.times) })).sorted()
                    guard !allTimes.isEmpty else { continue }
                    func value(_ prop: String, _ fallback: SIMD3<Double>, at t: Double) -> SIMD3<Double> {
                        guard let comps = props[prop]?.comps else { return fallback }
                        func c(_ k: String, _ d: Double) -> Double {
                            guard let curve = comps[k] else { return d }
                            let ts = curve.times
                            if t <= ts[0] { return curve.values[0] }
                            if t >= ts[ts.count - 1] { return curve.values[ts.count - 1] }
                            var i = 0; while i + 1 < ts.count && ts[i + 1] < t { i += 1 }
                            let f = (t - ts[i]) / max(1e-9, ts[i + 1] - ts[i])
                            return curve.values[i] + (curve.values[i + 1] - curve.values[i]) * f
                        }
                        return SIMD3(c("d|X", fallback.x), c("d|Y", fallback.y), c("d|Z", fallback.z))
                    }
                    let t0 = n.vector("Lcl Translation", .zero), r0 = n.vector("Lcl Rotation", .zero), s0 = n.vector("Lcl Scaling", SIMD3(1, 1, 1))
                    var tv: [Float] = [], rv: [Float] = [], sv: [Float] = []
                    for t in allTimes {
                        let l = local(n, t: value("Lcl Translation", t0, at: t), r: value("Lcl Rotation", r0, at: t), s: value("Lcl Scaling", s0, at: t))
                        let d = KeyframeClip.decompose(l.0)
                        tv += d[0..<3]; rv += d[3..<7]; sv += d[7..<10]
                    }
                    let times = allTimes.map { Float($0 - allTimes[0]) }
                    tracks.append(KeyframeTrack(joint: j, path: .translation, times: times, values: tv))
                    tracks.append(KeyframeTrack(joint: j, path: .rotation, times: times, values: rv))
                    tracks.append(KeyframeTrack(joint: j, path: .scale, times: times, values: sv))
                    duration = max(duration, times.last ?? 0)
                }
                guard !tracks.isEmpty else { continue }
                var clipName = name(stack); if clipName.isEmpty { clipName = "Animation \(clips.count + 1)" }
                clips.append(KeyframeClip(id: "file-\(clips.count)", name: clipName, duration: max(0.04, duration), tracks: tracks, base: baseTRS, pre: pre))
            }
            skeleton.refreshBindMatrices()
            rig = ImportedRig(skeleton: skeleton, skin: skin, clips: clips)
        }
        var notes: [String] = []
        if let rig { notes.append(L10n.t("保留了文件里的骨骼（\(rig.skeleton.joints.count - 1) 个关节）和 \(rig.clips.count) 个动画", "Kept the file's skeleton (\(rig.skeleton.joints.count - 1) joints) and \(rig.clips.count) animations")) }
        return ImportedModel(mesh: out, colors: nil, texture: texture, textureName: textureName, name: nil, rig: rig, notes: notes)
    }
}
