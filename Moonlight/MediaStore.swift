import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MediaStore {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonlight", isDirectory: true)
    }
    static var skins: URL { support.appendingPathComponent("skins", isDirectory: true) }
    static var backdrop: URL { support.appendingPathComponent("backdrop", isDirectory: true) }
    static var inbox: URL { support.appendingPathComponent("inbox", isDirectory: true) }

    static func ensure() {
        for url in [support, skins, backdrop, inbox] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// Copies off a temporary picker file. The returned URL lives in `folder`.
    static func copy(from source: URL, folder: URL, ext: String) -> URL? {
        ensure()
        let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let name = "\(IDs.new()).\(clean.isEmpty ? "dat" : clean)"
        let dest = folder.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    static func write(_ data: Data, folder: URL, ext: String) -> URL? {
        ensure()
        let name = "\(IDs.new()).\(ext)"
        let dest = folder.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    /// `stored` is a filename in `folder`, or a legacy absolute path.
    static func resolve(_ stored: String?, folder: URL) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("/") {
            if FileManager.default.fileExists(atPath: stored) { return stored }
            let moved = folder.appendingPathComponent((stored as NSString).lastPathComponent).path
            return FileManager.default.fileExists(atPath: moved) ? moved : nil
        }
        let path = folder.appendingPathComponent(stored).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func remove(stored: String?, folder: URL) {
        guard let stored, !stored.isEmpty else { return }
        if stored.hasPrefix("/") {
            try? FileManager.default.removeItem(atPath: stored)
            return
        }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(stored))
    }

    static func sniffExt(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.count > 12, let mark = String(data: data.subdata(in: 4..<12), encoding: .ascii) {
            if mark.contains("heic") || mark.contains("heix") || mark.contains("mif1") { return "heic" }
            if mark.contains("qt") || mark.contains("mp4") { return "mov" }
        }
        return "jpg"
    }
}

enum SkinFiles {
    static func path(_ stored: String) -> String? {
        if let found = MediaStore.resolve(stored, folder: MediaStore.skins) { return found }
        let legacy = Paths.skins.appendingPathComponent((stored as NSString).lastPathComponent).path
        return FileManager.default.fileExists(atPath: legacy) ? legacy : nil
    }
}

enum BackdropFiles {
    static func path(_ stored: String?) -> String? { MediaStore.resolve(stored, folder: MediaStore.backdrop) }
}

/// Still image from Photos, including HEIC. The file is copied into Application Support
/// inside the importing closure, because the picker deletes its temporary URL when that closure returns.
struct InboxImage: Transferable {
    var url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .heic) { SentTransferredFile($0.url) } importing: { received in
            InboxImage(url: try store(received.file, fallback: "heic"))
        }
        FileRepresentation(contentType: .image) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            return InboxImage(url: try store(received.file, fallback: ext))
        }
        DataRepresentation(contentType: .image) { image in
            (try? Data(contentsOf: image.url)) ?? Data()
        } importing: { data in
            let ext = MediaStore.sniffExt(data)
            guard let dest = MediaStore.write(data, folder: MediaStore.inbox, ext: ext) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return InboxImage(url: dest)
        }
    }

    private static func store(_ file: URL, fallback: String) throws -> URL {
        let ext = file.pathExtension.isEmpty ? fallback : file.pathExtension
        guard let dest = MediaStore.copy(from: file, folder: MediaStore.inbox, ext: ext) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return dest
    }
}

/// Movie from Photos. Copied straight into Application Support, never left in tmp.
struct InboxMovie: Transferable {
    var url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .mpeg4Movie) { SentTransferredFile($0.url) } importing: { received in
            InboxMovie(url: try store(received.file, fallback: "mp4"))
        }
        FileRepresentation(contentType: .quickTimeMovie) { SentTransferredFile($0.url) } importing: { received in
            InboxMovie(url: try store(received.file, fallback: "mov"))
        }
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            InboxMovie(url: try store(received.file, fallback: "mov"))
        }
    }

    private static func store(_ file: URL, fallback: String) throws -> URL {
        let ext = file.pathExtension.isEmpty ? fallback : file.pathExtension
        guard let dest = MediaStore.copy(from: file, folder: MediaStore.inbox, ext: ext) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return dest
    }
}

enum PickedMedia {
    /// PhotosPicker → loadTransferable (image, HEIC, movie, Live Photo) → Application Support.
    /// A Live Photo is saved as its still image. A movie is tried only when the item is not a Live Photo,
    /// because a Live Photo reports both types and the movie representation often fails the whole import.
    static func load(_ item: PhotosPickerItem, folder: URL) async -> (name: String, video: Bool)? {
        let types = item.supportedContentTypes
        let live = types.contains { $0.identifier.lowercased().contains("live-photo") }
        let movie = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        if !live, movie, let saved = await takeMovie(item, folder: folder) { return saved }
        if let saved = await takeImage(item, folder: folder) { return saved }
        if movie || live, let saved = await takeMovie(item, folder: folder) { return saved }
        if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
            let ext = MediaStore.sniffExt(data)
            let video = ext == "mov"
            guard let dest = MediaStore.write(data, folder: folder, ext: video ? "mov" : ext) else { return nil }
            return (dest.lastPathComponent, video)
        }
        return nil
    }

    private static func takeImage(_ item: PhotosPickerItem, folder: URL) async -> (name: String, video: Bool)? {
        guard let image = try? await item.loadTransferable(type: InboxImage.self) else { return nil }
        return place(image.url, folder: folder, video: false)
    }

    private static func takeMovie(_ item: PhotosPickerItem, folder: URL) async -> (name: String, video: Bool)? {
        guard let movie = try? await item.loadTransferable(type: InboxMovie.self) else { return nil }
        return place(movie.url, folder: folder, video: true)
    }

    private static func place(_ url: URL, folder: URL, video: Bool) -> (name: String, video: Bool)? {
        if url.deletingLastPathComponent().path == folder.path { return (url.lastPathComponent, video) }
        let ext = url.pathExtension.isEmpty ? (video ? "mov" : "jpg") : url.pathExtension
        guard let dest = MediaStore.copy(from: url, folder: folder, ext: ext) else { return nil }
        if url.deletingLastPathComponent().path == MediaStore.inbox.path {
            try? FileManager.default.removeItem(at: url)
        }
        return (dest.lastPathComponent, video)
    }
}
