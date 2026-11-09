import Foundation

// v1.93: the character-sheet standard. What pictures a design needs (front
// required; back and side recommended), how each is checked (whole figure,
// size, pose, plain background, matching proportions, the right view), and
// a grade for the set. Missing views can be proposed from an AI 3D model of
// the front picture (ConceptViewRender turns the model into a picture from
// the missing side); the user confirms each proposal before it is used.
// Pure Swift: the Vision measuring lives in the app layer.

/// Where a view's picture came from.
enum ConceptOrigin: String, Codable, Sendable {
    /// A picture the user picked.
    case user
    /// Cut from a character sheet.
    case sheet
    /// Rendered from an AI 3D model of the front picture (needs the user's confirmation).
    case ai
    /// Rendered from the base body painted with the front only: a preview, no new information.
    case estimate

    var title: String {
        switch self {
        case .user: L10n.t("你的图", "Yours")
        case .sheet: L10n.t("设定图", "From the sheet")
        case .ai: L10n.t("AI 推测", "AI guess")
        case .estimate: L10n.t("底模估计", "Base estimate")
        }
    }
}

/// One view of the design, as measured.
struct ConceptViewInput: Sendable {
    var view: PhotoView
    /// Vision's body points and outline; nil when no person was found.
    var photo: BodyPhoto?
    var width: Int
    var height: Int
    /// Share of the picture's border in one plain colour (0…1).
    var plainBorder: Float
    var origin: ConceptOrigin = .user
}

struct ConceptIssue: Equatable, Sendable, Identifiable {
    enum Level: Int, Comparable, Sendable {
        case blocking = 0, warning, tip
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var symbol: String { switch self { case .blocking: "xmark.octagon.fill"; case .warning: "exclamationmark.triangle.fill"; case .tip: "info.circle" } }
    }
    /// nil: about the whole set.
    var view: PhotoView?
    var code: String
    var level: Level
    var message: String
    var id: String { (view?.rawValue ?? "set") + "." + code }
}

struct ConceptSheetReport: Sendable {
    enum Grade: Int, Comparable, Sendable {
        case notReady = 0, basic, good, complete
        static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .notReady: L10n.t("还不能生成", "Not ready")
            case .basic: L10n.t("基础：只有正面", "Basic: front only")
            case .good: L10n.t("良好：正面 + 背面", "Good: front + back")
            case .complete: L10n.t("完整：正面 + 背面 + 侧面", "Complete: front + back + side")
            }
        }
    }
    var grade: Grade
    var issues: [ConceptIssue]
    /// Usable views (front, back, side), in that order.
    var present: [PhotoView]
    /// Recommended views not given (back and / or side), in that order.
    var missing: [PhotoView]
    var canMake: Bool { grade != .notReady }
    func issues(_ view: PhotoView?) -> [ConceptIssue] { issues.filter { $0.view == view } }
}

enum ConceptSheetSpec {
    struct Requirement: Identifiable, Sendable {
        var view: PhotoView
        var required: Bool
        var why: String
        var how: String
        var id: PhotoView { view }
        var title: String { view == ConceptSheetSpec.side ? L10n.t("侧面", "Side") : view.title }
    }

    /// Either side counts as the side view; `.left` stands for both.
    static let side = PhotoView.left
    static func normalized(_ view: PhotoView) -> PhotoView { view == .right ? .left : view }

    static let requirements: [Requirement] = [
        Requirement(view: .front, required: true,
                    why: L10n.t("决定体型比例和正面贴图；没有正面无法生成。", "Sets the proportions and the front texture; nothing can be made without it."),
                    how: L10n.t("正对镜头、从头到脚完整入画，A 字或 T 字站姿（手臂离开身体），纯色背景。", "Facing the camera, head to toe in frame, A- or T-pose (arms away from the body), plain background.")),
        Requirement(view: .back, required: false,
                    why: L10n.t("背面贴图（头发、背后图案、披风）。没有背面时只能用正面颜色模糊推测。", "The back texture (hair, back details, capes). Without it the back is a blur of the front's colours."),
                    how: L10n.t("和正面同样的姿势、同样的大小，转到背后。", "Same pose and size as the front, seen from behind.")),
        Requirement(view: .left, required: false,
                    why: L10n.t("身体厚度和侧面轮廓（360° 模型用）；也用来核对设计是否一致。底模角色的贴图暂时只用正面和背面。", "Body depth and side outline (for 360° models), and to check the design agrees. Base-body skins use only the front and back for now."),
                    how: L10n.t("正侧面（90°），不要 3/4 斜侧；同样大小、脚在同一高度。", "A true side (90°), not 3/4; same size, feet at the same height.")),
    ]

