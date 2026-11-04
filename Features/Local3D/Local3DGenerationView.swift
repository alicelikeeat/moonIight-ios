import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct Local3DGenerationView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = GenerationTaskManager.shared
    @State private var photo: PhotosPickerItem?
    @State private var files = false
    @State private var library = false
    @State private var dark = false
    @State private var fill = true
    @State private var confirmedStaticOrbit = false
    @State private var deleteCandidate: GeneratedModelManifest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("完全在此 iPhone 本地处理。图片生成带真实三维网格的深度立体模型；背面不可见，不能当作完整 360° 重建。")
                    .font(.callout).foregroundStyle(.secondary)
                if #unavailable(iOS 17.0) {
                    Label("图片生成需要 iOS 17+。本系统可导入分析视频、查看已保存模型。", systemImage: "info.circle")
                }
                importControls
                if manager.busy {
                    VStack(alignment: .leading, spacing: 8) {
                        if let fraction = manager.fraction { ProgressView(value: fraction) } else { ProgressView() }
                        Text(manager.stage).font(.callout)
                        Text("设备发热时会等待降温；摄影测量会停止。取消会在当前系统步骤结束后释放资源。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("取消任务", role: .cancel) { manager.cancel() }.accessibilityIdentifier("local3d-cancel")
                    }
                } else if !manager.stage.isEmpty {
                    Text(manager.stage).font(.callout).accessibilityIdentifier("local3d-status")
                }
                if let error = manager.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("重试素材处理") { manager.retry() }.disabled(manager.busy)
                    }
                    .accessibilityIdentifier("local3d-error")
                }
                if let video = manager.video { videoReport(video) }
                if let entity = manager.entity, let manifest = manager.selection, let preset = manager.preset {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(manifest.kind == .depthSurface ? "深度立体模型 · 背面未恢复" : "多视角摄影测量模型").font(.headline)
                        GeneratedModelPreview(model: entity, preset: preset, darkBackground: dark, fillLight: fill)
                            .frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("local3d-preview")
                            .accessibilityLabel("RealityKit 三维预览，可拖动旋转、双指缩放")
                        Text("拖动 360° 旋转 · 双指缩放 · 静态模型").font(.caption).foregroundStyle(.secondary)
                        HStack { Toggle("深色背景", isOn: $dark); Toggle("补光", isOn: $fill) }
                        modelDetails(manifest)
                        materialControls(preset)
                        ShareLink(item: GeneratedAssetStore.shared.modelURL(manifest.id)) {
                            Label("导出原始 USDZ", systemImage: "square.and.arrow.up")
                        }
                        Text("颜色预设保存在本机，导出的是原始纹理模型；没有骨骼、动画或独立服装部件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("本地 3D 资产（\(manager.models.count)）").font(.headline)
                if manager.models.isEmpty { Text("尚无模型。选择图片开始生成。").foregroundStyle(.secondary) }
                ForEach(manager.models) { manifest in
                    HStack {
                        Button { manager.open(manifest) } label: {
                            VStack(alignment: .leading) {
                                Text(manifest.title).lineLimit(1)
                                Text((manifest.kind == .depthSurface ? "深度立体模型" : "摄影测量") + (manifest.realityKitValidated ? " · 已验证加载" : " · 待验证加载"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("local3d-open-\(manifest.id)")
                        Button(role: .destructive) { deleteCandidate = manifest } label: { Image(systemName: "trash") }
                    }
                    .disabled(manager.busy)
                    Divider()
                }
                Text("高级研发尚未实现：完整 360° AI 角色、自动骨骼/蒙皮、动画适配、独立服装识别与自由换装。")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink("离线深度模型来源与许可") { Local3DLicenseView() }
            }
            .padding()
        }
        .navigationTitle("本地图片 / 视频转 3D")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $files, allowedContentTypes: [.jpeg, .png, .heic, .heif, .movie]) { result in
            switch result { case .success(let url): manager.importFile(url); case .failure(let error): manager.error = error.localizedDescription }
        }
        .sheet(isPresented: $library) {
            Glass3DMediaPicker(store: app.mediaStore, title: "选择本地生成素材", selectionOnly: true) { manager.reuse($0) }
        }
        .onChange(of: photo) { item in if let item { manager.importPhotos(item); photo = nil } }
        .onChange(of: scenePhase) { phase in
            if phase == .background { manager.cancel(); manager.releasePreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            manager.cancel(reason: .memory); manager.releasePreview()
        }
        .onDisappear { manager.cancel(); manager.releasePreview() }
        .task { await manager.refresh() }
        .confirmationDialog("删除此生成模型及其预设？共享原素材只在无其他模型引用时清理。", isPresented: Binding(
            get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible) {
            if let candidate = deleteCandidate { Button("删除模型", role: .destructive) { manager.delete(candidate); deleteCandidate = nil } }
        }
        .accessibilityIdentifier("local3d-screen")
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $photo, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                Label("从相册选择图片或视频", systemImage: "photo.on.rectangle")
            }.accessibilityIdentifier("local3d-photos")
            Button { files = true } label: { Label("从文件导入", systemImage: "folder") }
                .accessibilityIdentifier("local3d-files")
            Button { library = true } label: { Label("复用 Moonlight 素材库", systemImage: "square.stack") }
            Text(LocalObjectCapture.supported ? "设备支持本地 Object Capture；仅对合适的静态物体多视角输入尝试。" : "设备不支持本地 Object Capture；视频仍可抽帧检查及选择单帧立体化。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(manager.busy)
    }

    private func videoReport(_ video: VideoReconstructionInput) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("视频质量报告 · 尚未重建").font(.headline)
            Text("采样 \(video.report.sampled) · 保留 \(video.report.accepted) · 模糊 \(video.report.blurry) · 重复 \(video.report.duplicates) · 人物帧 \(video.report.humanFrames)")
                .font(.caption)
            Text(video.report.guidance).font(.callout)
            Text("相似度只能估计画面变化，不能证明环绕角度；模糊/重复阈值尚需真机校准。")
                .font(.caption).foregroundStyle(.secondary)
            if video.report.canAttemptObjectCapture && LocalObjectCapture.supported {
                Toggle("我拍摄的是静止物体，且已环绕覆盖前后和侧面", isOn: $confirmedStaticOrbit)
                Button("尝试本地摄影测量（待设备验证）") { manager.reconstruct() }
                    .disabled(manager.busy || !confirmedStaticOrbit)
            }
            if !video.frames.isEmpty {
                Text("点选清晰单帧 → 基础深度立体化").font(.subheadline)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(video.frames, id: \.self) { frame in
                            Button { manager.generateFrame(frame) } label: {
                                Glass3DMediaThumbnail(url: frame, kind: .image, side: 80)
                            }.disabled(manager.busy)
                        }
                    }
                }
            }
        }
        .onChange(of: video.id) { _ in confirmedStaticOrbit = false }
    }

    private func modelDetails(_ manifest: GeneratedModelManifest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(manifest.triangles > 0 ? "\(manifest.vertices) 顶点 · \(manifest.triangles) 三角面" : "摄影测量几何统计：暂不可用")
            Text(manifest.textureWidth > 0 ? "贴图 \(manifest.textureWidth) × \(manifest.textureHeight)" : "摄影测量贴图尺寸：暂不可用")
            Text("USDZ \(ByteCountFormatter.string(fromByteCount: Int64(manifest.modelBytes), countStyle: .file)) · 生成 \(manifest.elapsedSeconds, specifier: "%.1f") 秒")
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    private func materialControls(_ preset: ModelSkinPreset) -> some View {
        VStack(alignment: .leading) {
            Text("整体材质编辑").font(.headline)
            slider("红", \.red, preset)
            slider("绿", \.green, preset)
            slider("蓝", \.blue, preset)
            slider("粗糙度", \.roughness, preset)
            Button("保存材质预设") { manager.savePreset() }.disabled(manager.busy)
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<ModelSkinPreset, Float>, _ fallback: ModelSkinPreset) -> some View {
        HStack {
            Text(title).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { (manager.preset ?? fallback)[keyPath: key] },
                                  set: { value in var updated = manager.preset ?? fallback; updated[keyPath: key] = value; manager.preset = updated }), in: 0...1)
        }
    }
}

private struct Local3DLicenseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Depth Anything V2 Small F16").font(.headline)
                Text("原模型：Lihe Yang 等（Depth Anything V2）。Core ML 转换包：Apple。Apache License 2.0；允许商业使用，分发需保留许可及声明。本应用使用原始 Small F16 权重，未修改；推理在本机执行，不下载用户素材或调用远程推理。")
                Text("固定来源：apple/coreml-depth-anything-v2-small @ cfef6f6f2a70783dedc0bfae40cecbc2052285d3。Base/Large 非商业权重未引入。")
                Text(license).font(.caption).textSelection(.enabled)
            }.padding()
        }.navigationTitle("模型许可")
    }
    private var license: String {
        guard let url = Bundle.main.url(forResource: "LICENSE-DepthAnything", withExtension: "txt", subdirectory: "Local3D"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "许可文件缺失：该构建不能作为完整模型分发版本。" }
        return text
    }
}
