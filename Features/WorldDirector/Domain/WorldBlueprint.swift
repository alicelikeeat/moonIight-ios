import Foundation

// v1.81 World Director: the data that describes a planned world. A
// blueprint is pure, versioned, Codable data — no code, no entities. The
// builder turns it into ordinary SpatialWorld objects, so everything it
// makes can be walked, edited, saved and undone like hand-built content.

enum WorldTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case skyCity, memory, nature, futureCity, bossAdventure
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skyCity: L10n.t("玻璃天空城", "Glass Sky City")
        case .memory: L10n.t("梦境记忆世界", "Dream Memory World")
        case .nature: L10n.t("幻想自然世界", "Fantasy Nature")
        case .futureCity: L10n.t("未来玻璃都市", "Future Glass City")
        case .bossAdventure: L10n.t("Boss 冒险世界", "Boss Adventure")
        }
    }
    var summary: String {
        switch self {
        case .skyCity: L10n.t("漂浮岛屿、玻璃高塔、空中桥梁、云海与远山", "Floating islands, glass towers, sky bridges, cloud sea and far mountains")
        case .memory: L10n.t("把相册里的照片和视频做成画廊、影像墙和记忆小路", "Your photos and videos as galleries, video walls and a memory path")
        case .nature: L10n.t("山丘、森林、湖泊、溪流、遗迹和自然小径", "Hills, forests, lakes, streams, ruins and trails")
        case .futureCity: L10n.t("道路网、街区、玻璃高楼、广场和动态广告牌", "Road grid, blocks, glass towers, plazas and live billboards")
        case .bossAdventure: L10n.t("安全出生区、探索路线、战斗区、奖励和 Boss 场地", "Safe start, a route, fights, rewards and a Boss arena")
        }
    }
    var symbol: String {
        switch self {
        case .skyCity: "cloud.sun"; case .memory: "photo.on.rectangle.angled"; case .nature: "leaf"
        case .futureCity: "building.2"; case .bossAdventure: "flame"
        }
    }
}

enum WorldTimeOfDay: String, Codable, CaseIterable, Sendable {
    case day, dusk, night
    var title: String { switch self { case .day: L10n.t("白天", "Day"); case .dusk: L10n.t("黄昏", "Dusk"); case .night: L10n.t("夜晚", "Night") } }
}

/// What a regeneration may replace. Sky and light are the atmosphere.
enum WorldLayer: String, Codable, CaseIterable, Sendable {
    case terrain, roads, buildings, plants, decorations, creatures, media
    var title: String {
        switch self {
        case .terrain: L10n.t("地形", "Terrain"); case .roads: L10n.t("道路与桥", "Roads & Bridges"); case .buildings: L10n.t("建筑", "Buildings")
        case .plants: L10n.t("植被", "Plants"); case .decorations: L10n.t("装饰", "Decorations"); case .creatures: L10n.t("生物与宝箱", "Creatures & Chests")
        case .media: L10n.t("照片与视频", "Photos & Videos")
        }
    }
}

/// Device tier → how much the world may contain (set from the device;
/// thresholds to be tuned with on-device measurements).
enum WorldPerformanceTier: String, Codable, CaseIterable, Sendable {
    case low, standard, high
    var budget: PerformanceBudget {
        switch self {
        case .low: PerformanceBudget(tier: self, maxBlocks: 1800, maxPlants: 700, maxCreatures: 40, maxVideos: 2, maxMediaWalls: 6)
        case .standard: PerformanceBudget(tier: self, maxBlocks: 3200, maxPlants: 1300, maxCreatures: 70, maxVideos: 4, maxMediaWalls: 10)
        case .high: PerformanceBudget(tier: self, maxBlocks: 5000, maxPlants: 2000, maxCreatures: 100, maxVideos: 6, maxMediaWalls: 14)
        }
    }
}

struct PerformanceBudget: Codable, Equatable, Sendable {
    var tier: WorldPerformanceTier
    var maxBlocks: Int
    var maxPlants: Int
    var maxCreatures: Int
    /// Video walls that may play at once (the renderer still pauses hidden ones).
    var maxVideos: Int
    var maxMediaWalls: Int
}

/// A map position: cell x, y (0..<256) and surface height.
struct WorldPoint: Codable, Equatable, Hashable, Sendable {
    var x: Int
    var y: Int
    var z: Double
    var vector: SpatialVector { SpatialVector(Double(x) + 0.5, Double(y) + 0.5, z) }
    func distance(_ other: WorldPoint) -> Double { hypot(Double(x - other.x), Double(y - other.y)) }
}

