import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Native iOS glass on world blocks (iOS 26+): every visible block face is
// projected to the screen and drawn as one merged system glass layer over
// the 3D world. This file holds the pure geometry: block corners, the
// faces turned toward the camera, and screen polygons with one winding.

enum SpatialFaces {
    /// The 8 corners of a block in world cells (z up), placed by its
    /// group's frame when it moves. Order: bottom ring, then top ring.
    static func corners(_ block: SpatialBlock, frame: GroupFrame? = nil) -> [SpatialVector] {
        let half = block.size / 2
        var center = SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, 0)
        var lift = 0.0, turn = block.yaw
        if let frame { let placed = frame.place(center); center = SpatialVector(placed.x, placed.y, 0); lift = frame.offset.z; turn += frame.yaw }
        let radians = turn * .pi / 180, c = cos(radians), s = sin(radians)
        let ring = [(-half, -half), (half, -half), (half, half), (-half, half)].map { dx, dy in (center.x + dx * c - dy * s, center.y + dx * s + dy * c) }
        let bottom = block.elevation + lift, top = block.top + lift
        return ring.map { SpatialVector($0.0, $0.1, bottom) } + ring.map { SpatialVector($0.0, $0.1, top) }
    }

    /// Faces as corner indices, each listed counter-clockwise seen from
    /// outside, with its outward normal direction index.
    static let faces: [[Int]] = [
        [4, 5, 6, 7], // top
        [3, 2, 1, 0], // bottom
        [0, 1, 5, 4], // south (−y)
        [1, 2, 6, 5], // east (+x)
        [2, 3, 7, 6], // north (+y)
        [3, 0, 4, 7], // west (−x)
    ]

    /// Nearest depth (in front of the camera) a glass face may have. The 3D
    /// view clips geometry right in front of the lens, but a projected
    /// glass path would blow up to cover the screen (seen after revive, when
    /// the camera came to rest next to a block).
    static let nearestFaceDepth = 0.6

    /// A projected face is drawn only when every corner is far enough in
    /// front of the camera and it is not larger than the view itself.
    static func drawable(depths: [Double], bounds: CGRect, viewSize: CGSize) -> Bool {
        guard depths.count == 4, depths.allSatisfy({ $0.isFinite && $0 >= nearestFaceDepth }) else { return false }
        guard bounds.width.isFinite, bounds.height.isFinite else { return false }
        return bounds.width <= viewSize.width * 1.2 && bounds.height <= viewSize.height * 1.2
    }

    /// The faces turned toward `eye` (at most three for a box).
    static func visibleFaces(_ corners: [SpatialVector], eye: SpatialVector) -> [(index: Int, points: [SpatialVector])] {
        guard corners.count == 8 else { return [] }
        let center = corners.reduce(SpatialVector.zero, +) * (1.0 / 8)
        return faces.enumerated().compactMap { index, face in
            let points = face.map { corners[$0] }
            let faceCenter = points.reduce(SpatialVector.zero, +) * 0.25
            let normal = faceCenter - center
            let toEye = eye - faceCenter
            return normal.x * toEye.x + normal.y * toEye.y + normal.z * toEye.z > 1e-9 ? (index, points) : nil
        }
    }

    /// Signed area of a screen polygon (positive: counter-clockwise in a
    /// y-down screen space means clockwise visually).
    static func signedArea(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            area += Double(a.x * b.y - b.x * a.y)
        }
        return area / 2
    }

    /// Every polygon wound the same way, so overlapping faces join into one
    /// glass shape under the non-zero fill rule instead of cancelling out.
    static func oriented(_ points: [CGPoint]) -> [CGPoint] {
        signedArea(points) < 0 ? points.reversed() : points
    }

    /// The nearest blocks to the focus point, up to `budget` (cost control:
    /// one merged glass pass, but its shape still grows with face count).
    /// Blocks chosen last time get `margin` cells of head start, so blocks
    /// at the edge of the budget do not pop in and out as the camera drifts.
    static func nearest(_ blocks: [SpatialBlock], to focus: SpatialVector, budget: Int,
                        keeping previous: Set<String> = [], margin: Double = 1.5) -> [SpatialBlock] {
        guard blocks.count > budget else { return blocks }
        let scored = blocks.map { block -> (block: SpatialBlock, score: Double) in
            let d = hypot(Double(block.x) + 0.5 - focus.x, Double(block.y) + 0.5 - focus.y)
            return (block, previous.contains(block.id) ? d - margin : d)
        }
        return scored.sorted { a, b in a.score == b.score ? a.block.id < b.block.id : a.score < b.score }
            .prefix(budget).map(\.block)
    }

    /// Faces drawn with native glass per quality level (0: off, SceneKit glass only).
    static func budget(_ quality: RPGGlassQuality) -> Int {
        switch quality { case .high: 360; case .standard: 220; case .performance: 0 }
    }
}

/// Native glass is a separate layer from the 3D scene, so while the camera
/// moves the two can be a frame apart and the glass looks shaky. The glass
/// fades out while the camera moves and back in once it has settled; the 3D
/// glass blocks underneath carry the look meanwhile.
struct NativeGlassFade: Equatable, Sendable {
    /// 0 hidden … 1 fully shown.
    private(set) var visibility = 1.0
    private(set) var still = 0.0
    private var last: SpatialCameraState?

    static let settle = 0.2, fadeOut = 0.1, fadeIn = 0.25

    static func moved(_ a: SpatialCameraState, _ b: SpatialCameraState) -> Bool {
        let yaw = abs((a.yaw - b.yaw).remainder(dividingBy: 360))
        let t = a.target - b.target
        return yaw > 0.02 || abs(a.tilt - b.tilt) > 0.02 || abs(a.distance - b.distance) > 0.002
            || (t.x * t.x + t.y * t.y + t.z * t.z) > 0.000004
    }

    /// v1.78: hide at once and settle again (view size changed, world
    /// resumed): the glass must not show an old projection.
    mutating func restart() {
        visibility = 0; still = 0; last = nil
    }

    /// Advances one frame and returns the new visibility.
    mutating func step(camera: SpatialCameraState, dt: Double, shaking: Bool = false) -> Double {
        guard dt.isFinite, dt > 0 else { return visibility }
        let moving = shaking || last.map { Self.moved($0, camera) } ?? false
        last = camera
        still = moving ? 0 : still + dt
        if still >= Self.settle { visibility = min(1, visibility + dt / Self.fadeIn) }
        else if moving { visibility = max(0, visibility - dt / Self.fadeOut) }
        return visibility
    }
}

/// v1.78: how often the native glass shape is re-published, per second of
/// frames — the number to compare between v1.77 and v1.78 and between the
/// block-glass on / off settings on a real phone.
struct GlassPerfMeter: Equatable, Sendable {
    private(set) var frames = 0
    private(set) var seconds = 0.0
    private(set) var publishes = 0
    /// Last finished window.
    private(set) var publishesPerSecond = 0.0
    private(set) var framesPerSecond = 0.0
    static let window = 1.0

    /// Adds one frame; `publishes` is the running total of shape updates.
    mutating func frame(dt: Double, publishes total: Int) {
        guard dt.isFinite, dt > 0 else { return }
        if frames == 0 && seconds == 0 { publishes = total }
        frames += 1; seconds += dt
        if seconds >= Self.window {
            publishesPerSecond = Double(total - publishes) / seconds
            framesPerSecond = Double(frames) / seconds
            frames = 0; seconds = 0; publishes = total
        }
    }
}
