import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MeView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var colors
    @State private var meSheet: MeSheet?
    @State private var coverPlaying = true
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
                        PhotosPicker(selection: $coverItem, matching: .any(of: [.images, .videos])) {
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
                        navRow("库", "square.grid.2x2", id: "me.library") { meSheet = .library }
                        navRow("编辑资料", "pencil", id: "me.edit") { name = me.name; bio = me.bio; editingName = true }
                        navRow("设置", "gearshape", id: "me.settings") { meSheet = .settings }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 100)
            }
            .background { SystemGlassFill(dark: colors.dark) }
            .toolbar(.hidden, for: .navigationBar)
            .moonOnChange(of: avatarItem) { item in
                guard let item else { return }
                let contact = me.id
                Task {
                    await app.importProfile(item: item, contactId: contact, cover: false)
                    await MainActor.run { avatarItem = nil }
                }
            }
            .moonOnChange(of: coverItem) { item in
                guard let item else { return }
                let contact = me.id
                Task {
                    await app.importProfile(item: item, contactId: contact, cover: true)
                    await MainActor.run { coverItem = nil }
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
        .onAppear { if app.requestSettings { meSheet = .settings } }
        .moonOnChange(of: app.requestSettings) { on in
            if on { meSheet = .settings }
        }
        .sheet(item: $meSheet, onDismiss: { app.requestSettings = false }) { sheet in
            switch sheet {
            case .library:
                NavigationStack {
                    LibraryView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { meSheet = nil }
                            }
                        }
                }
            case .settings:
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { meSheet = nil }
                                    .accessibilityIdentifier("settings.done")
                            }
                        }
                }
            case .focus:
                focusSheet(cover: false)
            case .coverFocus:
                focusSheet(cover: true)
            }
        }
    }

    private func focusSheet(cover: Bool) -> some View {
        let me = app.social.me
        return FocusEditor(
            path: cover ? me.coverPath : me.avatarPath,
            video: cover ? me.coverVideo : me.avatarVideo,
            focus: Binding(
                get: { (cover ? app.social.me.coverFocus : app.social.me.avatarFocus) ?? MediaFocus() },
                set: { value in
                    let next = value.clamped()
                    app.editSocial { s in
                        guard let i = s.contacts.firstIndex(where: { $0.id == s.selfId }) else { return }
                        if cover { s.contacts[i].coverFocus = next } else { s.contacts[i].avatarFocus = next }
                    }
                }
            )
        )
    }

    private func cover(_ me: Contact) -> some View {
        let focus = me.coverFocus ?? MediaFocus()
        return Group {
            if let path = me.coverPath, me.coverVideo, FileManager.default.fileExists(atPath: path), coverPlaying {
                LoopFilm(ref: path)
            } else if let path = me.coverPath, FileManager.default.fileExists(atPath: path), let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ArtPlate(seed: 0)
            }
        }
        .scaleEffect(CGFloat(focus.scale))
        .offset(x: CGFloat(focus.x - 0.5) * 80, y: CGFloat(focus.y - 0.5) * 40)
        .onLongPressGesture(minimumDuration: 0.45) { profileRing(me, cover: true) }
    }

    private func avatar(_ me: Contact) -> some View {
        PhotosPicker(selection: $avatarItem, matching: .any(of: [.images, .videos])) {
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
                meSheet = cover ? .coverFocus : .focus
            },
            RingItem(title: coverPlaying ? "暂停" : "播放", systemImage: coverPlaying ? "pause" : "play") {
                let current = cover ? app.social.me.coverVideo : app.social.me.avatarVideo
                let path = cover ? app.social.me.coverPath : app.social.me.avatarPath
                guard current, path != nil else {
                    app.showToast(cover ? "封面还是图片，换一段视频才能循环播放" : "头像还是图片，换一段视频才能循环播放")
                    return
                }
                coverPlaying.toggle()
            },
            RingItem(title: "恢复默认", systemImage: "arrow.uturn.backward") { app.restoreProfile(contactId: me.id, cover: cover) },
        ], groups: [], settings: app.settings)
    }

    private func rowContents(_ title: String, _ symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 28)
            Text(title).font(.system(size: 16, weight: .medium))
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(colors.textDim)
        }
        .padding(14)
        .moonGlass(colors, radius: 16)
    }

    private func navRow(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            guard !PressGate.suppressTap else { return }
            action()
        } label: {
            rowContents(title, symbol)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundColor(colors.text)
        .accessibilityIdentifier(id)
    }
}

