import Foundation
import CoreGraphics
import ImageIO
import Vision
import RealityKit
import Metal
import simd

// P2 (experimental): automatic rig for humanoid depth models, on device.
// Body joints come from Vision on the model's own picture; the rig is
// built and checked off the main thread and only kept when the check
// passes. Playback deforms the mesh on the CPU (linear blend skinning)
// into one RealityKit LowLevelMesh per body region.

enum Generate3DRigError: LocalizedError {
    case noMesh, noPicture, notHumanoid, failedCheck([String])
    var errorDescription: String? {
        switch self {
        case .noMesh: L10n.t("只有深度立体模型可以自动绑定骨骼（多视角重建模型暂不支持）。", "Only depth models can be rigged automatically (reconstructed models are not supported yet).")
        case .noPicture: L10n.t("找不到这个模型的原图贴图。", "This model's picture is missing.")
        case .notHumanoid: L10n.t("没有检测到完整的人形姿态：需要看得清脖子、双肩和双髋。模型保持为静态。", "No complete human pose found: the neck, both shoulders and both hips must be visible. The model stays static.")
        case .failedCheck(let problems): L10n.t("骨骼绑定没有通过自动检查（", "The rig failed the automatic check (") + problems.joined(separator: ", ") + L10n.t("），模型保持为静态。", "); the model stays static.")
        }
    }
}

@available(iOS 18.0, *)
enum Generate3DRigging {
    /// Vision body pose on the picture → joints in picture coordinates.
    static func joints(in pictureURL: URL) throws -> BodyJoints2D {
        guard let source = CGImageSourceCreateWithURL(pictureURL as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Generate3DRigError.noPicture
        }
        let request = VNDetectHumanBodyPoseRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        guard let body = request.results?.max(by: { $0.confidence < $1.confidence }) else { throw Generate3DRigError.notHumanoid }
        let points = try body.recognizedPoints(.all)
        var out: [String: BodyJoints2D.Point] = [:]
        for (name, point) in points where point.confidence > 0 {
            // Vision: origin bottom-left. Picture coordinates: v down.
            out[name.rawValue.rawValue] = .init(u: Double(point.location.x), v: 1 - Double(point.location.y), confidence: Double(point.confidence))
        }
        return BodyJoints2D(points: out)
    }

    /// Builds, checks and saves a rig; returns the updated manifest.
    @MainActor static func rig(_ manifest: Generated3DManifest, store: Generated3DStore) async throws -> Generated3DManifest {
        guard let meshURL = store.meshURL(manifest) else { throw Generate3DRigError.noMesh }
        guard let pictureURL = store.textureURL(manifest) else { throw Generate3DRigError.noPicture }
        let id = manifest.id
        let skeletonURL = Generated3DStore.folder("Skeletons").appendingPathComponent(id + ".json")
        let skinURL = Generated3DStore.folder("Skeletons").appendingPathComponent(id + ".skin")
        let clipsURL = Generated3DStore.folder("Animations").appendingPathComponent(id + ".json")
        let validation = try await Task.detached(priority: .userInitiated) { () -> RigValidation in
            let joints = try Generate3DRigging.joints(in: pictureURL)
            guard let data = try? Data(contentsOf: meshURL), let mesh = GeneratedMeshCodec.decode(data) else { throw Generate3DRigError.noMesh }
            let skeleton: RigSkeleton
            do { skeleton = try AutoRig.skeleton(for: mesh, joints: joints) } catch { throw Generate3DRigError.notHumanoid }
            let skin = AutoRig.weights(for: mesh, skeleton: skeleton)
            let validation = RigValidation.run(mesh, skeleton: skeleton, skin: skin)
            guard validation.passed else { throw Generate3DRigError.failedCheck(validation.problems) }
            let package = RigPackage(skeleton: skeleton, joints: joints, clips: RigClip.standard, validation: validation)
            try JSONEncoder().encode(package).write(to: skeletonURL, options: .atomic)
            try skin.encoded().write(to: skinURL, options: .atomic)
            try JSONEncoder().encode(RigClip.standard).write(to: clipsURL, options: .atomic)
            return validation
        }.value
        var updated = manifest
        updated.rigFile = id
        updated.humanoidDetected = true
        updated.rigging = .experimentalVerified
        updated.animation = .experimentalVerified
        let seams = validation.seamStretch.values.max() ?? 0
        updated.notes.append(L10n.t("骨骼绑定（实验）：10 根骨骼、4 个动作，已通过本机自动检查，最大接缝拉伸 \(String(format: "%.2f", seams * 100))%。尚未经过人工真机验收。",
                                    "Rig (experimental): 10 bones, 4 clips; passed the on-device automatic check, worst seam stretch \(String(format: "%.2f", seams * 100))%. Not yet accepted on a device by a person."))
        try store.save(updated)
        return updated
    }

    /// Saved rig for a model, if any.
    static func load(_ manifest: Generated3DManifest) async -> (RigPackage, SkinWeights)? {
        guard let id = manifest.rigFile else { return nil }
        let skeletonURL = Generated3DStore.folder("Skeletons").appendingPathComponent(id + ".json")
        let skinURL = Generated3DStore.folder("Skeletons").appendingPathComponent(id + ".skin")
        return await Task.detached(priority: .userInitiated) { () -> (RigPackage, SkinWeights)? in
            guard let package = (try? Data(contentsOf: skeletonURL)).flatMap({ try? JSONDecoder().decode(RigPackage.self, from: $0) }),
                  let skin = (try? Data(contentsOf: skinURL)).flatMap(SkinWeights.decode) else { return nil }
            return (package, skin)
        }.value
    }
}

