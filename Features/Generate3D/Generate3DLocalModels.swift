import SwiftUI
import PhotosUI
import CoreML
import Vision
import ImageIO
import UniformTypeIdentifiers

// v1.75: picture → full 3D model with a learned 3D prior (Tripo-style),
// two ways, both without third-party clouds:
//  • on the user's own computer (tools/local3d: TripoSR or Hunyuan3D-2),
//    phone and computer on the same Wi-Fi;
//  • on the iPhone itself with TripoSR converted to Core ML
//    (tools/triposr-coreml), imported once from Files. Experimental: needs
//    an 8 GB iPhone; speed and heat were not measured on a device.

// MARK: Saving

@available(iOS 18.0, *)
extension Generated3DStore {
    /// Saves a mesh with either a raster texture or an encoded image.
    func storeMesh(_ input: GeneratedMesh, texture: RasterImage?, encodedTexture: Data?, name: String, sourceName: String, engine: String, notes: [String]) async throws -> Generated3DManifest {
        var mesh = input
        mesh.normalize(size: 1)
        let id = UUID().uuidString, meshFile = id + ".m3dg"
        let meshURL = Self.folder("Models").appendingPathComponent(meshFile)
        let textureURL = Self.folder("Textures").appendingPathComponent(id + ".jpg")
        let thumbURL = Self.folder("Thumbnails").appendingPathComponent(id + ".jpg")
        let final = mesh
        let size = try await Task.detached(priority: .userInitiated) { () throws -> (Int, Int) in
            try GeneratedMeshCodec.encode(final).write(to: meshURL, options: .atomic)
            var raster = texture
            if let encodedTexture, let source = CGImageSourceCreateWithData(encodedTexture as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                raster = ModelAnimationExport.raster(image)
            }
            if let raster, let cg = ModelAnimationExport.cgImage(raster), let jpeg = PixelReader.jpeg(cg, quality: 0.92) { try jpeg.write(to: textureURL, options: .atomic) }
            let thumb = ModelRasterizer.render(final, texture: raster, camera: RasterCamera(yaw: 0.35, lighting: true), width: 256, height: 256, background: [40, 44, 56, 255])
            if let cg = ModelAnimationExport.cgImage(thumb), let data = PixelReader.jpeg(cg, quality: 0.85) { try? data.write(to: thumbURL, options: .atomic) }
            return (raster?.width ?? 0, raster?.height ?? 0)
        }.value
        let manifest = Generated3DManifest(
            id: id, name: name, createdAt: Date(), source: .image, sourceName: sourceName, sourceHash: "local3d:" + id,
            engine: engine, engineVersion: "1.75", depthSource: .none, geometry: .imported, quality: .high,
            vertexCount: final.vertexCount, triangleCount: final.triangleCount, textureWidth: size.0, textureHeight: size.1,
            meshFile: meshFile, textureFile: size.0 > 0 ? id + ".jpg" : nil, usdzFile: nil, thumbnailFile: id + ".jpg",
            humanoidDetected: false, rigging: .experimentalNotImplemented, animation: .experimentalNotImplemented, separableParts: .notAvailable, notes: notes)
        try save(manifest)
        return manifest
    }
}

// MARK: On-device TripoSR

enum TripoSROnDevice {
    static var folder: URL { Generated3DStore.folder("Engines").appendingPathComponent("TripoSR", isDirectory: true) }
    static var encoderURL: URL { folder.appendingPathComponent("Encoder.mlmodelc", isDirectory: true) }
    static var decoderURL: URL { folder.appendingPathComponent("decoder.bin") }
    static var installed: Bool { FileManager.default.fileExists(atPath: encoderURL.path) && FileManager.default.fileExists(atPath: decoderURL.path) }
    /// TripoSR's encoder needs several GB while it runs.
    static var deviceSupported: Bool { ProcessInfo.processInfo.physicalMemory >= 7_500_000_000 }