enum MeSheet: String, Identifiable {
    case library, settings, focus, coverFocus
    var id: String { rawValue }
}

enum SettingsPage: String, Identifiable {
    case skins, icons, autoplay, focus, trash
    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var colors
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var page: SettingsPage?
    @State private var backdropItem: PhotosPickerItem?

    var body: some View {
        Form {
            Section("功能") {
                Button("按键背景") { page = .skins }
                    .accessibilityIdentifier("settings.skins")
                Button("主屏幕图标") { page = .icons }
                    .accessibilityIdentifier("settings.icons")
                Button("朋友圈播放 · \(app.settings.momentAutoplay.label)") { page = .autoplay }
                    .accessibilityIdentifier("settings.autoplay")
                PhotosPicker(selection: $backdropItem, matching: .any(of: [.images, .videos])) {
                    Text("首页背景")
                }
                .accessibilityIdentifier("settings.backdrop")
                Button("清除首页背景") {
                    app.settings.homeBackdropPath = nil
                    app.settings.homeBackdropVideo = false
                    app.saveSettings()
                }
                Button("调整头像位置") { page = .focus }
                    .accessibilityIdentifier("settings.focus")
                Button("最近删除") { page = .trash }
                    .accessibilityIdentifier("settings.trash")
                Toggle("后台刷新公开源", isOn: Binding(
                    get: { app.settings.bgRefreshOn },
                    set: {
                        app.settings.bgRefreshOn = $0
                        app.saveSettings()
                        BGRefresh.schedule(enabled: $0)
                    }
                ))
                .accessibilityIdentifier("settings.refresh")
                if app.settings.lastRefreshAt > 0 {
                    Text("上次刷新已记下").font(.caption).foregroundColor(.secondary)
                } else {
                    Text("系统决定什么时候跑，不保证立刻执行。").font(.caption).foregroundColor(.secondary)
                }
            }
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
                    ForEach(MenuSelect.choices, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("水滴选择", isOn: binding(\.dropSelect))
                    .accessibilityIdentifier("settings.drop")
                Text("默认关闭。长按只弹出圆环，点按键才会执行。打开后玻璃水滴跟着手指，松手落到的按键会执行。不管开不开，拖动时旁边的按键都会浮起来。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("底栏滑块", isOn: binding(\.tabLens))
                    .accessibilityIdentifier("settings.tabLens")
                Text("默认打开，底栏可以按住拖动换页。关掉后换成没有滑块的玻璃底栏。按在底栏上只换页；按在别的地方才弹出圆环。圆环开着时，同一根手指划过底栏也不会换页。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("按键自动隐藏", isOn: binding(\.chromeAutoHide))
                    .accessibilityIdentifier("settings.chromeHide")
                Picker("消失时间", selection: hideChoice) {
                    Text("1 秒").tag(1)
                    Text("2 秒").tag(2)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                    Text("自定义").tag(0)
                }
                .accessibilityIdentifier("settings.hideDelay")
                if hideChoice.wrappedValue == 0 {
                    HStack {
                        Text("1 秒")
                        Slider(value: Binding(
                            get: { Double(app.settings.chromeHideSeconds) },
                            set: { app.settings.chromeHideSeconds = ChromeTiming.clamp(Float($0.rounded())); app.saveSettings() }
                        ), in: 1...30, step: 1)
                        Text("30 秒")
                    }
                    Text(String(format: "%.0f 秒", app.settings.chromeHideSeconds))
                        .font(.caption).foregroundColor(.secondary)
                }
                Text("视频播放时收起首页按键和底栏。点一下画面它们会以系统玻璃淡入，安静一段时间后再消失。点任何按键都会重新计时。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("低电量不自动播放", isOn: binding(\.pauseOnLowPower))
                    .accessibilityIdentifier("settings.lowPower")
                Toggle("蜂窝网络不自动播放", isOn: binding(\.autoplayWifiOnly))
                    .accessibilityIdentifier("settings.wifiOnly")
                Picker("长按动画", selection: animBinding) {
                    Text("随机").tag(RingAnim.random)
                    ForEach(RingAnim.choices, id: \.self) { Text($0.short).tag($0.rawValue) }
                }
                Text(RingAnim.of(app.settings.ringAnim).hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("圆环速度") {
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
                Text("这个速度同时作用在星轨和旋转上。旋转会像气泡一样弹到位。")
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
                SecureField("YouTube Data API Key", text: binding(\.youtubeKey))
                TextField("PeerTube 实例，例如 example.com", text: binding(\.peertubeInstance))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("密钥和实例都留空则不请求。YouTube 搜索只用官方 Data API。不会内置任何密钥。").font(.caption).foregroundColor(.secondary)
            }
            Section("聊天服务器") {
                TextField("https://", text: binding(\.chatServerURL))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.chatURL")
                Button(app.chatConnected ? "已连接" : "连接") {
                    Task { await app.connectChat() }
                }
                .disabled(app.settings.chatServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings.chatConnect")
                Text("填写自己的服务器后点连接。协议是公开的 JSON：POST /v1/conversations/{id}/messages，GET /v1/sync。留空则只保存在本机，不会联网。").font(.caption).foregroundColor(.secondary)
            }
            Section("朋友圈") {
                Button("载入示例好友") { app.loadDemo() }
                Button("导出 social.json") { exportURL = app.exportSocial() }
                Button("导入备份") { importing = true }
            }
            Section("关于") {
                Text("月光 1.0 · iOS")
                Text("不解析哔哩哔哩 playurl / WBI，不下载流媒体，不绕过 DRM。网页播放只用官方嵌入页。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.root")
        .background { SystemGlassFill(dark: colors.dark) }
        .sheet(item: $page) { page in
            switch page {
            case .skins: ButtonSkinsView()
            case .icons: IconPickerView()
            case .autoplay: AutoplaySheet()
            case .focus:
                FocusEditor(
                    path: app.social.me.avatarPath,
                    video: app.social.me.avatarVideo,
                    focus: Binding(
                        get: { app.social.me.avatarFocus ?? MediaFocus() },
                        set: { value in
                            let next = value.clamped()
                            app.editSocial { s in
                                guard let i = s.contacts.firstIndex(where: { $0.id == s.selfId }) else { return }
                                s.contacts[i].avatarFocus = next
                            }
                        }
                    )
                )
            case .trash: TrashView()
            }
        }
        .moonOnChange(of: backdropItem) { item in
            guard let item else { return }
            Task { await importBackdrop(item) }
        }
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

    private func importBackdrop(_ item: PhotosPickerItem) async {
        let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        Paths.ensureDirs()
        if video, let movie = try? await item.loadTransferable(type: MovieFile.self) {
            let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
            let dest = Paths.media.appendingPathComponent("bg_\(IDs.new()).\(ext)")
            do {
                try FileManager.default.copyItem(at: movie.url, to: dest)
                await MainActor.run {
                    app.settings.homeBackdropPath = dest.path
                    app.settings.homeBackdropVideo = true
                    app.saveSettings()
                    app.showToast("已设为视频背景")
                }
            } catch {
                await MainActor.run { app.showToast("没能保存背景") }
            }
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            let dest = Paths.media.appendingPathComponent("bg_\(IDs.new()).jpg")
            do {
                try data.write(to: dest)
                await MainActor.run {
                    app.settings.homeBackdropPath = dest.path
                    app.settings.homeBackdropVideo = false
                    app.saveSettings()
                    app.showToast("已设为背景")
                }
            } catch {
                await MainActor.run { app.showToast("没能保存背景") }
            }
        }
        await MainActor.run { backdropItem = nil }
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

    private var hideChoice: Binding<Int> {
        Binding(
            get: {
                let seconds = Int(app.settings.chromeHideSeconds.rounded())
                return ChromeTiming.presets.contains(Float(seconds)) ? seconds : 0
            },
            set: { choice in
                if choice == 0 {
                    let seconds = Int(app.settings.chromeHideSeconds.rounded())
                    if ChromeTiming.presets.contains(Float(seconds)) {
                        app.settings.chromeHideSeconds = 8
                    }
                } else {
                    app.settings.chromeHideSeconds = ChromeTiming.clamp(Float(choice))
                }
                app.saveSettings()
            }
        )
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
                        app.showToast(fill ? "已铺满" : "已完整")
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
