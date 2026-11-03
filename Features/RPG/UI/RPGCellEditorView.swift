import SwiftUI
import PhotosUI
import ImageIO

/// Edits one block's content. Changes stay in a local draft with a live
/// preview; nothing touches the world until 确认, which commits a single
/// undoable edit. 取消 discards the draft.
struct RPGCellEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: RPGSession
    @ObservedObject var store: MediaStore
    let entity: WorldEntity
    private let original: MediaBinding?
    @State private var draft: MediaBinding
    @State private var picked: PhotosPickerItem?
    @State private var importing = false
    @State private var importNotice = ""
    @State private var fullscreen: MediaEntry?

    init(session: RPGSession, store: MediaStore, entity: WorldEntity) {
        self.session = session; self.store = store; self.entity = entity
        let current = session.mediaBinding(for: .entity(entity.id))
        original = current
        var start = current ?? MediaBinding(id: "draft", mediaID: "", kind: .icon, style: RPGCellStyle(value: "star.fill"))
        if start.kind.usesLibraryFile, start.fit == nil { start.fit = .fill }
        _draft = State(initialValue: start)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    RPGCellPreview(binding: draft, entry: entry(draft.mediaID))
                        .accessibilityIdentifier("rpg-cell-preview").accessibilityValue(summary)
                    Spacer()
                }
                if !draft.valid { Text(problem).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("rpg-cell-problem") }
            } footer: { Text("预览只在这里生效；点“确认”后才写入世界，可撤销。方块材质不变。") }
            Section("类型") {
                Picker("类型", selection: kindBinding) {
                    ForEach(RPGMediaKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("rpg-cell-kind")
            }
            switch draft.kind {
            case .image, .video, .gif: librarySection
            case .icon: iconSection
            case .number, .text: textSection
            }
            displaySection
            if original != nil {
                Section {
                    Button("删除格子内容", role: .destructive) { session.clearMedia(.entity(entity.id)); dismiss() }
                        .accessibilityIdentifier("rpg-cell-delete")
                }
            }
        }
        .navigationTitle("格子内容").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.accessibilityIdentifier("rpg-cell-cancel") }
            ToolbarItem(placement: .confirmationAction) {
                Button("确认") { session.applyCellContent(draft, to: entity.id); dismiss() }
                    .disabled(!draft.valid || draft == original || session.working).accessibilityIdentifier("rpg-cell-confirm")
            }
        }
        .fullScreenCover(item: $fullscreen) { entry in
            MediaPlayerView(entry: entry, onShareToMoments: { fullscreen = nil }, onQueueAdvance: { _ in }).environmentObject(model)
        }
        .onChange(of: picked) { value in importPicked(value) }
    }

    // MARK: Sections

    private var librarySection: some View {
        Section(draft.kind.title + "素材") {
            PhotosPicker(selection: $picked, matching: draft.kind == .video ? .videos : .images) {
                Label("从相册导入", systemImage: "square.and.arrow.down")
            }.disabled(importing).accessibilityIdentifier("rpg-cell-import")
            if !importNotice.isEmpty { Text(importNotice).font(.caption) }
            ForEach(candidates(for: draft.kind)) { item in
                Button { draft.mediaID = item.id } label: {
                    HStack {
                        Image(systemName: draft.kind == .video ? "video" : draft.kind == .gif ? "sparkles.rectangle.stack" : "photo")
                        Text(item.title).lineLimit(1)
                        Spacer()
                        if draft.mediaID == item.id { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44)
                }.accessibilityIdentifier("rpg-cell-pick-" + item.id)
            }
            if candidates(for: draft.kind).isEmpty { Text("库中没有可离线使用的\(draft.kind.title)，请先从相册导入。").font(.caption).foregroundStyle(.secondary) }
            if let item = entry(draft.mediaID) {
                Button("全屏查看") { fullscreen = item }.accessibilityIdentifier("rpg-cell-fullscreen")
            }
        }
    }

    private static let symbols = ["star.fill", "heart.fill", "moon.stars.fill", "sun.max.fill", "flame.fill", "leaf.fill",
                                  "drop.fill", "bolt.fill", "house.fill", "flag.fill", "key.fill", "music.note"]
    private var iconSection: some View {
        Section("图标") {
            Picker("来源", selection: Binding(get: { draft.mediaID.isEmpty ? 0 : 1 }, set: { custom in
                if custom == 1 { draft.style?.value = ""; draft.mediaID = candidates(for: .image).first?.id ?? "" }
                else { draft.mediaID = ""; if draft.style?.value.isEmpty != false { draft.style?.value = "star.fill" } }
            })) { Text("系统图标").tag(0); Text("自定义图片").tag(1) }.pickerStyle(.segmented).accessibilityIdentifier("rpg-cell-icon-source")
            if draft.mediaID.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Self.symbols, id: \.self) { name in
                        Button { draft.style?.value = name } label: {
                            Image(systemName: name).font(.title3).frame(maxWidth: .infinity, minHeight: 44)
                                .background(draft.style?.value == name ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityIdentifier("rpg-cell-symbol-" + name)
                    }
                }
                TextField("SF Symbol 名称", text: styleText).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("rpg-cell-symbol")
            } else {
                ForEach(candidates(for: .image)) { item in
                    Button { draft.mediaID = item.id } label: {
                        HStack { Text(item.title).lineLimit(1); Spacer(); if draft.mediaID == item.id { Image(systemName: "checkmark") } }.frame(minHeight: 44)
                    }.accessibilityIdentifier("rpg-cell-pick-" + item.id)
                }
            }
            colorRow("颜色", hex: Binding(get: { draft.style?.colorHex ?? "FFFFFF" }, set: { draft.style?.colorHex = $0 }))
            Toggle("粗体", isOn: Binding(get: { draft.style?.bold ?? true }, set: { draft.style?.bold = $0 }))
        }
    }

    private var textSection: some View {
        Section(draft.kind.title) {
            TextField(draft.kind == .number ? "数字，如 42 或 -3.5" : "最多 64 个字，最多 3 行", text: styleText, axis: draft.kind == .text ? .vertical : .horizontal)
                .keyboardType(draft.kind == .number ? .numbersAndPunctuation : .default)
                .lineLimit(1...3).accessibilityIdentifier("rpg-cell-value")
            Picker("字体", selection: Binding(get: { draft.style?.design ?? .rounded }, set: { draft.style?.design = $0 })) {
                Text("圆体").tag(RPGTextDesign.rounded); Text("标准").tag(RPGTextDesign.standard)
                Text("衬线").tag(RPGTextDesign.serif); Text("等宽").tag(RPGTextDesign.monospaced)
            }
            Picker("对齐", selection: Binding(get: { draft.style?.alignment ?? .center }, set: { draft.style?.alignment = $0 })) {
                Text("左").tag(RPGTextAlignment.leading); Text("中").tag(RPGTextAlignment.center); Text("右").tag(RPGTextAlignment.trailing)
            }.pickerStyle(.segmented)
            colorRow("文字颜色", hex: Binding(get: { draft.style?.colorHex ?? "FFFFFF" }, set: { draft.style?.colorHex = $0 }))
            Toggle("粗体", isOn: Binding(get: { draft.style?.bold ?? true }, set: { draft.style?.bold = $0 }))
        }
    }

    private var displaySection: some View {
        Section("显示") {
            if RPGCellRenderer.isGlyph(draft) {
                Slider(value: Binding(get: { draft.style?.size ?? 0.6 }, set: { draft.style?.size = $0 }), in: 0.2...1, step: 0.05) { Text("内容大小") }
                Text("内容大小 \(Int((draft.style?.size ?? 0.6) * 100))%").font(.caption)
                Toggle("背景色", isOn: Binding(get: { draft.style?.backgroundHex != nil }, set: { draft.style?.backgroundHex = $0 ? "1C1C1E" : nil }))
                    .accessibilityIdentifier("rpg-cell-background")
                if draft.style?.backgroundHex != nil {
                    colorRow("背景颜色", hex: Binding(get: { draft.style?.backgroundHex ?? "1C1C1E" }, set: { draft.style?.backgroundHex = $0 }))
                }
            }
            Slider(value: $draft.scale, in: 0.25...4, step: 0.25) { Text("缩放") }
            Text("缩放 \(String(format: "%.2f", draft.scale))").font(.caption)
            if draft.kind.usesLibraryFile || (draft.kind == .icon && !draft.mediaID.isEmpty) {
                Picker("铺放", selection: Binding(get: { draft.fit ?? .fill }, set: { draft.fit = $0 })) {
                    Text("裁剪填满").tag(RPGContentFit.fill); Text("完整适应").tag(RPGContentFit.fit)
                }.pickerStyle(.segmented).accessibilityIdentifier("rpg-cell-fit")
            }
            if draft.kind == .video || draft.kind == .gif {
                Toggle("播放", isOn: Binding(get: { draft.paused != true }, set: { draft.paused = $0 ? nil : true }))
                    .accessibilityIdentifier("rpg-cell-play")
                Toggle("循环", isOn: $draft.loop).accessibilityIdentifier("rpg-cell-loop")
            }
            if draft.kind == .video {
                Toggle("静音", isOn: $draft.muted).accessibilityIdentifier("rpg-cell-muted")
            }
        }
    }

    // MARK: Helpers

    private var kindBinding: Binding<RPGMediaKind> {
        Binding(get: { draft.kind }, set: { kind in
            guard kind != draft.kind else { return }
            let previous = draft.kind
            draft.kind = kind
            switch kind {
            case .image, .video, .gif:
                if previous != kind { draft.mediaID = candidates(for: kind).first?.id ?? "" }
                draft.style = nil; if draft.fit == nil { draft.fit = .fill }
            case .icon:
                draft.mediaID = ""; draft.style = RPGCellStyle(value: "star.fill", colorHex: draft.style?.colorHex ?? "FFFFFF")
            case .number:
                draft.mediaID = ""; draft.style = RPGCellStyle(value: "1", colorHex: draft.style?.colorHex ?? "FFFFFF", backgroundHex: draft.style?.backgroundHex)
            case .text:
                draft.mediaID = ""; draft.style = RPGCellStyle(value: "文字", colorHex: draft.style?.colorHex ?? "FFFFFF", backgroundHex: draft.style?.backgroundHex, size: 0.4)
            }
            if kind != .video { draft.muted = true }
            if kind != .video && kind != .gif { draft.paused = nil }
        })
    }

    private var styleText: Binding<String> {
        Binding(get: { draft.style?.value ?? "" }, set: { value in
            if draft.style == nil { draft.style = RPGCellStyle() }
            draft.style?.value = draft.kind == .icon ? value.lowercased().trimmingCharacters(in: .whitespaces) : value
        })
    }

    private func entry(_ id: String) -> MediaEntry? {
        id.isEmpty ? nil : store.items.first { $0.id == id }
    }

    /// Library items usable offline for a content kind.
    private func candidates(for kind: RPGMediaKind) -> [MediaEntry] {
        store.items.filter { item in
            guard item.kind != .embed, item.remoteURL?.isFileURL == true else { return false }
            return RPGMediaCatalogKind.kind(for: item) == kind
        }
    }

    private var summary: String {
        draft.kind.rawValue + ":" + (draft.style?.value.isEmpty == false ? draft.style!.value : draft.mediaID)
    }

    private var problem: String {
        switch draft.kind {
        case .image, .video, .gif: "请选择或导入\(draft.kind.title)。"
        case .icon: draft.mediaID.isEmpty ? "图标名称无效（只能用小写字母、数字和点）。" : "请选择自定义图标图片。"
        case .number: "请输入数字，最多 12 位整数和 6 位小数。"
        case .text: "文字需为 1–64 个字，最多 3 行。"
        }
    }

    private func colorRow(_ title: String, hex: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(uiColor: UIColor(rpgHex: hex.wrappedValue)) },
                                              set: { hex.wrappedValue = UIColor($0).rpgHex }), supportsOpacity: false)
    }

    private func importPicked(_ value: PhotosPickerItem?) {
        guard let value else { return }
        importing = true
        Task {
            defer { importing = false; picked = nil }
            do {
                guard let file = try await value.loadTransferable(type: RPGPickedFile.self) else { importNotice = "无法读取所选素材。"; return }
                defer { try? FileManager.default.removeItem(at: file.url) }
                let video = value.supportedContentTypes.contains { $0.conforms(to: .movie) }
                let gif = file.url.pathExtension.lowercased() == "gif"
                let title = video ? "沙盒视频" : gif ? "沙盒 GIF" : "沙盒图片"
                guard let item = await store.importLocalFile(file.url, title: title, kind: video ? .video : .image) else {
                    importNotice = store.notice ?? "导入失败。"; return
                }
                let kind = RPGMediaCatalogKind.kind(for: item)
                if draft.kind == .icon { draft.mediaID = item.id }
                else { if kind != draft.kind { kindBinding.wrappedValue = kind }; draft.mediaID = item.id }
                importNotice = "已导入，确认后绑定到格子。"
            } catch { importNotice = error.localizedDescription }
        }
    }
}

