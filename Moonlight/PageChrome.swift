import SwiftUI
import UIKit

struct BackdropFill: View {
    var settings: AppSettings

    var body: some View {
        let video = settings.backdropMode == .video
        let stored = video ? settings.backdropVideo : settings.backdropPhoto
        let focus = video ? settings.backdropVideoFocus : settings.backdropPhotoFocus
        let blurOn = video ? settings.backdropVideoBlur : settings.backdropPhotoBlur
        let file = BackdropFiles.path(stored)
        GeometryReader { geo in
            ZStack {
                Color.black
                if settings.backdropMode != .black, let file {
                    Group {
                        if video {
                            LoopFilm(ref: file)
                        } else if let image = UIImage(contentsOfFile: file) {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .frame(width: geo.size.width * 1.35, height: geo.size.height * 1.35)
                    .scaleEffect(CGFloat(max(1, focus.scale)))
                    .offset(x: CGFloat(focus.x - 0.5) * geo.size.width, y: CGFloat(focus.y - 0.5) * geo.size.height)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .blur(radius: blurOn ? 28 : 0)
                    Color.black.opacity(blurOn ? 0.5 : 0.18)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

struct PageBackdrop: View {
    var page: BackdropPage
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if app.settings.showsBackdrop(page) {
                ScreenPinnedFill { BackdropFill(settings: app.settings) }
            }
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

/// Pins a fill to the physical screen, including the Dynamic Island and the home indicator.
/// The background layer is the only thing that ignores the safe area.
struct ScreenPinnedFill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global)
            let screen = UIScreen.main.bounds
            content()
                .frame(width: screen.width, height: screen.height)
                .position(x: screen.midX - global.minX, y: screen.midY - global.minY)
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

struct ScreenBackdrop: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Group {
            if app.settings.showsBackdrop(app.visibleBackdrop) {
                ScreenPinnedFill { BackdropFill(settings: app.settings) }
            }
        }
        .ignoresSafeArea(.all)
        .allowsHitTesting(false)
    }
}

struct GlassIcon: View {
    var symbol: String
    var tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(tint, in: Circle())
    }
}

enum GlassTint {
    static let green = Color(red: 0.33, green: 0.70, blue: 0.52)
    static let pink = Color(red: 0.91, green: 0.42, blue: 0.52)
    static let purple = Color(red: 0.56, green: 0.46, blue: 0.86)
    static let blue = Color(red: 0.34, green: 0.54, blue: 0.92)
    static let orange = Color(red: 0.93, green: 0.62, blue: 0.28)
    static let gray = Color(red: 0.45, green: 0.48, blue: 0.55)
    static let red = Color(red: 0.86, green: 0.28, blue: 0.28)
}

struct GlassGroup<Content: View>: View {
    var title: String
    var colors: MoonColors
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(colors.textDim)
                .padding(.leading, 14)
            VStack(spacing: 0) { content() }
                .padding(.vertical, 4)
                .moonGlass(colors, radius: 22)
        }
    }
}

struct GlassLine: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color
    var colors: MoonColors
    var showChevron = true

    var body: some View {
        HStack(spacing: 12) {
            GlassIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundColor(colors.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundColor(colors.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showChevron {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundColor(colors.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct BackdropPagesSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moon) private var colors

    private var ink: MoonColors { app.settings.showsBackdrop(.settings) ? .media : colors }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        quick("全选") { app.settings.backdropPages = BackdropPages.selectAll(); app.saveSettings() }
                        quick("仅首页") { app.settings.backdropPages = BackdropPages.selectHome(); app.saveSettings() }
                    }
                    VStack(spacing: 0) {
                        ForEach(BackdropPage.allCases) { page in
                            Button {
                                var pages = app.settings.backdropPages
                                if pages.contains(page.rawValue) { pages.removeAll { $0 == page.rawValue } }
                                else { pages.append(page.rawValue) }
                                app.settings.backdropPages = BackdropPages.normalize(pages)
                                app.saveSettings()
                            } label: {
                                HStack {
                                    Text(page.label).font(.system(size: 16, weight: .medium)).foregroundColor(ink.text)
                                    Spacer()
                                    Image(systemName: app.settings.backdropPages.contains(page.rawValue) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(app.settings.backdropPages.contains(page.rawValue) ? ink.accent : ink.textDim)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("backdrop.page.\(page.rawValue)")
                        }
                    }
                    .moonGlass(ink, radius: 22)
                    Text("没选中的页面用主题背景。")
                        .font(.system(size: 12))
                        .foregroundColor(ink.textDim)
                }
                .padding(16)
            }
            .background {
                if app.settings.showsBackdrop(.settings) { PageBackdrop(page: .settings) }
                else { SystemGlassFill(dark: colors.dark) }
            }
            .navigationTitle("应用到页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func quick(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(ink.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .moonGlass(ink, radius: 14)
    }
}

/// Forces a dark scheme when a page backdrop is showing, without reading
/// `colorScheme` in the same view that writes it. That cycle drops later updates.
struct BackdropScheme: ViewModifier {
    @EnvironmentObject private var app: AppModel
    var page: BackdropPage

    func body(content: Content) -> some View {
        if app.settings.showsBackdrop(page) {
            content.environment(\.colorScheme, .dark)
        } else {
            content
        }
    }
}
