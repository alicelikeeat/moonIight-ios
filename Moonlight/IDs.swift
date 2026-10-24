import Foundation

enum IDs {
    static func new() -> String { UUID().uuidString.lowercased() }
}

enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var media: URL { documents.appendingPathComponent("media", isDirectory: true) }
    static var avatars: URL { documents.appendingPathComponent("avatars", isDirectory: true) }
    static var skins: URL { documents.appendingPathComponent("skins", isDirectory: true) }
    static var cache: URL { documents.appendingPathComponent("cache", isDirectory: true) }
    static var resume: URL { documents.appendingPathComponent("resume", isDirectory: true) }
    static var libraryFile: URL { documents.appendingPathComponent("library.json") }
    static var socialFile: URL { documents.appendingPathComponent("social.json") }
    static var settingsFile: URL { documents.appendingPathComponent("settings.json") }
    static var trashFile: URL { documents.appendingPathComponent("trash.json") }
    static var transfersFile: URL { documents.appendingPathComponent("transfers.json") }
    static var refreshFile: URL { documents.appendingPathComponent("refresh.json") }

    static func ensureDirs() {
        for url in [media, avatars, skins, cache, resume] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

extension Notification.Name {
    static let moonPauseAll = Notification.Name("moon.pauseAll")
    static let moonResumeFeed = Notification.Name("moon.resumeFeed")
}
