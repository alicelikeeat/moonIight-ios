import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ComposerDraft
    @State private var item: PhotosPickerItem?

    init(draft: ComposerDraft) { _draft = State(initialValue: draft) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("发布者", selection: $draft.authorId) {
                    Text("我").tag(app.social.selfId)
                    ForEach(app.social.friends) { friend in
                        Text(friend.name).tag(friend.id)
                    }
                }
                TextEditor(text: $draft.text).frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
                PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                    Label("加图片或视频", systemImage: "photo")
                }
                if !draft.attachments.isEmpty {
                    Text("已附加 \(draft.attachments.count) 个").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("发动态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { app.postMoment(authorId: draft.authorId, text: draft.text, attachments: draft.attachments) }
                }
            }
            .moonOnChange(of: item) { newItem in
                guard let newItem else { return }
                Task {
                    await app.importPicker(newItem, focusAfter: false)
                    if let entry = app.library.entries.first {
                        draft.attachments.append(app.attachment(from: entry))
                    }
                    item = nil
                }
            }
        }
    }
}

struct FullPlayerView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @EnvironmentObject private var hold: HoldController
    @Environment(\.dismiss) private var dismiss
    var entry: MediaEntry
    @StateObject private var session = PlayerSession()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea().allowsHitTesting(false)
            if entry.kind == .embed, let raw = entry.embedURL ?? entry.remoteURL, let url = URL(string: raw) {
                WebEmbedView(url: url).ignoresSafeArea()
            } else if entry.playbackURL != nil {
                PlayerLayerView(player: session.player, gravity: Gravity.choose(mode: app.settings.videoDisplay, video: session.naturalSize, view: UIScreen.main.bounds.size, override: entry.fillOverride))
                    .ignoresSafeArea()
                MediaTouchLayer(
                    onSingle: { session.toggle() },
                    onDouble: { app.favoriteOnly(entry.id) },
                    onLongBegan: { point in openPlayerRing(point) },
                    onLongChanged: { point in
                        ring.finger = point
                        hold.move(point)
                    },
                    onLongEnded: { _ in
                        let outcome = hold.lift()
                        ring.fingerDown = false
                        if outcome != .timed && outcome != .center {
                            if ring.session?.drop == true {
                                ring.releaseFinger(at: ring.finger)
                            } else if ring.session?.select == .drag || ring.session?.select == .slider {
                                ring.selectDrag(at: ring.finger)
                            }
                        }
                    },
                    onSwipeLeft: { app.infoEntry = entry },
                    onPinch: { fill in
                        app.updateEntry(entry.id) { $0.fillOverride = fill }
                        app.showToast(fill == true ? "已铺满" : "跟随设置")
                    }
                )
                if ring.session != nil { RingOverlay(ring: ring) }
                HoldChrome()
                if !session.showsPlaying {
                    Image(systemName: "play.fill").font(.system(size: 28)).foregroundColor(.white)
                        .padding(18).moonDisc(overMedia: true)
                        .allowsHitTesting(false)
                }
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").foregroundColor(.white).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityIdentifier("player.close")
                    Spacer()
                    Text(entry.title).foregroundColor(.white).lineLimit(1).allowsHitTesting(false)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44).allowsHitTesting(false)
                }
                .padding(.top, ScreenInsets.top)
                Spacer().allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            app.feedPlayer.pause()
            if entry.kind != .embed, let url = entry.playbackURL {
                session.load(url: url, autoplay: true, muted: false)
            }
        }
        .onDisappear { session.pause() }
    }

    private func openPlayerRing(_ point: CGPoint) {
        let items = [
            RingItem(title: entry.favorite ? "已收藏" : "收藏", systemImage: entry.favorite ? "heart.fill" : "heart", key: "fav") { app.toggleFavorite(entry.id) },
            RingItem(title: session.isMuted ? "打开声音" : "静音", systemImage: "speaker", key: "mute") { session.isMuted.toggle() },
            RingItem(title: "分享", systemImage: "square.and.arrow.up", key: "share") { sharePlayer() },
            RingItem(title: "保存到相册", systemImage: "square.and.arrow.down", key: "save") { app.saveToPhotos(entry) },
        ]
        let groups = [
            MenuGroup(title: "更多", items: [
                RingItem(title: "随机一条", systemImage: "shuffle", key: "random") { app.randomItem() },
                RingItem(title: "录屏", systemImage: "record.circle", key: "record") { app.toggleRecording() },
            ]),
        ]
        ring.fingerDown = true
        ring.finger = point
        ring.present(origin: point, items: items, groups: groups, settings: app.settings, overMedia: true)
        hold.arm(origin: point, settings: app.settings, catalog: RingCatalog(items: items, groups: groups, context: .player, title: entry.title, overMedia: true))
    }

    private func sharePlayer() {
        var items: [Any] = [entry.title]
        if let path = entry.localPath { items = [URL(fileURLWithPath: path)] }
        else if let remote = entry.remoteURL, let url = URL(string: remote) { items = [url] }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(av, animated: true)
    }
}
