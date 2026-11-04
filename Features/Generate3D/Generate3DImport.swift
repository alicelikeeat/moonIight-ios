import Foundation
import RealityKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

// v1.76: import GLB / glTF / FBX / OBJ / STL / 3MF (with the file's own
// skeleton and animations when it has them) and USD / USDZ (kept as is;
// RealityKit plays its animations).

@available(iOS 18.0, *)
extension Generated3DStore {
    static let modelExtensions = ModelImport.extensions + usdExtensions
    static let usdExtensions = ["usdz", "usd", "usda", "usdc"]

    /// Types offered in the file picker: models plus their companion files.
    static var importTypes: [UTType] {
        let ext = modelExtensions + ["mtl", "bin"]
        return ext.compactMap { UTType(filenameExtension: $0) } + [.usdz, .image, .data]
    }

    /// Saves the model among the picked files; the others (MTL, textures,
    /// .bin) are its companions.
    func storeImported(files: [(name: String, data: Data)]) async throws -> Generated3DManifest {
        guard let primary = files.first(where: { Self.modelExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }) else {
            throw ImportError.unsupported(files.first.map { ($0.name as NSString).pathExtension } ?? "")
        }
        let ext = (primary.name as NSString).pathExtension.lowercased()
        let name = (primary.name as NSString).deletingPathExtension
        if Self.usdExtensions.contains(ext) { return try await storeUSD(primary.data, ext: ext, name: name) }
        var companions: [String: Data] = [:]
        for f in files where f.name != primary.name { companions[(f.name as NSString).lastPathComponent.lowercased()] = f.data }
        let source = primary
        let prepared = try await Task.detached(priority: .userInitiated) { () throws -> (ImportedModel, Data?, String) in
            var model = try ModelImport.read(source.data, fileName: source.name, companions: companions)
            var texture: Data?, ext = "png"
            if let raw = model.texture {
                if raw.starts(with: [0xFF, 0xD8]) { texture = raw; ext = "jpg" }
                else if raw.starts(with: [0x89, 0x50, 0x4E, 0x47]) { texture = raw }
                else if let cg = CGImageSourceCreateWithData(raw as CFData, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }), let jpeg = PixelReader.jpeg(cg, quality: 0.92) {
                    texture = jpeg; ext = "jpg"   // TGA and others → JPEG
                } else {
                    model.notes.append(L10n.t("贴图格式无法读取，已忽略", "The texture format could not be read and was skipped"))
                }
            } else if let baked = ModelImport.baked(model), let cg = ModelAnimationExport.cgImage(baked.texture), let jpeg = PixelReader.jpeg(cg, quality: 0.92) {
                model = baked.model; texture = jpeg; ext = "jpg"
            }
            return (model, texture, ext)
        }.value
        let model = prepared.0, mesh = model.mesh
        let id = UUID().uuidString
        let meshFile = id + ".m3dg"
        let textureFile: String? = prepared.1 == nil ? nil : id + "." + prepared.2
        do {
            let meshURL = Self.folder("Models").appendingPathComponent(meshFile)
            try await Task.detached(priority: .userInitiated) { try GeneratedMeshCodec.encode(mesh).write(to: meshURL, options: .atomic) }.value
            if let textureFile, let texture = prepared.1 { try texture.write(to: Self.folder("Textures").appendingPathComponent(textureFile), options: .atomic) }
        } catch { throw Generate3DError.saveFailed(error.localizedDescription) }
        let textureImage = prepared.1.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let thumbnailFile = await renderThumbnail(mesh, texture: textureImage, id: id)

