import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// v1.76: OBJ (+ MTL), STL (binary / ASCII) and 3MF readers. Pure Swift.

enum OBJImporter {
    static func read(_ data: Data, companions: [String: Data]) throws -> ImportedModel {
        let text = String(decoding: data, as: UTF8.self)
        var v: [SIMD3<Float>] = [], vt: [SIMD2<Float>] = [], vn: [SIMD3<Float>] = [], vc: [SIMD3<Float>?] = []
        var out = GeneratedMesh()
        var colors: [Float] = [], anyColor = false
        var map: [String: UInt32] = [:]
        var mtllib: String?, usemtl: String?
        func index(_ s: Substring, _ count: Int) -> Int? {
            guard let i = Int(s), i != 0 else { return nil }
            let r = i > 0 ? i - 1 : count + i
            return r >= 0 && r < count ? r : nil
        }
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = parts.first else { continue }
            let nums = parts.dropFirst().compactMap { Float($0) }
            switch head {
            case "v" where nums.count >= 3:
                v.append(SIMD3(nums[0], nums[1], nums[2]))
                if nums.count >= 6 { vc.append(SIMD3(nums[3], nums[4], nums[5])); anyColor = true } else { vc.append(nil) }
            case "vt" where nums.count >= 2: vt.append(SIMD2(nums[0], nums[1]))
            case "vn" where nums.count >= 3: vn.append(SIMD3(nums[0], nums[1], nums[2]))
            case "mtllib": mtllib = parts.dropFirst().joined(separator: " ")
            case "usemtl": if usemtl == nil { usemtl = parts.dropFirst().joined(separator: " ") }
            case "f" where parts.count >= 4:
                var corner: [UInt32] = []
                for p in parts.dropFirst() {
                    let key = String(p)
                    if let existing = map[key] { corner.append(existing); continue }
                    let f = p.split(separator: "/", omittingEmptySubsequences: false)
                    guard let pi = index(f[0], v.count) else { continue }
                    let id = UInt32(out.vertexCount)
                    out.positions += [v[pi].x, v[pi].y, v[pi].z]
                    if f.count > 1, let ti = index(f[1], vt.count) { out.uvs += [vt[ti].x, vt[ti].y] } else { out.uvs += [0, 0] }
                    if f.count > 2, let ni = index(f[2], vn.count) { out.normals += [vn[ni].x, vn[ni].y, vn[ni].z] } else { out.normals += [.nan, .nan, .nan] }
                    let c = vc[pi] ?? SIMD3(1, 1, 1)
                    colors += [c.x, c.y, c.z]
                    map[key] = id
                    corner.append(id)
                }
                // Fan triangulation of the polygon.
                if corner.count >= 3 { for k in 1..<(corner.count - 1) { out.indices += [corner[0], corner[k], corner[k + 1]] } }
            default: break
            }
        }
        guard out.triangleCount > 0 else { throw ImportError.empty }
        if out.normals.contains(where: { $0.isNaN }) { out.computeNormals() }
        // Texture named by the material library (map_Kd).
        var textureName: String?
        if let lib = mtllib, let mtl = companions[(lib.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent.lowercased()] {
            var current: String?
            for raw in String(decoding: mtl, as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard let head = parts.first else { continue }
                if head == "newmtl" { current = parts.dropFirst().joined(separator: " ") }
                if head == "map_Kd", textureName == nil || current == usemtl { textureName = parts.last.map(String.init) }
            }
        }
        var notes: [String] = []
        if mtllib != nil && textureName == nil { notes.append(L10n.t("没有找到 OBJ 的贴图：导入时请同时选中 .mtl 和贴图图片", "The OBJ texture was not found: pick the .mtl and the texture image together with the .obj")) }
        return ImportedModel(mesh: out, colors: anyColor ? colors : nil, texture: nil, textureName: textureName, name: nil, rig: nil, notes: notes)
    }
}

enum STLImporter {
    static func read(_ data: Data) throws -> ImportedModel {
        let b = [UInt8](data)
        var triangles: [SIMD3<Float>] = []
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24) }
        let binaryCount = b.count >= 84 ? Int(UInt32(b[80]) | UInt32(b[81]) << 8 | UInt32(b[82]) << 16 | UInt32(b[83]) << 24) : -1
        if binaryCount >= 0, 84 + binaryCount * 50 == b.count {
            for t in 0..<binaryCount {
                let o = 84 + t * 50 + 12
                for k in 0..<3 { triangles.append(SIMD3(f32(o + k * 12), f32(o + k * 12 + 4), f32(o + k * 12 + 8))) }
            }
        } else {
            let text = String(decoding: data, as: UTF8.self)
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let parts = raw.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if parts.first == "vertex", parts.count >= 4, let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) { triangles.append(SIMD3(x, y, z)) }
            }
        }
        guard triangles.count >= 3 else { throw ImportError.empty }
        // Weld equal corners so the mesh is connected.
        var map: [SIMD3<Float>: UInt32] = [:]
        var out = GeneratedMesh()
        for p in triangles.prefix(triangles.count / 3 * 3) {
            if let id = map[p] { out.indices.append(id); continue }
            let id = UInt32(out.vertexCount)
            map[p] = id
            out.positions += [p.x, p.z, -p.y]; out.uvs += [0, 0]; out.indices.append(id)   // z-up → y-up
        }
        out.computeNormals()
        return ImportedModel(mesh: out, colors: nil, texture: nil, textureName: nil, name: nil, rig: nil,
                             notes: [L10n.t("STL 只有形状，没有颜色和贴图", "STL has shape only, no colours or texture")])
    }
}

