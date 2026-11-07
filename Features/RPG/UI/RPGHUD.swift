import SwiftUI
import UIKit

// V2.2 HUD: one glass language for every control over the world. iOS 26+
// uses system Liquid Glass; iOS 16–25 uses system materials. The look
// adapts to system settings and game state (RPGHUDGlassStyle), not to
// per-frame background sampling.

/// Game state the HUD glass reacts to, set once on the sandbox shell.
struct RPGHUDState: Equatable {
    var inCombat = false
    var editing = false
    /// v1.84: flat controls instead of live glass (3D power saver).
    var powerSave = false
}

private struct RPGHUDStateKey: EnvironmentKey { static let defaultValue = RPGHUDState() }
extension EnvironmentValues {
    var rpgHUDState: RPGHUDState {
        get { self[RPGHUDStateKey.self] }
        set { self[RPGHUDStateKey.self] = newValue }
    }
}

struct RPGHUDGlassModifier<S: Shape>: ViewModifier {
    let kind: RPGHUDGlassKind
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Environment(\.rpgHUDState) private var state
    /// v1.82: the user's clarity and colour.
    private let look = MoonGlassLookSetting()

    func body(content: Content) -> some View {
        // v1.78: a panel keeps taps on its empty areas (a tap between two
        // toolbar buttons must not select a block underneath); status
        // surfaces and bases keep their content's own hit area.
        if kind.absorbsTouches { surface(content).contentShape(shape) } else { surface(content) }
    }

    @ViewBuilder private func surface(_ content: Content) -> some View {
        let style = RPGHUDGlassStyle.resolve(kind, RPGHUDConditions(
            dark: scheme == .dark, increasedContrast: contrast == .increased, reduceTransparency: reduceTransparency,
            inCombat: state.inCombat, editing: state.editing, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, powerSave: state.powerSave))
        let tuning = look.tuning
        // A light scrim behind text: dark under light text, light under dark
        // text; v1.82: thicker when the user chose frosted glass.
        let scrim = (scheme == .dark ? Color.black : Color.white).opacity(min(0.5, style.scrim + tuning.veil))
        if style.flat {
            // No backdrop sampling at all: a plain see-through fill.
            content
                .background((scheme == .dark ? Color.black : Color.white).opacity(kind == .base ? 0.3 : 0.72), in: shape)
                .background(style.combatTint ? Color.red.opacity(0.12) : (tuning.tintColor ?? .clear).opacity(tuning.tintOpacity), in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.35), lineWidth: 0.6))
        } else if style.solid {
            content
                .background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            content
                .background(scrim, in: shape)
                .glassEffect(glass(style, tuning), in: shape)
        } else {
            content
                .background(scrim, in: shape)
                .background(style.combatTint || tuning.tintColor == nil ? AnyShapeStyle(Color.clear) : AnyShapeStyle(tuning.tintColor!.opacity(tuning.tintOpacity)), in: shape)
                .background(style.regular ? AnyShapeStyle(tuning.material) : AnyShapeStyle(.ultraThinMaterial), in: shape)
                .overlay(shape.stroke(Color.white.opacity(style.combatTint ? 0.5 : 0.28), lineWidth: 0.6))
                .overlay(style.combatTint ? shape.fill(Color.red.opacity(0.08)).allowsHitTesting(false) : nil)
        }
    }

    @available(iOS 26.0, *)
    private func glass(_ style: RPGHUDGlassStyle, _ tuning: MoonGlassTuning) -> Glass {
        var glass: Glass = style.regular && !tuning.usesClearGlass ? .regular : .clear
        if style.combatTint { glass = glass.tint(.red.opacity(0.18)) }
        else if let tint = tuning.tintColor { glass = glass.tint(tint.opacity(tuning.tintOpacity)) }
        if style.interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /// Adaptive HUD glass in a rounded rectangle.
    func hudGlass(_ kind: RPGHUDGlassKind, radius: CGFloat = 16) -> some View {
        modifier(RPGHUDGlassModifier(kind: kind, shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }
    /// Adaptive HUD glass in any shape.
    func hudGlass<S: Shape>(_ kind: RPGHUDGlassKind, in shape: S) -> some View {
        modifier(RPGHUDGlassModifier(kind: kind, shape: shape))
    }
}

/// Groups nearby glass so iOS 26 blends it as one surface; plain stack before.
struct RPGGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: spacing) { content() } } else { content() }
    }
}

/// Press feedback for glass controls. v1.82: liquid — squash, wobble
/// back, a sweep of light and a soft tap (the glass itself is the HUD's).
struct RPGPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(MoonLiquidJellyEffect(pressed: configuration.isPressed, amount: 1.2))
    }
}
