import Foundation

enum RPGSaveError: Error, LocalizedError, Equatable {
    case invalidID, corrupt, missingWorld, ambiguous
    var errorDescription: String? {
        switch self {
        case .invalidID: "存档身份无效。"
        case .corrupt: "主存档和备份均无法读取，原文件已保留。"
        case .missingWorld: "找不到对应世界。"
        case .ambiguous: "活动索引无法读取，发现多个保留世界，请选择要恢复的世界。"
        }
    }
}
/// Per-world atomic file + previous-good backup. Original and creative copies
/// never share a world file; the active-world pointer is committed last.
enum RPGSaveCheckpoint: CaseIterable, Sendable { case beforeBackup, afterBackup, beforePrimary, afterPrimary, beforePointer, afterPointer }

struct RPGRecoveryChoice:Identifiable,Sendable {
    let id:String
    let seed:UInt64
    let revision:UInt64
    let creative:Bool
}

actor RPGWorldDiskStore: RPGWorldStorage {
    private struct Locator: Codable { let id: String }
    let root: URL
    private(set) var recoveredFromBackup = false
    private let fault: (@Sendable (RPGSaveCheckpoint) throws -> Void)?
    init(root: URL, fault: (@Sendable (RPGSaveCheckpoint) throws -> Void)? = nil) { self.root = root; self.fault = fault }
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
        if !FileManager.default.fileExists(atPath: pointer.path) && !FileManager.default.fileExists(atPath: backup.path) { return try await recoverUnindexed() }
        for (index, url) in [pointer, backup].enumerated() {
            do {
                let locator = try JSONDecoder().decode(Locator.self, from: read(url, limit: 4096))
                let world = try await load(id: locator.id)
                if index == 1 { recoveredFromBackup = true }
                return world
            } catch {
                if error as? RPGWorldError == .unsupportedVersion || error as? RPGWorldError == .oversized { throw error }
                continue
            }
        }
        if let recovered=try await recoverUnindexed(){return recovered}
        throw RPGSaveError.corrupt
    }
    private func recoverUnindexed() async throws -> WorldState? {
        let choices=try await recoverableWorlds()
        guard !choices.isEmpty else{return nil}
        guard choices.count==1 else{throw RPGSaveError.ambiguous}
        let world=try await load(id:choices[0].id);recoveredFromBackup=true;return world
    }
    func recoverableWorlds() async throws -> [RPGRecoveryChoice] {
        let folder=root.appendingPathComponent("Worlds",isDirectory:true)
        guard FileManager.default.fileExists(atPath:folder.path) else{return []}
        let urls=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey,.contentModificationDateKey],options:[.skipsHiddenFiles])
            .filter{url in
                (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory)==true &&
                ["world.json","world.backup.json"].contains{FileManager.default.fileExists(atPath:url.appendingPathComponent($0).path)}
            }
            .sorted{((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)>((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}
        guard urls.count<=256 else{throw RPGWorldError.oversized}
        var choices:[RPGRecoveryChoice]=[]
        for url in urls {
            do {
                let world=try await load(id:url.lastPathComponent)
                choices.append(.init(id:world.id,seed:world.seed,revision:world.revision,creative:world.isCreativeCopy))
            }catch{if error as? RPGWorldError == .unsupportedVersion || error as? RPGWorldError == .oversized{throw error}}
        }
        guard urls.isEmpty || !choices.isEmpty else{throw RPGSaveError.corrupt}
        return choices
    }
    func load(id: String) async throws -> WorldState {
        let folder = try directory(id)
        var candidates: [(Int,WorldState)] = []
        for (index, name) in ["world.json", "world.backup.json"].enumerated() {
            do {
                let world = try RPGWorldCodec.decode(read(folder.appendingPathComponent(name), limit: RPGWorldCodec.maximumBytes))
                guard world.id == id else { throw RPGSaveError.invalidID }
                candidates.append((index,world))
            } catch {
                // Downgrading must never overwrite a future schema or generator.
                if error as? RPGWorldError == .unsupportedVersion || error as? RPGWorldError == .oversized { throw error }
            }
        }
        guard let selected = candidates.max(by: { lhs,rhs in
            lhs.1.revision == rhs.1.revision ? lhs.0 > rhs.0 : lhs.1.revision < rhs.1.revision
        }) else { throw RPGSaveError.corrupt }
        if selected.0 == 1 { recoveredFromBackup = true }
        return selected.1
    }
    func save(_ world: WorldState) async throws {
        let data = try RPGWorldCodec.encode(world), folder = try directory(world.id)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let primary = folder.appendingPathComponent("world.json"), backup = folder.appendingPathComponent("world.backup.json")
        // Inspect both copies before writing. A corrupt primary must not make
        // an old asynchronous snapshot eligible to replace a newer good backup.
        var validPrimary: Data?
        for candidate in [primary,backup] {
            do {
                let previous = try read(candidate,limit:RPGWorldCodec.maximumBytes)
                let decoded = try RPGWorldCodec.decode(previous)
                guard decoded.id == world.id else { continue }
                guard decoded.revision <= world.revision else { throw RPGEditError.stale }
                if candidate == primary { validPrimary = previous }
            } catch {
                if error as? RPGWorldError == .unsupportedVersion || error as? RPGWorldError == .oversized || error as? RPGEditError == .stale { throw error }
            }
        }
        try fault?(.beforeBackup)
        if let validPrimary { try validPrimary.write(to:backup,options:.atomic) }
        try fault?(.afterBackup); try fault?(.beforePrimary)
        try data.write(to: primary, options: .atomic)
        try fault?(.afterPrimary); try fault?(.beforePointer)
        let pointer = root.appendingPathComponent("active.json"), pointerBackup = root.appendingPathComponent("active.backup.json")
        if let previous = try? read(pointer, limit: 4096), (try? JSONDecoder().decode(Locator.self, from: previous)) != nil {
            try previous.write(to: pointerBackup, options: .atomic)
        }
        try JSONEncoder().encode(Locator(id: world.id)).write(to: pointer, options: .atomic)
        try fault?(.afterPointer)
    }
}
