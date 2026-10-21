import SwiftUI
import UIKit

struct MoonColors: Equatable {
    var dark: Bool
    var accent: Color
    var onAccent: Color
    var glassTint: Color
    var glassStroke: Color
    var text: Color
    var textDim: Color
    var danger: Color
    var bgTop: Color
    var bgBottom: Color
    var heart: Color

    static let dark = MoonColors(
        dark: true,
        accent: Color(red: 0.910, green: 0.890, blue: 0.788),
        onAccent: Color(red: 0.082, green: 0.086, blue: 0.102),
        glassTint: Color(red: 0.114, green: 0.125, blue: 0.161).opacity(0.55),
        glassStroke: Color.white.opacity(0.35),
        text: Color(red: 0.961, green: 0.957, blue: 0.937),
        textDim: Color.white.opacity(0.62),
        danger: Color(red: 1, green: 0.353, blue: 0.322),
        bgTop: Color(red: 0.051, green: 0.059, blue: 0.082),
        bgBottom: Color(red: 0.027, green: 0.031, blue: 0.043),
        heart: Color(red: 1, green: 0.302, blue: 0.427)
    )
    static let light = MoonColors(
        dark: false,
        accent: Color(red: 0.541, green: 0.510, blue: 0.373),
        onAccent: .white,
        glassTint: Color.white.opacity(0.72),
        glassStroke: Color.white.opacity(0.9),
        text: Color(red: 0.082, green: 0.086, blue: 0.102),
        textDim: Color.black.opacity(0.48),
        danger: Color(red: 0.898, green: 0.263, blue: 0.227),
        bgTop: Color(red: 0.969, green: 0.961, blue: 0.937),
        bgBottom: Color(red: 0.925, green: 0.914, blue: 0.878),
        heart: Color(red: 0.92, green: 0.27, blue: 0.40)
    )
    static let media = MoonColors.dark
}

private struct MoonColorsKey: EnvironmentKey {
    static let defaultValue = MoonColors.dark
}

extension EnvironmentValues {
    var moon: MoonColors {
        get { self[MoonColorsKey.self] }
        set { self[MoonColorsKey.self] = newValue }
    }
}

extension ThemeMode {
    var preferred: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
    func colors(system: ColorScheme) -> MoonColors {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return system == .dark ? .dark : .light
        }
    }
}

struct GlassBackground: ViewModifier {
    var colors: MoonColors
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(colors.glassTint, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(colors.glassStroke, lineWidth: 0.7))
    }
}

extension View {
    func moonGlass(_ colors: MoonColors, radius: CGFloat = 22) -> some View {
        modifier(GlassBackground(colors: colors, radius: radius))
    }

    /// One-argument change handler that stays on the iOS 16 deployment target.
    @ViewBuilder
    func moonOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            onChange(of: value) { _, newValue in action(newValue) }
        } else {
            onChange(of: value, perform: action)
        }
    }
}

struct MoonBackground: View {
    var colors: MoonColors
    var body: some View {
        LinearGradient(colors: [colors.bgTop, colors.bgBottom], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(colors.accent.opacity(colors.dark ? 0.14 : 0.18))
                    .frame(width: 280, height: 280)
                    .blur(radius: 40)
                    .offset(x: 80, y: -40)
            }
            .ignoresSafeArea()
    }
}

enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func soft() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func tick() { UISelectionFeedbackGenerator().selectionChanged() }
    static func confirm() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

enum RelTime {
    static func string(_ ms: Int64, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        let d = now - ms
        if d < 60_000 { return "刚刚" }
        if d < 3_600_000 { return "\(d / 60_000) 分钟前" }
        if d < 86_400_000 { return "\(d / 3_600_000) 小时前" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }
}

enum Monogram {
    static let palette: [Color] = [
        Color(red: 0.91, green: 0.89, blue: 0.79),
        Color(red: 0.62, green: 0.70, blue: 0.90),
        Color(red: 0.55, green: 0.75, blue: 0.68),
        Color(red: 0.86, green: 0.70, blue: 0.55),
        Color(red: 0.72, green: 0.62, blue: 0.86),
        Color(red: 0.90, green: 0.62, blue: 0.70),
    ]
    static func color(_ index: Int) -> Color { palette[abs(index) % palette.count] }
    static func letter(_ name: String) -> String { String(name.prefix(1)) }
}

struct ArtPlate: View {
    var seed: Int
    var body: some View {
        let a = Monogram.palette[abs(seed) % Monogram.palette.count]
        let b = Monogram.palette[abs(seed + 3) % Monogram.palette.count]
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12), b.opacity(0.85), a.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 70, height: 70)
                .blur(radius: 0.4)
                .offset(x: CGFloat((seed % 5) - 2) * 18, y: -30)
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 8)
                .frame(width: 120, height: 120)
                .offset(y: 40)
        }
    }
}

enum ScreenInsets {
    static var top: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets.top ?? 48
    }
    static var bottom: CGFloat {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window?.safeAreaInsets.bottom ?? 20
    }
}

func artSeed(_ url: String?) -> Int? {
    guard let url, url.hasPrefix("art:") else { return nil }
    return Int(url.dropFirst(4))
}
