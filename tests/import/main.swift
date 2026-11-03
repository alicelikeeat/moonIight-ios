import Foundation

// MediaImportIndex checks. Needs CryptoKit (macOS):
// swiftc Shared/Persistence/MediaImportIndex.swift tests/import/main.swift
var checks = 0
func check(_ condition: Bool, _ name: String) { precondition(condition, name); checks += 1 }

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-index-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let a = folder.appendingPathComponent("a.gif"), b = folder.appendingPathComponent("b.gif"), c = folder.appendingPathComponent("c.gif")
try Data("same bytes".utf8).write(to: a)
try Data("same bytes".utf8).write(to: b)
try Data("other bytes".utf8).write(to: c)
check(try MediaImportIndex.sha256(of: a) == MediaImportIndex.sha256(of: b), "same content, same hash")
check(try MediaImportIndex.sha256(of: a) != MediaImportIndex.sha256(of: c), "different content, different hash")
check(try MediaImportIndex.sha256(of: a) == "58100dc8fc06562ce3e578231dc948e083520ee49c4b4ee5a5a28bb4b4003feb", "known SHA-256 hex digest")
let big = folder.appendingPathComponent("big.bin")
try Data(repeating: 7, count: 3 * (1 << 20) + 5).write(to: big)
check((try MediaImportIndex.sha256(of: big)).count == 64, "multi-chunk file hashes")

let index = MediaImportIndex(url: folder.appendingPathComponent("media/import-hashes.json"))
check(index.entryID(for: "x") == nil, "empty index")
index.record("h1", entryID: "e1"); index.record("h2", entryID: "e2")
check(index.entryID(for: "h1") == "e1" && index.entryID(for: "h2") == "e2", "recorded and reloaded")
index.prune(keeping: ["e2"])
check(index.entryID(for: "h1") == nil && index.entryID(for: "h2") == "e2", "deleted entries pruned")
try Data("garbage".utf8).write(to: index.url)
check(index.load().isEmpty, "corrupt index treated as empty")
index.record("h3", entryID: "e3")
check(index.entryID(for: "h3") == "e3", "index recovers after corruption")
print("Import index checks passed: \(checks)")
