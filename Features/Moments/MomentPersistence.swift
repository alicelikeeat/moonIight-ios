import Foundation
import os

/// Saves moments to Application Support/Moments/moments.json instead of
/// UserDefaults. Writing UserDefaults re-serialised the whole list on the
/// main thread for every like or comment; here encoding and disk work run
/// on a background actor.
///
/// On first launch after the update, posts saved under the old UserDefaults
/// key are copied into the file. The old key is removed only after that
/// file write succeeds, so an interrupted migration simply runs again.
@MainActor
final class MomentPersistence {
    static let legacyDefaultsKey = "moonlight.moments.v2"
    static let schemaVersion = 1

    private let file: VersionedJSONFile<[MomentPost]>
    private let defaults: UserDefaults
    private var writer: VersionedJSONWriter<[MomentPost]>
    private var sequence = 0
    private let log = Logger(subsystem: "com.moonlight.feed", category: "moments")

    nonisolated static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moments", isDirectory: true)
    }

    init(directory: URL = MomentPersistence.defaultDirectory(), defaults: UserDefaults = .standard) {
        file = VersionedJSONFile(directory: directory, name: "moments", schemaVersion: Self.schemaVersion)
        self.defaults = defaults
        writer = VersionedJSONWriter(file: file, loadedRevision: 0, blocked: false)
    }

    /// Reads saved posts once at launch.
    func load() -> [MomentPost] {
        do {
            if let snapshot = try file.load() {
                writer = VersionedJSONWriter(file: file, loadedRevision: snapshot.revision, blocked: false)
                if snapshot.fromBackup { log.notice("Loaded moments from backup file") }
                // The file already holds the data; a leftover key is from an
                // interrupted migration.
                defaults.removeObject(forKey: Self.legacyDefaultsKey)
                return snapshot.payload
            }
        } catch {
            // A newer app version wrote this file (or it is too large). Keep
            // it as is and do not save over it this session.
            log.error("Moments file kept unchanged: \(String(describing: error), privacy: .public)")
            writer = VersionedJSONWriter(file: file, loadedRevision: 0, blocked: true)
            return []
        }
        return migrateFromDefaults()
    }

    /// Queues a background save of the current list.
    func save(_ posts: [MomentPost]) {
        sequence += 1
        let sequence = sequence, writer = writer, log = log
        Task.detached(priority: .utility) {
            do {
                try await writer.save(posts, sequence: sequence)
            } catch {
                log.error("Moments save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func migrateFromDefaults() -> [MomentPost] {
        guard let data = defaults.data(forKey: Self.legacyDefaultsKey),
              let posts = try? JSONDecoder().decode([MomentPost].self, from: data) else { return [] }
        sequence += 1
        let sequence = sequence, writer = writer, log = log
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await writer.save(posts, sequence: sequence)
                await self?.removeLegacyCopy()
            } catch {
                log.error("Moments migration failed; UserDefaults copy kept: \(String(describing: error), privacy: .public)")
            }
        }
        return posts
    }

    private func removeLegacyCopy() {
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }
}
