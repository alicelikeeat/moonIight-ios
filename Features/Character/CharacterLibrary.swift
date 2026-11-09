import Foundation
import SwiftUI

// v1.91: the app's character packages (Application Support/Characters),
// loaded once and kept in memory. Damaged packages are listed separately
// and never stop the others from loading.

@available(iOS 18.0, *)
@MainActor final class CharacterLibrary: ObservableObject {
    static let shared = CharacterLibrary()

    @Published private(set) var packages: [CharacterPackage] = []
    @Published private(set) var damaged: [String] = []
    let store: CharacterPackageStore

    /// v1.92: models (AI 3D page or imported files) the user made into base bodies.
    @Published private(set) var modelBases: [BaseBodyEntry] = []
    private var basesURL: URL { store.folder.appendingPathComponent("ModelBases.json") }

    init(folder: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        store = CharacterPackageStore(folder: folder ?? base.appendingPathComponent("Characters", isDirectory: true))
        reload()
        modelBases = (try? Data(contentsOf: basesURL)).flatMap { try? JSONDecoder().decode([BaseBodyEntry].self, from: $0) } ?? []
    }

    var allBases: [BaseBodyEntry] { BaseBodyCatalog.builtins + modelBases }
    func base(_ id: String?) -> BaseBodyEntry? { allBases.first { $0.id == (id ?? BaseBodyCatalog.neutralID) } }

    /// Makes a rigged model a base body (checked first). Returns an error message, nil on success.
    func addModelBase(_ manifest: Generated3DManifest) async -> String? {
        guard let loaded = await Self.loadModelBody(manifest.id) else {
            return L10n.t("这个模型还没有骨骼：请先点「自动绑定骨骼」，完成后再设为底模。", "This model has no rig yet: tap Auto Rig first, then make it a base.")
        }
        let check = CharacterValidator.validate(mesh: loaded.body.mesh, skeleton: loaded.body.skeleton, skin: loaded.body.skin, motions: MotionLibrary.standard)
        guard check.ok else { return L10n.t("没有通过检查，不能作为底模：", "Failed its checks; it cannot be a base: ") + check.errors.map(\.message).prefix(2).joined(separator: "; ") }
        let entry = BaseBodyCatalog.entry(model: manifest.id, name: String(manifest.name.prefix(40)))
        modelBases.removeAll { $0.id == entry.id }
        modelBases.append(entry)
        try? FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(modelBases).write(to: basesURL, options: .atomic)
        return nil
    }
    func removeModelBase(_ id: String) {
        modelBases.removeAll { $0.id == id }
        try? JSONEncoder().encode(modelBases).write(to: basesURL, options: .atomic)
    }

    /// A rigged Generated3D model as a base body: its mesh in metres (feet on the
    /// ground), its skeleton (27-joint rigs as they are, ten-bone rigs mapped)
    /// and weights, wrapped like HumanBase so outfits, skins and motions apply;
    /// plus its own texture. Nil for models without a rig.
    static func loadModelBody(_ id: String) async -> (body: HumanBody, texture: URL?)? {
        let store = Generated3DStore.shared
        guard let manifest = store.models.first(where: { $0.id == id }), let meshURL = store.meshURL(manifest) else { return nil }
        let assets = RiggingAssetStore(folder: Generated3DStore.folder("Rigs"))
        let found = await Task.detached(priority: .userInitiated) { () -> (GeneratedMesh?, (RiggedCharacter, SkinInfluences)?) in
            let mesh = (try? Data(contentsOf: meshURL)).flatMap(GeneratedMeshCodec.decode)
            guard let saved = try? assets.load(id) else { return (mesh, nil) }
            let rigMesh = saved.0.optimizedMeshFile != nil ? (try? Data(contentsOf: assets.optimizedMeshURL(id))).flatMap(GeneratedMeshCodec.decode) : mesh
            return (rigMesh, saved)
        }.value
        guard var mesh = found.0.map(FiniteMesh.repaired) else { return nil }
        var rig: (SkeletonDefinition, SkinInfluences)? = found.1.map { (LegacyRigAdapter.upgrade($0.0), $0.1) }
        if rig == nil, let legacy = await Generate3DRigging.load(manifest), let converted = LegacyRigAdapter.convert(legacy.0, skin: legacy.1, vertexCount: mesh.vertexCount) {
            rig = (converted.skeleton, converted.skin)
        }
        guard let rig, rig.1.count == mesh.vertexCount else { return nil }
        var (skeleton, skin) = rig
        if mesh.normals.count != mesh.positions.count { mesh.computeNormals() }
        if mesh.uvs.count != mesh.vertexCount * 2 { mesh.uvs = [Float](repeating: 0, count: mesh.vertexCount * 2) }
        var height = mesh.bounds.max[1] - mesh.bounds.min[1]
        // Generated models are normalised to about 1 unit: give them a person's size, feet on the ground.
        let floor = mesh.bounds.min[1]
        let k: Float = height > 0 && height < 1.2 ? 1.75 / height : 1
        for i in 0..<mesh.vertexCount { mesh.positions[i * 3] *= k; mesh.positions[i * 3 + 1] = (mesh.positions[i * 3 + 1] - floor) * k; mesh.positions[i * 3 + 2] *= k }
        for i in skeleton.joints.indices {
            var rest = skeleton.joints[i].rest
            rest.tx *= k; rest.tz *= k
            rest.ty = skeleton.joints[i].parentID == nil ? (rest.ty - floor) * k : rest.ty * k
            skeleton.joints[i].restTransform = rest.matrix
        }
        skeleton.refreshBindMatrices()
        skin = SkinInfluences(joints: skin.joints, weights: skin.weights)
        height *= k
        let body = HumanBody(shape: HumanShape(height: height), lod: 0, skeleton: skeleton, mesh: mesh, skin: skin, master: Array(0..<mesh.vertexCount),
                             vertices: HumanBase.parts(mesh: mesh, skin: skin, skeleton: skeleton))
        return (body, store.textureURL(manifest))
    }

    func reload() {
        let found = store.list()
        packages = found.packages.sorted { ($0.manifest.history.first?.date ?? .distantPast) < ($1.manifest.history.first?.date ?? .distantPast) }
        damaged = found.damaged
    }

    func package(_ id: String) -> CharacterPackage? { packages.first { $0.manifest.id == id } }

    /// Saves (validating first). Returns the error message, nil on success.
    @discardableResult
    func save(_ package: CharacterPackage) -> String? {
        guard package.validation.ok else { return L10n.t("角色没有通过检查，不能保存：", "The character failed its checks and cannot be saved: ") + package.validation.errors.map(\.message).prefix(2).joined(separator: "; ") }
        do { try store.save(package) } catch CharacterPackageError.newerFormat(let v) {
            return L10n.t("这个角色由更新版本的 Moonlight 保存（格式 \(v)），为避免损坏没有覆盖。", "This character was saved by a newer Moonlight (format \(v)); it was not overwritten.")
        } catch { return error.localizedDescription }
        reload()
        return nil
    }

    func delete(_ id: String) { store.delete(id); reload() }
}
