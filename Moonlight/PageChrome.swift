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
                .scaleEffect(CGFloat(max(1, focus.scale)))
                .offset(x: CGFloat(focus.x - 0.5) * 180, y: CGFloat(focus.y - 0.5) * 240)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: blurOn ? 28 : 0)
                Color.black.opacity(blurOn ? 0.5 : 0.18)
            }
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
                BackdropFill(settings: app.settings)
            }
        }
        .ignoresSafeArea(edges: app.settings.edgeToEdge ? .all : .bottom)
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

enum CaptureSlots {
    static let items: [(title: String, symbol: String, id: String)] = [
        ("拍照", "camera.fill", "capture.photo"),
        ("录像", "video.fill", "capture.video"),
        ("导入", "photo.on.rectangle", "capture.import"),
        ("发朋友圈", "square.and.pencil", "capture.compose"),
    ]
}

enum CaptureFanLayout {
    static func geometry(origin: CGPoint, size: CGSize) -> RadialResult {
        let margin = 16.0
        return RadialGeometry.layout(
            originX: Double(origin.x), originY: Double(origin.y), n: CaptureSlots.items.count,
            left: margin,
            top: Double(ScreenInsets.top) + 72,
            right: Double(size.width) - margin,
            bottom: Double(size.height) - Double(ScreenInsets.bottom) - 28,
            radius: 128,
            itemR: 42
        )
    }

    static func hitIndex(finger: CGPoint, origin: CGPoint, size: CGSize) -> Int? {
        let geo = geometry(origin: origin, size: size)
        return RadialGeometry.hit(geo, x: Double(finger.x), y: Double(finger.y), hitR: 48)
    }
}

struct CaptureFanOverlay: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let origin = app.fan?.origin ?? CGPoint(x: size.width / 2, y: size.height - 80)
            let finger = app.fan?.finger ?? origin
            let geo = CaptureFanLayout.geometry(origin: origin, size: size)
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                    .onTapGesture { app.fan = nil }
                // Not an ancestor of the bubbles: a parent identifier replaces theirs on iOS 26.
                Color.clear
                    .frame(width: 4, height: 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("capture.fan")
                    .accessibilityLabel("拍摄")
                    .allowsHitTesting(false)
                Text("拍摄")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .moonCapsule(overMedia: true)
                    .accessibilityIdentifier("capture.pill")
                    .offset(y: ScreenInsets.top + 28 - size.height / 2)
                Circle()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 8, height: 8)
                    .offset(x: geo.centerX - size.width / 2, y: geo.centerY - size.height / 2)
                    .allowsHitTesting(false)
                ForEach(Array(CaptureSlots.items.enumerated()), id: \.offset) { index, item in
                    let spot = geo.pos(index)
                    let center = CGPoint(x: spot.0, y: spot.1)
                    let near = hypot(finger.x - center.x, finger.y - center.y) < 54 && (app.fan?.down == true)
                    Button {
                        app.fireCapture(index)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 58, height: 58)
                                .moonDisc(overMedia: true)
                                .overlay(Circle().stroke(Color.white.opacity(near ? 0.9 : 0.35), lineWidth: near ? 1.6 : 0.7))
                                .scaleEffect(near ? 1.12 : 1)
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .moonCapsule(overMedia: true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityIdentifier(item.id)
                    // Padding participates in layout, so the hit target matches the drawn bubble.
                    // offset and position leave the control's hit target somewhere else.
                    .padding(.leading, max(0, center.x - 40))
                    .padding(.top, max(0, center.y - 46))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .zIndex(2)
                }
            }
        }
        .ignoresSafeArea()
    }
}