enum ThreeMFImporter {
    final class Parser: NSObject, XMLParserDelegate {
        struct Object { var vertices: [SIMD3<Float>] = []; var triangles: [(UInt32, UInt32, UInt32, Int?, Int?)] = []; var pid: Int?; var pindex: Int?; var components: [(Int, RigXform)] = [] }
        var objects: [Int: Object] = [:]
        var items: [(Int, RigXform)] = []
        var groups: [Int: [SIMD3<Float>]] = [:]
        private var current: Int?, currentGroup: Int?
        static func transform(_ s: String?) -> RigXform {
            let v = (s ?? "").split(separator: " ").compactMap { Float($0) }
            guard v.count == 12 else { return .identity }
            var x = RigXform()
            x.a = v[0]; x.b = v[1]; x.c = v[2]; x.d = v[3]; x.e = v[4]; x.f = v[5]; x.g = v[6]; x.h = v[7]; x.i = v[8]; x.tx = v[9]; x.ty = v[10]; x.tz = v[11]
            return x
        }
        static func colour(_ s: String?) -> SIMD3<Float> {
            var hex = (s ?? "#FFFFFF").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
            if hex.count == 8 { hex = String(hex.prefix(6)) }
            let v = UInt32(hex, radix: 16) ?? 0xFFFFFF
            return SIMD3(Float(v >> 16 & 0xFF) / 255, Float(v >> 8 & 0xFF) / 255, Float(v & 0xFF) / 255)
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "object":
                if let id = a["id"].flatMap(Int.init) { current = id; objects[id] = Object(pid: a["pid"].flatMap(Int.init), pindex: a["pindex"].flatMap(Int.init)) }
            case "vertex":
                if let c = current, let x = a["x"].flatMap(Float.init), let y = a["y"].flatMap(Float.init), let z = a["z"].flatMap(Float.init) { objects[c]?.vertices.append(SIMD3(x, y, z)) }
            case "triangle":
                if let c = current, let v1 = a["v1"].flatMap(UInt32.init), let v2 = a["v2"].flatMap(UInt32.init), let v3 = a["v3"].flatMap(UInt32.init) {
                    objects[c]?.triangles.append((v1, v2, v3, a["pid"].flatMap(Int.init), a["p1"].flatMap(Int.init)))
                }
            case "component":
                if let c = current, let id = a["objectid"].flatMap(Int.init) { objects[c]?.components.append((id, Self.transform(a["transform"]))) }
            case "item":
                if let id = a["objectid"].flatMap(Int.init) { items.append((id, Self.transform(a["transform"]))) }
            case "basematerials", "colorgroup":
                currentGroup = a["id"].flatMap(Int.init); if let g = currentGroup { groups[g] = [] }
            case "base", "color":
                if let g = currentGroup { groups[g]?.append(Self.colour(a["displaycolor"] ?? a["color"])) }
            default: break
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            if local == "object" { current = nil }
            if local == "basematerials" || local == "colorgroup" { currentGroup = nil }
        }
    }

    static func read(_ data: Data) throws -> ImportedModel {
        let files: [String: [UInt8]]
        do { files = try ZipReader.entries(data) } catch { throw ImportError.damaged("3MF zip") }
        guard let model = files.first(where: { $0.key.lowercased().hasSuffix(".model") && $0.key.lowercased().contains("3d/") })?.value ?? files.first(where: { $0.key.lowercased().hasSuffix(".model") })?.value else {
            throw ImportError.damaged("no 3D model part")
        }
        let p = Parser()
        let xml = XMLParser(data: Data(model))
        xml.delegate = p
        guard xml.parse() else { throw ImportError.damaged("3MF XML") }
        var out = GeneratedMesh()
        var colors: [Float] = [], anyColor = false
        func emit(_ id: Int, _ t: RigXform, depth: Int) {
            guard depth < 16, let o = p.objects[id] else { return }
            for (child, ct) in o.components { emit(child, t * ct, depth: depth + 1) }
            for tri in o.triangles {
                let pid = tri.3 ?? o.pid, pindex = tri.4 ?? o.pindex
                let colour = pid.flatMap { p.groups[$0] }.flatMap { g in pindex.flatMap { $0 < g.count ? g[$0] : nil } }
                if colour != nil { anyColor = true }
                for vi in [tri.0, tri.1, tri.2] {
                    guard Int(vi) < o.vertices.count else { continue }
                    let q = t.point(o.vertices[Int(vi)])
                    out.indices.append(UInt32(out.vertexCount))
                    out.positions += [q.x, q.y, q.z]; out.uvs += [0, 0]
                    let c = colour ?? SIMD3(0.85, 0.85, 0.85)
                    colors += [c.x, c.y, c.z]
                }
            }
        }
        let items = p.items.isEmpty ? p.objects.keys.sorted().map { ($0, RigXform.identity) } : p.items
        for (id, t) in items { emit(id, t, depth: 0) }
        out.indices = Array(out.indices.prefix(out.indices.count / 3 * 3))
        guard out.triangleCount > 0 else { throw ImportError.empty }
        out.computeNormals()
        // 3MF is z-up (printing); turn to y-up.
        for v in 0..<out.vertexCount {
            let y = out.positions[v * 3 + 1], z = out.positions[v * 3 + 2]
            out.positions[v * 3 + 1] = z; out.positions[v * 3 + 2] = -y
            let ny = out.normals[v * 3 + 1], nz = out.normals[v * 3 + 2]
            out.normals[v * 3 + 1] = nz; out.normals[v * 3 + 2] = -ny
        }
        return ImportedModel(mesh: out, colors: anyColor ? colors : nil, texture: nil, textureName: nil, name: nil, rig: nil, notes: [])
    }
}
