import PhotosUI
import SwiftUI

struct BackgroundSettingsView: View {
    @EnvironmentObject private var store: BackgroundStore
    @State private var cleanConfirmation = false
    var body: some View {
        List {
            Section {
                Label("图片和视频都可用于页面、玻璃按键与个人资料。", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline)
                Text("通用背景会应用到未单独设置的位置。每个位置可以覆盖通用设置，或恢复跟随。")
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
            Section("媒体管理") {
                Button { cleanConfirmation = true } label: {
                    Label("清理未使用背景（\(store.unusedCount)）", systemImage: "sparkles")
                }.disabled(store.unusedCount == 0)
                Text("替换或恢复默认时，原媒体仍保留在背景库里，可再次使用。清理只移除当前没有任何位置使用的背景。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("背景与按键").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).pageBackground(.settings)
        .confirmationDialog("清理 \(store.unusedCount) 个未使用背景？", isPresented: $cleanConfirmation, titleVisibility: .visible) {
            Button("清理未使用", role: .destructive) { store.cleanUnused() }
            Button("取消", role: .cancel) {}
        }
    }

    private func description(_ target: BackgroundTarget) -> String {
        guard let config = store.resolved(target), let asset = store.asset(config) else { return target.fallback == nil ? "默认外观" : "跟随通用外观" }
        let inherited = store.configurations[target.rawValue] == nil
        return (asset.isVideo ? "视频 · 静音循环" : "图片") + (inherited ? " · 跟随通用" : " · 单独设置")
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
        }.clipped().allowsHitTesting(false)
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
                                }.buttonStyle(.plain).accessibilityLabel(asset.isVideo ? "使用这个视频背景" : "使用这个图片背景")
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
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
