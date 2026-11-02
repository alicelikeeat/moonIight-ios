import Foundation

// Checks for VersionedJSONFile / VersionedJSONWriter. Foundation only, so it
// also runs on Linux: swiftc Shared/Persistence/VersionedJSONFile.swift tests/persistence/main.swift

struct Note: Codable, Equatable, Sendable { var text: String }

var checks = 0
@MainActor func check(_ condition: Bool, _ name: String) {
    precondition(condition, name); checks += 1
}
@MainActor func expectError(_ expected: VersionedFileError, _ name: String, _ body: () throws -> Void) {
    do { try body(); preconditionFailure("\(name): no error") } catch let error as VersionedFileError {
        precondition(error == expected, "\(name): got \(error)"); checks += 1
    } catch { preconditionFailure("\(name): \(error)") }
}
func freshDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("persistence-check-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func files(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

// Empty directory and round trip.
var directory = freshDirectory()
var file = VersionedJSONFile<[Note]>(directory: directory, name: "notes", schemaVersion: 1)
check(try file.load() == nil, "empty directory loads nothing")
check(!file.exists, "no file yet")
try file.save([Note(text: "a")], revision: 1)
var loaded = try file.load()!
check(loaded.payload == [Note(text: "a")] && loaded.revision == 1 && !loaded.fromBackup, "round trip")
check(files(in: directory) == ["notes.json"], "first save has no backup")

// Second save keeps the first as backup.
try file.save([Note(text: "b")], revision: 2)
check(files(in: directory) == ["notes.backup.json", "notes.json"], "backup created")
loaded = try file.load()!
check(loaded.payload == [Note(text: "b")] && loaded.revision == 2, "newest revision wins")

// Corrupt primary falls back to the backup and is not promoted over it.
try Data("{not json".utf8).write(to: file.primary)
loaded = try file.load()!
check(loaded.payload == [Note(text: "a")] && loaded.fromBackup, "corrupt primary uses backup")
try file.save([Note(text: "c")], revision: 3)
let backupAfterCorruptPrimary = try VersionedJSONFile<[Note]>(directory: directory, name: "notes", schemaVersion: 1)
    .load()!
check(backupAfterCorruptPrimary.payload == [Note(text: "c")], "save after corrupt primary")
let backupData = try Data(contentsOf: file.backup)
check(String(decoding: backupData, as: UTF8.self).contains("\"a\""), "good backup kept, corrupt primary not copied over it")

// Backup with a higher revision than the primary wins.
directory = freshDirectory()
file = VersionedJSONFile(directory: directory, name: "notes", schemaVersion: 1)
try file.save([Note(text: "new")], revision: 5)
try FileManager.default.copyItem(at: file.primary, to: file.backup)
try file.save([Note(text: "old")], revision: 4)
check(try file.load()!.payload == [Note(text: "new")], "highest revision wins across files")

// Payload that no longer decodes counts as unreadable.
directory = freshDirectory()
file = VersionedJSONFile(directory: directory, name: "notes", schemaVersion: 1)
try Data(#"{"schemaVersion":1,"revision":1,"payload":[{"wrong":1}]}"#.utf8).write(to: file.primary)
check(try file.load() == nil, "undecodable payload loads nothing")

// Both copies unreadable: moved aside, not deleted, and saving works again.
directory = freshDirectory()
file = VersionedJSONFile(directory: directory, name: "notes", schemaVersion: 1)
try Data("x".utf8).write(to: file.primary)
try Data("y".utf8).write(to: file.backup)
check(try file.load() == nil, "two corrupt copies load nothing")
check(!file.exists && files(in: directory).filter { $0.contains("corrupt-") }.count == 2, "corrupt copies quarantined")
try file.save([Note(text: "fresh")], revision: 1)
check(try file.load()!.payload == [Note(text: "fresh")], "save after quarantine")

// A newer app version's file is never read or replaced.
directory = freshDirectory()
file = VersionedJSONFile(directory: directory, name: "notes", schemaVersion: 1)
let future = Data(#"{"schemaVersion":2,"revision":9,"payload":{"shape":"different"}}"#.utf8)
try future.write(to: file.primary)
expectError(.futureSchema(2), "future schema load") { _ = try file.load() }
expectError(.futureSchema(2), "future schema save") { try file.save([Note(text: "x")], revision: 10) }
check(try Data(contentsOf: file.primary) == future && !FileManager.default.fileExists(atPath: file.backup.path), "future file untouched")

// Size limit.
directory = freshDirectory()
let small = VersionedJSONFile<[Note]>(directory: directory, name: "notes", schemaVersion: 1, maximumBytes: 64)
expectError(.oversized, "oversized save") { try small.save([Note(text: String(repeating: "x", count: 100))], revision: 1) }
check(!small.exists, "oversized save writes nothing")

// Writer: late saves never replace newer ones; blocked writer never writes.
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    let directory = freshDirectory()
    let file = VersionedJSONFile<[Note]>(directory: directory, name: "notes", schemaVersion: 1)
    let writer = VersionedJSONWriter(file: file, loadedRevision: 0, blocked: false)
    let first = try await writer.save([Note(text: "two")], sequence: 2)
    let late = try await writer.save([Note(text: "one")], sequence: 1)
    let loaded = try file.load()!
    precondition(first && !late, "writer sequence result")
    precondition(loaded.payload == [Note(text: "two")] && loaded.revision == 1, "late save ignored")
    _ = try await writer.save([Note(text: "three")], sequence: 3)
    let advanced = try file.load()!
    precondition(advanced.revision == 2, "revision advances")

    let blocked = VersionedJSONWriter(file: file, loadedRevision: 0, blocked: true)
    do { _ = try await blocked.save([Note(text: "x")], sequence: 1); preconditionFailure("blocked writer saved") }
    catch let error as VersionedFileError { precondition(error == .writesBlocked, "blocked error") }
    let untouched = try file.load()!
    precondition(untouched.payload == [Note(text: "three")], "blocked writer left file alone")
    semaphore.signal()
}
semaphore.wait()
checks += 6
print("Persistence checks passed: \(checks)")
