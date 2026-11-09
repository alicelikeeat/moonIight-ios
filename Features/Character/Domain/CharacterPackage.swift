import Foundation

// v1.91: the Moonlight character standard on disk, and the checks every
// character passes before it may enter a world.
//
// A CharacterPackage is a folder:
//   Manifest.json            identity, versions, source and licence, history
//   Appearance.json          shape, skin material, outfit, equipment
//   Skeleton/Skeleton.json   joints (ids, parents, bind, limits, sources)
//   Motions/MotionLibrary.json  motion ids used + any custom motions
//   Equipment/Sockets.json   attachment sockets
//   Diagnostics/Validation.json  the last validation report
//   Meshes/LOD<n>.m3dg, Skin/LOD<n>.skin  only for custom geometry
// HumanBase characters store no geometry: their meshes are rebuilt from the
// shared base body and their shape, so many characters cost no extra disk.
// Saves go to a temporary folder first and replace the old one in one move;
// a package from a newer format is never overwritten; a damaged package is
// skipped by the list, never fatal. Pure Foundation (tested on Linux).

// MARK: Validation

struct CharacterIssue: Codable, Equatable, Sendable {
    enum Severity: String, Codable, Sendable { case error, warning }
    var severity: Severity
    var code: String
    var message: String
}

struct CharacterValidation: Codable, Equatable, Sendable {
    var issues: [CharacterIssue] = []
    var checkedAt: Date?
    var ok: Bool { !issues.contains { $0.severity == .error } }
    var errors: [CharacterIssue] { issues.filter { $0.severity == .error } }
}

enum CharacterValidator {
    /// Memory budget for one character's geometry (vertices × channels).
    static let maxVertices = 200_000
    static let maxTriangles = 400_000

