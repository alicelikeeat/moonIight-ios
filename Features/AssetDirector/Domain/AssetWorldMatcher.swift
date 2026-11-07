import Foundation

// v1.87 AI Asset Director — choosing analysed assets for a World Director
// run. The matcher only reads records; it turns the suitable ones into the
// AssetDescriptors the existing planner and builder already understand,
// adds a role for each, and explains every choice and every skip. Without
// any records, the World Director works exactly as before.

/// What an asset does in a generated world.
enum AssetWorldRole: String, Codable, Sendable {
    /// A character model standing in the world.
    case character
    /// A building or prop model.
    case sceneModel
    /// A water / loop video or GIF on the fountain (Golden World town).
    case fountainMedia
    /// A video or GIF on a screen / billboard.
    case screen
    /// A picture on a gallery wall.
    case gallery
    /// Only shapes style and palette; never placed.
    case styleOnly
    /// Glass tint taken from a material picture.
    case material

    var title: String {
        switch self {
        case .character: L10n.t("角色", "Character")
        case .sceneModel: L10n.t("场景模型", "Scene model")
        case .fountainMedia: L10n.t("喷泉水面影像", "Fountain water footage")
        case .screen: L10n.t("影像屏", "Screen")
        case .gallery: L10n.t("画廊墙", "Gallery wall")
        case .styleOnly: L10n.t("只作风格参考", "Style reference only")
        case .material: L10n.t("玻璃材质色调", "Glass material tint")
        }
    }
    /// Roles that put the asset's own pixels or mesh into the world.
    var placed: Bool { self != .styleOnly && self != .material }
}

struct AssetUsageLine: Equatable, Sendable, Identifiable {
    var assetID: String
    var title: String
    var role: AssetWorldRole?
    var reason: String
    var id: String { assetID }
}

struct AssetWorldSelection: Equatable, Sendable {
    var descriptors: [AssetDescriptor]
    var usage: [AssetUsageLine]
    var skipped: [AssetUsageLine]
    /// Style pack nearest to the reference pictures (Golden World town).
    var suggestedStyle: ArtStyle?
    /// Accent colour taken from a glass / crystal material picture.
    var materialTint: String?
}

enum AssetWorldMatcher {
    /// Roles a record can take in a theme, best first.
    static func roles(for r: AssetIntelligenceRecord, theme: WorldTheme) -> [AssetWorldRole] {
        let cats = r.categories
        switch r.mediaType {
        case .model:
            return cats.contains(.character) ? [.character] : [.sceneModel]
        case .video, .gif:
            if cats.contains(.character) && r.mediaType == .gif { return [.gallery] }
            if theme == .crystalKingdom { return r.sceneContext.contains(.water) || cats.contains(.nature) || cats.contains(.effect) ? [.fountainMedia] : [] }
            return [.screen]
        case .image:
            if cats.contains(.material) { return [.material, .styleOnly] }
            if cats.contains(.building) || cats.contains(.reference) || cats.contains(.nature) { return [.styleOnly] }
            return theme == .crystalKingdom ? [.styleOnly] : [.gallery]
        case .audio:
            return []
        }
    }

    /// Why a record cannot be used, if it cannot.
    static func blocker(_ r: AssetIntelligenceRecord) -> String? {
        if r.status == .failed || r.status == .cancelled || r.status == .queued || r.status == .analysing { return L10n.t("还没有分析完成", "Not analysed yet") }
        if r.primaryCategory == nil { return L10n.t("分类待确认", "Category needs confirming") }
        if r.provenance.personalUse == .denied { return L10n.t("授权不允许在世界里使用", "The licence does not allow use in a world") }
        if r.provenance.origin == .internet && r.provenance.personalUse != .allowed { return L10n.t("网络素材缺少可用授权", "Online asset without a usable licence") }
        if let gpu = r.signals?.technical.gpuBytesEstimate, gpu > AssetRules.maxTextureBytes { return L10n.t("占用显存过大", "Needs too much GPU memory") }
        if let tri = r.signals?.technical.triangleCount, tri > AssetRules.maxPolygons { return L10n.t("面数过多（\(tri)）", "Too many triangles (\(tri))") }
        if r.mediaType == .model, r.signals?.technical.realityKitReady == false { return r.signals?.technical.realityKitNote ?? L10n.t("RealityKit 无法加载", "RealityKit cannot load it") }
        return nil
    }

