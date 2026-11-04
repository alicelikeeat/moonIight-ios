import SwiftUI

/// Native iOS glass on world blocks (iOS 26+). Every visible face of the
/// nearest blocks is projected to the screen with the same camera maths as
/// RealityKit, joined into one path and drawn as one system glass layer:
/// one glass pass for all blocks. Characters closer to the camera than a
/// block are cut out of its glass, so the glass never covers someone
/// standing in front of it. Media faces stay out of the glass to stay sharp.
@available(iOS 18.0, *)
@MainActor final class Glass3DNativeGlass: ObservableObject {
    @Published private(set) var shape = Path()
    @Published private(set) var faces = 0
    /// Fades the glass out while the camera moves (see `NativeGlassFade`).
    @Published private(set) var opacity = 1.0
    func setOpacity(_ value: Double) {
        let v = min(1, max(0, value))
        if abs(v - opacity) > 0.02 || (v != opacity && (v == 0 || v == 1)) { opacity = v }
    }
    /// Blocks drawn last time (kept steady at the budget edge).
    private var chosenIDs: Set<String> = []
    /// Lock-on reticle over the locked target (screen point).
    @Published var reticle: CGPoint?
    /// Move handles for the selection: centre and the screen direction and
    /// length of one step along x, map-y and height.
    @Published var gizmo: Gizmo?
    struct Gizmo: Equatable { var center: CGPoint; var axes: [CGPoint] }

    struct Character { let position: SpatialVector; let radius: Double; let height: Double }

    func update(projection: SpatialProjection, blocks: [SpatialBlock], frames: [String: GroupFrame], characters: [Character], budget: Int) {
        guard budget > 0, projection.viewSize.width > 0 else {
            if faces != 0 { shape = Path(); faces = 0 }
            chosenIDs = []
            return
        }
        let eye = projection.eye
        // Moving platforms stay in the 3D scene only: the separate glass
        // layer would trail them by a frame.
        let still = blocks.filter { $0.collision != .trigger && $0.groupID.map { frames[$0] == nil } ?? true }
        let chosen = SpatialFaces.nearest(still, to: projection.target, budget: budget, keeping: chosenIDs)
        chosenIDs = Set(chosen.map(\.id))
        // Screen rectangles of characters, with their distance from the camera.
        let cutouts: [(rect: CGRect, depth: Double)] = characters.compactMap { character in
            guard let foot = projection.project(character.position),
                  let head = projection.project(character.position + SpatialVector(0, 0, character.height)),
                  let side = projection.project(character.position + SpatialVector(character.radius, 0, character.height / 2)) else { return nil }
            let mid = projection.project(character.position + SpatialVector(0, 0, character.height / 2))?.point ?? foot.point
            let halfWidth = max(6, abs(side.point.x - mid.x) * 1.3)
            let top = min(foot.point.y, head.point.y), bottom = max(foot.point.y, head.point.y)
            return (CGRect(x: mid.x - halfWidth, y: top - 4, width: halfWidth * 2, height: bottom - top + 8), foot.depth)
        }
        var path = Path(), count = 0
        for block in chosen {
            let corners = SpatialFaces.corners(block, frame: block.groupID.flatMap { frames[$0] })
            let center = corners.reduce(SpatialVector.zero, +) * (1.0 / 8)
            guard let blockDepth = projection.project(center)?.depth else { continue }
            let mediaFace: Int? = block.media.map { media in switch media.face { case .top: 0; case .front: 2; case .side: 3 } }
            for face in SpatialFaces.visibleFaces(corners, eye: eye) where face.index != mediaFace {
                let projected = face.points.compactMap { projection.project($0) }
                guard projected.count == 4 else { continue }
                let points = projected.map(\.point)
                var facePath = Path()
                facePath.addLines(SpatialFaces.oriented(points)); facePath.closeSubpath()
                let bounds = facePath.boundingRect
                guard SpatialFaces.drawable(depths: projected.map(\.depth), bounds: bounds, viewSize: projection.viewSize),
                      bounds.intersects(CGRect(origin: .zero, size: projection.viewSize)) else { continue }
                for cut in cutouts where cut.depth < blockDepth - 0.3 && cut.rect.intersects(bounds) {
                    facePath = facePath.subtracting(Path(roundedRect: cut.rect, cornerRadius: min(cut.rect.width, cut.rect.height) / 3))
                }
                path.addPath(facePath); count += 1
            }
        }
        shape = path
        if faces != count { faces = count }
    }
}

/// The glass layer itself: one system glass shape, never takes touches.
@available(iOS 18.0, *)
struct Glass3DNativeGlassLayer: View {
    @ObservedObject var glass: Glass3DNativeGlass
    var body: some View {
        if #available(iOS 26.0, *) {
            if glass.opacity > 0 {
                Color.clear
                    .glassEffect(.clear, in: PathShape(path: glass.shape))
                    .opacity(glass.opacity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct PathShape: Shape {
    let path: Path
    func path(in rect: CGRect) -> Path { path }
}
