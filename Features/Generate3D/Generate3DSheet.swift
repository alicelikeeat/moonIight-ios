import SwiftUI
import PhotosUI
import ImageIO
import Vision

// v1.76: model from a character turnaround sheet — one picture holding the
// front / back / side views. The figures are split out on the phone, their
// labels read with on-device text recognition, and the views carved into a
// 360° model like the multi-photo path.

enum SheetPipeline {
    struct Analysis: @unchecked Sendable {
        var image: CGImage
        var raster: RasterImage
        var panels: [SheetPanel]
    }

    static func analyze(_ data: Data) throws -> Analysis {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let raster = ModelAnimationExport.raster(image) else { throw Generate3DError.unreadableImage }
        let found = CharacterSheet.panels(raster)
        guard !found.isEmpty else { throw SheetError.noFigures }
        let panels = CharacterSheet.assign(found, labels: labels(image), imageWidth: raster.width, imageHeight: raster.height)
        return Analysis(image: image, raster: raster, panels: panels)
    }

    /// Text in the picture (on-device recognition), normalised, y down.
    static func labels(_ image: CGImage) -> [SheetLabel] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { o in
            guard let text = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return SheetLabel(text: text, x0: Float(b.minX), x1: Float(b.maxX), y0: Float(1 - b.maxY), y1: Float(1 - b.minY))
        }
    }

    static func build(_ analysis: Analysis) throws -> MultiViewResult {
        var photos: [PhotoView: ViewPhoto] = [:]
        for panel in analysis.panels {
            guard let view = panel.view, photos[view] == nil else { continue }
            var photo = CharacterSheet.photo(analysis.raster, panel: panel)
            // The outline from the plain background failed: ask Vision.
            let covered = photo.mask.reduce(0, +) / Float(max(1, photo.mask.count))
            if covered < 0.03, let crop = analysis.image.cropping(to: CGRect(x: panel.x0, y: panel.y0, width: panel.w, height: panel.h)),
               let mask = ImageGenerationPipeline.subjectMask(VNImageRequestHandler(cgImage: crop, orientation: .up)) {
                photo.mask = DepthField(width: mask.width, height: mask.height, nearness: mask.values, mask: mask.values).resampled(width: photo.width, height: photo.height).nearness
            }
            photos[view] = photo
        }
        var options = MultiViewCarver.Options()
        options.resolution = 160
        var result = try MultiViewCarver.build(photos, options: options)
        let unused = analysis.panels.filter { $0.view == nil }.count
        if unused > 0 { result.notes.append(L10n.t("设定图里还有 \(unused) 个视角（如 3/4 斜侧）没有用于建模", "\(unused) more views in the sheet (such as 3/4) were not used")) }
        return result
    }
}

enum SheetError: Error, LocalizedError {
    case noFigures
    var errorDescription: String? {
        L10n.t("没有在图里找到站立的人物。请用背景干净、人物并排站成一行的设定图", "No standing figures were found. Use a sheet with a plain background and the figures side by side in a row")
    }
}

