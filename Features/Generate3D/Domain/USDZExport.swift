import Foundation

// v1.87: USDZ export without depending on Model I/O's export support.
// Moonlight writes the USD scene itself (ASCII USD: mesh, UVs, normals,
// UsdPreviewSurface material, and UsdSkel skeleton / skin / animation) and
// packs it as a USDZ: an uncompressed zip whose first file is the root
// layer and whose file data all start on 64-byte boundaries. The app then
// re-loads the result with RealityKit before offering it. Pure Swift.

// MARK: Matrices (column-major, translation in 12…14 — the layout of Mat4 and RigXform.matrix)

enum USDMatrix {
    static let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    static func multiply(_ a: [Float], _ b: [Float]) -> [Float] {
        var r = [Float](repeating: 0, count: 16)
        for c in 0..<4 { for row in 0..<4 {
            var s: Float = 0
            for k in 0..<4 { s += a[k * 4 + row] * b[c * 4 + k] }
            r[c * 4 + row] = s
        } }
        return r
    }

    static func translation(_ t: [Float]) -> [Float] { var m = identity; m[12] = t[0]; m[13] = t[1]; m[14] = t[2]; return m }

    /// Inverse of an affine matrix (last row 0 0 0 1).
    static func inverse(_ m: [Float]) -> [Float]? {
        let a = m[0], b = m[4], c = m[8], d = m[1], e = m[5], f = m[9], g = m[2], h = m[6], i = m[10]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12, det.isFinite else { return nil }
        let k = 1 / det
        let r00 = (e * i - f * h) * k, r01 = (c * h - b * i) * k, r02 = (b * f - c * e) * k
        let r10 = (f * g - d * i) * k, r11 = (a * i - c * g) * k, r12 = (c * d - a * f) * k
        let r20 = (d * h - e * g) * k, r21 = (b * g - a * h) * k, r22 = (a * e - b * d) * k
        let tx = m[12], ty = m[13], tz = m[14]
        return [r00, r10, r20, 0, r01, r11, r21, 0, r02, r12, r22, 0,
                -(r00 * tx + r01 * ty + r02 * tz), -(r10 * tx + r11 * ty + r12 * tz), -(r20 * tx + r21 * ty + r22 * tz), 1]
    }

    /// Translation, rotation quaternion (w, x, y, z) and scale.
    static func decompose(_ m: [Float]) -> (t: [Float], q: [Float], s: [Float]) {
        var x = [m[0], m[1], m[2]], y = [m[4], m[5], m[6]], z = [m[8], m[9], m[10]]
        func len(_ v: [Float]) -> Float { (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot() }
        let s = [max(1e-8, len(x)), max(1e-8, len(y)), max(1e-8, len(z))]
        x = x.map { $0 / s[0] }; y = y.map { $0 / s[1] }; z = z.map { $0 / s[2] }
        // Rotation matrix R (columns x, y, z) → quaternion.
        let r00 = x[0], r11 = y[1], r22 = z[2]
        var q: [Float]
        let trace = r00 + r11 + r22
        if trace > 0 {
            let k = 0.5 / (trace + 1).squareRoot()
            q = [0.25 / k, (y[2] - z[1]) * k, (z[0] - x[2]) * k, (x[1] - y[0]) * k]
        } else if r00 > r11 && r00 > r22 {
            let k = 2 * (1 + r00 - r11 - r22).squareRoot()
            q = [(y[2] - z[1]) / k, 0.25 * k, (y[0] + x[1]) / k, (z[0] + x[2]) / k]
        } else if r11 > r22 {
            let k = 2 * (1 + r11 - r00 - r22).squareRoot()
            q = [(z[0] - x[2]) / k, (y[0] + x[1]) / k, 0.25 * k, (z[1] + y[2]) / k]
        } else {
            let k = 2 * (1 + r22 - r00 - r11).squareRoot()
            q = [(x[1] - y[0]) / k, (z[0] + x[2]) / k, (z[1] + y[2]) / k, 0.25 * k]
        }
        let n = (q.map { $0 * $0 }.reduce(0, +)).squareRoot()
        if n > 0 { q = q.map { $0 / n } }
        return ([m[12], m[13], m[14]], q, s)
    }
}

// MARK: Skeleton data in USD terms

/// A skeleton, its skin and sampled animation, independent of which rig
/// system made it. Joint i's parent is always earlier in the list.
struct USDSkinnedData: Equatable, Sendable {
    var jointNames: [String]
    var parents: [Int?]
    /// World transforms at bind time.
    var bindWorld: [[Float]]
    /// Local (parent-relative) rest transforms.
    var restLocal: [[Float]]
    /// Four joints and weights per vertex.
    var jointIndices: [Int32]
    var jointWeights: [Float]
    var framesPerSecond: Double = 24
    /// Per frame, per joint local transforms (empty: no animation).
    var frames: [[[Float]]] = []
    var clips: [(name: String, start: Int, end: Int)] = []

