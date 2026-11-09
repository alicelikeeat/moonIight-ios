import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// v1.92: the AI 3D page's base-body character maker (the first card). Pick a
// base body (woman, man, child, elder, giant boss, the neutral mannequin, or
// one of your own model bases), then paint it from a photo (with an optional
// back photo), a video or a character sheet. The result is a character in
// the character library: rigged, animated by the shared motions, ready for
// the 3D world.

@available(iOS 18.0, *)
struct BaseBodyCharacterCard: View {
    enum Source: String, CaseIterable, Identifiable {
        case photo, video, sheet
        var id: String { rawValue }
        var title: String { switch self { case .photo: L10n.t("照片", "Photo"); case .video: L10n.t("视频", "Video"); case .sheet: L10n.t("设定图", "Sheet") } }
    }

    @ObservedObject private var library = CharacterLibrary.shared
    @State private var baseID = BaseBodyCatalog.neutralID
    @State private var source = Source.photo
    @State private var front: Data?
    @State private var back: Data?
    @State private var video: URL?
    @State private var fitShape = true
    @State private var busy: String?
    @State private var message: String?
    @State private var thumbnail: UIImage?
    @State private var frontItem: PhotosPickerItem?
    @State private var backItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?

    /// Painted skins go on HumanBase bases (model bases keep their own texture).
    private var bases: [BaseBodyEntry] { BaseBodyCatalog.builtins }
    private var base: BaseBodyEntry { bases.first { $0.id == baseID } ?? BaseBodyCatalog.builtins[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("底模角色（推荐）", "Base-Body Character (recommended)"), systemImage: "figure.stand").font(.headline)
            Text(L10n.t("先选底模，再用照片、视频或设定图生成皮肤。得到完整 360°、自带骨骼和全部通用动作的角色。", "Pick a base body, then make its skin from a photo, a video or a character sheet. You get a full 360° character with a skeleton and every shared motion."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bases) { entry in
                        Button { baseID = entry.id } label: {
                            VStack(spacing: 4) {
                                Image(systemName: entry.symbol).font(.title3)
                                Text(entry.name).font(.caption2).lineLimit(1)
                            }
                            .frame(width: 70, height: 58)
                            .background(RoundedRectangle(cornerRadius: 12).fill(entry.id == baseID ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bb-base-" + entry.id)
                    }
                }
            }
            Picker(L10n.t("皮肤来源", "Skin from"), selection: $source) { ForEach(Source.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).accessibilityIdentifier("bb-source")
            sourcePickers
            Toggle(L10n.t("按照片调整体型（性别、年龄和大小保留底模的）", "Take the photo's proportions (gender, age and size stay the base's)"), isOn: $fitShape).font(.caption)
            if let busy { HStack { ProgressView(); Text(busy).font(.caption) } }
            Button { make() } label: { Label(L10n.t("生成底模角色", "Make the Character"), systemImage: "wand.and.stars") }
                .buttonStyle(.moonLiquidProminent).disabled(busy != nil || !ready).accessibilityIdentifier("bb-make")
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().frame(height: 160).frame(maxWidth: .infinity) }
            if let message { Text(message).font(.caption).accessibilityIdentifier("bb-message") }
        }
        .padding(14).moonGlassCard(radius: 18, tint: .purple)
        .onChange(of: frontItem) { _, item in load(item) { front = $0 } }
        .onChange(of: backItem) { _, item in load(item) { back = $0 } }
        .onChange(of: videoItem) { _, item in loadVideo(item) }
    }

    private var ready: Bool {
        switch source { case .photo, .sheet: front != nil; case .video: video != nil }
    }

    @ViewBuilder private var sourcePickers: some View {
        switch source {
        case .photo:
            HStack {
                PhotosPicker(selection: $frontItem, matching: .images) { Label(front == nil ? L10n.t("正面照片", "Front photo") : L10n.t("已选正面", "Front chosen"), systemImage: "person.fill") }
                    .accessibilityIdentifier("bb-front")
                PhotosPicker(selection: $backItem, matching: .images) { Label(back == nil ? L10n.t("背面（可选）", "Back (optional)") : L10n.t("已选背面", "Back chosen"), systemImage: "person.fill.turn.left") }
                    .accessibilityIdentifier("bb-back")
            }
            .font(.caption)
        case .sheet:
            PhotosPicker(selection: $frontItem, matching: .images) { Label(front == nil ? L10n.t("选择设定图（正面 + 背面）", "Pick a sheet (front + back)") : L10n.t("已选设定图", "Sheet chosen"), systemImage: "rectangle.split.3x1") }
                .font(.caption).accessibilityIdentifier("bb-sheet")
        case .video:
            PhotosPicker(selection: $videoItem, matching: .videos) { Label(video == nil ? L10n.t("选择视频（转一圈更好）", "Pick a video (turning around is best)") : L10n.t("已选视频", "Video chosen"), systemImage: "video") }
                .font(.caption).accessibilityIdentifier("bb-video")
        }
    }

    private func load(_ item: PhotosPickerItem?, into set: @escaping (Data?) -> Void) {
        guard let item else { return }
        Task { set(try? await item.loadTransferable(type: Data.self)); message = nil }
    }
    private func loadVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { message = L10n.t("视频无法读取", "The video could not be read"); return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-" + UUID().uuidString + ".mov")
            do { try data.write(to: url); video = url; message = nil } catch { message = error.localizedDescription }
        }
    }

