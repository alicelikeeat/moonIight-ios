import Foundation
import CryptoKit

/// Separate asset namespace; old MediaStore files and world saves are untouched.
actor GeneratedAssetStore {
    static let shared = GeneratedAssetStore()
    nonisolated let root: URL
    private let fm = FileManager.default
    private let folders = ["Models", "Textures", "Skeletons", "Animations", "Thumbnails", "Presets", "Manifests", "Sources"]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Generated3D", isDirectory: true)
    }

    private func prepare() throws {
        for folder in folders { try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
    }

    nonisolated func modelURL(_ id: UUID) -> URL { root.appendingPathComponent("Models/\(id.uuidString).usdz") }

    private func file(_ id: UUID) -> VersionedJSONFile<GeneratedModelManifest> {
        VersionedJSONFile(directory: root.appendingPathComponent("Manifests"), name: id.uuidString, schemaVersion: 1, maximumBytes: 64 << 10)
    }

    func list() throws -> [GeneratedModelManifest] {
        try prepare()
        let urls = try fm.contentsOfDirectory(at: root.appendingPathComponent("Manifests"), includingPropertiesForKeys: nil)
        let ids = Set(urls.compactMap { UUID(uuidString: $0.lastPathComponent.components(separatedBy: ".")[0]) })
        var items: [GeneratedModelManifest] = []
        for id in ids {
            guard let manifest = try file(id).load()?.payload else { throw GenerationError.corruptAsset }
            guard manifest.id == id else { throw GenerationError.corruptAsset }
            try validate(manifest)
            items.append(manifest)
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func manifest(_ id: UUID) throws -> GeneratedModelManifest {
        guard let manifest = try file(id).load()?.payload else { throw GenerationError.corruptAsset }
        guard manifest.id == id else { throw GenerationError.corruptAsset }
        try validate(manifest)
        return manifest
    }

    private func validate(_ manifest: GeneratedModelManifest) throws {
        let hash = manifest.sourceHash
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
              manifest.sourceExtension.count <= 12,
              !manifest.sourceExtension.isEmpty, manifest.sourceExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              manifest.textureHash.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true else {
            throw GenerationError.corruptAsset
        }
    }

    func saveImage(_ result: GeneratedImage, source: URL, title: String, libraryID: String?, elapsed: Double) throws -> GeneratedModelManifest {
        let savingStarted = Date()
        try prepare()
        try GenerationResources.checkDisk(at: root, bytes: Int64(result.texture.count * 4 + (30 << 20)))
        let id = UUID(), texture = root.appendingPathComponent("Textures/.\(id).png")
        let target = modelURL(id)
        var committed = false
        defer {
            try? fm.removeItem(at: texture)
            if !committed { try? fm.removeItem(at: target) }
        }
        try result.texture.write(to: texture, options: .atomic)
        let textureHash = try MediaImportIndex.sha256(of: texture)
        let textureTarget = root.appendingPathComponent("Textures/\(textureHash).png")
        if !fm.fileExists(atPath: textureTarget.path) { try fm.copyItem(at: texture, to: textureTarget) }
        let sourceInfo = try preserveSource(source)
        try Task.checkCancellation()
        try DepthUSDZWriter.write(mesh: result.mesh, png: result.texture, to: target)
        try Task.checkCancellation()
        let bytes = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0
        let manifest = GeneratedModelManifest(id: id, createdAt: .now, title: title, sourceName: title,
            sourceHash: sourceInfo.hash, sourceExtension: sourceInfo.ext, sourceLibraryID: libraryID,
            engine: GeneratedModelManifest.engineVersion + ";DepthAnythingV2SmallF16@cfef6f6",
            kind: .depthSurface, quality: result.quality, vertices: result.mesh.positions.count,
            triangles: result.mesh.triangleCount, textureWidth: result.width, textureHeight: result.height,
            textureHash: textureHash, modelBytes: bytes, elapsedSeconds: elapsed + Date().timeIntervalSince(savingStarted), realityKitValidated: false)
        try file(id).save(manifest, revision: 1)
        committed = true
        return manifest
    }

    func saveReconstruction(model: URL, source: URL, title: String, elapsed: Double) throws -> GeneratedModelManifest {
        let savingStarted = Date()
        try prepare()
        let id = UUID(), target = modelURL(id)
        let sourceInfo = try preserveSource(source)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: target) } }
        try fm.copyItem(at: model, to: target)
        try Task.checkCancellation()
        let bytes = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0
        guard bytes > 0 else { throw GenerationError.corruptAsset }
        // Counts are unknown until parsed; 0 is displayed as unavailable in UI.
        let manifest = GeneratedModelManifest(id: id, createdAt: .now, title: title, sourceName: title,
            sourceHash: sourceInfo.hash, sourceExtension: sourceInfo.ext, engine: GeneratedModelManifest.engineVersion + ";AppleObjectCapture",
            kind: .photogrammetry, quality: "ObjectCapture-reduced-unverified", vertices: 0, triangles: 0,
            textureWidth: 0, textureHeight: 0, modelBytes: bytes, elapsedSeconds: elapsed + Date().timeIntervalSince(savingStarted), realityKitValidated: false)
        try file(id).save(manifest, revision: 1)
        committed = true
        return manifest
    }

    func confirmRealityKit(_ id: UUID, sampledPeak: UInt64? = nil) throws -> GeneratedModelManifest {
        let snapshot = try file(id).load()
        guard var manifest = snapshot?.payload else { throw GenerationError.corruptAsset }
        manifest.realityKitValidated = true
        if let sampledPeak { manifest.sampledPeakFootprintBytes = sampledPeak }
        try file(id).save(manifest, revision: (snapshot?.revision ?? 0) + 1)
        return manifest
    }

    func savePreset(_ preset: ModelSkinPreset) throws {
        try preset.validate()
        _ = try manifest(preset.modelID)
        let data = try JSONEncoder().encode(preset)
        try data.write(to: root.appendingPathComponent("Presets/\(preset.modelID).json"), options: .atomic)
    }

    func preset(_ id: UUID) throws -> ModelSkinPreset {
        let url = root.appendingPathComponent("Presets/\(id).json")
        guard fm.fileExists(atPath: url.path) else { return ModelSkinPreset(modelID: id) }
        guard ((try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max) < 4096 else { throw GenerationError.corruptAsset }
        let preset = try JSONDecoder().decode(ModelSkinPreset.self, from: Data(contentsOf: url))
        guard preset.modelID == id else { throw GenerationError.corruptAsset }
        try preset.validate()
        return preset
    }

    func delete(_ id: UUID) throws {
        _ = try manifest(id)
        for url in [modelURL(id), root.appendingPathComponent("Presets/\(id).json"), file(id).primary, file(id).backup] {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try removeUnreferencedContent()
    }

    /// Only call after all manifests load; future/corrupt manifests block GC.
    func removeUnreferencedContent() throws {
        let manifests = try list()
        let sources = Set(manifests.map { "\($0.sourceHash).\($0.sourceExtension)" })
        let textures = Set(manifests.compactMap { $0.textureHash.map { $0 + ".png" } })
        for (directory, keep) in [("Sources", sources), ("Textures", textures)] {
            for url in try fm.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil) {
                if !keep.contains(url.lastPathComponent) { try fm.removeItem(at: url) }
            }
        }
        let liveIDs = Set(manifests.map(\.id))
        for folder in ["Models", "Presets"] {
            for url in try fm.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil) {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !liveIDs.contains(id) {
                    try fm.removeItem(at: url)
                }
            }
        }
    }

    private func preserveSource(_ source: URL) throws -> (hash: String, ext: String) {
        guard source.isFileURL else { throw GenerationError.invalidInput("生成输入必须是本机文件。") }
        let size = (try fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= 2 << 30 else { throw GenerationError.invalidInput("素材为空或超过 2 GB 本地任务上限。") }
        try GenerationResources.checkDisk(at: root, bytes: size)
        let temporary = root.appendingPathComponent("Sources/.\(UUID()).partial")
        fm.createFile(atPath: temporary.path, contents: nil)
        defer { try? fm.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: temporary)
        defer { try? input.close(); try? output.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try GenerationResources.check(minimumMemory: 100 << 20)
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let candidate = source.pathExtension.lowercased()
        let ext = !candidate.isEmpty && candidate.count <= 12 && candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? candidate : "bin"
        let target = root.appendingPathComponent("Sources/\(hash).\(ext)")
        if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: temporary, to: target) }
        return (hash, ext)
    }
}
