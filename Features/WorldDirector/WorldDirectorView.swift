import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// v1.81 World Director screen: theme → words → assets → options → three
// candidates with top-down previews and quality scores → build the chosen
// one (one undo step). For a world made here: regenerate layers (near the
// camera or everywhere), change the sky, lock blocks, restore the old world.

@available(iOS 18.0, *)
struct WorldDirectorSheet: View {
    @ObservedObject var controller: Glass3DController
    @ObservedObject var store: MediaStore
    var onClassic: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var models = Generated3DStore.shared

    @State private var theme = WorldTheme.skyCity
    @State private var prompt = ""
    @State private var time: WorldTimeOfDay?
    @State private var density = ContentDensity.medium
    @State private var difficulty = GameDifficulty.normal
    @State private var tier = WorldDirectorSheet.deviceTier
    @State private var seed: UInt64 = UInt64.random(in: 1...999_999_999)
    @State private var useAI = false
    @State private var chosenMedia: Set<String> = []
    @State private var chosenModels: Set<String> = []
    @State private var pickingLibrary = false
    @State private var browsingOnline = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importingFiles = false

    @StateObject private var progress = WorldDirectorProgress()
    @State private var flag = WorldDirectorCancelFlag()
    @State private var candidates: [WorldCandidate] = []
    @State private var previews: [String: UIImage] = [:]
    @State private var notes: [String] = []
    @State private var message: String?

    @State private var regenLayers: Set<WorldLayer> = [.buildings, .plants, .decorations]
    @State private var nearCamera = true
    @State private var regenerating = false

    /// Device tier from memory (to be tuned with on-device measurements).
    static var deviceTier: WorldPerformanceTier {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gb < 4.5 ? .low : gb < 7 ? .standard : .high
    }
    private var hasKey: Bool { SecureSettings.read(ClaudeMotion.keyAccount)?.isEmpty == false }

