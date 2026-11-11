import SwiftUI
import PhotosUI
import ImageIO

// v1.93: cloud 3D generation with Meshy, on the AI 3D page. The user's own
// API key (kept in the keychain), one to four pictures (front first), and a
// confirmation before every send that says what leaves the phone and that
// it costs credits. The result is a GLB with clean remeshed geometry and
// PBR textures, saved like every other model: it can be rigged, made a base
// body, or worn as a garment.

enum MeshyClient {
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try Meshy3DProtocol.check(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        return data
    }

    /// Pictures → the finished task's GLB. Cancelling stops the waiting (a task
    /// Meshy already started keeps running there and keeps its credits).
    static func generate(key: String, pictures: [Data], options: MeshyOptions,
                         progress: @escaping @Sendable (String, Double) -> Void) async throws -> (glb: Data, task: MeshyTask) {
        progress(L10n.t("上传图片到 Meshy", "Uploading the pictures to Meshy"), 0.03)
        let id = try Meshy3DProtocol.createdID(try await send(Meshy3DProtocol.create(key: key, pictures: pictures, options: options)))
        let started = Date()
        var attempt = 0
        var task = MeshyTask(id: id, status: .pending, progress: 0)
        while !task.finished {
            try Task.checkCancellation()
            if Date().timeIntervalSince(started) > 1500 { throw MeshyError.timedOut }
            try await Task.sleep(nanoseconds: UInt64(Meshy3DProtocol.pollDelay(attempt: attempt) * 1e9))
            attempt += 1
            task = try Meshy3DProtocol.task(try await send(Meshy3DProtocol.status(key: key, id: id)))
            let waiting = task.status == .pending ? L10n.t("排队中", "Queued") + ((task.preceding ?? 0) > 0 ? L10n.t("（前面 \(task.preceding ?? 0) 个任务）", " (\(task.preceding ?? 0) ahead)") : "")
                                                  : L10n.t("Meshy 正在生成", "Meshy is generating")
            progress(waiting + " \(task.progress)%", 0.05 + 0.85 * Double(task.progress) / 100)
        }
        switch task.status {
        case .failed: throw MeshyError.failed(task.error ?? "FAILED")
        case .canceled: throw MeshyError.canceled
        default: break
        }
        guard let url = task.glb else { throw MeshyError.noModel }
        progress(L10n.t("下载模型", "Downloading the model"), 0.93)
        // The model link is a signed asset URL: no key is sent to it.
        let (glb, response) = try await URLSession.shared.data(from: url)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0), !glb.isEmpty else { throw MeshyError.noModel }
        return (glb, task)
    }

    /// A JPEG no longer than 1536 pixels on its longer side.
    static func jpeg(_ data: Data) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PixelReader.jpeg(image, quality: 0.92)
    }
}

