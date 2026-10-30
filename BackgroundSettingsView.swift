import PhotosUI
import SwiftUI

struct BackgroundSettingsView: View {
    @EnvironmentObject private var store: BackgroundStore
    @State private var cleanConfirmation = false
    @State private var buttonTarget = BackgroundTarget.allButtons
    @State private var buttonDraft = ButtonBackgroundPlaylist()
    @State private var buttonSelections: [PhotosPickerItem] = []
    @State private var buttonImporting = false
    @State private var buttonImportError: String?
    @AppStorage("moonlight.glass.buttonSize") private var glassButtonSize = GlassSurfaceSize.balanced.rawValue
    @AppStorage("moonlight.glass.bannerSize") private var glassBannerSize = GlassSurfaceSize.balanced.rawValue
    @AppStorage("moonlight.glass.panelSize") private var glassPanelSize = GlassSurfaceSize.balanced.rawValue
    @AppStorage("moonlight.blindMode") private var blindMode = false
    @AppStorage("moonlight.button.tint") private var buttonTint = "moon"
    @AppStorage("moonlight.button.tint.red") private var customTintRed = 0.55
    @AppStorage("moonlight.button.tint.green") private var customTintGreen = 0.50
    @AppStorage("moonlight.button.tint.blue") private var customTintBlue = 0.27
    var body: some View {
        List {
            Section {
                Label("图片和视频都可用于页面、玻璃按键与个人资料。", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline)
                Text("页面背景、玻璃按键和播放顺序在这里统一管理。通用背景会应用到未单独设置的位置，每个位置仍可覆盖通用设置或恢复跟随。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("盲盒模式") {
                Toggle("隐藏按键内容", isOn: blindModeBinding)
                Text("开启后，底栏按键的图标、文字和选中提示都会隐去；右上角连续点击三次才会出现退出按钮。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("按键互动颜色") {
                Picker("主色", selection: $buttonTint) {
                    Text("月光金").tag("moon")
                    Text("蓝色").tag("blue")
                    Text("粉色").tag("pink")
                    Text("薄荷").tag("mint")
                    Text("橙色").tag("orange")
                    Text("自定义").tag("custom")
                }
                if buttonTint == "custom" {
                    ColorPicker("自定义颜色", selection: customTintBinding, supportsOpacity: false)
                }
                Text("应用自有按键会在互动时缩放、提亮，并采用此颜色。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("玻璃尺寸") {
                Picker("按键与圆环", selection: $glassButtonSize) {
                    ForEach(GlassSurfaceSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("横幅与卡片", selection: $glassBannerSize) {
                    ForEach(GlassSurfaceSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("弹出面板", selection: $glassPanelSize) {
                    ForEach(GlassSurfaceSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("按键会保留至少 44 pt 的触控范围；横幅、卡片与面板使用同一套圆角、留白和玻璃层级，以避免组件相互遮挡。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(BackgroundTarget.sections, id: \.self) { section in
                Section(section) {
                    ForEach(BackgroundTarget.allCases.filter { $0.section == section }) { target in
                        NavigationLink {
                            BackgroundEditorView(target: target)
                        } label: {
                            HStack(spacing: 12) {
                                BackgroundAssetThumbnail(asset: store.asset(store.resolved(target)))
                                    .frame(width: 42, height: 42).clipShape(RoundedRectangle(cornerRadius: target.isButton || target == .avatar ? 21 : 10))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(target.title).foregroundStyle(.primary)
                                    Text(description(target)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 3)
                        }.accessibilityIdentifier("background-target-\(target.rawValue)")
                    }
                }
            }
            Section("按键背景与播放") {
                Picker("应用到", selection: $buttonTarget) {
                    ForEach(BackgroundTarget.allCases.filter(\.isButton)) { target in
                        Text(target.section + " · " + target.title).tag(target)
                    }
                }
                Picker("播放模式", selection: buttonDraftBinding.mode) {
                    ForEach(BackgroundPlaybackMode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("background-playback-mode")
                Stepper("每项 \(Int(buttonDraft.interval)) 秒", value: buttonDraftBinding.interval, in: 3...120, step: 3)
                    .disabled(buttonDraft.mode == .fixed)
                Text("已选 \(buttonDraft.assetIDs.count) 项 · \(buttonDraft.mode.title)")
                    .accessibilityIdentifier("background-playback-summary")
                Text("图片和视频共用同一套队列：顺序、洗牌或随机播放。视频静音循环；离开页面或进入后台会自动停止计时。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("已选按键背景 · 可拖动排序") {
                if buttonDraft.assetIDs.isEmpty {
                    Text("从下方背景素材中选择图片或视频后，会出现在这里。")
                        .foregroundStyle(.secondary)
                }
                ForEach(buttonDraft.assetIDs, id: \.self) { id in
                    if let asset = store.assets.first(where: { $0.id == id }) {
                        HStack {
                            buttonThumbnail(asset)
                            Text(asset.isVideo ? "视频背景" : "图片背景")
                            Spacer()
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { from, to in
                    var value = buttonDraft
                    value.assetIDs.move(fromOffsets: from, toOffset: to)
                    buttonDraftBinding.wrappedValue = value
                }
                .onDelete { offsets in
                    var value = buttonDraft
                    value.assetIDs.remove(atOffsets: offsets)
                    buttonDraftBinding.wrappedValue = value
                }
            }
            Section("按键背景素材") {
                PhotosPicker(selection: $buttonSelections, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                    Label("添加图片或视频", systemImage: "plus")
                }
                .disabled(buttonImporting)
                if buttonImporting { ProgressView("正在添加…") }
                if let buttonImportError { Text(buttonImportError).foregroundStyle(.red).font(.caption) }
                if store.assets.isEmpty {
                    Text("还没有背景素材。添加后可供页面、按键、长按圆环和横幅重复使用。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.assets) { asset in
                    Button {
                        var value = buttonDraft
                        if value.assetIDs.contains(asset.id) { value.assetIDs.removeAll { $0 == asset.id } }
                        else { value.assetIDs.append(asset.id) }
                        buttonDraftBinding.wrappedValue = value
                    } label: {
                        HStack {
                            buttonThumbnail(asset)
                            Text(asset.isVideo ? "视频背景" : "图片背景")
                            Spacer()
                            Image(systemName: buttonDraft.assetIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("playlist-asset-\(asset.id)")
                    .accessibilityValue(buttonDraft.assetIDs.contains(asset.id) ? "已选择" : "未选择")
                }
                Button("恢复跟随通用播放设置") {
                    store.resetPlaylist(for: buttonTarget)
                    buttonDraft = store.playlist(for: buttonTarget) ?? ButtonBackgroundPlaylist()
                }
            }
            Section("媒体管理") {
                Button { cleanConfirmation = true } label: {
                    Label("清理未使用背景（\(store.unusedCount)）", systemImage: "sparkles")
                }.disabled(store.unusedCount == 0)
                Text("替换或恢复默认时，原媒体仍保留在背景库里，可再次使用。清理只移除当前没有任何位置使用的背景。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("背景与按键").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("background-settings")
        .toolbar { EditButton() }
        .scrollContentBackground(.hidden).pageBackground(.settings)
        .confirmationDialog("清理 \(store.unusedCount) 个未使用背景？", isPresented: $cleanConfirmation, titleVisibility: .visible) {
            Button("清理未使用", role: .destructive) { store.cleanUnused() }
            Button("取消", role: .cancel) {}
        }
        .task(id: buttonTarget) {
            buttonDraft = store.playlist(for: buttonTarget) ?? ButtonBackgroundPlaylist()
        }
        .task(id: buttonSelections) {
            guard !buttonSelections.isEmpty else { return }
            buttonImporting = true; buttonImportError = nil
            for item in buttonSelections {
                do {
                    let asset = try await store.importSelection(item, for: buttonTarget, apply: false)
                    var value = buttonDraft
                    if !value.assetIDs.contains(asset.id) { value.assetIDs.append(asset.id) }
                    buttonDraftBinding.wrappedValue = value
                } catch {
                    buttonImportError = error.localizedDescription
                }
            }
            buttonSelections = []; buttonImporting = false
        }
    }

    private func description(_ target: BackgroundTarget) -> String {
        guard let config = store.resolved(target), let asset = store.asset(config) else { return target.fallback == nil ? "默认外观" : "跟随通用外观" }
        let inherited = store.configurations[target.rawValue] == nil
        return (asset.isVideo ? "视频 · 静音循环" : "图片") + (inherited ? " · 跟随通用" : " · 单独设置")
    }
    private func buttonThumbnail(_ asset: BackgroundAsset) -> some View {
        BackgroundAssetThumbnail(asset: asset).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private var blindModeBinding: Binding<Bool> {
        Binding(get: { blindMode }, set: { blindMode = $0 })
    }
    private var customTintBinding: Binding<Color> {
        Binding {
            Color(red: customTintRed, green: customTintGreen, blue: customTintBlue)
        } set: { color in
            let value = UIColor(color)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            if value.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                customTintRed = Double(red); customTintGreen = Double(green); customTintBlue = Double(blue)
                buttonTint = "custom"
            }
        }
    }
    private var buttonDraftBinding: Binding<ButtonBackgroundPlaylist> {
        Binding(get: { buttonDraft }, set: { value in buttonDraft = value; store.setPlaylist(value, for: buttonTarget) })
    }
}

struct BackgroundAssetThumbnail: View {
    @EnvironmentObject private var store: BackgroundStore
    let asset: BackgroundAsset?
    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let asset, let image = store.image(for: asset, thumbnail: true) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: asset?.isVideo == true ? "video.fill" : "photo").foregroundStyle(.secondary) }
            if asset?.isVideo == true {
                Image(systemName: "play.fill").font(.caption2).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.45), in: Circle())
            }
        }.clipped()
    }
}

struct BackgroundEditorView: View {
    @EnvironmentObject private var store: BackgroundStore
    let target: BackgroundTarget
    @State private var selection: PhotosPickerItem?
    @State private var draft: BackgroundConfiguration?
    @State private var importing = false
    @State private var importError: String?
    @State private var cropping = false
    @State private var applying = false

    var body: some View {
        Form {
            Section {
                ZStack {
                    Color(uiColor: .tertiarySystemGroupedBackground)
                    if let draft { BackgroundMediaLayer(configuration: draft) }
                    if target.isButton || target == .avatar {
                        Image(systemName: target == .avatar ? "person.fill" : "moon.stars.fill")
                            .font(.system(size: 36, weight: .medium)).foregroundStyle(draft?.veil.foreground ?? Color.primary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(target.title).font(.title2.bold())
                            Text("这里是文字与背景的预览").font(.subheadline)
                            Spacer()
                            if target.rawValue.hasPrefix("page.") {
                                RoundedRectangle(cornerRadius: 16).fill(.regularMaterial).frame(height: 46)
                            }
                        }.foregroundStyle(.primary).padding(20)
                    }
                }
                .frame(height: target.isButton || target == .avatar ? 150 : 220)
                .frame(maxWidth: target.isButton || target == .avatar ? 150 : .infinity)
                .clipShape(RoundedRectangle(cornerRadius: target.isButton || target == .avatar ? 75 : 22))
                .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                HStack(spacing: 16) {
                    PhotosPicker(selection: $selection, matching: .images) { Label("选图片", systemImage: "photo") }
                    Spacer()
                    PhotosPicker(selection: $selection, matching: .videos) { Label("选视频", systemImage: "video") }
                }.buttonStyle(.borderless).disabled(importing)
                if let draft, let asset = store.asset(draft) {
                    Text(asset.isVideo ? "视频背景 · 静音循环" : "图片背景")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("background-media-kind")
                }
                if importing { ProgressView("正在导入并生成预览…") }
                if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            }
            if let draft {
                Section("画面与可读性") {
                    Button { cropping = true } label: { Label("调整画面 · 拖动与双指缩放", systemImage: "crop.rotate") }
                    HStack { Text("缩放"); Spacer(); Text("\(Int(draft.scale * 100))%").foregroundStyle(.secondary) }
                    Slider(value: numberBinding(\.scale), in: 1...4)
                    Picker("遮罩", selection: Binding(get: { self.draft?.veil ?? .theme }, set: { value in
                        guard var config = self.draft else { return }; config.veil = value; update(config)
                    })) { ForEach(BackgroundVeil.allCases) { Text($0.title).tag($0) } }
                    HStack { Text("遮罩强度"); Spacer(); Text("\(Int(draft.opacity * 100))%").foregroundStyle(.secondary) }
                    Slider(value: numberBinding(\.opacity), in: 0...0.95)
                    Text("用遮罩保持文字清晰。视频静音循环；减少动态效果或低电量模式下显示封面。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button { applying = true } label: { Label("应用到其他位置…", systemImage: "square.on.square") }
                    Button(target.fallback == nil ? "恢复默认外观" : "恢复跟随通用外观", role: .destructive) {
                        store.reset(target); self.draft = store.resolved(target)
                    }
                }
            }
            if !store.assets.isEmpty {
                Section("已有背景 · 点击复用") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(store.assets) { asset in
                                Button {
                                    store.use(asset, for: target); draft = store.resolved(target)
                                } label: {
                                    BackgroundAssetThumbnail(asset: asset).frame(width: 76, height: 76)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(draft?.assetID == asset.id ? Color.accentColor : .clear, lineWidth: 3))
                                }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                    .frame(minWidth: 76, minHeight: 76)
                    .accessibilityLabel(asset.isVideo ? "使用这个视频背景" : "使用这个图片背景")
                            }
                        }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("background-assets-scroll")
                }
            }
        }
        }
        // Floating navigation must never cover the final reusable asset row.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 104).allowsHitTesting(false)
        }
        .navigationTitle(target.title).navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).pageBackground(.settings)
        .onAppear { draft = store.resolved(target) }
        .task(id: selection) {
            guard let selection else { return }
            importing = true; importError = nil
            do { try await store.importSelection(selection, for: target); draft = store.resolved(target) }
            catch { importError = error.localizedDescription }
            importing = false
            self.selection = nil
        }
        .sheet(isPresented: $cropping) {
            if let draft { BackgroundCropView(target: target, initial: draft) { update($0) } }
        }
        .sheet(isPresented: $applying) {
            if let draft { BackgroundTargetPicker(configuration: draft, initial: target) }
        }
    }

    private func update(_ config: BackgroundConfiguration) { var value = config; value.clamp(); draft = value; store.set(value, for: target) }
    private func numberBinding(_ keyPath: WritableKeyPath<BackgroundConfiguration, Double>) -> Binding<Double> {
        Binding(get: { draft?[keyPath: keyPath] ?? 0 }, set: { number in
            guard var config = draft else { return }; config[keyPath: keyPath] = number; update(config)
        })
    }
}

private struct BackgroundCropView: View {
    @Environment(\.dismiss) private var dismiss
    let target: BackgroundTarget
    let onSave: (BackgroundConfiguration) -> Void
    @State private var draft: BackgroundConfiguration
    @State private var base: BackgroundConfiguration
    init(target: BackgroundTarget, initial: BackgroundConfiguration, onSave: @escaping (BackgroundConfiguration) -> Void) {
        self.target = target; self.onSave = onSave
        _draft = State(initialValue: initial); _base = State(initialValue: initial)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    let circle = target.isButton || target == .avatar
                    let width = min(geometry.size.width - 24, circle ? 300 : 430)
                    let height = circle ? width : target == .cover ? width / 2 : min(geometry.size.height - 20, width * 16 / 9)
                    ZStack {
                        BackgroundMediaLayer(configuration: draft)
                        RoundedRectangle(cornerRadius: circle ? width / 2 : 16).strokeBorder(.white.opacity(0.7), lineWidth: 1)
                    }
                    .frame(width: width, height: height)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: circle ? width / 2 : 16))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        draft.x = base.x + value.translation.width / width
                        draft.y = base.y + value.translation.height / height
                        draft.clamp()
                    }.onEnded { _ in base = draft })
                    .simultaneousGesture(MagnificationGesture().onChanged { value in
                        draft.scale = base.scale * value; draft.clamp()
                    }.onEnded { _ in base = draft })
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                Text("双指放大后拖动画面，调整显示的位置。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                Button("还原画面") { draft.scale = 1; draft.x = 0; draft.y = 0; base = draft }.padding(.bottom, 16)
            }
            .navigationTitle("调整画面").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { onSave(draft); dismiss() } }
            }
        }
    }
}

private struct BackgroundTargetPicker: View {
    @EnvironmentObject private var store: BackgroundStore
    @Environment(\.dismiss) private var dismiss
    let configuration: BackgroundConfiguration
    @State private var selected: Set<BackgroundTarget>
    init(configuration: BackgroundConfiguration, initial: BackgroundTarget) { self.configuration = configuration; _selected = State(initialValue: [initial]) }
    var body: some View {
        NavigationStack {
            List {
                ForEach(BackgroundTarget.sections, id: \.self) { section in
                    Section(section) {
                        ForEach(BackgroundTarget.allCases.filter { $0.section == section }) { target in
                            Toggle(target.title, isOn: Binding(get: { selected.contains(target) }, set: { enabled in
                                if enabled { selected.insert(target) } else { selected.remove(target) }
                            }))
                        }
                    }
                }
            }
            .navigationTitle("应用到 \(selected.count) 个位置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(selected.count == BackgroundTarget.allCases.count ? "取消全选" : "全选") {
                    selected = selected.count == BackgroundTarget.allCases.count ? [] : Set(BackgroundTarget.allCases)
                } }
                ToolbarItem(placement: .confirmationAction) { Button("应用") {
                    selected.forEach { store.set(configuration, for: $0) }; dismiss()
                }.disabled(selected.isEmpty) }
            }
        }
    }
}

