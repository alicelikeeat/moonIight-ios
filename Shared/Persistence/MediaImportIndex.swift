import Foundation
import CryptoKit

/// Remembers which library entry holds each imported file's content, so
/// importing the same picture, GIF or video again reuses that entry instead
/// of copying the file a second time. Stored as a small JSON map
/// (SHA-256 hex -> entry ID) next to the imported media.
struct MediaImportIndex: Sendable {
    let url: URL

    /// SHA-256 of a file, read in 1 MB pieces so large videos are not loaded whole.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    func entryID(for hash: String) -> String? { load()[hash] }

    func record(_ hash: String, entryID: String) {
        var map = load(); map[hash] = entryID
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(map).write(to: url, options: .atomic)
    }

    /// Drops hashes whose entry is gone, e.g. after the library item was deleted.
    func prune(keeping ids: Set<String>) {
        let map = load(), kept = map.filter { ids.contains($0.value) }
        guard kept.count != map.count else { return }
        try? JSONEncoder().encode(kept).write(to: url, options: .atomic)
    }
}
