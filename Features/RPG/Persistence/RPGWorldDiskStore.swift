import Foundation

enum RPGSaveError: Error, LocalizedError {
    case invalidID, corrupt, missingWorld
    var errorDescription: String? {
        switch self {
        case .invalidID: "存档身份无效。"
        case .corrupt: "主存档和备份均无法读取，原文件已保留。"
        case .missingWorld: "找不到对应世界。"
        }
    }
}
/// Per-world atomic file + previous-good backup. Original and creative copies
/// never share a world file; the active-world pointer is committed last.
actor RPGWorldDiskStore: RPGWorldStorage {
    private struct Locator: Codable { let id: String }
    let root: URL
    private(set) var recoveredFromBackup = false
    init(root: URL) { self.root = root }
    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RPG", isDirectory: true)
    }
    private func directory(_ id: String) throws -> URL {
        guard !id.isEmpty, id.utf8.count <= 128, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw RPGSaveError.invalidID }
        return root.appendingPathComponent("Worlds", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    private func read(_ url: URL, limit: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max
        guard size <= Int64(limit) else { throw RPGWorldError.oversized }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }
    func load() async throws -> WorldState? {
        recoveredFromBackup = false
        let pointer = root.appendingPathComponent("active.json"), backup = root.appendingPathComponent("active.backup.json")
        if !FileManager.default.fileExists(atPath: pointer.path) && !FileManager.default.fileExists(atPath: backup.path) { return nil }
        for (index, url) in [pointer, backup].enumerated() {
            do {
                let locator = try JSONDecoder().decode(Locator.self, from: read(url, limit: 4096))
                let world = try await load(id: locator.id)
                if index == 1 { recoveredFromBackup = true }
                return world
            } catch { continue }
        }
        throw RPGSaveError.corrupt
    }
    func load(id: String) async throws -> WorldState {
        let folder = try directory(id)
        for (index, name) in ["world.json", "world.backup.json"].enumerated() {
            do {
                let world = try RPGWorldCodec.decode(read(folder.appendingPathComponent(name), limit: RPGWorldCodec.maximumBytes))
                guard world.id == id else { throw RPGSaveError.invalidID }
                if index == 1 { recoveredFromBackup = true }
                return world
            } catch { continue }
        }
        throw RPGSaveError.corrupt
    }
    func save(_ world: WorldState) async throws {
        let data = try RPGWorldCodec.encode(world), folder = try directory(world.id)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let primary = folder.appendingPathComponent("world.json"), backup = folder.appendingPathComponent("world.backup.json")
        // Never replace a previous-good backup with an unreadable primary.
        if let previous = try? read(primary, limit: RPGWorldCodec.maximumBytes),
           let decoded = try? RPGWorldCodec.decode(previous), decoded.id == world.id {
            guard decoded.revision <= world.revision else { throw RPGEditError.stale }
            try previous.write(to: backup, options: .atomic)
        }
        try data.write(to: primary, options: .atomic)
        let pointer = root.appendingPathComponent("active.json"), pointerBackup = root.appendingPathComponent("active.backup.json")
        if let previous = try? read(pointer, limit: 4096), (try? JSONDecoder().decode(Locator.self, from: previous)) != nil {
            try previous.write(to: pointerBackup, options: .atomic)
        }
        try JSONEncoder().encode(Locator(id: world.id)).write(to: pointer, options: .atomic)
    }
}
