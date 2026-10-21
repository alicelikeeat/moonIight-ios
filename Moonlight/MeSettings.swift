import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var colors
    @State private var showSettings = false
    @State private var showLibrary = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var coverItem: PhotosPickerItem?
    @State private var editingName = false
    @State private var name = ""
    @State private var bio = ""

    var body: some View {
        let me = app.social.me
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        cover(me)
                            .frame(height: 180)
                            .clipped()
                        PhotosPicker(selection: $coverItem, matching: .images) {
                            Text("换封面").font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        avatar(me)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(me.name).font(.system(size: 22, weight: .bold))
                            Text(me.bio.isEmpty ? "写一句介绍" : me.bio).font(.system(size: 13)).foregroundColor(colors.textDim)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .offset(y: -28)
                    VStack(spacing: 10) {
                        navRow("库", "square.grid.2x2") { showLibrary = true }
                        navRow("编辑资料", "pencil") { name = me.name; bio = me.bio; editingName = true }
                        navRow("设置", "gearshape") { showSettings = true }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 100)
            }
            .background(MoonBackground(colors: colors))
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $showLibrary) { LibraryView() }
            .navigationDestination(isPresented: $showSettings) { SettingsView() }
            .moonOnChange(of: avatarItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        app.copyProfileData(contactId: me.id, data: data, cover: false)
                    }
                    avatarItem = nil
                }
            }
            .moonOnChange(of: coverItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        app.copyProfileData(contactId: me.id, data: data, cover: true)
                    }
                    coverItem = nil
                }
            }
            .alert("编辑资料", isPresented: $editingName) {
                TextField("名字", text: $name)
                TextField("简介", text: $bio)
                Button("保存") {
                    var copy = app.social.me
                    copy.name = name.isEmpty ? "我" : name
                    copy.bio = bio
                    app.upsertFriend(copy)
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func cover(_ me: Contact) -> some View {
        Group {
            if let path = me.coverPath, FileManager.default.fileExists(atPath: path) {
                RemoteOrLocalImage(url: URL(fileURLWithPath: path), mode: .fill)
            } else {
                ArtPlate(seed: 0)
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) { profileRing(me, cover: true) }
    }

    private func avatar(_ me: Contact) -> some View {
        PhotosPicker(selection: $avatarItem, matching: .images) {
            Group {
                if let path = me.avatarPath, FileManager.default.fileExists(atPath: path) {
                    RemoteOrLocalImage(url: URL(fileURLWithPath: path), mode: .fill)
                } else {
                    Circle().fill(Monogram.color(me.avatarColor))
                        .overlay(Text(Monogram.letter(me.name)).font(.system(size: 28, weight: .semibold)).foregroundColor(.black.opacity(0.75)))
                }
            }
            .frame(width: 84, height: 84)
            .clipShape(Circle())
            .overlay(Circle().stroke(colors.bgTop, lineWidth: 3))
        }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in profileRing(me, cover: false) })
    }

    private func profileRing(_ me: Contact, cover: Bool) {
        ring.present(origin: CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY), items: [
            RingItem(title: "更换", systemImage: "photo") { app.showToast(cover ? "点右上角换封面" : "点头像换一张") },
            RingItem(title: "调整位置", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
                app.editSocial { s in
                    guard let i = s.contacts.firstIndex(where: { $0.id == me.id }) else { return }
                    if cover {
                        var f = s.contacts[i].coverFocus ?? MediaFocus()
                        f.y = min(1, f.y + 0.1)
                        s.contacts[i].coverFocus = f
                    } else {
                        var f = s.contacts[i].avatarFocus ?? MediaFocus()
                        f.scale = min(MediaFocus.maxScale, f.scale + 0.15)
                        s.contacts[i].avatarFocus = f
                    }
                }
                app.showToast("已微调位置")
            },
            RingItem(title: "播放", systemImage: "play") { app.showToast("封面视频会在后续版本循环播放") },
            RingItem(title: "恢复默认", systemImage: "arrow.uturn.backward") { app.restoreProfile(contactId: me.id, cover: cover) },
        ], groups: [], settings: app.settings)
    }

    private func navRow(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol).frame(width: 28)
                Text(title).font(.system(size: 16, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(colors.textDim)
            }
            .padding(14)
            .moonGlass(colors, radius: 16)
        }
        .foregroundColor(colors.text)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.moon) private var colors
    @State private var exportURL: URL?
    @State private var importing = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: binding(\.theme)) {
                    ForEach(ThemeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("视频显示", selection: binding(\.videoDisplay)) {
                    ForEach(VideoDisplay.allCases, id: \.self) { Text($0.short).tag($0) }
                }
                Picker("菜单背景", selection: binding(\.menuBackdrop)) {
                    ForEach(MenuBackdrop.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("长按菜单", selection: binding(\.menuSelect)) {
                    ForEach(MenuSelect.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("长按动画", selection: animBinding) {
                    Text("随机").tag(RingAnim.random)
                    ForEach(RingAnim.choices, id: \.self) { Text($0.short).tag($0.rawValue) }
                }
                Text(RingAnim.of(app.settings.ringAnim).hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("动画池（随机时使用）") {
                ForEach(RingAnim.choices, id: \.self) { style in
                    Toggle(style.label, isOn: Binding(
                        get: { RingAnimPick.parseSet(app.settings.ringAnimSet).contains(style) },
                        set: { on in
                            var set = RingAnimPick.parseSet(app.settings.ringAnimSet)
                            if on { set.insert(style) } else { set.remove(style) }
                            app.settings.ringAnimSet = RingAnimPick.encodeSet(set)
                            app.saveSettings()
                        }
                    ))
                }
            }
            Section("图库密钥") {
                SecureField("Pexels API Key", text: binding(\.pexelsKey))
                SecureField("Pixabay API Key", text: binding(\.pixabayKey))
                Text("留空则不请求这两家。不会内置任何密钥。").font(.caption).foregroundColor(.secondary)
            }
            Section("聊天服务器") {
                TextField("https://", text: binding(\.chatServerURL))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("连接") {}
                    .disabled(true)
                Text("即将推出。当前只有本机的 LocalTransport，RemoteTransport 不会联网。").font(.caption).foregroundColor(.secondary)
            }
            Section("朋友圈") {
                Button("载入示例好友") { app.loadDemo() }
                Button("导出 social.json") { exportURL = app.exportSocial() }
                Button("导入备份") { importing = true }
            }
            Section("关于") {
                Text("月光 0.1 · iOS")
                Text("不解析哔哩哔哩 playurl / WBI，不下载流媒体，不绕过 DRM。网页播放只用官方嵌入页。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                let ok = url.startAccessingSecurityScopedResource()
                app.importSocial(url: url)
                if ok { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private var animBinding: Binding<String> {
        Binding(get: { app.settings.ringAnim }, set: { app.settings.ringAnim = $0; app.saveSettings() })
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { app.settings[keyPath: keyPath] = $0; app.saveSettings() })
    }
}

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
    @Environment(\.dismiss) private var dismiss
    var entry: MediaEntry
    @StateObject private var session = PlayerSession()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = entry.playbackURL {
                PlayerLayerView(player: session.player, gravity: Gravity.choose(mode: app.settings.videoDisplay, video: session.naturalSize, view: UIScreen.main.bounds.size, override: entry.fillOverride))
                    .ignoresSafeArea()
            }
            MediaTouchLayer(
                onSingle: { session.toggle() },
                onDouble: { app.favoriteOnly(entry.id) },
                onLongBegan: { _ in },
                onLongChanged: { _ in },
                onLongEnded: { _ in }
            )
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").foregroundColor(.white).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text(entry.title).foregroundColor(.white).lineLimit(1)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.top, ScreenInsets.top)
                Spacer()
            }
            if !session.showsPlaying {
                Image(systemName: "play.fill").font(.system(size: 28)).foregroundColor(.white)
                    .padding(18).background(.ultraThinMaterial, in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            app.feedPlayer.pause()
            if let url = entry.playbackURL { session.load(url: url, autoplay: true, muted: false) }
        }
        .onDisappear { session.pause() }
    }
}
