import Foundation

// v1.87 AI Asset Director — the data model. One record per asset (by
// content), kept in its own versioned store next to the media library, not
// inside the world save. World objects keep pointing at stable asset /
// library ids; the record only adds what analysis learned about them.
// Pure Foundation: tested by the domain tests.

/// Main game-asset categories. An asset has one primary and any number of
/// secondary categories; files are never copied per category.
enum AssetCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case character, building, nature, material, effect, prop, reference, audio
    var id: String { rawValue }
    var title: String {
        switch self {
        case .character: L10n.t("角色", "Characters")
        case .building: L10n.t("建筑", "Buildings")
        case .nature: L10n.t("自然环境", "Nature")
        case .material: L10n.t("材质", "Materials")
        case .effect: L10n.t("动画与特效", "Animation & Effects")
        case .prop: L10n.t("游戏道具", "Props")
        case .reference: L10n.t("参考素材", "References")
        case .audio: L10n.t("音频", "Audio")
        }
    }
    var symbol: String {
        switch self {
        case .character: "person.fill"
        case .building: "building.columns.fill"
        case .nature: "leaf.fill"
        case .material: "square.grid.3x3.fill"
        case .effect: "sparkles"
        case .prop: "shield.lefthalf.filled"
        case .reference: "photo.artframe"
        case .audio: "waveform"
        }
    }
}

/// What an asset can be used for in a world.
enum AssetUse: String, Codable, CaseIterable, Sendable {
    case sprite, characterModel, worldModel, texture, materialConfig, styleReference, palette
    case mediaScreen, dynamicTexture, effectLoop, storyMedia, motionReference
    case music, ambience, soundEffect
    var title: String {
        switch self {
        case .sprite: L10n.t("精灵 / 立牌", "Sprite / standee")
        case .characterModel: L10n.t("角色模型", "Character model")
        case .worldModel: L10n.t("场景模型", "Scene model")
        case .texture: L10n.t("贴图", "Texture")
        case .materialConfig: L10n.t("材质配置", "Material setup")
        case .styleReference: L10n.t("风格参考", "Style reference")
        case .palette: L10n.t("配色参考", "Palette")
        case .mediaScreen: L10n.t("影像屏", "Media screen")
        case .dynamicTexture: L10n.t("动态贴图", "Moving texture")
        case .effectLoop: L10n.t("特效循环", "Effect loop")
        case .storyMedia: L10n.t("剧情媒体", "Story media")
        case .motionReference: L10n.t("动作参考", "Motion reference")
        case .music: L10n.t("音乐", "Music")
        case .ambience: L10n.t("环境音", "Ambience")
        case .soundEffect: L10n.t("动作音效", "Sound effect")
        }
    }
}

/// Where in a map an asset fits.
enum AssetSceneContext: String, Codable, CaseIterable, Sendable {
    case plaza, castle, homes, market, garden, forest, water, mountain, interior, sky, anywhere
}

enum AssetTagSource: String, Codable, Sendable {
    /// Apple Vision's built-in image classifier.
    case vision
    /// Apple SoundAnalysis' built-in classifier.
    case sound
    /// Body pose detection on video frames.
    case pose
    /// Measured from pixels, frames, mesh or audio samples.
    case measured
    /// Optional cloud vision (only with explicit consent).
    case cloud
    case user
}

struct AssetTag: Codable, Equatable, Hashable, Sendable {
    var name: String
    /// The source's own score (0…1); not a probability unless calibrated.
    var score: Double
    var source: AssetTagSource
}

/// A confidence value and what kind of number it is. Raw model scores are
/// never presented as accuracy.
struct AssetConfidence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Mapped through thresholds fitted on a labelled set (see `AssetCalibration`).
        case calibrated
        /// A model's own score, uncalibrated.
        case modelScore
        /// From a deterministic measurement (e.g. a skeleton is present).
        case measured
        /// Set or confirmed by the user.
        case user
    }
    var value: Double
    var kind: Kind
}

enum AssetPermission: String, Codable, Sendable {
    case allowed, denied, unknown
    var title: String {
        switch self {
        case .allowed: L10n.t("允许", "Allowed")
        case .denied: L10n.t("不允许", "Not allowed")
        case .unknown: L10n.t("未知", "Unknown")
        }
    }
}

