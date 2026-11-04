import Foundation
import RealityKit
import UIKit
import simd

// v1.73 M06: RealityKit preview for the rig workbench. RealityKit poses
// skeletons but does not compute skin weights, so this adapter deforms the
// mesh on the CPU with the rig's own weights (linear blend skinning) into a
// LowLevelMesh, and draws joints, bones and the selected joint's axes.

@available(iOS 18.0, *)
@MainActor final class SkinnedMeshPlayer {
    struct Vertex { var position: SIMD3<Float>; var normal: SIMD3<Float>; var uv: SIMD2<Float> }
    let mesh: GeneratedMesh
    let lowLevel: LowLevelMesh
    let resource: MeshResource

    init(mesh: GeneratedMesh) throws {
        self.mesh = mesh
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: mesh.vertexCount, vertexAttributes: attributes,
                                                 vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)], indexCapacity: mesh.indices.count)
        lowLevel = try LowLevelMesh(descriptor: descriptor)
        let indices = mesh.indices
        lowLevel.withUnsafeMutableIndices { raw in
            let target = raw.bindMemory(to: UInt32.self)
            for (i, index) in indices.enumerated() { target[i] = index }
        }
        lowLevel.parts.replaceAll([LowLevelMesh.Part(indexCount: indices.count, topology: .triangle, bounds: BoundingBox(min: [-3, -3, -3], max: [3, 3, 3]))])
        resource = try MeshResource(from: lowLevel)
        update(positions: mesh.positions, normals: mesh.normals)
    }

    func update(positions: [Float], normals: [Float]) {
        let uvs = mesh.uvs, n = mesh.vertexCount
        lowLevel.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let target = raw.bindMemory(to: Vertex.self)
            for i in 0..<n {
                target[i] = Vertex(position: SIMD3(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]),
                                   normal: SIMD3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]), uv: SIMD2(uvs[i * 2], uvs[i * 2 + 1]))
            }
        }
    }
}

extension RigXform {
    var simd: simd_float4x4 {
        simd_float4x4(columns: (SIMD4(a, b, c, 0), SIMD4(d, e, f, 0), SIMD4(g, h, i, 0), SIMD4(tx, ty, tz, 1)))
    }
}

@available(iOS 18.0, *)
@MainActor final class RigPreviewScene: ObservableObject {
    let root = Entity()
    private let pivot = Entity()
    private let content = Entity()
    private let camera = PerspectiveCamera()
    private let rigLayer = Entity()
    private let axes = Entity()
    @Published var yaw: Float = 0.4 { didSet { turn() } }
    @Published var pitch: Float = -0.1 { didSet { turn() } }
    @Published var distance: Float = 2.0 { didSet { place() } }
    @Published var showSkeleton = true { didSet { restyle(); rigLayer.isEnabled = showSkeleton } }
    @Published private(set) var playing: MotionClip?

    private var player: SkinnedMeshPlayer?
    private var body: ModelEntity?
    private var texture: TextureResource?
    private var skeleton: SkeletonDefinition?
    private var skin: SkinInfluences?
    private var markers: [ModelEntity] = []
    private var bones: [ModelEntity] = []
    private var selected: Int?
    /// Manual pose from the joint rotation sliders (degrees).
    private var manual: SkeletonPose?
    private var clock: Float = 0, sinceUpdate: Float = 0
    private var needsPose = true
    var updates: EventSubscription?

    init() {
        root.addChild(pivot); root.addChild(camera)
        pivot.addChild(content)
        camera.camera.fieldOfViewInDegrees = 40
        let backdrop = ModelEntity(mesh: .generateSphere(radius: 30))
        var sky = UnlitMaterial(color: UIColor(white: 0.12, alpha: 1)); sky.faceCulling = .front
        backdrop.model?.materials = [sky]
        root.addChild(backdrop)
        let light = DirectionalLight(); light.light.intensity = 2500; light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        root.addChild(light)
        // Axes: x red, y green, z blue.
        for (i, color) in [UIColor.systemRed, .systemGreen, .systemBlue].enumerated() {
            var size: SIMD3<Float> = [0.006, 0.006, 0.006]; size[i] = 0.12
            let bar = ModelEntity(mesh: .generateBox(size: size), materials: [UnlitMaterial(color: color)])
            var offset: SIMD3<Float> = .zero; offset[i] = 0.06
            bar.position = offset
            axes.addChild(bar)
        }
        axes.isEnabled = false
        place(); turn()
    }

