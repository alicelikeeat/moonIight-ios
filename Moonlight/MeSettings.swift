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
            .onAppear { if app.requestSettings { showSettings = true; app.requestSettings = false } }
            .moonOnChange(of: app.requestSettings) { on in
                if on { showSettings = true; app.requestSettings = false }
            }
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
    @EnvironmentObject private var ring: RingController
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
            Section("星轨速度") {
                HStack {
                    Text("慢")
                    Slider(value: Binding(
                        get: { Double(app.settings.starSpeed) },
                        set: { app.settings.starSpeed = RingMotion.clampSpeed(Float($0)); app.saveSettings() }
                    ), in: 0.5...2)
                    Text("快")
                }
                Text(String(format: "%.2f×", app.settings.starSpeed))
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Button("慢") { app.settings.starSpeed = 0.7; app.saveSettings() }
                    Button("标准") { app.settings.starSpeed = 1; app.saveSettings() }
                    Button("快") { app.settings.starSpeed = 1.4; app.saveSettings() }
                    Button("试一试") { previewStar() }
                }
                Text("按钮从屏幕上方的天空旋转落下，沿螺旋加速，落地略微过冲后回到完整大小。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section {
                Toggle("定时长按", isOn: binding(\.timedOn))
                if app.settings.timedOn {
                    Picker("触发时间", selection: thresholdChoice) {
                        Text("5 秒").tag(0)
                        Text("10 秒").tag(1)
                        Text("自定义").tag(2)
                    }
                    if thresholdChoice.wrappedValue == 2 {
                        HStack {
                            Text("3 秒")
                            Slider(value: Binding(
                                get: { Double(app.settings.timedSeconds) },
                                set: { app.settings.timedSeconds = HoldConfig.clampSeconds(Float(($0 * 2).rounded() / 2)); app.saveSettings() }
                            ), in: 3...15)
                            Text("15 秒")
                        }
                        Text(String(format: "%.1f 秒", app.settings.timedSeconds))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Toggle("显示计时", isOn: binding(\.timedShowTime))
                    Toggle("倒计时动画", isOn: binding(\.timedCountdown))
                    Toggle("到时自动触发", isOn: binding(\.timedAutoFire))
                    ForEach(HoldContext.allCases, id: \.self) { ctx in
                        Picker("分配 · \(ctx.label)", selection: assignBinding(ctx)) {
                            Text("不分配").tag("")
                            ForEach(TimedActions.options(ctx)) { option in
                                Text(option.label).tag(option.key)
                            }
                        }
                    }
                }
                Toggle("全部按键", isOn: binding(\.centerPanel))
            } header: {
                Text("定时长按")
            } footer: {
                Text("长按照常打开菜单。继续按住到设定时间，分配给该场景的按钮会执行，可撤销的会给出撤销。删除不能被分配。手指移动超过一小段会取消计时。在屏幕中心圆里按住 5 秒打开全部按键。")
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
                Text("月光 0.3 · iOS")
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

    private func previewStar() {
        let origin = CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY)
        ring.present(origin: origin, items: [
            RingItem(title: "收藏", systemImage: "heart") {},
            RingItem(title: "倍速", systemImage: "speedometer") {},
            RingItem(title: "声音", systemImage: "speaker.wave.2") {},
            RingItem(title: "分享", systemImage: "square.and.arrow.up") {},
        ], groups: [
            MenuGroup(title: "预览", items: [RingItem(title: "关闭", systemImage: "xmark") {}]),
        ], settings: app.settings, overMedia: false, styleOverride: .star)
    }

    private var thresholdChoice: Binding<Int> {
        Binding(
            get: {
                if abs(app.settings.timedSeconds - 5) < 0.05 { return 0 }
                if abs(app.settings.timedSeconds - 10) < 0.05 { return 1 }
                return 2
            },
            set: { choice in
                switch choice {
                case 0: app.settings.timedSeconds = 5
                case 1: app.settings.timedSeconds = 10
                default:
                    if abs(app.settings.timedSeconds - 5) < 0.05 || abs(app.settings.timedSeconds - 10) < 0.05 {
                        app.settings.timedSeconds = 7
                    }
                }
                app.saveSettings()
            }
        )
    }

    private func assignBinding(_ ctx: HoldContext) -> Binding<String> {
        Binding(
            get: { app.settings.timedAssign[ctx.rawValue] ?? "" },
            set: { value in
                if value.isEmpty { app.settings.timedAssign.removeValue(forKey: ctx.rawValue) }
                else if TimedActions.assignable(ctx, value) { app.settings.timedAssign[ctx.rawValue] = value }
                app.saveSettings()
            }
        )
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
    @EnvironmentObject private var ring: RingController
    @EnvironmentObject private var hold: HoldController
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
                onLongBegan: { point in openPlayerRing(point) },
                onLongChanged: { point in
                    ring.finger = point
                    hold.move(point)
                },
                onLongEnded: { _ in
                    let outcome = hold.lift()
                    ring.fingerDown = false
                    if outcome != .timed && outcome != .center && app.settings.menuSelect == .drag {
                        ring.selectDrag(at: ring.finger)
                    }
                }
            )
            if ring.session != nil { RingOverlay(ring: ring) }
            HoldChrome()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").foregroundColor(.white).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text(entry.title).foregroundColor(.white).lineLimit(1).allowsHitTesting(false)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44).allowsHitTesting(false)
                }
                .padding(.top, ScreenInsets.top)
                Spacer().allowsHitTesting(false)
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
                RingItem(title: "录屏", systemImage: "record.circle", key: "record") { app.showToast("录屏在下一版用系统 ReplayKit，只录本应用") },
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
