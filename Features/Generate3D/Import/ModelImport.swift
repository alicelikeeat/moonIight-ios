import Foundation

// v1.76: importing 3D files from other apps (e.g. Tripo exports): GLB with
// its own skeleton and animations, FBX (skeleton, skin, animations), OBJ
// (+ MTL texture), STL and 3MF. USD / USDZ go through RealityKit (see the
// iOS side). Everything is normalised to the app's unit size; rigs get a
// synthetic root joint that carries that normalisation, so the file's
// animations play unchanged. Pure Swift.

struct ImportedRig: Sendable {
    var skeleton: SkeletonDefinition
    var skin: SkinInfluences
    var clips: [KeyframeClip]
}

struct ImportedModel: Sendable {
    var mesh: GeneratedMesh
    /// RGB per vertex (0…1) when the file colours vertices.
    var colors: [Float]?
    /// Encoded image (PNG / JPEG) of the base-colour texture.
    var texture: Data?
    /// Texture file named by the model (OBJ / FBX) when not embedded.
    var textureName: String?
    var name: String?
    var rig: ImportedRig?
    var notes: [String] = []
}

enum ImportError: Error, Equatable, LocalizedError {
    case unsupported(String), empty, damaged(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): L10n.t("不支持的格式：\(ext)", "Unsupported format: \(ext)")
        case .empty: L10n.t("文件里没有可用的三角网格", "No usable triangle mesh in the file")
        case .damaged(let why): L10n.t("文件无法读取：", "The file could not be read: ") + why
        }
    }
}

enum ModelImport {
    static let extensions = ["glb", "gltf", "fbx", "obj", "stl", "3mf"]

    /// `companions`: other picked files by lower-cased name (MTL, textures).
    static func read(_ data: Data, fileName: String, companions: [String: Data] = [:]) throws -> ImportedModel {
        let ext = (fileName as NSString).pathExtension.lowercased()
        var model: ImportedModel
        switch ext {
        case "glb": model = try GLTFImporter.read(data)
        case "fbx": model = try FBXImporter.read(data)
        case "obj": model = try OBJImporter.read(data, companions: companions)
        case "stl": model = try STLImporter.read(data)
        case "3mf": model = try ThreeMFImporter.read(data)
        default: throw ImportError.unsupported(ext)
        }
        if model.texture == nil, let name = model.textureName {
            let key = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()
            model.texture = companions[key]
        }
        if model.name == nil { model.name = (fileName as NSString).deletingPathExtension }
        guard model.mesh.triangleCount > 0 else { throw ImportError.empty }
        return normalized(model)
    }

