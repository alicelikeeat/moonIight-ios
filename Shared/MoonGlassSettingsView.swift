import SwiftUI
import UIKit

// v1.82: the user's glass look — clarity and colour — read by every glass
// surface (pages, buttons, lists, the 3D world's controls and panels).

/// Reads the saved glass look; views update when it changes.
struct MoonGlassLookSetting: DynamicProperty {
    @AppStorage(MoonGlassTuning.clarityKey) var clarity = MoonGlassTuning.defaultClarity
    @AppStorage(MoonGlassTuning.tintKey) var tintHex = ""
    @AppStorage(MoonGlassTuning.strengthKey) var strength = MoonGlassTuning.defaultStrength
    var tuning: MoonGlassTuning { MoonGlassTuning(clarity: clarity, tintHex: tintHex, strength: strength) }
}

extension MoonGlassTuning {
    var tintColor: Color? { hasTint ? Color(uiColor: UIColor(rpgHex: tintHex)) : nil }
    var material: Material {
        switch thickness {
        case .ultraThin: .ultraThinMaterial
        case .thin: .thinMaterial
        case .regular: .regularMaterial
        case .thick: .thickMaterial
        }
    }
    /// System glass for this look. `override` (a prominent button's own
    /// colour) wins over the user's colour.
    @available(iOS 26.0, *)
    func glass(interactive: Bool, override: Color? = nil, allowClear: Bool = true) -> Glass {
        var g: Glass = usesClearGlass && allowClear ? .clear : .regular
        if let override { g = g.tint(override.opacity(0.85)) } else if let t = tintColor { g = g.tint(t.opacity(tintOpacity)) }
        return interactive ? g.interactive() : g
    }
}

