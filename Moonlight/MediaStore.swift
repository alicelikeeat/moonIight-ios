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

/// Image file from the photo picker, including HEIC. Copied out of the temporary import URL.
struct ImageFile: Transferable {
    var url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            guard let dest = MediaStore.copy(from: received.file, folder: MediaStore.inbox, ext: ext) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return ImageFile(url: dest)
        }
    }
}

enum PickedMedia {
    static func load(_ item: PhotosPickerItem, folder: URL) async -> (name: String, video: Bool)? {
        let types = item.supportedContentTypes
        let video = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        if video, let movie = try? await item.loadTransferable(type: MovieFile.self) {
            let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
            guard let dest = MediaStore.copy(from: movie.url, folder: folder, ext: ext) else { return nil }
            return (dest.lastPathComponent, true)
        }
        if let image = try? await item.loadTransferable(type: ImageFile.self) {
            let ext = image.url.pathExtension.isEmpty ? "jpg" : image.url.pathExtension
            guard let dest = MediaStore.copy(from: image.url, folder: folder, ext: ext) else { return nil }
            return (dest.lastPathComponent, false)
        }
        if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
            let ext = MediaStore.sniffExt(data)
            guard let dest = MediaStore.write(data, folder: folder, ext: video ? "mov" : ext) else { return nil }
            return (dest.lastPathComponent, video)
        }
        return nil
    }
}