    static func mesh(_ m: GeneratedMesh, name: String = "mesh") -> [CharacterIssue] {
        var out: [CharacterIssue] = []
        func err(_ code: String, _ msg: String) { out.append(CharacterIssue(severity: .error, code: code, message: name + ": " + msg)) }
        func warn(_ code: String, _ msg: String) { out.append(CharacterIssue(severity: .warning, code: code, message: name + ": " + msg)) }
        if m.vertexCount == 0 || m.triangleCount == 0 { err("mesh.empty", L10n.t("没有顶点或三角形", "no vertices or triangles")); return out }
        if m.positions.count % 3 != 0 || m.indices.count % 3 != 0 { err("mesh.layout", L10n.t("数据长度不对", "array lengths do not fit")) }
        if m.vertexCount > maxVertices || m.triangleCount > maxTriangles { err("mesh.budget", L10n.t("超出内存预算（\(m.vertexCount) 顶点）", "over the memory budget (\(m.vertexCount) vertices)")) }
        let bad = m.positions.filter { !$0.isFinite }.count
        if bad > 0 { err("mesh.nan", L10n.t("\(bad / 3 + 1) 个顶点是 NaN 或无穷大", "\(bad / 3 + 1) vertices are NaN or infinite")) }
        if let i = m.indices.first(where: { Int($0) >= m.vertexCount }) { err("mesh.index", L10n.t("三角形引用了不存在的顶点 \(i)", "a triangle uses vertex \(i), which does not exist")) }
        if m.normals.count != m.positions.count || !m.normals.allSatisfy(\.isFinite) { warn("mesh.normals", L10n.t("法线缺失或无效（会重新计算）", "normals missing or invalid (recomputed)")) }
        if m.uvs.count != m.vertexCount * 2 || !m.uvs.allSatisfy(\.isFinite) { warn("mesh.uvs", L10n.t("UV 缺失或无效", "UVs missing or invalid")) }
        if bad == 0, m.indices.allSatisfy({ Int($0) < m.vertexCount }) {
            var degenerate = 0
            for t in 0..<m.triangleCount {
                let a = Int(m.indices[t * 3]), b = Int(m.indices[t * 3 + 1]), c = Int(m.indices[t * 3 + 2])
                func p(_ i: Int) -> SIMD3<Float> { SIMD3(m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]) }
                if a == b || b == c || a == c || cLength(cCross(p(b) - p(a), p(c) - p(a))) < 1e-12 { degenerate += 1 }
            }
            if degenerate * 10 > m.triangleCount { err("mesh.degenerate", L10n.t("\(degenerate) 个退化三角形", "\(degenerate) degenerate triangles")) }
            else if degenerate > 0 { warn("mesh.degenerate", L10n.t("\(degenerate) 个退化三角形", "\(degenerate) degenerate triangles")) }
            let b = m.bounds
            let size = (0..<3).map { b.max[$0] - b.min[$0] }.max() ?? 0
            if !size.isFinite || size <= 1e-5 || size > 1000 { err("mesh.bounds", L10n.t("模型尺寸异常（\(size)）", "implausible size (\(size))")) }
        }
        return out
    }

    static func skeleton(_ s: SkeletonDefinition, humanoid: Bool = true) -> [CharacterIssue] {
        do { try s.validate(humanoid: humanoid); return [] } catch {
            return [CharacterIssue(severity: .error, code: "skeleton.invalid", message: L10n.t("骨骼无效：", "Invalid skeleton: ") + String(describing: error))]
        }
    }

    static func skin(_ skin: SkinInfluences, jointCount: Int, vertexCount: Int) -> [CharacterIssue] {
        var out: [CharacterIssue] = []
        if skin.count != vertexCount { out.append(CharacterIssue(severity: .error, code: "skin.count", message: L10n.t("权重数量 \(skin.count) 与顶点数 \(vertexCount) 不符", "\(skin.count) weights for \(vertexCount) vertices"))) ; return out }
        var badJoint = 0, badSum = 0, badValue = 0
        for v in 0..<skin.count {
            var sum: Float = 0
            for k in 0..<4 {
                let j = skin.joints[v * 4 + k], w = skin.weights[v * 4 + k]
                if !w.isFinite || w < 0 { badValue += 1; continue }
                if j != 255 { if Int(j) >= jointCount { badJoint += 1 } else { sum += w } }
            }
            if abs(sum - 1) > 0.01 { badSum += 1 }
        }
        if badJoint > 0 { out.append(CharacterIssue(severity: .error, code: "skin.joint", message: L10n.t("\(badJoint) 个权重指向不存在的关节", "\(badJoint) weights point at joints that do not exist"))) }
        if badValue > 0 { out.append(CharacterIssue(severity: .error, code: "skin.value", message: L10n.t("\(badValue) 个权重是负数或无效值", "\(badValue) weights are negative or invalid"))) }
        if badSum > 0 { out.append(CharacterIssue(severity: badSum * 20 > skin.count ? .error : .warning, code: "skin.sum", message: L10n.t("\(badSum) 个顶点的权重之和不是 1", "\(badSum) vertices' weights do not sum to 1"))) }
        return out
    }

    static func motions(_ motions: [UniversalMotion]) -> [CharacterIssue] {
        motions.filter { !$0.valid }.map { CharacterIssue(severity: .error, code: "motion.invalid", message: L10n.t("动作 \($0.id) 的时间或数据无效", "Motion \($0.id) has invalid timing or data")) }
    }

    /// Everything for one rigged body.
    static func validate(mesh m: GeneratedMesh, skeleton s: SkeletonDefinition, skin: SkinInfluences, motions: [UniversalMotion] = [], humanoid: Bool = true) -> CharacterValidation {
        var issues = mesh(m) + skeleton(s, humanoid: humanoid) + self.skin(skin, jointCount: s.joints.count, vertexCount: m.vertexCount) + self.motions(motions)
        // A pose test: the bind pose must deform to the bind mesh (inverse binds agree), and a motion must stay finite.
        if issues.allSatisfy({ $0.severity != .error }) {
            let rest = SkinWeightSolver.deform(m, skin: skin, matrices: RigPoser.skinning(MotionSample(), skeleton: s))
            let drift = zip(rest.positions, m.positions).map { abs($0 - $1) }.max() ?? 0
            if !(drift < 1e-3) { issues.append(CharacterIssue(severity: .error, code: "rig.bind", message: L10n.t("绑定姿态下模型偏移了 \(drift)", "the bind pose moves the mesh by \(drift)"))) }
            if let walk = MotionLibrary.motion("walk") {
                let moved = SkinWeightSolver.deform(m, skin: skin, matrices: RigPoser.skinning(walk.sample(at: 0.3, legLength: RigPoser.legLength(s)), skeleton: s))
                if !moved.positions.allSatisfy(\.isFinite) { issues.append(CharacterIssue(severity: .error, code: "rig.motion", message: L10n.t("播放动作后出现无效顶点", "a motion produces invalid vertices"))) }
            }
        }
        return CharacterValidation(issues: issues, checkedAt: nil)
    }
}

// MARK: Package

struct CharacterManifest: Codable, Equatable, Sendable {
    static let currentFormat = 1

    enum Geometry: Codable, Equatable, Sendable {
        /// Rebuilt from the shared base body and the appearance's shape.
        case humanBase(version: String)
        /// The package's own meshes (Meshes/LOD<n>.m3dg) and weights.
        case custom(lods: Int)
    }
    struct Source: Codable, Equatable, Sendable {
        var kind: String          // "humanBase", "photo", "import", "legacy"
        var hash: String?
        var name: String?
        var license: String
    }
    struct Change: Codable, Equatable, Sendable {
        var date: Date
        var what: String
    }
    enum Quality: String, Codable, Sendable { case verified, warnings, failed, unchecked }

