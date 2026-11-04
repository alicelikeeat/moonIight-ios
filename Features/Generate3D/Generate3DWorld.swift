import Foundation
import RealityKit
import UIKit

/// AI-generated models as 3D-world character looks (v1.69). Models load in
/// the background (the default body shows meanwhile). Rigged models play
/// the clip for each character's action; characters sharing a model and a
/// clip share one deforming mesh, so many copies cost one skinning pass.
@available(iOS 18.0, *)
@MainActor final class Glass3DGeneratedLooks {
    private struct Loaded {
        var mesh: GeneratedMesh
        var height: Float
        var minY: Float
        var material: RealityKit.Material
        var rig: (package: RigPackage, skin: SkinWeights)?
        var staticMesh: MeshResource?
        var animated: [String: AnimatedRegionMesh] = [:]
    }
    private var loaded: [String: Loaded] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []
    private var clock: Float = 0, sinceUpdate: Float = 0

    func isReady(_ template: CharacterTemplate) -> Bool { template.generatedModelID.map { loaded[$0] != nil } ?? false }

    /// Entity for a template, or nil while loading / when the model is gone.
    func entity(_ template: CharacterTemplate, action: CharacterAction) -> Entity? {
        guard let id = template.generatedModelID, !failed.contains(id) else { return nil }
        guard var model = loaded[id] else { load(id); return nil }
        let body: Entity
        if let rig = model.rig {
            let clipID = RigClip.id(for: action)
            if model.animated[clipID] == nil, let shared = try? AnimatedRegionMesh(mesh: model.mesh, skin: rig.skin, skeleton: rig.package.skeleton) {
                model.animated[clipID] = shared
                loaded[id] = model
            }
            guard let shared = model.animated[clipID] else { return nil }
            body = shared.makeEntity(material: model.material)
        } else {
            if model.staticMesh == nil { model.staticMesh = try? Self.resource(model.mesh); loaded[id] = model }
            guard let resource = model.staticMesh else { return nil }
            body = ModelEntity(mesh: resource, materials: [model.material])
        }
        // Height from the template, feet on the ground; the relief's front
        // turns to the camera like the picture characters do.
        let scale = Float(template.height) / max(0.01, model.height)
        body.scale = SIMD3(repeating: scale)
        body.position = [0, -model.minY * scale, 0]
        let holder = Entity()
        holder.addChild(body)
        holder.components.set(BillboardComponent())
        if template.shadow { holder.addChild(Glass3DCharacters.shadow(radius: Float(template.height) * 0.25)) }
        return holder
    }

    /// Advances every shared clip (20 updates a second).
    func tick(_ dt: Float) {
        clock += dt; sinceUpdate += dt
        guard sinceUpdate >= 0.05 else { return }
        sinceUpdate = 0
        for model in loaded.values {
            guard let rig = model.rig else { continue }
            for (clipID, mesh) in model.animated {
                let clip = rig.package.clips.first { $0.id == clipID }
                mesh.pose(clip, time: clip.map { clock.truncatingRemainder(dividingBy: $0.period) } ?? 0)
            }
        }
    }

    private func load(_ id: String) {
        guard !loading.contains(id) else { return }
        loading.insert(id)
        let store = Generated3DStore.shared
        guard let manifest = store.models.first(where: { $0.id == id }), let meshURL = store.meshURL(manifest) else {
            loading.remove(id); failed.insert(id); return
        }
        let textureURL = store.textureURL(manifest)
        Task { @MainActor [self] in
            defer { self.loading.remove(id) }
            let mesh = await Task.detached(priority: .utility) { () -> GeneratedMesh? in
                (try? Data(contentsOf: meshURL)).flatMap(GeneratedMeshCodec.decode)
            }.value
            guard let mesh else { self.failed.insert(id); return }
            var rig: (package: RigPackage, skin: SkinWeights)?
            if let saved = await Generate3DRigging.load(manifest), saved.1.count == mesh.vertexCount { rig = (saved.0, saved.1) }
            var material = UnlitMaterial()
            if let textureURL, let texture = try? await TextureResource(contentsOf: textureURL, options: .init(semantic: .color)) {
                material.color = .init(tint: .white, texture: .init(texture))
            }
            let bounds = mesh.bounds
            self.loaded[id] = Loaded(mesh: mesh, height: bounds.max[1] - bounds.min[1], minY: bounds.min[1], material: material, rig: rig)
        }
    }

    private static func resource(_ mesh: GeneratedMesh) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "generated")
        descriptor.positions = MeshBuffers.Positions((0..<mesh.vertexCount).map { SIMD3(mesh.positions[$0 * 3], mesh.positions[$0 * 3 + 1], mesh.positions[$0 * 3 + 2]) })
        descriptor.normals = MeshBuffers.Normals((0..<mesh.vertexCount).map { SIMD3(mesh.normals[$0 * 3], mesh.normals[$0 * 3 + 1], mesh.normals[$0 * 3 + 2]) })
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates((0..<mesh.vertexCount).map { SIMD2(mesh.uvs[$0 * 2], mesh.uvs[$0 * 2 + 1]) })
        descriptor.primitives = .triangles(mesh.indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