/// Small live preview of a draft, drawn the same way the world draws it.
struct RPGCellPreview: View {
    let binding: MediaBinding
    let entry: MediaEntry?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.gray.opacity(0.25))
            content.frame(width: 96, height: 96).clipped()
        }
        .frame(width: 112, height: 112)
    }

    @ViewBuilder private var content: some View {
        if RPGCellRenderer.isGlyph(binding) {
            Image(uiImage: RPGCellRenderer.image(kind: binding.kind, style: binding.style ?? RPGCellStyle())).resizable().scaledToFit()
        } else if binding.kind != .video, let url = entry?.remoteURL, url.isFileURL, let image = Self.thumbnail(url) {
            let picture = Image(uiImage: image).resizable()
            if binding.kind == .icon {
                picture.renderingMode(.template).foregroundStyle(Color(uiColor: UIColor(rpgHex: binding.style?.colorHex ?? "FFFFFF"))).scaledToFit()
            } else if binding.fit == .fit {
                picture.scaledToFit()
            } else {
                picture.scaledToFill()
            }
        } else if binding.kind == .video, let title = entry?.title {
            VStack(spacing: 6) { Image(systemName: "play.rectangle.fill").font(.largeTitle); Text(title).font(.caption2).lineLimit(2) }
        } else {
            Image(systemName: "questionmark.square.dashed").font(.largeTitle).foregroundStyle(.secondary)
        }
    }

    /// First frame, reduced; GIF previews show their first frame here.
    static func thumbnail(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 240,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

extension UIColor {
    /// "RRGGBB" for this colour in sRGB, clamped.
    var rpgHex: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "FFFFFF" }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
