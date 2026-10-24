import Foundation

enum AtomicFile {
    /// tmp + fsync + replace. A crash leaves either the old file or the complete new one.
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tmp, options: .noFileProtection)
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    static func read(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }
}

/// File writes run on this actor (off the main actor). The caller debounces and passes a generation.
actor StoreWriter {
    private var generation = 0

    func bump() -> Int {
        generation += 1
        return generation
    }

    func writeIfCurrent(generation g: Int, social: Data, library: Data, settings: Data, trash: Data, transfers: Data) {
        guard g == generation else { return }
        try? AtomicFile.write(social, to: Paths.socialFile)
        try? AtomicFile.write(library, to: Paths.libraryFile)
        try? AtomicFile.write(settings, to: Paths.settingsFile)
        try? AtomicFile.write(trash, to: Paths.trashFile)
        try? AtomicFile.write(transfers, to: Paths.transfersFile)
    }
}