/// Source, author and licence. Commercial and modification rights are
/// separate from whether the file loads, and default to unknown.
struct AssetProvenance: Codable, Equatable, Sendable {
    var origin: AssetSourceType
    var author: String?
    var licenseName: String?
    /// Where the licence is stated (a URL or the bundled licence file).
    var licenseProof: String?
    var commercialUse: AssetPermission = .unknown
    var modification: AssetPermission = .unknown
    /// May the user use it in their own Moonlight worlds (personal use)?
    var personalUse: AssetPermission = .unknown

    /// Starting point for a new asset. The user's own photos and files may
    /// be used in their own worlds, but nothing about commercial rights is
    /// known; only a recorded open licence (CC0 / CC-BY / public domain)
    /// allows more. Online assets without one may not be used at all.
    static func initial(origin: AssetSourceType, license: String?, author: String?, proof: String?) -> AssetProvenance {
        var p = AssetProvenance(origin: origin, author: author, licenseName: license, licenseProof: proof)
        let open = AssetLicense.usable(license)
        if open {
            p.commercialUse = .allowed
            p.modification = (license ?? "").lowercased().contains("nd") ? .denied : .allowed
            p.personalUse = .allowed
        } else if origin.userOwned {
            p.personalUse = .allowed
        } else if origin == .internet {
            p.personalUse = license == nil ? .unknown : .denied
        }
        return p
    }
}

/// Facts measured from the file. Everything optional: only what was measured.
struct AssetTechnicalInfo: Codable, Equatable, Sendable {
    var fileBytes: Int = 0
    var uniformType: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    /// Share of transparent pixels (0…1).
    var transparentShare: Double?
    var duration: Double?
    var frameRate: Double?
    var frameCount: Int?
    /// Seconds of the frames that were analysed.
    var sampledTimes: [Double]?
    var loops: Bool?
    var vertexCount: Int?
    var triangleCount: Int?
    /// Bounds in the file's units (x, y, z).
    var bounds: [Double]?
    var hasSkeleton: Bool?
    var jointCount: Int?
    var hasSkin: Bool?
    var animationNames: [String]?
    var materialCount: Int?
    var textureCount: Int?
    var textureBytes: Int?
    var gpuBytesEstimate: Int?
    /// Can RealityKit show it (directly or after the app's own import)?
    var realityKitReady: Bool?
    var realityKitNote: String?
    var sampleRate: Double?
    var channels: Int?
    var peakDecibels: Double?
    var rmsDecibels: Double?
    var silenceShare: Double?

    var aspect: Double? {
        guard let w = pixelWidth, let h = pixelHeight, h > 0 else { return nil }
        return Double(w) / Double(h)
    }
}

/// A time span of a video where an action was seen.
struct AssetMotionSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var label: String
    var score: Double
}

/// What the analyzers measured, before any decision. Kept with the record
/// so a classifier change can re-decide without re-reading the file.
struct AssetSignals: Codable, Equatable, Sendable {
    var mediaType: AssetMediaType
    var technical = AssetTechnicalInfo()
    var labels: [AssetTag] = []
    var dominantColors: [String] = []
    var pixel: AssetPixelStats?
    /// People seen (count only; no face or body data is kept).
    var peopleCount = 0
    var motionEnergy: Double?
    var loopSimilarity: Double?
    var motionSegments: [AssetMotionSegment] = []
    /// Vision feature print (for similarity), when computed.
    var featurePrint: [Float]?
    /// Model: proportions and kind of mesh.
    var humanoidShape: Bool?
    var parseError: String?
    /// True when image recognition could not be used (the simulator gives a fixed answer).
    var visionSkipped: Bool? = nil
}

/// The analyzer that produced a record, for caching and re-analysis.
struct AssetAnalysisInfo: Codable, Equatable, Sendable {
    var analyzerID: String
    var analyzerVersion: Int
    var configurationVersion: Int
    var analyzedAt: Date
    var cloud: Bool
    var milliseconds: Int
}

