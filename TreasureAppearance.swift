import SwiftUI
import UIKit

enum TreasureBackground: String, Codable, CaseIterable, Identifiable {
    case system, solid, purple
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .solid: "自定义纯色"; case .purple: "黑紫主题" } }
}
struct TreasureAppearance: Codable, Equatable {
    var background = TreasureBackground.system
    var red = 0.08, green = 0.08, blue = 0.12
    static func load(_ data: Data, legacy: Data) -> Self {
        // Decode only the shared appearance fields. Legacy autoplay, target,
        // sound and image duration are deliberately never restored or run.
        (try? JSONDecoder().decode(Self.self, from: data)) ??
        (try? JSONDecoder().decode(Self.self, from: legacy)) ?? Self()
    }
    func isDark(system: ColorScheme) -> Bool {
        switch background {
        case .system: system == .dark
        case .purple: true
        case .solid: red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.5
        }
    }
}
struct TreasureBackgroundSurface: View {
    let options: TreasureAppearance
    var body: some View {
        switch options.background {
        case .system: Color(uiColor: .systemBackground)
        case .solid: Color(red: options.red, green: options.green, blue: options.blue)
        case .purple: LinearGradient(colors: [.black, Color(red: 0.15, green: 0.11, blue: 0.25)], startPoint: .top, endPoint: .bottom)
        }
    }
}
struct TreasureAppearanceSettings: View {
    @Binding var options: TreasureAppearance
    var body: some View {
        Form { Group {
            Picker("背景", selection: $options.background) {
                ForEach(TreasureBackground.allCases) { Text($0.title).tag($0) }
            }
            if options.background == .solid {
                ColorPicker("纯色", selection: Binding(get: {
                    Color(red: options.red, green: options.green, blue: options.blue)
                }, set: { color in
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
                    options.red = Double(r); options.green = Double(g); options.blue = Double(b)
                }), supportsOpacity: false)
            }
            TreasureBackgroundSurface(options: options).frame(height: 80).clipShape(RoundedRectangle(cornerRadius: 16))
            Button("恢复系统背景") { options = TreasureAppearance() }
            }.listRowBackground(MoonLiquidRowBackground())
        }.moonLiquidList().navigationTitle("月藏图背景")
    }
}
