import Foundation

// v1.87 AI Asset Director — from measured signals to categories, uses,
// style and a confidence that says what kind of number it is. Pure: the
// analyzers in the app measure; this decides. File names are never used
// as evidence.

// MARK: Pixel statistics

/// Measured from a small RGBA thumbnail (typically ≤ 256 px).
struct AssetPixelStats: Codable, Equatable, Sendable {
    /// Share of fully or mostly transparent pixels.
    var transparentShare: Double
    /// Distinct colours (5 bits per channel) per opaque pixel — low for pixel art and flat illustration.
    var colourVariety: Double
    var meanSaturation: Double
    var meanBrightness: Double
    /// Share of opaque pixels with almost no saturation.
    var grayscaleShare: Double
    /// Mean colour difference between neighbouring pixels (0…1).
    var edgeEnergy: Double
    /// Share of neighbour steps that are either flat or a hard jump — high for pixel art and cel shading.
    var hardEdgeShare: Double
    /// How well opposite edges match (1 = seamless): textures tile.
    var tileability: Double
    /// Height / width of the opaque part's bounding box (cut-outs only).
    var opaqueAspect: Double? = nil

    static func measure(_ image: RasterImage) -> AssetPixelStats? {
        let w = image.width, h = image.height
        guard w >= 2, h >= 2, image.rgba.count >= w * h * 4 else { return nil }
        var transparent = 0, opaque = 0, gray = 0
        var minX = w, maxX = -1, minY = h, maxY = -1
        var saturation = 0.0, brightness = 0.0
        var colours = Set<Int>()
        for i in 0..<(w * h) {
            let o = i * 4
            let a = image.rgba[o + 3]
            if a < 128 { transparent += 1; continue }
            opaque += 1
            let px = i % w, py = i / w
            minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
            let r = Double(image.rgba[o]) / 255, g = Double(image.rgba[o + 1]) / 255, b = Double(image.rgba[o + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let s = mx > 0 ? (mx - mn) / mx : 0
            saturation += s; brightness += mx
            if s < 0.08 { gray += 1 }
            colours.insert(Int(image.rgba[o] >> 3) << 10 | Int(image.rgba[o + 1] >> 3) << 5 | Int(image.rgba[o + 2] >> 3))
        }
        func diff(_ p: Int, _ q: Int) -> Double {
            let a = p * 4, b = q * 4
            return (abs(Double(image.rgba[a]) - Double(image.rgba[b])) + abs(Double(image.rgba[a + 1]) - Double(image.rgba[b + 1])) +
                    abs(Double(image.rgba[a + 2]) - Double(image.rgba[b + 2]))) / (3 * 255)
        }
        var edges = 0.0, steps = 0, hard = 0
        for y in 0..<h { for x in 0..<(w - 1) {
            let p = y * w + x
            guard image.rgba[p * 4 + 3] >= 128, image.rgba[(p + 1) * 4 + 3] >= 128 else { continue }
            let d = diff(p, p + 1); edges += d; steps += 1
            if d < 0.02 || d > 0.25 { hard += 1 }
        } }
        var wrap = 0.0, wrapCount = 0
        for y in 0..<h { wrap += diff(y * w, y * w + w - 1); wrapCount += 1 }
        for x in 0..<w { wrap += diff(x, (h - 1) * w + x); wrapCount += 1 }
        // Compare the wrap seam with the image's own neighbour difference.
        let inner = steps > 0 ? edges / Double(steps) : 0
        let seam = wrapCount > 0 ? wrap / Double(wrapCount) : 1
        let tile = transparent * 2 > w * h ? 0 : max(0, min(1, 1 - max(0, seam - inner) * 4))
        let n = Double(max(1, opaque))
        return AssetPixelStats(transparentShare: Double(transparent) / Double(w * h),
                               colourVariety: Double(colours.count) / n,
                               meanSaturation: saturation / n, meanBrightness: brightness / n,
                               grayscaleShare: Double(gray) / n, edgeEnergy: inner,
                               hardEdgeShare: steps > 0 ? Double(hard) / Double(steps) : 0, tileability: tile,
                               opaqueAspect: transparent * 5 > w * h && maxX >= minX ? Double(maxY - minY + 1) / Double(maxX - minX + 1) : nil)
    }
}

// MARK: Vocabulary

/// Keywords matched against classifier label identifiers (lower-cased,
/// "_" as space). Matching words, not exact ids, keeps this working across
/// classifier versions; unmatched labels simply add nothing.
enum AssetVocabulary {
    static let categories: [AssetCategory: [String]] = [
        .character: ["people", "person", "adult", "child", "baby", "portrait", "selfie", "costume", "cartoon", "anime", "doll", "figurine", "puppet", "mascot", "comic", "toy"],
        .building: ["building", "castle", "house", "tower", "bridge", "church", "temple", "palace", "architecture", "structure", "skyscraper",
                    "cathedral", "monument", "fortress", "cottage", "barn", "lighthouse", "facade", "roof", "dome", "arch", "furniture", "chair", "table", "room", "interior"],
        .nature: ["tree", "forest", "plant", "flower", "grass", "sky", "cloud", "mountain", "hill", "rock", "sea", "ocean", "beach", "lake", "river",
                  "water", "waterfall", "sand", "snow", "desert", "field", "landscape", "sunset", "moon", "garden", "fountain", "coast", "shore", "leaf", "foliage", "aerial"],
        .material: ["texture", "pattern", "wood", "brick", "stone", "metal", "tile", "fabric", "marble", "concrete", "floor", "plank", "plywood",
                    "cobblestone", "pavement", "rust", "carpet", "glass", "surface", "laminate"],
        .effect: ["fire", "flame", "smoke", "sparkle", "fireworks", "explosion", "lightning", "magic", "laser", "glow", "neon", "light", "spark", "bokeh"],
        .prop: ["weapon", "sword", "knife", "shield", "chest", "treasure", "bottle", "tool", "coin", "key", "armor", "helmet", "jewelry", "crown", "potion", "lantern", "vase", "box"],
        .reference: ["drawing", "sketch", "illustration", "painting", "art", "screenshot", "document", "diagram", "poster", "map", "concept"],
    ]

    static let sounds: [AssetUse: [String]] = [
        .music: ["music", "singing", "guitar", "piano", "drum", "orchestra", "song", "instrument", "violin", "flute", "choir"],
        .ambience: ["rain", "wind", "water", "stream", "ocean", "bird", "insect", "crowd", "traffic", "thunder", "fire", "forest", "chatter", "hum", "rustle"],
        .soundEffect: ["footstep", "knock", "door", "bell", "gunshot", "explosion", "sword", "click", "whoosh", "slam", "crash", "glass", "punch", "clap", "beep", "chime"],
    ]

    static func words(_ label: String) -> [String] {
        label.lowercased().replacingOccurrences(of: "_", with: " ").split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Categories a label supports, by keyword (a word or its plural / prefix).
    static func categories(for label: String) -> [AssetCategory] {
        let ws = words(label)
        return AssetCategory.allCases.filter { cat in
            (categories[cat] ?? []).contains { key in ws.contains { $0 == key || $0 == key + "s" || $0 == key + "es" || ($0.hasPrefix(key) && key.count >= 5) } }
        }
    }

    static func soundUses(for label: String) -> [AssetUse] {
        let ws = words(label)
        return [AssetUse.music, .ambience, .soundEffect].filter { use in
            (sounds[use] ?? []).contains { key in ws.contains { $0 == key || $0 == key + "s" || $0.hasPrefix(key) } }
        }
    }

    static let scenes: [AssetSceneContext: [String]] = [
        .castle: ["castle", "palace", "fortress", "tower", "crown"], .homes: ["house", "cottage", "home", "roof"],
        .market: ["market", "shop", "stall", "food", "fruit"], .garden: ["flower", "garden", "plant", "grass"],
        .forest: ["forest", "tree", "foliage", "leaf"], .water: ["water", "fountain", "river", "lake", "sea", "ocean", "beach", "coast"],
        .mountain: ["mountain", "hill", "rock", "cliff"], .interior: ["room", "interior", "furniture", "table", "chair"],
        .sky: ["sky", "cloud", "moon", "sunset", "star"], .plaza: ["fountain", "statue", "plaza", "square", "monument"],
    ]
}

// MARK: Calibration

/// Thresholds that turn a score into automatic / candidates / review.
/// `fit` chooses them from labelled samples; until fitted, scores are
/// reported as `.modelScore`, not as accuracy.
struct AssetCalibration: Codable, Equatable, Sendable {
    var automatic: Double
    var candidates: Double
    /// True when the thresholds came from `fit` on labelled data.
    var fitted: Bool
    var sampleCount: Int

    static let starter = AssetCalibration(automatic: 0.62, candidates: 0.34, fitted: false, sampleCount: 0)

    func decision(_ top: Double) -> AssetDecision {
        top >= automatic ? .automatic : top >= candidates ? .candidates : .review
    }

    /// Picks the lowest automatic threshold whose top-1 precision on the
    /// samples above it is at least `precision`, and the candidates threshold
    /// where the right answer is still within the top three for `recall` of them.
    static func fit(_ samples: [(scores: [AssetScoredCategory], truth: AssetCategory)], precision: Double = 0.9, recall: Double = 0.95) -> AssetCalibration {
        let usable = samples.filter { !$0.scores.isEmpty }
        guard usable.count >= 8 else { return .starter }
        struct Top { var score: Double; var right: Bool; var inTop3: Bool }
        let tops: [Top] = usable.map { sample in
            Top(score: sample.scores[0].score, right: sample.scores[0].category == sample.truth,
                inTop3: sample.scores.prefix(3).contains { $0.category == sample.truth })
        }
        var automatic = 0.95
        for t in stride(from: 0.2, through: 0.95, by: 0.01) {
            let above = tops.filter { $0.score >= t }
            guard above.count >= 3 else { continue }
            if Double(above.filter(\.right).count) / Double(above.count) >= precision { automatic = t; break }
        }
        var candidates = min(automatic, 0.5)
        for t in stride(from: min(automatic, 0.6), through: 0.05, by: -0.01) {
            let above = tops.filter { $0.score >= t }
            guard !above.isEmpty else { continue }
            if Double(above.filter(\.inTop3).count) / Double(above.count) >= recall { candidates = t } else { break }
        }
        return AssetCalibration(automatic: automatic, candidates: min(candidates, automatic), fitted: true, sampleCount: usable.count)
    }
}

/// Top-1 / top-3 on a labelled set, with the counts the numbers come from.
struct AssetEvaluation: Codable, Equatable, Sendable {
    var samples: Int
    var top1: Double
    var top3: Double
    var perCategory: [String: Int]
    var confusions: [String]

    static func measure(_ results: [(name: String, scores: [AssetScoredCategory], truth: AssetCategory)]) -> AssetEvaluation {
        var hit1 = 0, hit3 = 0, per: [String: Int] = [:], confusions: [String] = []
        for r in results {
            per[r.truth.rawValue, default: 0] += 1
            if r.scores.first?.category == r.truth { hit1 += 1 } else {
                confusions.append("\(r.name): \(r.truth.rawValue) → \(r.scores.first?.category.rawValue ?? "none")")
            }
            if r.scores.prefix(3).contains(where: { $0.category == r.truth }) { hit3 += 1 }
        }
        let n = max(1, results.count)
        return AssetEvaluation(samples: results.count, top1: Double(hit1) / Double(n), top3: Double(hit3) / Double(n), perCategory: per, confusions: confusions)
    }
}

// MARK: Classifier

struct AssetClassification: Equatable, Sendable {
    var scores: [AssetScoredCategory]
    var decision: AssetDecision
    var primary: AssetCategory?
    var secondary: [AssetCategory]
    var uses: [AssetUse]
    var scenes: [AssetSceneContext]
    var styles: [String]
    var tags: [AssetTag]
    var evidence: [String]
    var confidence: AssetConfidence
}

enum AssetClassifier {
    static let id = "moonlight.asset-classifier"
    static let version = 1

    /// Signals → scored categories, uses, scenes, style and evidence.
    static func classify(_ s: AssetSignals, calibration: AssetCalibration = .starter) -> AssetClassification {
        var raw: [AssetCategory: Double] = [:]
        var evidence: [String] = []
        func add(_ c: AssetCategory, _ v: Double, _ why: String? = nil) {
            raw[c, default: 0] += v
            if let why { evidence.append(why) }
        }
        // Labels from Vision / SoundAnalysis / cloud, weighted by their score.
        let strong = s.labels.filter { $0.score >= 0.1 }.sorted { $0.score > $1.score }.prefix(24)
        for label in strong {
            for c in AssetVocabulary.categories(for: label.name) {
                add(c, label.score * (label.source == .cloud ? 1.2 : 1))
            }
        }
        if s.visionSkipped == true {
            evidence.append(L10n.t("此环境不能用 Vision 图像识别（模拟器只返回固定结果），只按像素、透明度、形状和尺寸判断", "Vision recognition is unavailable here (the simulator returns a fixed answer); judged by pixels, transparency, shape and size only"))
        }
        let topLabels = strong.prefix(4).map { "\($0.name) \(Int($0.score * 100))%" }
        if !topLabels.isEmpty { evidence.append(L10n.t("识别标签：", "Labels: ") + topLabels.joined(separator: "、")) }
        if s.peopleCount > 0 { add(.character, 0.5, L10n.t("检测到 \(s.peopleCount) 个人物", "\(s.peopleCount) people detected")) }

        let alpha = s.pixel?.transparentShare ?? s.technical.transparentShare ?? 0
        var uses: [AssetUse] = []
        switch s.mediaType {
        case .image:
            if let p = s.pixel {
                if alpha > 0.2 {
                    // A cut-out: sprite or standee, never a tiling texture. Without
                    // character labels its shape decides: upright figures are characters.
                    if (raw[.character] ?? 0) > 0.2 { add(.character, 0.6) }
                    else if let shape = p.opaqueAspect, shape >= 1.15 {
                        add(.character, 0.5, L10n.t("透明背景里的直立轮廓（高宽比 \(String(format: "%.1f", shape))），像角色", "Upright outline on a transparent background (aspect \(String(format: "%.1f", shape))), like a character"))
                    } else { add(.prop, 0.3) }
                    add(.prop, 0.1)
                    evidence.append(L10n.t("透明背景 \(Int(alpha * 100))%：适合精灵 / 立牌", "Transparent background \(Int(alpha * 100))%: fits a sprite / standee"))
                    uses.append(.sprite)
                } else if p.tileability > 0.7 && p.edgeEnergy > 0.005 {
                    add(.material, 0.7, L10n.t("边缘可无缝拼接（\(Int(p.tileability * 100))%）：适合贴图", "Edges tile (\(Int(p.tileability * 100))%): fits a texture"))
                    uses.append(.texture); uses.append(.materialConfig)
                } else {
                    add(.reference, 0.25)
                    uses.append(.styleReference)
                }
                if let w = s.technical.pixelWidth, let h = s.technical.pixelHeight, w == h, w >= 64, w & (w - 1) == 0, alpha < 0.05 {
                    add(.material, 0.2, L10n.t("\(w)×\(h) 方形二次幂尺寸，常见于贴图", "\(w)×\(h) square power of two, typical of textures"))
                }
            }
            uses.append(.palette)
        case .gif:
            let motion = s.motionEnergy ?? 0
            if alpha > 0.2 && ((raw[.character] ?? 0) + Double(s.peopleCount) > 0.15 || (s.pixel?.opaqueAspect ?? 0) >= 1.15) {
                add(.character, 0.9, L10n.t("透明背景的循环动画，像角色精灵", "Looping animation on a transparent background, like a character sprite"))
                uses.append(.sprite)
            } else if alpha > 0.2 {
                add(.effect, 0.5, L10n.t("透明背景的动画，可作特效", "Animation on a transparent background, usable as an effect"))
                add(.character, 0.3)
                uses.append(.effectLoop)
            } else if motion > 0.12 && (s.pixel?.meanBrightness ?? 0) > 0.55 {
                add(.effect, 0.45, L10n.t("明亮且运动强烈：可能是特效", "Bright and moving strongly: possibly an effect"))
                uses.append(.effectLoop)
            } else {
                add(.reference, 0.2)
                uses.append(.dynamicTexture)
            }
            if (s.loopSimilarity ?? 0) > 0.85 { evidence.append(L10n.t("首尾帧接近，可无缝循环", "First and last frames match: loops cleanly")) }
            add(.effect, 0.15)
        case .video:
            uses.append(.mediaScreen); uses.append(.storyMedia)
            if (s.motionEnergy ?? 0) > 0.03 { uses.append(.dynamicTexture) }
            let poses = s.motionSegments.filter { $0.label == "person" }
            if !poses.isEmpty {
                uses.append(.motionReference)
                evidence.append(L10n.t("\(poses.count) 段画面里有可见人体动作（只能作动作参考，不是骨骼动画数据）",
                                       "Visible body motion in \(poses.count) segments (motion reference only, not skeletal animation data)"))
            }
        case .model:
            let tri = s.technical.triangleCount ?? 0
            if s.technical.hasSkeleton == true && s.humanoidShape == true {
                add(.character, 1.0, L10n.t("有骨骼且身形像人", "Rigged and human-shaped"))
            } else if s.technical.hasSkeleton == true {
                add(.character, 0.45, L10n.t("有骨骼，但身形不像人：请确认是不是角色", "Rigged but not human-shaped: confirm whether it is a character"))
                add(.prop, 0.25)
            } else if s.humanoidShape == true {
                add(.character, 0.5, L10n.t("身形像人但没有骨骼：可用自动骨骼", "Human-shaped without a skeleton: auto-rig can add one"))
            }
            if let b = s.technical.bounds, b.count == 3 {
                let tall = b[1], footprint = max(b[0], b[2])
                if footprint > 0 && tall / footprint < 1.6 && tri > 400 && s.technical.hasSkeleton != true && s.humanoidShape != true {
                    add(.building, 0.35, L10n.t("底面宽、无骨骼：可能是建筑或家具", "Wide base, no skeleton: possibly a building or furniture"))
                }
            }
            add(.prop, 0.2)
            uses.append((raw[.character] ?? 0) >= 0.5 ? .characterModel : .worldModel)
        case .audio:
            add(.audio, 1.0, L10n.t("音频文件", "Audio file"))
            var counts: [AssetUse: Double] = [:]
            for label in strong where label.source == .sound || label.source == .cloud {
                for use in AssetVocabulary.soundUses(for: label.name) { counts[use, default: 0] += label.score }
            }
            uses += counts.sorted { $0.value > $1.value }.map(\.key)
            if counts.isEmpty { evidence.append(L10n.t("没有可用的声音分类结果：只记录了时长和音量，用途需要你选择", "No sound classification available: only length and level were measured; choose the use yourself")) }
        }

        // Scores → shares; nothing scored means review.
        let total = raw.values.reduce(0, +)
        var scores = raw.filter { $0.value > 0 }.map { AssetScoredCategory(category: $0.key, score: total > 0 ? $0.value / max(total, 1.0) : 0) }
        scores.sort { $0.score == $1.score ? $0.category.rawValue < $1.category.rawValue : $0.score > $1.score }
        let top = scores.first?.score ?? 0
        let decision = s.parseError != nil ? .review : calibration.decision(top)
        let primary: AssetCategory? = decision == .review ? nil : scores.first?.category
        let secondary = scores.dropFirst().filter { $0.score >= max(0.15, top * 0.35) }.map(\.category)

        var scenes: [AssetSceneContext] = []
        for (scene, keys) in AssetVocabulary.scenes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if strong.contains(where: { l in AssetVocabulary.words(l.name).contains { w in keys.contains { w == $0 || w == $0 + "s" } } }) { scenes.append(scene) }
        }
        if scenes.isEmpty { scenes = [.anywhere] }
        if decision == .review { evidence.append(L10n.t("把握不够：请确认分类", "Not confident enough: please confirm the category")) }

        let tags = Array(strong.prefix(12))
        var seen = Set<AssetUse>()
        let uniqueUses = uses.filter { seen.insert($0).inserted }
        return AssetClassification(scores: scores, decision: decision, primary: primary, secondary: secondary, uses: uniqueUses, scenes: scenes,
                                   styles: ArtStyleMatcher.styles(s), tags: Array(tags), evidence: evidence,
                                   confidence: AssetConfidence(value: min(1, max(0, top)), kind: calibration.fitted ? .calibrated : .modelScore))
    }

    /// Applies a classification to a record, keeping everything the user locked or corrected.
    static func apply(_ c: AssetClassification, to record: inout AssetIntelligenceRecord, signals: AssetSignals, analysis: AssetAnalysisInfo, now: Date) {
        if !record.locks.contains(.category) {
            record.primaryCategory = c.primary
            record.secondaryCategories = c.secondary
            record.decision = c.decision
            record.confidence = c.confidence
        }
        record.candidates = c.scores
        if !record.locks.contains(.tags) { record.semanticTags = c.tags }
        if !record.locks.contains(.style) { record.styleTags = c.styles }
        if !record.locks.contains(.uses) { record.recommendedUses = c.uses }
        record.sceneContext = c.scenes
        record.dominantColors = signals.dominantColors
        record.evidence = c.evidence
        record.signals = signals
        record.analysis = analysis
        record.status = record.locks.contains(.category) ? .ready : c.decision == .review ? .needsReview : .ready
        record.updatedAt = now
    }
}

// MARK: Art style

/// Game art style from pixels and labels, and the closest Moonlight style pack.
enum ArtStyleMatcher {
    static func styles(_ s: AssetSignals) -> [String] {
        guard s.mediaType == .image || s.mediaType == .gif || s.mediaType == .video, let p = s.pixel else { return [] }
        var tags: [String] = []
        let labels = s.labels.filter { $0.score >= 0.15 }.flatMap { AssetVocabulary.words($0.name) }
        if p.colourVariety < 0.06 && p.hardEdgeShare > 0.85 { tags.append("pixel") }
        if labels.contains(where: { ["cartoon", "anime", "comic", "illustration"].contains($0) }) || (p.colourVariety < 0.12 && p.hardEdgeShare > 0.7 && p.meanSaturation > 0.3) {
            tags.append("cartoon")
        }
        if p.grayscaleShare > 0.85 && p.meanBrightness > 0.6 { tags.append("ink") }
        if labels.contains("painting") || (p.meanSaturation > 0.45 && p.edgeEnergy > 0.06 && p.colourVariety > 0.3) { tags.append("painterly") }
        if tags.isEmpty && p.colourVariety > 0.25 { tags.append("realistic") }
        tags.append(p.meanBrightness > 0.65 ? "bright" : p.meanBrightness < 0.35 ? "dark" : "mid")
        if let first = s.dominantColors.first, let rgb = AssetAnalyzer.rgb(first) {
            tags.append(rgb.0 > rgb.2 + 0.08 ? "warm" : rgb.2 > rgb.0 + 0.08 ? "cool" : "neutral")
        }
        return tags
    }

    /// The Moonlight style pack whose palette is nearest to these colours.
    static func nearestPack(_ colors: [String]) -> (style: ArtStyle, distance: Double)? {
        let rgbs = colors.compactMap(AssetAnalyzer.rgb)
        guard !rgbs.isEmpty else { return nil }
        func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            let r = a.0 - b.0, g = a.1 - b.1, bl = a.2 - b.2
            return (r * r + g * g + bl * bl).squareRoot()
        }
        var best: (style: ArtStyle, distance: Double)?
        for style in ArtStyle.allCases {
            let palette = style.pack.palette.compactMap(AssetAnalyzer.rgb)
            var total = 0.0
            for c in rgbs { total += palette.map { distance(c, $0) }.min() ?? 1 }
            let mean = total / Double(rgbs.count)
            if best == nil || mean < best!.distance { best = (style, mean) }
        }
        return best
    }

    /// Groups of assets whose style vectors are close (for building a style pack).
    static func groups(_ records: [AssetIntelligenceRecord], threshold: Double = 0.12) -> [[String]] {
        let items = records.compactMap { r -> (String, [Double])? in
            guard let p = r.signals?.pixel else { return nil }
            return (r.assetID, [p.colourVariety, p.meanSaturation, p.meanBrightness, p.grayscaleShare, p.hardEdgeShare])
        }
        var groups: [[String]] = []
        var used = Set<String>()
        for (id, v) in items where !used.contains(id) {
            var group = [id]; used.insert(id)
            for (other, w) in items where !used.contains(other) {
                var squares: Double = 0
                for (a, b) in zip(v, w) { let e: Double = a - b; squares += e * e }
                let d = (squares / Double(v.count)).squareRoot()
                if d <= threshold { group.append(other); used.insert(other) }
            }
            if group.count >= 2 { groups.append(group) }
        }
        return groups
    }
}