    private func place() { camera.look(at: .zero, from: [0, 0, max(0.6, min(6, distance))], relativeTo: nil) }
    private func turn() { pivot.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0]) }

    func setModel(_ mesh: GeneratedMesh, textureURL: URL?) async {
        content.children.removeAll()
        player = try? SkinnedMeshPlayer(mesh: mesh)
        if let textureURL { texture = try? await TextureResource(contentsOf: textureURL, options: .init(semantic: .color)) }
        guard let player else { return }
        let entity = ModelEntity(mesh: player.resource)
        body = entity
        content.addChild(entity)
        content.addChild(rigLayer); rigLayer.addChild(axes)
        let b = mesh.bounds
        content.position = -SIMD3((b.min[0] + b.max[0]) / 2, (b.min[1] + b.max[1]) / 2, (b.min[2] + b.max[2]) / 2)
        restyle()
        needsPose = true
    }

    private func restyle() {
        var material = UnlitMaterial()
        if let texture { material.color = .init(tint: .white, texture: .init(texture)) } else { material.color = .init(tint: UIColor(white: 0.85, alpha: 1)) }
        if showSkeleton { material.blending = .transparent(opacity: .init(floatLiteral: 0.45)) }
        body?.model?.materials = [material]
    }

    /// Shows a rig (nil hides joints and plays nothing).
    func setRig(_ skeleton: SkeletonDefinition?, skin: SkinInfluences?) {
        self.skeleton = skeleton; self.skin = skin
        if let manual, manual.rotations.count != skeleton?.joints.count { self.manual = nil }
        for m in markers { m.removeFromParent() }
        for b in bones { b.removeFromParent() }
        markers = []; bones = []
        guard let skeleton else { needsPose = true; return }
        let height = skeleton.height
        for joint in skeleton.joints {
            let color: UIColor = joint.confidence >= 0.8 ? .systemGreen : joint.confidence >= 0.5 ? .systemYellow : .systemRed
            let marker = ModelEntity(mesh: .generateSphere(radius: height * 0.012), materials: [UnlitMaterial(color: color)])
            rigLayer.addChild(marker); markers.append(marker)
            let bone = ModelEntity(mesh: .generateCylinder(height: 1, radius: height * 0.004), materials: [UnlitMaterial(color: UIColor.white.withAlphaComponent(0.9))])
            rigLayer.addChild(bone); bones.append(bone)
        }
        needsPose = true
    }

    func select(_ joint: Int?) {
        selected = joint
        for (i, m) in markers.enumerated() { m.scale = SIMD3(repeating: i == joint ? 1.8 : 1) }
        axes.isEnabled = joint != nil
        needsPose = true
    }

    func play(_ clip: MotionClip?) { playing = clip; clock = 0; manual = nil; needsPose = true }

    /// Rotation of one joint (degrees), for the skeleton page.
    func rotate(_ joint: Int, to degrees: SIMD3<Float>) {
        guard let skeleton else { return }
        playing = nil
        var pose = manual ?? SkeletonPose.rest(skeleton)
        pose.rotations[joint] = degrees
        manual = pose; needsPose = true
    }
    func rotation(_ joint: Int) -> SIMD3<Float> { manual?.rotations[safe: joint] ?? .zero }
    func restPose() { manual = nil; playing = nil; needsPose = true }

    func tick(_ dt: Float) {
        clock += dt; sinceUpdate += dt
        guard needsPose || playing != nil, sinceUpdate >= 1.0 / 30 else { return }
        sinceUpdate = 0; needsPose = false
        guard let player else { return }
        guard let skeleton, let skin, skin.count == player.mesh.vertexCount else {
            player.update(positions: player.mesh.positions, normals: player.mesh.normals); return
        }
        let pose: SkeletonPose
        if let playing { pose = playing.pose(skeleton, at: clock.truncatingRemainder(dividingBy: playing.period), height: skeleton.height) }
        else { pose = manual ?? SkeletonPose.rest(skeleton) }
        let deformed = SkinWeightSolver.deform(player.mesh, skin: skin, matrices: pose.skinning(skeleton))
        player.update(positions: deformed.positions, normals: deformed.normals)
        let world = pose.world(skeleton)
        for (i, m) in markers.enumerated() where i < world.count { m.position = world[i].origin }
        for (i, bone) in bones.enumerated() where i < world.count {
            guard let p = skeleton.parentIndex(i) else { bone.isEnabled = false; continue }
            let a = world[p].origin, b = world[i].origin, d = b - a, length = simd_length(d)
            bone.isEnabled = length > 1e-4
            guard length > 1e-4 else { continue }
            bone.position = (a + b) / 2
            bone.scale = [1, length, 1]
            bone.orientation = simd_quatf(from: [0, 1, 0], to: d / length)
        }
        if let selected, selected < world.count {
            axes.transform = Transform(matrix: world[selected].simd)
            axes.scale = SIMD3(repeating: skeleton.height)
        }
    }
}