    var formatVersion = CharacterManifest.currentFormat
    var id: String
    var name: String
    var geometry: Geometry
    var source: Source
    var meshVersion = 1
    var skeletonVersion = 1
    var motionLibraryVersion = UniversalMotion.currentVersion
    /// Generated3D model this character came from, if any.
    var modelID: String?
    var quality = Quality.unchecked
    var history: [Change] = []
}

struct CharacterPackage: Equatable, Sendable {
    var manifest: CharacterManifest
    var appearance: CharacterAppearance
    var skeleton: SkeletonDefinition
    /// Library motion ids the character uses, plus its own motions.
    var motionIDs: [String]
    var customMotions: [UniversalMotion] = []
    var sockets: [AttachmentSocket]
    var validation: CharacterValidation
    /// Custom geometry only (LOD meshes and their weights).
    var meshes: [GeneratedMesh] = []
    var skins: [SkinInfluences] = []
    /// v1.92: images by file name (Textures/), e.g. a painted skin's atlas.
    var textures: [String: Data] = [:]
    /// v1.93: fitted garments' source meshes by file name (Garments/, GeneratedMeshCodec).
    var garments: [String: Data] = [:]

    var motions: [UniversalMotion] { motionIDs.compactMap(MotionLibrary.motion) + customMotions }

    /// A HumanBase character from an appearance (checked).
    static func humanBase(id: String = UUID().uuidString, name: String, appearance: CharacterAppearance, date: Date = Date()) -> CharacterPackage? {
        guard let body = HumanBase.build(appearance.shape) else { return nil }
        let motions = MotionLibrary.standard
        var validation = CharacterValidator.validate(mesh: body.mesh, skeleton: body.skeleton, skin: body.skin, motions: motions)
        validation.checkedAt = date
        let manifest = CharacterManifest(id: id, name: name, geometry: .humanBase(version: "hm08-1"),
                                         source: .init(kind: "humanBase", hash: nil, name: "MakeHuman hm08", license: "CC0-1.0"),
                                         quality: validation.ok ? (validation.issues.isEmpty ? .verified : .warnings) : .failed,
                                         history: [.init(date: date, what: "created")])
        return CharacterPackage(manifest: manifest, appearance: appearance, skeleton: body.skeleton, motionIDs: motions.map(\.id),
                                sockets: SkeletonBuilder.sockets(body.skeleton), validation: validation)
    }
}

enum CharacterPackageError: Error, Equatable { case newerFormat(Int), damaged(String), notFound }

/// Packages in one folder (Application Support/Characters in the app).
struct CharacterPackageStore: Sendable {
    let folder: URL

    func url(_ id: String) -> URL { folder.appendingPathComponent(id + ".mcpkg", isDirectory: true) }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    private struct Motions: Codable { var ids: [String]; var custom: [UniversalMotion] }

