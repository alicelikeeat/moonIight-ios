import Foundation
import SwiftUI

// v1.91: the app's character packages (Application Support/Characters),
// loaded once and kept in memory. Damaged packages are listed separately
// and never stop the others from loading.

@available(iOS 18.0, *)
@MainActor final class CharacterLibrary: ObservableObject {
    static let shared = CharacterLibrary()

    @Published private(set) var packages: [CharacterPackage] = []
    @Published private(set) var damaged: [String] = []
    let store: CharacterPackageStore

    init(folder: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        store = CharacterPackageStore(folder: folder ?? base.appendingPathComponent("Characters", isDirectory: true))
        reload()
    }

    func reload() {
        let found = store.list()
        packages = found.packages.sorted { ($0.manifest.history.first?.date ?? .distantPast) < ($1.manifest.history.first?.date ?? .distantPast) }
        damaged = found.damaged
    }

    func package(_ id: String) -> CharacterPackage? { packages.first { $0.manifest.id == id } }

    /// Saves (validating first). Returns the error message, nil on success.
    @discardableResult
    func save(_ package: CharacterPackage) -> String? {
        guard package.validation.ok else { return L10n.t("角色没有通过检查，不能保存：", "The character failed its checks and cannot be saved: ") + package.validation.errors.map(\.message).prefix(2).joined(separator: "; ") }
        do { try store.save(package) } catch CharacterPackageError.newerFormat(let v) {
            return L10n.t("这个角色由更新版本的 Moonlight 保存（格式 \(v)），为避免损坏没有覆盖。", "This character was saved by a newer Moonlight (format \(v)); it was not overwritten.")
        } catch { return error.localizedDescription }
        reload()
        return nil
    }

    func delete(_ id: String) { store.delete(id); reload() }
}
