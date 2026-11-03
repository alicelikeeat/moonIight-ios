import Foundation

struct RPGMediaDescriptor: Equatable, Sendable {
    let id: String
    let kind: RPGMediaKind
    let url: URL
    let coverURL: URL?
}
enum RPGMediaAvailability: Equatable, Sendable {
    case available(RPGMediaDescriptor), missing, unsupported, remote
}
protocol RPGMediaCatalog {
    @MainActor func resolve(_ id: String) -> RPGMediaAvailability
}
/// Resolves existing library identities; never refreshes discovery or mutates it.
@MainActor struct MediaStoreRPGCatalog: RPGMediaCatalog {
    let store: MediaStore
    func resolve(_ id: String) -> RPGMediaAvailability {
        guard let entry = store.items.first(where: { $0.id == id }) else { return .missing }
        guard entry.kind != .embed, let url = entry.remoteURL else { return .unsupported }
        guard url.isFileURL else { return .remote }
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        return .available(.init(id: id, kind: RPGMediaCatalogKind.kind(for: entry), url: url, coverURL: entry.coverURL))
    }
}

/// Library entries only know image or video; GIF is told apart by file type.
enum RPGMediaCatalogKind {
    static func kind(for entry: MediaEntry) -> RPGMediaKind {
        if entry.kind == .video { return .video }
        return entry.remoteURL?.pathExtension.lowercased() == "gif" ? .gif : .image
    }
}