    /// General rules of a good sheet (shown in the guide).
    static let rules: [String] = [
        L10n.t("每个视角都画完整的人，从头顶到脚底，不要裁切。", "Every view shows the whole figure, top of the head to the soles, uncropped."),
        L10n.t("所有视角同样大小、脚底对齐在同一条线上（正交视图，不要透视）。", "All views at the same size, soles on one line (orthographic, no perspective)."),
        L10n.t("A 字或 T 字站姿：手臂离开身体，腋下和身体两侧才能分开上色。", "A- or T-pose: arms away from the body, so the underarms and sides can be painted apart."),
        L10n.t("纯色背景、平光，不要投影和强烈明暗（光影会被当成颜色贴上去）。", "Plain background and flat light, no cast shadows or strong shading (shading is taken as colour)."),
        L10n.t("人物至少 800 像素高；300 像素以下贴图会明显发糊。", "The figure at least 800 pixels tall; under 300 the texture is visibly blurry."),
        L10n.t("可选：细节特写（脸、饰品、武器）和材质标注（布、皮革、金属），用于后续精修。", "Optional: close-ups (face, accessories, weapons) and material notes (cloth, leather, metal) for later refinement."),
    ]

    static let minimumFigurePixels: Float = 300
    static let recommendedFigurePixels: Float = 800

    /// What the checks read from one measured view (BodyPhoto units: y up, height = 1).
    struct Measures: Equatable, Sendable {
        var top: Float
        var bottom: Float
        var tall: Float { top - bottom }
        /// Hips above the soles, as a share of the figure.
        var legShare: Float?
        /// Shoulder joint distance, as a share of the figure.
        var shoulderShare: Float?
        var feetSeen: Bool
        var face: Float
        /// nil: the wrists or shoulders were not seen.
        var armsApart: Bool?
        var cropped: Bool
    }

    static func measures(_ p: BodyPhoto) -> Measures? {
        let seen = PhotoJoint.allCases.compactMap { p.point($0) }
        let top = p.top ?? seen.map(\.y).max(), bottom = p.bottom ?? seen.map(\.y).min()
        guard let top, let bottom, top - bottom > 0.05 else { return nil }
        let tall = top - bottom
        let hips = p.mid(.leftHip, .rightHip), shoulders = p.mid(.leftShoulder, .rightShoulder)
        var shoulderShare: Float?
        if let l = p.point(.leftShoulder), let r = p.point(.rightShoulder) { shoulderShare = abs(l.x - r.x) / tall }
        var armsApart: Bool?
        if let shoulders, let hips, let share = shoulderShare {
            let centre = (shoulders.x + hips.x) / 2
            let wrists = [p.point(.leftWrist), p.point(.rightWrist)].compactMap { $0 }
            if !wrists.isEmpty {
                // Hanging arms reach about half a shoulder width out; an A-pose much further.
                let reach = share * tall / 2 + 0.08 * tall
                armsApart = wrists.contains { abs($0.x - centre) > reach }
            }
        }
        let face = max(p.points[.nose]?.confidence ?? 0, p.points[.leftEye]?.confidence ?? 0, p.points[.rightEye]?.confidence ?? 0)
        return Measures(top: top, bottom: bottom, legShare: hips.map { ($0.y - bottom) / tall }, shoulderShare: shoulderShare,
                        feetSeen: p.point(.leftAnkle) != nil || p.point(.rightAnkle) != nil, face: face, armsApart: armsApart,
                        cropped: !p.outline.isEmpty && (top > 0.985 || bottom < 0.015))
    }

