import SwiftUI

private struct GlassContainerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var moonGlassContainer: Bool {
        get { self[GlassContainerKey.self] }
        set { self[GlassContainerKey.self] = newValue }
    }
}

/// One native material per surface. Decorations never receive touches.
struct MoonGlassBackdrop: View {
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: radius).fill(Color(uiColor: .secondarySystemBackground))
            } else if #available(iOS 26.0, *) {
                RoundedRectangle(cornerRadius: radius).fill(.clear)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius))
            } else {
                RoundedRectangle(cornerRadius: radius).fill(.regularMaterial)
            }
        }
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(0.4), lineWidth: 1)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
extension View {
    func moonSingleGlass(radius: CGFloat = 22) -> some View {
        background { MoonGlassBackdrop(radius: radius) }.environment(\.moonGlassContainer, true)
    }
}

/// Only the background deforms: TextField, marked text and caret stay still.
struct MoonSearchBubble: ViewModifier {
    let focused: Bool
    let submission: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var scale: CGFloat = 1
    @State private var highlight = false
    @State private var lastSubmission = 0
    func body(content: Content) -> some View {
        content
            .background {
                MoonGlassBackdrop(radius: 40)
                    .overlay {
                        if contrast != .increased {
                            Capsule().strokeBorder(.white.opacity(highlight ? 0.45 : 0.08), lineWidth: 1)
                        }
                    }
                    .scaleEffect(scale).allowsHitTesting(false).accessibilityHidden(true)
            }
            .environment(\.moonGlassContainer, true)
            .task(id: "\(focused)-\(submission)-\(reduceMotion)") {
                let pulse = focused || submission != lastSubmission
                lastSubmission = submission
                guard pulse else { scale = 1; highlight = false; return }
                guard !reduceMotion else {
                    scale = 1
                    withAnimation(.easeOut(duration: 0.2)) { highlight = focused }
                    return
                }
                withAnimation(.easeOut(duration: 0.1)) { scale = 1.025; highlight = true }
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { scale = 1; highlight = focused }
            }
    }
}