        // The file's skeleton goes into the rig store with its animations.
        var notes = [L10n.t("从 \(ext.uppercased()) 导入：\(mesh.vertexCount) 个顶点、\(mesh.triangleCount) 个三角面。", "Imported from \(ext.uppercased()): \(mesh.vertexCount) vertices, \(mesh.triangleCount) triangles.")] + model.notes
        var rigged = false, humanoid = false
        if let rig = model.rig {
            let clips = [MotionClip.standard("rest")].compactMap { $0 } + MotionClip.fromFile(rig.clips)
            let character = RiggedCharacter(modelID: id, meshFile: meshFile, optimizedMeshFile: nil, skinFile: id + ".skin", vertexCount: mesh.vertexCount,
                                            skeleton: rig.skeleton, clips: clips, sockets: [], diagnostics: RiggingDiagnostics(),
                                            metadata: RiggedCharacterMetadata(engine: "Model file", engineVersion: "1.76.0", route: "file",
                                                                              createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), poseType: "file"))
            do {
                try RiggingAssetStore(folder: Self.folder("Rigs")).save(character, skin: rig.skin, optimizedMesh: nil)
                rigged = true
                humanoid = Set(rig.skeleton.joints.map(\.semanticTag)).isSuperset(of: [.leftUpperArm, .rightUpperArm, .leftThigh, .rightThigh])
                notes.append(L10n.t("文件自带的动作可在「自动骨骼 → 动作测试」里播放；放进 3D 世界后按动作名对应待机、行走等。尚未经过人工真机验收。",
                                    "The file's animations play under Auto Rig → Motion tests; in the 3D world they map to idle, walk and so on by name. Not yet accepted on a device by a person."))
            } catch {
                notes.append(L10n.t("骨骼保存失败：", "Saving the skeleton failed: ") + error.localizedDescription)
            }
        }
        let manifest = Generated3DManifest(
            id: id, name: model.name ?? name, createdAt: Date(), source: .image, sourceName: primary.name,
            sourceHash: SHA256.hash(data: primary.data).map { String(format: "%02x", $0) }.joined(),
            engine: ext.uppercased() + " import", engineVersion: "1.76", depthSource: .none, geometry: .imported, quality: .medium,
            vertexCount: mesh.vertexCount, triangleCount: mesh.triangleCount, textureWidth: textureImage?.width ?? 0, textureHeight: textureImage?.height ?? 0,
            meshFile: meshFile, textureFile: textureFile, usdzFile: nil, thumbnailFile: thumbnailFile,
            humanoidDetected: humanoid, rigging: rigged ? .experimentalVerified : .experimentalNotImplemented,
            animation: rigged && !(model.rig?.clips.isEmpty ?? true) ? .experimentalVerified : .experimentalNotImplemented,
            separableParts: .notAvailable, notes: notes)
        try save(manifest)
        return manifest
    }

    /// USD / USDZ: stored as is (RealityKit draws it and plays its own
    /// animations); it must load before it is kept.
    private func storeUSD(_ data: Data, ext: String, name: String) async throws -> Generated3DManifest {
        let id = UUID().uuidString
        let file = id + "." + ext
        let target = Self.folder("Models").appendingPathComponent(file)
        do { try data.write(to: target, options: .atomic) } catch { throw Generate3DError.saveFailed(error.localizedDescription) }
        guard let entity = try? await Entity(contentsOf: target) else {
            try? FileManager.default.removeItem(at: target)
            throw ImportError.damaged(L10n.t("RealityKit 无法加载这个 USD 文件", "RealityKit could not load this USD file"))
        }
        let animations = entity.availableAnimations.count
        let manifest = Generated3DManifest(
            id: id, name: name, createdAt: Date(), source: .image, sourceName: name + "." + ext,
            sourceHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            engine: ext.uppercased() + " import", engineVersion: "1.76", depthSource: .none, geometry: .imported, quality: .medium,
            vertexCount: 0, triangleCount: Self.triangles(in: entity), textureWidth: 0, textureHeight: 0,
            meshFile: nil, textureFile: nil, usdzFile: file, thumbnailFile: nil,
            humanoidDetected: false, rigging: .experimentalNotImplemented, animation: animations > 0 ? .experimentalVerified : .experimentalNotImplemented,
            separableParts: .notAvailable,
            notes: [L10n.t("从 \(ext.uppercased()) 导入，原样保存。文件自带 \(animations) 个动画，预览和 3D 世界里会循环播放第一个。USD 模型不能重新绑定骨骼或换皮肤。",
                           "Imported from \(ext.uppercased()) and kept as is. It has \(animations) animations; the first loops in the preview and the 3D world. USD models cannot be re-rigged or reskinned.")])
        try save(manifest)
        return manifest
    }

    func renderThumbnail(_ mesh: GeneratedMesh, texture: CGImage?, id: String) async -> String? {
        let data = await Task.detached(priority: .utility) { () -> Data? in
            let raster = texture.flatMap { ModelAnimationExport.raster($0) }
            let image = ModelRasterizer.render(mesh, texture: raster, camera: RasterCamera(yaw: 0.35, lighting: true), width: 256, height: 256, background: [40, 44, 56, 255])
            return ModelAnimationExport.cgImage(image).flatMap { PixelReader.jpeg($0, quality: 0.8) }
        }.value
        guard let data, (try? data.write(to: Self.folder("Thumbnails").appendingPathComponent(id + ".jpg"), options: .atomic)) != nil else { return nil }
        return id + ".jpg"
    }
}
