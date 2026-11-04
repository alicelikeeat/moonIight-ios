import SwiftUI
import RealityKit
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

// AI 3D generation screens (v1.67): pick a picture or video, follow real
// stage progress (cancellable), then preview, edit the look, save, export.
// Opened from the 3D world's menu; everything stays on the device.

@available(iOS 18.0, *)
struct Generate3DScreen: View {
    /// The 3D world, when opened from it (enables "use as character look").
    var controller: Glass3DController?
    /// Media library (exported GIFs / videos and picture characters go here).
    var mediaStore: MediaStore?
    /// Closes this screen (back to the world, e.g. to place a model).
    var onDone: (() -> Void)?
    @StateObject private var tasks = GenerationTaskManager()
    @ObservedObject private var store = Generated3DStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var capabilities = Generate3DCapabilities.current()
    @State private var quality = Generate3DCapabilities.current().recommended
    @State private var backStyle = DepthMeshBuilder.BackStyle.inflated
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var photoFilter = PHPickerFilter.images
    @State private var importingFile = false
    @State private var fileIsVideo = false
    @State private var opened: Generated3DManifest?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    capabilityCard
                    if tasks.running { progressCard } else { startButtons }
                    statusCard
                    if let video = tasks.video, !tasks.running { videoCard(video) }
                    libraryGrid
                }
                .padding(16)
            }
            .navigationTitle(L10n.t("AI 生成 3D 模型", "AI 3D Models")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("关闭", "Close")) { tasks.cancel(); tasks.reset(); dismiss() } }
            }
            .navigationDestination(item: $opened) { manifest in Generated3DDetailView(manifest: manifest, store: store, controller: controller, mediaStore: mediaStore, onPlace: { tasks.reset(); if let onDone { onDone() } else { dismiss() } }) }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: photoFilter, preferredItemEncoding: .current)
        .fileImporter(isPresented: $importingFile, allowedContentTypes: fileIsVideo ? [.movie, .mpeg4Movie, .quickTimeMovie] : [.jpeg, .png, .heic, .image]) { result in
            if case .success(let url) = result { startFromFile(url, video: fileIsVideo) }
        }
        .onChange(of: photoItem) { _, item in if let item { startFromPhotos(item) } }
        .onChange(of: tasks.phase) { _, phase in
            if case .finished(let id) = phase, let manifest = store.models.first(where: { $0.id == id }) { opened = manifest }
        }
        .onAppear { capabilities = .current(); store.reload() }
        .accessibilityIdentifier("generate3d-screen")
    }

    // MARK: Cards

    private var capabilityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.t("完全在本机运行，不上传任何图片或视频", "Runs fully on this iPhone; nothing is uploaded"), systemImage: "lock.shield").font(.subheadline.weight(.semibold))
            capability(L10n.t("AI 深度估计", "AI depth"), capabilities.depthModelReady ? L10n.t("可用", "Ready") : capabilities.depthModelBundled ? L10n.t("需要 iOS 17", "Needs iOS 17") : L10n.t("本安装包未内置", "Not in this build"), capabilities.depthModelReady)
            capability(L10n.t("人像照片自带深度", "Portrait photo depth"), L10n.t("可用（无需 AI）", "Ready (no AI needed)"), true)
            capability(L10n.t("视频多视角重建", "Multi-view video"), capabilities.objectCapture ? L10n.t("本机支持", "Supported") : L10n.t("本机不支持，可用基础立体化", "Not on this device; basic depth model available"), capabilities.objectCapture)
            capability(L10n.t("USDZ 导出", "USDZ export"), capabilities.usdzExport ? L10n.t("可用（保存时实际加载验证）", "Ready (verified by loading)") : L10n.t("不可用，可导出 OBJ", "Unavailable; OBJ export works"), capabilities.usdzExport)
            capability(L10n.t("自动骨骼 / 动画 / 换装", "Auto rig / animation / outfits"), L10n.t("实验性，尚未实现", "Experimental, not implemented"), false)
            HStack {
                Text(L10n.t("精度", "Quality")).font(.subheadline)
                Spacer()
                Picker(L10n.t("精度", "Quality"), selection: $quality) { ForEach(GenerationQuality.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 240)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("立体方式", "Shape")).font(.subheadline)
                Picker(L10n.t("立体方式", "Shape"), selection: $backStyle) { ForEach(DepthMeshBuilder.BackStyle.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text(backStyle == .inflated
                     ? L10n.t("按人看图想象形体的方式：每个部位的厚度随它在画面里的宽度变化（细的耳朵、四肢薄而圆，宽的身体厚而圆），正面细节来自深度，背面用整体颜色，正反面在轮廓处无缝闭合。这是推测，不是 360° 重建。", "Like a person imagining the shape: each part's thickness follows its width in the picture (thin ears and limbs round and slim, wide bodies round and full); front details come from depth, the back uses the overall colours, and front and back close at the outline. A guess, not a 360° reconstruction.")
                     : backStyle == .mirrored
                     ? L10n.t("背面按正面深度鼓起来；这是推测，不是 AI 重建的真实背面。", "The back bulges like the front; a guess, not a reconstructed back.")
                     : L10n.t("正面深度 + 平板背面（旧方式）。", "Front depth with a flat back (the old way)."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if capabilities.thermal >= 2 { Label(L10n.t("设备温度较高，生成可能暂停", "The device is warm; generation may pause"), systemImage: "thermometer.sun").font(.caption).foregroundStyle(.orange) }
        }
        .padding(14).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func capability(_ title: String, _ value: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title).font(.caption)
            Spacer()
            Text(value).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private var startButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("图片生成 3D", "Picture to 3D")).font(.headline)
            HStack(spacing: 10) {
                bigButton(L10n.t("相册图片", "Photo"), "photo", [.orange, .pink]) { photoFilter = .images; choosingPhoto = true }
                bigButton(L10n.t("文件图片", "Image File"), "doc.richtext", [.blue, .cyan]) { fileIsVideo = false; importingFile = true }
            }
            Text(L10n.t("单张图片生成「深度立体模型」：正面是真实深度的三维网格，背面为封闭平板，不是完整 360° 模型。", "One picture makes a depth relief: a real 3D mesh from depth on the front, closed flat back; not a full 360° model."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.t("视频生成 3D", "Video to 3D")).font(.headline).padding(.top, 6)
            HStack(spacing: 10) {
                bigButton(L10n.t("相册视频", "Video"), "video", [.purple, .indigo]) { photoFilter = .videos; choosingPhoto = true }
                bigButton(L10n.t("文件视频", "Video File"), "film", [.teal, .green]) { fileIsVideo = true; importingFile = true }
            }
            Text(L10n.t("先抽帧检查清晰度、重复和视角覆盖；绕物体拍摄且本机支持时可多视角重建，否则可用最清晰一帧做深度立体模型。", "Frames are checked for sharpness, duplicates and view coverage first. Orbit videos can be reconstructed on supported devices; otherwise the sharpest frame makes a depth relief."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func bigButton(_ title: String, _ symbol: String, _ colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { ProgressView(); Text(tasks.stage).font(.subheadline.weight(.semibold)) }
            if let fraction = tasks.fraction { ProgressView(value: fraction).tint(.accentColor) }
            Text(L10n.t("进度按实际完成的步骤显示。", "Progress follows the steps actually finished.")).font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive) { tasks.cancel() } label: { Label(L10n.t("取消生成", "Cancel"), systemImage: "xmark.circle") }
                .buttonStyle(Glass3DChipStyle(tint: .red)).accessibilityIdentifier("generate3d-cancel")
        }
        .padding(14).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder private var statusCard: some View {
        switch tasks.phase {
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.orange)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        case .cancelled:
            Label(L10n.t("已取消，没有保存任何结果。", "Cancelled; nothing was saved."), systemImage: "xmark.circle").font(.subheadline).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func videoCard(_ video: VideoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("视频检查结果", "Video Check")).font(.headline)
            Text(video.assessment.message).font(.subheadline)
            HStack(spacing: 14) {
                stat(L10n.t("采样", "Sampled"), "\(video.sampled)")
                stat(L10n.t("模糊", "Blurry"), "\(video.blurry)")
                stat(L10n.t("重复", "Duplicate"), "\(video.duplicates)")
                stat(L10n.t("有效", "Usable"), "\(video.kept.count)")
            }
            if video.totalSeconds > video.analysedSeconds {
                Text(L10n.t("视频较长，只检查了前 \(Int(video.analysedSeconds)) 秒。", "Long video: only the first \(Int(video.analysedSeconds)) s were checked.")).font(.caption).foregroundStyle(.secondary)
            }
            if video.assessment.canReconstruct {
                Button { tasks.reconstruct(store: store) } label: { Label(L10n.t("多视角重建", "Reconstruct"), systemImage: "cube.transparent") }
                    .buttonStyle(Glass3DChipStyle(tint: .accentColor, prominent: true)).disabled(!capabilities.objectCapture)
                if !capabilities.objectCapture {
                    Text(L10n.t("这台设备不支持本地多视角重建。", "This device cannot reconstruct from many views.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if video.bestFrame != nil {
                Button { tasks.depthFromBestFrame(quality: quality, back: backStyle, store: store) } label: { Label(L10n.t("用最清晰一帧做深度立体模型", "Depth Relief from the Sharpest Frame"), systemImage: "photo") }
                    .buttonStyle(Glass3DChipStyle(tint: .accentColor))
            }
            Button(L10n.t("放弃这个视频", "Discard Video")) { tasks.reset() }.buttonStyle(Glass3DChipStyle())
        }
        .padding(14).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) { Text(value).font(.headline.monospacedDigit()); Text(title).font(.caption2).foregroundStyle(.secondary) }
    }

    private var libraryGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("我的 3D 模型（\(store.models.count)）", "My 3D Models (\(store.models.count))")).font(.headline)
            if store.models.isEmpty {
                Text(L10n.t("生成的模型会保存在这里，重新打开 App 也能加载。", "Generated models are kept here and reload after restarting the app.")).font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 12)], spacing: 12) {
                ForEach(store.models) { manifest in
                    Button { opened = manifest } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Glass3DMediaThumbnail(url: store.thumbnailURL(manifest), kind: .image, side: 100, corner: 14)
                                .overlay(alignment: .bottomLeading) {
                                    Text(manifest.geometry == .photogrammetry ? L10n.t("重建", "Scan") : L10n.t("深度", "Depth"))
                                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(manifest.geometry == .photogrammetry ? Color.purple : Color.blue, in: Capsule()).padding(5)
                                }
                            Text(manifest.name).font(.caption2).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Inputs

    private func startFromPhotos(_ item: PhotosPickerItem) {
        photoItem = nil
        let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        Task {
            guard let file = try? await item.loadTransferable(type: RPGPickedFile.self) else { return }
            let name = video ? L10n.t("相册视频", "Video") : L10n.t("相册图片", "Photo")
            if video { tasks.analyze(video: file.url, name: name) }
            else { tasks.generate(image: file.url, name: name, quality: quality, back: backStyle, store: store, removeAfter: true) }
        }
    }

    private func startFromFile(_ url: URL, video: Bool) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
        let name = url.deletingPathExtension().lastPathComponent
        if video { tasks.analyze(video: copy, name: name) }
        else { tasks.generate(image: copy, name: name, quality: quality, back: backStyle, store: store, removeAfter: true) }
    }
}

// MARK: Preview

/// RealityKit scene for one model: turntable pivot, camera, lights, backdrop.
@available(iOS 18.0, *)
@MainActor final class Generated3DPreviewScene: ObservableObject {
    enum Backdrop: String, CaseIterable, Identifiable {
        case dark, light, blue
        var id: Self { self }
        var title: String { switch self { case .dark: L10n.t("深色", "Dark"); case .light: L10n.t("浅色", "Light"); case .blue: L10n.t("蓝色", "Blue") } }
        var color: UIColor { switch self { case .dark: UIColor(white: 0.1, alpha: 1); case .light: UIColor(white: 0.92, alpha: 1); case .blue: UIColor(red: 0.25, green: 0.35, blue: 0.6, alpha: 1) } }
    }

    let root = Entity()
    let pivot = Entity()
    let camera = PerspectiveCamera()
    private let backdrop = ModelEntity(mesh: .generateSphere(radius: 30))
    private let keyLight = DirectionalLight(), fillLight = DirectionalLight()
    private var model: ModelEntity?
    private var baseTexture: TextureResource?
    @Published var yaw: Float = 0.5 { didSet { turn() } }
    @Published var pitch: Float = -0.15 { didSet { turn() } }
    @Published var distance: Float = 1.9 { didSet { place() } }
    @Published var lit = false { didSet { Task { await restyle() } } }
    @Published var backdropStyle = Backdrop.dark { didSet { paint() } }
    private var tint: String?
    private var texture: TextureResource?
    /// Rigged models: per-region meshes, the playing clip and region colours.
    private var animated: AnimatedRegionMesh?
    @Published private(set) var rig: RigPackage?
    @Published private(set) var clip: RigClip?
    private var clipTime: Float = 0
    private var sinceUpdate: Float = 0
    @Published var regionTints: [Int: String] = [:] { didSet { Task { await restyle() } } }
    var updates: EventSubscription?

    init() {
        root.addChild(pivot); root.addChild(camera); root.addChild(backdrop)
        camera.camera.fieldOfViewInDegrees = 40
        keyLight.light.intensity = 3000; keyLight.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        fillLight.light.intensity = 1200; fillLight.look(at: .zero, from: [-2, 0.5, 1], relativeTo: nil)
        root.addChild(keyLight); root.addChild(fillLight)
        paint(); place(); turn()
    }

    private func paint() {
        var material = UnlitMaterial(color: backdropStyle.color)
        material.faceCulling = .front
        backdrop.model?.materials = [material]
    }
    private func place() { camera.look(at: .zero, from: [0, 0, max(0.6, min(6, distance))], relativeTo: nil) }
    private func turn() { pivot.orientation = simd_quatf(angle: pitch, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0]) }

    /// Loads a depth model (own mesh format) or a USDZ, centred and sized to 1.
    func load(_ manifest: Generated3DManifest, store: Generated3DStore) async throws -> (triangles: Int, vertices: Int) {
        pivot.children.removeAll()
        model = nil
        if let meshURL = store.meshURL(manifest) {
            let mesh = try await Task.detached(priority: .userInitiated) { () -> GeneratedMesh in
                guard let data = try? Data(contentsOf: meshURL), let mesh = GeneratedMeshCodec.decode(data) else { throw Generate3DError.meshFailed }
                return mesh
            }.value
            var descriptor = MeshDescriptor(name: "generated")
            descriptor.positions = MeshBuffers.Positions((0..<mesh.vertexCount).map { SIMD3(mesh.positions[$0 * 3], mesh.positions[$0 * 3 + 1], mesh.positions[$0 * 3 + 2]) })
            descriptor.normals = MeshBuffers.Normals((0..<mesh.vertexCount).map { SIMD3(mesh.normals[$0 * 3], mesh.normals[$0 * 3 + 1], mesh.normals[$0 * 3 + 2]) })
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates((0..<mesh.vertexCount).map { SIMD2(mesh.uvs[$0 * 2], mesh.uvs[$0 * 2 + 1]) })
            descriptor.primitives = .triangles(mesh.indices)
            if let textureURL = store.textureURL(manifest) { baseTexture = try? await TextureResource(contentsOf: textureURL, options: .init(semantic: .color)) }
            animated = nil; rig = nil; clip = nil
            if let loaded = await Generate3DRigging.load(manifest), loaded.1.count == mesh.vertexCount,
               let regions = try? AnimatedRegionMesh(mesh: mesh, skin: loaded.1, skeleton: loaded.0.skeleton) {
                animated = regions; rig = loaded.0
                pivot.addChild(regions.root)
            } else {
                let entity = ModelEntity(mesh: try MeshResource.generate(from: [descriptor]))
                model = entity
                pivot.addChild(entity)
            }
            await restyle()
            return (mesh.triangleCount, mesh.vertexCount)
        }
        guard let usdz = store.usdzURL(manifest) else { throw Generate3DError.meshFailed }
        let entity = try await Entity(contentsOf: usdz)
        let bounds = entity.visualBounds(relativeTo: nil)
        let span = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        if span > 0 { entity.scale = SIMD3(repeating: 1 / span); entity.position = -bounds.center / span }
        pivot.addChild(entity)
        return (Generated3DStore.triangles(in: entity), 0)
    }

    /// Whole-model look: colour tint and / or replacement texture.
    func applyLook(tint: String?, textureURL: URL?) async {
        self.tint = tint
        texture = nil
        if let textureURL { texture = try? await TextureResource(contentsOf: textureURL, options: .init(semantic: .color)) }
        await restyle()
    }

    private func material(_ hex: String?) -> RealityKit.Material {
        let color = hex.map { UIColor(rpgHex: $0) } ?? .white
        let image = texture ?? baseTexture
        if lit {
            var material = PhysicallyBasedMaterial()
            if let image { material.baseColor = .init(tint: color, texture: .init(image)) } else { material.baseColor = .init(tint: color) }
            material.roughness = 0.7; material.metallic = 0.0
            return material
        }
        var material = UnlitMaterial()
        if let image { material.color = .init(tint: color, texture: .init(image)) } else { material.color = .init(tint: color) }
        return material
    }

    private func restyle() async {
        if let animated {
            for part in animated.regionEntities { part.entity.model?.materials = [material(regionTints[part.region] ?? tint)] }
        } else if let model {
            model.model?.materials = [material(tint)]
        }
        keyLight.isEnabled = lit; fillLight.isEnabled = lit
    }

    /// After a clip was designed or removed.
    func replaceRig(_ package: RigPackage) {
        rig = package
        if let clip, !package.clips.contains(where: { $0.id == clip.id }) { play(nil) }
    }

    /// Plays a clip (nil = rest pose).
    func play(_ next: RigClip?) {
        clip = next; clipTime = 0
        if next == nil { animated?.pose(nil, time: 0) }
    }

    /// Called every rendered frame; skins at up to 30 fps.
    func tick(_ dt: Float) {
        guard let animated, let clip else { return }
        clipTime += dt; sinceUpdate += dt
        guard sinceUpdate >= 1.0 / 30 else { return }
        sinceUpdate = 0
        animated.pose(clip, time: clipTime.truncatingRemainder(dividingBy: clip.period))
    }

}

@available(iOS 18.0, *)
struct Generated3DDetailView: View {
    let manifest: Generated3DManifest
    @ObservedObject var store: Generated3DStore
    var controller: Glass3DController?
    var mediaStore: MediaStore?
    /// Goes back to the world with the Creature tool and this look selected.
    var onPlace: (() -> Void)?
    @State private var exportOptions = ModelAnimationExport.Options()
    /// Export progress (nil = idle); a class so background work can report into it.
    @StateObject private var exportProgress = ExportProgressBox()
    private var exporting: Double? { exportProgress.value }
    @State private var exportTask: Task<Void, Never>?
    @State private var exported: URL?
    @State private var exportMessage: String?
    @StateObject private var scene = Generated3DPreviewScene()
    @Environment(\.dismiss) private var dismiss
    @State private var counts: (triangles: Int, vertices: Int)?
    @State private var loadError: String?
    @State private var dragStart: (Float, Float)?
    @State private var zoomStart: Float?
    @State private var tint: String?
    @State private var skinTexture: URL?
    @State private var skinItem: PhotosPickerItem?
    @State private var choosingSkin = false
    @State private var exportFiles: [URL] = []
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var rigging = false
    // Claude motion design (online, opt-in).
    @State private var aiPrompt = ""
    @State private var aiKeyDraft = ""
    @State private var aiHasKey = SecureSettings.read(ClaudeMotion.keyAccount)?.isEmpty == false
    @AppStorage("generate3d.claude.model") private var aiModelID = ClaudeMotion.models[0].id
    @State private var aiConfirm = false
    @State private var aiBusy = false
    @State private var aiMessage: String?
    @State private var aiTask: Task<Void, Never>?

    @Environment(\.scenePhase) private var scenePhase
    private var current: Generated3DManifest { store.models.first { $0.id == manifest.id } ?? manifest }
    private var depthModel: Bool { current.meshFile != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                preview
                controls
                if let message { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                infoCard
                if depthModel { exportCard }
                if depthModel { rigCard }
                if depthModel { skinCard }
                actions
            }
            .padding(16)
        }
        .navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .photosPicker(isPresented: $choosingSkin, selection: $skinItem, matching: .images)
        .onChange(of: skinItem) { _, item in if let item { replaceTexture(item) } }
        .confirmationDialog(L10n.t("删除这个模型？", "Delete this model?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L10n.t("删除", "Delete"), role: .destructive) { store.delete(current); dismiss() }
        } message: { Text(L10n.t("模型、贴图、皮肤预设都会从本机删除。", "The model, its texture and skin presets are removed from this device.")) }
    }

    /// No 3D rendering while the app is not in front (keeps the phone cool).
    @ViewBuilder private var preview: some View {
        if scenePhase == .active { livePreview } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black).frame(height: 340)
        }
    }

    private var livePreview: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(scene.root)
            let scene = scene
            scene.updates = content.subscribe(to: SceneEvents.Update.self) { event in
                MainActor.assumeIsolated { scene.tick(Float(event.deltaTime)) }
            }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            if counts == nil && loadError == nil { ProgressView() }
            if let loadError { Label(loadError, systemImage: "exclamationmark.triangle").font(.subheadline).padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            let start = dragStart ?? (scene.yaw, scene.pitch)
            dragStart = start
            scene.yaw = start.0 + Float(value.translation.width) * 0.01
            scene.pitch = max(-1.4, min(1.4, start.1 + Float(value.translation.height) * 0.01))
        }.onEnded { _ in dragStart = nil })
        .simultaneousGesture(MagnifyGesture().onChanged { value in
            let start = zoomStart ?? scene.distance
            zoomStart = start
            scene.distance = max(0.6, min(6, start / Float(value.magnification)))
        }.onEnded { _ in zoomStart = nil })
        .accessibilityLabel(L10n.t("3D 预览：拖动旋转，双指缩放", "3D preview: drag to turn, pinch to zoom"))
        .accessibilityIdentifier("generate3d-preview")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker(L10n.t("背景", "Background"), selection: $scene.backdropStyle) { ForEach(Generated3DPreviewScene.Backdrop.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Toggle(L10n.t("立体光照", "Lighting"), isOn: $scene.lit).fixedSize().font(.caption)
            Button { scene.yaw = 0.5; scene.pitch = -0.15; scene.distance = 1.9 } label: { Image(systemName: "scope") }.accessibilityLabel(L10n.t("居中", "Recentre"))
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(L10n.t("类型", "Type"), current.backStyle == .inflated ? L10n.t("形体推测立体模型（正面细节来自深度，体积按轮廓推测，背面为颜色推测；非真实 360° 重建）", "Shape-guess model (front details from depth, volume from the outline, back from colours; not a 360° reconstruction)") : current.geometry.title)
            row(L10n.t("深度来源", "Depth"), current.depthSource.title)
            row(L10n.t("生成引擎", "Engine"), current.engine + " " + current.engineVersion)
            if depthModel { row(L10n.t("精度", "Quality"), current.quality.title) }
            row(L10n.t("三角面", "Triangles"), "\(counts?.triangles ?? current.triangleCount)")
            if (counts?.vertices ?? current.vertexCount) > 0 { row(L10n.t("顶点", "Vertices"), "\(counts?.vertices ?? current.vertexCount)") }
            if current.textureWidth > 0 { row(L10n.t("贴图", "Texture"), "\(current.textureWidth) × \(current.textureHeight)") }
            row(L10n.t("文件大小", "Size"), ByteCountFormatter.string(fromByteCount: store.size(current), countStyle: .file))
            row(L10n.t("USDZ", "USDZ"), current.usdzFile == nil ? L10n.t("无", "None") : L10n.t("已导出并通过加载检查", "Exported and verified"))
            row(L10n.t("人形检测", "Human pose"), current.humanoidDetected ? L10n.t("检测到人形姿态", "Human pose found") : L10n.t("未检测到", "Not found"))
            if current.backStyle == .mirrored { row(L10n.t("背面", "Back"), L10n.t("正面深度的镜像推测，不是 AI 重建", "Mirrored guess of the front, not an AI reconstruction")) }
            row(L10n.t("骨骼 / 动画", "Rig / animation"), current.rigging == .experimentalVerified ? L10n.t("实验性：已通过本机自动检查，未经人工真机验收", "Experimental: passed the on-device automatic check, not yet accepted by a person") : L10n.t("未绑定，静态模型", "Not rigged; static model"))
            row(L10n.t("可换装部件", "Outfit parts"), L10n.t("无法从单张图片分离衣服、头发；骨骼绑定后可按身体分区换色", "Clothes and hair cannot be separated from one picture; rigged models can colour body regions"))
            ForEach(current.notes, id: \.self) { Text("· " + $0).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).font(.caption)
            Spacer(minLength: 0)
        }
    }

    private static let regionNames = [L10n.t("头部", "Head"), L10n.t("躯干", "Torso"), L10n.t("手臂", "Arms"), L10n.t("腿部", "Legs")]

    private var rigCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("骨骼与动作", "Rig & Motion")).font(.headline)
                Text(L10n.t("实验性", "Experimental")).font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Color.orange, in: Capsule())
            }
            if let rig = scene.rig {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(L10n.t("静止", "Rest")) { scene.play(nil) }.buttonStyle(Glass3DChipStyle(tint: scene.clip == nil ? .accentColor : .primary, prominent: scene.clip == nil))
                        ForEach(rig.clips) { clip in
                            Button(clip.id.hasPrefix("ai-") ? "✦ " + clip.name : clip.name) { scene.play(clip) }
                                .buttonStyle(Glass3DChipStyle(tint: scene.clip?.id == clip.id ? .accentColor : .primary, prominent: scene.clip?.id == clip.id))
                                .contextMenu {
                                    if clip.id.hasPrefix("ai-") {
                                        Button(role: .destructive) { removeAIClip(clip.id) } label: { Label(L10n.t("删除这个动作", "Delete This Motion"), systemImage: "trash") }
                                    }
                                }
                        }
                    }
                }
                let seams = rig.validation.seamStretch.map { "\($0.key) \(String(format: "%.2f", $0.value * 100))%" }.sorted().joined(separator: " · ")
                Text(L10n.t("自动检查：通过 · 接缝拉伸 ", "Automatic check: passed · seam stretch ") + seams).font(.caption2).foregroundStyle(.secondary)
                claudeSection(rig)
                Text(L10n.t("身体分区颜色（不是独立服装）", "Body region colours (not separate clothes)")).font(.caption.weight(.semibold))
                ForEach(0..<4, id: \.self) { region in
                    HStack(spacing: 8) {
                        Text(Self.regionNames[region]).font(.caption).frame(width: 40, alignment: .leading)
                        ForEach([nil, "FFD27A", "8FD3FF", "FF8FB1", "7FE3C8", "3A3A48"], id: \.self) { hex in
                            Button { scene.regionTints[region] = hex } label: {
                                Circle().fill(hex.map { Color(UIColor(rpgHex: $0)) } ?? Color.white).frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(scene.regionTints[region] == hex ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: scene.regionTints[region] == hex ? 2.5 : 1))
                            }
                            .buttonStyle(.plain).accessibilityLabel(Self.regionNames[region] + " " + (hex ?? L10n.t("原色", "Original")))
                        }
                    }
                }
            } else if rigging {
                HStack { ProgressView(); Text(L10n.t("正在识别姿态、绑定骨骼并自动检查…", "Finding the pose, rigging and checking…")).font(.caption) }
            } else {
                Text(L10n.t("用原图识别人体姿态，自动生成 10 根骨骼、计算蒙皮权重，并用待机、行走、奔跑、挥手 4 个动作实际变形检查；通过才会保存，否则保持静态模型。", "Finds the body pose in the picture, builds 10 bones and skin weights, and really deforms the model through idle, walk, run and wave; it is kept only if the check passes, otherwise the model stays static."))
                    .font(.caption).foregroundStyle(.secondary)
                Button { autoRig() } label: { Label(L10n.t("自动绑定骨骼", "Auto Rig"), systemImage: "figure.walk") }
                    .buttonStyle(Glass3DChipStyle(tint: .accentColor, prominent: true)).accessibilityIdentifier("generate3d-auto-rig")
            }
        }
        .padding(14).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: GIF / video export

    private var exportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("动图与视频", "GIFs & Video")).font(.headline)
            Text(L10n.t("把模型真实渲染成动图或视频：转一圈展示，或播放骨骼动作；可存入媒体库贴到方块上，也可分享。", "Render the model into a GIF or video: a full turn, or a rig motion. Save to the media library for blocks, or share."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    contentChip(.turntable)
                    if let rig = scene.rig { ForEach(rig.clips) { clip in contentChip(.clip(clip.id)) } }
                }
            }
            Picker(L10n.t("格式", "Format"), selection: $exportOptions.format) { ForEach(ModelAnimationExport.Format.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            HStack {
                Picker(L10n.t("背景", "Background"), selection: $exportOptions.background) {
                    ForEach(ModelAnimationExport.Background.allCases.filter { $0 != .clear || exportOptions.format == .gif }, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Picker(L10n.t("尺寸", "Size"), selection: $exportOptions.size) { Text("360").tag(360); Text("540").tag(540); Text("720").tag(720) }.pickerStyle(.menu)
            }
            if let exporting {
                HStack {
                    ProgressView(value: exporting).tint(.accentColor)
                    Button(L10n.t("取消", "Cancel")) { exportTask?.cancel() }.buttonStyle(Glass3DChipStyle(tint: .red))
                }
            } else {
                HStack(spacing: 8) {
                    Button { startExport() } label: { Label(L10n.t("生成", "Render"), systemImage: "film.stack") }
                        .buttonStyle(Glass3DChipStyle(tint: .accentColor, prominent: true)).accessibilityIdentifier("generate3d-export")
                    if controller != nil, mediaStore != nil {
                        Button { makeSpriteCharacter() } label: { Label(L10n.t("做成八方向动图角色", "Make an 8-Direction Picture Character"), systemImage: "rotate.3d") }
                            .buttonStyle(Glass3DChipStyle(tint: .accentColor)).accessibilityIdentifier("generate3d-sprite-character")
                    }
                }
            }
            if let exported {
                HStack(spacing: 8) {
                    ShareLink(item: exported) { Label(L10n.t("分享 / 存到相册", "Share / Save"), systemImage: "square.and.arrow.up") }.buttonStyle(Glass3DChipStyle(tint: .accentColor))
                    Text(exported.lastPathComponent.hasSuffix("gif") ? "GIF" : "MP4").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            if let exportMessage { Text(exportMessage).font(.caption).foregroundStyle(.secondary) }
            Text(L10n.t("「八方向动图角色」会从 8 个方向渲染待机、行走、挥手动图，做成一个图片角色：在世界里不用实时计算骨骼，更省电。", "An 8-direction picture character renders idle, walk and wave from eight directions into GIFs: no live skinning in the world, so it uses less power."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func contentChip(_ content: ModelAnimationExport.Content) -> some View {
        Button(content.title) { exportOptions.content = content }
            .buttonStyle(Glass3DChipStyle(tint: exportOptions.content == content ? .accentColor : .primary, prominent: exportOptions.content == content))
    }

    private func exportSource() async throws -> ModelAnimationExport.Source {
        guard let meshURL = store.meshURL(current) else { throw Generate3DError.meshFailed }
        let textureURL = store.textureURL(current)
        let rig = await Generate3DRigging.load(current)
        return try await Task.detached(priority: .userInitiated) { try ModelAnimationExport.loadSource(mesh: meshURL, texture: textureURL, rig: rig) }.value
    }

    private func startExport() {
        exported = nil; exportMessage = nil; exportProgress.value = 0
        var draft = exportOptions
        if draft.format == .mp4 && draft.background == .clear { draft.background = .dark }
        let options = draft
        let progress = exportProgress.reporter
        let title = current.name + " · " + options.content.title
        exportTask = Task {
            do {
                let source = try await exportSource()
                let job = Task.detached(priority: .userInitiated) { [options] in try await ModelAnimationExport.export(source, options: options, progress: progress) }
                let url = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                exported = url
                if let mediaStore, (await mediaStore.importLocalFile(url, title: title, kind: options.format == .gif ? .image : .video)) != nil {
                    exportMessage = L10n.t("已存入媒体库（可在方块的媒体里选用）。", "Saved to the media library (choose it as block media).")
                }
            } catch {
                exportMessage = (error as? Generate3DError) == .cancelled || error is CancellationError ? L10n.t("已取消。", "Cancelled.") : ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            exportProgress.value = nil
        }
    }

    /// Bakes the model into an 8-direction GIF character and selects it.
    private func makeSpriteCharacter() {
        guard let controller, let mediaStore else { return }
        exported = nil; exportMessage = nil; exportProgress.value = 0
        let progress = exportProgress.reporter
        let name = String(current.name.prefix(48))
        exportTask = Task {
            do {
                let source = try await exportSource()
                let job = Task.detached(priority: .userInitiated) { try await ModelAnimationExport.spriteSheets(source, progress: progress) }
                let sheets = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                var bindings: [MediaBinding] = []
                var byClip: [String: [String]] = [:]
                for sheet in sheets.files.sorted(by: { ($0.clip, $0.direction) < ($1.clip, $1.direction) }) {
                    guard let entry = await mediaStore.importLocalFile(sheet.url, title: "\(name) · \(sheet.clip) · \(sheet.direction + 1)", kind: .image) else { continue }
                    try? FileManager.default.removeItem(at: sheet.url)
                    let binding = MediaBinding(id: "cb:" + UUID().uuidString, mediaID: entry.id, kind: .gif, fit: .fit)
                    bindings.append(binding); byClip[sheet.clip, default: []].append(binding.id)
                }
                var template = CharacterTemplate(id: "char:" + UUID().uuidString, name: String((name + L10n.t(" · 动图", " · Pictures")).prefix(64)))
                template.mode = .directional8
                template.aspect = 1
                template.height = min(8, max(0.5, 1.6 / max(0.2, sheets.figure)))
                template.footAnchor = min(0.5, max(0, sheets.foot))
                for entry in ModelExportPlan.spriteClips {
                    guard let ids = byClip[entry.clip] ?? byClip["idle"], ids.count == 8 else { continue }
                    for action in entry.actions { template.clips[action.rawValue] = ActionClip(bindingIDs: ids, speed: 1, loop: true) }
                }
                guard !template.clips.isEmpty else { throw Generate3DError.saveFailed(L10n.t("动图没有生成", "No pictures were made")) }
                controller.saveCharacter(template, bindings: bindings)
                controller.creatureLook = template.id
                exportMessage = L10n.t("已做成「\(template.name)」：在「生物」或「主角」工具的外观里可以选它。", "Made \(template.name): pick it under Look in the Creature or Player tool.")
            } catch {
                exportMessage = (error as? Generate3DError) == .cancelled || error is CancellationError ? L10n.t("已取消。", "Cancelled.") : ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            exportProgress.value = nil
        }
    }

    // MARK: Claude motion design

    private var aiModel: ClaudeMotion.ModelChoice { ClaudeMotion.models.first { $0.id == aiModelID } ?? ClaudeMotion.models[0] }

    @ViewBuilder private func claudeSection(_ rig: RigPackage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(L10n.t("用 Claude 设计动作", "Design a Motion with Claude"), systemImage: "sparkles").font(.caption.weight(.semibold))
                Text(L10n.t("联网 · 可选", "Online · optional")).font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Color.purple, in: Capsule())
            }
            Text(L10n.t("用一句话描述动作（如「开心地跳舞，双手举过头顶」）。Claude 按这具骨骼写出动作，回到手机后照样做变形检查，通过才保存。只发送文字描述和骨骼关节坐标，不发送图片和模型；费用记在你自己的 API Key 上。",
                        "Describe a motion in a sentence (e.g. \"dance happily, hands above the head\"). Claude writes it for this skeleton; back on the phone it goes through the same deformation check and is kept only if it passes. Only the text and the joint positions are sent, never the picture or the model; usage is billed to your own API key."))
                .font(.caption2).foregroundStyle(.secondary)
            if aiHasKey {
                HStack(spacing: 6) {
                    Picker(L10n.t("模型", "Model"), selection: $aiModelID) { ForEach(ClaudeMotion.models) { Text($0.name).tag($0.id) } }
                        .pickerStyle(.menu).font(.caption)
                    Spacer()
                    Button(L10n.t("移除 Key", "Remove Key")) { SecureSettings.delete(ClaudeMotion.keyAccount); aiHasKey = false }.font(.caption2)
                }
                TextField(L10n.t("描述一个动作…", "Describe a motion…"), text: $aiPrompt, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).font(.caption).accessibilityIdentifier("generate3d-claude-prompt")
                if aiBusy {
                    HStack {
                        ProgressView()
                        Text(L10n.t("Claude 正在设计，随后本机检查…", "Claude is designing, then the phone checks it…")).font(.caption)
                        Spacer()
                        Button(L10n.t("取消", "Cancel")) { aiTask?.cancel() }.font(.caption)
                    }
                } else {
                    Button { aiConfirm = true } label: { Label(L10n.t("设计动作", "Design Motion"), systemImage: "wand.and.stars") }
                        .buttonStyle(Glass3DChipStyle(tint: .purple, prominent: true))
                        .disabled(aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("generate3d-claude-design")
                }
            } else {
                HStack(spacing: 6) {
                    SecureField("Anthropic API Key", text: $aiKeyDraft).textFieldStyle(.roundedBorder).font(.caption)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(L10n.t("保存", "Save")) {
                        let key = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        SecureSettings.write(key, account: ClaudeMotion.keyAccount); aiKeyDraft = ""; aiHasKey = true
                    }.buttonStyle(Glass3DChipStyle(tint: .purple, prominent: true))
                }
                Text(L10n.t("Key 只存在本机钥匙串里。", "The key is kept only in this phone's keychain.")).font(.caption2).foregroundStyle(.secondary)
            }
            if let aiMessage { Text(aiMessage).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(10).background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .confirmationDialog(L10n.t("发送给 Claude？", "Send to Claude?"), isPresented: $aiConfirm, titleVisibility: .visible) {
            Button(L10n.t("发送", "Send")) { designWithClaude(rig) }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("将通过网络发送到 Anthropic（\(aiModel.name)）：你的动作描述和 10 根骨骼的关节坐标。不发送图片、贴图或模型。费用记在你的 API Key 上。", "This sends to Anthropic (\(aiModel.name)) over the network: your description and the joint positions of the 10 bones. No picture, texture or model is sent. Usage is billed to your API key.")
                 + (aiModel.fallbacks ? L10n.t("若该模型拒绝，会由 Anthropic 推荐的备用模型自动重试（已开启）。", " If the model declines, Anthropic's recommended fallback model retries automatically (on).") : ""))
        }
    }

    private func designWithClaude(_ rig: RigPackage) {
        let text = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let key = SecureSettings.read(ClaudeMotion.keyAccount) else { aiMessage = ClaudeMotionError.noKey.errorDescription; return }
        aiBusy = true; aiMessage = nil
        let model = aiModel, manifest = current
        aiTask = Task {
            do {
                let clip = try await ClaudeMotionClient.design(description: String(text.prefix(500)), skeleton: rig.skeleton, model: model, apiKey: key)
                try Task.checkCancellation()
                let updated = try await Generate3DRigging.addClip(clip, to: manifest, store: store)
                scene.replaceRig(updated)
                if let saved = updated.clips.last { scene.play(saved) }
                aiMessage = L10n.t("「\(clip.name)」已通过本机检查并保存，正在预览；也可以在动图导出里选它。", "\"\(clip.name)\" passed the check and was saved; it is playing now and can be exported.")
                aiPrompt = ""
            } catch is CancellationError {
                aiMessage = L10n.t("已取消。", "Cancelled.")
            } catch let error as URLError where error.code == .cancelled {
                aiMessage = L10n.t("已取消。", "Cancelled.")
            } catch {
                aiMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            aiBusy = false
        }
    }

    private func removeAIClip(_ id: String) {
        let manifest = current
        Task {
            if let updated = try? await Generate3DRigging.removeClip(id, from: manifest) { scene.replaceRig(updated) }
        }
    }

    private func autoRig() {
        rigging = true; message = nil
        Task {
            do {
                let updated = try await Generate3DRigging.rig(current, store: store)
                counts = try await scene.load(updated, store: store)
                message = L10n.t("骨骼已绑定（实验），可以预览动作。", "Rigged (experimental); preview the motions.")
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            rigging = false
        }
    }

    private var skinCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("材质与皮肤", "Material & Skins")).font(.headline)
            HStack(spacing: 8) {
                ForEach([nil, "FFD27A", "8FD3FF", "FF8FB1", "7FE3C8", "B9A6FF"], id: \.self) { hex in
                    Button { tint = hex; Task { await scene.applyLook(tint: hex, textureURL: skinTexture) } } label: {
                        Circle().fill(hex.map { Color(UIColor(rpgHex: $0)) } ?? Color.white)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(tint == hex ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: tint == hex ? 3 : 1))
                    }
                    .buttonStyle(.plain).accessibilityLabel(hex ?? L10n.t("原色", "Original"))
                }
            }
            HStack(spacing: 8) {
                Button { choosingSkin = true } label: { Label(L10n.t("替换贴图", "Replace Texture"), systemImage: "photo") }.buttonStyle(Glass3DChipStyle())
                if skinTexture != nil { Button(L10n.t("恢复原贴图", "Original Texture")) { skinTexture = nil; Task { await scene.applyLook(tint: tint, textureURL: nil) } }.buttonStyle(Glass3DChipStyle()) }
                Button { savePreset() } label: { Label(L10n.t("保存为皮肤", "Save Skin"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(Glass3DChipStyle(tint: .accentColor)).disabled(tint == nil && skinTexture == nil && scene.regionTints.isEmpty)
            }
            if !current.skinPresets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(current.skinPresets) { preset in
                            Button(preset.name) {
                                tint = preset.tintHex; skinTexture = store.url("Presets", preset.textureFile)
                                scene.regionTints = Dictionary(uniqueKeysWithValues: (preset.regionTints ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
                                Task { await scene.applyLook(tint: tint, textureURL: skinTexture) }
                            }
                            .buttonStyle(Glass3DChipStyle(tint: .accentColor))
                            .contextMenu { Button(L10n.t("删除皮肤", "Delete Skin"), role: .destructive) { deletePreset(preset) } }
                        }
                    }
                }
            }
            Text(L10n.t("单张图片无法分出独立的头发、衣服，换装以整体颜色和贴图实现。", "Hair and clothes cannot be separated from one picture; skins change the whole model's colour and texture.")).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let controller, current.meshFile != nil || current.usdzFile != nil {
                Button { useAsCharacter(controller) } label: {
                    Label(current.rigFile != nil ? L10n.t("放进 3D 世界（带动作）", "Place in the 3D World (animated)") : L10n.t("放进 3D 世界", "Place in the 3D World"), systemImage: "mappin.and.ellipse")
                }
                .buttonStyle(Glass3DChipStyle(tint: .accentColor, prominent: true)).accessibilityIdentifier("generate3d-use-in-world")
                Button { useAsPlayer(controller) } label: { Label(L10n.t("设为主角外观", "Use as the Player's Look"), systemImage: "figure.stand") }
                    .buttonStyle(Glass3DChipStyle(tint: .accentColor)).accessibilityIdentifier("generate3d-use-as-player")
            }
            HStack(spacing: 10) {
                if exportFiles.isEmpty {
                    Button { Task { exportFiles = await store.exportFiles(current) } } label: { Label(L10n.t("准备导出", "Prepare Export"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(Glass3DChipStyle())
                } else {
                    ShareLink(items: exportFiles) { Label(L10n.t("导出 \(exportFiles.count) 个文件", "Export \(exportFiles.count) Files"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(Glass3DChipStyle(tint: .accentColor))
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label(L10n.t("删除", "Delete"), systemImage: "trash") }.buttonStyle(Glass3DChipStyle(tint: .red))
            }
        }
    }

    // MARK: Actions

    private func load() async {
        do { counts = try await scene.load(current, store: store) }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? L10n.t("模型加载失败", "Could not load the model") }
    }

    private func replaceTexture(_ item: PhotosPickerItem) {
        skinItem = nil
        Task {
            guard let file = try? await item.loadTransferable(type: RPGPickedFile.self) else { return }
            defer { try? FileManager.default.removeItem(at: file.url) }
            let target = Generated3DStore.folder("Presets").appendingPathComponent("\(current.id)-\(UUID().uuidString).jpg")
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048]
                guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                      let data = PixelReader.jpeg(image) else { return false }
                return (try? data.write(to: target)) != nil
            }.value
            guard ok else { message = L10n.t("无法读取这张图片。", "Could not read this picture."); return }
            skinTexture = target
            await scene.applyLook(tint: tint, textureURL: target)
        }
    }

    private func savePreset() {
        var updated = current
        let regions = scene.regionTints.isEmpty ? nil : Dictionary(uniqueKeysWithValues: scene.regionTints.map { (String($0.key), $0.value) })
        updated.skinPresets.append(.init(id: UUID().uuidString, name: L10n.t("皮肤 \(updated.skinPresets.count + 1)", "Skin \(updated.skinPresets.count + 1)"), tintHex: tint, textureFile: skinTexture?.lastPathComponent, regionTints: regions))
        do { try store.save(updated); message = L10n.t("皮肤已保存。", "Skin saved.") } catch { message = error.localizedDescription }
    }

    private func deletePreset(_ preset: Generated3DManifest.SkinPreset) {
        var updated = current
        updated.skinPresets.removeAll { $0.id == preset.id }
        if let file = preset.textureFile, !updated.skinPresets.contains(where: { $0.textureFile == file }) { try? FileManager.default.removeItem(at: Generated3DStore.folder("Presets").appendingPathComponent(file)) }
        try? store.save(updated)
    }

    /// Depth models are used directly (no USDZ needed; animated when
    /// rigged); reconstructed models through their USDZ.
    /// Makes this model the player's look and goes back to the world.
    private func useAsPlayer(_ controller: Glass3DController) {
        controller.setPlayerCharacter(controller.characterID(forGenerated: current))
        controller.mode = .edit
        controller.tool = .player
        if let onPlace { onPlace() } else { message = L10n.t("主角外观已更换。", "The player's look has changed.") }
    }

    /// Picks this model as the Creature tool's look and goes back to the
    /// world in design mode, ready to tap the ground.
    private func useAsCharacter(_ controller: Glass3DController) {
        controller.creatureLook = controller.characterID(forGenerated: current)
        controller.mode = .edit
        controller.tool = .creature
        if let onPlace { onPlace() } else { message = L10n.t("已选好：在设计模式「生物」工具里轻点地面放置。", "Selected: tap the ground with the Creature tool in design mode.") }
    }
}

/// Progress of a running export, reported from background work.
@MainActor final class ExportProgressBox: ObservableObject {
    @Published var value: Double?
    var reporter: @Sendable (Double) -> Void {
        { [weak self] v in Task { @MainActor in if self?.value != nil { self?.value = v } } }
    }
}