    static func select(_ records: [AssetIntelligenceRecord], theme: WorldTheme, maxPlaced: Int = 12) -> AssetWorldSelection {
        var descriptors: [AssetDescriptor] = [], usage: [AssetUsageLine] = [], skipped: [AssetUsageLine] = []
        var fountain = false, placed = 0
        var references: [String] = [], tint: String?
        let ordered = records.sorted { ($0.confidence?.value ?? 0) == ($1.confidence?.value ?? 0) ? $0.assetID < $1.assetID : ($0.confidence?.value ?? 0) > ($1.confidence?.value ?? 0) }
        for r in ordered {
            if let why = blocker(r) { skipped.append(AssetUsageLine(assetID: r.assetID, title: r.title, role: nil, reason: why)); continue }
            guard var role = roles(for: r, theme: theme).first else {
                skipped.append(AssetUsageLine(assetID: r.assetID, title: r.title, role: nil, reason: L10n.t("这个主题里没有合适的位置", "No fitting place in this theme"))); continue
            }
            if role == .fountainMedia {
                if fountain { role = .styleOnly } else { fountain = true }
            }
            if role.placed {
                guard placed < maxPlaced else { skipped.append(AssetUsageLine(assetID: r.assetID, title: r.title, role: nil, reason: L10n.t("超过本次可摆放数量", "Over this run's placement limit"))); continue }
                placed += 1
            }
            if role == .styleOnly { references += r.dominantColors.prefix(2) }
            if role == .material, tint == nil { tint = r.dominantColors.first }
            if let d = descriptor(r, role: role) { descriptors.append(d) }
            usage.append(AssetUsageLine(assetID: r.assetID, title: r.title, role: role, reason: reason(r, role: role)))
        }
        let style = theme == .crystalKingdom ? ArtStyleMatcher.nearestPack(references + (tint.map { [$0] } ?? []))?.style : nil
        return AssetWorldSelection(descriptors: descriptors, usage: usage, skipped: skipped, suggestedStyle: style, materialTint: tint)
    }

    static func reason(_ r: AssetIntelligenceRecord, role: AssetWorldRole) -> String {
        switch role {
        case .character: L10n.t("角色模型：站在广场或街区", "Character model: stands in the plaza or a district")
        case .sceneModel: L10n.t("场景模型：放在街区空地", "Scene model: placed on a free lot")
        case .fountainMedia: L10n.t("有水或循环画面：播放在喷泉水面", "Water or loop footage: plays on the fountain water")
        case .screen: L10n.t("视频放上影像屏", "Video on a screen")
        case .gallery: L10n.t("图片放上画廊墙", "Picture on a gallery wall")
        case .styleOnly: L10n.t("参考图只参与配色和风格，不放进场景", "Reference only shapes colours and style; not placed")
        case .material: L10n.t("材质图的主色用于玻璃色调", "The material's main colour tints the glass")
        }
    }

    /// The existing World Director descriptor, with the analysis' colours,
    /// tags and role. Style-only assets keep `libraryID` nil, so the
    /// builder can never put their pixels into the world.
    static func descriptor(_ r: AssetIntelligenceRecord, role: AssetWorldRole) -> AssetDescriptor? {
        var library: String?
        switch r.storage {
        case .library(let id), .generatedModel(let id): library = id
        case .builtin, .directorFile: library = nil
        }
        if !role.placed { library = nil }
        if role.placed && library == nil { return nil }
        let source: AssetSourceType = r.provenance.origin
        var d = AssetDescriptor(assetID: r.assetID, sourceType: source, mediaType: r.mediaType, libraryID: library, contentHash: r.contentHash,
                                license: r.provenance.licenseName, attribution: r.provenance.author)
        d.dominantColors = r.dominantColors
        d.styleTags = r.styleTags
        d.semanticTags = r.allTagNames
        d.title = r.title
        if let t = r.signals?.technical {
            d.pixelWidth = t.pixelWidth ?? (r.mediaType == .model ? 1 : 0); d.pixelHeight = t.pixelHeight ?? (r.mediaType == .model ? 1 : 0)
            d.duration = t.duration; d.hasAlpha = (t.transparentShare ?? 0) > 0.2
            d.polygonCount = t.triangleCount; d.boundingBox = t.bounds
            d.textureMemoryEstimate = t.gpuBytesEstimate ?? 0
        }
        d.compatibleWorldTypes = WorldTheme.allCases
        d.assetRole = role
        return d
    }
}