enum AssetStatus: String, Codable, Sendable {
    case queued, analysing, needsReview, ready, failed, cancelled
    var title: String {
        switch self {
        case .queued: L10n.t("排队中", "Queued")
        case .analysing: L10n.t("分析中", "Analysing")
        case .needsReview: L10n.t("待确认", "Needs review")
        case .ready: L10n.t("已完成", "Done")
        case .failed: L10n.t("失败", "Failed")
        case .cancelled: L10n.t("已取消", "Cancelled")
        }
    }
}

/// How the classifier's decision should be used.
enum AssetDecision: String, Codable, Sendable {
    /// High confidence: categories applied.
    case automatic
    /// Middle: the top candidates are shown, the first applied tentatively.
    case candidates
    /// Low: nothing applied until the user chooses.
    case review
}

struct AssetScoredCategory: Codable, Equatable, Sendable {
    var category: AssetCategory
    var score: Double
}

/// Fields the user can lock; AI re-analysis never changes a locked field.
enum AssetLockField: String, Codable, CaseIterable, Sendable {
    case category, tags, style, uses, license
}

struct AssetCorrection: Codable, Equatable, Sendable {
    var field: AssetLockField
    var before: String
    var after: String
    var at: Date
}

struct AssetFailure: Codable, Equatable, Sendable {
    var stage: String
    var message: String
    var at: Date
}

/// Where the one stored copy of the file lives. Never a free-form path from
/// a model or a user: always one of the app's own stores.
enum AssetStorageReference: Codable, Equatable, Hashable, Sendable {
    /// Moonlight media library entry (images, videos, GIFs).
    case library(String)
    /// Generated / imported 3D model in `Generated3DStore`.
    case generatedModel(String)
    /// Built-in starter pack file name.
    case builtin(String)
    /// The Asset Director's own import folder (audio, unsupported-by-library files): a file name only.
    case directorFile(String)

    var key: String {
        switch self {
        case .library(let id): "library:" + id
        case .generatedModel(let id): "model:" + id
        case .builtin(let name): "builtin:" + name
        case .directorFile(let name): "file:" + name
        }
    }
}

struct AssetIntelligenceRecord: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1

    var schemaVersion = Self.schemaVersion
    var assetID: String
    var contentHash: String
    var mediaType: AssetMediaType
    var storage: AssetStorageReference
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var status: AssetStatus = .queued

    var primaryCategory: AssetCategory?
    var secondaryCategories: [AssetCategory] = []
    var candidates: [AssetScoredCategory] = []
    var decision: AssetDecision = .review
    var semanticTags: [AssetTag] = []
    var styleTags: [String] = []
    var dominantColors: [String] = []
    var recommendedUses: [AssetUse] = []
    var sceneContext: [AssetSceneContext] = []
    /// Short human-readable reasons for the decision.
    var evidence: [String] = []
    var confidence: AssetConfidence?

    var signals: AssetSignals?
    var provenance: AssetProvenance
    var analysis: AssetAnalysisInfo?
    var failures: [AssetFailure] = []
    var corrections: [AssetCorrection] = []
    var locks: Set<AssetLockField> = []
    /// Tags the user added (kept across re-analysis).
    var userTags: [String] = []

    var id: String { assetID }
    var categories: [AssetCategory] { (primaryCategory.map { [$0] } ?? []) + secondaryCategories.filter { $0 != primaryCategory } }
    var allTagNames: [String] { semanticTags.map(\.name) + userTags }

    var valid: Bool {
        schemaVersion == Self.schemaVersion && !assetID.isEmpty && assetID.count <= 160 && !contentHash.isEmpty &&
            title.count <= 200 && semanticTags.count <= 64 && userTags.count <= 64 && styleTags.count <= 16 &&
            (confidence.map { $0.value.isFinite && (0...1).contains($0.value) } ?? true)
    }
}

/// Cache identity: the same content analysed by the same analyzer version
/// and configuration is never analysed again.
struct AssetCacheKey: Codable, Equatable, Hashable, Sendable {
    var contentHash: String
    var analyzerID: String
    var analyzerVersion: Int
    var configurationVersion: Int
    var string: String { "\(contentHash)|\(analyzerID)|\(analyzerVersion)|\(configurationVersion)" }
}