@available(iOS 18.0, *)
struct CharacterSheetCard: View {
    @ObservedObject var store: Generated3DStore
    let onCreated: (Generated3DManifest) -> Void
    @State private var item: PhotosPickerItem?
    @State private var analysis: SheetPipeline.Analysis?
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var busy: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("设定图建模", "Model from a Character Sheet")).font(.headline)
            Text(L10n.t("一张图里并排画着正面、背面、侧面的角色设定图（三视图 / 转面图）。会自动切出每个视角、识别 FRONT / BACK / LEFT 等标签，再按轮廓雕刻成 360° 模型。背景要干净。",
                        "A character sheet with front, back and side views side by side in one picture. Each view is cut out, labels such as FRONT / BACK / LEFT are read, and the outlines are carved into a 360° model. Needs a plain background."))
                .font(.caption).foregroundStyle(.secondary)
            PhotosPicker(selection: $item, matching: .images) {
                Label(analysis == nil ? L10n.t("选择设定图", "Choose a Sheet") : L10n.t("换一张设定图", "Choose Another Sheet"), systemImage: "rectangle.split.3x1")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.moonLiquid).disabled(busy != nil)
            .accessibilityIdentifier("generate3d-sheet-pick")
            if let analysis {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(analysis.panels) { panel in panelView(panel) } }
                }
                let views = analysis.panels.compactMap(\.view)
                Button { build() } label: {
                    Label(L10n.t("用 \(views.count) 个视角建模", "Build from \(views.count) views"), systemImage: "cube.transparent").frame(maxWidth: .infinity)
                }
                .buttonStyle(.moonLiquidProminent).disabled(busy != nil || !views.contains(.front) || views.count < 2)
                .accessibilityIdentifier("generate3d-sheet-build")
                Text(L10n.t("点视角名可以改方向。3/4 斜侧视角不参与雕刻。头发、手指等细节和凹陷处还原不了，生成后可用「自动骨骼」绑定。",
                            "Tap a view's name to change it. 3/4 views are not used. Hair, fingers and hollows are not recovered; rig it afterwards with Auto Rig."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let busy { HStack { ProgressView(); Text(busy).font(.caption) } }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(14).moonGlassCard(radius: 18, tint: .indigo)
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            item = nil
            load(newItem)
        }
    }

    private func panelView(_ panel: SheetPanel) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06))
                if let image = thumbs[panel.id] { Image(uiImage: image).resizable().scaledToFit() }
            }
            .frame(width: 70, height: 120).clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(panel.view == nil ? 0.45 : 1)
            Menu {
                ForEach(PhotoView.allCases) { v in Button(v.title) { set(panel, v) } }
                Button(L10n.t("不用", "Don't use")) { set(panel, nil) }
            } label: {
                Text(panel.view?.title ?? (panel.diagonal ? L10n.t("3/4（不用）", "3/4 (unused)") : L10n.t("不用", "Unused")))
                    .font(.caption2.weight(.semibold))
            }
            if let label = panel.label { Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: 76)
    }

    private func set(_ panel: SheetPanel, _ view: PhotoView?) {
        guard var a = analysis, let i = a.panels.firstIndex(where: { $0.id == panel.id }) else { return }
        // One panel per view: the panel that had it gives it up.
        if let view { for k in a.panels.indices where a.panels[k].view == view { a.panels[k].view = nil } }
        a.panels[i].view = view
        analysis = a
    }

    private func load(_ newItem: PhotosPickerItem) {
        busy = L10n.t("正在切分视角、识别标签…", "Splitting the views and reading labels…"); message = nil
        Task {
            defer { busy = nil }
            guard let data = try? await newItem.loadTransferable(type: Data.self) else { message = L10n.t("图片无法读取", "The picture could not be read"); return }
            do {
                let a = try await Task.detached(priority: .userInitiated) { try SheetPipeline.analyze(data) }.value
                var t: [Int: UIImage] = [:]
                for p in a.panels {
                    if let crop = a.image.cropping(to: CGRect(x: p.x0, y: p.y0, width: p.w, height: p.h)) { t[p.id] = UIImage(cgImage: crop).preparingThumbnail(of: CGSize(width: 140, height: 240)) }
                }
                analysis = a; thumbs = t
            } catch {
                analysis = nil; thumbs = [:]
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func build() {
        guard let a = analysis else { return }
        busy = L10n.t("正在按轮廓雕刻模型…", "Carving the model from the outlines…"); message = nil
        Task {
            defer { busy = nil }
            do {
                let result = try await Task.detached(priority: .userInitiated) { try SheetPipeline.build(a) }.value
                let manifest = try await store.storeMultiView(result, name: L10n.t("设定图模型", "Sheet model"))
                analysis = nil; thumbs = [:]
                onCreated(manifest)
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
