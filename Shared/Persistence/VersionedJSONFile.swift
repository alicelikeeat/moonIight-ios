import Foundation

enum VersionedFileError: Error, Equatable {
    /// The file was written by a newer app version. It is left untouched.
    case futureSchema(Int)
    case oversized
    /// Saving is turned off because loading found a newer-version file.
    case writesBlocked
}

/// One Codable value stored as JSON with a schema version and a revision
/// number. Every save keeps the previous good file as a backup; loading
/// picks the newest copy that still decodes. Unreadable copies are moved
/// aside instead of deleted, and a newer-version file is never overwritten.
struct VersionedJSONFile<Payload: Codable & Sendable>: Sendable {
    struct Snapshot: Sendable {
        let payload: Payload
        let revision: Int
        let fromBackup: Bool
    }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var revision: Int
        var payload: Payload
    }

    /// Only the header is decoded, so a future payload shape cannot hide a
    /// future schema number behind a decoding error.
    private struct Header: Decodable {
        var schemaVersion: Int
        var revision: Int
    }

    let primary: URL
    let backup: URL
    let schemaVersion: Int
    let maximumBytes: Int

    init(directory: URL, name: String, schemaVersion: Int, maximumBytes: Int = 32 << 20) {
        primary = directory.appendingPathComponent("\(name).json")
        backup = directory.appendingPathComponent("\(name).backup.json")
        self.schemaVersion = schemaVersion
        self.maximumBytes = maximumBytes
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: primary.path) || FileManager.default.fileExists(atPath: backup.path)
    }

    /// Returns nil when there is no readable file. Throws `futureSchema`
    /// or `oversized` when a file must be kept and not replaced.
    func load() throws -> Snapshot? {
        var candidates: [Snapshot] = []
        var unreadable: [URL] = []
        for url in [primary, backup] where FileManager.default.fileExists(atPath: url.path) {
            let data = try read(url)
            guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
                unreadable.append(url)
                continue
            }
            if header.schemaVersion > schemaVersion { throw VersionedFileError.futureSchema(header.schemaVersion) }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                unreadable.append(url)
                continue
            }
            candidates.append(Snapshot(payload: envelope.payload, revision: envelope.revision, fromBackup: url == backup))
        }
        // Prefer the higher revision; on a tie, prefer the primary file.
        let best = candidates.max { lhs, rhs in
            lhs.revision == rhs.revision ? lhs.fromBackup && !rhs.fromBackup : lhs.revision < rhs.revision
        }
        if best == nil { unreadable.forEach(quarantine) }
        return best
    }

    /// Writes `payload` as `revision`. The current primary file becomes the
    /// backup first, but only if it is itself readable.
    func save(_ payload: Payload, revision: Int) throws {
        let data = try JSONEncoder().encode(Envelope(schemaVersion: schemaVersion, revision: revision, payload: payload))
        guard data.count <= maximumBytes else { throw VersionedFileError.oversized }
        try FileManager.default.createDirectory(at: primary.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: primary.path),
           let previous = try? read(primary),
           let header = try? JSONDecoder().decode(Header.self, from: previous) {
            if header.schemaVersion > schemaVersion { throw VersionedFileError.futureSchema(header.schemaVersion) }
            try previous.write(to: backup, options: .atomic)
        }
        try data.write(to: primary, options: .atomic)
    }

    private func read(_ url: URL) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= maximumBytes else { throw VersionedFileError.oversized }
        return try Data(contentsOf: url)
    }

    private func quarantine(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}

/// Runs saves for a `VersionedJSONFile` off the main thread. Each save
/// carries a sequence number from the caller, so a save that reaches the
/// actor late can never replace a newer one.
actor VersionedJSONWriter<Payload: Codable & Sendable> {
    private let file: VersionedJSONFile<Payload>
    private var revision: Int
    private var lastSequence = 0
    private var blocked: Bool

    init(file: VersionedJSONFile<Payload>, loadedRevision: Int, blocked: Bool) {
        self.file = file
        revision = loadedRevision
        self.blocked = blocked
    }

    /// Returns true when this payload is on disk, false when a newer save
    /// already replaced it.
    @discardableResult
    func save(_ payload: Payload, sequence: Int) throws -> Bool {
        guard !blocked else { throw VersionedFileError.writesBlocked }
        guard sequence > lastSequence else { return false }
        do {
            try file.save(payload, revision: revision + 1)
        } catch VersionedFileError.futureSchema(let version) {
            blocked = true
            throw VersionedFileError.futureSchema(version)
        }
        revision += 1
        lastSequence = sequence
        return true
    }
}
