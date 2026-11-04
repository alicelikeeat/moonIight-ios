import Foundation

// v1.73: saving rigged characters. Files live in their own folder next to
// the models (Rigs/), so v1.72 rigs (Skeletons/, Animations/) and the
// source meshes are never touched. Every save keeps the previous version
// as .prev for rollback; a file from a newer format is refused, not
// overwritten.

struct RiggingAssetStore: Sendable {
    let folder: URL

    func characterURL(_ modelID: String) -> URL { folder.appendingPathComponent(modelID + ".rig.json") }
    func skinURL(_ modelID: String) -> URL { folder.appendingPathComponent(modelID + ".skin") }
    func optimizedMeshURL(_ modelID: String) -> URL { folder.appendingPathComponent(modelID + ".opt.mesh") }
    func checkpointURL(_ modelID: String) -> URL { folder.appendingPathComponent(modelID + ".checkpoint.json") }

    func exists(_ modelID: String) -> Bool { FileManager.default.fileExists(atPath: characterURL(modelID).path) }

    /// Writes skin, optional optimised mesh, then the character (last, so a
    /// half-written save is never picked up). Old files become .prev.
    func save(_ character: RiggedCharacter, skin: SkinInfluences, optimizedMesh: GeneratedMesh?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never overwrite a save from a newer app version.
        if let existing = try? Data(contentsOf: characterURL(character.modelID)) {
            do { _ = try RiggedCharacter.decode(existing) } catch RiggedCharacter.LoadError.newerFormat(let v) { throw RiggedCharacter.LoadError.newerFormat(v) } catch {}
        }
        func write(_ data: Data, _ url: URL) throws {
            let prev = url.appendingPathExtension("prev")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: prev)
                try? FileManager.default.copyItem(at: url, to: prev)
            }
            try data.write(to: url, options: .atomic)
        }
        try write(skin.encoded(), skinURL(character.modelID))
        if let optimizedMesh { try write(GeneratedMeshCodec.encode(optimizedMesh), optimizedMeshURL(character.modelID)) }
        try write(try character.encoded(), characterURL(character.modelID))
        try? FileManager.default.removeItem(at: checkpointURL(character.modelID))
    }

    /// Character and weights (nil when missing or not matching).
    func load(_ modelID: String) throws -> (RiggedCharacter, SkinInfluences)? {
        guard let data = try? Data(contentsOf: characterURL(modelID)) else { return nil }
        let character = try RiggedCharacter.decode(data)
        guard let skinData = try? Data(contentsOf: skinURL(modelID)), let skin = SkinInfluences.decode(skinData),
              skin.count == character.vertexCount, skin.valid(jointCount: character.skeleton.joints.count, vertexCount: skin.count) else { return nil }
        return (character, skin)
    }

    /// Restores the previous save (rollback).
    func rollback(_ modelID: String) throws -> Bool {
        let urls = [characterURL(modelID), skinURL(modelID), optimizedMeshURL(modelID)]
        guard FileManager.default.fileExists(atPath: urls[0].appendingPathExtension("prev").path) else { return false }
        for url in urls {
            let prev = url.appendingPathExtension("prev")
            guard FileManager.default.fileExists(atPath: prev.path) else { continue }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: prev, to: url)
        }
        return true
    }

    func delete(_ modelID: String) {
        for url in [characterURL(modelID), skinURL(modelID), optimizedMeshURL(modelID), checkpointURL(modelID)] {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("prev"))
        }
    }

    // MARK: Checkpoints (interrupted jobs resume from the skeleton)

    struct Checkpoint: Codable, Equatable, Sendable {
        var modelID: String
        var stage: String
        var skeleton: SkeletonDefinition?
        var savedAt: Date
    }
    func saveCheckpoint(_ c: Checkpoint) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder.rig.encode(c).write(to: checkpointURL(c.modelID), options: .atomic)
    }
    func checkpoint(_ modelID: String) -> Checkpoint? {
        (try? Data(contentsOf: checkpointURL(modelID))).flatMap { try? JSONDecoder.rig.decode(Checkpoint.self, from: $0) }
    }
}
