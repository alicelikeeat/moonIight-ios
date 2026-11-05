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
    /// The block being edited, or nil for an empty cell (task E, A+: the
    /// content is placed on a new walk-through display cell).
    let entity: WorldEntity?
    let point: SurfacePoint?
    /// Set when shown in the floating panel instead of a sheet.
    var onClose: (() -> Void)?
    private let original: MediaBinding?
    @State private var draft: MediaBinding
    @State private var picked: PhotosPickerItem?
    @State private var importing = false
    @State private var importNotice = ""
    @State private var fullscreen: MediaEntry?

    init(session: RPGSession, store: MediaStore, entity: WorldEntity?, point: SurfacePoint? = nil, initialKind: RPGMediaKind? = nil, onClose: (() -> Void)? = nil) {
        self.session = session; self.store = store; self.entity = entity; self.point = point ?? entity?.surface; self.onClose = onClose
        let current = entity.flatMap { session.mediaBinding(for: .entity($0.id)) }
        original = current
        var start = current ?? MediaBinding(id: "draft", mediaID: "", kind: .icon, style: RPGCellStyle(value: "star.fill"))
        if current == nil, let initialKind, initialKind != start.kind { start = Self.template(for: initialKind) }
        if start.kind.usesLibraryFile, start.fit == nil { start.fit = .fill }
        _draft = State(initialValue: start)
    }

    var body: some View {
        List { Group {
            Section {
                HStack {
                    Spacer()
                    RPGCellPreview(binding: draft, entry: entry(draft.mediaID))
                        .accessibilityIdentifier("rpg-cell-preview").accessibilityValue(summary)
                    Spacer()
                }
                if !draft.valid { Text(problem).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("rpg-cell-problem") }
            } footer: { Text(L10n.t("预览只在这里生效；点“确认”后才写入世界，可撤销。方块材质不变。", "The preview only applies here. Tap Confirm to write it to the world (undoable). The block material stays.")) }
            // Near the top so it is reachable without scrolling a long form.
            if original != nil {
                Section {
                    Button(L10n.t("删除格子内容", "Remove Cell Content"), role: .destructive) { if let entity { session.clearMedia(.entity(entity.id)) }; close() }
                        .accessibilityIdentifier("rpg-cell-delete")
                }
            }
            Section(L10n.t("类型", "Type")) {
                Picker(L10n.t("类型", "Type"), selection: kindBinding) {
                    ForEach(RPGMediaKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("rpg-cell-kind")
            }
            switch draft.kind {
            case .image, .video, .gif: librarySection
            case .icon: iconSection
            case .number, .text: textSection
            }
            displaySection
            }.listRowBackground(MoonLiquidRowBackground())
        }.moonLiquidList()
        .navigationTitle(L10n.t("格子内容", "Cell Content")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(L10n.t("取消", "Cancel")) { close() }.accessibilityIdentifier("rpg-cell-cancel") }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("确认", "Confirm")) {
                    if let entity { session.applyCellContent(draft, to: entity.id) } else if let point { session.applyContent(draft, at: point) }
                    close()
                }
                    .disabled(!draft.valid || draft == original || session.working).accessibilityIdentifier("rpg-cell-confirm")
            }
        }
        .fullScreenCover(item: $fullscreen) { entry in
            MediaPlayerView(entry: entry, onShareToMoments: { fullscreen = nil }, onQueueAdvance: { _ in }).environmentObject(model)
        }
        .onChange(of: picked) { value in importPicked(value) }
    }

    private func close() { if let onClose { onClose() } else { dismiss() } }

    /// Starting content for a content tool (图片 / 文字 / …) on a fresh cell.
    static func template(for kind: RPGMediaKind) -> MediaBinding {
        switch kind {
        case .image, .video, .gif: MediaBinding(id: "draft", mediaID: "", kind: kind, fit: .fill)
        case .icon: MediaBinding(id: "draft", mediaID: "", kind: .icon, style: RPGCellStyle(value: "star.fill"))
        case .number: MediaBinding(id: "draft", mediaID: "", kind: .number, style: RPGCellStyle(value: "1"))
        case .text: MediaBinding(id: "draft", mediaID: "", kind: .text, style: RPGCellStyle(value: L10n.t("文字", "Text"), size: 0.4))
        }
    }

    // MARK: Sections

    private var librarySection: some View {
        Section(draft.kind.title + L10n.t("素材", " Media")) {
            PhotosPicker(selection: $picked, matching: draft.kind == .video ? .videos : .images) {
                Label(L10n.t("从相册导入", "Import from Photos"), systemImage: "square.and.arrow.down")
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
            if candidates(for: draft.kind).isEmpty { Text(L10n.t("库中没有可离线使用的\(draft.kind.title)，请先从相册导入。", "No offline \(draft.kind.title) in the library yet. Import one from Photos.")).font(.caption).foregroundStyle(.secondary) }
            if let item = entry(draft.mediaID) {
                Button(L10n.t("全屏查看", "View Full Screen")) { fullscreen = item }.accessibilityIdentifier("rpg-cell-fullscreen")
            }
        }
    }

    private static let symbols = ["star.fill", "heart.fill", "moon.stars.fill", "sun.max.fill", "flame.fill", "leaf.fill",
                                  "drop.fill", "bolt.fill", "house.fill", "flag.fill", "key.fill", "music.note"]
    private var iconSection: some View {
        Section(L10n.t("图标", "Icon")) {
            Picker(L10n.t("来源", "Source"), selection: Binding(get: { draft.mediaID.isEmpty ? 0 : 1 }, set: { custom in
                if custom == 1 { draft.style?.value = ""; draft.mediaID = candidates(for: .image).first?.id ?? "" }
                else { draft.mediaID = ""; if draft.style?.value.isEmpty != false { draft.style?.value = "star.fill" } }
            })) { Text(L10n.t("系统图标", "System Icon")).tag(0); Text(L10n.t("自定义图片", "Custom Image")).tag(1) }.pickerStyle(.segmented).accessibilityIdentifier("rpg-cell-icon-source")
            if draft.mediaID.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(Self.symbols, id: \.self) { name in
                        Button { draft.style?.value = name } label: {
                            Image(systemName: name).font(.title3).frame(maxWidth: .infinity, minHeight: 44)
                                .background(draft.style?.value == name ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.moonJelly).accessibilityIdentifier("rpg-cell-symbol-" + name)
                    }
                }
                TextField(L10n.t("SF Symbol 名称", "SF Symbol name"), text: styleText).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("rpg-cell-symbol")
            } else {
                ForEach(candidates(for: .image)) { item in
                    Button { draft.mediaID = item.id } label: {
                        HStack { Text(item.title).lineLimit(1); Spacer(); if draft.mediaID == item.id { Image(systemName: "checkmark") } }.frame(minHeight: 44)
                    }.accessibilityIdentifier("rpg-cell-pick-" + item.id)
                }
            }
            colorRow(L10n.t("颜色", "Color"), hex: Binding(get: { draft.style?.colorHex ?? "FFFFFF" }, set: { draft.style?.colorHex = $0 }))
            Toggle(L10n.t("粗体", "Bold"), isOn: Binding(get: { draft.style?.bold ?? true }, set: { draft.style?.bold = $0 }))
        }
    }

    private var textSection: some View {
        Section(draft.kind.title) {
            TextField(draft.kind == .number ? L10n.t("数字，如 42 或 -3.5", "Number, e.g. 42 or -3.5") : L10n.t("最多 64 个字，最多 3 行", "Up to 64 characters, 3 lines"), text: styleText, axis: draft.kind == .text ? .vertical : .horizontal)
                .keyboardType(draft.kind == .number ? .numbersAndPunctuation : .default)
                .lineLimit(1...3).accessibilityIdentifier("rpg-cell-value")
            Picker(L10n.t("字体", "Font"), selection: Binding(get: { draft.style?.design ?? .rounded }, set: { draft.style?.design = $0 })) {
                Text(L10n.t("圆体", "Rounded")).tag(RPGTextDesign.rounded); Text(L10n.t("标准", "Standard")).tag(RPGTextDesign.standard)
                Text(L10n.t("衬线", "Serif")).tag(RPGTextDesign.serif); Text(L10n.t("等宽", "Mono")).tag(RPGTextDesign.monospaced)
            }
            Picker(L10n.t("对齐", "Align"), selection: Binding(get: { draft.style?.alignment ?? .center }, set: { draft.style?.alignment = $0 })) {
                Text(L10n.t("左", "Left")).tag(RPGTextAlignment.leading); Text(L10n.t("中", "Center")).tag(RPGTextAlignment.center); Text(L10n.t("右", "Right")).tag(RPGTextAlignment.trailing)
            }.pickerStyle(.segmented)
            colorRow(L10n.t("文字颜色", "Text Color"), hex: Binding(get: { draft.style?.colorHex ?? "FFFFFF" }, set: { draft.style?.colorHex = $0 }))
            Toggle(L10n.t("粗体", "Bold"), isOn: Binding(get: { draft.style?.bold ?? true }, set: { draft.style?.bold = $0 }))
        }
    }

    private var displaySection: some View {
        Section(L10n.t("显示", "Display")) {
            if RPGCellRenderer.isGlyph(draft) {
                Slider(value: Binding(get: { draft.style?.size ?? 0.6 }, set: { draft.style?.size = $0 }), in: 0.2...1, step: 0.05) { Text(L10n.t("内容大小", "Content Size")) }
                Text(L10n.t("内容大小", "Content Size") + " \(Int((draft.style?.size ?? 0.6) * 100))%").font(.caption)
                Toggle(L10n.t("背景色", "Background"), isOn: Binding(get: { draft.style?.backgroundHex != nil }, set: { draft.style?.backgroundHex = $0 ? "1C1C1E" : nil }))
                    .accessibilityIdentifier("rpg-cell-background")
                if draft.style?.backgroundHex != nil {
                    colorRow(L10n.t("背景颜色", "Background Color"), hex: Binding(get: { draft.style?.backgroundHex ?? "1C1C1E" }, set: { draft.style?.backgroundHex = $0 }))
                }
            }
            Slider(value: $draft.scale, in: 0.25...4, step: 0.25) { Text(L10n.t("缩放", "Scale")) }
            Text(L10n.t("缩放", "Scale") + " " + String(format: "%.2f", draft.scale)).font(.caption)
            if draft.kind.usesLibraryFile || (draft.kind == .icon && !draft.mediaID.isEmpty) {
                Picker(L10n.t("铺放", "Fit"), selection: Binding(get: { draft.fit ?? .fill }, set: { draft.fit = $0 })) {
                    Text(L10n.t("裁剪填满", "Fill")).tag(RPGContentFit.fill); Text(L10n.t("完整适应", "Fit")).tag(RPGContentFit.fit)
                }.pickerStyle(.segmented).accessibilityIdentifier("rpg-cell-fit")
            }
            if draft.kind == .video || draft.kind == .gif {
                Toggle(L10n.t("播放", "Play"), isOn: Binding(get: { draft.paused != true }, set: { draft.paused = $0 ? nil : true }))
                    .accessibilityIdentifier("rpg-cell-play")
                Toggle(L10n.t("循环", "Loop"), isOn: $draft.loop).accessibilityIdentifier("rpg-cell-loop")
            }
            if draft.kind == .video {
                Toggle(L10n.t("静音", "Mute"), isOn: $draft.muted).accessibilityIdentifier("rpg-cell-muted")
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
                draft.mediaID = ""; draft.style = RPGCellStyle(value: L10n.t("文字", "Text"), colorHex: draft.style?.colorHex ?? "FFFFFF", backgroundHex: draft.style?.backgroundHex, size: 0.4)
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
        case .image, .video, .gif: L10n.t("请选择或导入\(draft.kind.title)。", "Choose or import a \(draft.kind.title).")
        case .icon: draft.mediaID.isEmpty ? L10n.t("图标名称无效（只能用小写字母、数字和点）。", "Invalid icon name (lowercase letters, digits and dots only).") : L10n.t("请选择自定义图标图片。", "Choose a custom icon image.")
        case .number: L10n.t("请输入数字，最多 12 位整数和 6 位小数。", "Enter a number: up to 12 digits and 6 decimals.")
        case .text: L10n.t("文字需为 1–64 个字，最多 3 行。", "Text must be 1–64 characters, up to 3 lines.")
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
                guard let file = try await value.loadTransferable(type: RPGPickedFile.self) else { importNotice = L10n.t("无法读取所选素材。", "Couldn't read the selected item."); return }
                defer { try? FileManager.default.removeItem(at: file.url) }
                let video = value.supportedContentTypes.contains { $0.conforms(to: .movie) }
                let gif = file.url.pathExtension.lowercased() == "gif"
                let title = video ? L10n.t("沙盒视频", "Sandbox Video") : gif ? L10n.t("沙盒 GIF", "Sandbox GIF") : L10n.t("沙盒图片", "Sandbox Image")
                guard let item = await store.importLocalFile(file.url, title: title, kind: video ? .video : .image) else {
                    importNotice = store.notice ?? L10n.t("导入失败。", "Import failed."); return
                }
                let kind = RPGMediaCatalogKind.kind(for: item)
                if draft.kind == .icon { draft.mediaID = item.id }
                else { if kind != draft.kind { kindBinding.wrappedValue = kind }; draft.mediaID = item.id }
                importNotice = L10n.t("已导入，确认后绑定到格子。", "Imported. Confirm to bind it to the cell.")
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