/// One RealityKit mesh per body region, deformed on the CPU each frame.
@available(iOS 18.0, *)
@MainActor final class AnimatedRegionMesh {
    struct Vertex { var position: SIMD3<Float>; var normal: SIMD3<Float>; var uv: SIMD2<Float> }
    private struct Region { var vertices: [Int32]; var mesh: LowLevelMesh; var entity: ModelEntity }

    let root = Entity()
    private var regions: [Region] = []
    private let mesh: GeneratedMesh
    private let skin: SkinWeights
    private let skeleton: RigSkeleton
    private var deformedPositions: [SIMD3<Float>]
    private var deformedNormals: [SIMD3<Float>]

    init(mesh: GeneratedMesh, skin: SkinWeights, skeleton: RigSkeleton) throws {
        self.mesh = mesh; self.skin = skin; self.skeleton = skeleton
        deformedPositions = (0..<mesh.vertexCount).map { SIMD3(mesh.positions[$0 * 3], mesh.positions[$0 * 3 + 1], mesh.positions[$0 * 3 + 2]) }
        deformedNormals = (0..<mesh.vertexCount).map { SIMD3(mesh.normals[$0 * 3], mesh.normals[$0 * 3 + 1], mesh.normals[$0 * 3 + 2]) }
        let triangleRegion = RigPose.triangleRegions(mesh, skin: skin)
        for region in 0..<4 {
            var remap = [Int32](repeating: -1, count: mesh.vertexCount), vertices: [Int32] = [], indices: [UInt32] = []
            for t in 0..<mesh.triangleCount where triangleRegion[t] == UInt8(region) {
                for k in 0..<3 {
                    let v = Int(mesh.indices[t * 3 + k])
                    if remap[v] < 0 { remap[v] = Int32(vertices.count); vertices.append(Int32(v)) }
                    indices.append(UInt32(remap[v]))
                }
            }
            guard !indices.isEmpty else { continue }
            let attributes: [LowLevelMesh.Attribute] = [
                .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
                .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
                .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
            ]
            let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertices.count, vertexAttributes: attributes,
                                                     vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)],
                                                     indexCapacity: indices.count)
            let low = try LowLevelMesh(descriptor: descriptor)
            low.withUnsafeMutableIndices { raw in
                let target = raw.bindMemory(to: UInt32.self)
                for (i, index) in indices.enumerated() { target[i] = index }
            }
            low.parts.replaceAll([LowLevelMesh.Part(indexCount: indices.count, topology: .triangle, bounds: BoundingBox(min: [-2, -2, -2], max: [2, 2, 2]))])
            let entity = ModelEntity(mesh: try MeshResource(from: low))
            root.addChild(entity)
            regions.append(Region(vertices: vertices, mesh: low, entity: entity))
        }
        write()
    }

    /// Region of each part entity, for colours.
    var regionEntities: [(region: Int, entity: ModelEntity)] {
        var out: [(Int, ModelEntity)] = []
        var index = 0
        let present = Set(RigPose.triangleRegions(mesh, skin: skin))
        for region in 0..<4 where present.contains(UInt8(region)) { out.append((region, regions[index].entity)); index += 1 }
        return out
    }

    /// Poses the mesh for `clip` at `time` (nil clip = rest pose).
    func pose(_ clip: RigClip?, time: Float) {
        let matrices = RigPose.matrices(skeleton, clip: clip, time: time).map { m in
            simd_float4x4(columns: (SIMD4(m.m[0], m.m[1], m.m[2], m.m[3]), SIMD4(m.m[4], m.m[5], m.m[6], m.m[7]),
                                    SIMD4(m.m[8], m.m[9], m.m[10], m.m[11]), SIMD4(m.m[12], m.m[13], m.m[14], m.m[15])))
        }
        for i in 0..<mesh.vertexCount {
            let p = SIMD4(mesh.positions[i * 3], mesh.positions[i * 3 + 1], mesh.positions[i * 3 + 2], 1)
            let n = SIMD4(mesh.normals[i * 3], mesh.normals[i * 3 + 1], mesh.normals[i * 3 + 2], 0)
            let a = matrices[Int(skin.bone0[i])], b = matrices[Int(skin.bone1[i])], w = skin.weight0[i]
            let q = a * p * w + b * p * (1 - w), m = a * n * w + b * n * (1 - w)
            deformedPositions[i] = SIMD3(q.x, q.y, q.z)
            let normal = SIMD3(m.x, m.y, m.z)
            deformedNormals[i] = simd_length(normal) > 0 ? simd_normalize(normal) : SIMD3(0, 0, 1)
        }
        write()
    }

    private func write() {
        for region in regions {
            region.mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
                let target = raw.bindMemory(to: Vertex.self)
                for (i, v) in region.vertices.enumerated() {
                    let index = Int(v)
                    target[i] = Vertex(position: deformedPositions[index], normal: deformedNormals[index],
                                       uv: SIMD2(mesh.uvs[index * 2], mesh.uvs[index * 2 + 1]))
                }
            }
        }
    }
}
