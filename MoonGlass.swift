import SwiftUI

private struct GlassContainerKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var moonGlassContainer: Bool {
        get { self[GlassContainerKey.self] }
        set { self[GlassContainerKey.self] = newValue }
    }
}

extension MoonGlassMotion {
    /// SwiftUI animation for a glass change (nil: change without animation).
    static func animation(_ kind: Kind, reduceMotion: Bool) -> Animation? {
        let c = curve(kind, reduceMotion: reduceMotion)
        if c.response <= 0 { return nil }
        return c.linear ? .easeInOut(duration: c.response) : .spring(response: c.response, dampingFraction: c.damping)
    }
}

/// One native material per surface. Decorations never receive touches, so
/// the glass is never interactive (v1.78: interactive glass on a surface
/// that cannot be touched only costs work).
struct MoonGlassBackdrop: View {
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    /// v1.82: the user's clarity and colour.
    private let look = MoonGlassLookSetting()
    var body: some View {
        let tuning = look.tuning
        Group {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: radius).fill(Color(uiColor: .secondarySystemBackground))
            } else if #available(iOS 26.0, *) {
                MoonGlassWash(shape: RoundedRectangle(cornerRadius: radius), tuning: tuning, includeTint: false)
                    .glassEffect(tuning.glass(interactive: false), in: RoundedRectangle(cornerRadius: radius))
            } else {
                RoundedRectangle(cornerRadius: radius).fill(tuning.material)
                    .overlay(MoonGlassWash(shape: RoundedRectangle(cornerRadius: radius), tuning: tuning))
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
                    withAnimation(MoonGlassMotion.animation(.fade, reduceMotion: true)) { highlight = focused }
                    return
                }
                let press = MoonGlassMotion.curve(.press, reduceMotion: false)
                withAnimation(MoonGlassMotion.animation(.press, reduceMotion: false)) { scale = 1.025; highlight = true }
                try? await Task.sleep(nanoseconds: UInt64(press.response * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(MoonGlassMotion.animation(.morph, reduceMotion: false)) { scale = 1; highlight = focused }
            }
    }
}