    /// Writes into a temporary folder, then swaps it in. Refuses to replace a
    /// package written by a newer format.
    func save(_ package: CharacterPackage) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = url(package.manifest.id)
        if let existing = try? Data(contentsOf: target.appendingPathComponent("Manifest.json")),
           let old = try? Self.decoder.decode(CharacterManifest.self, from: existing), old.formatVersion > CharacterManifest.currentFormat {
            throw CharacterPackageError.newerFormat(old.formatVersion)
        }
        let temp = folder.appendingPathComponent(".tmp-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        for sub in ["Skeleton", "Motions", "Equipment", "Diagnostics", "Meshes", "Skin", "Preview", "Textures", "Garments"] {
            try fm.createDirectory(at: temp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let e = Self.encoder
        try e.encode(package.manifest).write(to: temp.appendingPathComponent("Manifest.json"))
        try e.encode(package.appearance).write(to: temp.appendingPathComponent("Appearance.json"))
        try e.encode(package.skeleton).write(to: temp.appendingPathComponent("Skeleton/Skeleton.json"))
        try e.encode(Motions(ids: package.motionIDs, custom: package.customMotions)).write(to: temp.appendingPathComponent("Motions/MotionLibrary.json"))
        try e.encode(package.sockets).write(to: temp.appendingPathComponent("Equipment/Sockets.json"))
        try e.encode(package.validation).write(to: temp.appendingPathComponent("Diagnostics/Validation.json"))
        for (i, mesh) in package.meshes.enumerated() { try GeneratedMeshCodec.encode(mesh).write(to: temp.appendingPathComponent("Meshes/LOD\(i).m3dg")) }
        for (i, skin) in package.skins.enumerated() { try SkinCodec.encode(skin).write(to: temp.appendingPathComponent("Skin/LOD\(i).skin")) }
        for (name, data) in package.textures {
            // Plain file names only (no folders, no tricks).
            guard Self.plainName(name) else { continue }
            try data.write(to: temp.appendingPathComponent("Textures/" + name))
        }
        for (name, data) in package.garments {
            guard Self.plainName(name) else { continue }
            try data.write(to: temp.appendingPathComponent("Garments/" + name))
        }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: target)
        }
    }

    static func plainName(_ name: String) -> Bool { !name.isEmpty && name.count <= 64 && !name.contains("/") && !name.contains("\\") && !name.hasPrefix(".") }

    func load(_ id: String) throws -> CharacterPackage {
        let base = url(id)
        guard let manifestData = try? Data(contentsOf: base.appendingPathComponent("Manifest.json")) else { throw CharacterPackageError.notFound }
        let d = Self.decoder
        guard let manifest = try? d.decode(CharacterManifest.self, from: manifestData) else { throw CharacterPackageError.damaged("Manifest.json") }
        guard manifest.formatVersion <= CharacterManifest.currentFormat else { throw CharacterPackageError.newerFormat(manifest.formatVersion) }
        func read<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            guard let data = try? Data(contentsOf: base.appendingPathComponent(path)), let value = try? d.decode(type, from: data) else { throw CharacterPackageError.damaged(path) }
            return value
        }
        let appearance = try read(CharacterAppearance.self, "Appearance.json")
        let skeleton = try read(SkeletonDefinition.self, "Skeleton/Skeleton.json")
        let motions = try read(Motions.self, "Motions/MotionLibrary.json")
        let sockets = try read([AttachmentSocket].self, "Equipment/Sockets.json")
        let validation = (try? read(CharacterValidation.self, "Diagnostics/Validation.json")) ?? CharacterValidation()
        var meshes: [GeneratedMesh] = [], skins: [SkinInfluences] = []
        if case .custom(let lods) = manifest.geometry {
            for i in 0..<lods {
                guard let m = (try? Data(contentsOf: base.appendingPathComponent("Meshes/LOD\(i).m3dg"))).flatMap(GeneratedMeshCodec.decode),
                      let s = (try? Data(contentsOf: base.appendingPathComponent("Skin/LOD\(i).skin"))).flatMap(SkinCodec.decode) else { throw CharacterPackageError.damaged("LOD\(i)") }
                meshes.append(m); skins.append(s)
            }
        }
        guard motions.custom.allSatisfy(\.valid) else { throw CharacterPackageError.damaged("Motions") }
        var textures: [String: Data] = [:]
        let textureFolder = base.appendingPathComponent("Textures")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: textureFolder.path)) ?? [] where !name.hasPrefix(".") {
            if let data = try? Data(contentsOf: textureFolder.appendingPathComponent(name)), data.count <= 32_000_000 { textures[name] = data }
        }
        var garments: [String: Data] = [:]
        let garmentFolder = base.appendingPathComponent("Garments")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: garmentFolder.path)) ?? [] where !name.hasPrefix(".") {
            if let data = try? Data(contentsOf: garmentFolder.appendingPathComponent(name)), data.count <= 32_000_000 { garments[name] = data }
        }
        return CharacterPackage(manifest: manifest, appearance: appearance, skeleton: skeleton, motionIDs: motions.ids, customMotions: motions.custom,
                                sockets: sockets, validation: validation, meshes: meshes, skins: skins, textures: textures, garments: garments)
    }

    /// Every readable package; damaged ones are reported, not fatal.
    func list() -> (packages: [CharacterPackage], damaged: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var ok: [CharacterPackage] = [], bad: [String] = []
        for name in names.sorted() where name.hasSuffix(".mcpkg") {
            let id = String(name.dropLast(6))
            do { ok.append(try load(id)) } catch { bad.append(id) }
        }
        return (ok, bad)
    }

    func delete(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }

    /// A texture file of a saved package (for RealityKit to load).
    func textureURL(_ id: String, _ name: String) -> URL { url(id).appendingPathComponent("Textures/" + name) }
}

/// Binary weights: "SKI1", count, 4 joint bytes and 4 floats per vertex.
enum SkinCodec {
    static func encode(_ s: SkinInfluences) -> Data {
        var d = Data("SKI1".utf8)
        withUnsafeBytes(of: UInt32(s.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: s.joints)
        for w in s.weights { withUnsafeBytes(of: w.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }
    static func decode(_ data: Data) -> SkinInfluences? {
        var r = ByteReader(bytes: [UInt8](data))
        guard r.bytes.count >= 8, Array(r.bytes[0..<4]) == Array("SKI1".utf8) else { return nil }
        r.offset = 4
        guard let n = try? Int(r.u32()), n <= 2_000_000, let joints = try? r.u8(n * 4), let weights = try? r.f32(n * 4), r.offset == r.bytes.count else { return nil }
        guard weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return SkinInfluences(joints: joints, weights: weights)
    }
}
