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
            inCombat: state.inCombat, editing: state.editing, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
        let tuning = look.tuning
        // A light scrim behind text: dark under light text, light under dark
        // text; v1.82: thicker when the user chose frosted glass.
        let scrim = (scheme == .dark ? Color.black : Color.white).opacity(min(0.5, style.scrim + tuning.veil))
        if style.solid {
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

/// 360° analog stick. The world is a grid, so the session turns the vector
/// into steps in the nearest of 8 directions (RPGStickRules). Lifting the
/// finger or a cancelled touch returns it to the centre.
struct RPGJoystick: View {
    let session: RPGSession
    var size: CGFloat = 128
    @State private var knob: CGSize = .zero
    @GestureState private var touching = false

    var body: some View {
        let reach = size / 2 - 24
        // v1.78: one glass system per stick — a non-touch base and an
        // interactive knob in the same container (no stacked glass layers).
        RPGGlassGroup(spacing: 0) {
            ZStack {
                Color.clear.frame(width: size, height: size).hudGlass(.base, in: Circle())
                ForEach(0..<8, id: \.self) { index in
                    Capsule().fill(Color.primary.opacity(0.25)).frame(width: 2, height: 7)
                        .offset(y: -(size / 2 - 9)).rotationEffect(.degrees(Double(index) * 45))
                }
                Color.clear.frame(width: 50, height: 50).hudGlass(.interactive, in: Circle())
                    .overlay(Circle().fill(Color.white.opacity(touching ? 0.28 : 0.12)))
                    .offset(knob)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    let vector = RPGStickRules.vector(dx: value.location.x - size / 2, dy: value.location.y - size / 2, radius: reach)
                    if knob == .zero { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    knob = CGSize(width: vector.x * reach, height: vector.y * reach)
                    session.setStick(vector.x, vector.y)
                }
        )
        // GestureState resets on end and on cancel, so the stick always re-centres.
        .onChange(of: touching) { active in if !active { reset() } }
        .onDisappear { reset() }
        .disabled(!session.ready || session.working)
        .accessibilityElement()
        .accessibilityLabel(L10n.t("移动摇杆", "Movement Stick"))
        .accessibilityHint(L10n.t("用上下左右动作移动一格", "Use the actions to move one cell"))
        .accessibilityIdentifier("rpg-joystick")
        .accessibilityAction(named: L10n.t("向上", "Up")) { session.move(dx: 0, dz: 1) }
        .accessibilityAction(named: L10n.t("向下", "Down")) { session.move(dx: 0, dz: -1) }
        .accessibilityAction(named: L10n.t("向左", "Left")) { session.move(dx: -1, dz: 0) }
        .accessibilityAction(named: L10n.t("向右", "Right")) { session.move(dx: 1, dz: 0) }
    }

    private func reset() {
        knob = .zero
        session.setStick(0, 0)
    }
}

/// Attack, skill and roll as glass buttons with cooldown rings. Combat
/// rules and numbers are unchanged; disabled while the action cools down.
struct RPGCombatPad: View {
    @ObservedObject var session: RPGSession
    @ObservedObject var hud: RPGCombatHUDModel

    var body: some View {
        RPGGlassGroup(spacing: 10) {
            if hud.dead {
                Button { session.revive() } label: { label("heart.fill", L10n.t("安全复苏", "Revive"), size: 72) }
                    .buttonStyle(.moonJelly).hudGlass(.interactive, in: Circle()).accessibilityIdentifier("rpg-revive")
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(spacing: 10) {
                        action(.skill, symbol: "sparkles", title: L10n.t("范围技能", "Area Skill"), size: 52, cooldown: hud.cooldowns[1], id: "rpg-skill")
                        action(.roll, symbol: session.world.player.perspective == .side ? "hare.fill" : "arrow.triangle.2.circlepath", title: session.world.player.perspective == .side ? L10n.t("冲刺", "Dash") : L10n.t("翻滚", "Roll"), size: 48, cooldown: hud.cooldowns[2], id: "rpg-roll")
                    }
                    action(.attack, symbol: "bolt.fill", title: L10n.t("攻击", "Attack"), size: 72, cooldown: hud.cooldowns[0], id: "rpg-attack")
                }
            }
        }
        .disabled(!session.ready || session.working)
    }

    private func action(_ kind: RPGCombatAction, symbol: String, title: String, size: CGFloat, cooldown: Double, id: String) -> some View {
        Button { session.combatAction(kind) } label: { label(symbol, title, size: size) }
            .buttonStyle(RPGPressStyle())
            .hudGlass(.interactive, in: Circle())
            .overlay(
                Circle().trim(from: 0, to: cooldown).stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(2).allowsHitTesting(false)
            )
            .opacity(cooldown > 0 ? 0.7 : 1)
            .accessibilityLabel(title)
            .accessibilityValue(cooldown > 0 ? L10n.t("冷却中", "Cooling down") : L10n.t("就绪", "Ready"))
            .accessibilityIdentifier(id)
    }

    private func label(_ symbol: String, _ title: String, size: CGFloat) -> some View {
        VStack(spacing: 1) {
            Image(systemName: symbol).font(.system(size: size * 0.32, weight: .bold))
            if size >= 60 { Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1) }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

/// Press feedback for glass controls. v1.82: liquid — squash, wobble
/// back, a sweep of light and a soft tap (the glass itself is the HUD's).
struct RPGPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(MoonLiquidJellyEffect(pressed: configuration.isPressed, amount: 1.2))
    }
}

/// Health and stamina bars on light glass.
struct RPGVitalsBar: View {
    @ObservedObject var hud: RPGCombatHUDModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            bar(value: hud.health, tint: .red, symbol: "heart.fill")
            bar(value: hud.stamina, tint: .green, symbol: "bolt.fill")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .hudGlass(.light, radius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("生命 \(hud.health)，耐力 \(hud.stamina)", "Health \(hud.health), stamina \(hud.stamina)"))
        .accessibilityIdentifier("rpg-vitals")
    }
    private func bar(value: Int, tint: Color, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                Capsule().fill(tint.opacity(0.85)).frame(width: 96 * CGFloat(max(0, min(100, value))) / 100)
            }.frame(width: 96, height: 5)
            Text("\(value)").font(.system(size: 9, weight: .semibold).monospacedDigit()).frame(width: 22, alignment: .trailing)
        }
    }
}
