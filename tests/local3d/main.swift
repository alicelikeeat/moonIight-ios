import Foundation

var checks = 0
@MainActor func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}
@MainActor func rejects(_ expected: GenerationError, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected \(expected)") }
    catch { check(error as? GenerationError == expected, "Wrong error: \(error)") }
}

let edge = 64
let depth = (0..<(edge * edge)).map { Float($0 % edge) / Float(edge - 1) }
let mask = [UInt8](repeating: 255, count: depth.count)
let mesh = try ModelOptimizationService.depthMesh(width: edge, height: edge, inverseDepth: depth,
    mask: mask, imageAspect: 1, maximumEdge: 64)
try mesh.validate()
check(mesh.positions.count == 4096, "Actual grid vertices")
check(mesh.triangleCount == 63 * 63 * 2, "Actual grid triangles")
check(mesh.positions.map(\.z).max()! - mesh.positions.map(\.z).min()! > 0.25, "Must have real depth")
check(Set(mesh.indices).count == mesh.positions.count, "No isolated vertices")
check(mesh.textureCoordinates.first == [0, 1] && mesh.textureCoordinates.last == [1, 0], "Texture orientation")
let a = mesh.positions[Int(mesh.indices[0])], b = mesh.positions[Int(mesh.indices[1])], c = mesh.positions[Int(mesh.indices[2])]
check((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0, "Faces point towards camera")

var cutout = mask
for y in 20..<44 { for x in 20..<44 { cutout[y * edge + x] = 0 } }
let holes = try ModelOptimizationService.depthMesh(width: edge, height: edge, inverseDepth: depth,
    mask: cutout, imageAspect: 1, maximumEdge: edge)
check(holes.positions.count < mesh.positions.count && holes.triangleCount < mesh.triangleCount, "Mask removes geometry")
check(holes.positions.allSatisfy { abs($0.x) >= 0.18 || abs($0.y) >= 0.18 }, "No invented geometry in mask hole")

rejects(.noSubject) { _ = try ModelOptimizationService.depthMesh(width: edge, height: edge, inverseDepth: depth,
    mask: Array(repeating: 0, count: depth.count), imageAspect: 1, maximumEdge: edge) }
rejects(.flatDepth) { _ = try ModelOptimizationService.depthMesh(width: edge, height: edge,
    inverseDepth: Array(repeating: 1, count: depth.count), mask: mask, imageAspect: 1, maximumEdge: edge) }
rejects(.noSubject) { _ = try ModelOptimizationService.depthMesh(width: edge, height: edge,
    inverseDepth: Array(repeating: .nan, count: depth.count), mask: mask, imageAspect: 1, maximumEdge: edge) }
rejects(.invalidInput("深度与主体遮罩尺寸无效。")) {
    _ = try ModelOptimizationService.depthMesh(width: 1, height: 1, inverseDepth: [], mask: [], imageAspect: 1, maximumEdge: edge)
}
rejects(.invalidInput("深度与主体遮罩尺寸无效。")) {
    _ = try ModelOptimizationService.depthMesh(width: edge, height: edge, inverseDepth: depth, mask: mask, imageAspect: .nan, maximumEdge: edge)
}

let bounded = try ModelOptimizationService.depthMesh(width: edge, height: edge, inverseDepth: depth,
    mask: mask, imageAspect: 2, maximumEdge: 99999)
check(bounded.positions.count <= 192 * 192, "Mesh budget enforced")
check(bounded.positions.map(\.y).max()! <= 0.25, "Preserves image aspect")

var corrupt = mesh
corrupt.indices[0] = UInt32.max
rejects(.corruptAsset) { try corrupt.validate() }
corrupt = mesh; corrupt.positions[0].x = .infinity
rejects(.corruptAsset) { try corrupt.validate() }
corrupt = mesh; corrupt.textureCoordinates[0].x = 2
rejects(.corruptAsset) { try corrupt.validate() }

let data = try JSONEncoder().encode(mesh)
let reloaded = try JSONDecoder().decode(DepthMesh.self, from: data)
check(reloaded == mesh, "Geometry survives serialization/reload")
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/local3d-test.usdz")
let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII=")!
try DepthUSDZWriter.write(mesh: reloaded, png: png, to: output)
check((try? Data(contentsOf: output).count) ?? 0 > 20000, "USDZ contains mesh, not a picture-only file")

var report = VideoQualityReport(sampled: 60, accepted: 40, blurry: 10, duplicates: 10, humanFrames: 0,
    durationSeconds: 20, diverseTransitions: 10)
check(report.canAttemptObjectCapture, "Candidate static object")
check(report.coverageStatus == "unverified", "Feature diversity never proves view coverage")
report.humanFrames = 1
check(!report.canAttemptObjectCapture, "People video rejected for object reconstruction")
report.humanFrames = 0; report.diverseTransitions = 0
check(!report.canAttemptObjectCapture && report.coverageStatus == "insufficient", "Fixed viewpoint rejected")
report.diverseTransitions = 10; report.accepted = 3
check(!report.canAttemptObjectCapture, "Few frames rejected")

let id = UUID()
let manifest = GeneratedModelManifest(id: id, createdAt: .now, title: "unit fixture", sourceName: "fixture.png",
    sourceHash: String(repeating: "a", count: 64), sourceExtension: "png", engine: GeneratedModelManifest.engineVersion,
    kind: .depthSurface, quality: "test", vertices: mesh.positions.count, triangles: mesh.triangleCount,
    textureWidth: 1, textureHeight: 1, modelBytes: 1, elapsedSeconds: 0, realityKitValidated: false)
check(manifest.skeletonStatus == "notImplemented" && manifest.animationStatus == "staticOnly" && manifest.clothingStatus == "wholeMaterialOnly", "No false advanced capabilities")
check(!manifest.realityKitValidated, "Writing a file does not prove RealityKit loaded it")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local3d-unit-\(UUID())")
defer { try? FileManager.default.removeItem(at: directory) }
let storage = VersionedJSONFile<GeneratedModelManifest>(directory: directory, name: id.uuidString, schemaVersion: 1)
try storage.save(manifest, revision: 1)
let freshStorage = VersionedJSONFile<GeneratedModelManifest>(directory: directory, name: id.uuidString, schemaVersion: 1)
let reopened = try freshStorage.load()?.payload
check(reopened == manifest, "Reopen manifest from a fresh storage instance")
var skin = ModelSkinPreset(modelID: id)
try skin.validate(); skin.red = .nan
rejects(.corruptAsset) { try skin.validate() }
skin.red = 1; skin.roughness = -1
rejects(.corruptAsset) { try skin.validate() }

// Test actual cooperative cancellation inside mesh generation.
let semaphore = DispatchSemaphore(value: 0)
Task.detached {
    let work = Task {
        // Enter the actual algorithm in a cancelled task.
        while !Task.isCancelled { await Task.yield() }
        return try ModelOptimizationService.depthMesh(width: edge, height: edge, inverseDepth: depth,
            mask: mask, imageAspect: 1, maximumEdge: edge)
    }
    work.cancel()
    do { _ = try await work.value; fatalError("Cancellation ignored") }
    catch { precondition(error is CancellationError) }
    semaphore.signal()
}
check(semaphore.wait(timeout: .now() + 10) == .success, "Task cancellation completes")
print("Local3D: \(checks) checks passed; USDZ fixture: \(output.path)")
