import SwiftUI
import RealityKit
import UIKit

/// Non-AR preview, available from iOS 16. Does not request camera access.
struct GeneratedModelPreview: UIViewRepresentable {
    let model: Entity
    let preset: ModelSkinPreset
    var darkBackground: Bool
    var fillLight: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.systemGray6)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.update(model, preset: preset)
        view.environment.background = .color(darkBackground ? .black : .systemGray6)
        context.coordinator.light.light.intensity = fillLight ? 3000 : 900
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        view.scene.anchors.removeAll()
        coordinator.materials.removeAll(); coordinator.model = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        let anchor = AnchorEntity(world: .zero)
        let camera = PerspectiveCamera()
        let rotation = Entity()
        let light = DirectionalLight()
        weak var model: Entity?
        var materials: [ObjectIdentifier: [any RealityKit.Material]] = [:]
        private var lastPreset: ModelSkinPreset?
        private var yaw: Float = 0, pitch: Float = 0
        private var zoom: Float = 1

        func attach(_ view: ARView) {
            camera.camera.fieldOfViewInDegrees = 40
            camera.position = [0, 0, 2.2]
            light.light.intensity = 3000
            light.orientation = simd_quatf(angle: -.pi / 5, axis: [1, 0, 0]) * simd_quatf(angle: -.pi / 6, axis: [0, 1, 0])
            let fill = PointLight()
            fill.light.intensity = 600; fill.position = [-1, 1, 2]
            anchor.addChild(camera); anchor.addChild(rotation); anchor.addChild(light); anchor.addChild(fill)
            view.scene.anchors.append(anchor)
            view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        }

        func update(_ newModel: Entity, preset: ModelSkinPreset) {
            if model !== newModel {
                rotation.children.removeAll(); materials.removeAll()
                let normalized = Entity()
                normalized.addChild(newModel)
                let bounds = newModel.visualBounds(relativeTo: normalized)
                let extent = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
                let scale = 1 / max(0.00001, extent)
                normalized.scale = SIMD3(repeating: scale)
                normalized.position = -bounds.center * scale
                rotation.addChild(normalized)
                model = newModel; lastPreset = nil
                yaw = 0; pitch = 0; zoom = 1
                rotation.orientation = simd_quatf(angle: 0, axis: [0, 1, 0]); camera.position = [0, 0, 2.2]
                visit(newModel) { entity in
                    if let component = entity.components[ModelComponent.self] { materials[ObjectIdentifier(entity)] = component.materials }
                }
            }
            guard preset != lastPreset else { return }
            lastPreset = preset
            let color = UIColor(red: CGFloat(preset.red), green: CGFloat(preset.green), blue: CGFloat(preset.blue), alpha: 1)
            visit(newModel) { entity in
                guard var component = entity.components[ModelComponent.self], let originals = materials[ObjectIdentifier(entity)] else { return }
                component.materials = originals.map { original in
                    if var material = original as? PhysicallyBasedMaterial {
                        material.baseColor.tint = color
                        material.roughness = .init(floatLiteral: preset.roughness)
                        return material
                    }
                    if var material = original as? SimpleMaterial {
                        material.color.tint = color
                        material.roughness = .init(floatLiteral: preset.roughness)
                        return material
                    }
                    if var material = original as? UnlitMaterial { material.color.tint = color; return material }
                    return original
                }
                entity.components.set(component)
            }
        }

        private func visit(_ entity: Entity, action: (Entity) -> Void) {
            action(entity)
            for child in entity.children { visit(child, action: action) }
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            let offset = gesture.translation(in: gesture.view)
            yaw += Float(offset.x) * 0.01
            pitch = min(.pi / 2, max(-.pi / 2, pitch + Float(offset.y) * 0.01))
            rotation.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
            gesture.setTranslation(.zero, in: gesture.view)
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            zoom = min(3, max(0.5, zoom * Float(gesture.scale)))
            camera.position = [0, 0, 2.2 / zoom]
            gesture.scale = 1
        }
    }
}
