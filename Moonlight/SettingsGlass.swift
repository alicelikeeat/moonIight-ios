import PhotosUI
import SwiftUI
import UIKit

enum SettingsPage: String, Identifiable {
    case skins, icons, autoplay, focus, trash, backdropFocus
    var id: String { rawValue }
}

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var colors
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var page: SettingsPage?
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var pagesOpen = false
    @State private var webURL = ""
    @State private var imageHoldOpen = false

    private var ink: MoonColors { app.settings.showsBackdrop(.settings) ? .media : colors }
    private var onBackdrop: Bool { app.settings.showsBackdrop(.settings) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                iconTiles
                Text("iOS 只能换成包里的预设图标。用照片做主屏幕图标需要系统不提供给普通 App 的能力，这里不做。")
                    .font(.system(size: 12))
                    .foregroundColor(ink.textDim)
                    .padding(.horizontal, 6)
                entries
                recordGroup
                sourcesGroup
                socialGroup
                backdropGroup
                playbackGroup
                gestureGroup
                Text("月光 1.1 · iOS\n不解析哔哩哔哩 playurl / WBI，不下载流媒体，不绕过 DRM。网页播放只用官方嵌入页。")
                    .font(.system(size: 12))
                    .foregroundColor(ink.textDim)
                    .padding(.horizontal, 8)
            }
            .padding(16)
            .padding(.bottom, 40)
        }
        .foregroundColor(ink.text)
        .background {
            if onBackdrop { PageBackdrop(page: .settings) } else { SystemGlassFill(dark: colors.dark) }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.root")
        .environment(\.colorScheme, onBackdrop ? .dark : (colors.dark ? .dark : .light))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }.accessibilityIdentifier("settings.done")
            }
        }
        .sheet(item: $page) { page in
            switch page {
            case .skins: ButtonSkinsView()
            case .icons: IconPickerView()
            case .autoplay: AutoplaySheet()
            case .focus: avatarFocus
            case .trash: TrashView()
            case .backdropFocus: backdropFocus
            }
        }
        .sheet(isPresented: $pagesOpen) { BackdropPagesSheet() }
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
        .confirmationDialog("图片停留", isPresented: $imageHoldOpen, titleVisibility: .visible) {
            ForEach(ImageHold.choices, id: \.0) { seconds, label in
                Button(label) { app.settings.imageHold = seconds; app.saveSettings() }
            }
            Button("取消", role: .cancel) {}
        }
        .moonOnChange(of: photoItem) { item in
            guard let item else { return }
            Task { await storeBackdrop(item, video: false) }
        }
        .moonOnChange(of: videoItem) { item in
            guard let item else { return }
            Task { await storeBackdrop(item, video: true) }
        }
    }

    private var iconTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(IconPreset.allCases) { preset in
                    Button { app.applyIcon(preset) } label: {
                        VStack(spacing: 6) {
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(ink.glassTint)
                                    .frame(width: 64, height: 64)
                                    .overlay(Image(systemName: "moon.fill").font(.system(size: 26)).foregroundColor(ink.accent))
                                if app.settings.iconPreset == preset.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(ink.accent)
                                        .background(Circle().fill(Color.black.opacity(0.35)))
                                        .offset(x: -4, y: -4)
                                }
                            }
                            Text(preset == .primary ? "月光（默认）" : preset.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(ink.text)
                                .multilineTextAlignment(.center)
                                .frame(width: 78)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("icon.tile.\(preset.rawValue)")
                }
            }
        }
    }

    private var entries: some View {
        GlassGroup(title: "功能", colors: ink) {
            nav("按键背景", "给圆环按键换照片或视频", "circle.grid.2x2", GlassTint.orange, "settings.skins") { page = .skins }
            nav("主屏幕图标", "预设图标", "app.badge", GlassTint.pink, "settings.icons") { page = .icons }
            nav("朋友圈播放", app.settings.momentAutoplay.label, "play.rectangle", GlassTint.green, "settings.autoplay") { page = .autoplay }
            nav("调整头像位置", "拖动、双指缩放", "person.crop.circle", GlassTint.blue, "settings.focus") { page = .focus }
            nav("最近删除", "碎纸机里的内容可以还原", "trash", GlassTint.red, "settings.trash") { page = .trash }
            toggleLine("后台刷新公开源", "系统决定什么时候跑", "arrow.clockwise", GlassTint.gray, "settings.refresh", binding(\.bgRefreshOn)) {
                BGRefresh.schedule(enabled: app.settings.bgRefreshOn)
            }
        }
    }

    private var recordGroup: some View {
        GlassGroup(title: "录屏", colors: ink) {
            GlassLine(title: app.recorder.recording ? "正在录屏" : "录屏", subtitle: "只录这个 App，不录麦克风。结束后放进库。", symbol: "record.circle", tint: GlassTint.red, colors: ink, showChevron: false)
            Button(app.recorder.recording ? "停止并保存" : "开始录屏") { app.toggleRecording() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(ink.text)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .accessibilityIdentifier("settings.record")
        }
    }

    private var sourcesGroup: some View {
        GlassGroup(title: "内容源", colors: ink) {
            ForEach(SourceCatalog.rows, id: \.key) { row in
                Toggle(isOn: Binding(
                    get: { app.settings.sourceOn(row.key) },
                    set: { app.settings.setSource(row.key, $0); app.saveSettings() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).foregroundColor(ink.text)
                        Text(row.subtitle).font(.system(size: 12)).foregroundColor(ink.textDim)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .accessibilityIdentifier("source.\(row.key)")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("网址").font(.system(size: 13, weight: .semibold)).foregroundColor(ink.textDim)
                TextField("https://", text: $webURL)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .moonGlass(ink, radius: 12)
                    .accessibilityIdentifier("source.webURL")
                Button("检查 robots.txt 并加入") {
                    let raw = webURL
                    webURL = ""
                    Task { await app.addWebSource(raw) }
                }
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("source.webAdd")
                ForEach(app.settings.webSources) { source in
                    Text(source.title.isEmpty ? source.url : source.title).font(.system(size: 12)).foregroundColor(ink.textDim).lineLimit(1)
                }
            }
            .padding(14)
            Button("刷新哔哩热榜") { Task { await app.loadHot() } }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .accessibilityIdentifier("source.hot")
            if let hotError = app.hotError {
                Text(hotError).font(.system(size: 12)).foregroundColor(ink.textDim).padding(.horizontal, 14).padding(.bottom, 8)
                    .accessibilityIdentifier("source.hotError")
            }
            SecureField("Pexels API Key", text: binding(\.pexelsKey)).padding(.horizontal, 14)
            SecureField("Pixabay API Key", text: binding(\.pixabayKey)).padding(.horizontal, 14)
            SecureField("YouTube Data API Key", text: binding(\.youtubeKey)).padding(.horizontal, 14)
            TextField("PeerTube 实例", text: binding(\.peertubeInstance))
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            Text("密钥留空则不请求。不会内置任何密钥。").font(.system(size: 12)).foregroundColor(ink.textDim).padding(.horizontal, 14).padding(.bottom, 8)
        }
        .accessibilityIdentifier("settings.sources")
    }

    private var socialGroup: some View {
        GlassGroup(title: "朋友圈与消息", colors: ink) {
            TextField("聊天服务器 https://", text: binding(\.chatServerURL))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .accessibilityIdentifier("settings.chatURL")
            Button(app.chatConnected ? "已连接" : "连接") { Task { await app.connectChat() } }
                .disabled(app.settings.chatServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 14)
                .accessibilityIdentifier("settings.chatConnect")
            nav("载入示例好友", "几个虚拟好友和一条月亮", "person.2", GlassTint.green, "settings.demo") { app.loadDemo() }
            nav("导出 social.json", "备份朋友圈", "square.and.arrow.up", GlassTint.blue, "settings.export") { exportURL = app.exportSocial() }
            nav("导入备份", "从 JSON 恢复", "square.and.arrow.down", GlassTint.orange, "settings.import") { importing = true }
        }
    }

    private var backdropGroup: some View {
        GlassGroup(title: "首页背景", colors: ink) {
            Picker("背景", selection: binding(\.backdropMode)) {
                ForEach(BackdropMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .accessibilityIdentifier("settings.backdrop")
            HStack(spacing: 10) {
                backdropTile(video: false)
                backdropTile(video: true)
            }
            .padding(.horizontal, 14)
            PhotosPicker(selection: $photoItem, matching: .images) {
                GlassLine(title: "更换照片", subtitle: "只替换这一个；视频会保留", symbol: "photo", tint: GlassTint.blue, colors: ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backdrop.replacePhoto")
            PhotosPicker(selection: $videoItem, matching: .videos) {
                GlassLine(title: "更换视频", subtitle: "只替换这一个；另一种会保留", symbol: "video", tint: GlassTint.purple, colors: ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backdrop.replaceVideo")
            Button {
                guard app.settings.backdropMode == .photo || app.settings.backdropMode == .video else {
                    app.showToast("先选择照片或视频")
                    return
                }
                let stored = app.settings.backdropMode == .video ? app.settings.backdropVideo : app.settings.backdropPhoto
                guard BackdropFiles.path(stored) != nil else { app.showToast("还没有选择文件"); return }
                page = .backdropFocus
            } label: {
                GlassLine(title: "调整位置", subtitle: "拖动 · 双指缩放，按全屏比例", symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: GlassTint.green, colors: ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backdrop.focus")
            Toggle(isOn: blurBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模糊并变暗").foregroundColor(ink.text)
                    Text("让内容和文字更清楚 · 照片和视频分别记住").font(.system(size: 12)).foregroundColor(ink.textDim)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .accessibilityIdentifier("backdrop.blur")
            Button { pagesOpen = true } label: {
                GlassLine(title: "应用到页面", subtitle: BackdropPages.summary(app.settings.backdropPages), symbol: "square.on.square", tint: GlassTint.orange, colors: ink)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("backdrop.pages")
            Toggle(isOn: binding(\.edgeToEdge)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("延伸到灵动岛").foregroundColor(ink.text)
                    Text("首页视频和页面背景可以铺到状态栏后面，按键仍留在安全区内。").font(.system(size: 12)).foregroundColor(ink.textDim)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.edge")
            Text("照片和视频各自保存（含位置与模糊设置），切换选项只改变使用哪一个；只有点垃圾桶才会删除 App 内的副本。")
                .font(.system(size: 12))
                .foregroundColor(ink.textDim)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }

    private var playbackGroup: some View {
        GlassGroup(title: "播放", colors: ink) {
            GlassLine(title: "视频显示", subtitle: "不裁内容；接近屏幕比例（裁切 <8%）时铺满 · 双指捏合单独切换", symbol: "rectangle.arrowtriangle.2.inward", tint: GlassTint.green, colors: ink, showChevron: false)
            Picker("视频显示", selection: binding(\.videoDisplay)) {
                ForEach(VideoDisplay.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .accessibilityIdentifier("settings.videoDisplay")
            Toggle(isOn: Binding(
                get: { app.settings.feedMuted },
                set: {
                    app.settings.feedMuted = $0
                    app.feedPlayer.isMuted = $0
                    app.feedPlayer.player.isMuted = $0
                    app.saveSettings()
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("静音").foregroundColor(ink.text)
                    Text("信息流默认静音").font(.system(size: 12)).foregroundColor(ink.textDim)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.mute")
            Toggle(isOn: Binding(
                get: { app.settings.feedLoop },
                set: {
                    app.settings.feedLoop = $0
                    app.feedPlayer.loop = $0
                    app.saveSettings()
                }
            )) {
                labeled("循环播放", "视频播完重播", "repeat", GlassTint.green)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.loop")
            Toggle(isOn: Binding(
                get: { app.settings.feedShuffle },
                set: {
                    app.settings.feedShuffle = $0
                    app.applyFeedOrder()
                    app.saveSettings()
                }
            )) {
                labeled("随机顺序", "信息流打乱", "shuffle", GlassTint.purple)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.shuffle")
            Button { imageHoldOpen = true } label: {
                HStack {
                    labeled("图片停留", "不自动切换 · 滑动换下一张", "photo", GlassTint.blue)
                    Text(ImageHold.label(app.settings.imageHold)).font(.system(size: 14)).foregroundColor(ink.textDim)
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(ink.textDim)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.imageHold")
            Toggle(isOn: Binding(
                get: { app.settings.rememberPlace },
                set: {
                    app.settings.rememberPlace = $0
                    if $0 { app.rememberPlace(seconds: app.feedPlayer.currentSeconds) }
                    app.saveSettings()
                }
            )) {
                labeled("记住位置", "从上次的位置继续", "bolt.fill", GlassTint.orange)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.remember")
            Toggle(isOn: binding(\.resumeOnReturn)) {
                labeled("返回时继续播放", "离开 App 一律暂停；回来时只继续之前在播的", "bolt.horizontal", GlassTint.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.resume")
            Toggle(isOn: binding(\.revealBlur)) {
                labeled("模糊渐显动画", "内容出现时由模糊变清晰", "sparkles", GlassTint.purple)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.reveal")
            Picker("渐显速度", selection: Binding(
                get: { app.settings.reveal },
                set: { app.settings.revealSpeed = $0.rawValue; app.saveSettings() }
            )) {
                ForEach(RevealPace.allCases) { pace in
                    Text(pace.label).tag(pace)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .accessibilityIdentifier("settings.revealSpeed")
            Toggle(isOn: binding(\.progressLine)) {
                labeled("播放进度线", "沉浸播放时底部细线", "timeline.selection", GlassTint.blue)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .accessibilityIdentifier("settings.progress")
            Toggle("按键自动隐藏", isOn: binding(\.chromeAutoHide))
                .padding(.horizontal, 14)
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
            .padding(.horizontal, 14)
            if hideChoice.wrappedValue == 0 {
                Slider(value: Binding(
                    get: { Double(app.settings.chromeHideSeconds) },
                    set: { app.settings.chromeHideSeconds = ChromeTiming.clamp(Float($0.rounded())); app.saveSettings() }
                ), in: 1...30, step: 1)
                .padding(.horizontal, 14)
                Text(String(format: "%.0f 秒", app.settings.chromeHideSeconds)).font(.caption).foregroundColor(ink.textDim).padding(.horizontal, 14)
            }
            Text("视频播放时收起首页按键和底栏。点一下画面它们会以系统玻璃淡入，安静一段时间后再消失。")
                .font(.system(size: 12)).foregroundColor(ink.textDim).padding(.horizontal, 14)
            Toggle("低电量不自动播放", isOn: binding(\.pauseOnLowPower))
                .padding(.horizontal, 14)
                .accessibilityIdentifier("settings.lowPower")
            Toggle("蜂窝网络不自动播放", isOn: binding(\.autoplayWifiOnly))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .accessibilityIdentifier("settings.wifiOnly")
        }
    }

    private var gestureGroup: some View {
        GlassGroup(title: "手势", colors: ink) {
            Picker("长按菜单", selection: binding(\.menuSelect)) {
                ForEach(MenuSelect.choices, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Toggle("水滴选择", isOn: binding(\.dropSelect))
                .padding(.horizontal, 14)
                .accessibilityIdentifier("settings.drop")
            Text("默认关闭。长按只弹出圆环，点按键才会执行。打开后玻璃水滴跟着手指，松手落到的按键会执行。")
                .font(.system(size: 12)).foregroundColor(ink.textDim).padding(.horizontal, 14)
            Toggle("底栏滑块", isOn: binding(\.tabLens))
                .padding(.horizontal, 14)
                .accessibilityIdentifier("settings.tabLens")
            Text("打开时，按住底栏拖动可以换页。拍摄只是中间的按钮，不会变成一页。")
                .font(.system(size: 12)).foregroundColor(ink.textDim).padding(.horizontal, 14)
            Picker("主题", selection: binding(\.theme)) {
                ForEach(ThemeMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Picker("菜单背景", selection: binding(\.menuBackdrop)) {
                ForEach(MenuBackdrop.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            Toggle("定时长按", isOn: binding(\.timedOn)).padding(.horizontal, 14)
            if app.settings.timedOn {
                Text(String(format: "触发 %.1f 秒", app.settings.timedSeconds))
                    .font(.system(size: 12)).foregroundColor(ink.textDim).padding(.horizontal, 14)
                Slider(value: Binding(
                    get: { Double(app.settings.timedSeconds) },
                    set: { app.settings.timedSeconds = HoldConfig.clampSeconds(Float($0)); app.saveSettings() }
                ), in: 3...15).padding(.horizontal, 14)
            }
            HStack {
                Text("慢")
                Slider(value: Binding(
                    get: { Double(app.settings.starSpeed) },
                    set: { app.settings.starSpeed = RingMotion.clampSpeed(Float($0)); app.saveSettings() }
                ), in: 0.5...2)
                Text("快")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Text("圆环速度同时作用在星轨和旋转上。").font(.system(size: 12)).foregroundColor(ink.textDim).padding(.horizontal, 14).padding(.bottom, 8)
        }
    }

    private func backdropTile(video: Bool) -> some View {
        let stored = video ? app.settings.backdropVideo : app.settings.backdropPhoto
        let file = BackdropFiles.path(stored)
        let active = app.settings.backdropMode == (video ? .video : .photo)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let file, video {
                LoopFilm(ref: file).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if let file, let image = UIImage(contentsOfFile: file) {
                Image(uiImage: image).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: video ? "video" : "photo").font(.system(size: 22)).foregroundColor(ink.textDim)
                    Text(video ? "视频 · 未选择" : "照片 · 未选择").font(.system(size: 12)).foregroundColor(ink.textDim)
                }
            }
            if active, file != nil {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                    Text(video ? "视频 · 使用中" : "照片 · 使用中")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
            }
            if file != nil {
                Button { app.deleteBackdrop(video: video) } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(7)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .padding(6)
                .accessibilityIdentifier(video ? "backdrop.video.trash" : "backdrop.photo.trash")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard file != nil else { return }
            app.settings.backdropMode = video ? .video : .photo
            app.saveSettings()
        }
        .accessibilityIdentifier(video ? "backdrop.video" : "backdrop.photo")
    }

    private var blurBinding: Binding<Bool> {
        Binding(
            get: { app.settings.backdropMode == .video ? app.settings.backdropVideoBlur : app.settings.backdropPhotoBlur },
            set: {
                if app.settings.backdropMode == .video { app.settings.backdropVideoBlur = $0 }
                else { app.settings.backdropPhotoBlur = $0 }
                app.saveSettings()
            }
        )
    }

    private var avatarFocus: some View {
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
    }

    private var backdropFocus: some View {
        let video = app.settings.backdropMode == .video
        let stored = video ? app.settings.backdropVideo : app.settings.backdropPhoto
        return FocusEditor(
            path: BackdropFiles.path(stored),
            video: video,
            focus: Binding(
                get: { video ? app.settings.backdropVideoFocus : app.settings.backdropPhotoFocus },
                set: { value in
                    let next = value.clamped()
                    if video { app.settings.backdropVideoFocus = next } else { app.settings.backdropPhotoFocus = next }
                    app.saveSettings()
                }
            )
        )
    }

    private func storeBackdrop(_ item: PhotosPickerItem, video: Bool) async {
        guard let saved = await PickedMedia.load(item, folder: MediaStore.backdrop) else {
            await MainActor.run { app.showToast("没能保存这个背景"); photoItem = nil; videoItem = nil }
            return
        }
        await MainActor.run {
            if video {
                if saved.video {
                    if let old = app.settings.backdropVideo { MediaStore.remove(stored: old, folder: MediaStore.backdrop) }
                    app.settings.backdropVideo = saved.name
                    app.settings.backdropMode = .video
                    app.showToast("已换上视频背景")
                } else { app.showToast("请选一段视频") }
            } else if !saved.video {
                if let old = app.settings.backdropPhoto { MediaStore.remove(stored: old, folder: MediaStore.backdrop) }
                app.settings.backdropPhoto = saved.name
                app.settings.backdropMode = .photo
                app.showToast("已换上照片背景")
            } else { app.showToast("请选一张照片") }
            app.saveSettings()
            photoItem = nil
            videoItem = nil
        }
    }

    private func labeled(_ title: String, _ subtitle: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            GlassIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundColor(ink.text)
                Text(subtitle).font(.system(size: 12)).foregroundColor(ink.textDim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func nav(_ title: String, _ subtitle: String, _ symbol: String, _ tint: Color, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlassLine(title: title, subtitle: subtitle, symbol: symbol, tint: tint, colors: ink)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func toggleLine(_ title: String, _ subtitle: String, _ symbol: String, _ tint: Color, _ id: String, _ value: Binding<Bool>, extra: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; extra() })) {
            HStack(spacing: 12) {
                GlassIcon(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(ink.text)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(ink.textDim)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
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
                    if ChromeTiming.presets.contains(Float(seconds)) { app.settings.chromeHideSeconds = 8 }
                } else {
                    app.settings.chromeHideSeconds = ChromeTiming.clamp(Float(choice))
                }
                app.saveSettings()
            }
        )
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: keyPath] }, set: { app.settings[keyPath: keyPath] = $0; app.saveSettings() })
    }
}