// MARK: Plan parts

enum TerrainKind: String, Codable, Sendable {
    /// Floating island: a walkable top at `height`, rock underneath.
    case island
    /// Hill from the ground up to `height` (gentle slopes).
    case hill
    /// Far scenery: a tall cone at the edge of the map.
    case mountain
    /// Shallow glass water.
    case lake
    /// Flat raised area with stepped edges.
    case plateau
    /// Low decorative cloud puffs.
    case cloud
}

struct TerrainFeature: Codable, Equatable, Sendable {
    var kind: TerrainKind
    var center: WorldPoint
    var radius: Int
    /// Top height (islands, hills, plateaus, mountains).
    var height: Double
    /// Rock depth under an island.
    var depth: Double = 4
}

struct TerrainPlan: Codable, Equatable, Sendable {
    var features: [TerrainFeature] = []
}

struct BiomeRegion: Codable, Equatable, Sendable, Identifiable {
    /// garden, forest, plaza, district, arena, gallery, ruins, safe, camp, reward
    var id: String
    var kind: String
    var center: WorldPoint
    var radius: Int
    var density: Double
}

struct RoadSegment: Codable, Equatable, Sendable {
    var from: WorldPoint
    var to: WorldPoint
    var width: Int
    /// "road" on the surface, "bridge" across a gap, "stream" (water ribbon).
    var kind: String
}

struct RoadNetwork: Codable, Equatable, Sendable {
    var segments: [RoadSegment] = []
}

enum LandmarkKind: String, Codable, Sendable {
    case crystalPalace, spire, ancientTree, megaTower, galleryHall, arena
    var title: String {
        switch self {
        case .crystalPalace: L10n.t("水晶宫殿", "Crystal Palace"); case .spire: L10n.t("玻璃尖塔", "Glass Spire")
        case .ancientTree: L10n.t("古树遗迹", "Ancient Tree Ruin"); case .megaTower: L10n.t("中央巨塔", "Central Tower")
        case .galleryHall: L10n.t("记忆大厅", "Memory Hall"); case .arena: L10n.t("Boss 场地", "Boss Arena")
        }
    }
}

struct LandmarkPlan: Codable, Equatable, Sendable {
    var kind: LandmarkKind
    var position: WorldPoint
    var scale: Double
}

struct BuildingZone: Codable, Equatable, Sendable {
    var regionID: String
    /// Structure names: BuildingKind raw values or "skyscraper", "pavilion", "billboard".
    var structures: [String]
    var count: Int
}

struct DecorationPlan: Codable, Equatable, Sendable {
    var plants: Int
    var flowersShare: Double
    var trees: Int
    var lamps: Int
    var crystals: Int
    var clouds: Int
}

struct MaterialPalette: Codable, Equatable, Sendable {
    var primary: String
    var secondary: String
    var accent: String
    /// Share of opaque (stone / metal) structure blocks: the supports.
    var opaqueShare: Double
    var glassDensity: Double
    var glow: Double
}

struct LightingProfile: Codable, Equatable, Sendable {
    var timeOfDay: WorldTimeOfDay
    var skyTop: String
    var skyHorizon: String
    var sunIntensity: Double
    var sunElevation: Double
    var glow: Double
}

/// Which slot an asset fills, and where.
struct AssetAssignment: Codable, Equatable, Sendable {
    var assetID: String
    /// galleryWall, billboard, landmarkScreen, portal, statue
    var slot: String
    var position: WorldPoint
    /// Wall direction: 0 along x, 1 along y.
    var axis: Int
}

struct SpawnPlan: Codable, Equatable, Sendable {
    var position: WorldPoint
    /// Degrees; the landmark is ahead.
    var facing: Double
}

struct ExplorationRoute: Codable, Equatable, Sendable {
    var name: String
    var waypoints: [WorldPoint]
}

struct GenerationMetadata: Codable, Equatable, Sendable {
    var generatorVersion: Int
    /// "local" or "claude"
    var planner: String
    var prompt: String
    var candidate: Int
    var notes: [String] = []
}

