import SwiftUI

// v1.82 Liquid Glass kit: the 3D world's glass language for every page.
// Buttons press like a drop of glass (squash, wobble back, a light sweep
// and a soft tap); cards and panels rise out of the page as glass. All
// motion runs only around a touch or an appearance — nothing animates
// while idle, so pages cost nothing extra when still. Reduce Motion keeps
// the glass but drops the squash, wobble and sweep; Reduce Transparency
// gives solid surfaces.

/// The outline a liquid surface takes.
enum MoonLiquidOutline: Equatable {
    case capsule, circle, rounded(CGFloat)
}

struct MoonLiquidShape: InsettableShape {
    var outline: MoonLiquidOutline = .capsule
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        switch outline {
        case .capsule: return Capsule(style: .continuous).path(in: r)
        case .circle: return Circle().path(in: r)
        case .rounded(let radius): return RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous).path(in: r)
        }
    }
    func inset(by amount: CGFloat) -> MoonLiquidShape { MoonLiquidShape(outline: outline, inset: inset + amount) }
}

/// Spring curves of the kit (one place to tune the feel).
enum MoonLiquidMotion {
    /// Finger down: quick and firm.
    static let press = Animation.spring(response: 0.18, dampingFraction: 0.62)
    /// Finger up: loose, overshoots once like a settling drop.
    static let release = Animation.spring(response: 0.46, dampingFraction: 0.44)
    /// Cards and panels rising into place.
    static let emerge = Animation.spring(response: 0.5, dampingFraction: 0.78)
    /// Selection moving between options.
    static let morph = Animation.spring(response: 0.38, dampingFraction: 0.7)
}

// MARK: Press

/// Squash, wobble, sweep and haptic for any pressable label. `glass` puts
/// interactive system glass behind the label (iOS 26), material before.
struct MoonLiquidPress: View {
    let configuration: ButtonStyleConfiguration
    var outline: MoonLiquidOutline = .capsule
    var tint: Color?
    var glass = true
    var hPadding: CGFloat = 12
    var vPadding: CGFloat = 8
    var minHeight: CGFloat? = 44
    var blind = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let pressed = configuration.isPressed
        let shape = MoonLiquidShape(outline: outline)
        configuration.label
            .padding(.horizontal, hPadding).padding(.vertical, vPadding)
            .frame(minHeight: minHeight)
            .modifier(MoonLiquidForeground(white: tint != nil))
            .contentShape(shape)
            .modifier(MoonLiquidSurface(shape: shape, tint: tint, glass: glass, pressed: pressed))
            .opacity(blind ? 0.01 : isEnabled ? 1 : 0.45)
            .modifier(MoonLiquidJellyEffect(pressed: pressed, outline: outline))
    }
}

private struct MoonLiquidForeground: ViewModifier {
    let white: Bool
    func body(content: Content) -> some View {
        if white { content.foregroundStyle(Color.white) } else { content }
    }
}

/// The liquid response itself: squash on press, a loose wobble back, one
/// sweep of light after the release and a soft tap. Apply to any view
/// whose pressed state is known.
struct MoonLiquidJellyEffect: ViewModifier {
    let pressed: Bool
    var outline: MoonLiquidOutline = .capsule
    var amount: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: CGFloat = -1.4
    /// The sweep layer exists only while it runs (idle buttons cost nothing).
    @State private var sweeping = false
    @State private var releases = 0
    func body(content: Content) -> some View {
        let squash = pressed && !reduceMotion
        content
            .overlay { if sweeping { MoonLiquidSweep(phase: sweep).clipShape(MoonLiquidShape(outline: outline)).allowsHitTesting(false) } }
            .scaleEffect(x: squash ? 1 + 0.07 * amount : 1, y: squash ? 1 - 0.09 * amount : 1)
            .brightness(pressed ? 0.07 : 0)
            .animation(pressed ? MoonLiquidMotion.press : MoonLiquidMotion.release, value: pressed)
            .onChange(of: pressed) { down in
                if !down && !reduceMotion { releases += 1 }
            }
            .task(id: releases) {
                guard releases > 0 else { return }
                sweep = -1.4; sweeping = true
                // Next turn: the layer is on screen, so the move animates.
                await Task.yield()
                withAnimation(.easeOut(duration: 0.6)) { sweep = 1.4 }
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                sweeping = false
            }
            .modifier(MoonLiquidHaptic(trigger: pressed))
    }
}

/// A diagonal band of light that crosses the glass once after a release.
struct MoonLiquidSweep: View {
    let phase: CGFloat
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.42), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(24, g.size.width * 0.45))
                .rotationEffect(.degrees(18))
                .offset(x: phase * g.size.width)
                .frame(width: g.size.width, height: g.size.height)
                .opacity(abs(phase) < 1.35 ? 1 : 0)
        }
        .blendMode(.plusLighter)
        .accessibilityHidden(true)
    }
}

/// Soft tap on finger down (iOS 17+).
struct MoonLiquidHaptic: ViewModifier {
    let trigger: Bool
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: trigger) { _, new in new }
        } else {
            content
        }
    }
}

/// The glass under a control, with a rim of light that brightens on press.
struct MoonLiquidSurface: ViewModifier {
    let shape: MoonLiquidShape
    var tint: Color?
    var glass = true
    var pressed = false
    /// Touch-reactive system glass (only for surfaces that receive touches).
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        Group {
            if !glass {
                content.background { if let tint { shape.fill(tint.gradient) } }
            } else if reduceTransparency {
                content.background { shape.fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color(uiColor: .secondarySystemBackground))) }
            } else if #available(iOS 26.0, *) {
                content.glassEffect(Self.systemGlass(tint: tint, interactive: interactive), in: shape)
            } else {
                content.background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint.opacity(0.78)) }
                    }
                }
            }
        }
        .overlay {
            if glass || tint != nil {
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(pressed ? 0.75 : 0.42), .white.opacity(0.04), .white.opacity(pressed ? 0.35 : 0.14)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: contrast == .increased ? 1.5 : 0.8)
            .allowsHitTesting(false)
            }
        }
    }
}

