import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum MoonStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let accent = Color(red: 0.48, green: 0.45, blue: 0.30)
    static let muted = Color.secondary
    static let cardRadius: CGFloat = 24
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// One root-level interaction style keeps button feedback consistent without
/// adding another material layer. In full blind mode only the rendered label
/// disappears; layout and hit testing stay intact.
/// v1.82: every button is liquid glass — it squashes under the finger,
/// wobbles back, a light sweeps across and the phone taps softly. Inside a
/// glass container the button gets the motion without a second glass.
struct MoonInteractiveButtonStyle: ButtonStyle {
    let blind: Bool
    @Environment(\.moonGlassContainer) private var inGlass
    func makeBody(configuration: Configuration) -> some View {
        MoonLiquidPress(configuration: configuration, outline: .rounded(22), glass: !inGlass,
                        hPadding: inGlass ? 0 : 8, vPadding: 0, minHeight: 44, blind: blind)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    init(title: String, subtitle: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MoonLiquidIcon(symbol: symbol, color: MoonStyle.accent, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold()).tracking(-0.5).accessibilityIdentifier("page-title-\(title)")
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
        .moonEmerge()
    }
}

struct EmptyPanel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(MoonStyle.accent)
                .frame(width: 66, height: 66).moonLiquidSurface(.circle)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 4)
        .moonCard(radius: 24)
    }
}

struct StatCard: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 5) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 14)
            .background { MoonGlassBackdrop(radius: 18) }
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8).allowsHitTesting(false) }
            .moonEmerge()
    }
}

struct MenuRow: View {
    let symbol: String
    let title: String
    let color: Color
    var body: some View {
        HStack(spacing: 12) {
            MoonLiquidIcon(symbol: symbol, color: color, size: 34)
            Text(title).font(.body.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 13).padding(.horizontal, 8)
            .contentShape(Rectangle())
    }
}






@MainActor
@ViewBuilder
func glassTabContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: 10) { content() }
    } else {
        content()
    }
}

extension View {
    @ViewBuilder
    func moonGlassCircle(_ target: BackgroundTarget = .allButtons) -> some View {
        modifier(MediaGlassCircle(target: target))
    }
}
