import SwiftUI
import PhotosUI
import ImageIO
import Vision
import UniformTypeIdentifiers
#if canImport(ImagePlayground)
import ImagePlayground
#endif

// v1.74: AI one-tap characters from a text prompt, and models from 2–6
// photos. Text: Claude (online, the user's key, confirmed before sending)
// or local keywords (offline) choose a character spec that is built into a
// rigged 3D model on the phone; Apple's on-device image generation (where
// available) makes a picture that goes through the picture-to-3D pipeline.

// MARK: Saving

@available(iOS 18.0, *)
extension Generated3DStore {
    /// Saves a text-built character with its exact rig (ready to animate).
    func storeProcedural(_ built: ColouredMesh, spec: CharacterSpec, prompt: String, engine: String) async throws -> Generated3DManifest {
        let id = UUID().uuidString
        let meshFile = id + ".m3dg", textureFile = id + ".jpg"
        let mesh = built.mesh, palette = built.palette
        let meshURL = Self.folder("Models").appendingPathComponent(meshFile)
        let textureURL = Self.folder("Textures").appendingPathComponent(textureFile)
        let thumbURL = Self.folder("Thumbnails").appendingPathComponent(id + ".jpg")
        try await Task.detached(priority: .userInitiated) {
            try GeneratedMeshCodec.encode(mesh).write(to: meshURL, options: .atomic)
            guard let image = ModelAnimationExport.cgImage(palette), let jpeg = PixelReader.jpeg(image, quality: 1) else { throw Generate3DError.saveFailed("texture") }
            try jpeg.write(to: textureURL, options: .atomic)
            var framed = mesh; framed.normalize(size: 1)
            let thumb = ModelRasterizer.render(framed, texture: palette, camera: RasterCamera(yaw: 0.35, lighting: true), width: 256, height: 256, background: [40, 44, 56, 255])
            if let cg = ModelAnimationExport.cgImage(thumb), let data = PixelReader.jpeg(cg, quality: 0.85) { try? data.write(to: thumbURL, options: .atomic) }
        }.value
        // The exact rig goes straight into the v1.73 rig store.
        let skeleton = built.skeleton, skin = built.skin
        let results = await Task.detached(priority: .userInitiated) { RiggingPipeline.test(mesh, skeleton: skeleton, skin: skin) }.value
        let character = RiggedCharacter(modelID: id, meshFile: meshFile, optimizedMeshFile: nil, skinFile: id + ".skin", vertexCount: mesh.vertexCount,
                                        skeleton: skeleton, clips: MotionClip.library, sockets: SkeletonBuilder.sockets(skeleton),
                                        diagnostics: RiggingDiagnostics(results: results),
                                        metadata: RiggedCharacterMetadata(engine: "Moonlight Character Builder", engineVersion: "1.74.0", route: "built",
                                                                          createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)), poseType: "aPose"))
        try RiggingAssetStore(folder: Self.folder("Rigs")).save(character, skin: skin, optimizedMesh: nil)
        let passed = results.filter { $0.status == .pass }.count
        let manifest = Generated3DManifest(
            id: id, name: spec.name, createdAt: Date(), source: .image, sourceName: prompt, sourceHash: "text:" + id,
            engine: engine, engineVersion: "1.74", depthSource: .none, geometry: .procedural, quality: .medium,
            vertexCount: mesh.vertexCount, triangleCount: mesh.triangleCount, textureWidth: palette.width, textureHeight: palette.height,
            meshFile: meshFile, textureFile: textureFile, usdzFile: nil, thumbnailFile: id + ".jpg",
            humanoidDetected: true, rigging: .experimentalVerified, animation: .experimentalVerified, separableParts: .notAvailable,
            notes: [L10n.t("由文字「\(prompt)」生成：\(spec.outfit.rawValue) 服装，配件 \(spec.accessories.map(\.rawValue).joined(separator: "、"))。",
                           "Made from the text \"\(prompt)\": \(spec.outfit.rawValue) outfit, accessories \(spec.accessories.map(\.rawValue).joined(separator: ", ")))."),
                    L10n.t("自带 27 关节骨骼（由生成器直接给出，不是识别出来的），8 项动作测试通过 \(passed) 项。尚未经过人工真机验收。",
                           "Comes with a 27-joint rig (given by the builder, not estimated); \(passed) of 8 motion tests passed. Not yet accepted on a device by a person.")])
        try save(manifest)
        return manifest
    }

    /// Saves a model carved from several photos.
    func storeMultiView(_ result: MultiViewResult, name: String) async throws -> Generated3DManifest {
        let id = UUID().uuidString
        let meshFile = id + ".m3dg", textureFile = id + ".jpg"
        var mesh = result.mesh
        mesh.normalize(size: 1)
        let atlas = result.atlas, final = mesh
        let meshURL = Self.folder("Models").appendingPathComponent(meshFile)
        let textureURL = Self.folder("Textures").appendingPathComponent(textureFile)
        let thumbURL = Self.folder("Thumbnails").appendingPathComponent(id + ".jpg")
        try await Task.detached(priority: .userInitiated) {
            try GeneratedMeshCodec.encode(final).write(to: meshURL, options: .atomic)
            guard let image = ModelAnimationExport.cgImage(atlas), let jpeg = PixelReader.jpeg(image, quality: 0.9) else { throw Generate3DError.saveFailed("texture") }
            try jpeg.write(to: textureURL, options: .atomic)
            let thumb = ModelRasterizer.render(final, texture: atlas, camera: RasterCamera(yaw: 0.35, lighting: true), width: 256, height: 256, background: [40, 44, 56, 255])
            if let cg = ModelAnimationExport.cgImage(thumb), let data = PixelReader.jpeg(cg, quality: 0.85) { try? data.write(to: thumbURL, options: .atomic) }
        }.value
        let manifest = Generated3DManifest(
            id: id, name: name, createdAt: Date(), source: .image, sourceName: result.views.map(\.title).joined(separator: "+"), sourceHash: "views:" + id,
            engine: "Moonlight Multi-view Carver", engineVersion: "1.74", depthSource: .none, geometry: .multiView, quality: .medium,
            vertexCount: final.vertexCount, triangleCount: final.triangleCount, textureWidth: atlas.width, textureHeight: atlas.height,
            meshFile: meshFile, textureFile: textureFile, usdzFile: nil, thumbnailFile: id + ".jpg",
            humanoidDetected: false, rigging: .experimentalNotImplemented, animation: .experimentalNotImplemented, separableParts: .notAvailable,
            notes: [L10n.t("用 \(result.views.count) 张照片（\(result.views.map(\.title).joined(separator: "、"))）建模。", "Made from \(result.views.count) photos (\(result.views.map(\.title).joined(separator: ", ")))).")] + result.notes)
        try save(manifest)
        return manifest
    }
}