    /// Imports the converter's output folder (TripoSREncoder.mlpackage or
    /// .mlmodel / .mlmodelc, and triposr_decoder.bin), compiling on device.
    static func install(from folderURL: URL) async throws {
        let access = folderURL.startAccessingSecurityScopedResource()
        defer { if access { folderURL.stopAccessingSecurityScopedResource() } }
        let items = (try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)) ?? []
        guard let decoder = items.first(where: { $0.pathExtension == "bin" }) else { throw TripoSRError.modelMissing }
        guard let encoder = items.first(where: { ["mlpackage", "mlmodel", "mlmodelc"].contains($0.pathExtension) }) else { throw TripoSRError.modelMissing }
        _ = try TripoSRDecoder.load(Data(contentsOf: decoder))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let compiled: URL
        if encoder.pathExtension == "mlmodelc" {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mlmodelc")
            try FileManager.default.copyItem(at: encoder, to: copy)
            compiled = copy
        } else {
            compiled = try await MLModel.compileModel(at: encoder)
        }
        try? FileManager.default.removeItem(at: encoderURL)
        try FileManager.default.moveItem(at: compiled, to: encoderURL)
        try? FileManager.default.removeItem(at: decoderURL)
        try FileManager.default.copyItem(at: decoder, to: decoderURL)
    }

    static func remove() { try? FileManager.default.removeItem(at: folder) }

    /// Picture → subject on grey, 512 × 512, channel-first floats 0…1 (as
    /// TripoSR's run.py prepares it, foreground ratio 0.85).
    static func input(_ image: CGImage) throws -> MLMultiArray {
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        guard let raster = ModelAnimationExport.raster(image) else { throw Generate3DError.unreadableImage }
        let maskRaw = ImageGenerationPipeline.subjectMask(handler)
        let mask = maskRaw.map { DepthField(width: $0.width, height: $0.height, nearness: $0.values, mask: $0.values).resampled(width: raster.width, height: raster.height).nearness }
            ?? [Float](repeating: 1, count: raster.width * raster.height)
        var x0 = raster.width, y0 = raster.height, x1 = 0, y1 = 0
        for y in 0..<raster.height { for x in 0..<raster.width where mask[y * raster.width + x] > 0.5 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 > x0, y1 > y0 else { throw Generate3DError.noSubject }
        let side = Float(max(x1 - x0, y1 - y0)) / 0.85
        let cx = Float(x0 + x1) / 2, cy = Float(y0 + y1) / 2
        let array = try MLMultiArray(shape: [1, 3, 512, 512], dataType: .float32)
        let plane = 512 * 512
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { out, _ in
            for y in 0..<512 { for x in 0..<512 {
                let sx = Int(cx + (Float(x) + 0.5 - 256) / 512 * side), sy = Int(cy + (Float(y) + 0.5 - 256) / 512 * side)
                var rgb: [Float] = [0.5, 0.5, 0.5]
                if sx >= 0, sy >= 0, sx < raster.width, sy < raster.height {
                    let a = mask[sy * raster.width + sx], o = (sy * raster.width + sx) * 4
                    for c in 0..<3 { rgb[c] = Float(raster.rgba[o + c]) / 255 * a + 0.5 * (1 - a) }
                }
                for c in 0..<3 { out[c * plane + y * 512 + x] = rgb[c] }
            } }
        }
        return array
    }

    static func run(_ imageURL: URL, resolution: Int, progress: @escaping @Sendable (String, Double) -> Void) async throws -> (mesh: GeneratedMesh, texture: RasterImage) {
        guard installed else { throw TripoSRError.modelMissing }
        guard deviceSupported else { throw TripoSRError.unsupportedDevice }
        progress(L10n.t("准备图片", "Preparing the picture"), 0.05)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024]
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Generate3DError.unreadableImage }
        let input = try Self.input(image)
        try Task.checkCancellation()
        progress(L10n.t("AI 推测 3D 形体（神经网络）", "AI infers the 3D shape (neural network)"), 0.15)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: encoderURL, configuration: configuration)
        let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: input)]))
        guard let name = model.modelDescription.outputDescriptionsByName.keys.first, let triplaneArray = output.featureValue(for: name)?.multiArrayValue else { throw TripoSRError.badOutput("no output") }
        let decoder = try TripoSRDecoder.load(Data(contentsOf: decoderURL))
        let expected = 3 * decoder.channels * decoder.planeSize * decoder.planeSize
        guard triplaneArray.count == expected else { throw TripoSRError.badOutput("\(triplaneArray.count) values, expected \(expected)") }
        var triplane = [Float](repeating: 0, count: expected)
        switch triplaneArray.dataType {
        case .float16:
            triplaneArray.withUnsafeBufferPointer(ofType: Float16.self) { p in for i in 0..<expected { triplane[i] = Float(p[i]) } }
        case .float32:
            triplaneArray.withUnsafeBufferPointer(ofType: Float.self) { p in for i in 0..<expected { triplane[i] = p[i] } }
        default:
            for i in 0..<expected { triplane[i] = triplaneArray[i].floatValue }
        }
        guard triplane.allSatisfy(\.isFinite) else { throw TripoSRError.badOutput("not finite") }
        try Task.checkCancellation()
        progress(L10n.t("提取表面并上色", "Extracting the surface and colours"), 0.5)
        let field = try decoder.mesh(triplane, resolution: resolution, cancelled: { Task.isCancelled })
        progress(L10n.t("制作贴图", "Making the texture"), 0.9)
        let baked = VertexColorBaker.bake(field.mesh, colors: field.colors)
        return (baked.mesh, baked.texture)
    }
}