    /// Checks a set of views (at most one per view; right counts as the side).
    static func check(_ inputs: [ConceptViewInput]) -> ConceptSheetReport {
        var byView: [PhotoView: ConceptViewInput] = [:]
        for input in inputs where [.front, .back, .left, .right].contains(input.view) {
            let v = normalized(input.view)
            if byView[v] == nil { byView[v] = input }
        }
        var issues: [ConceptIssue] = []
        func add(_ view: PhotoView?, _ code: String, _ level: ConceptIssue.Level, _ message: String) {
            issues.append(ConceptIssue(view: view, code: code, level: level, message: message))
        }
        var present: [PhotoView] = []
        let frontMeasures = byView[.front]?.photo.flatMap(measures)

        for view in [PhotoView.front, .back, side] {
            guard let input = byView[view] else {
                switch view {
                case .front: add(.front, "missing", .blocking, L10n.t("缺少正面图：正面是必需的。", "No front picture: the front is required."))
                case .back: add(.back, "missing", .warning, L10n.t("缺少背面：背面会用正面颜色模糊推测，头发和背后图案不会出现。可以让 AI 补全。", "No back: it will be a blur of the front's colours, without hair or back details. AI can propose one."))
                default: add(side, "missing", .tip, L10n.t("缺少侧面：360° 模型的厚度只能靠猜；底模角色不需要侧面。可以让 AI 补全来核对设计。", "No side: a 360° model has to guess its depth; base-body characters do not need it. AI can propose one to check the design."))
                }
                continue
            }
            switch input.origin {
            case .ai: add(view, "ai", .tip, L10n.t("这张是 AI 推测的：请确认发型、服装和背后图案和你的设定一致。", "This view is an AI guess: check that the hair, clothes and back details match your design."))
            case .estimate: add(view, "estimate", .tip, L10n.t("这张是底模估计的预览，不带来新信息。", "This is a preview estimated from the base body; it adds no information."))
            default: break
            }
            if input.plainBorder < 0.55 {
                add(view, "background", .warning, L10n.t("背景不够干净：杂乱背景会让人物轮廓认错。", "The background is busy: the figure's outline may be found wrongly."))
            }
            guard let photo = input.photo, let m = measures(photo) else {
                switch view {
                case .front: add(.front, "noPerson", .blocking, L10n.t("正面图里没有认出人物（肩和胯）。请换一张能看到整个人的图。", "No person (shoulders and hips) found in the front picture. Use one that shows the whole person."))
                case .back: add(.back, "noPerson", .warning, L10n.t("背面图里没有认出人物，生成时不会用它。", "No person found in the back picture; it will not be used."))
                default:
                    // Vision often misses a side-on body; the picture still counts.
                    add(side, "noPoints", .tip, L10n.t("侧面图里没认出关节点（侧身时很常见），只检查了背景。", "No joints found in the side picture (common side-on); only the background was checked."))
                    present.append(side)
                }
                continue
            }
            if view != side && (photo.mid(.leftShoulder, .rightShoulder) == nil || photo.mid(.leftHip, .rightHip) == nil) {
                if view == .front { add(.front, "noPerson", .blocking, L10n.t("正面图里没有同时认出肩和胯。请换一张能看到整个人的图。", "The shoulders and hips were not both found in the front picture. Use one that shows the whole person.")) }
                else { add(.back, "noPerson", .warning, L10n.t("背面图里没有同时认出肩和胯，生成时不会用它。", "The shoulders and hips were not both found in the back picture; it will not be used.")) }
                continue
            }
            present.append(view)
            let pixels = m.tall * Float(input.height)
            if pixels < minimumFigurePixels {
                add(view, "small", .warning, L10n.t("人物只有 \(Int(pixels)) 像素高，贴图会很糊；建议至少 \(Int(recommendedFigurePixels)) 像素。", "The figure is only \(Int(pixels)) pixels tall, so the texture will be blurry; at least \(Int(recommendedFigurePixels)) is recommended."))
            } else if pixels < recommendedFigurePixels {
                add(view, "smallish", .tip, L10n.t("人物 \(Int(pixels)) 像素高，可用；\(Int(recommendedFigurePixels)) 像素以上更清晰。", "The figure is \(Int(pixels)) pixels tall: usable; over \(Int(recommendedFigurePixels)) is sharper."))
            }
            if m.cropped { add(view, "cropped", .warning, L10n.t("人物碰到了图片边缘，可能被裁掉了一部分。", "The figure touches the picture's edge and may be cropped.")) }
            if !m.feetSeen && view != side { add(view, "feet", .warning, L10n.t("看不到脚：腿长和鞋子会用标准值。", "The feet are not visible: leg length and shoes use standard values.")) }
            switch view {
            case .front:
                if m.armsApart == false { add(.front, "armsDown", .warning, L10n.t("手臂贴着身体：腋下和身体两侧的贴图会混在一起。建议 A 字或 T 字站姿。", "The arms touch the body: the underarms and sides will share colours. An A- or T-pose is better.")) }
                if let s = m.shoulderShare, s < 0.12 { add(.front, "turned", .warning, L10n.t("正面图的肩膀很窄，人物可能侧着身。", "The shoulders look narrow; the figure may be turned.")) }
                if m.face < 0.3 { add(.front, "noFace", .tip, L10n.t("正面图里没认出脸。如果这是背面，请放到背面。", "No face found in the front picture. If it is the back, put it there.")) }
            case .back:
                if m.face > 0.5 { add(.back, "face", .warning, L10n.t("背面图里认出了脸，可能放成了正面图。", "A face was found in the back picture; it may be a front view.")) }
            default:
                if let s = m.shoulderShare, s > 0.14 { add(side, "notSide", .warning, L10n.t("这张看起来不是正侧面（两肩都很宽地露出来）。", "This does not look like a true side (both shoulders show wide).")) }
            }
            if view != .front, let f = frontMeasures, let a = f.legShare, let b = m.legShare, abs(a - b) > 0.07 {
                add(view, "proportions", .warning, L10n.t(String(format: "和正面的比例不一致：腿长占身高 %.0f%%，正面是 %.0f%%。", b * 100, a * 100),
                                                          String(format: "Proportions differ from the front: legs %.0f%% of the height, the front %.0f%%.", b * 100, a * 100)))
            }
        }

        let missing = [PhotoView.back, side].filter { !present.contains($0) }
        let grade: ConceptSheetReport.Grade
        if issues.contains(where: { $0.level == .blocking }) { grade = .notReady }
        else if present.contains(.back) && present.contains(side) { grade = .complete }
        else if present.contains(.back) { grade = .good }
        else { grade = .basic }
        issues.sort { ($0.level, order($0.view)) < ($1.level, order($1.view)) }
        return ConceptSheetReport(grade: grade, issues: issues, present: present, missing: missing)
    }

