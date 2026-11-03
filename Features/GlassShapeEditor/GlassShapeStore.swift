import Foundation
import Combine

/// The editor's own storage, apart from the sandbox world: one JSON file in
/// Application Support/GlassShapeEditor. Saved shapes are also offered to
/// the map editor's shape tool.
@MainActor final class GlassShapeStore: ObservableObject {
    static let shared = GlassShapeStore()

    @Published private(set) var library: ShapeLibrary
    private let file: URL
    private var pendingSave: Task<Void, Never>?

    init(directory: URL? = nil) {
        let base = directory ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("GlassShapeEditor", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        file = base.appendingPathComponent("library.json")
        library = (try? Data(contentsOf: file)).flatMap(ShapeLibrary.decode) ?? ShapeLibrary()
    }

    var shapes: [ShapeDocument] { library.shapes }

    /// The shape being edited; a fresh droplet the first time.
    func currentOrNew() -> ShapeDocument {
        if let current = library.current { return current }
        let document = ShapeDocument(name: L10n.t("我的形状", "My Shape"), outline: ShapeTemplate.droplet.outline)
        update(document)
        return document
    }

    /// Saves a change soon after it happens (autosave while editing).
    func update(_ document: ShapeDocument) {
        guard document.valid else { return }
        var stamped = document; stamped.updated = Date()
        library.upsert(stamped)
        scheduleSave()
    }

    func select(_ id: String) { library.currentID = id; scheduleSave() }
    func remove(_ id: String) { library.remove(id); scheduleSave() }
    @discardableResult func duplicate(_ id: String) -> ShapeDocument? {
        let copy = library.duplicate(id, suffix: L10n.t(" 副本", " Copy")); scheduleSave(); return copy
    }
    func rename(_ id: String, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !trimmed.isEmpty, var document = library.shapes.first(where: { $0.id == id }) else { return }
        document.name = trimmed; update(document)
    }

    /// Writes now (leaving the editor, app going to background).
    func flush() {
        pendingSave?.cancel(); pendingSave = nil
        write(library)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.write(self.library)
        }
    }

    private func write(_ value: ShapeLibrary) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: file, options: [.atomic])
    }
}