    private func make() {
        let base = base, source = source, fitShape = fitShape, front = front, back = back, video = video
        busy = L10n.t("识别人物并生成皮肤…", "Finding the person and making the skin…")
        message = nil; thumbnail = nil
        Task {
            defer { busy = nil }
            do {
                let output: BaseBodySkinPipeline.Output = try await Task.detached(priority: .userInitiated) {
                    switch source {
                    case .photo:
                        guard let f = front.flatMap(BaseBodySkinPipeline.image) else { throw BaseBodySkinPipeline.Failure.unreadable }
                        return try BaseBodySkinPipeline.make(base: base, front: f, back: back.flatMap(BaseBodySkinPipeline.image), source: .photo, fitShape: fitShape)
                    case .sheet:
                        guard let data = front else { throw BaseBodySkinPipeline.Failure.unreadable }
                        let views = try BaseBodySkinPipeline.sheet(data)
                        return try BaseBodySkinPipeline.make(base: base, front: views.front, back: views.back, source: .sheet, fitShape: fitShape)
                    case .video:
                        guard let video else { throw BaseBodySkinPipeline.Failure.unreadable }
                        let analysis = try await VideoReconstructionPipeline.analyze(video, progress: { _, _ in })
                        defer { try? FileManager.default.removeItem(at: analysis.framesFolder) }
                        let frames = try BaseBodySkinPipeline.frames(analysis)
                        return try BaseBodySkinPipeline.make(base: base, front: frames.front, back: frames.back, source: .video, fitShape: fitShape)
                    }
                }.value
                let name = base.name + " · " + source.title
                guard var package = CharacterPackage.humanBase(name: name, appearance: output.appearance) else { message = L10n.t("没有找到通用底模文件", "The base body file is missing"); return }
                package.textures[output.appearance.painted?.atlas ?? "skin.jpg"] = output.atlas
                if let error = library.save(package) { message = error; return }
                thumbnail = await Task.detached(priority: .utility) { Self.thumbnail(output) }.value
                message = (output.notes + [L10n.t("已存入角色库：「\(name)」。在 3D 世界 ⋯ → 角色工作台里可以设为玩家或放到世界里。", "Saved to the character library as “\(name)”. In the 3D world, ⋯ → Character Workbench can make it the player or place it.")]).joined(separator: "\n")
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// A small render of the painted character (front three-quarter view).
    nonisolated static func thumbnail(_ output: BaseBodySkinPipeline.Output) -> UIImage? {
        guard let skin = output.appearance.painted, let body = HumanBase.build(output.appearance.shape, lod: 1),
              let atlas = UIImage(data: output.atlas)?.cgImage.flatMap(ModelAnimationExport.raster) else { return nil }
        var mesh = BaseBodyPaint.paint(body.model, front: skin.front, back: skin.back).mesh
        mesh.normalize(size: 1)
        let image = ModelRasterizer.render(mesh, texture: atlas, camera: RasterCamera(yaw: 0.35, lighting: true), width: 240, height: 320, background: [30, 32, 44, 255])
        return ModelAnimationExport.cgImage(image).map { UIImage(cgImage: $0) }
    }
}
