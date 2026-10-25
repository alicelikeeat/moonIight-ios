import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SkinBadge: View {
    var systemImage: String
    var key: String?
    var title: String
    var skins: [String: ButtonSkin]
    var ink: Color

    var body: some View {
        let resolved = ButtonSkins.resolve(key: key, title: title, skins: skins)
        let file = resolved.flatMap { SkinFiles.path($0.skin.path) }
        ZStack {
            if let resolved, let file {
                if resolved.skin.video {
                    SkinLoop(path: file, slot: resolved.id.rawValue)
                } else if let image = UIImage(contentsOfFile: file) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: systemImage).font(.system(size: 18, weight: .medium)).foregroundColor(ink)
                }
            } else {
                Image(systemName: systemImage).font(.system(size: 18, weight: .medium)).foregroundColor(ink)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(Circle())
    }
}

private struct SkinLoop: View {
    var path: String
    var slot: String
    @StateObject private var session = PlayerSession()
    @State private var playing = false

    var body: some View {
        Group {
            if playing {
                PlayerLayerView(player: session.player, gravity: .resizeAspectFill)
            } else {
                Image(systemName: "play.fill").font(.system(size: 14)).foregroundColor(.white)
            }
        }
        .onAppear {
            let allowed = SkinStage.shared.claim(slot)
            playing = allowed
            guard allowed else { return }
            session.loop = true
            session.load(url: URL(fileURLWithPath: path), autoplay: true, muted: true)
        }
        .onDisappear {
            SkinStage.shared.release(slot)
            session.pause()
        }
    }
}

struct LoopFilm: View {
    var ref: String
    @StateObject private var session = PlayerSession()

    var body: some View {
        PlayerLayerView(player: session.player, gravity: .resizeAspectFill)
            .onAppear {
                session.loop = true
                let url = ref.hasPrefix("http") ? URL(string: ref) : URL(fileURLWithPath: ref)
                session.load(url: url, autoplay: true, muted: true)
            }
            .onDisappear { session.pause() }
    }
}

struct RecordPill: View {
    @ObservedObject var recorder: RecorderModel
    var stop: () -> Void

    var body: some View {
        Group {
            if recorder.recording {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("正在录制").font(.system(size: 13, weight: .semibold))
                    Button("停止") {
                        guard !PressGate.suppressTap else { return }
                        stop()
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("record.pill")
                .allowsHitTesting(true)
            }
        }
        .allowsHitTesting(recorder.recording)
    }
}

struct ShredderCurtain: View {
    var title: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).lineLimit(1)
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(height: 14)
                    .padding(.horizontal, CGFloat(i % 2 == 0 ? 28 : 48))
                    .rotationEffect(.degrees(i % 2 == 0 ? -8 : 7))
                    .offset(x: i % 2 == 0 ? -24 : 24)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: 280)
        .accessibilityIdentifier("shredder.root")
        .accessibilityLabel("碎纸机")
        .allowsHitTesting(false)
    }
}

struct ButtonSkinsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<String>()
    @State private var item: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("29 个按键")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .accessibilityIdentifier("skins.count")
                    Text("一张图或一段视频可以套在一个、几个或全部按键上。同时播放的视频最多 4 个，其余停在画面上。")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.72))
                    MediaPreviewFrame(
                        file: pendingSkin.flatMap { SkinFiles.path($0.path) },
                        video: pendingSkin?.video == true,
                        active: pendingSkin != nil,
                        symbol: "photo",
                        empty: "未选择",
                        caption: pendingSkin?.video == true ? "视频" : "图片",
                        colors: .media,
                        badge: GlassTint.orange,
                        accessibilityID: "skins.preview"
                    )
                    .frame(maxWidth: 160)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PhotosPicker(selection: $item, matching: .any(of: [.images, .videos])) {
                        Label("选图片或视频", systemImage: "photo.on.rectangle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .moonGlass(MoonColors.media, radius: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("skins.pick")
                    HStack(spacing: 8) {
                        skinAction("用在选中的", "skins.picked") { assign(ButtonSkinID.allCases.filter { picked.contains($0.rawValue) }) }
                        skinAction("用在全部 29 个", "skins.all") { assign(ButtonSkinID.allCases) }
                        skinAction("清除选中", "skins.clear") {
                            var skins = app.settings.buttonSkins
                            ButtonSkins.clear(ButtonSkinID.allCases.filter { picked.contains($0.rawValue) }, skins: &skins)
                            app.settings.buttonSkins = skins
                            app.saveSettings()
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                        ForEach(ButtonSkinID.allCases) { id in
                            Button {
                                if picked.contains(id.rawValue) { picked.remove(id.rawValue) } else { picked.insert(id.rawValue) }
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack(alignment: .topTrailing) {
                                        SkinBadge(systemImage: id.symbol, key: id.rawValue, title: id.title, skins: app.settings.buttonSkins, ink: .white)
                                            .frame(width: 72, height: 72)
                                            .moonDisc(overMedia: true)
                                        if picked.contains(id.rawValue) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(.white)
                                                .background(Circle().fill(Color.black.opacity(0.45)))
                                                .offset(x: 4, y: -4)
                                        }
                                    }
                                    Text(id.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                    if app.settings.buttonSkins[id.rawValue] != nil {
                                        Text(app.settings.buttonSkins[id.rawValue]?.video == true ? "视频" : "图片")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("skin.\(id.rawValue)")
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background {
                ZStack {
                    Color.black
                    SystemGlassFill(dark: true)
                }
                .ignoresSafeArea()
            }
            .navigationTitle("按键背景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .environment(\.colorScheme, .dark)
            .foregroundColor(.white)
            .accessibilityIdentifier("skins.root")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundColor(.white)
                        .accessibilityIdentifier("skins.done")
                }
            }
            .moonOnChange(of: item) { newItem in
                guard let newItem else { return }
                Task { await importSkin(newItem) }
            }
            .modifier(DarkSheet())
        }
    }

    private func skinAction(_ title: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .moonGlass(MoonColors.media, radius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func assign(_ ids: [ButtonSkinID]) {
        guard let any = pendingSkin ?? app.settings.buttonSkins.values.first else {
            app.showToast("先选一张图片或一段视频")
            return
        }
        var skins = app.settings.buttonSkins
        ButtonSkins.assign(ids, skin: any, into: &skins)
        app.settings.buttonSkins = skins
        app.saveSettings()
        app.showToast(ids.count == ButtonSkinID.allCases.count ? "已套到全部 29 个按键" : "已套到 \(ids.count) 个按键")
    }

    @State private var pendingSkin: ButtonSkin?

    private func importSkin(_ item: PhotosPickerItem) async {
        let saved = await PickedMedia.load(item, folder: MediaStore.skins).map { ButtonSkin(path: $0.name, video: $0.video) }
        await MainActor.run {
            if let saved {
                pendingSkin = saved
                app.showToast(saved.video ? "已选一段视频" : "已选一张图片")
            } else {
                app.showToast("没能保存这个背景")
            }
            self.item = nil
        }
    }
}

private struct DarkSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationBackground {
                ZStack {
                    Color.black
                    SystemGlassFill(dark: true)
                }
            }
        } else {
            content
        }
    }
}

struct IconPickerView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("只能换成包里的预设。不能用一张自己的照片当主屏幕图标。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                ForEach(IconPreset.allCases) { preset in
                    Button {
                        app.applyIcon(preset)
                    } label: {
                        HStack {
                            Text(preset.title)
                            Spacer()
                            if app.settings.iconPreset == preset.rawValue {
                                Image(systemName: "checkmark")
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("icon.\(preset.rawValue)")
                }
                Spacer()
            }
            .padding(16)
            .navigationTitle("主屏幕图标")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("icons.root")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("icons.done")
                }
            }
        }
    }
}

