import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// A Photos item copied to a temporary file. GIF is listed before generic
/// images so an animated GIF arrives as a .gif, not a flattened still.
struct RPGPickedFile:Transferable,Sendable {
    let url:URL
    static var transferRepresentation:some TransferRepresentation {
        FileRepresentation(importedContentType:.movie){received in try copy(received.file)}
        FileRepresentation(importedContentType:.gif){received in try copy(received.file)}
        FileRepresentation(importedContentType:.image){received in try copy(received.file)}
    }
    private static func copy(_ source:URL)throws->RPGPickedFile {
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at:source,to:destination)
        return .init(url:destination)
    }
}