    static func == (a: USDSkinnedData, b: USDSkinnedData) -> Bool {
        a.jointNames == b.jointNames && a.parents == b.parents && a.bindWorld == b.bindWorld && a.restLocal == b.restLocal &&
            a.jointIndices == b.jointIndices && a.jointWeights == b.jointWeights && a.frames == b.frames && a.clips.map(\.name) == b.clips.map(\.name)
    }

    var valid: Bool {
        let n = jointNames.count
        return n > 0 && parents.count == n && bindWorld.count == n && restLocal.count == n &&
            parents.enumerated().allSatisfy { i, p in p.map { $0 < i } ?? true } &&
            jointIndices.count == jointWeights.count && jointIndices.count % 4 == 0 && jointIndices.allSatisfy { $0 >= 0 && Int($0) < n } &&
            frames.allSatisfy { $0.count == n }
    }

    /// USD joint paths ("torso/head"), with names made safe and unique.
    var jointPaths: [String] {
        var used = Set<String>(), names: [String] = []
        for raw in jointNames {
            var name = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" })
            if name.isEmpty || name.first!.isNumber { name = "j_" + name }
            var unique = name, k = 1
            while used.contains(unique) { k += 1; unique = "\(name)_\(k)" }
            used.insert(unique); names.append(unique)
        }
        var paths: [String] = []
        for i in names.indices { paths.append(parents[i].map { paths[$0] + "/" + names[i] } ?? names[i]) }
        return paths
    }

    /// Local transforms from world ones.
    static func locals(world: [[Float]], parents: [Int?]) -> [[Float]] {
        world.indices.map { i in
            guard let p = parents[i], let inv = USDMatrix.inverse(world[p]) else { return world[i] }
            return USDMatrix.multiply(inv, world[i])
        }
    }

    /// Moonlight's own rig (auto-rig, text-made characters): ten bones, two
    /// weights per vertex, procedural clips. Joint world transform at time t
    /// is RigPose's bone matrix × translation(head), so USD's skinning
    /// (world × inverse bind) is exactly the matrix the preview uses.
    static func moonlight(skeleton: RigSkeleton, skin: SkinWeights, clips: [RigClip], fps: Double = 24) -> USDSkinnedData? {
        let bones = RigBone.allCases
        guard bones.allSatisfy({ skeleton.bone($0) != nil }), skin.valid else { return nil }
        let heads = bones.map { skeleton.bone($0)!.head }
        let parents: [Int?] = bones.map { b in b.parent.map(\.rawValue) }
        let bind = heads.map(USDMatrix.translation)
        var data = USDSkinnedData(jointNames: bones.map { "\($0)" }, parents: parents, bindWorld: bind, restLocal: locals(world: bind, parents: parents),
                                  jointIndices: [], jointWeights: [], framesPerSecond: fps)
        for v in 0..<skin.count {
            data.jointIndices += [Int32(skin.bone0[v]), Int32(skin.bone1[v]), 0, 0]
            data.jointWeights += [skin.weight0[v], 1 - skin.weight0[v], 0, 0]
        }
        for clip in clips {
            let count = max(2, Int((Double(clip.period) * fps).rounded()))
            let start = data.frames.count
            for f in 0..<count {
                let deltas = RigPose.matrices(skeleton, clip: clip, time: Float(Double(f) / fps))
                let world = bones.map { USDMatrix.multiply(deltas[$0.rawValue].m, bind[$0.rawValue]) }
                data.frames.append(locals(world: world, parents: parents))
            }
            data.clips.append((clip.name, start, data.frames.count - 1))
        }
        return data
    }