    private static func order(_ view: PhotoView?) -> Int { [PhotoView.front, .back, side].firstIndex { $0 == view } ?? 3 }

    /// Share of the border ring (3% of the shorter side) within a small
    /// distance of its median colour: 1 = one plain colour all round.
    static func plainBorder(_ image: RasterImage) -> Float {
        let w = image.width, h = image.height
        guard w > 4, h > 4, image.rgba.count >= w * h * 4 else { return 0 }
        let ring = max(1, min(w, h) * 3 / 100)
        var samples: [(Int, Int, Int)] = []
        let step = max(1, (w + h) / 400)
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) where x < ring || x >= w - ring || y < ring || y >= h - ring {
                let o = (y * w + x) * 4
                samples.append((Int(image.rgba[o]), Int(image.rgba[o + 1]), Int(image.rgba[o + 2])))
            }
        }
        guard !samples.isEmpty else { return 0 }
        let rs = samples.map { $0.0 }.sorted(), gs = samples.map { $0.1 }.sorted(), bs = samples.map { $0.2 }.sorted()
        let m = (rs[rs.count / 2], gs[gs.count / 2], bs[bs.count / 2])
        let close = samples.filter { abs($0.0 - m.0) + abs($0.1 - m.1) + abs($0.2 - m.2) < 48 }.count
        return Float(close) / Float(samples.count)
    }
}