// MARK: Computer client

enum LocalServerClient {
    static let urlKey = "local3d.url"
    static let tokenAccount = "local3d-token"
    static var config: LocalServerConfig? {
        LocalServerConfig.parse(UserDefaults.standard.string(forKey: urlKey) ?? "", token: SecureSettings.read(tokenAccount) ?? "")
    }

    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        try CloudRiggingProtocol.check(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        return data
    }

    static func generate(_ config: LocalServerConfig, image: Data, progress: @escaping @Sendable (String, Double) -> Void) async throws -> Data {
        progress(L10n.t("上传图片到电脑", "Uploading the picture to the computer"), 0.05)
        var job = try CloudRiggingProtocol.job(try await send(Image3DServerProtocol.create(config, image: image, mime: "image/jpeg", texture: true)))
        let started = Date()
        var attempt = 0
        do {
            while !job.finished {
                try Task.checkCancellation()
                if Date().timeIntervalSince(started) > 900 { throw CloudRigError.timedOut }
                try await Task.sleep(nanoseconds: UInt64(min(3, 0.8 + Double(attempt) * 0.4) * 1e9))
                attempt += 1
                job = try CloudRiggingProtocol.job(try await send(Image3DServerProtocol.status(config, id: job.id)))
                progress(L10n.t("电脑正在生成（\(job.status.rawValue)）", "The computer is generating (\(job.status.rawValue))"), 0.1 + 0.8 * (job.progress ?? 0))
            }
        } catch {
            _ = try? await send(Image3DServerProtocol.cancel(config, id: job.id))
            throw error
        }
        guard job.status == .succeeded else { throw CloudRigError.rejected(job.message ?? job.status.rawValue) }
        progress(L10n.t("下载模型", "Downloading the model"), 0.92)
        let glb = try await send(Image3DServerProtocol.result(config, id: job.id))
        _ = try? await send(Image3DServerProtocol.delete(config, id: job.id))
        return glb
    }
}

// MARK: Card