struct AutoplaySheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(MomentAutoplay.allCases, id: \.self) { mode in
                    Button {
                        app.settings.momentAutoplay = mode
                        app.saveSettings()
                    } label: {
                        HStack {
                            Text(mode.label)
                            Spacer()
                            if app.settings.momentAutoplay == mode { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("autoplay.\(mode.rawValue)")
                }
                if app.settings.momentAutoplay == .picked {
                    let videos = app.social.moments.filter { $0.attachments.contains { $0.kind == .video } }
                    if videos.isEmpty {
                        Text("还没有带视频的动态。先载入示例或发一条带视频的动态。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ForEach(videos) { moment in
                        Button {
                            var ids = app.settings.momentAutoplayIds
                            if let i = ids.firstIndex(of: moment.id) { ids.remove(at: i) } else { ids.append(moment.id) }
                            app.settings.momentAutoplayIds = ids
                            app.saveSettings()
                        } label: {
                            HStack {
                                Text(moment.text.isEmpty ? "视频动态" : moment.text).lineLimit(1)
                                Spacer()
                                if app.settings.momentAutoplayIds.contains(moment.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("朋友圈播放")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("moment.autoplay")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("autoplay.done")
                }
            }
        }
    }
}

struct FocusEditor: View {
    var path: String?
    var video: Bool
    @Binding var focus: MediaFocus
    @Environment(\.dismiss) private var dismiss
    @State private var dragStart = MediaFocus()

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black
                    media
                        .scaleEffect(CGFloat(focus.scale))
                        .offset(
                            x: CGFloat(focus.x - 0.5) * geo.size.width,
                            y: CGFloat(focus.y - 0.5) * geo.size.height
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let dx = Float(value.translation.width / max(geo.size.width, 1))
                                    let dy = Float(value.translation.height / max(geo.size.height, 1))
                                    focus = MediaFocus(x: dragStart.x + dx, y: dragStart.y + dy, scale: dragStart.scale).clamped()
                                }
                                .onEnded { _ in dragStart = focus }
                        )
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    focus = MediaFocus(x: dragStart.x, y: dragStart.y, scale: dragStart.scale * Float(value)).clamped()
                                }
                                .onEnded { _ in dragStart = focus }
                        )
                }
            }
            .navigationTitle("调整位置")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("focus.editor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("focus.done")
                }
            }
            .onAppear { dragStart = focus }
        }
    }

    @ViewBuilder private var media: some View {
        if let path, video, FileManager.default.fileExists(atPath: path) {
            LoopFilm(ref: path)
        } else if let path, let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ArtPlate(seed: 1)
        }
    }
}

struct TrashView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if app.trash.isEmpty {
                    Text("最近删除是空的")
                        .foregroundColor(.secondary)
                        .accessibilityIdentifier("trash.empty")
                } else {
                    List {
                        ForEach(app.trash) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).lineLimit(1)
                                    Text(item.kind == .entry ? "库" : "动态").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("还原") { app.restoreTrash(item.id) }
                                Button("清除") { app.forgetTrash(item.id) }
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("最近删除")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("trash.root")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("trash.done")
                }
                if !app.trash.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("清空") { app.emptyTrash() }
                    }
                }
            }
        }
    }
}