    /// Rigs from model files (GLB / FBX): their own hierarchy, four weights,
    /// keyframed or procedural motion clips, sampled through the same pose code the app plays.
    static func imported(skeleton: SkeletonDefinition, skin: SkinInfluences, clips: [MotionClip], fps: Double = 24) -> USDSkinnedData? {
        let joints = skeleton.joints
        guard !joints.isEmpty, skin.joints.count == skin.weights.count else { return nil }
        // Parent-first order (file order may not be).
        var order: [Int] = [], placed = Set<Int>()
        while order.count < joints.count {
            let before = order.count
            for i in joints.indices where !placed.contains(i) {
                if let p = skeleton.parentIndex(i), !placed.contains(p) { continue }
                order.append(i); placed.insert(i)
            }
            if order.count == before { return nil }   // a cycle
        }
        let newIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        let parents: [Int?] = order.map { skeleton.parentIndex($0).flatMap { newIndex[$0] } }
        let worldRest = skeleton.worldRest
        let bind = order.map { i in RigXform(matrix: joints[i].inverseBindMatrix)?.inverse?.matrix ?? worldRest[i].matrix }
        var data = USDSkinnedData(jointNames: order.map { joints[$0].jointID }, parents: parents, bindWorld: bind,
                                  restLocal: order.map { joints[$0].restTransform }, jointIndices: skin.joints.map { Int32(newIndex[Int($0)] ?? 0) },
                                  jointWeights: skin.weights, framesPerSecond: fps)
        for clip in clips where clip.period > 0 {
            let count = max(2, Int((Double(clip.period) * fps).rounded()))
            let start = data.frames.count
            for f in 0..<count {
                let world = clip.pose(skeleton, at: Float(Double(f) / fps)).world(skeleton).map(\.matrix)
                data.frames.append(locals(world: order.map { world[$0] }, parents: parents))
            }
            data.clips.append((clip.name, start, data.frames.count - 1))
        }
        return data
    }
}

// MARK: USD scene text

/// What a USDZ file contains, for the export screen.
struct USDZContents: Equatable, Sendable {
    var vertices: Int
    var triangles: Int
    var texture: Bool
    var vertexColours: Bool
    var joints: Int
    var skinned: Bool
    var clipNames: [String]
}

enum USDAWriter {
    static func f(_ v: Float) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded() && abs(v) < 1e7 { return String(Int(v)) }
        return String(format: "%.6g", v)
    }
    static func tuple(_ values: ArraySlice<Float>) -> String { "(" + values.map(f).joined(separator: ", ") + ")" }
    static func matrix(_ m: [Float]) -> String {
        // USD writes rows of a row-vector matrix: our columns.
        "( " + (0..<4).map { tuple(m[($0 * 4)..<($0 * 4 + 4)]) }.joined(separator: ", ") + " )"
    }