extension MoonLiquidSurface {
    @available(iOS 26.0, *)
    static func systemGlass(tint: Color?, interactive: Bool) -> Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint.opacity(0.85)) }
        return interactive ? g.interactive() : g
    }
}

// MARK: Button styles

/// Liquid glass button. `tint` makes it a prominent (coloured) glass button.
struct MoonLiquidButtonStyle: ButtonStyle {
    var outline: MoonLiquidOutline = .capsule
    var tint: Color?
    var padded = true
    func makeBody(configuration: Configuration) -> some View {
        MoonLiquidPress(configuration: configuration, outline: outline, tint: tint, hPadding: padded ? 13 : 0, vPadding: padded ? 7 : 0, minHeight: padded ? 36 : nil)
    }
}

/// Squash, wobble, sweep and haptic only: for labels that already sit on
/// their own glass (HUD buttons, chips inside glass panels).
struct MoonLiquidJellyStyle: ButtonStyle {
    var outline: MoonLiquidOutline = .capsule
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(MoonLiquidJellyEffect(pressed: configuration.isPressed, outline: outline))
    }
}

extension ButtonStyle where Self == MoonLiquidButtonStyle {
    static var moonLiquid: MoonLiquidButtonStyle { MoonLiquidButtonStyle() }
    static func moonLiquid(tint: Color?, outline: MoonLiquidOutline = .capsule) -> MoonLiquidButtonStyle { MoonLiquidButtonStyle(outline: outline, tint: tint) }
    static var moonLiquidProminent: MoonLiquidButtonStyle { MoonLiquidButtonStyle(tint: .accentColor) }
}

extension ButtonStyle where Self == MoonLiquidJellyStyle {
    static var moonJelly: MoonLiquidJellyStyle { MoonLiquidJellyStyle() }
}

// MARK: Cards and pages

/// A glass card that rises into place when it first appears.
struct MoonLiquidCard: ViewModifier {
    var radius: CGFloat = 22
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { MoonGlassBackdrop(radius: radius) }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.03), .white.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
            .environment(\.moonGlassContainer, true)
            .moonEmerge()
    }
}

/// First appearance: rises, sharpens and fades in like glass condensing.
struct MoonLiquidEmerge: ViewModifier {
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .blur(radius: shown || reduceMotion ? 0 : 6)
            .onAppear {
                guard !shown else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : MoonLiquidMotion.emerge.delay(delay)) { shown = true }
            }
    }
}

/// Round glass icon tile (the 3D panel header look).
struct MoonLiquidIcon: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 34
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            }
            .shadow(color: color.opacity(0.35), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

/// Page backdrop: soft pools of colour for the glass to bend. Static
/// gradients only (no blur, no animation): drawn once, free while scrolling.
struct MoonLiquidBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, dark = scheme == .dark
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                RadialGradient(colors: [Color.indigo.opacity(dark ? 0.45 : 0.22), .clear], center: UnitPoint(x: 0.1, y: 0.08), startRadius: 0, endRadius: max(w, h) * 0.6)
                RadialGradient(colors: [MoonStyle.accent.opacity(dark ? 0.4 : 0.24), .clear], center: UnitPoint(x: 0.95, y: 0.4), startRadius: 0, endRadius: max(w, h) * 0.55)
                RadialGradient(colors: [Color.cyan.opacity(dark ? 0.28 : 0.16), .clear], center: UnitPoint(x: 0.3, y: 0.95), startRadius: 0, endRadius: max(w, h) * 0.5)
            }
            .drawingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    /// Glass card that rises into place on first appearance.
    func moonCard(radius: CGFloat = 22, padding: CGFloat = 14) -> some View { modifier(MoonLiquidCard(radius: radius, padding: padding)) }
    /// One-off appearance animation (rise, sharpen, fade in).
    func moonEmerge(delay: Double = 0) -> some View { modifier(MoonLiquidEmerge(delay: delay)) }
    /// Page backdrop behind a sheet or page.
    func moonLiquidPage() -> some View { background { MoonLiquidBackdrop() } }
    /// Glass under any view (non-interactive look, e.g. a status pill).
    func moonLiquidSurface(_ outline: MoonLiquidOutline = .capsule, tint: Color? = nil) -> some View {
        modifier(MoonLiquidSurface(shape: MoonLiquidShape(outline: outline), tint: tint, interactive: false))
    }
    /// Glass behind a card that keeps its own padding (replaces solid or
    /// material card backgrounds).
    func moonGlassCard(radius: CGFloat = 18, tint: Color? = nil) -> some View {
        background {
            ZStack {
                MoonGlassBackdrop(radius: radius)
                if let tint { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.09)).allowsHitTesting(false) }
            }
        }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.36), .white.opacity(0.03), .white.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
    }
    /// Lists and forms on the liquid page: the system background is hidden
    /// so the colour pools show through the glass rows.
    func moonLiquidList() -> some View {
        scrollContentBackground(.hidden).background { MoonLiquidBackdrop() }
    }
}

/// Row background for lists and forms: frosted glass with a top highlight.
struct MoonLiquidRowBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack(alignment: .top) {
            if reduceTransparency { Color(uiColor: .secondarySystemGroupedBackground) }
            else { Rectangle().fill(.ultraThinMaterial) }
            LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
        }
        .accessibilityHidden(true)
    }
}