// MARK: Pipelines

enum MultiViewPipeline {
    /// Photo files → subject masks (Vision) → carved model.
    static func run(_ files: [PhotoView: URL]) throws -> MultiViewResult {
        var photos: [PhotoView: ViewPhoto] = [:]
        for (view, url) in files {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 900]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let raster = ModelAnimationExport.raster(image) else { throw Generate3DError.unreadableImage }
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            guard let mask = ImageGenerationPipeline.subjectMask(handler) else { throw MultiViewError.noSubject(view) }
            let values = DepthField(width: mask.width, height: mask.height, nearness: mask.values, mask: mask.values).resampled(width: raster.width, height: raster.height).nearness
            photos[view] = ViewPhoto(width: raster.width, height: raster.height, mask: values, image: raster)
        }
        return try MultiViewCarver.build(photos)
    }
}

/// Apple's on-device image generation (Image Playground; Apple Intelligence devices, iOS 18.4+).
enum AppleImageGenerator {
    static func picture(for prompt: String) async throws -> CGImage {
        #if canImport(ImagePlayground)
        if #available(iOS 18.4, *) {
            let creator = try await ImageCreator()
            let style = creator.availableStyles.contains(.animation) ? ImagePlaygroundStyle.animation : (creator.availableStyles.first ?? .animation)
            let text = prompt + ", full body, standing straight facing the viewer, arms slightly away from the body, plain light background"
            for try await created in creator.images(for: [.text(text)], style: style, limit: 1) { return created.cgImage }
        }
        #endif
        throw Generate3DError.depthUnavailable(L10n.t("这台设备不支持 Apple 本机生图（需要支持 Apple 智能的 iPhone 和 iOS 18.4 以上）", "Apple on-device image generation is not available here (needs an Apple Intelligence iPhone and iOS 18.4+)"))
    }
}