    static func scene(mesh: GeneratedMesh, colors: [Float]?, textureName: String?, skin: USDSkinnedData?) -> (text: String, contents: USDZContents) {
        let skinned = skin.map { $0.valid && $0.jointIndices.count == mesh.vertexCount * 4 } ?? false
        let anim = skinned && !(skin?.frames.isEmpty ?? true)
        var out = "#usda 1.0\n(\n    defaultPrim = \"Root\"\n    metersPerUnit = 1\n    upAxis = \"Y\"\n"
        if anim, let s = skin {
            out += "    startTimeCode = 0\n    endTimeCode = \(max(1, s.frames.count - 1))\n    timeCodesPerSecond = \(f(Float(s.framesPerSecond)))\n"
            out += "    customLayerData = {\n        dictionary moonlightClips = {\n"
            for (i, c) in s.clips.enumerated() {
                let key = "clip\(i)_" + String(c.name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.prefix(40).map(Character.init))
                out += "            int2 \(key) = (\(c.start), \(c.end))\n"
            }
            out += "        }\n    }\n"
        }
        out += ")\n\n"
        out += "def \(skinned ? "SkelRoot" : "Xform") \"Root\" (\n    kind = \"component\"\n)\n{\n"
        if skinned, let s = skin {
            let paths = s.jointPaths.map { "\"\($0)\"" }.joined(separator: ", ")
            out += "    def Skeleton \"Skel\" (\n        prepend apiSchemas = [\"SkelBindingAPI\"]\n    )\n    {\n"
            out += "        uniform token[] joints = [\(paths)]\n"
            out += "        uniform matrix4d[] bindTransforms = [\(s.bindWorld.map(matrix).joined(separator: ", "))]\n"
            out += "        uniform matrix4d[] restTransforms = [\(s.restLocal.map(matrix).joined(separator: ", "))]\n"
            if anim { out += "        rel skel:animationSource = </Root/Skel/Anim>\n" }
            if anim {
                out += "\n        def SkelAnimation \"Anim\"\n        {\n            uniform token[] joints = [\(paths)]\n"
                var t = "", r = "", sc = ""
                for (i, frame) in s.frames.enumerated() {
                    let parts = frame.map(USDMatrix.decompose)
                    t += "                \(i): [" + parts.map { tuple($0.t[0..<3]) }.joined(separator: ", ") + "],\n"
                    r += "                \(i): [" + parts.map { tuple($0.q[0..<4]) }.joined(separator: ", ") + "],\n"
                    sc += "                \(i): [" + parts.map { tuple($0.s[0..<3]) }.joined(separator: ", ") + "],\n"
                }
                out += "            float3[] translations.timeSamples = {\n\(t)            }\n"
                out += "            quatf[] rotations.timeSamples = {\n\(r)            }\n"
                out += "            half3[] scales.timeSamples = {\n\(sc)            }\n        }\n"
            }
            out += "    }\n\n"
        }
        let schemas = skinned ? "\"SkelBindingAPI\", \"MaterialBindingAPI\"" : "\"MaterialBindingAPI\""
        out += "    def Mesh \"Mesh\" (\n        prepend apiSchemas = [\(schemas)]\n    )\n    {\n"
        out += "        uniform bool doubleSided = 0\n        uniform token subdivisionScheme = \"none\"\n"
        out += "        int[] faceVertexCounts = [" + Array(repeating: "3", count: mesh.triangleCount).joined(separator: ", ") + "]\n"
        out += "        int[] faceVertexIndices = [" + mesh.indices.prefix(mesh.triangleCount * 3).map { String($0) }.joined(separator: ", ") + "]\n"
        out += "        point3f[] points = [" + (0..<mesh.vertexCount).map { tuple(mesh.positions[($0 * 3)..<($0 * 3 + 3)]) }.joined(separator: ", ") + "]\n"
        if mesh.normals.count == mesh.positions.count {
            out += "        normal3f[] normals = [" + (0..<mesh.vertexCount).map { tuple(mesh.normals[($0 * 3)..<($0 * 3 + 3)]) }.joined(separator: ", ") + "] (\n            interpolation = \"vertex\"\n        )\n"
        }
        if mesh.uvs.count == mesh.vertexCount * 2 {
            // USD's st has v going up; the app's UVs go down like image rows.
            out += "        texCoord2f[] primvars:st = [" + (0..<mesh.vertexCount).map { "(\(f(mesh.uvs[$0 * 2])), \(f(1 - mesh.uvs[$0 * 2 + 1])))" }.joined(separator: ", ") + "] (\n            interpolation = \"vertex\"\n        )\n"
        }
        let useColours = textureName == nil && (colors?.count ?? 0) == mesh.vertexCount * 3
        if useColours, let colors {
            out += "        color3f[] primvars:displayColor = [" + (0..<mesh.vertexCount).map { tuple(colors[($0 * 3)..<($0 * 3 + 3)]) }.joined(separator: ", ") + "] (\n            interpolation = \"vertex\"\n        )\n"
        }
        if skinned, let s = skin {
            out += "        int[] primvars:skel:jointIndices = [" + s.jointIndices.map { String($0) }.joined(separator: ", ") + "] (\n            elementSize = 4\n            interpolation = \"vertex\"\n        )\n"
            out += "        float[] primvars:skel:jointWeights = [" + s.jointWeights.map(f).joined(separator: ", ") + "] (\n            elementSize = 4\n            interpolation = \"vertex\"\n        )\n"
            out += "        matrix4d primvars:skel:geomBindTransform = \(matrix(USDMatrix.identity))\n"
            out += "        rel skel:skeleton = </Root/Skel>\n"
        }
        out += "        rel material:binding = </Root/Materials/Surface>\n    }\n\n"
        out += "    def Scope \"Materials\"\n    {\n        def Material \"Surface\"\n        {\n"
        out += "            token outputs:surface.connect = </Root/Materials/Surface/Preview.outputs:surface>\n"
        out += "            def Shader \"Preview\"\n            {\n                uniform token info:id = \"UsdPreviewSurface\"\n"
        if textureName != nil {
            out += "                color3f inputs:diffuseColor.connect = </Root/Materials/Surface/Texture.outputs:rgb>\n"
        } else if useColours {
            out += "                color3f inputs:diffuseColor.connect = </Root/Materials/Surface/Colours.outputs:result>\n"
        } else {
            out += "                color3f inputs:diffuseColor = (0.8, 0.8, 0.8)\n"
        }
        out += "                float inputs:roughness = 0.6\n                float inputs:metallic = 0\n                token outputs:surface\n            }\n"
        if let textureName {
            out += "            def Shader \"ST\"\n            {\n                uniform token info:id = \"UsdPrimvarReader_float2\"\n                string inputs:varname = \"st\"\n                float2 outputs:result\n            }\n"
            out += "            def Shader \"Texture\"\n            {\n                uniform token info:id = \"UsdUVTexture\"\n                asset inputs:file = @\(textureName)@\n"
            out += "                float2 inputs:st.connect = </Root/Materials/Surface/ST.outputs:result>\n                token inputs:wrapS = \"repeat\"\n                token inputs:wrapT = \"repeat\"\n"
            out += "                token inputs:sourceColorSpace = \"sRGB\"\n                float3 outputs:rgb\n            }\n"
        } else if useColours {
            out += "            def Shader \"Colours\"\n            {\n                uniform token info:id = \"UsdPrimvarReader_float3\"\n                string inputs:varname = \"displayColor\"\n                float3 outputs:result\n            }\n"
        }
        out += "        }\n    }\n}\n"
        let contents = USDZContents(vertices: mesh.vertexCount, triangles: mesh.triangleCount, texture: textureName != nil, vertexColours: useColours,
                                    joints: skinned ? (skin?.jointNames.count ?? 0) : 0, skinned: skinned, clipNames: anim ? (skin?.clips.map(\.name) ?? []) : [])
        return (out, contents)
    }
}

