import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// v1.92: the AI 3D page's base-body character maker (the first card). Pick a
// base body (woman, man, child, elder, giant boss, the neutral mannequin, or
// one of your own model bases), then paint it from a photo (with an optional
// back photo), a video or a character sheet. The result is a character in
// the character library: rigged, animated by the shared motions, ready for
// the 3D world.
// v1.93: the pictures are checked against the character-sheet standard
// (front required; back and side recommended) and a missing back or side
// can be proposed by AI from the front, adopted only after the user confirms.

@available(iOS 18.0, *)
struct BaseBodyCharacterCard: View {
    enum Source: String, CaseIterable, Identifiable {
        case photo, video, sheet
        var id: String { rawValue }
        var title: String { switch self { case .photo: L10n.t("照片", "Photo"); case .video: L10n.t("视频", "Video"); case .sheet: L10n.t("设定图", "Sheet") } }
    }

    @ObservedObject private var library = CharacterLibrary.shared
    @StateObject private var progress = LocalJobProgress()
    @State private var baseID = BaseBodyCatalog.neutralID
    @State private var source = Source.photo
    /// Front, back and side pictures (photos, or cut from a sheet, or adopted AI proposals).
    @State private var views: [PhotoView: Data] = [:]
    @State private var origins: [PhotoView: ConceptOrigin] = [:]
    @State private var video: URL?
    @State private var fitShape = true
    @State private var busy: String?
    @State private var message: String?
    @State private var thumbnail: UIImage?
    @State private var frontItem: PhotosPickerItem?
    @State private var backItem: PhotosPickerItem?
    @State private var sideItem: PhotosPickerItem?
    @State private var sheetItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var report: ConceptSheetReport?
    @State private var checks = 0
    @State private var showGuide = false
    @State private var completion: ConceptViewCompletion.Result?

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
            if source != .video { checklist }
            Toggle(L10n.t("按照片调整体型（性别、年龄和大小保留底模的）", "Take the photo's proportions (gender, age and size stay the base's)"), isOn: $fitShape).font(.caption)
            if let busy { HStack { ProgressView(); Text(progress.stage ?? busy).font(.caption) } }
            Button { make() } label: { Label(L10n.t("生成底模角色", "Make the Character"), systemImage: "wand.and.stars") }
                .buttonStyle(.moonLiquidProminent).disabled(busy != nil || !ready).accessibilityIdentifier("bb-make")
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().frame(height: 160).frame(maxWidth: .infinity) }
            if let message { Text(message).font(.caption).accessibilityIdentifier("bb-message") }
        }
        .padding(14).moonGlassCard(radius: 18, tint: .purple)
        .onChange(of: frontItem) { _, item in load(item, .front) }
        .onChange(of: backItem) { _, item in load(item, .back) }
        .onChange(of: sideItem) { _, item in load(item, .left) }
        .onChange(of: sheetItem) { _, item in loadSheet(item) }
        .onChange(of: videoItem) { _, item in loadVideo(item) }
        .onChange(of: source) { _, _ in views = [:]; origins = [:]; report = nil }
        .onChange(of: views) { _, _ in recheck() }
        .sheet(isPresented: $showGuide) { ConceptSheetGuide() }
        .sheet(item: $completion) { result in
            ConceptCompletionSheet(result: result, front: views[.front].flatMap { UIImage(data: $0) }) { adopted in
                for (view, data) in adopted { views[view] = data; origins[view] = .ai }
            }
        }
    }

    private var ready: Bool {
        switch source { case .photo, .sheet: views[.front] != nil && report?.canMake != false; case .video: video != nil }
    }

    @ViewBuilder private var sourcePickers: some View {
        switch source {
        case .photo:
            HStack {
                picker($frontItem, .front, L10n.t("正面（必需）", "Front (required)"), "person.fill", "bb-front")
                picker($backItem, .back, L10n.t("背面", "Back"), "person.fill.turn.left", "bb-back")
                picker($sideItem, .left, L10n.t("侧面", "Side"), "person.fill.turn.right", "bb-side")
            }
            .font(.caption)
        case .sheet:
            PhotosPicker(selection: $sheetItem, matching: .images) { Label(views[.front] == nil ? L10n.t("选择设定图（正面 + 背面 + 侧面）", "Pick a sheet (front + back + side)") : L10n.t("已选设定图", "Sheet chosen"), systemImage: "rectangle.split.3x1") }
                .font(.caption).accessibilityIdentifier("bb-sheet")
        case .video:
            PhotosPicker(selection: $videoItem, matching: .videos) { Label(video == nil ? L10n.t("选择视频（转一圈更好）", "Pick a video (turning around is best)") : L10n.t("已选视频", "Video chosen"), systemImage: "video") }
                .font(.caption).accessibilityIdentifier("bb-video")
        }
    }

    private func picker(_ item: Binding<PhotosPickerItem?>, _ view: PhotoView, _ title: String, _ symbol: String, _ id: String) -> some View {
        PhotosPicker(selection: item, matching: .images) {
            Label(views[view] == nil ? title : title + " ✓", systemImage: symbol).lineLimit(1)
        }
        .accessibilityIdentifier(id)
    }

    // MARK: Character-sheet check

    @ViewBuilder private var checklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let report {
                    Label(report.grade.title, systemImage: report.grade >= .good ? "checkmark.seal.fill" : (report.canMake ? "seal" : "xmark.seal"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(report.grade >= .good ? Color.green : (report.canMake ? Color.orange : Color.red))
                        .accessibilityIdentifier("bb-grade")
                } else {
                    Text(L10n.t("设定图规范：正面必需，背面和侧面推荐", "Sheet standard: front required, back and side recommended")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { showGuide = true } label: { Label(L10n.t("规范", "Standard"), systemImage: "questionmark.circle") }
                    .font(.caption).accessibilityIdentifier("bb-guide")
            }
            if let report {
                ForEach(report.issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.level.symbol)
                            .foregroundStyle(issue.level == .blocking ? Color.red : (issue.level == .warning ? Color.orange : Color.secondary))
                        Text((issue.view.map { ($0 == ConceptSheetSpec.side ? L10n.t("侧面", "Side") : $0.title) + "：" } ?? "") + issue.message)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption2)
                }
                if views[.front] != nil, report.canMake, !report.missing.isEmpty {
                    Button { complete(report.missing) } label: {
                        Label(L10n.t("补全缺少的视角（", "Propose missing views (") + ConceptViewCompletion.route.title + L10n.t("）", ")"), systemImage: "rotate.3d")
                    }
                    .font(.caption).buttonStyle(.bordered).disabled(busy != nil).accessibilityIdentifier("bb-complete")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .accessibilityIdentifier("bb-check")
    }

    private func recheck() {
        checks += 1
        let token = checks, views = views, origins = origins
        guard !views.isEmpty else { report = nil; return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { ConceptSheetCheck.report(views, origins: origins) }.value
            if token == checks { report = result }
        }
    }

    private func complete(_ missing: [PhotoView]) {
        guard let frontData = views[.front] else { return }
        let base = base, reporter = progress.reporter
        busy = L10n.t("从正面推测缺少的视角…", "Guessing the missing views from the front…")
        progress.stage = busy
        message = nil
        Task {
            defer { busy = nil; progress.stage = nil }
            do {
                completion = try await Task.detached(priority: .userInitiated) {
                    guard let front = BaseBodySkinPipeline.image(frontData) else { throw BaseBodySkinPipeline.Failure.unreadable }
                    return try await ConceptViewCompletion.propose(front: front, base: base, views: missing, progress: reporter)
                }.value
            } catch is CancellationError {
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Loading

    private func load(_ item: PhotosPickerItem?, _ view: PhotoView) {
        guard let item else { return }
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            views[view] = data; origins[view] = .user; message = nil
        }
    }
    private func loadSheet(_ item: PhotosPickerItem?) {
        guard let item else { return }
        busy = L10n.t("切分设定图…", "Splitting the sheet…")
        Task {
            defer { busy = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else { message = L10n.t("图片无法读取", "The picture could not be read"); return }
            do {
                let split = try await Task.detached(priority: .userInitiated) { () -> [PhotoView: Data] in
                    let cut = try BaseBodySkinPipeline.sheet(data)
                    var out: [PhotoView: Data] = [:]
                    for (view, image) in [(PhotoView.front, cut.front as CGImage?), (.back, cut.back), (.left, cut.side)] {
                        if let image, let jpeg = PixelReader.jpeg(image, quality: 0.92) { out[view] = jpeg }
                    }
                    return out
                }.value
                origins = split.mapValues { _ in .sheet }
                views = split
                message = nil
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
    private func loadVideo(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { message = L10n.t("视频无法读取", "The video could not be read"); return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bb-" + UUID().uuidString + ".mov")
            do { try data.write(to: url); video = url; message = nil } catch { message = error.localizedDescription }
        }
    }

    // MARK: Making

    private func make() {
        let base = base, source = source, fitShape = fitShape, front = views[.front], back = views[.back], video = video
        let backGuessed = origins[.back] == .ai
        busy = L10n.t("识别人物并生成皮肤…", "Finding the person and making the skin…")
        message = nil; thumbnail = nil
        Task {
            defer { busy = nil }
            do {
                let output: BaseBodySkinPipeline.Output = try await Task.detached(priority: .userInitiated) {
                    switch source {
                    case .photo, .sheet:
                        guard let f = front.flatMap({ BaseBodySkinPipeline.image($0) }) else { throw BaseBodySkinPipeline.Failure.unreadable }
                        return try BaseBodySkinPipeline.make(base: base, front: f, back: back.flatMap { BaseBodySkinPipeline.image($0) },
                                                             source: source == .sheet ? .sheet : .photo, fitShape: fitShape)
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
                var notes = output.notes
                if backGuessed && output.appearance.painted?.back != nil {
                    notes.append(L10n.t("背面用的是 AI 推测、经你确认的视角。", "The back is an AI-proposed view you confirmed."))
                }
                message = (notes + [L10n.t("已存入角色库：「\(name)」。在 3D 世界 ⋯ → 角色工作台里可以设为玩家或放到世界里。", "Saved to the character library as “\(name)”. In the 3D world, ⋯ → Character Workbench can make it the player or place it.")]).joined(separator: "\n")
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

// MARK: Proposals

/// The proposed views beside the user's front: each is adopted only when the user switches it on.
@available(iOS 18.0, *)
struct ConceptCompletionSheet: View {
    let result: ConceptViewCompletion.Result
    let front: UIImage?
    let onAdopt: ([PhotoView: Data]) -> Void
    @State private var adopted: Set<PhotoView> = []
    @Environment(\.dismiss) private var dismiss

    private var adoptable: Bool { result.route != .estimate }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(adoptable ? L10n.t("核对每个视角是否和你的设定一致，只打开一致的。", "Check each view against your design; switch on only those that match.")
                                   : L10n.t("只能预览，不能采用。", "Preview only; nothing can be adopted."))
                        .font(.subheadline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                        if let front { tile(Image(uiImage: front), title: PhotoView.front.title, badge: ConceptOrigin.user.title) }
                        ForEach(result.proposals) { p in
                            VStack(spacing: 6) {
                                tile(Image(decorative: p.image, scale: 1), title: p.view == ConceptSheetSpec.side ? L10n.t("侧面", "Side") : p.view.title, badge: p.origin.title)
                                if adoptable {
                                    Toggle(L10n.t("采用", "Adopt"), isOn: Binding(get: { adopted.contains(p.view) }, set: { on in if on { adopted.insert(p.view) } else { adopted.remove(p.view) } }))
                                        .font(.caption).accessibilityIdentifier("concept-adopt-" + p.view.rawValue)
                                }
                            }
                        }
                    }
                    ForEach(Array(result.notes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle(L10n.t("补全视角 · ", "Missing views · ") + result.route.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("取消", "Cancel")) { dismiss() } }
                if adoptable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("采用所选", "Adopt selected")) {
                            var out: [PhotoView: Data] = [:]
                            for p in result.proposals where adopted.contains(p.view) { out[p.view] = p.jpeg }
                            onAdopt(out)
                            dismiss()
                        }
                        .disabled(adopted.isEmpty).accessibilityIdentifier("concept-apply")
                    }
                }
            }
        }
    }

    private func tile(_ image: Image, title: String, badge: String) -> some View {
        VStack(spacing: 4) {
            image.resizable().scaledToFit().frame(height: 200).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
        }
    }
}

// MARK: Guide

/// The character-sheet standard: what to draw, why, and how Moonlight uses it.
@available(iOS 18.0, *)
struct ConceptSheetGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.t("需要的视角", "Views")) {
                    ForEach(ConceptSheetSpec.requirements) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: r.view == .front ? "person.fill" : (r.view == .back ? "person.fill.turn.left" : "person.fill.turn.right"))
                                Text(r.title).font(.headline)
                                Text(r.required ? L10n.t("必需", "Required") : L10n.t("推荐", "Recommended"))
                                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill((r.required ? Color.red : Color.accentColor).opacity(0.18)))
                            }
                            Text(r.how).font(.subheadline)
                            Text(r.why).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section(L10n.t("画法规则", "Rules")) {
                    ForEach(Array(ConceptSheetSpec.rules.enumerated()), id: \.offset) { _, rule in Text(rule).font(.subheadline) }
                }
                Section(L10n.t("等级", "Grades")) {
                    ForEach([ConceptSheetReport.Grade.complete, .good, .basic, .notReady], id: \.rawValue) { Text($0.title).font(.subheadline) }
                }
                Section(L10n.t("缺少视角时", "Missing views")) {
                    Text(L10n.t("只有正面时，可以点「补全缺少的视角」：AI 先从正面推测一个 3D 模型，再从背面和侧面画出来，你确认一致后才会使用。AI 看不到背面，推测可能和设定不同；有条件时，自己画的背面和侧面永远更准。",
                                "With only a front, tap Propose missing views: an AI infers a 3D model from the front and draws it from the back and side; nothing is used until you confirm it matches. The AI cannot see the back, so its guess may differ from your design; a back and side you draw are always more accurate."))
                        .font(.subheadline)
                }
            }
            .navigationTitle(L10n.t("设定图规范", "Character-Sheet Standard"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() } } }
        }
    }
}