    /// Centre on the origin, tallest side 1; rigs follow through their root.
    static func normalized(_ input: ImportedModel) -> ImportedModel {
        var m = input
        let b = m.mesh.bounds
        let span = max(1e-6, (0..<3).map { b.max[$0] - b.min[$0] }.max()!)
        let k = 1 / span
        let c = SIMD3((b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2, (b.min[2] + b.max[2]) / 2)
        for v in 0..<m.mesh.vertexCount { for a in 0..<3 { m.mesh.positions[v * 3 + a] = (m.mesh.positions[v * 3 + a] - c[a]) * k } }
        if m.mesh.normals.count != m.mesh.positions.count || !m.mesh.normals.allSatisfy(\.isFinite) { m.mesh.computeNormals() }
        if var rig = m.rig, let root = rig.skeleton.joints.firstIndex(where: { $0.parentID == nil }) {
            var a = RigXform.identity
            a.a = k; a.e = k; a.i = k
            a.tx = -c.x * k; a.ty = -c.y * k; a.tz = -c.z * k
            rig.skeleton.joints[root].restTransform = (a * rig.skeleton.joints[root].rest).matrix
            rig.skeleton.refreshBindMatrices()
            m.rig = rig
        }
        return m
    }
}

// MARK: glTF / GLB

enum GLTFImporter {
    /// a + b × w, entry by entry (blending skin matrices).
    static func add(_ a: RigXform, _ b: RigXform, _ w: Float) -> RigXform {
        var o = a
        o.a += b.a * w; o.b += b.b * w; o.c += b.c * w
        o.d += b.d * w; o.e += b.e * w; o.f += b.f * w
        o.g += b.g * w; o.h += b.h * w; o.i += b.i * w
        o.tx += b.tx * w; o.ty += b.ty * w; o.tz += b.tz * w
        return o
    }
    static func read(_ data: Data) throws -> ImportedModel {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24) }
        guard bytes.count >= 20, u32(0) == 0x4654_6C67 else { throw GLBError.notGLB }
        var offset = 12, json: [String: Any]?, bin: [UInt8] = []
        while offset + 8 <= min(bytes.count, u32(8)) {
            let length = u32(offset), type = u32(offset + 4)
            guard offset + 8 + length <= bytes.count else { throw GLBError.badChunk }
            let body = bytes[(offset + 8)..<(offset + 8 + length)]
            if type == 0x4E4F_534A { json = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] } else if type == 0x004E_4942 && bin.isEmpty { bin = Array(body) }
            offset += 8 + length + (4 - length % 4) % 4
        }
        guard let json else { throw GLBError.badJSON }
        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let skins = json["skins"] as? [[String: Any]] ?? []

        func read(_ index: Int) throws -> (values: [Float], comps: Int) {
            guard index < accessors.count else { throw GLBError.badAccessor("accessor") }
            let a = accessors[index]
            let count = a["count"] as? Int ?? 0, type = a["componentType"] as? Int ?? 0, normalized = a["normalized"] as? Bool ?? false
            let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][a["type"] as? String ?? ""] ?? 0
            guard comps > 0, count >= 0, count < 20_000_000 else { throw GLBError.badAccessor("type") }
            guard let vi = a["bufferView"] as? Int, vi < views.count else { return ([Float](repeating: 0, count: count * comps), comps) }
            let v = views[vi]
            let size = [5126: 4, 5125: 4, 5123: 2, 5122: 2, 5121: 1, 5120: 1][type] ?? 0
            guard size > 0 else { throw GLBError.badAccessor("component") }
            let step = (v["byteStride"] as? Int) ?? size * comps
            let base = (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
            guard count == 0 || base + step * (count - 1) + size * comps <= bin.count else { throw GLBError.badAccessor("range") }
            var out = [Float](repeating: 0, count: count * comps)
            for i in 0..<count { for c in 0..<comps {
                let o = base + i * step + c * size
                let value: Float
                switch type {
                case 5126: value = Float(bitPattern: UInt32(bin[o]) | UInt32(bin[o + 1]) << 8 | UInt32(bin[o + 2]) << 16 | UInt32(bin[o + 3]) << 24)
                case 5125: value = Float(UInt32(bin[o]) | UInt32(bin[o + 1]) << 8 | UInt32(bin[o + 2]) << 16 | UInt32(bin[o + 3]) << 24)
                case 5123: let u = UInt16(bin[o]) | UInt16(bin[o + 1]) << 8; value = normalized ? Float(u) / 65535 : Float(u)
                case 5122: let u = Int16(bitPattern: UInt16(bin[o]) | UInt16(bin[o + 1]) << 8); value = normalized ? max(-1, Float(u) / 32767) : Float(u)
                case 5121: value = normalized ? Float(bin[o]) / 255 : Float(bin[o])
                default: let u = Int8(bitPattern: bin[o]); value = normalized ? max(-1, Float(u) / 127) : Float(u)
                }
                out[i * comps + c] = value
            } }
            return (out, comps)
        }

        // Node hierarchy and rest transforms.
        var parent = [Int?](repeating: nil, count: nodes.count)
        for (i, n) in nodes.enumerated() { for c in n["children"] as? [Int] ?? [] where c < nodes.count { parent[c] = i } }
        func trs(_ n: [String: Any]) -> [Float] {
            if let m = n["matrix"] as? [Double], m.count == 16, let x = RigXform(matrix: m.map(Float.init)) { return KeyframeClip.decompose(x) }
            let t = (n["translation"] as? [Double])?.map(Float.init) ?? [0, 0, 0]
            let r = (n["rotation"] as? [Double])?.map(Float.init) ?? [0, 0, 0, 1]
            let s = (n["scale"] as? [Double])?.map(Float.init) ?? [1, 1, 1]
            return t + r + s
        }
        let localTRS = nodes.map(trs)
        var worldCache = [RigXform?](repeating: nil, count: nodes.count)
        func world(_ i: Int, depth: Int = 0) -> RigXform {
            if let w = worldCache[i] { return w }
            let local = KeyframeClip.compose(localTRS[i])
            let w = (depth < 128 ? parent[i].map { world($0, depth: depth + 1) } : nil).map { $0 * local } ?? local
            worldCache[i] = w
            return w
        }

        // Skeleton from the first skin: a synthetic root, then joints parents-first.
        var jointOf: [Int: Int] = [:]          // node → our joint index
        var skeleton: SkeletonDefinition?
        var skinJoints: [Int] = []             // skin joint index → node
        var pre: [Int: [Float]] = [:]
        var skinMatrix: [Int: RigXform] = [:] // our joint → world × inverse bind
        if let skin = skins.first, let list = skin["joints"] as? [Int], !list.isEmpty {
            skinJoints = list.filter { $0 < nodes.count }
            let inSkin = Set(skinJoints)
            func depth(_ n: Int) -> Int { var d = 0, c = parent[n]; while let p = c, d < 256 { d += 1; c = parent[p] }; return d }
            let ordered = skinJoints.sorted { depth($0) < depth($1) }
            var ibm: [Int: RigXform] = [:]
            if let acc = skin["inverseBindMatrices"] as? Int, let m = try? read(acc), m.comps == 16 {
                for (k, node) in skinJoints.enumerated() where (k + 1) * 16 <= m.values.count { ibm[node] = RigXform(matrix: Array(m.values[(k * 16)..<(k * 16 + 16)])) }
            }
            var joints = [RigJoint(jointID: "moonlight-root", parentID: nil, restTransform: RigXform.identity.matrix, inverseBindMatrix: RigXform.identity.matrix,
                                   jointLimit: .free, semanticTag: .other, confidence: 1)]
            // Rest = the scene's own pose (non-joint parents included);
            // skinned vertices are moved into it below.
            var usedIDs = Set(["moonlight-root"])
            for node in ordered {
                var ancestor = parent[node]
                while let a = ancestor, !inSkin.contains(a) { ancestor = parent[a] }
                let local = ancestor.map { (world($0).inverse ?? .identity) * world(node) } ?? world(node)
                var name = (nodes[node]["name"] as? String) ?? "joint\(node)"
                if name.isEmpty { name = "joint\(node)" }
                while usedIDs.contains(name) { name += "_" }
                usedIDs.insert(name)
                jointOf[node] = joints.count
                skinMatrix[joints.count] = world(node) * (ibm[node] ?? .identity)
                joints.append(RigJoint(jointID: name, parentID: "moonlight-root", restTransform: local.matrix, inverseBindMatrix: RigXform.identity.matrix,
                                       jointLimit: .free, semanticTag: JointNames.tag(name), confidence: 1))
                // When the joint's file parent is not a joint (an armature
                // node), animations need that parent's transform first.
                if let p = parent[node], p != ancestor {
                    let chain = ancestor.map { (world($0).inverse ?? .identity) * world(p) } ?? world(p)
                    pre[joints.count - 1] = chain.matrix
                }
            }
            // Parent ids by node (names may repeat).
            for node in ordered {
                guard let j = jointOf[node] else { continue }
                var ancestor = parent[node]
                while let a = ancestor, !inSkin.contains(a) { ancestor = parent[a] }
                joints[j].parentID = ancestor.flatMap { jointOf[$0] }.map { joints[$0].jointID } ?? "moonlight-root"
            }
            var s = SkeletonDefinition(joints: joints)
            s.refreshBindMatrices()
            skeleton = s
        }

        // Meshes.
        var out = GeneratedMesh()
        var colors: [Float] = [], anyColor = false
        var skinRows: [[(Int, Float)]] = []
        var material: Int?
        func visit(_ n: Int, depth: Int) throws {
            guard depth < 128 else { return }
            if let mi = nodes[n]["mesh"] as? Int, mi < meshes.count {
                let skinned = nodes[n]["skin"] != nil && skeleton != nil
                let transform = skinned ? RigXform.identity : world(n)
                // Rigid parts follow the nearest joint above them.
                var holder: Int? = n
                while let h = holder, jointOf[h] == nil { holder = parent[h] }
                let rigidJoint = holder.flatMap { jointOf[$0] } ?? 0
                for prim in meshes[mi]["primitives"] as? [[String: Any]] ?? [] {
                    guard (prim["mode"] as? Int ?? 4) == 4 else { continue }
                    let attr = prim["attributes"] as? [String: Int] ?? [:]
                    guard let pi = attr["POSITION"] else { continue }
                    let pos = try read(pi).values
                    let count = pos.count / 3
                    let nor = try attr["NORMAL"].map { try read($0).values }
                    let uv = try attr["TEXCOORD_0"].map { try read($0).values }
                    let col = try attr["COLOR_0"].map { try read($0) }
                    let jts = skinned ? try attr["JOINTS_0"].map { try read($0).values } : nil
                    let wts = skinned ? try attr["WEIGHTS_0"].map { try read($0).values } : nil
                    let base = UInt32(out.vertexCount)
                    for v in 0..<count {
                        var row: [(Int, Float)] = []
                        if let jts, let wts, v * 4 + 3 < jts.count, v * 4 + 3 < wts.count {
                            for k in 0..<4 where wts[v * 4 + k] > 0 {
                                let sj = Int(jts[v * 4 + k])
                                if sj < skinJoints.count, let j = jointOf[skinJoints[sj]] { row.append((j, wts[v * 4 + k])) }
                            }
                            if row.isEmpty { row = [(0, 1)] }
                        } else { row = [(rigidJoint, 1)] }
                        skinRows.append(row)
                        // Skinned vertices: bind space → the scene's rest pose.
                        let local = SIMD3(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2])
                        var p = transform.point(local)
                        var blend: RigXform?
                        if skinned, jts != nil {
                            let total = row.reduce(Float(0)) { $0 + $1.1 }
                            if total > 0 {
                                var m = RigXform(); m.a = 0; m.e = 0; m.i = 0
                                for (j, w) in row { m = Self.add(m, skinMatrix[j] ?? .identity, w / total) }
                                blend = m
                                p = m.point(local)
                            }
                        }
                        out.positions += [p.x, p.y, p.z]
                        if let nor, v * 3 + 2 < nor.count {
                            let n = SIMD3(nor[v * 3], nor[v * 3 + 1], nor[v * 3 + 2])
                            var q = (blend ?? transform).direction(n); let l = rigLength(q); if l > 0 { q /= l }
                            out.normals += [q.x, q.y, q.z]
                        } else { out.normals += [.nan, .nan, .nan] }
                        if let uv, v * 2 + 1 < uv.count { out.uvs += [uv[v * 2], 1 - uv[v * 2 + 1]] } else { out.uvs += [0, 0] }
                        if let col, v * col.comps + 2 < col.values.count {
                            colors += [col.values[v * col.comps], col.values[v * col.comps + 1], col.values[v * col.comps + 2]]; anyColor = true
                        } else { colors += [1, 1, 1] }
                    }
                    if let ii = prim["indices"] as? Int {
                        for i in try read(ii).values { guard Int(i) < count else { throw GLBError.badAccessor("index") }; out.indices.append(base + UInt32(i)) }
                    } else { out.indices += (0..<UInt32(count)).map { base + $0 } }
                    if transform.determinant < 0 {
                        var t = out.indices.count - (prim["indices"] != nil ? (try read(prim["indices"] as! Int)).values.count : count)
                        while t + 2 < out.indices.count { out.indices.swapAt(t + 1, t + 2); t += 3 }
                    }
                    if material == nil { material = prim["material"] as? Int }
                }
            }
            for c in nodes[n]["children"] as? [Int] ?? [] where c < nodes.count { try visit(c, depth: depth + 1) }
        }
        let scenes = json["scenes"] as? [[String: Any]] ?? []
        var roots = scenes.isEmpty ? [] : (scenes[min(scenes.count - 1, json["scene"] as? Int ?? 0)]["nodes"] as? [Int] ?? [])
        if roots.isEmpty { roots = nodes.indices.filter { parent[$0] == nil } }
        for r in roots where r < nodes.count { try visit(r, depth: 0) }
        guard out.triangleCount > 0 else { throw ImportError.empty }
        if out.normals.contains(where: { $0.isNaN }) { out.computeNormals() }

        // Texture.
        var texture: Data?
        let materials = json["materials"] as? [[String: Any]] ?? [], textures = json["textures"] as? [[String: Any]] ?? [], images = json["images"] as? [[String: Any]] ?? []
        if let m = material, m < materials.count, let pbr = materials[m]["pbrMetallicRoughness"] as? [String: Any], let ref = pbr["baseColorTexture"] as? [String: Any],
           let t = ref["index"] as? Int, t < textures.count, let src = textures[t]["source"] as? Int, src < images.count, let vi = images[src]["bufferView"] as? Int, vi < views.count {
            let v = views[vi], start = v["byteOffset"] as? Int ?? 0, length = v["byteLength"] as? Int ?? 0
            if start + length <= bin.count { texture = Data(bin[start..<(start + length)]) }
        }

        // Rig and animations.
        var rig: ImportedRig?
        if let skeleton {
            var skin = SkinInfluences(count: out.vertexCount)
            for (v, row) in skinRows.enumerated() {
                let top = row.sorted { $0.1 > $1.1 }.prefix(4)
                SkinWeightSolver.write(Array(top), into: &skin, vertex: v)
                if top.isEmpty || skin.influences(v).isEmpty { skin.joints[v * 4] = 0; skin.weights[v * 4] = 1 }
            }
            var base = [[Float]?](repeating: nil, count: skeleton.joints.count)
            for (node, j) in jointOf { base[j] = localTRS[node] }
            var clips: [KeyframeClip] = []
            for (ai, anim) in (json["animations"] as? [[String: Any]] ?? []).enumerated() {
                let samplers = anim["samplers"] as? [[String: Any]] ?? []
                var tracks: [KeyframeTrack] = [], duration: Float = 0
                for ch in anim["channels"] as? [[String: Any]] ?? [] {
                    guard let target = ch["target"] as? [String: Any], let node = target["node"] as? Int, let j = jointOf[node],
                          let path = (target["path"] as? String).flatMap(KeyframeTrack.Path.init(rawValue:)),
                          let si = ch["sampler"] as? Int, si < samplers.count,
                          let input = samplers[si]["input"] as? Int, let output = samplers[si]["output"] as? Int else { continue }
                    let times = try read(input).values, values = try read(output)
                    let interpolation = samplers[si]["interpolation"] as? String ?? "LINEAR"
                    var v = values.values
                    let width = values.comps
                    if interpolation == "CUBICSPLINE" {
                        // Keep the value of each (in-tangent, value, out-tangent) triple.
                        v = (0..<times.count).flatMap { k in Array(values.values[((k * 3 + 1) * width)..<((k * 3 + 2) * width)]) }
                    }
                    tracks.append(KeyframeTrack(joint: j, path: path, times: times, values: v, step: interpolation == "STEP"))
                    duration = max(duration, times.last ?? 0)
                }
                guard !tracks.isEmpty else { continue }
                let name = (anim["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Animation \(ai + 1)"
                clips.append(KeyframeClip(id: "file-\(ai)", name: name, duration: max(0.04, duration), tracks: tracks, base: base, pre: pre))
            }
            rig = ImportedRig(skeleton: skeleton, skin: skin, clips: clips)
        }
        var notes: [String] = []
        if let rig { notes.append(L10n.t("保留了文件里的骨骼（\(rig.skeleton.joints.count - 1) 个关节）和 \(rig.clips.count) 个动画", "Kept the file's skeleton (\(rig.skeleton.joints.count - 1) joints) and \(rig.clips.count) animations")) }
        if skins.count > 1 { notes.append(L10n.t("文件有 \(skins.count) 套蒙皮，只使用第一套", "The file has \(skins.count) skins; only the first is used")) }
        return ImportedModel(mesh: out, colors: anyColor ? colors : nil, texture: texture, textureName: nil, name: meshes.first?["name"] as? String, rig: rig, notes: notes)
    }
}
