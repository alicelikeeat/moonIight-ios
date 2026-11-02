import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MediaEntryCard: View {
    @EnvironmentObject private var model: AppModel
    let entry: MediaEntry
    let height: CGFloat
    var isSelected = false
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    GeometryReader { proxy in
                        thumbnail
                            .frame(width: proxy.size.width, height: height)
                            .clipped()
                    }
                    .frame(height: height)
                    .clipped()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, MoonStyle.accent)
                            .padding(9)
                    }
                    Text(model.mediaStore.enabledSources.first(where: { $0.id == entry.source })?.name ?? MediaSource.defaults.first(where: { $0.kind == entry.platform })?.name ?? entry.platform)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                    Text(entry.author.isEmpty ? entry.platform : entry.author)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(isSelected ? MoonStyle.accent : .white.opacity(0.55), lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background { MediaCardHitAnchor(entryID: entry.id).allowsHitTesting(false).accessibilityHidden(true) }
        .modifier(NativeMediaCardInteractions(
            holdEnabled: model.cardLongPressEnabled,
            onTap: onSelect,
            onHold: {
                LongPressHapticFeedback.shared.menuOpened()
                let location = MediaCardHitRegistry.center(for: entry.id) ?? CGPoint(x: 180, y: 360)
                activateLongPress(at: location)
                finishLongPress()
            }
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityIdentifier("media-card-\(entry.id)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }

    private func activateLongPress(at location: CGPoint) {
        model.activeLongPressMenu = ActiveLongPressMenu(entry: entry, location: location, fingerLocation: location)
    }

    private func finishLongPress() {
        if var menu = model.activeLongPressMenu, menu.entry?.id == entry.id {
            menu.fingerDown = false
            model.activeLongPressMenu = menu
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if entry.kind == .image, let url = entry.remoteURL, url.isFileURL {
            LocalMediaImage(url: url, fill: true)
        } else if entry.kind == .video, let url = entry.remoteURL, url.isFileURL {
            LocalVideoPoster(url: url)
        } else if let url = entry.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                case .failure: fallback
                case .empty: ZStack { fallback; ProgressView().tint(.white) }
                @unknown default: fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        LinearGradient(colors: [MoonStyle.accent.opacity(0.72), Color.indigo.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(Image(systemName: "play.rectangle.fill").font(.system(size: 32)).foregroundStyle(.white.opacity(0.75)))
    }
}

struct LocalVideoPoster: View {
    let url: URL
    @State private var poster: UIImage?
    var body: some View {
        ZStack {
            if let poster {
                Image(uiImage: poster).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [MoonStyle.accent.opacity(0.65), .indigo.opacity(0.36)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Image(systemName: "play.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
        }
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            if let result = try? await generator.image(at: .zero) { poster = UIImage(cgImage: result.image) }
        }
    }
}
