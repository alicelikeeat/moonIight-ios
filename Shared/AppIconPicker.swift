import SwiftUI
import UIKit

/// v1.85: choose the home screen icon (five glass moons, or the classic one).
struct AppIconChoice: Identifiable, Equatable {
    /// nil = the primary icon.
    let iconName: String?
    let preview: String
    let zh: String, en: String
    var id: String { iconName ?? "primary" }
    var title: String { L10n.t(zh, en) }

    static let all: [AppIconChoice] = [
        AppIconChoice(iconName: nil, preview: "AppIconPreview", zh: "金纹玻璃", en: "Gold Veins"),
        AppIconChoice(iconName: "IconPixel", preview: "IconPixelPreview", zh: "像素月", en: "Pixel Moon"),
        AppIconChoice(iconName: "IconBubble", preview: "IconBubblePreview", zh: "虹彩泡泡", en: "Rainbow Bubble"),
        AppIconChoice(iconName: "IconPaint", preview: "IconPaintPreview", zh: "油彩月", en: "Painted Moon"),
        AppIconChoice(iconName: "IconInk", preview: "IconInkPreview", zh: "水墨月", en: "Ink Moon"),
        AppIconChoice(iconName: "IconClassic", preview: "IconClassicPreview", zh: "经典", en: "Classic"),
    ]
}

struct AppIconPicker: View {
    @State private var current = UIApplication.shared.alternateIconName
    @State private var message: String?
    @Namespace private var selection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 18) {
                    ForEach(AppIconChoice.all) { choice in tile(choice) }
                }
                .padding(14).moonGlassCard(radius: 24)
                if let message { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                Text(L10n.t("换图标后系统会弹出一次提示，这是 iOS 的规定。", "iOS shows a short notice after the icon changes."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .moonLiquidPage()
        .navigationTitle(L10n.t("App 图标", "App Icon"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("app-icon-screen")
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let chosen = current == choice.iconName
        return Button { pick(choice) } label: {
            VStack(spacing: 8) {
                Image(choice.preview).resizable().scaledToFit()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8))
                    .background {
                        if chosen {
                            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3)
                                .padding(-6).matchedGeometryEffect(id: "icon", in: selection)
                        }
                    }
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                Text(choice.title).font(.caption.weight(chosen ? .semibold : .regular)).foregroundStyle(chosen ? Color.accentColor : .primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.moonJelly)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("app-icon-\(choice.id)")
    }

    private func pick(_ choice: AppIconChoice) {
        guard choice.iconName != current, UIApplication.shared.supportsAlternateIcons else {
            if !UIApplication.shared.supportsAlternateIcons { message = L10n.t("这台设备不支持更换图标", "This device cannot change the icon") }
            return
        }
        withAnimation(MoonLiquidMotion.morph) { current = choice.iconName }
        UIApplication.shared.setAlternateIconName(choice.iconName) { error in
            Task { @MainActor in
                if let error {
                    current = UIApplication.shared.alternateIconName
                    message = L10n.t("没有换成：", "Could not change: ") + error.localizedDescription
                } else {
                    message = L10n.t("已换成「\(choice.title)」", "Changed to \(choice.title)")
                }
            }
        }
    }
}
