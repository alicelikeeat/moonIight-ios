import Foundation

// v1.81 World Director: one description for every asset a world can use —
// album photos and videos, files, the Moonlight library, built-in assets,
// online assets and AI-made models — and the checks that decide whether
// it may be used. Analysis of pixels is pure; reading files happens off
// the main thread in the app layer.

enum AssetSourceType: String, Codable, CaseIterable, Sendable {
    case photos, files, library, builtin, internet, aiGenerated, generatedModel
    /// Content the user brought or made: no licence needed.
    var userOwned: Bool { self == .photos || self == .files || self == .library || self == .aiGenerated || self == .generatedModel }
}

enum AssetMediaType: String, Codable, CaseIterable, Sendable {
    case image, video, gif, model, audio
}

struct AssetDescriptor: Codable, Equatable, Sendable, Identifiable {
    var assetID: String
    var sourceType: AssetSourceType
    var mediaType: AssetMediaType
    /// The Moonlight media library entry that holds the file (images,
    /// videos, GIFs) or the generated model id (models).
    var libraryID: String?
    var localURL: String?
    var contentHash: String
    var license: String?
    var attribution: String?
    var dominantColors: [String] = []
    var styleTags: [String] = []
    var semanticTags: [String] = []
    /// Model bounds in metres (x, y, z), when known.
    var boundingBox: [Double]?
    var polygonCount: Int?
    var textureMemoryEstimate: Int = 0
    var compatibleWorldTypes: [WorldTheme] = WorldTheme.allCases
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    var duration: Double?
    var hasAlpha = false
    var title = ""
    /// v1.87: what the Asset Director decided this asset does in a world
    /// (optional, so earlier records decode unchanged).
    var assetRole: AssetWorldRole? = nil
    var id: String { assetID }

    var aspect: Double { pixelHeight > 0 ? Double(pixelWidth) / Double(pixelHeight) : 1 }
}

/// Licences an online asset may carry and still be used.
enum AssetLicense {
    static let allowed = ["cc0", "cc-by", "cc by", "public domain", "pdm", "cc-by-sa", "cc by-sa"]
    static func usable(_ license: String?) -> Bool {
        guard let license = license?.lowercased(), !license.isEmpty else { return false }
        return allowed.contains { license.contains($0) } && !license.contains("nc") && !license.contains("nd")
    }
}

enum AssetUsability: Equatable, Sendable {
    case ok
    case skipped(String)
}

enum AssetRules {
    static let maxPolygons = 150_000
    static let maxTextureBytes = 64 * 1024 * 1024
    static let maxPixels = 8192

    /// Whether an asset may enter a world, and why not.
    static func check(_ asset: AssetDescriptor) -> AssetUsability {
        if asset.assetID.isEmpty || asset.contentHash.isEmpty { return .skipped(L10n.t("素材信息不完整", "Incomplete asset")) }
        if !asset.sourceType.userOwned && asset.sourceType != .builtin && !AssetLicense.usable(asset.license) {
            return .skipped(L10n.t("「\(asset.title)」没有可用的授权", "“\(asset.title)” has no usable licence"))
        }
        // Style-only and material-tint assets never put pixels in a world.
        if let role = asset.assetRole, !role.placed { return .ok }
        switch asset.mediaType {
        case .image, .gif, .video:
            if asset.libraryID == nil { return .skipped(L10n.t("「\(asset.title)」还没有导入素材库", "“\(asset.title)” is not in the library")) }
            if asset.pixelWidth <= 0 || asset.pixelHeight <= 0 { return .skipped(L10n.t("「\(asset.title)」无法读取（可能已损坏）", "“\(asset.title)” could not be read (damaged?)")) }
            if asset.pixelWidth > maxPixels * 2 || asset.pixelHeight > maxPixels * 2 { return .skipped(L10n.t("「\(asset.title)」分辨率过大", "“\(asset.title)” is too large")) }
        case .model:
            if asset.libraryID == nil { return .skipped(L10n.t("「\(asset.title)」模型不可用", "“\(asset.title)” model unavailable")) }
            if let polygons = asset.polygonCount, polygons > maxPolygons { return .skipped(L10n.t("「\(asset.title)」面数过多（\(polygons)），已跳过", "“\(asset.title)” has too many triangles (\(polygons))")) }
        case .audio:
            return .skipped(L10n.t("音频暂时只保存，不放进世界", "Audio is kept but not placed in the world"))
        }
        if asset.textureMemoryEstimate > maxTextureBytes { return .skipped(L10n.t("「\(asset.title)」占用内存过大", "“\(asset.title)” needs too much memory")) }
        return .ok
    }