    var body: some View {
        NavigationStack {
            Form { Group {
                if controller.world.director != nil { currentWorld }
                themeSection
                Section(L10n.t("描述（可选）", "Description (optional)")) {
                    TextField(L10n.t("例如：纯白玻璃王国，漂浮在云海上，有水晶宫殿、空中花园、桥梁和动态影像墙", "e.g. a white glass kingdom above a cloud sea with a crystal palace, sky gardens, bridges and a video wall"),
                              text: $prompt, axis: .vertical)
                        .lineLimit(2...5).accessibilityIdentifier("world-director-prompt")
                    Toggle(isOn: $useAI) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("用 Claude 理解描述", "Let Claude read the description"))
                            Text(hasKey ? L10n.t("只发送文字和素材类型、颜色，不发送照片；一次请求约 1–2 千 token，用你的密钥计费。失败或 30 秒无回应时自动改用本机规则。", "Sends only the words and asset kinds / colours, never the pictures; about 1–2k tokens per request on your key. Falls back to on-device rules on failure or after 30 s.")
                                        : L10n.t("需要先在「AI 生成 3D 模型」里填写 Claude API 密钥；不填也能离线生成。", "Add a Claude API key under AI 3D Models first; generation also works offline without it."))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!hasKey)
                }
                assetsSection
                optionsSection
                generateSection
                if !candidates.isEmpty { candidatesSection }
                Section {
                    Button(L10n.t("改用经典随机生成器", "Use the classic random generator")) { dismiss(); onClassic() }
                        .font(.footnote)
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }.moonLiquidList()
            .navigationTitle(L10n.t("世界导演", "World Director")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.t("关闭", "Close")) { flag.set(); dismiss() } } }
            .sheet(isPresented: $pickingLibrary) { libraryPicker }
            .sheet(isPresented: $browsingOnline) {
                Glass3DOnlineAssetsView(store: store) { entry in chosenMedia.insert(entry.id) }
            }
            .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.image, .gif, .movie], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { importFiles(urls) }
            }
            .onChange(of: photoItems) { _, picked in if !picked.isEmpty { importPhotos(picked) } }
        }
    }

    // MARK: Current world

    private var currentWorld: some View {
        Section {
            if let record = controller.world.director {
                Label(record.blueprint.theme.title + " · " + record.intentSummary, systemImage: record.blueprint.theme.symbol).font(.subheadline).lineLimit(2)
            }
            ForEach(WorldLayer.allCases, id: \.self) { layer in
                Toggle(layer.title, isOn: Binding(get: { regenLayers.contains(layer) }, set: { on in if on { regenLayers.insert(layer) } else { regenLayers.remove(layer) } }))
            }
            Toggle(L10n.t("只改镜头附近（约 24 格）", "Only near the camera (about 24 cells)"), isOn: $nearCamera)
            Button {
                regenerating = true; message = nil
                Task {
                    defer { regenerating = false }
                    do { notes = try await controller.regenerateDirector(layers: regenLayers, nearCamera: nearCamera); message = L10n.t("已重新生成，可撤销", "Regenerated; undo is available") }
                    catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                }
            } label: { Label(regenerating ? L10n.t("正在重新生成…", "Regenerating…") : L10n.t("重新生成选中的部分", "Regenerate the chosen parts"), systemImage: "arrow.triangle.2.circlepath") }
                .disabled(regenLayers.isEmpty || regenerating).accessibilityIdentifier("world-director-regenerate")
            Picker(L10n.t("天空与光照", "Sky & light"), selection: Binding(get: { controller.world.atmosphere?.timeOfDay ?? .day }, set: { controller.relightDirector($0) })) {
                ForEach(WorldTimeOfDay.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Button { controller.lockSelection() } label: { Label(L10n.t("锁定选中的方块（重新生成不会改动）", "Lock the selected blocks (regeneration keeps them)"), systemImage: "lock") }
                .disabled(controller.selection.isEmpty)
            if controller.canRestoreBeforeDirector {
                Button(role: .destructive) { controller.restoreBeforeDirector(); dismiss() } label: { Label(L10n.t("恢复生成前的世界", "Restore the world before generating"), systemImage: "clock.arrow.circlepath") }
            }
        } header: { Text(L10n.t("当前世界", "This world")) } footer: {
            Text(L10n.t("你搭建或改动过的方块、生物和物品永远不会被重新生成覆盖。每次重新生成都可以撤销。", "Blocks, creatures and items you built or changed are never replaced. Every regeneration can be undone."))
        }
    }

    // MARK: Theme

    private var themeSection: some View {
        Section(L10n.t("世界模板", "World template")) {
            ForEach(WorldTheme.allCases) { t in
                Button { theme = t; candidates = [] } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.symbol).font(.title3).frame(width: 34).foregroundStyle(theme == t ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(t.summary).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if theme == t { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                    }
                }
                .accessibilityAddTraits(theme == t ? .isSelected : []).accessibilityIdentifier("world-director-theme-" + t.rawValue)
            }
        }
    }

    // MARK: Assets

    private var assetsSection: some View {
        Section {
            HStack {
                Button { pickingLibrary = true } label: { Label(L10n.t("素材库", "Library"), systemImage: "photo.stack") }
                Spacer()
                PhotosPicker(selection: $photoItems, maxSelectionCount: 12, matching: .any(of: [.images, .videos])) { Label(L10n.t("相册", "Photos"), systemImage: "photo.on.rectangle") }
                Spacer()
                Button { importingFiles = true } label: { Label(L10n.t("文件", "Files"), systemImage: "folder") }
                Spacer()
                Button { browsingOnline = true } label: { Label(L10n.t("网络", "Online"), systemImage: "globe") }
            }
            .buttonStyle(.borderless).labelStyle(.titleAndIcon).font(.caption)
            if !chosenMedia.isEmpty || !chosenModels.isEmpty {
                Text(L10n.t("已选 \(chosenMedia.count) 个图片 / 视频，\(chosenModels.count) 个 3D 模型", "\(chosenMedia.count) pictures / videos, \(chosenModels.count) 3D models chosen")).font(.caption)
            }
            if !AIAssetDirector.shared.directorPicks.isEmpty {
                Text(L10n.t("另有智能素材库的 \(AIAssetDirector.shared.directorPicks.count) 个已分析素材", "Plus \(AIAssetDirector.shared.directorPicks.count) analysed assets from the Asset Director"))
                    .font(.caption).accessibilityIdentifier("world-director-smart-assets")
            }
        } header: { Text(L10n.t("素材（可选）", "Assets (optional)")) } footer: {
            Text(L10n.t("照片和视频会放进画廊墙、影像屏和广告牌，AI 3D 模型会站在出生点附近。照片只保存在手机里；网络素材只使用允许商用和改编的授权，并记入「素材来源与授权」。", "Pictures and videos go on gallery walls, screens and billboards; AI 3D models stand near the start. Photos stay on the phone; online assets only with licences that allow commercial use and changes, recorded under Credits."))
        }
    }

    private var libraryPicker: some View {
        NavigationStack {
            List { Group {
                Section(L10n.t("图片与视频", "Pictures & videos")) {
                    ForEach(glass3DMediaItems(store)) { item in
                        Button { toggle(&chosenMedia, item.id) } label: {
                            HStack {
                                Image(systemName: item.kind == .video ? "film" : item.kind == .gif ? "sparkles.rectangle.stack" : "photo")
                                Text(item.title).lineLimit(1).foregroundStyle(.primary)
                                Spacer()
                                if chosenMedia.contains(item.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
                let usable = models.models.filter { $0.meshFile != nil }
                if !usable.isEmpty {
                    Section(L10n.t("AI 生成的 3D 模型", "AI 3D models")) {
                        ForEach(usable) { m in
                            Button { toggle(&chosenModels, m.id) } label: {
                                HStack {
                                    Image(systemName: "cube.transparent")
                                    Text(m.name).lineLimit(1).foregroundStyle(.primary)
                                    Spacer()
                                    if chosenModels.contains(m.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    }
                }
                }.listRowBackground(MoonLiquidRowBackground())
            }.moonLiquidList()
            .navigationTitle(L10n.t("选择素材", "Choose assets")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.t("完成", "Done")) { pickingLibrary = false } } }
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) { if set.contains(id) { set.remove(id) } else { set.insert(id) } }

    private func importPhotos(_ picked: [PhotosPickerItem]) {
        photoItems = []
        Task {
            for item in picked {
                guard let file = try? await item.loadTransferable(type: RPGPickedFile.self) else { continue }
                let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
                if let entry = await store.importLocalFile(file.url, title: video ? L10n.t("世界视频", "World video") : L10n.t("世界图片", "World photo"), kind: video ? .video : .image) {
                    chosenMedia.insert(entry.id)
                }
                try? FileManager.default.removeItem(at: file.url)
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                let video = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
                if let entry = await store.importLocalFile(url, title: url.deletingPathExtension().lastPathComponent, kind: video ? .video : .image) { chosenMedia.insert(entry.id) }
                if access { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: Options

    private var optionsSection: some View {
        Section(L10n.t("选项", "Options")) {
            Picker(L10n.t("时间", "Time of day"), selection: $time) {
                Text(L10n.t("按模板", "Theme default")).tag(WorldTimeOfDay?.none)
                ForEach(WorldTimeOfDay.allCases, id: \.self) { Text($0.title).tag(WorldTimeOfDay?.some($0)) }
            }
            Picker(L10n.t("内容密度", "Density"), selection: $density) { ForEach(ContentDensity.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker(L10n.t("难度", "Difficulty"), selection: $difficulty) { ForEach(GameDifficulty.allCases, id: \.self) { Text($0.title).tag($0) } }
            Picker(L10n.t("设备性能", "Device budget"), selection: $tier) {
                Text(L10n.t("省电", "Light")).tag(WorldPerformanceTier.low)
                Text(L10n.t("标准", "Standard")).tag(WorldPerformanceTier.standard)
                Text(L10n.t("高", "High")).tag(WorldPerformanceTier.high)
            }
            HStack {
                Text(L10n.t("种子 \(seed)", "Seed \(seed)")).monospacedDigit().font(.footnote)
                Spacer()
                Button(L10n.t("换一个", "New")) { seed = UInt64.random(in: 1...999_999_999); candidates = [] }
            }
        }
    }

    // MARK: Generate

    private var generateSection: some View {
        Section {
            if let stage = progress.stage {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(stage.title).font(.subheadline); Spacer(); Button(L10n.t("取消", "Cancel")) { flag.set() } }
                    ProgressView(value: progress.fraction)
                }
            } else {
                Button { generate() } label: {
                    Label(L10n.t("生成三个方案", "Make three candidates"), systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.moonLiquidProminent).accessibilityIdentifier("world-director-generate")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            ForEach(notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func generate() {
        candidates = []; previews = [:]; notes = []; message = nil
        let flag = WorldDirectorCancelFlag(); self.flag = flag
        let box = progress
        box.stage = .assets; box.fraction = 0
        let mediaItems = glass3DMediaItems(store).filter { chosenMedia.contains($0.id) }
        let attributions = Glass3DAttributions.shared.byMedia
        let modelAssets = models.models.filter { chosenModels.contains($0.id) }.map { WorldAssetReader.model(id: $0.id, title: $0.name, triangles: $0.triangleCount) }
        Task {
            defer { box.stage = nil }
            let entries = mediaItems.map { item -> (id: String, title: String, url: URL?, kind: RPGMediaKind, source: AssetSourceType, license: String?) in
                let attribution = attributions[item.id]
                let source: AssetSourceType = attribution == nil ? .library : (attribution!.provider.contains("Kenney") ? .builtin : .internet)
                return (item.id, item.title, item.url, item.kind, source, attribution?.license)
            }
            var request = WorldGenerationRequest(theme: theme, prompt: prompt, seed: seed, timeOfDay: time, density: density, difficulty: difficulty, tier: tier)
            request.assets = await WorldAssetReader.describe(entries: entries) + modelAssets
            // v1.87: analysed assets from the Asset Director, with their roles; every use and skip is listed.
            let picks = AIAssetDirector.shared.directorPicks
            if !picks.isEmpty {
                let selection = AIAssetDirector.shared.worldSelection(picks, theme: theme)
                request.assets += selection.descriptors
                notes += selection.usage.map { L10n.t("素材「\($0.title)」：", "Asset “\($0.title)”: ") + ($0.role?.title ?? "") + " · " + $0.reason }
                notes += selection.skipped.map { L10n.t("未使用「\($0.title)」：", "Not used “\($0.title)”: ") + $0.reason }
            }
            var intent: WorldIntent? = nil, planner = "local"
            if useAI, let key = SecureSettings.read(ClaudeMotion.keyAccount) {
                box.stage = .planning
                let result = await WorldPlanningRunner.intent(ClaudeWorldPlanner(apiKey: key), request: request, assets: request.assets, seconds: 30)
                let resolved = WorldIntentResolver.resolve(ai: result, request: request)
                intent = resolved.intent; planner = resolved.planner
                if let note = resolved.note { notes.append(note) }
            }
            do {
                let found = try await controller.directorCandidates(request, intent: intent, planner: planner, flag: flag) { s, f in
                    Task { @MainActor in box.stage = s; box.fraction = f }
                }
                candidates = found
                notes += found.first?.blueprint.generationMetadata.notes.dropFirst() ?? []
                for c in found {
                    if let cg = ModelAnimationExport.cgImage(WorldPreview.raster(c.output.world, blueprint: c.blueprint)) { previews[c.id] = UIImage(cgImage: cg) }
                }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: Candidates

    private var candidatesSection: some View {
        Section {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, c in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        if let image = previews[c.id] {
                            Image(uiImage: image).resizable().interpolation(.none).frame(width: 112, height: 112).clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel(L10n.t("方案 \(index + 1) 俯视预览", "Candidate \(index + 1) map preview"))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.t("方案 \(index + 1) · 评分 \(Int(c.report.total))", "Candidate \(index + 1) · score \(Int(c.report.total))")).font(.subheadline.weight(.semibold))
                            Text(c.blueprint.landmarkPlan.kind.title + " · " + c.blueprint.lightingProfile.timeOfDay.title).font(.caption)
                            score(L10n.t("构图", "Composition"), c.report.composition)
                            score(L10n.t("协调", "Harmony"), c.report.harmony)
                            score(L10n.t("光照配色", "Light & colour"), c.report.lighting)
                            score(L10n.t("探索", "Exploration"), c.report.exploration)
                            score(L10n.t("性能", "Performance"), c.report.performance)
                            Text(L10n.t("\(c.report.blocks) 方块 · \(c.report.plants) 植物 · \(c.report.creatures) 生物", "\(c.report.blocks) blocks · \(c.report.plants) plants · \(c.report.creatures) creatures"))
                                .font(.caption2).foregroundStyle(.secondary)
                            if !c.report.passed { Text(L10n.t("未通过：", "Failed: ") + c.report.violations.joined(separator: ", ")).font(.caption2).foregroundStyle(.red) }
                        }
                    }
                    Button {
                        controller.applyDirector(c)
                        dismiss()
                    } label: { Label(L10n.t("用这个方案搭建世界", "Build this world"), systemImage: "checkmark.circle").frame(maxWidth: .infinity) }
                        .buttonStyle(.moonLiquid).disabled(!c.report.passed)
                        .accessibilityIdentifier("world-director-apply-\(index)")
                }
                .padding(.vertical, 4)
            }
        } header: { Text(L10n.t("候选方案", "Candidates")) } footer: {
            Text(L10n.t("黄点是出生点，粉点是主地标。搭建后会替换之前生成的内容，你自己搭建的东西保留；可以撤销或「恢复生成前的世界」。", "Yellow: start. Pink: main landmark. Building replaces earlier generated content and keeps what you built; undo or restore is available."))
        }
    }

    private func score(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).frame(width: 64, alignment: .leading)
            ProgressView(value: min(100, max(0, value)), total: 100).frame(width: 70)
            Text("\(Int(value))").font(.caption2.monospacedDigit())
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(title) \(Int(value))")
    }
}

/// Progress of a run (main-actor box the background work can update).
@MainActor final class WorldDirectorProgress: ObservableObject {
    @Published var stage: WorldGenerationStage?
    @Published var fraction = 0.0
}
