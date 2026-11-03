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
    static func nearest(_ blocks: [SpatialBlock], to focus: SpatialVector, budget: Int) -> [SpatialBlock] {
        guard blocks.count > budget else { return blocks }
        return Array(blocks.sorted { a, b in
            let da = hypot(Double(a.x) + 0.5 - focus.x, Double(a.y) + 0.5 - focus.y), db = hypot(Double(b.x) + 0.5 - focus.x, Double(b.y) + 0.5 - focus.y)
            return da == db ? a.id < b.id : da < db
        }.prefix(budget))
    }

    /// Faces drawn with native glass per quality level (0: off, SceneKit glass only).
    static func budget(_ quality: RPGGlassQuality) -> Int {
        switch quality { case .high: 360; case .standard: 220; case .performance: 0 }
    }
}