@available(iOS 18.0, *)
struct MeshyCard: View {
    @ObservedObject var store: Generated3DStore
    let onCreated: (Generated3DManifest) -> Void
    @State private var key = ""
    @State private var hasKey = SecureSettings.read(Meshy3DProtocol.keyAccount)?.isEmpty == false
    @State private var items: [PhotosPickerItem] = []
    @State private var pictures: [Data] = []
    @State private var options = MeshyOptions()
    @State private var confirming = false
    @State private var message: String?
    @State private var job: Task<Void, Never>?
    @StateObject private var progress = LocalJobProgress()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("云端 AI 生成（Meshy，质量最高）", "Cloud AI Generation (Meshy, best quality)"), systemImage: "cloud").font(.headline)
            Text(L10n.t("用你自己的 Meshy API Key，把 1–4 张同一对象的图片（第一张是正面，可加背面、左、右）发到 Meshy 生成完整 3D：重新布线的干净网格、PBR 贴图；人物可直接生成 T-Pose，方便绑骨和穿衣。图片会离开手机，每次按 Meshy 的价格消耗你账户的额度。",
                        "With your own Meshy API key, 1–4 pictures of one subject (the first is the front; add back, left, right) go to Meshy for a full 3D model: clean remeshed geometry and PBR textures; people can come out in a T-pose, ready to rig and dress. Pictures leave the phone, and each run uses your account's credits at Meshy's prices."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField(hasKey ? L10n.t("已保存 Key（填新的可替换）", "Key saved (enter a new one to replace)") : L10n.t("Meshy API Key（msy_…）", "Meshy API key (msy_…)"), text: $key)
                    .textFieldStyle(.roundedBorder).font(.caption).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("meshy-key")
                if hasKey {
                    Button(L10n.t("删除", "Remove"), role: .destructive) { SecureSettings.write("", account: Meshy3DProtocol.keyAccount); hasKey = false; key = "" }
                        .font(.caption).accessibilityIdentifier("meshy-key-remove")
                }
            }
            Text(L10n.t("Key 只保存在这台手机的钥匙串里，只发给 api.meshy.ai。在 Meshy 网站的 API Keys 页面创建，可以给它设每月额度上限。", "The key stays in this phone's keychain and is sent only to api.meshy.ai. Create it on Meshy's API Keys page; you can give it a monthly credit limit."))
                .font(.caption2).foregroundStyle(.secondary)
            PhotosPicker(selection: $items, maxSelectionCount: Meshy3DProtocol.maxPictures, selectionBehavior: .ordered, matching: .images) {
                Label(pictures.isEmpty ? L10n.t("选 1–4 张图片（按选择顺序，第一张是正面）", "Pick 1–4 pictures (in order; the first is the front)") : L10n.t("已选 \(pictures.count) 张图片", "\(pictures.count) pictures chosen"), systemImage: "photo.on.rectangle.angled")
            }
            .font(.caption).accessibilityIdentifier("meshy-pictures")
            Toggle(L10n.t("这是人物：生成 T-Pose", "A person: generate in a T-pose"), isOn: $options.character).font(.caption).accessibilityIdentifier("meshy-character")
            Toggle(L10n.t("PBR 贴图（金属度、粗糙度、法线）", "PBR maps (metallic, roughness, normal)"), isOn: $options.pbr).font(.caption).accessibilityIdentifier("meshy-pbr")
            Toggle(L10n.t("精细几何（更慢，消耗更多额度）", "Fine geometry (slower, more credits)"), isOn: $options.fineGeometry).font(.caption).accessibilityIdentifier("meshy-fine")
            Picker(L10n.t("面数", "Faces"), selection: $options.polycount) {
                Text(L10n.t("1 万（远景）", "10k (far)")).tag(10_000)
                Text(L10n.t("3 万（手机推荐）", "30k (phone)")).tag(30_000)
                Text(L10n.t("6 万（主角）", "60k (hero)")).tag(60_000)
            }
            .font(.caption).accessibilityIdentifier("meshy-polycount")
            if let stage = progress.stage {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { ProgressView(); Text(stage).font(.caption); Spacer(); Button(L10n.t("停止等待", "Stop Waiting")) { job?.cancel() }.font(.caption) }
                    ProgressView(value: progress.value)
                }
            } else {
                Button { confirming = true } label: { Label(L10n.t("发送到 Meshy 并生成", "Send to Meshy and Generate"), systemImage: "paperplane").frame(maxWidth: .infinity) }
                    .buttonStyle(.moonLiquidProminent).disabled(pictures.isEmpty || !(hasKey || !key.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("meshy-generate")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("meshy-message") }
        }
        .padding(14).moonGlassCard(radius: 18, tint: .teal)
        .onChange(of: items) { _, picked in load(picked) }
        .confirmationDialog(L10n.t("把 \(pictures.count) 张图片发送到 Meshy？", "Send \(pictures.count) pictures to Meshy?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L10n.t("发送并生成（消耗额度）", "Send and Generate (uses credits)")) { start() }.accessibilityIdentifier("meshy-confirm")
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("图片会上传到 Meshy（api.meshy.ai）并按它的价格扣除你账户的额度。任务一旦开始，即使在这里停止等待也不会退还额度。", "The pictures are uploaded to Meshy (api.meshy.ai) and your account is charged credits at its prices. Once a task has started, stopping the wait here does not refund them."))
        }
    }

    private func load(_ picked: [PhotosPickerItem]) {
        Task {
            var out: [Data] = []
            for item in picked.prefix(Meshy3DProtocol.maxPictures) {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let jpeg = await Task.detached(priority: .userInitiated, operation: { MeshyClient.jpeg(data) }).value { out.append(jpeg) }
            }
            pictures = out
            message = out.count < picked.count ? L10n.t("有图片无法读取，已跳过。", "Some pictures could not be read and were skipped.") : nil
        }
    }

    private func start() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { SecureSettings.write(typed, account: Meshy3DProtocol.keyAccount); hasKey = true; key = "" }
        guard let apiKey = SecureSettings.read(Meshy3DProtocol.keyAccount), !apiKey.isEmpty else { message = MeshyError.noKey.errorDescription; return }
        let pictures = pictures, options = options, report = progress.reporter, box = progress
        message = nil
        progress.stage = L10n.t("准备发送", "Preparing")
        job = Task {
            defer { box.stage = nil }
            do {
                let result = try await MeshyClient.generate(key: apiKey, pictures: pictures, options: options, progress: report)
                let glb = result.glb
                let model = try await Task.detached(priority: .userInitiated) { try Image3DServerProtocol.model(fromGLB: glb) }.value
                var notes = [L10n.t("由 Meshy 云端从 \(pictures.count) 张图片生成（重新布线约 \(options.clamped.polycount) 面" + (options.character ? "，T-Pose" : "") + "）。", "Generated by Meshy's cloud from \(pictures.count) pictures (remeshed to about \(options.clamped.polycount) faces" + (options.character ? ", T-pose" : "") + ").")]
                if let credits = result.task.credits { notes.append(L10n.t("本次消耗 \(credits) 额度。", "This run used \(credits) credits.")) }
                if options.pbr { notes.append(L10n.t("文件里的金属度、粗糙度和法线贴图目前没有导入，只用了基础颜色贴图。", "The file's metallic, roughness and normal maps are not imported yet; only the base colour texture is used.")) }
                let manifest = try await store.storeMesh(model.mesh, texture: model.texture, encodedTexture: model.encodedTexture, name: L10n.t("Meshy 云端模型", "Meshy cloud model"),
                                                         sourceName: "Meshy", engine: "Meshy API (cloud)", notes: notes)
                onCreated(manifest)
            } catch is CancellationError {
                message = L10n.t("已停止等待。已经开始的任务仍会在 Meshy 上完成并计费，可在 Meshy 网站下载。", "Stopped waiting. A task that already started still finishes and is charged at Meshy; download it from the Meshy site.")
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