    /// Usable assets, and a note for each skipped one.
    static func partition(_ assets: [AssetDescriptor]) -> (usable: [AssetDescriptor], notes: [String]) {
        var usable: [AssetDescriptor] = [], notes: [String] = []
        var seen = Set<String>()
        for asset in assets {
            guard seen.insert(asset.contentHash.isEmpty ? asset.assetID : asset.contentHash).inserted else { continue }
            switch check(asset) {
            case .ok: usable.append(asset)
            case .skipped(let why): notes.append(why)
            }
        }
        return (usable, notes)
    }
}

/// Pixels → colours and tags (pure; works on a small RasterImage).
enum AssetAnalyzer {
    /// Up to three dominant colours (hex), most common first.
    static func dominantColors(_ image: RasterImage, count: Int = 3) -> [String] {
        guard image.width > 0, image.height > 0 else { return [] }
        // Coarse histogram on a 4-level-per-channel grid, then averages.
        var buckets: [Int: (n: Int, r: Int, g: Int, b: Int)] = [:]
        let step = max(1, max(image.width, image.height) / 64)
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: step) {
                let o = (y * image.width + x) * 4
                guard image.rgba[o + 3] > 32 else { continue }
                let r = Int(image.rgba[o]), g = Int(image.rgba[o + 1]), b = Int(image.rgba[o + 2])
                let key = (r >> 6) << 4 | (g >> 6) << 2 | (b >> 6)
                var bucket = buckets[key] ?? (0, 0, 0, 0)
                bucket.n += 1; bucket.r += r; bucket.g += g; bucket.b += b
                buckets[key] = bucket
            }
        }
        return buckets.values.sorted { $0.n > $1.n }.prefix(count).map { b in
            String(format: "%02X%02X%02X", b.r / b.n, b.g / b.n, b.b / b.n)
        }
    }

    static func hasAlpha(_ image: RasterImage) -> Bool {
        stride(from: 3, to: image.rgba.count, by: 4 * max(1, image.width / 32)).contains { image.rgba[$0] < 250 }
    }

    /// Style tags from colours and shape.
    static func styleTags(colors: [String], width: Int, height: Int) -> [String] {
        var tags: [String] = []
        let aspect = height > 0 ? Double(width) / Double(height) : 1
        tags.append(aspect > 1.25 ? "landscape" : aspect < 0.8 ? "portrait" : "square")
        if let first = colors.first, let rgb = rgb(first) {
            let brightness = (rgb.0 + rgb.1 + rgb.2) / 3
            tags.append(brightness > 0.7 ? "bright" : brightness < 0.3 ? "dark" : "mid")
            tags.append(rgb.0 > rgb.2 + 0.08 ? "warm" : rgb.2 > rgb.0 + 0.08 ? "cool" : "neutral")
        }
        return tags
    }

    static func rgb(_ hex: String) -> (Double, Double, Double)? {
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return (Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255)
    }

    /// Themes an asset suits.
    static func compatibleThemes(_ type: AssetMediaType) -> [WorldTheme] {
        switch type {
        case .video, .gif: [.memory, .futureCity, .skyCity]
        case .image: WorldTheme.allCases
        case .model: [.skyCity, .nature, .futureCity, .bossAdventure, .memory]
        case .audio: []
        }
    }

    /// A full descriptor for an image already in the library.
    static func describe(image: RasterImage?, id: String, source: AssetSourceType, type: AssetMediaType, libraryID: String?,
                         hash: String, title: String, width: Int, height: Int, duration: Double? = nil, license: String? = nil) -> AssetDescriptor {
        let colors = image.map { dominantColors($0) } ?? []
        var asset = AssetDescriptor(assetID: id, sourceType: source, mediaType: type, libraryID: libraryID, contentHash: hash, license: license)
        asset.dominantColors = colors
        asset.styleTags = styleTags(colors: colors, width: width, height: height)
        asset.semanticTags = type == .video ? ["motion"] : type == .gif ? ["motion", "loop"] : []
        asset.pixelWidth = width; asset.pixelHeight = height; asset.duration = duration
        asset.hasAlpha = image.map(hasAlpha) ?? false
        asset.textureMemoryEstimate = min(width, 2048) * min(height, 2048) * 4
        asset.compatibleWorldTypes = compatibleThemes(type)
        asset.title = title
        return asset
    }
}