/// Frost and colour laid over a glass surface. On iOS 26 the colour is in
/// the system glass itself, so only the frost is drawn here.
struct MoonGlassWash<S: Shape>: View {
    let shape: S
    let tuning: MoonGlassTuning
    var includeTint = true
    var body: some View {
        ZStack {
            // Fills the offered space even when there is nothing to draw.
            Color.clear
            if tuning.veil > 0 { shape.fill(Color(uiColor: .systemBackground).opacity(tuning.veil)) }
            if includeTint, let tint = tuning.tintColor { shape.fill(tint.opacity(tuning.tintOpacity)) }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Settings → Glass Look.
struct MoonGlassSettingsView: View {
    @AppStorage(MoonGlassTuning.clarityKey) private var clarity = MoonGlassTuning.defaultClarity
    @AppStorage(MoonGlassTuning.tintKey) private var tintHex = ""
    @AppStorage(MoonGlassTuning.strengthKey) private var strength = MoonGlassTuning.defaultStrength
    @Namespace private var selection

    static let presets: [(zh: String, en: String, hex: String)] = [
        ("无色", "None", ""), ("月光金", "Moon Gold", "C9B26B"), ("冰蓝", "Ice Blue", "7FD3FF"), ("薰衣草", "Lavender", "B39DFF"),
        ("樱粉", "Blossom", "FF9EC4"), ("薄荷", "Mint", "7FE3C0"), ("暮橙", "Dusk", "FFAA66"), ("墨黑", "Ink", "2B2B33"),
    ]

    private var tuning: MoonGlassTuning { MoonGlassTuning(clarity: clarity, tintHex: tintHex, strength: strength) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                clarityCard
                colourCard
                Button {
                    withAnimation(MoonLiquidMotion.morph) {
                        clarity = MoonGlassTuning.defaultClarity; tintHex = ""; strength = MoonGlassTuning.defaultStrength
                    }
                } label: { Label(L10n.t("恢复默认", "Reset"), systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.moonLiquid).disabled(tuning.isDefault)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("glass-look-reset")
                Text(L10n.t("影响页面、按键、列表，以及 3D 世界里的操作按钮和面板。3D 方块本身的玻璃颜色在方块面板里单独设置。",
                            "Applies to pages, buttons, lists and the 3D world's controls and panels. The glass of 3D blocks is set in the block panel."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .moonLiquidPage()
        .navigationTitle(L10n.t("玻璃外观", "Glass Look"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("glass-look-screen")
    }

    // MARK: Preview

    /// Real glass over a busy picture, so every change shows at once.
    private var preview: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    Rectangle().fill(i.isMultiple(of: 2) ? Color.white.opacity(0.35) : Color.black.opacity(0.15))
                }
            }
            .rotationEffect(.degrees(-20)).scaleEffect(1.6)
            Image(systemName: "moon.stars.fill").font(.system(size: 80)).foregroundStyle(.white.opacity(0.85)).offset(x: 90, y: -30)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MoonLiquidIcon(symbol: "sparkles", color: MoonStyle.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("玻璃卡片", "Glass Card")).font(.headline)
                        Text(L10n.t("文字始终清晰可读", "Text stays readable")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button(L10n.t("按一下", "Press")) {}.buttonStyle(.moonLiquid)
                    Button(L10n.t("确定", "OK")) {}.buttonStyle(.moonLiquidProminent)
                    Button {} label: { Image(systemName: "heart.fill") }.buttonStyle(.moonLiquid(tint: nil, outline: .circle))
                }
            }
            .padding(14)
            .moonGlassCard(radius: 22)
            .padding(18)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("glass-look-preview")
    }

    // MARK: Clarity

    private var clarityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.t("透明度", "Clarity"), systemImage: "drop.halffull").font(.subheadline.weight(.semibold))
                Spacer()
                Text(clarityTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Slider(value: $clarity, in: 0...1) {
                Text(L10n.t("透明度", "Clarity"))
            } minimumValueLabel: {
                Image(systemName: "circle.dotted").accessibilityLabel(L10n.t("磨砂", "Frosted"))
            } maximumValueLabel: {
                Image(systemName: "circle").accessibilityLabel(L10n.t("通透", "Clear"))
            }
            .accessibilityIdentifier("glass-look-clarity")
        }
        .padding(14).moonGlassCard(radius: 20)
    }

    private var clarityTitle: String {
        switch tuning.thickness {
        case .thick: L10n.t("磨砂", "Frosted")
        case .regular: L10n.t("标准", "Standard")
        case .thin: L10n.t("轻薄", "Light")
        case .ultraThin: L10n.t("通透", "Clear")
        }
    }

    // MARK: Colour

    private var colourCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("颜色", "Colour"), systemImage: "paintpalette").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(Self.presets, id: \.hex) { preset in swatch(preset) }
            }
            ColorPicker(L10n.t("自定义颜色", "Custom Colour"), selection: customColour, supportsOpacity: false)
                .font(.subheadline)
                .accessibilityIdentifier("glass-look-custom")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("颜色浓度", "Colour Strength")).font(.caption).foregroundStyle(.secondary)
                Slider(value: $strength, in: 0...1).disabled(tintHex.isEmpty)
                    .accessibilityIdentifier("glass-look-strength")
            }
        }
        .padding(14).moonGlassCard(radius: 20)
    }

    private func swatch(_ preset: (zh: String, en: String, hex: String)) -> some View {
        let chosen = tuning.tintHex == preset.hex
        return Button {
            withAnimation(MoonLiquidMotion.morph) { tintHex = preset.hex }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    if chosen {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).frame(width: 50, height: 50)
                            .matchedGeometryEffect(id: "swatch", in: selection)
                    }
                    if preset.hex.isEmpty {
                        Image(systemName: "circle.slash").font(.system(size: 18)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40).moonLiquidSurface(.circle)
                    } else {
                        Circle().fill(Color(uiColor: UIColor(rpgHex: preset.hex)).gradient).frame(width: 40, height: 40)
                            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.8))
                    }
                }
                .frame(width: 50, height: 50)
                Text(L10n.t(preset.zh, preset.en)).font(.caption2).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.moonJelly)
        .accessibilityLabel(L10n.t(preset.zh, preset.en))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("glass-look-tint-\(preset.hex.isEmpty ? "none" : preset.hex)")
    }

    private var customColour: Binding<Color> {
        Binding(get: { tuning.tintColor ?? Color(uiColor: UIColor(rpgHex: "C9B26B")) }, set: { colour in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(colour).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            let clamp = { (v: CGFloat) in Int((min(1, max(0, v)) * 255).rounded()) }
            tintHex = String(format: "%02X%02X%02X", clamp(r), clamp(g), clamp(b))
        })
    }
}
