import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// One world, two ways to look at it. Switching changes the projection only.
// Player coordinates, block collision and the clock stay on `SpatialWorld`.

enum WorldViewMode: String, Codable, Sendable {
    case pixelRPG, spatial3D
}

/// Classic overhead RPG camera: orthographic, fixed pitch, pinch zoom.
struct PixelRPGProfile: Equatable, Sendable {
    var pitchDegrees = 50.0
    /// Vertical extent of the orthographic view, in world cells.
    var verticalSpan = 42.0
    var yaw = 0.0
    static let minimumSpan = 14.0
    static let maximumSpan = 110.0

    var clampedSpan: Double { min(Self.maximumSpan, max(Self.minimumSpan, verticalSpan.isFinite ? verticalSpan : 42)) }
}

struct DualPerspectiveCamera: Equatable, Sendable {
    var mode: WorldViewMode
    var target: SpatialVector
    var spatialTilt: Double
    var spatialYaw: Double
    var spatialDistance: Double
    var pixel: PixelRPGProfile

    static func following(_ target: SpatialVector, mode: WorldViewMode = .spatial3D) -> DualPerspectiveCamera {
        DualPerspectiveCamera(mode: mode, target: target, spatialTilt: SpatialCameraRules.playTilt, spatialYaw: 0, spatialDistance: 14, pixel: PixelRPGProfile())
    }

    /// Copies yaw across so the view keeps facing the same way. Does not move `target`.
    mutating func toggle() {
        let held = target
        switch mode {
        case .spatial3D:
            pixel.yaw = spatialYaw
            mode = .pixelRPG
        case .pixelRPG:
            spatialYaw = pixel.yaw
            mode = .spatial3D
        }
        target = held
    }

    /// Writes the view mode onto the world and puts position, blocks and clock back
    /// if anything else moved. Collision data is the block list.
    mutating func applyToggle(to world: inout SpatialWorld) {
        let position = world.player.position
        let lastSafe = world.player.lastSafe
        let blocks = world.blocks
        let clock = world.clock
        toggle()
        var save = world.hybrid ?? HybridWorldSave.centralFocus(mode: mode)
        save.viewMode = mode
        world.hybrid = save
        world.player.position = position
        world.player.lastSafe = lastSafe
        world.blocks = blocks
        world.clock = clock
    }

    /// Eye for the pixel profile. Yaw 0 sits south of the target and looks north,
    /// the same convention as `SpatialCameraRules`.
    static func pixelEye(target: SpatialVector, profile: PixelRPGProfile) -> SpatialVector {
        let pitch = min(80, max(35, profile.pitchDegrees)) * .pi / 180
        let distance = 40.0
        let horizontal = cos(pitch) * distance
        let yaw = profile.yaw * .pi / 180
        return SpatialVector(target.x + sin(yaw) * horizontal, target.y - cos(yaw) * horizontal, target.z + sin(pitch) * distance)
    }

    func eye() -> SpatialVector {
        switch mode {
        case .pixelRPG:
            return Self.pixelEye(target: target, profile: pixel)
        case .spatial3D:
            let state = SpatialCameraState(target: target, tilt: spatialTilt, yaw: spatialYaw, distance: spatialDistance)
            return SpatialCameraRules.position(state)
        }
    }

#if canImport(CoreGraphics)
    func projection(viewSize: CGSize) -> SpatialProjection {
        switch mode {
        case .pixelRPG:
            var profile = pixel
            profile.verticalSpan = profile.clampedSpan
            return SpatialProjection(eye: Self.pixelEye(target: target, profile: profile), target: target, fieldOfView: SpatialCameraRules.fieldOfView, viewSize: viewSize, yaw: profile.yaw, orthographicSpan: profile.verticalSpan)
        case .spatial3D:
            let state = SpatialCameraState(target: target, tilt: spatialTilt, yaw: spatialYaw, distance: spatialDistance)
            return SpatialProjection(eye: SpatialCameraRules.position(state), target: target, fieldOfView: SpatialCameraRules.fieldOfView, viewSize: viewSize, yaw: spatialYaw, orthographicSpan: nil)
        }
    }
#endif
}

/// What a perspective switch is allowed to change: the saved view mode only.
struct PerspectiveContinuity: Equatable, Sendable {
    var position: SpatialVector
    var lastSafe: SpatialVector
    var collision: [String: String]
    var clock: Double

    static func capture(_ world: SpatialWorld) -> PerspectiveContinuity {
        let collision = Dictionary(world.blocks.map { ($0.id, $0.collision.rawValue) }, uniquingKeysWith: { first, _ in first })
        return PerspectiveContinuity(position: world.player.position, lastSafe: world.player.lastSafe, collision: collision, clock: world.clock)
    }
}
