import SwiftUI

/// Every visible cell as one compound shape (glass lab option B).
struct RPGGridShape: Shape {
    let cells: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for cell in cells {
            path.addRoundedRect(in: cell.insetBy(dx: 1.5, dy: 1.5), cornerSize: CGSize(width: 5, height: 5), style: .continuous)
        }
        return path
    }
}

/// Native glass over many cells, for measuring what a phone can sustain.
/// Laid over the SpriteKit world, never takes touches, and only redraws
/// when the camera settles (the session swaps in the texture while it moves).
struct RPGGridGlassOverlay: View {
    @ObservedObject var session: RPGSession

    var body: some View {
        if let grid = session.glassGrid, session.glassRender != .selectedOnly, session.glassRender != .texture {
            if #available(iOS 26.0, *) {
                RPGNativeGridGlass(render: session.glassRender,
                                   cells: RPGGlassPolicy.gridCells(bounds: grid.bounds, corner: grid.corner, cell: grid.cell),
                                   player: grid.player)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct RPGNativeGridGlass: View {
    let render: RPGGlassRender
    let cells: [CGRect]
    let player: CGPoint

    var body: some View {
        Group {
            switch render {
            case .nativeMerged:
                // B: a single glass layer, so one backdrop pass for the grid.
                Color.clear.glassEffect(.clear, in: RPGGridShape(cells: cells))
                    .accessibilityElement().accessibilityIdentifier("rpg-grid-glass").accessibilityValue("merged:\(cells.count)")
            case .nativeNearest(let count):
                // C: one glass view per cell; each is its own backdrop pass.
                let nearest = RPGGlassPolicy.nearest(cells, to: player, count: count)
                ZStack {
                    ForEach(Array(nearest.enumerated()), id: \.offset) { _, cell in
                        Color.clear.frame(width: cell.width - 3, height: cell.height - 3)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .position(x: cell.midX, y: cell.midY)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .ignore).accessibilityIdentifier("rpg-grid-glass").accessibilityValue("nearest:\(nearest.count)")
            default:
                EmptyView()
            }
        }
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}