// MARK: USDZ package

/// USDZ: a zip with no compression and no encryption, the root layer
/// first, and every file's data starting on a 64-byte boundary (padding
/// goes in the local header's extra field).
enum USDZPackage {
    static let alignment = 64

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func pack(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32, _ d: inout Data) { for k in 0..<4 { d.append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) } }
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let offset = out.count
            let headerEnd = offset + 30 + name.count
            var pad = (alignment - (headerEnd + 4) % alignment) % alignment
            // The extra field carries the padding (id 0x1986, as Pixar's packager does).
            if pad < 0 { pad += alignment }
            var extra = Data(); u16(0x1986, &extra); u16(pad, &extra); extra.append(Data(repeating: 0, count: pad))
            u32(0x0403_4B50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(0, &out); u16(0x21, &out)
            u32(crc, &out); u32(UInt32(file.data.count), &out); u32(UInt32(file.data.count), &out)
            u16(name.count, &out); u16(extra.count, &out); out.append(name); out.append(extra)
            out.append(file.data)
            u32(0x0201_4B50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0x21, &central)
            u32(crc, &central); u32(UInt32(file.data.count), &central); u32(UInt32(file.data.count), &central)
            u16(name.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central)
            u32(UInt32(offset), &central); central.append(name)
        }
        let centralOffset = out.count
        out.append(central)
        u32(0x0605_4B50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(UInt32(central.count), &out); u32(UInt32(centralOffset), &out); u16(0, &out)
        return out
    }

    /// The stored files (name, data offset, data), for checks.
    static func entries(_ zip: Data) -> [(name: String, offset: Int, data: Data)]? {
        let b = [UInt8](zip)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        var o = 0, out: [(String, Int, Data)] = []
        while o + 30 <= b.count && u32(o) == 0x0403_4B50 {
            guard u16(o + 8) == 0 else { return nil }   // compressed: not a USDZ
            let size = u32(o + 18), nameLength = u16(o + 26), extraLength = u16(o + 28)
            let start = o + 30 + nameLength + extraLength
            guard start + size <= b.count else { return nil }
            out.append((String(decoding: b[(o + 30)..<(o + 30 + nameLength)], as: UTF8.self), start, Data(b[start..<(start + size)])))
            o = start + size
        }
        return out.isEmpty ? nil : out
    }

    /// A whole USDZ for a mesh (and skin / animation).
    static func make(mesh: GeneratedMesh, colors: [Float]? = nil, texture: Data?, skin: USDSkinnedData?) -> (data: Data, contents: USDZContents) {
        let ext = texture.map { $0.starts(with: [0xFF, 0xD8]) ? "jpg" : "png" }
        let textureName = ext.map { "texture." + $0 }
        let scene = USDAWriter.scene(mesh: mesh, colors: colors, textureName: textureName, skin: skin)
        var files: [(String, Data)] = [("model.usda", Data(scene.text.utf8))]
        if let texture, let textureName { files.append((textureName, texture)) }
        return (pack(files), scene.contents)
    }
}