// MARK: Missing views from a 3D model

/// Turns a 3D model (an AI model of the front picture, or the painted base
/// body) into the picture a missing view would show: orthographic-like
/// camera, no shading (so the colours can be painted back on), a plain
/// background, the figure upright and centred.
enum ConceptViewRender {
    static let background: [UInt8] = [244, 244, 246, 255]

    /// The model's turn that shows `view` when the model faces +z.
    /// The left side (+x, the character's left) faces the camera at −90°.
    static func yaw(_ view: PhotoView) -> Float? {
        switch view {
        case .front: return 0
        case .back: return Float.pi
        case .left: return -Float.pi / 2
        case .right: return Float.pi / 2
        case .top, .bottom: return nil
        }
    }

    static func render(_ mesh: GeneratedMesh, texture: RasterImage?, colors: [UInt8]? = nil, view: PhotoView, facing offset: Float = 0,
                       width: Int = 512, height: Int = 768, supersample: Int = 2) -> RasterImage? {
        guard let yaw = yaw(view), mesh.vertexCount > 0, mesh.triangleCount > 0 else { return nil }
        var framed = mesh
        framed.normalize(size: 1)
        if framed.normals.count != framed.positions.count { framed.computeNormals() }
        if framed.uvs.count != framed.vertexCount * 2 { framed.uvs = [Float](repeating: 0, count: framed.vertexCount * 2) }
        let camera = RasterCamera(yaw: yaw + offset, pitch: 0, fieldOfView: 18, margin: 1.12, lighting: false)
        return ModelRasterizer.render(framed, texture: texture, colors: colors, camera: camera, width: width, height: height,
                                      background: background, supersample: supersample)
    }

    /// The figure's box in a picture: pixels that differ from the border's colour.
    static func figureBox(_ image: RasterImage) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return nil }
        let corners = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)].map { (x, y) -> [Int] in
            let o = (y * w + x) * 4; return [Int(image.rgba[o]), Int(image.rgba[o + 1]), Int(image.rgba[o + 2])]
        }
        let bg = (0..<3).map { k in corners.map { $0[k] }.sorted()[1] }
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w {
            let o = (y * w + x) * 4
            let d = abs(Int(image.rgba[o]) - bg[0]) + abs(Int(image.rgba[o + 1]) - bg[1]) + abs(Int(image.rgba[o + 2]) - bg[2])
            if d > 60 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
        } }
        guard x1 > x0, y1 > y0 else { return nil }
        return (x0, y0, x1, y1)
    }

    /// A small colour thumbnail of the figure's box (for comparing views).
    static func thumbnail(_ image: RasterImage, width: Int = 16, height: Int = 24) -> [Float]? {
        guard let box = figureBox(image) else { return nil }
        var out: [Float] = []
        for j in 0..<height { for i in 0..<width {
            let x = box.x0 + (box.x1 - box.x0) * (2 * i + 1) / (2 * width)
            let y = box.y0 + (box.y1 - box.y0) * (2 * j + 1) / (2 * height)
            let o = (y * image.width + x) * 4
            out += [Float(image.rgba[o]), Float(image.rgba[o + 1]), Float(image.rgba[o + 2])]
        } }
        return out
    }

    /// Which way the model faces: of the four turns, the one whose front
    /// render looks most like the user's front picture. AI models do not
    /// always come out facing +z.
    static func facing(_ mesh: GeneratedMesh, texture: RasterImage?, colors: [UInt8]? = nil, front target: RasterImage) -> Float {
        guard let want = thumbnail(target) else { return 0 }
        var best: (Float, Float) = (0, .infinity)
        for offset in [Float(0), .pi / 2, .pi, -.pi / 2] {
            guard let image = render(mesh, texture: texture, colors: colors, view: .front, facing: offset, width: 96, height: 144, supersample: 1),
                  let got = thumbnail(image) else { continue }
            var d: Float = 0
            for k in got.indices { d += abs(got[k] - want[k]) }
            if d < best.1 { best = (offset, d) }
        }
        return best.0
    }
}