/// Claude character design request (the user's own key).
enum ClaudeCharacterClient {
    static func design(prompt: String, model: ClaudeMotion.ModelChoice, apiKey: String) async throws -> CharacterSpec {
        guard !apiKey.isEmpty else { throw ClaudeMotionError.noKey }
        var request = URLRequest(url: ClaudeMotion.endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        for (k, v) in ClaudeMotion.headers(apiKey: apiKey, model: model) { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try ClaudeCharacter.requestBody(prompt: prompt, model: model)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try ClaudeCharacter.spec(fromResponse: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: Cards

@available(iOS 18.0, *)
struct AICharacterCard: View {
    enum Engine: String, CaseIterable, Identifiable {
        case claude, keywords, apple
        var id: Self { self }
        var title: String {
            switch self {
            case .claude: L10n.t("Claude 设计", "Claude"); case .keywords: L10n.t("本机关键词", "Keywords")
            case .apple: L10n.t("Apple 本机生图", "Apple Image")
            }
        }
    }
    @ObservedObject var store: Generated3DStore
    @ObservedObject var tasks: GenerationTaskManager
    let quality: GenerationQuality
    let onCreated: (Generated3DManifest) -> Void
    @State private var prompt = ""
    @State private var engine = SecureSettings.read(ClaudeMotion.keyAccount)?.isEmpty == false ? Engine.claude : .keywords
    @State private var busy = false
    @State private var message: String?
    @State private var keyDraft = ""
    @State private var hasKey = SecureSettings.read(ClaudeMotion.keyAccount)?.isEmpty == false
    @State private var confirm = false

    private static let examples = [L10n.t("拿剑和盾的红色战士", "red warrior with sword and shield"), L10n.t("紫色长发法师", "purple mage with long hair"),
                                   L10n.t("金发弓箭手", "blonde archer"), L10n.t("可爱的机器人", "cute robot"), L10n.t("黑衣忍者", "ninja in black")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("AI 一键生成角色", "AI One-Tap Character")).font(.headline)
            TextField(L10n.t("描述你想要的角色，例如：一个拿剑的战士", "Describe a character, e.g. a warrior with a sword"), text: $prompt, axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityIdentifier("generate3d-ai-prompt")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { ForEach(Self.examples, id: \.self) { e in Button(e) { prompt = e }.buttonStyle(.moonLiquid).font(.caption) } }
            }
            Picker(L10n.t("方式", "Engine"), selection: $engine) { ForEach(Engine.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text(engineNote).font(.caption2).foregroundStyle(.secondary)
            if engine == .claude && !hasKey {
                HStack {
                    SecureField("Anthropic API Key", text: $keyDraft).textFieldStyle(.roundedBorder).font(.caption).textInputAutocapitalization(.never)
                    Button(L10n.t("保存", "Save")) {
                        let k = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines); guard !k.isEmpty else { return }
                        SecureSettings.write(k, account: ClaudeMotion.keyAccount); hasKey = true; keyDraft = ""
                    }.buttonStyle(.moonLiquid)
                }
            }
            if busy { HStack { ProgressView(); Text(L10n.t("正在生成…", "Generating…")).font(.caption) } }
            else {
                Button { if engine == .claude { confirm = true } else { generate() } } label: {
                    Label(L10n.t("生成 3D 角色", "Generate 3D Character"), systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.moonLiquidProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || tasks.running || (engine == .claude && !hasKey))
                .accessibilityIdentifier("generate3d-ai-generate")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(14).moonGlassCard(radius: 18, tint: .purple)
        .confirmationDialog(L10n.t("发送给 Claude？", "Send to Claude?"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L10n.t("发送", "Send")) { generate() }
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("只发送这段文字描述（不含图片），费用记在你的 API Key 上。被拒绝时会由 Anthropic 推荐的备用模型自动重试。", "Only this text is sent (no pictures); usage is billed to your API key. If declined, Anthropic's recommended fallback model retries automatically."))
        }
    }

    private var engineNote: String {
        switch engine {
        case .claude: L10n.t("联网：Claude 按描述选择体型、服装、发型、配件和配色，手机上搭出完整 360° 的 3D 角色，自带骨骼，可直接做动作。", "Online: Claude picks body, outfit, hair, accessories and colours; the phone builds a full 360° rigged 3D character.")
        case .keywords: L10n.t("离线：按关键词（战士、法师、骑士、弓箭手、忍者、公主、机器人、颜色等）搭出角色。这不是 AI，只认识常见词。", "Offline: builds from keywords (warrior, mage, knight, archer, ninja, princess, robot, colours…). Not AI; it only knows common words.")
        case .apple: L10n.t("本机 AI：先用 Apple 图乐园生成一张全身图，再把图片立体化（深度立体模型，不是完整 360°）。需要支持 Apple 智能的 iPhone。", "On-device AI: Apple Image Playground makes a full-body picture, then it becomes a depth model (not full 360°). Needs an Apple Intelligence iPhone.")
        }
    }

    private func generate() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                switch engine {
                case .apple:
                    let image = try await AppleImageGenerator.picture(for: text)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                    guard let data = PixelReader.jpeg(image, quality: 0.95) else { throw Generate3DError.unreadableImage }
                    try data.write(to: url)
                    tasks.generate(image: url, name: String(text.prefix(30)), quality: quality, back: .inflated, store: store, removeAfter: true)
                case .claude, .keywords:
                    let spec: CharacterSpec
                    if engine == .claude {
                        guard let key = SecureSettings.read(ClaudeMotion.keyAccount) else { throw ClaudeMotionError.noKey }
                        spec = try await ClaudeCharacterClient.design(prompt: text, model: ClaudeMotion.models[0], apiKey: key)
                    } else {
                        spec = CharacterKeywords.spec(for: text)
                    }
                    let built = await Task.detached(priority: .userInitiated) { ProceduralCharacterBuilder.build(spec) }.value
                    let manifest = try await store.storeProcedural(built, spec: spec, prompt: text, engine: engine == .claude ? "Claude + Moonlight Character Builder" : "Moonlight Character Builder (keywords)")
                    onCreated(manifest)
                }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

@available(iOS 18.0, *)
struct MultiViewCard: View {
    @ObservedObject var store: Generated3DStore
    let onCreated: (Generated3DManifest) -> Void
    @State private var files: [PhotoView: URL] = [:]
    @State private var thumbs: [PhotoView: UIImage] = [:]
    @State private var loading: Set<PhotoView> = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("多张照片建模", "Model from Several Photos")).font(.headline)
            Text(L10n.t("同一个人物或物体，从不同方向各拍一张：前后 2 张、前后左右 4 张，或再加上下共 6 张。背景尽量干净，每张都要拍全。", "Photos of the same subject from different sides: front + back (2), + left + right (4), or + top + bottom (6). Plain background, whole subject in each."))
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(PhotoView.allCases) { view in slot(view) }
            }
            if busy { HStack { ProgressView(); Text(L10n.t("正在识别轮廓并建模…", "Finding outlines and building…")).font(.caption) } }
            else {
                Button { build() } label: { Label(L10n.t("用 \(files.count) 张照片建模", "Build from \(files.count) photos"), systemImage: "cube.transparent").frame(maxWidth: .infinity) }
                    .buttonStyle(.moonLiquidProminent).disabled(files[.front] == nil || files.count < 2)
                    .accessibilityIdentifier("generate3d-multiview-build")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(14).moonGlassCard(radius: 18, tint: .teal)
    }

    /// v1.76: each slot has its own picker, so the photo always lands in
    /// the slot that was tapped (the shared picker lost it on dismissal).
    private func load(_ newItem: PhotosPickerItem, into view: PhotoView) {
        loading.insert(view)
        Task {
            defer { loading.remove(view) }
            guard let data = try? await newItem.loadTransferable(type: Data.self) else { message = L10n.t("照片无法读取", "The photo could not be read"); return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("view-\(view.rawValue)-" + UUID().uuidString + ".img")
            do { try data.write(to: url) } catch { message = L10n.t("照片无法保存：", "The photo could not be saved: ") + error.localizedDescription; return }
            if let old = files[view] { try? FileManager.default.removeItem(at: old) }
            files[view] = url
            thumbs[view] = UIImage(data: data).flatMap { $0.preparingThumbnail(of: CGSize(width: 160, height: 160)) }
            message = nil
        }
    }

    private func slot(_ view: PhotoView) -> some View {
        PhotosPicker(selection: Binding<PhotosPickerItem?>(get: { nil }, set: { if let item = $0 { load(item, into: view) } }), matching: .images) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
                    if let image = thumbs[view] { Image(uiImage: image).resizable().scaledToFill() }
                    else if loading.contains(view) { ProgressView() }
                    else { Image(systemName: view == .front ? "person.fill" : "plus").foregroundStyle(.secondary) }
                }
                .frame(height: 80).clipShape(RoundedRectangle(cornerRadius: 12))
                Text(view.title + (view == .front ? L10n.t("（必需）", " (needed)") : "")).font(.caption2.weight(.semibold))
                Text(view.hint).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .buttonStyle(.moonJelly)
        .contextMenu { if files[view] != nil { Button(L10n.t("移除", "Remove"), role: .destructive) { files[view] = nil; thumbs[view] = nil } } }
        .accessibilityIdentifier("generate3d-view-" + view.rawValue)
    }

    private func build() {
        let selected = files
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                // v1.90: a whole person in front (and back) → the universal base body.
                let manifest: Generated3DManifest
                if let front = selected[.front],
                   let built = try await Task.detached(priority: .userInitiated, operation: { try await BaseBodyCharacterPipeline.run(front: front, back: selected[.back], progress: { _, _ in }) }).value {
                    manifest = try await store.storeBaseBody(built, name: L10n.t("照片人物", "Photo person"), sourceName: selected.keys.map(\.title).joined(separator: "+"), hash: "views:" + UUID().uuidString)
                } else {
                    let result = try await Task.detached(priority: .userInitiated) { try MultiViewPipeline.run(selected) }.value
                    manifest = try await store.storeMultiView(result, name: L10n.t("多视角模型", "Multi-view model"))
                }
                for url in selected.values { try? FileManager.default.removeItem(at: url) }
                files = [:]; thumbs = [:]
                onCreated(manifest)
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
