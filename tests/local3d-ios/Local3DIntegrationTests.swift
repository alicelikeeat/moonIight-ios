import XCTest
import RealityKit
@testable import Moonlight

@MainActor
final class Local3DIntegrationTests: XCTestCase {
    func testBundledCoreMLModelCompilesAndPredictsOffline() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("The bundled spec-8 model requires iOS 17") }
        let source = try XCTUnwrap(Bundle.main.url(forResource: "ph_aerial_rocks_02", withExtension: "jpg", subdirectory: "Glass3DStarter"))
        // A bundled CC0 texture is used to test real inference and resource paths;
        // this is not a subject-segmentation or reconstruction quality test.
        let output = try await Task.detached(priority: .userInitiated) {
            let image = try ImageGenerationPipeline.decode(source, edge: 1024)
            return try ImageGenerationPipeline.estimateDepth(image)
        }.value
        XCTAssertEqual(output.width, 518)
        XCTAssertEqual(output.height, 392)
        XCTAssertEqual(output.values.count, 518 * 392)
        XCTAssertTrue(output.values.allSatisfy(\.isFinite))
        XCTAssertGreaterThan((output.values.max() ?? 0) - (output.values.min() ?? 0), 0.0001)
    }

    func testSavedDepthMeshLoadsInRealityKitAndReopensFromDisk() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("local3d-integration-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII="))
        let source = directory.appendingPathComponent("source.png")
        try png.write(to: source)
        let edge = 32
        let depth = (0..<(edge * edge)).map { Float($0 % edge) / Float(edge - 1) }
        let mesh = try ModelOptimizationService.depthMesh(width: edge, height: edge, inverseDepth: depth,
            mask: Array(repeating: 255, count: depth.count), imageAspect: 1, maximumEdge: edge)
        let generated = GeneratedImage(mesh: mesh, texture: png, width: 1, height: 1, quality: "test-fixture")
        let store = GeneratedAssetStore(root: directory.appendingPathComponent("Generated3D"))
        let manifest = try await store.saveImage(generated, source: source, title: "geometry-test", libraryID: nil, elapsed: 0)
        XCTAssertFalse(manifest.realityKitValidated)
        let loader = GeneratedModelLoader()
        let entity = try await loader.load(store.modelURL(manifest.id))
        let bounds = entity.visualBounds(relativeTo: nil)
        XCTAssertGreaterThan(bounds.extents.x, 0.9)
        XCTAssertGreaterThan(bounds.extents.z, 0.25)
        let confirmed = try await store.confirmRealityKit(manifest.id)
        XCTAssertTrue(confirmed.realityKitValidated)
        let freshStore = GeneratedAssetStore(root: store.root)
        let reopened = try await freshStore.manifest(manifest.id)
        XCTAssertEqual(reopened, confirmed)
        _ = try await loader.load(freshStore.modelURL(reopened.id))
        var skin = ModelSkinPreset(modelID: manifest.id)
        skin.red = 0.3
        try await freshStore.savePreset(skin)
        let reopenedSkin = try await freshStore.preset(manifest.id)
        XCTAssertEqual(reopenedSkin, skin)
        // Identical input and texture must share content-addressed files.
        let other = try await store.saveImage(generated, source: source, title: "same-source", libraryID: nil, elapsed: 0)
        XCTAssertEqual(other.sourceHash, manifest.sourceHash)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.root.appendingPathComponent("Sources").path).count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.root.appendingPathComponent("Textures").path).count, 1)
        try await store.delete(manifest.id)
        let remaining = try await store.list()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.root.appendingPathComponent("Sources").path).count, 1)
        try await store.delete(other.id)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: store.root.appendingPathComponent("Sources").path).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: source.path), "Imported source outside Generated3D must stay untouched")
    }

    func testOversizedImageIsRejectedBeforeCopy() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("oversize-\(UUID()).png")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: source) }
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 101 << 20)
        try handle.close()
        XCTAssertThrowsError(try Local3DPhotoFile.stage(source, video: false))
    }
}
