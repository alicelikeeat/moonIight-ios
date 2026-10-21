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
    static var libraryFile: URL { documents.appendingPathComponent("library.json") }
    static var socialFile: URL { documents.appendingPathComponent("social.json") }
    static var settingsFile: URL { documents.appendingPathComponent("settings.json") }

    static func ensureDirs() {
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
    }
}

extension Notification.Name {
    static let moonPauseAll = Notification.Name("moon.pauseAll")
}
