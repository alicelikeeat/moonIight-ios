import Foundation

// v1.73: binary glTF 2.0 (.glb) import and export. Reads triangle meshes
// (positions, normals, first UV set, indices) from every mesh node of the
// default scene with node transforms applied, plus the first base-colour
// texture's image bytes. Existing skins / animations in the file are
// ignored (the model is rigged again). Writes a single textured mesh for
// export and cloud upload. Pure Swift.

enum GLBError: Error, Equatable, LocalizedError {
    case notGLB, unsupportedVersion(Int), badChunk, badJSON, noMesh, badAccessor(String), unsupportedPrimitive(Int), tooLarge
    var errorDescription: String? {
        switch self {
        case .notGLB: L10n.t("不是 GLB 文件（需要二进制 glTF 2.0）", "Not a GLB file (binary glTF 2.0 needed)")
        case .unsupportedVersion(let v): L10n.t("不支持的 glTF 版本 \(v)", "Unsupported glTF version \(v)")
        case .badChunk, .badJSON: L10n.t("GLB 文件已损坏", "The GLB file is damaged")
        case .noMesh: L10n.t("GLB 里没有三角网格", "No triangle mesh in the GLB")
        case .badAccessor(let what): L10n.t("GLB 数据无法读取：", "GLB data could not be read: ") + what
        case .unsupportedPrimitive(let mode): L10n.t("暂不支持的图元类型 \(mode)（只支持三角形）", "Unsupported primitive mode \(mode) (triangles only)")
        case .tooLarge: L10n.t("模型太大（超过 100 万个顶点）", "Model too large (over 1 million vertices)")
        }
    }
}

struct GLBModel: Sendable {
    var mesh: GeneratedMesh
    /// Encoded image (PNG / JPEG) of the first base-colour texture.
    var texture: Data?
    var textureMime: String?
    var name: String?
}

enum GLBCodec {
    static let vertexLimit = 1_000_000

    // MARK: Read