struct WorldBlueprint: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1
    var blueprintID: String
    var schemaVersion = WorldBlueprint.schemaVersion
    var seed: UInt64
    var theme: WorldTheme
    var palette: MaterialPalette
    var terrainPlan: TerrainPlan
    var biomeRegions: [BiomeRegion]
    var roadNetwork: RoadNetwork
    var landmarkPlan: LandmarkPlan
    var buildingZones: [BuildingZone]
    var decorationPlan: DecorationPlan
    var lightingProfile: LightingProfile
    var assetAssignments: [AssetAssignment]
    var spawnPlan: SpawnPlan
    var explorationRoutes: [ExplorationRoute]
    var performanceBudget: PerformanceBudget
    var generationMetadata: GenerationMetadata
    var id: String { blueprintID }

    /// Structural problems (empty when the blueprint can be built).
    func validate() -> [String] {
        var problems: [String] = []
        if schemaVersion > Self.schemaVersion { problems.append("newer schema \(schemaVersion)") }
        func inside(_ p: WorldPoint) -> Bool { (2..<254).contains(p.x) && (2..<254).contains(p.y) && p.z.isFinite && (-16...64).contains(p.z) }
        if !inside(spawnPlan.position) { problems.append("spawn outside the map") }
        if !inside(landmarkPlan.position) { problems.append("landmark outside the map") }
        for feature in terrainPlan.features where !(feature.center.x >= 0 && feature.center.x < 256 && feature.center.y >= 0 && feature.center.y < 256 && (1...60).contains(feature.radius) && feature.height.isFinite && (0...60).contains(feature.height)) {
            problems.append("bad terrain feature"); break
        }
        for segment in roadNetwork.segments where !(inside(segment.from) && inside(segment.to) && (1...5).contains(segment.width)) { problems.append("bad road"); break }
        if Set(biomeRegions.map(\.id)).count != biomeRegions.count { problems.append("duplicate region") }
        let regionIDs = Set(biomeRegions.map(\.id))
        for zone in buildingZones where !regionIDs.contains(zone.regionID) || !(0...60).contains(zone.count) { problems.append("bad building zone"); break }
        for hex in [palette.primary, palette.secondary, palette.accent, lightingProfile.skyTop, lightingProfile.skyHorizon] where !(hex.count == 6 && hex.allSatisfy(\.isHexDigit)) {
            problems.append("bad colour \(hex)"); break
        }
        if !(0...1).contains(palette.opaqueShare) || !(0.1...0.9).contains(palette.glassDensity) { problems.append("bad palette") }
        if !(0...5).contains(lightingProfile.sunIntensity) || !(-10...90).contains(lightingProfile.sunElevation) { problems.append("bad lighting") }
        if terrainPlan.features.count > 80 || roadNetwork.segments.count > 80 || biomeRegions.count > 60 || assetAssignments.count > 60 || explorationRoutes.count > 8 {
            problems.append("too many parts")
        }
        return problems
    }
}

// MARK: Request

struct WorldGenerationRequest: Codable, Equatable, Sendable {
    var theme: WorldTheme
    var prompt = ""
    var seed: UInt64 = 20_261_105
    /// nil: the theme's default.
    var timeOfDay: WorldTimeOfDay?
    var density = ContentDensity.medium
    var difficulty = GameDifficulty.normal
    var tier = WorldPerformanceTier.standard
    var assets: [AssetDescriptor] = []
}

// MARK: Saved with the world

/// The chosen blueprint, saved with the world (optional field), so local
/// regeneration knows the plan and a reload shows what was generated.
struct WorldDirectorRecord: Codable, Equatable, Sendable {
    var blueprint: WorldBlueprint
    var intentSummary: String
}

/// Sky and light for the 3D world (optional field; nil keeps the
/// built-in sky).
struct SpatialAtmosphere: Codable, Equatable, Sendable {
    var skyTop: String
    var skyHorizon: String
    var sunIntensity: Double
    var sunElevation: Double
    var glow: Double
    var timeOfDay: WorldTimeOfDay
    var valid: Bool {
        [skyTop, skyHorizon].allSatisfy { $0.count == 6 && $0.allSatisfy(\.isHexDigit) } && (0...5).contains(sunIntensity) && (-10...90).contains(sunElevation) && (0...2).contains(glow)
    }
    init(_ lighting: LightingProfile) {
        skyTop = lighting.skyTop; skyHorizon = lighting.skyHorizon; sunIntensity = lighting.sunIntensity
        sunElevation = lighting.sunElevation; glow = lighting.glow; timeOfDay = lighting.timeOfDay
    }
}

/// Non-glass surfaces for structure (optional field on SpatialGlass).
enum SpatialSurface: String, Codable, CaseIterable, Sendable {
    case glass, stone, metal, crystal
}
