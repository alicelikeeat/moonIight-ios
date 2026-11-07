import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// v1.87 AI Asset Director — the 智能素材库 workbench.

@available(iOS 18.0, *)
struct AssetDirectorView: View {
    /// The open 3D world, when opened from there (placement needs it).
    let controller: AnyObject?
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var director = AIAssetDirector.shared
    @ObservedObject private var models = Generated3DStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = AssetQuery()
    @State private var importing = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var cloudPrompt = false

    var body: some View {
        NavigationStack {
            List {
                Group {
                    statusSection
                    importSection
                    filterSection
                    assetsSection
                    suggestionsSection
                    settingsSection
                    evaluationSection
                }
                .listRowBackground(MoonLiquidRowBackground())
            }
            .moonLiquidList()
            .navigationTitle(L10n.t("智能素材库", "Asset Director"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { AssetDetailView(assetID: $0, controller: controller) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { dismiss() }.accessibilityIdentifier("asset-director-done") } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie, .audio, .gif, .item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await director.importFiles(urls, origin: .files, store: model.mediaStore) }
            }
            .onChange(of: photoItems) { picked in importPhotos(picked) }
            .onAppear { AppModelBridge.store = model.mediaStore }
            #if DEBUG
            .overlay(alignment: .topLeading) {
                Text("summary").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false).accessibilityIdentifier("asset-director-summary")
                    .accessibilityValue(SemanticAssetLibrary.sorted(director.state).map { r in
                        "\(r.title)=\(r.primaryCategory?.rawValue ?? "none")+\(r.secondaryCategories.map(\.rawValue).joined(separator: "/")):\(r.decision.rawValue):\(Int((r.confidence?.value ?? 0) * 100)):\(r.recommendedUses.prefix(3).map(\.rawValue).joined(separator: "/"))"
                    }.joined(separator: " | "))
            }
            #endif
            .alert(L10n.t("开启云端视觉分析？", "Turn on cloud vision?"), isPresented: $cloudPrompt) {
                Button(L10n.t("开启", "Turn on")) { director.updateSettings { $0.cloudVision = true } }
                Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.t("之后分析图片和 GIF 时，会把一张最长边 512 像素的 JPEG 缩略图（不含位置等元数据）发送给 Anthropic，使用你在设置里填写的 API 密钥并按其计费。不上传原图、视频或音频。每天最多 \(director.state.settings.cloudDailyLimit) 张，可以随时关闭。",
                            "From now on, for pictures and GIFs a JPEG thumbnail (longest side 512 px, no location or other metadata) is sent to Anthropic with the API key from Settings and billed to it. Originals, videos and audio are never uploaded. At most \(director.state.settings.cloudDailyLimit) a day; you can turn it off any time."))
            }
        }
    }

    // MARK: Status

    private var counts: [AssetStatus: Int] { SemanticAssetLibrary.counts(director.state) }

    private var statusSection: some View {
        Section {
            let c = counts, q = director.state.queue
            HStack(spacing: 14) {
                stat(c[.queued, default: 0], L10n.t("排队", "Queued"))
                stat(c[.analysing, default: 0], L10n.t("分析中", "Running"))
                stat(c[.ready, default: 0], L10n.t("完成", "Done"))
                stat(c[.needsReview, default: 0], L10n.t("待确认", "Review"))
                stat(c[.failed, default: 0], L10n.t("失败", "Failed"))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("asset-director-status")
            .accessibilityValue("queued=\(c[.queued, default: 0]) analysing=\(c[.analysing, default: 0]) ready=\(c[.ready, default: 0]) review=\(c[.needsReview, default: 0]) failed=\(c[.failed, default: 0])")
            HStack {
                Button(q.paused ? L10n.t("继续", "Resume") : L10n.t("暂停", "Pause")) { director.pause(!q.paused) }.accessibilityIdentifier("asset-director-pause")
                Spacer()
                Button(L10n.t("取消全部", "Cancel all"), role: .destructive) { director.cancelAll() }.disabled(q.waiting + q.running == 0)
                Spacer()
                Button(L10n.t("重试失败", "Retry failed")) { director.retryFailed() }.disabled(c[.failed, default: 0] + c[.cancelled, default: 0] == 0)
            }
            .buttonStyle(.borderless).font(.subheadline)
            if let message = director.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("asset-director-message") }
            if let problem = director.loadProblem { Text(problem).font(.caption).foregroundStyle(.orange) }
        } footer: {
            Text(L10n.t("默认只在本机分析。同一内容只分析一次；分析器更新后才会重新分析。", "Analysis runs on this device by default. The same content is analysed once, again only when the analyzer changes."))
        }
    }

    private func stat(_ n: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    // MARK: Import

    private var importSection: some View {
        Section(L10n.t("导入", "Import")) {
            HStack {
                Button { importing = true } label: { Label(L10n.t("文件", "Files"), systemImage: "folder") }.accessibilityIdentifier("asset-director-files")
                Spacer()
                PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .any(of: [.images, .videos])) { Label(L10n.t("相册", "Photos"), systemImage: "photo.on.rectangle") }
                Spacer()
                Button { Task { await director.importLibrary(glass3DMediaItems(model.mediaStore)) } } label: { Label(L10n.t("素材库", "Library"), systemImage: "photo.stack") }
                    .accessibilityIdentifier("asset-director-library")
                Spacer()
                Button { director.importModels(models.models) } label: { Label(L10n.t("3D 模型", "3D models"), systemImage: "cube.transparent") }
                    .accessibilityIdentifier("asset-director-models")
            }
            .buttonStyle(.borderless).labelStyle(.titleAndIcon).font(.caption)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--asset-director-fixtures") {
                Button(L10n.t("导入测试素材（城堡参考、房屋模型、玻璃材质、喷泉视频、人物模型）", "Import test assets")) {
                    Task {
                        AssetDirectorLog.mark("fixtures: writing")
                        let urls = await AssetWork.run { AssetDirectorFixtures.write() }
                        AssetDirectorLog.mark("fixtures: \(urls.count) written")
                        await director.importFiles(urls, origin: .files, store: model.mediaStore)
                    }
                }
                .accessibilityIdentifier("asset-director-import-fixtures")
            }
            #endif
        }
    }

    private func importPhotos(_ picked: [PhotosPickerItem]) {
        photoItems = []
        Task {
            var urls: [URL] = []
            for item in picked { if let file = try? await item.loadTransferable(type: RPGPickedFile.self) { urls.append(file.url) } }
            await director.importFiles(urls, origin: .photos, store: model.mediaStore)
        }
    }

    // MARK: Browse

    private var filterSection: some View {
        Section {
            TextField(L10n.t("搜索标签、名称、用途", "Search tags, names, uses"), text: $query.text).textInputAutocapitalization(.never).accessibilityIdentifier("asset-director-search")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(L10n.t("全部", "All"), selected: query.category == nil && query.status == nil) { query.category = nil; query.status = nil }
                    chip(L10n.t("待确认", "Review"), selected: query.status == .needsReview) { query.status = .needsReview; query.category = nil }
                    ForEach(AssetCategory.allCases) { c in
                        chip(c.title, selected: query.category == c) { query.category = c; query.status = nil }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(selected ? .semibold : .regular)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var assetsSection: some View {
        let results = SemanticAssetLibrary.search(query, in: director.state)
        return Section {
            if results.isEmpty {
                Text(L10n.t("还没有素材。导入图片、视频、GIF、音频或 3D 模型后，这里会显示分析结果。", "No assets yet. Import pictures, videos, GIFs, audio or 3D models to see their analysis.")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(results.prefix(300)) { r in
                NavigationLink(value: r.assetID) { AssetRow(record: r) }
                    .accessibilityIdentifier("asset-row-" + r.title)
            }
            if !results.isEmpty {
                Button(L10n.t("把已分析的素材交给世界导演（\(results.filter { $0.primaryCategory != nil }.count)）", "Send analysed assets to the World Director (\(results.filter { $0.primaryCategory != nil }.count))")) {
                    director.directorPicks.formUnion(results.filter { $0.primaryCategory != nil }.map(\.assetID))
                }
                .accessibilityIdentifier("asset-director-use-all-for-director")
                if !director.directorPicks.isEmpty {
                    Text(L10n.t("世界导演将使用 \(director.directorPicks.count) 个素材", "The World Director will use \(director.directorPicks.count) assets")).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("asset-director-picks")
                }
            }
        } header: { Text(L10n.t("素材（\(results.count)）", "Assets (\(results.count))")) }
    }

    private var suggestionsSection: some View {
        let missing = SemanticAssetLibrary.missingResources(in: director.state)
        let groups = AssetRouter.styleGroups(Array(director.state.records.values), capabilities: director.capabilities)
        return Group {
            if !missing.isEmpty || !groups.isEmpty {
                Section(L10n.t("缺失资源与建议", "Missing resources & suggestions")) {
                    ForEach(missing, id: \.assetID) { item in
                        NavigationLink(value: item.assetID) { Label(item.message, systemImage: "exclamationmark.bubble").font(.caption) }
                    }
                    ForEach(groups) { g in
                        Label(g.reason, systemImage: "paintpalette").font(.caption)
                    }
                }
            }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section {
            Toggle(L10n.t("本地分析（Vision、SoundAnalysis）", "On-device analysis (Vision, SoundAnalysis)"), isOn: .constant(true)).disabled(true)
            Toggle(L10n.t("云端视觉分析（Claude）", "Cloud vision (Claude)"), isOn: Binding(get: { director.state.settings.cloudVision }, set: { on in
                if on { cloudPrompt = true } else { director.updateSettings { $0.cloudVision = false } }
            }))
            .accessibilityIdentifier("asset-director-cloud")
            Stepper(L10n.t("每天最多 \(director.state.settings.cloudDailyLimit) 张", "At most \(director.state.settings.cloudDailyLimit) a day"),
                    value: Binding(get: { director.state.settings.cloudDailyLimit }, set: { v in director.updateSettings { $0.cloudDailyLimit = v } }), in: 1...200)
                .disabled(!director.state.settings.cloudVision)
            Text(L10n.t("今天已用 \(director.state.settings.cloudDay == AssetCloudPolicy.day(Date()) ? director.state.settings.cloudUsedToday : 0) 张。", "Used today: \(director.state.settings.cloudDay == AssetCloudPolicy.day(Date()) ? director.state.settings.cloudUsedToday : 0)."))
                .font(.caption2).foregroundStyle(.secondary)
        } header: { Text(L10n.t("隐私与成本", "Privacy & cost")) } footer: {
            Text(L10n.t("云端分析与世界导演的「AI 规划」是两个独立权限：后者只发送文字和颜色。网络失败时本地分析照常进行。", "Cloud vision is a separate permission from the World Director's AI planning, which only sends text and colours. Local analysis carries on when the network fails."))
        }
    }

    private var evaluationSection: some View {
        Section {
            Button(director.evaluating ? L10n.t("评测中…", "Evaluating…") : L10n.t("用内置素材评测分类", "Evaluate on the bundled assets")) { Task { await director.evaluateStarterPack() } }
                .disabled(director.evaluating).accessibilityIdentifier("asset-director-evaluate")
            if let e = director.state.lastEvaluation {
                let cal = director.state.calibration
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("样本 \(e.samples) · Top-1 \(String(format: "%.1f", e.top1 * 100))% · Top-3 \(String(format: "%.1f", e.top3 * 100))%",
                                "\(e.samples) samples · top-1 \(String(format: "%.1f", e.top1 * 100))% · top-3 \(String(format: "%.1f", e.top3 * 100))%")).font(.caption.weight(.semibold))
                    Text(e.perCategory.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                    Text(cal.fitted ? L10n.t("阈值已按评测样本校准：自动 ≥ \(String(format: "%.2f", cal.automatic))，候选 ≥ \(String(format: "%.2f", cal.candidates))", "Thresholds fitted: automatic ≥ \(String(format: "%.2f", cal.automatic)), candidates ≥ \(String(format: "%.2f", cal.candidates))")
                         : L10n.t("样本不足，仍使用初始阈值（分数不代表准确率）", "Too few samples; starter thresholds (scores are not accuracy)")).font(.caption2).foregroundStyle(.secondary)
                    ForEach(e.confusions.prefix(6), id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("asset-director-evaluation")
                .accessibilityValue("samples=\(e.samples) top1=\(String(format: "%.3f", e.top1)) top3=\(String(format: "%.3f", e.top3)) fitted=\(cal.fitted)")
            }
        } header: { Text(L10n.t("准确率评测", "Accuracy check")) } footer: {
            Text(L10n.t("评测集是内置的 Kenney 角色（CC0）和 Poly Haven 贴图（CC0），只有角色与材质两类，样本少，不能代表所有素材。", "The set is the bundled Kenney characters (CC0) and Poly Haven textures (CC0): only two categories and few samples, not representative of all assets."))
        }
    }
}

// MARK: Row

@available(iOS 18.0, *)
struct AssetRow: View {
    let record: AssetIntelligenceRecord
    var body: some View {
        HStack(spacing: 10) {
            AssetThumbnail(record: record, side: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title.isEmpty ? record.assetID : record.title).font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(record.categories.prefix(3), id: \.self) { c in
                        Label(c.title, systemImage: c.symbol).font(.caption2).labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    if record.categories.isEmpty { Text(record.status.title).font(.caption2).foregroundStyle(.orange) }
                }
                Text(statusLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(record.primaryCategory?.rawValue ?? record.status.rawValue)
    }
    private var statusLine: String {
        var parts = [record.status.title]
        if let c = record.confidence { parts.append(c.kind == .user ? L10n.t("已确认", "Confirmed") : L10n.t("分数 \(Int(c.value * 100))", "score \(Int(c.value * 100))")) }
        if record.locks.contains(.category) { parts.append(L10n.t("已锁定", "Locked")) }
        return parts.joined(separator: " · ")
    }
}

/// A small preview made off the main thread (first frame for video).
@available(iOS 18.0, *)
struct AssetThumbnail: View {
    let record: AssetIntelligenceRecord
    let side: CGFloat
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: icon).foregroundStyle(.secondary) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: record.assetID) {
            guard let url = AIAssetDirector.shared.fileURL(record.storage) else { return }
            let type = record.mediaType, px = Int(side * 3)
            let cg: CGImage? = await Task.detached(priority: .utility) {
                switch type {
                case .image, .gif: return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { VisualSemanticAnalyzer.thumbnail($0, side: px) }
                case .video:
                    let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: px, height: px)
                    return try? await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
                default: return nil
                }
            }.value
            if let cg { image = UIImage(cgImage: cg) }
        }
    }
    private var icon: String {
        switch record.mediaType { case .model: "cube.transparent"; case .audio: "waveform"; case .video: "film"; case .gif: "sparkles.rectangle.stack"; case .image: "photo" }
    }
}

// MARK: Detail

@available(iOS 18.0, *)
struct AssetDetailView: View {
    let assetID: String
    let controller: AnyObject?
    @ObservedObject private var director = AIAssetDirector.shared
    @State private var newTag = ""
    @State private var pending: AssetTaskSuggestion?
    @State private var result: String?
    @State private var working = false
    @State private var deleteRefs: [String]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let r = director.state.records[assetID] {
            List {
                Group {
                    previewSection(r)
                    categorySection(r)
                    tagsSection(r)
                    usesSection(r)
                    routesSection(r)
                    relationsSection(r)
                    technicalSection(r)
                    provenanceSection(r)
                    historySection(r)
                }
                .listRowBackground(MoonLiquidRowBackground())
            }
            .moonLiquidList()
            .navigationTitle(r.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(pending?.operation.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let task = pending {
                    Button(L10n.t("确认执行", "Run it")) { run(task) }
                    Button(L10n.t("取消", "Cancel"), role: .cancel) { pending = nil }
                }
            } message: {
                if let t = pending {
                    Text([L10n.t("输出：", "Output: ") + t.output,
                          t.prerequisites.isEmpty ? nil : L10n.t("前提：", "Needs: ") + t.prerequisites.joined(separator: "、"),
                          L10n.t("成本：", "Cost: ") + t.cost.title,
                          t.external ? L10n.t("会通过网络调用外部服务", "Calls an outside service over the network") : L10n.t("只在本机处理", "Runs on this device only"),
                          L10n.t("失败时：", "If it fails: ") + t.fallback].compactMap { $0 }.joined(separator: "\n"))
                }
            }
            .alert(L10n.t("仍在使用中", "Still in use"), isPresented: Binding(get: { deleteRefs != nil }, set: { if !$0 { deleteRefs = nil } })) {
                Button(L10n.t("仍然移除分析记录", "Remove the record anyway"), role: .destructive) { director.removeRecord(assetID); dismiss() }
                Button(L10n.t("保留", "Keep"), role: .cancel) {}
            } message: {
                Text((deleteRefs ?? []).joined(separator: "\n") + "\n" + L10n.t("移除的只是分析记录；原文件和世界里的引用都会保留。", "Only the analysis record goes; the file and the world's references stay."))
            }
        } else {
            Text(L10n.t("素材已移除", "Asset removed")).foregroundStyle(.secondary)
        }
    }

    private func run(_ task: AssetTaskSuggestion) {
        pending = nil; working = true; result = nil
        Task { result = await director.run(task, controller: controller); working = false }
    }

    private func previewSection(_ r: AssetIntelligenceRecord) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                AssetThumbnail(record: r, side: 110)
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.status.title).font(.caption.weight(.semibold))
                    if let c = r.confidence {
                        Text(c.kind == .user ? L10n.t("你已确认", "Confirmed by you") : c.kind == .calibrated ? L10n.t("校准分数 \(Int(c.value * 100))", "Calibrated \(Int(c.value * 100))")
                             : L10n.t("模型分数 \(Int(c.value * 100))（未校准，不是准确率）", "Model score \(Int(c.value * 100)) (uncalibrated, not accuracy)")).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(r.evidence.prefix(5), id: \.self) { Text("• " + $0).font(.caption2) }
                }
            }
            if working { ProgressView() }
            if let result { Text(result).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("asset-detail-result") }
        }
    }

    private func categorySection(_ r: AssetIntelligenceRecord) -> some View {
        Section {
            Picker(L10n.t("主要类别", "Main category"), selection: Binding(get: { r.primaryCategory }, set: { c in
                if let c { director.setCategory(r.assetID, primary: c, secondary: r.secondaryCategories) }
            })) {
                Text(L10n.t("待确认", "Unconfirmed")).tag(AssetCategory?.none)
                ForEach(AssetCategory.allCases) { Text($0.title).tag(AssetCategory?.some($0)) }
            }
            .accessibilityIdentifier("asset-detail-category")
            ForEach(AssetCategory.allCases.filter { $0 != r.primaryCategory }) { c in
                Toggle(L10n.t("也属于：", "Also: ") + c.title, isOn: Binding(get: { r.secondaryCategories.contains(c) }, set: { on in
                    guard let primary = r.primaryCategory ?? r.candidates.first?.category else { return }
                    var s = r.secondaryCategories.filter { $0 != c }; if on { s.append(c) }
                    director.setCategory(r.assetID, primary: primary, secondary: s)
                }))
                .font(.caption)
            }
            if !r.candidates.isEmpty {
                Text(L10n.t("候选：", "Candidates: ") + r.candidates.prefix(3).map { "\($0.category.title) \(Int($0.score * 100))" }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            Toggle(L10n.t("锁定分类（重新分析不改动）", "Lock category (re-analysis keeps it)"), isOn: Binding(get: { r.locks.contains(.category) }, set: { director.setLock(r.assetID, .category, $0) }))
        } header: { Text(L10n.t("分类", "Category")) }
    }

    private func tagsSection(_ r: AssetIntelligenceRecord) -> some View {
        Section(L10n.t("标签", "Tags")) {
            ForEach(r.semanticTags, id: \.name) { tag in
                HStack {
                    Text(tag.name).font(.caption)
                    Spacer()
                    Text("\(tag.source.rawValue) \(Int(tag.score * 100))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Button { director.removeTag(r.assetID, tag.name) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                        .accessibilityLabel(L10n.t("移除标签 \(tag.name)", "Remove tag \(tag.name)"))
                }
            }
            ForEach(r.userTags, id: \.self) { tag in
                HStack {
                    Label(tag, systemImage: "person.crop.circle").font(.caption)
                    Spacer()
                    Button { director.removeTag(r.assetID, tag) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(L10n.t("添加自定义标签", "Add a custom tag"), text: $newTag).font(.caption)
                Button(L10n.t("添加", "Add")) { director.addTag(r.assetID, newTag); newTag = "" }.disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !r.styleTags.isEmpty { Text(L10n.t("风格：", "Style: ") + r.styleTags.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary) }
            if !r.dominantColors.isEmpty {
                HStack(spacing: 4) { ForEach(r.dominantColors, id: \.self) { hex in RoundedRectangle(cornerRadius: 3).fill(Color(hex: hex)).frame(width: 22, height: 14) } }
                    .accessibilityLabel(L10n.t("主色 ", "Main colours ") + r.dominantColors.joined(separator: " "))
            }
        }
    }

    private func usesSection(_ r: AssetIntelligenceRecord) -> some View {
        Section(L10n.t("推荐用途", "Recommended uses")) {
            if r.recommendedUses.isEmpty { Text(L10n.t("暂无（请选择分类）", "None yet (choose a category)")).font(.caption).foregroundStyle(.secondary) }
            ForEach(r.recommendedUses, id: \.self) { Text($0.title).font(.caption) }
            if !r.sceneContext.isEmpty { Text(L10n.t("适合：", "Fits: ") + r.sceneContext.map(\.rawValue).joined(separator: "、")).font(.caption2).foregroundStyle(.secondary) }
            if let why = AssetWorldMatcher.blocker(r) { Label(why, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange) }
            Toggle(L10n.t("交给世界导演使用", "Use in the World Director"), isOn: Binding(get: { director.directorPicks.contains(r.assetID) }, set: { on in
                if on { director.directorPicks.insert(r.assetID) } else { director.directorPicks.remove(r.assetID) }
            }))
        }
    }

    private func routesSection(_ r: AssetIntelligenceRecord) -> some View {
        let routes = AssetRouter.route(r, capabilities: director.capabilities)
        return Section(L10n.t("专业处理", "Processing")) {
            if routes.isEmpty { Text(L10n.t("没有可用的处理建议", "No suggestions")).font(.caption).foregroundStyle(.secondary) }
            ForEach(routes) { t in
                Button {
                    if t.state.usable { if t.needsConfirmation { pending = t } else { run(t) } }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.module.title + " · " + t.operation.title).font(.subheadline)
                        Text(t.reason).font(.caption2).foregroundStyle(.secondary)
                        switch t.state {
                        case .available: EmptyView()
                        case .needsSetup(let why): Text(why).font(.caption2).foregroundStyle(.orange)
                        case .unavailable(let why): Text(why).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!t.state.usable || working)
                .accessibilityIdentifier("asset-route-" + t.operation.rawValue)
            }
        }
    }

    private func relationsSection(_ r: AssetIntelligenceRecord) -> some View {
        let rels = SemanticAssetLibrary.relationships(of: r.assetID, in: director.state)
        return Group {
            if !rels.isEmpty {
                Section(L10n.t("关联素材", "Linked assets")) {
                    ForEach(rels, id: \.self) { rel in
                        let other = rel.from == r.assetID ? rel.to : rel.from
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(rel.kind.rawValue) · \(director.state.records[other]?.title ?? other)").font(.caption)
                            Text(rel.confirmed ? L10n.t("已确认", "Confirmed") : (rel.note ?? L10n.t("建议，待确认", "Suggested, unconfirmed"))).font(.caption2).foregroundStyle(.secondary)
                            if !rel.confirmed {
                                HStack {
                                    Button(L10n.t("确认", "Confirm")) { director.confirmRelation(rel, accept: true) }
                                    Button(L10n.t("不是", "No"), role: .destructive) { director.confirmRelation(rel, accept: false) }
                                }.buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    private func technicalSection(_ r: AssetIntelligenceRecord) -> some View {
        let t = r.signals?.technical ?? AssetTechnicalInfo()
        var rows: [(String, String)] = []
        if let w = t.pixelWidth, let h = t.pixelHeight { rows.append((L10n.t("尺寸", "Size"), "\(w)×\(h)")) }
        if let a = t.transparentShare { rows.append((L10n.t("透明区域", "Transparent"), "\(Int(a * 100))%")) }
        if let d = t.duration { rows.append((L10n.t("时长", "Length"), String(format: "%.1f s", d))) }
        if let f = t.frameRate { rows.append((L10n.t("帧率", "Frame rate"), String(format: "%.1f", f))) }
        if let n = t.sampledTimes?.count { rows.append((L10n.t("分析帧", "Frames analysed"), "\(n)")) }
        if let v = t.triangleCount { rows.append((L10n.t("三角面", "Triangles"), "\(v)")) }
        if let s = t.hasSkeleton { rows.append((L10n.t("骨骼", "Skeleton"), s ? "\(t.jointCount ?? 0)" : L10n.t("无", "none"))) }
        if let clips = t.animationNames { rows.append((L10n.t("动作", "Clips"), clips.isEmpty ? L10n.t("无", "none") : clips.joined(separator: ", "))) }
        if let g = t.gpuBytesEstimate { rows.append((L10n.t("预计显存", "GPU memory"), ByteCountFormatter.string(fromByteCount: Int64(g), countStyle: .memory))) }
        if let ok = t.realityKitReady { rows.append(("RealityKit", ok ? L10n.t("可用", "Ready") : (t.realityKitNote ?? L10n.t("不可用", "Not ready")))) }
        if let rms = t.rmsDecibels { rows.append((L10n.t("响度", "Level"), String(format: "%.0f dB", rms))) }
        if let ch = t.channels { rows.append((L10n.t("声道", "Channels"), "\(ch)")) }
        for seg in r.signals?.motionSegments ?? [] { rows.append((L10n.t("人体动作", "Body motion"), String(format: "%.1f–%.1f s · %d%%", seg.start, seg.end, Int(seg.score * 100)))) }
        return Section(L10n.t("技术信息", "Technical")) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack { Text(row.0).font(.caption); Spacer(); Text(row.1).font(.caption.monospacedDigit()).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            }
        }
    }

    private func provenanceSection(_ r: AssetIntelligenceRecord) -> some View {
        Section {
            TextField(L10n.t("授权（如 CC0 1.0）", "Licence (e.g. CC0 1.0)"), text: Binding(get: { r.provenance.licenseName ?? "" }, set: { v in
                var p = r.provenance; p.licenseName = v.isEmpty ? nil : String(v.prefix(80)); director.setProvenance(r.assetID, p)
            })).font(.caption)
            TextField(L10n.t("作者", "Author"), text: Binding(get: { r.provenance.author ?? "" }, set: { v in
                var p = r.provenance; p.author = v.isEmpty ? nil : String(v.prefix(80)); director.setProvenance(r.assetID, p)
            })).font(.caption)
            permission(L10n.t("商业用途", "Commercial use"), r.provenance.commercialUse) { v in var p = r.provenance; p.commercialUse = v; director.setProvenance(r.assetID, p) }
            permission(L10n.t("修改", "Modification"), r.provenance.modification) { v in var p = r.provenance; p.modification = v; director.setProvenance(r.assetID, p) }
            permission(L10n.t("在自己的世界里使用", "Use in my worlds"), r.provenance.personalUse) { v in var p = r.provenance; p.personalUse = v; director.setProvenance(r.assetID, p) }
        } header: { Text(L10n.t("来源与授权", "Source & licence")) } footer: {
            Text(L10n.t("来源：\(r.provenance.origin.rawValue)。能加载不代表允许商用；未知授权保持「未知」。", "Source: \(r.provenance.origin.rawValue). Loading is not a licence; unknown stays unknown."))
        }
    }

    private func permission(_ title: String, _ value: AssetPermission, _ set: @escaping (AssetPermission) -> Void) -> some View {
        Picker(title, selection: Binding(get: { value }, set: set)) {
            ForEach([AssetPermission.unknown, .allowed, .denied], id: \.self) { Text($0.title).tag($0) }
        }.font(.caption)
    }

    private func historySection(_ r: AssetIntelligenceRecord) -> some View {
        Section {
            if let a = r.analysis {
                Text("\(a.analyzerID) v\(a.analyzerVersion) · \(a.cloud ? L10n.t("含云端", "with cloud") : L10n.t("本机", "on device")) · \(a.milliseconds) ms").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(r.failures.suffix(3).enumerated()), id: \.offset) { _, f in Text(f.message).font(.caption2).foregroundStyle(.red) }
            ForEach(Array(r.corrections.suffix(5).enumerated()), id: \.offset) { _, c in
                Text("\(c.field.rawValue): \(c.before) → \(c.after)").font(.caption2).foregroundStyle(.secondary)
            }
            Button(L10n.t("重新分析", "Analyse again")) { director.reanalyse([r.assetID]) }
            Button(L10n.t("移除分析记录", "Remove the record"), role: .destructive) {
                let refs = director.references(r.assetID)
                if refs.isEmpty { director.removeRecord(r.assetID); dismiss() } else { deleteRefs = refs }
            }
        } header: { Text(L10n.t("记录", "History")) }
    }
}

private extension Color {
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}