    static func read(_ data: Data) throws -> GLBModel {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24) }
        guard bytes.count >= 20, u32(0) == 0x4654_6C67 else { throw GLBError.notGLB }
        guard u32(4) == 2 else { throw GLBError.unsupportedVersion(u32(4)) }
        let total = min(bytes.count, u32(8))
        var offset = 12, json: [String: Any]?, bin: ArraySlice<UInt8> = []
        while offset + 8 <= total {
            let length = u32(offset), type = u32(offset + 4)
            guard offset + 8 + length <= total else { throw GLBError.badChunk }
            let body = bytes[(offset + 8)..<(offset + 8 + length)]
            if type == 0x4E4F_534A { json = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] }
            else if type == 0x004E_4942 && bin.isEmpty { bin = body }
            offset += 8 + length + (4 - length % 4) % 4
        }
        guard let json else { throw GLBError.badJSON }
        let binary = Array(bin)
        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let nodes = json["nodes"] as? [[String: Any]] ?? []

        func viewBytes(_ index: Int) throws -> (data: ArraySlice<UInt8>, stride: Int?) {
            guard index < views.count, (views[index]["buffer"] as? Int ?? 0) == 0 else { throw GLBError.badAccessor("bufferView") }
            let v = views[index], start = v["byteOffset"] as? Int ?? 0, length = v["byteLength"] as? Int ?? 0
            guard start >= 0, length >= 0, start + length <= binary.count else { throw GLBError.badAccessor("bufferView range") }
            return (binary[start..<(start + length)], v["byteStride"] as? Int)
        }
        /// Accessor as floats (components per element) or integers.
        func floats(_ index: Int, components want: Int) throws -> [Float] {
            guard index < accessors.count else { throw GLBError.badAccessor("accessor") }
            let a = accessors[index]
            let count = a["count"] as? Int ?? 0, type = a["componentType"] as? Int ?? 0, normalized = a["normalized"] as? Bool ?? false
            let comps = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as? String ?? ""] ?? 0
            guard comps == want, count >= 0, count <= vertexLimit * 3 else { throw GLBError.badAccessor("type") }
            guard let viewIndex = a["bufferView"] as? Int else { return [Float](repeating: 0, count: count * comps) }
            let (view, stride) = try viewBytes(viewIndex)
            let size = [5126: 4, 5125: 4, 5123: 2, 5122: 2, 5121: 1, 5120: 1][type] ?? 0
            guard size > 0 else { throw GLBError.badAccessor("component type") }
            let step = stride ?? size * comps, base = view.startIndex + (a["byteOffset"] as? Int ?? 0)
            guard count == 0 || base + step * (count - 1) + size * comps <= view.endIndex else { throw GLBError.badAccessor("accessor range") }
            var out = [Float](repeating: 0, count: count * comps)
            for i in 0..<count { for c in 0..<comps {
                let o = base + i * step + c * size
                let value: Float
                switch type {
                case 5126: value = Float(bitPattern: UInt32(binary[o]) | UInt32(binary[o + 1]) << 8 | UInt32(binary[o + 2]) << 16 | UInt32(binary[o + 3]) << 24)
                case 5125: value = Float(UInt32(binary[o]) | UInt32(binary[o + 1]) << 8 | UInt32(binary[o + 2]) << 16 | UInt32(binary[o + 3]) << 24)
                case 5123: let u = UInt16(binary[o]) | UInt16(binary[o + 1]) << 8; value = normalized ? Float(u) / 65535 : Float(u)
                case 5122: let u = Int16(bitPattern: UInt16(binary[o]) | UInt16(binary[o + 1]) << 8); value = normalized ? max(-1, Float(u) / 32767) : Float(u)
                case 5121: value = normalized ? Float(binary[o]) / 255 : Float(binary[o])
                default: let u = Int8(bitPattern: binary[o]); value = normalized ? max(-1, Float(u) / 127) : Float(u)
                }
                out[i * comps + c] = value
            } }
            return out
        }

        // Node transforms (matrix or TRS), from the default scene down.
        func local(_ node: [String: Any]) -> RigXform {
            if let m = node["matrix"] as? [Double], m.count == 16, let x = RigXform(matrix: m.map(Float.init)) { return x }
            let t = (node["translation"] as? [Double])?.map(Float.init) ?? [0, 0, 0]
            let r = (node["rotation"] as? [Double])?.map(Float.init) ?? [0, 0, 0, 1]
            let s = (node["scale"] as? [Double])?.map(Float.init) ?? [1, 1, 1]
            var x = quaternion(r)
            x.a *= s[0]; x.b *= s[0]; x.c *= s[0]; x.d *= s[1]; x.e *= s[1]; x.f *= s[1]; x.g *= s[2]; x.h *= s[2]; x.i *= s[2]
            x.tx = t[0]; x.ty = t[1]; x.tz = t[2]
            return x
        }
        var instances: [(mesh: Int, transform: RigXform)] = []
        func visit(_ index: Int, _ parent: RigXform, depth: Int) {
            guard index < nodes.count, depth < 64 else { return }
            let world = parent * local(nodes[index])
            if let m = nodes[index]["mesh"] as? Int { instances.append((m, world)) }
            for child in nodes[index]["children"] as? [Int] ?? [] { visit(child, world, depth: depth + 1) }
        }
        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let roots = scenes.isEmpty ? [] : (scenes[min(scenes.count - 1, json["scene"] as? Int ?? 0)]["nodes"] as? [Int] ?? [])
        for r in roots { visit(r, .identity, depth: 0) }
        if instances.isEmpty { instances = meshes.indices.map { ($0, .identity) } }

        var out = GeneratedMesh()
        var hasNormals = true
        var textureMaterial: Int?
        for (meshIndex, transform) in instances where meshIndex < meshes.count {
            for primitive in meshes[meshIndex]["primitives"] as? [[String: Any]] ?? [] {
                let mode = primitive["mode"] as? Int ?? 4
                guard mode == 4 else { throw GLBError.unsupportedPrimitive(mode) }
                let attributes = primitive["attributes"] as? [String: Int] ?? [:]
                guard let positionIndex = attributes["POSITION"] else { continue }
                let positions = try floats(positionIndex, components: 3)
                let count = positions.count / 3
                guard out.vertexCount + count <= vertexLimit else { throw GLBError.tooLarge }
                let normals = try attributes["NORMAL"].map { try floats($0, components: 3) }
                let uvs = try attributes["TEXCOORD_0"].map { try floats($0, components: 2) }
                if normals == nil { hasNormals = false }
                let base = UInt32(out.vertexCount)
                for v in 0..<count {
                    let p = transform.point(SIMD3(positions[v * 3], positions[v * 3 + 1], positions[v * 3 + 2]))
                    out.positions += [p.x, p.y, p.z]
                    if let normals {
                        var n = transform.direction(SIMD3(normals[v * 3], normals[v * 3 + 1], normals[v * 3 + 2]))
                        let l = rigLength(n); if l > 0 { n /= l }
                        out.normals += [n.x, n.y, n.z]
                    } else { out.normals += [0, 0, 1] }
                    // glTF UV origin is top-left; ours is bottom-left.
                    out.uvs += uvs.map { [$0[v * 2], 1 - $0[v * 2 + 1]] } ?? [0, 0]
                }
                let indexStart = out.indices.count
                if let indexAccessor = primitive["indices"] as? Int {
                    let indices = try floats(indexAccessor, components: 1)
                    for i in indices { guard Int(i) < count else { throw GLBError.badAccessor("index") }; out.indices.append(base + UInt32(i)) }
                } else {
                    out.indices += (0..<UInt32(count)).map { base + $0 }
                }
                if textureMaterial == nil, let m = primitive["material"] as? Int { textureMaterial = m }
                // Mirrored transforms flip the winding.
                if transform.determinant < 0 {
                    var t = indexStart
                    while t + 2 < out.indices.count { out.indices.swapAt(t + 1, t + 2); t += 3 }
                }
            }
        }
        guard out.triangleCount > 0 else { throw GLBError.noMesh }
        if !hasNormals { out.computeNormals() }

        // First base-colour texture image.
        var texture: Data?, mime: String?
        let materials = json["materials"] as? [[String: Any]] ?? []
        let textures = json["textures"] as? [[String: Any]] ?? []
        let images = json["images"] as? [[String: Any]] ?? []
        if let m = textureMaterial, m < materials.count,
           let pbr = materials[m]["pbrMetallicRoughness"] as? [String: Any], let ref = pbr["baseColorTexture"] as? [String: Any],
           let t = ref["index"] as? Int, t < textures.count, let source = textures[t]["source"] as? Int, source < images.count,
           let view = images[source]["bufferView"] as? Int, let bytes = try? viewBytes(view) {
            texture = Data(bytes.data); mime = images[source]["mimeType"] as? String
        }
        let name = meshes.first?["name"] as? String
        return GLBModel(mesh: out, texture: texture, textureMime: mime, name: name)
    }

    static func quaternion(_ q: [Float]) -> RigXform {
        let x = q[0], y = q[1], z = q[2], w = q[3]
        var r = RigXform()
        r.a = 1 - 2 * (y * y + z * z); r.b = 2 * (x * y + z * w); r.c = 2 * (x * z - y * w)
        r.d = 2 * (x * y - z * w); r.e = 1 - 2 * (x * x + z * z); r.f = 2 * (y * z + x * w)
        r.g = 2 * (x * z + y * w); r.h = 2 * (y * z - x * w); r.i = 1 - 2 * (x * x + y * y)
        return r
    }

    // MARK: Write

    /// One mesh, one material; PNG / JPEG texture embedded when given.
    static func write(_ mesh: GeneratedMesh, texture: Data? = nil, textureMime: String = "image/png", name: String = "moonlight") -> Data {
        var bin = Data()
        func align() { while bin.count % 4 != 0 { bin.append(0) } }
        func appendFloats(_ values: [Float]) -> (Int, Int) {
            align(); let start = bin.count
            for v in values { var b = v.bitPattern.littleEndian; withUnsafeBytes(of: &b) { bin.append(contentsOf: $0) } }
            return (start, bin.count - start)
        }
        let b = mesh.bounds
        let pos = appendFloats(mesh.positions), nor = appendFloats(mesh.normals.count == mesh.positions.count ? mesh.normals : [Float](repeating: 0, count: mesh.positions.count))
        // Back to glTF's top-left UV origin.
        var flipped = mesh.uvs
        for i in stride(from: 1, to: flipped.count, by: 2) { flipped[i] = 1 - flipped[i] }
        let uv = appendFloats(flipped)
        align(); let idxStart = bin.count
        for i in mesh.indices { var v = i.littleEndian; withUnsafeBytes(of: &v) { bin.append(contentsOf: $0) } }
        let idx = (idxStart, bin.count - idxStart)
        var image: (Int, Int)?
        if let texture { align(); image = (bin.count, texture.count); bin.append(texture) }
        align()
        var views: [[String: Any]] = [
            ["buffer": 0, "byteOffset": pos.0, "byteLength": pos.1, "target": 34962],
            ["buffer": 0, "byteOffset": nor.0, "byteLength": nor.1, "target": 34962],
            ["buffer": 0, "byteOffset": uv.0, "byteLength": uv.1, "target": 34962],
            ["buffer": 0, "byteOffset": idx.0, "byteLength": idx.1, "target": 34963],
        ]
        if let image { views.append(["buffer": 0, "byteOffset": image.0, "byteLength": image.1]) }
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Moonlight"],
            "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0, "name": name]],
            "meshes": [["name": name, "primitives": [["attributes": ["POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2], "indices": 3, "material": 0, "mode": 4]]]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": mesh.vertexCount, "type": "VEC3", "min": b.min.map(Double.init), "max": b.max.map(Double.init)],
                ["bufferView": 1, "componentType": 5126, "count": mesh.vertexCount, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5126, "count": mesh.vertexCount, "type": "VEC2"],
                ["bufferView": 3, "componentType": 5125, "count": mesh.indices.count, "type": "SCALAR"],
            ],
            "bufferViews": views,
            "buffers": [["byteLength": bin.count]],
            "materials": [["name": name, "pbrMetallicRoughness": (image != nil ? ["baseColorTexture": ["index": 0], "metallicFactor": 0, "roughnessFactor": 0.8] : ["metallicFactor": 0, "roughnessFactor": 0.8]) as [String: Any]]],
        ]
        if image != nil {
            json["textures"] = [["source": 0]]
            json["images"] = [["bufferView": 4, "mimeType": textureMime]]
        }
        var jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var out = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + jsonData.count + 8 + bin.count)
        u32(jsonData.count); u32(0x4E4F_534A); out.append(jsonData)
        u32(bin.count); u32(0x004E_4942); out.append(bin)
        return out
    }
}