@available(iOS 18.0, *)
struct LocalAIModelCard: View {
    enum Mode: String, CaseIterable, Identifiable {
        case computer, phone
        var id: Self { self }
        var title: String { self == .computer ? L10n.t("电脑生成", "On my computer") : L10n.t("手机本机", "On this iPhone") }
    }
    @ObservedObject var store: Generated3DStore
    let onCreated: (Generated3DManifest) -> Void
    @State private var mode = Mode.computer
    @State private var address = UserDefaults.standard.string(forKey: LocalServerClient.urlKey) ?? ""
    @State private var token = ""
    @State private var health: String?
    @State private var choosing = false
    @State private var item: PhotosPickerItem?
    @State private var importing = false
    @State private var installed = TripoSROnDevice.installed
    @State private var resolution = 128
    @StateObject private var progress = LocalJobProgress()
    private var busy: String? { progress.stage }
    private var fraction: Double { progress.value }
    @State private var message: String?
    @State private var job: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("AI 图片转完整 3D（类 Tripo）", "AI Picture to Full 3D (Tripo-style)")).font(.headline)
            Text(L10n.t("用训练好的 3D 生成模型（TripoSR / Hunyuan3D-2）从一张图推测出完整 360° 形体，背面和侧面也有形状。不经过任何第三方云。", "A trained 3D model (TripoSR / Hunyuan3D-2) infers the full 360° shape from one picture, back and sides included. No third-party cloud."))
                .font(.caption).foregroundStyle(.secondary)
            Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            if mode == .computer { computer } else { phone }
            if let busy {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { ProgressView(); Text(busy).font(.caption); Spacer(); Button(L10n.t("取消", "Cancel")) { job?.cancel() }.font(.caption) }
                    ProgressView(value: fraction)
                }
            } else {
                Button { choosing = true } label: { Label(L10n.t("选图片并生成", "Pick a Picture and Generate"), systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(mode == .computer ? LocalServerConfig.parse(address, token: token) == nil : !(installed && TripoSROnDevice.deviceSupported))
                    .accessibilityIdentifier("generate3d-local-generate")
            }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(14).background(Color.indigo.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .photosPicker(isPresented: $choosing, selection: $item, matching: .images)
        .onChange(of: item) { _, newItem in if let newItem { item = nil; start(newItem) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            progress.stage = L10n.t("导入并编译模型（可能要一两分钟）", "Importing and compiling the model (may take a minute or two)")
            Task {
                do { try await TripoSROnDevice.install(from: url); installed = true; message = L10n.t("TripoSR 模型已导入", "TripoSR model imported") }
                catch { message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                progress.stage = nil
            }
        }
    }

    @ViewBuilder private var computer: some View {
        Text(L10n.t("在电脑上运行项目里的 tools/local3d/server.py（说明见同目录 README），手机和电脑连同一个 Wi-Fi，填上它显示的地址。", "Run tools/local3d/server.py on your computer (see its README), keep phone and computer on the same Wi-Fi, and enter the address it shows."))
            .font(.caption2).foregroundStyle(.secondary)
        TextField(L10n.t("例如 192.168.1.20:8765", "e.g. 192.168.1.20:8765"), text: $address).textFieldStyle(.roundedBorder).font(.caption)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        SecureField(L10n.t("令牌（如果启动时设了 --token）", "Token (if started with --token)"), text: $token).textFieldStyle(.roundedBorder).font(.caption)
        HStack {
            Button(L10n.t("测试连接", "Test Connection")) { test() }.buttonStyle(.bordered).font(.caption)
            if let health { Text(health).font(.caption2).foregroundStyle(.green) }
        }
    }

    @ViewBuilder private var phone: some View {
        if !TripoSROnDevice.deviceSupported {
            Text(L10n.t("这台 iPhone 内存不足 8 GB，不能在本机运行；请用「电脑生成」。", "This iPhone has less than 8 GB of memory; use On my computer instead.")).font(.caption).foregroundStyle(.orange)
        }
        Text(installed ? L10n.t("已导入 TripoSR 模型。实验功能：速度、发热未经真机测试，生成时请保持在前台。", "TripoSR model imported. Experimental: speed and heat untested on a device; keep the app in front while it runs.")
             : L10n.t("需要先在 Mac 上用 tools/triposr-coreml/convert.py 转换模型（约 0.8 GB），把输出文件夹放进「文件」，再在这里导入。", "First convert the model on a Mac with tools/triposr-coreml/convert.py (about 0.8 GB), put the output folder in Files, then import it here."))
            .font(.caption2).foregroundStyle(.secondary)
        HStack {
            Button(installed ? L10n.t("重新导入模型", "Re-import Model") : L10n.t("导入模型文件夹", "Import Model Folder")) { importing = true }.buttonStyle(.bordered).font(.caption)
            if installed { Button(L10n.t("删除模型", "Delete Model"), role: .destructive) { TripoSROnDevice.remove(); installed = false }.buttonStyle(.bordered).font(.caption) }
        }
        Picker(L10n.t("精细度", "Detail"), selection: $resolution) {
            Text(L10n.t("快 96", "Fast 96")).tag(96); Text(L10n.t("标准 128", "Standard 128")).tag(128); Text(L10n.t("精细 160", "Fine 160")).tag(160)
        }.pickerStyle(.segmented)
    }

    private func test() {
        UserDefaults.standard.set(address, forKey: LocalServerClient.urlKey)
        if !token.isEmpty { SecureSettings.write(token, account: LocalServerClient.tokenAccount) }
        guard let config = LocalServerConfig.parse(address, token: token.isEmpty ? (SecureSettings.read(LocalServerClient.tokenAccount) ?? "") : token) else {
            message = L10n.t("地址无效：http 只能连局域网地址（如 192.168.x.x 或 xxx.local）", "Invalid address: http only to local network addresses (e.g. 192.168.x.x or name.local)"); return
        }
        health = nil; message = nil
        Task {
            do {
                let info = try Image3DServerProtocol.healthInfo(try await LocalServerClient.send(Image3DServerProtocol.health(config)))
                health = L10n.t("已连接：\(info.backend)", "Connected: \(info.backend)")
            } catch { message = L10n.t("连不上电脑：", "Cannot reach the computer: ") + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
        }
    }

    private func start(_ picked: PhotosPickerItem) {
        message = nil; progress.value = 0
        progress.stage = L10n.t("读取图片", "Reading the picture")
        let mode = mode, resolution = resolution
        if mode == .computer {
            UserDefaults.standard.set(address, forKey: LocalServerClient.urlKey)
            if !token.isEmpty { SecureSettings.write(token, account: LocalServerClient.tokenAccount) }
        }
        let config = LocalServerConfig.parse(address, token: token.isEmpty ? (SecureSettings.read(LocalServerClient.tokenAccount) ?? "") : token)
        let report = progress.reporter
        let box = progress
        job = Task {
            defer { box.stage = nil }
            do {
                guard let data = try await picked.loadTransferable(type: Data.self) else { throw Generate3DError.unreadableImage }
                let manifest: Generated3DManifest
                if mode == .computer {
                    guard let config else { throw CloudRigError.notConfigured }
                    let jpeg = await Task.detached { () -> Data in
                        guard let s = CGImageSourceCreateWithData(data as CFData, nil),
                              let img = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1536] as CFDictionary),
                              let jpeg = PixelReader.jpeg(img, quality: 0.92) else { return data }
                        return jpeg
                    }.value
                    let glb = try await LocalServerClient.generate(config, image: jpeg, progress: report)
                    let model = try await Task.detached { try Image3DServerProtocol.model(fromGLB: glb) }.value
                    manifest = try await store.storeMesh(model.mesh, texture: model.texture, encodedTexture: model.encodedTexture, name: L10n.t("电脑 AI 模型", "Computer AI model"),
                                                         sourceName: "Local 3D server", engine: "Moonlight Local 3D (computer)",
                                                         notes: [L10n.t("在你自己的电脑上由 3D 生成模型推测出完整形体（\(config.baseURL.host ?? "")）。", "Full shape inferred by a 3D generation model on your own computer (\(config.baseURL.host ?? "")).")])
                } else {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".img")
                    try data.write(to: url)
                    defer { try? FileManager.default.removeItem(at: url) }
                    let result = try await Task.detached(priority: .userInitiated) { try await TripoSROnDevice.run(url, resolution: resolution, progress: report) }.value
                    manifest = try await store.storeMesh(result.mesh, texture: result.texture, encodedTexture: nil, name: L10n.t("本机 AI 模型", "On-device AI model"),
                                                         sourceName: "TripoSR", engine: "TripoSR (Core ML, on device)",
                                                         notes: [L10n.t("由 TripoSR（MIT 许可）在本机推测出完整形体，网格精细度 \(resolution)。实验功能，未经真机验收。", "Full shape inferred on device by TripoSR (MIT licence), grid \(resolution). Experimental; not accepted on a device.")])
                }
                onCreated(manifest)
            } catch is CancellationError {
                message = L10n.t("已取消", "Cancelled")
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Progress of a local generation, reported from background work.
@MainActor final class LocalJobProgress: ObservableObject {
    @Published var stage: String?
    @Published var value = 0.0
    var reporter: @Sendable (String, Double) -> Void {
        { [weak self] text, value in Task { @MainActor in if self?.stage != nil { self?.stage = text; self?.value = value } } }
    }
}
