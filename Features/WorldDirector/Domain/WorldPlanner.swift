import Foundation

// v1.81 World Director: from a request (theme, words, assets, seed) to a
// blueprint. Words become a structured intent (local keywords, or a
// validated AI answer); the intent and the theme rules then place the
// spawn, the landmark ahead of it, terrain, roads, zones and decoration
// with composition in mind (foreground / middle / far), never as a
// uniform scatter. Deterministic for the same request and variant.

/// What the words ask for, as data (the AI may fill it; it is clamped).
struct WorldIntent: Codable, Equatable, Sendable {
    var theme: WorldTheme
    var colors: [String] = []
    var landmark: LandmarkKind?
    var islands: Int?
    var gardens = false
    var bridges = false
    var water = false
    var mountains = false
    var forest = false
    var videoWall = false
    var crystals = false
    var timeOfDay: WorldTimeOfDay?
    /// 0.5 … 1.5: how big and how many buildings.
    var buildingScale = 1.0
    var summary = ""

    func clamped() -> WorldIntent {
        var c = self
        c.colors = colors.map { $0.uppercased().replacingOccurrences(of: "#", with: "") }.filter { $0.count == 6 && $0.allSatisfy(\.isHexDigit) }.prefix(3).map { $0 }
        c.islands = islands.map { min(4, max(2, $0)) }
        c.buildingScale = buildingScale.isFinite ? min(1.5, max(0.5, buildingScale)) : 1
        c.summary = String(summary.prefix(300))
        return c
    }
}

enum WorldIntentParser {
    private static let colorWords: [(words: [String], hex: String)] = [
        (["纯白", "白", "white", "pearl"], "F4F7FB"), (["银", "silver"], "C9D3E0"), (["金", "gold", "golden"], "F2C46D"),
        (["蓝", "blue", "azure"], "8FB8FF"), (["粉", "pink", "rose"], "FFB3D1"), (["紫", "purple", "violet"], "B9A6FF"),
        (["绿", "green", "emerald"], "8FD9A8"), (["红", "red", "crimson"], "FF7A7A"), (["橙", "orange"], "FFB27A"),
        (["黑", "暗", "dark", "black"], "30364A"),
    ]

    /// Local understanding of the prompt (offline, no AI).
    static func parse(_ prompt: String, theme: WorldTheme) -> WorldIntent {
        let t = prompt.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        var intent = WorldIntent(theme: theme)
        for entry in colorWords where entry.words.contains(where: { t.contains($0) }) { intent.colors.append(entry.hex) }
        if has("水晶", "crystal") { intent.crystals = true; intent.landmark = intent.landmark ?? .crystalPalace }
        if has("宫殿", "城堡", "palace", "castle", "王国", "kingdom") { intent.landmark = .crystalPalace }
        if has("尖塔", "spire") { intent.landmark = .spire }
        if has("巨塔", "摩天", "skyscraper", "tower") && theme == .futureCity { intent.landmark = .megaTower }
        if has("古树", "神树", "ancient tree", "great tree") { intent.landmark = .ancientTree }
        if has("画廊", "大厅", "gallery", "museum", "hall") { intent.landmark = .galleryHall }
        if has("花园", "花", "garden", "flower") { intent.gardens = true }
        if has("桥", "bridge") { intent.bridges = true }
        if has("湖", "河", "溪", "水", "瀑布", "lake", "river", "stream", "water", "waterfall", "海") { intent.water = true }
        if has("山", "mountain", "峰") { intent.mountains = true }
        if has("森林", "树", "forest", "wood", "jungle") { intent.forest = true }
        if has("视频", "影像", "屏幕", "广告", "video", "screen", "billboard") { intent.videoWall = true }
        if has("夜", "night", "星", "neon", "霓虹") { intent.timeOfDay = .night }
        else if has("黄昏", "日落", "夕阳", "dusk", "sunset") { intent.timeOfDay = .dusk }
        else if has("白天", "阳光", "day", "sunny") { intent.timeOfDay = .day }
        if has("岛", "island", "漂浮", "floating", "云海", "cloud") { intent.islands = 4 }
        if has("宏大", "巨大", "壮观", "grand", "huge", "giant", "massive") { intent.buildingScale = 1.35 }
        if has("小", "cozy", "安静", "quiet", "small") { intent.buildingScale = 0.75 }
        intent.summary = prompt.isEmpty ? theme.title : String(prompt.prefix(120))
        return intent.clamped()
    }
}

/// Theme rules: palette, lighting and building language.
enum WorldThemeStyle {
    static func palette(_ theme: WorldTheme, intent: WorldIntent, assets: [AssetDescriptor] = []) -> MaterialPalette {
        var p: MaterialPalette = switch theme {
        case .skyCity: MaterialPalette(primary: "F4F7FB", secondary: "C9CFD8", accent: "8FD3FF", opaqueShare: 0.35, glassDensity: 0.35, glow: 0.4)
        case .memory: MaterialPalette(primary: "FFE9F2", secondary: "D9CFE8", accent: "B9A6FF", opaqueShare: 0.3, glassDensity: 0.3, glow: 0.6)
        case .nature: MaterialPalette(primary: "BFE8D0", secondary: "8C8676", accent: "8FB8FF", opaqueShare: 0.55, glassDensity: 0.4, glow: 0.3)
        case .futureCity: MaterialPalette(primary: "9FD3FF", secondary: "5A6478", accent: "FF8FB1", opaqueShare: 0.4, glassDensity: 0.45, glow: 0.9)
        case .bossAdventure: MaterialPalette(primary: "C9C2B8", secondary: "4A4A55", accent: "FF7A5A", opaqueShare: 0.55, glassDensity: 0.5, glow: 0.5)
        case .crystalKingdom: MaterialPalette(primary: "F1EEE8", secondary: "8FB8E0", accent: "F7FBFF", opaqueShare: 0.6, glassDensity: 0.5, glow: 0.4)
        }
        // A town's colours come from its art style pack, not from loose colour words.
        if theme == .crystalKingdom { return p }
        // Memory worlds take their accent from the chosen photos' colours
        // (most common dominant colour), unless the words name colours.
        if theme == .memory, intent.colors.isEmpty {
            var counts: [String: Int] = [:]
            for asset in assets { if let c = asset.dominantColors.first { counts[c, default: 0] += 1 } }
            if let top = counts.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key { p.accent = top }
        }
        if let first = intent.colors.first { p.primary = first }
        if intent.colors.count > 1 { p.accent = intent.colors[1] }
        if intent.colors.count > 2 { p.secondary = intent.colors[2] }
        return p
    }

    static func defaultTime(_ theme: WorldTheme) -> WorldTimeOfDay {
        switch theme { case .skyCity, .nature, .crystalKingdom: .day; case .memory, .bossAdventure: .dusk; case .futureCity: .night }
    }

    static func lighting(_ theme: WorldTheme, time: WorldTimeOfDay) -> LightingProfile {
        switch time {
        case .day:
            let top = theme == .nature ? "4F8FD0" : "5B8FD9"
            return LightingProfile(timeOfDay: .day, skyTop: top, skyHorizon: "DCEBFA", sunIntensity: 1.0, sunElevation: 52, glow: 0.3)
        case .dusk:
            return LightingProfile(timeOfDay: .dusk, skyTop: theme == .bossAdventure ? "3A2440" : "3A3F78", skyHorizon: theme == .bossAdventure ? "E0754F" : "F2A57A",
                                   sunIntensity: 0.6, sunElevation: 12, glow: 0.8)
        case .night:
            return LightingProfile(timeOfDay: .night, skyTop: "0B1030", skyHorizon: theme == .futureCity ? "3B2A66" : "2A3466", sunIntensity: 0.18, sunElevation: -4, glow: 1.4)
        }
    }
}

enum WorldPlanner {
    static let version = 1
    static let center = 128

    /// One blueprint for a request; `variant` (0, 1, 2…) gives the
    /// candidate layouts different seeds and arrangements.
    static func plan(_ request: WorldGenerationRequest, intent rawIntent: WorldIntent? = nil, variant: Int = 0, planner: String = "local") -> WorldBlueprint {
        let intent = (rawIntent ?? WorldIntentParser.parse(request.prompt, theme: request.theme)).clamped()
        let seed = request.seed &+ UInt64(variant) &* 0x9E37_79B9_7F4A_7C15
        var random = SpatialRandom(seed: seed)
        let theme = request.theme
        let time = request.timeOfDay ?? intent.timeOfDay ?? WorldThemeStyle.defaultTime(theme)
        var budget = request.tier.budget
        if request.density == .low { budget.maxBlocks = budget.maxBlocks * 3 / 4 }
        let (usable, notes) = AssetRules.partition(request.assets.filter { $0.compatibleWorldTypes.contains(theme) })
        // Composition: the landmark sits ahead of the spawn, in the
        // middle distance; facing points at it.
        let heading = random.unit() * 2 * .pi
        var context = PlanContext(random: random, theme: theme, intent: intent, density: request.density.factor, heading: heading, budget: budget)
        switch theme {
        case .skyCity: context.skyCity()
        case .memory: context.memoryWorld(assets: usable.count)
        case .nature: context.natureWorld()
        case .futureCity: context.futureCity()
        case .bossAdventure: context.bossWorld()
        case .crystalKingdom: break
        }
        var town: GoldenTownIntent?
        var palette = WorldThemeStyle.palette(theme, intent: intent, assets: usable)
        if theme == .crystalKingdom {
            // Golden World: the town planner decides the layout; the blueprint records districts,
            // landmark, spawn and route for the evaluator and for local regeneration.
            var townIntent = GoldenTownIntent.parse(request.prompt)
            // v1.87 Asset Director: reference pictures choose the style pack
            // unless the words name one; a material picture tints the glass.
            let named = GoldenTownIntent.parse(request.prompt).style != .crystalFantasy || ["水晶", "crystal", "玻璃", "glass"].contains { request.prompt.lowercased().contains($0) }
            let references = usable.filter { $0.assetRole == .styleOnly }.flatMap { $0.dominantColors.prefix(2) }
            if !named, !references.isEmpty, let style = ArtStyleMatcher.nearestPack(references)?.style { townIntent.style = style }
            if let tint = usable.first(where: { $0.assetRole == .material })?.dominantColors.first { townIntent.glassTint = tint }
            if intent.forest { townIntent.forest = true }
            if intent.mountains { townIntent.mountains = true }
            let plan = GoldenCityPlanner.plan(seed: seed, intent: townIntent)
            context.regions = plan.districts.map { BiomeRegion(id: $0.key, kind: $0.kind, center: WorldPoint(x: $0.x, y: $0.y, z: $0.z), radius: $0.radius, density: 1) }
            context.features = plan.farMountains
            context.spawn = WorldPoint(x: Int(plan.spawn.x), y: Int(plan.spawn.y), z: 0)
            let castle = WorldPoint(x: 127, y: 155, z: GoldenCityPlan.terraceHeight)
            context.landmark = LandmarkPlan(kind: .crystalPalace, position: castle, scale: 1)
            context.routes = [ExplorationRoute(name: L10n.t("城门到城堡", "Gate to castle"), waypoints: Array(plan.route.dropLast()) + [castle])]
            context.zones = []; context.roads = []; context.mediaSpots = []
            context.townSpots = plan.assetSpots
            context.fountainSpot = WorldPoint(x: plan.fountain.x, y: plan.fountain.y, z: 0)
            let golden = GoldenBudget.of(request.tier)
            budget.maxBlocks = golden.maxBlocks + (townIntent.mountains ? 1_200 : 0)
            budget.maxPlants = golden.maxPlants
            context.budget = budget
            let pack = townIntent.style.pack
            palette = MaterialPalette(primary: pack.material(.wall).tintHex, secondary: pack.material(.roof).tintHex, accent: pack.material(.accent).tintHex,
                                      opaqueShare: 0.6, glassDensity: 0.5, glow: 0.4)
            town = townIntent
        }
        context.addFarMountains(force: theme != .crystalKingdom && (intent.mountains || theme == .skyCity || theme == .nature || theme == .bossAdventure))
        let assignments = context.assign(usable)
        let facing = atan2(Double(context.landmark.position.y - context.spawn.y), Double(context.landmark.position.x - context.spawn.x)) * 180 / .pi
        var metadata = GenerationMetadata(generatorVersion: version, planner: planner, prompt: String(request.prompt.prefix(300)), candidate: variant)
        metadata.notes = notes
        if !intent.summary.isEmpty { metadata.notes.insert(intent.summary, at: 0) }
        return WorldBlueprint(
            blueprintID: "bp-\(seed % 1_000_000_000)-\(variant)", seed: seed, theme: theme,
            palette: palette,
            terrainPlan: TerrainPlan(features: context.features), biomeRegions: context.regions,
            roadNetwork: RoadNetwork(segments: context.roads), landmarkPlan: context.landmark,
            buildingZones: context.zones, decorationPlan: context.decoration(),
            lightingProfile: WorldThemeStyle.lighting(theme, time: time),
            assetAssignments: assignments, spawnPlan: SpawnPlan(position: context.spawn, facing: facing),
            explorationRoutes: context.routes, performanceBudget: budget, generationMetadata: metadata, town: town)
    }
}

/// Mutable planning state for one blueprint.
struct PlanContext {
    var random: SpatialRandom
    let theme: WorldTheme
    let intent: WorldIntent
    let density: Double
    let heading: Double
    var budget: PerformanceBudget
    var features: [TerrainFeature] = []
    var regions: [BiomeRegion] = []
    var roads: [RoadSegment] = []
    var zones: [BuildingZone] = []
    var routes: [ExplorationRoute] = []
    var spawn = WorldPoint(x: 128, y: 128, z: 0)
    var landmark = LandmarkPlan(kind: .spire, position: WorldPoint(x: 128, y: 170, z: 0), scale: 1)
    /// Where media walls may go (filled by the theme).
    var mediaSpots: [(WorldPoint, Int, String)] = []
    /// Golden World town: open spots for models and the fountain (v1.87).
    var townSpots: [GoldenAssetSpot] = []
    var fountainSpot: WorldPoint?

    init(random: SpatialRandom, theme: WorldTheme, intent: WorldIntent, density: Double, heading: Double, budget: PerformanceBudget) {
        self.random = random; self.theme = theme; self.intent = intent; self.density = density; self.heading = heading; self.budget = budget
    }


    static func clampCell(_ v: Int) -> Int { min(240, max(16, v)) }
    func point(angle: Double, distance: Double, from origin: WorldPoint, z: Double = 0) -> WorldPoint {
        WorldPoint(x: Self.clampCell(origin.x + Int((cos(angle) * distance).rounded())), y: Self.clampCell(origin.y + Int((sin(angle) * distance).rounded())), z: z)
    }
    mutating func region(_ kind: String, _ center: WorldPoint, _ radius: Int, density: Double = 1) -> String {
        let id = "\(kind)-\(regions.count)"
        regions.append(BiomeRegion(id: id, kind: kind, center: center, radius: radius, density: density))
        return id
    }
    mutating func road(_ a: WorldPoint, _ b: WorldPoint, width: Int = 3, kind: String = "road") {
        roads.append(RoadSegment(from: a, to: b, width: width, kind: kind))
    }

    // MARK: Glass Sky City

    mutating func skyCity() {
        let main = WorldPoint(x: 128, y: 128, z: 4)
        features.append(TerrainFeature(kind: .island, center: main, radius: 14, height: 4, depth: 6))
        // Spawn on the main island, on the side away from the landmark.
        spawn = point(angle: heading + .pi, distance: 6, from: main, z: 4)
        let landmarkHeight = 8.0 + Double(random.int(0...2))
        let landmarkCenter = point(angle: heading, distance: 44 + random.unit() * 6, from: main, z: landmarkHeight)
        features.append(TerrainFeature(kind: .island, center: landmarkCenter, radius: 12, height: landmarkHeight, depth: 8))
        landmark = LandmarkPlan(kind: intent.landmark ?? .crystalPalace, position: landmarkCenter, scale: intent.buildingScale)
        road(main, landmarkCenter, width: 3, kind: "bridge")
        let safeID = region("safe", main, 10)
        let plazaID = region("plaza", landmarkCenter, 11)
        // A ramp up from the cloud floor, so a fall is never a dead end.
        let rampFoot = point(angle: heading + .pi, distance: 26, from: main, z: 0)
        road(rampFoot, point(angle: heading + .pi, distance: 13, from: main, z: 4), width: 2, kind: "bridge")
        let count = intent.islands ?? (2 + random.int(0...2))
        var routeStops: [WorldPoint] = [spawn, landmarkCenter]
        for index in 0..<count {
            let side: Double = index % 2 == 0 ? 1 : -1
            let angle = heading + side * (1.1 + Double(index / 2) * 0.7 + random.unit() * 0.3)
            let height = 3.0 + Double(random.int(0...5))
            let center = point(angle: angle, distance: 30 + random.unit() * 16, from: main, z: height)
            let radius = 7 + random.int(0...3)
            features.append(TerrainFeature(kind: .island, center: center, radius: radius, height: height, depth: 5))
            road(main, center, width: 2, kind: "bridge")
            let garden = intent.gardens || index % 2 == 0
            let id = region(garden ? "garden" : "district", center, radius - 1, density: garden ? 1.2 : 0.8)
            zones.append(BuildingZone(regionID: id, structures: garden ? ["pavilion", "altar"] : ["tower", "hut", "pavilion"], count: garden ? 1 : 2 + Int(intent.buildingScale)))
            mediaSpots.append((point(angle: angle + .pi, distance: Double(radius - 3), from: center, z: height), 0, "galleryWall"))
            routeStops.append(center)
        }
        zones.append(BuildingZone(regionID: safeID, structures: ["tower", "pavilion"], count: 2))
        zones.append(BuildingZone(regionID: plazaID, structures: ["tower"], count: Int(2 * intent.buildingScale)))
        // Media near the spawn (foreground) and by the landmark.
        mediaSpots.insert((point(angle: heading + 0.6, distance: 8, from: main, z: 4), 1, "galleryWall"), at: 0)
        mediaSpots.append((point(angle: heading + .pi, distance: 8, from: landmarkCenter, z: landmarkHeight), 0, "landmarkScreen"))
        for i in 0..<Int(10 * density) {
            let angle = random.unit() * 2 * .pi
            features.append(TerrainFeature(kind: .cloud, center: point(angle: angle, distance: 18 + random.unit() * 60, from: main, z: 0.4), radius: 4 + random.int(0...3), height: 0.6 + Double(i % 3) * 0.3))
        }
        routes = [ExplorationRoute(name: L10n.t("通往地标", "To the landmark"), waypoints: [spawn, landmarkCenter]),
                  ExplorationRoute(name: L10n.t("群岛环游", "Island tour"), waypoints: routeStops)]
    }

    // MARK: Dream Memory

    mutating func memoryWorld(assets: Int) {
        let hall = point(angle: heading, distance: 40, from: WorldPoint(x: 128, y: 128, z: 0))
        spawn = WorldPoint(x: 128, y: 128, z: 0)
        landmark = LandmarkPlan(kind: intent.landmark ?? .galleryHall, position: hall, scale: intent.buildingScale)
        _ = region("safe", spawn, 7)
        _ = region("plaza", hall, 12)
        // A winding memory path from the spawn to the hall, walls along it.
        var previous = spawn
        let walls = max(4, min(budget.maxMediaWalls, assets + 2))
        var stops: [WorldPoint] = [spawn]
        for i in 1...4 {
            let t = Double(i) / 4
            let wobble = (i % 2 == 0 ? 1.0 : -1.0) * (10 + random.unit() * 6)
            let base = point(angle: heading, distance: 40 * t, from: spawn)
            let next = i == 4 ? hall : point(angle: heading + .pi / 2, distance: wobble, from: base)
            road(previous, next, width: 3)
            stops.append(next)
            previous = next
        }
        for i in 0..<walls {
            let stop = stops[1 + i % (stops.count - 1)]
            let side: Double = i % 2 == 0 ? 1 : -1
            mediaSpots.append((point(angle: heading + side * .pi / 2, distance: 5, from: stop), i % 2, i == 0 ? "landmarkScreen" : "galleryWall"))
        }
        let garden = point(angle: heading - 1.4, distance: 30, from: spawn)
        let gardenID = region("garden", garden, 12, density: 1.3)
        zones.append(BuildingZone(regionID: gardenID, structures: ["pavilion"], count: 2))
        road(spawn, garden, width: 2)
        // A still lake mirrors the memory hall's colours.
        features.append(TerrainFeature(kind: .lake, center: point(angle: heading + 1.6, distance: 26, from: spawn), radius: intent.water ? 12 : 8, height: 0))
        features.append(TerrainFeature(kind: .hill, center: point(angle: heading + 2.6, distance: 34, from: spawn), radius: 12, height: 3.5))
        routes = [ExplorationRoute(name: L10n.t("记忆小路", "Memory path"), waypoints: stops), ExplorationRoute(name: L10n.t("花园", "Garden"), waypoints: [spawn, garden])]
    }

    // MARK: Fantasy Nature

    mutating func natureWorld() {
        spawn = WorldPoint(x: 128, y: 128, z: 0)
        let tree = point(angle: heading, distance: 46, from: spawn)
        landmark = LandmarkPlan(kind: intent.landmark ?? .ancientTree, position: tree, scale: intent.buildingScale)
        _ = region("safe", spawn, 7)
        _ = region("plaza", tree, 10)
        road(spawn, tree, width: 2)
        // Hills on both sides of the way, a lake with a stream to it.
        for i in 0..<3 {
            let side: Double = i % 2 == 0 ? 1 : -1
            let center = point(angle: heading + side * (0.7 + Double(i) * 0.35), distance: 28 + Double(i) * 9, from: spawn)
            let radius = 10 + random.int(0...4)
            features.append(TerrainFeature(kind: .hill, center: center, radius: radius, height: Double(radius) / 3.2))
            let id = region("forest", center, radius, density: intent.forest ? 1.4 : 1)
            zones.append(BuildingZone(regionID: id, structures: [], count: 0))
        }
        let lake = point(angle: heading - 1.9, distance: 30, from: spawn)
        features.append(TerrainFeature(kind: .lake, center: lake, radius: 11, height: 0))
        road(point(angle: heading - 1.2, distance: 52, from: spawn), lake, width: 2, kind: "stream")
        let ruins = point(angle: heading + 2.2, distance: 38, from: spawn)
        let ruinsID = region("ruins", ruins, 10)
        zones.append(BuildingZone(regionID: ruinsID, structures: ["ruins", "altar"], count: 3))
        road(spawn, ruins, width: 2)
        let gardenID = region("garden", point(angle: heading - 0.6, distance: 16, from: spawn), 8, density: 1.2)
        zones.append(BuildingZone(regionID: gardenID, structures: ["hut"], count: 1))
        mediaSpots.append((point(angle: heading + 0.5, distance: 9, from: spawn), 1, "galleryWall"))
        routes = [ExplorationRoute(name: L10n.t("古树小径", "Trail to the tree"), waypoints: [spawn, tree]),
                  ExplorationRoute(name: L10n.t("湖与遗迹", "Lake and ruins"), waypoints: [spawn, lake, ruins])]
    }

    // MARK: Future Glass City

    mutating func futureCity() {
        spawn = WorldPoint(x: 128, y: 128, z: 0)
        let spacing = 22
        let extent = 2
        // Avenue grid (kept clear, a glowing centre line), the spawn on a
        // plaza at a crossing.
        for i in -extent...extent {
            let c = 128 + i * spacing
            road(WorldPoint(x: 128 - extent * spacing, y: c, z: 0), WorldPoint(x: 128 + extent * spacing, y: c, z: 0), width: 3, kind: "avenue")
            road(WorldPoint(x: c, y: 128 - extent * spacing, z: 0), WorldPoint(x: c, y: 128 + extent * spacing, z: 0), width: 3, kind: "avenue")
        }
        _ = region("safe", spawn, 7)
        // The landmark tower at a block corner ahead of the spawn.
        let ax = cos(heading) >= 0 ? 1 : -1, ay = sin(heading) >= 0 ? 1 : -1
        let towerBlock = WorldPoint(x: 128 + ax * spacing * 2 - ax * spacing / 2, y: 128 + ay * spacing - ay * spacing / 2, z: 0)
        landmark = LandmarkPlan(kind: intent.landmark ?? .megaTower, position: towerBlock, scale: intent.buildingScale)
        var stops: [WorldPoint] = [spawn]
        for bx in -extent..<extent {
            for by in -extent..<extent {
                let center = WorldPoint(x: 128 + bx * spacing + spacing / 2, y: 128 + by * spacing + spacing / 2, z: 0)
                if center.distance(towerBlock) < 2 || center.distance(spawn) < 10 { continue }
                let plaza = random.unit() < 0.18
                let id = region(plaza ? "plaza" : "district", center, spacing / 2 - 3, density: plaza ? 1 : 1)
                if plaza { stops.append(center); zones.append(BuildingZone(regionID: id, structures: ["pavilion"], count: 1)) }
                else {
                    let near = 1 - min(1, center.distance(spawn) / 70)
                    zones.append(BuildingZone(regionID: id, structures: ["skyscraper"], count: 1 + Int((2 + near * 2) * intent.buildingScale * min(1.2, density))))
                }
            }
        }
        for i in 0..<min(budget.maxMediaWalls, 8) {
            let a = heading + Double(i) * 0.8
            mediaSpots.append((point(angle: a, distance: 9 + Double(i % 3) * 18, from: spawn), i % 2, "billboard"))
        }
        stops.append(towerBlock)
        routes = [ExplorationRoute(name: L10n.t("城市大道", "Main avenue"), waypoints: [spawn, towerBlock]), ExplorationRoute(name: L10n.t("广场漫步", "Plazas"), waypoints: stops)]
    }

    // MARK: Boss Adventure

    mutating func bossWorld() {
        spawn = WorldPoint(x: 128, y: 128, z: 0)
        let arena = point(angle: heading, distance: 70, from: spawn)
        landmark = LandmarkPlan(kind: .arena, position: arena, scale: 1)
        let camp = region("safe", spawn, 9)
        zones.append(BuildingZone(regionID: camp, structures: ["hut", "altar"], count: 2))
        let first = point(angle: heading + 0.45, distance: 26, from: spawn)
        let second = point(angle: heading - 0.4, distance: 48, from: spawn)
        let reward = point(angle: heading + 1.2, distance: 40, from: spawn)
        let fight1 = region("combat", first, 10), fight2 = region("combat", second, 11)
        zones.append(BuildingZone(regionID: fight1, structures: ["ruins"], count: 2))
        zones.append(BuildingZone(regionID: fight2, structures: ["ruins", "tower"], count: 3))
        _ = region("reward", reward, 6)
        _ = region("arena", arena, 8)
        road(spawn, first, width: 3); road(first, second, width: 3); road(second, arena, width: 3); road(first, reward, width: 2)
        features.append(TerrainFeature(kind: .hill, center: point(angle: heading + 1.9, distance: 30, from: spawn), radius: 12, height: 3.5))
        features.append(TerrainFeature(kind: .hill, center: point(angle: heading - 1.7, distance: 34, from: spawn), radius: 13, height: 4))
        mediaSpots.append((point(angle: heading - 0.5, distance: 8, from: spawn), 1, "galleryWall"))
        routes = [ExplorationRoute(name: L10n.t("讨伐之路", "Road to the Boss"), waypoints: [spawn, first, second, arena]),
                  ExplorationRoute(name: L10n.t("宝藏支线", "Treasure detour"), waypoints: [spawn, first, reward])]
    }

    // MARK: Shared

    mutating func addFarMountains(force: Bool) {
        guard force else { return }
        // Far layer: a ring of mountains behind the landmark side.
        for i in 0..<4 {
            let angle = heading + (Double(i) - 1.5) * 0.5 + (random.unit() - 0.5) * 0.15
            let center = point(angle: angle, distance: 108, from: WorldPoint(x: 128, y: 128, z: 0))
            features.append(TerrainFeature(kind: .mountain, center: center, radius: 6 + random.int(0...2), height: 18 + Double(random.int(0...12))))
        }
    }

    func decoration() -> DecorationPlan {
        let base: (plants: Int, flowers: Double, trees: Int, lamps: Int, crystals: Int, clouds: Int) = switch theme {
        case .skyCity: (260, 0.55, 18, 30, intent.crystals ? 40 : 22, 0)
        case .memory: (320, 0.6, 24, 34, 14, 0)
        case .nature: (700, 0.3, 120, 16, 8, 0)
        case .futureCity: (160, 0.4, 30, 60, 10, 0)
        case .bossAdventure: (380, 0.2, 60, 24, 12, 0)
        // The town places its own trees, flowers and lamps.
        case .crystalKingdom: (0, 0, 0, 0, 0, 0)
        }
        let plants = min(budget.maxPlants, Int(Double(base.plants) * density * (intent.gardens ? 1.3 : 1) * (intent.forest ? 1.3 : 1)))
        return DecorationPlan(plants: plants, flowersShare: base.flowers, trees: min(plants / 3, Int(Double(base.trees) * density * (intent.forest ? 1.6 : 1))),
                              lamps: base.lamps, crystals: base.crystals, clouds: base.clouds)
    }

    /// Golden World town: one loop video / GIF on the fountain water, models on the town's open spots.
    mutating func assignTown(_ assets: [AssetDescriptor]) -> [AssetAssignment] {
        var result: [AssetAssignment] = []
        if let fountain = fountainSpot,
           let media = assets.first(where: { $0.assetRole == .fountainMedia || ($0.assetRole == nil && ($0.mediaType == .video || $0.mediaType == .gif)) }) {
            result.append(AssetAssignment(assetID: media.assetID, slot: "fountainMedia", position: fountain, axis: 0))
        }
        // Characters take the plaza first; scene models fill the rest.
        let models = assets.filter { $0.mediaType == .model }.sorted { ($0.assetRole == .character ? 0 : 1) < ($1.assetRole == .character ? 0 : 1) }
        for (model, spot) in zip(models, townSpots) {
            result.append(AssetAssignment(assetID: model.assetID, slot: "statue", position: WorldPoint(x: spot.x, y: spot.y, z: 0), axis: 0))
        }
        return result
    }

    /// Asset → slot: videos to screens / billboards first (within the
    /// video budget), pictures to gallery walls; models become statues.
    mutating func assign(_ assets: [AssetDescriptor]) -> [AssetAssignment] {
        // Style-only and material assets shape the plan; they are never placed.
        let assets = assets.filter { $0.assetRole?.placed ?? true }
        if theme == .crystalKingdom { return assignTown(assets) }
        var result: [AssetAssignment] = []
        var spots = mediaSpots
        var videos = 0
        let ordered = assets.filter { $0.mediaType == .video || $0.mediaType == .gif } + assets.filter { $0.mediaType == .image }
        for asset in ordered {
            guard result.count < budget.maxMediaWalls, !spots.isEmpty else { break }
            if asset.mediaType == .video {
                guard videos < budget.maxVideos else { continue }
                videos += 1
            }
            let index = spots.firstIndex { ($0.2 == "landmarkScreen" || $0.2 == "billboard") == (asset.mediaType != .image) } ?? 0
            let spot = spots.remove(at: index)
            result.append(AssetAssignment(assetID: asset.assetID, slot: spot.2, position: spot.0, axis: spot.1))
        }
        for asset in assets where asset.mediaType == .model {
            guard result.count < budget.maxMediaWalls + 4 else { break }
            let p = point(angle: heading + 0.3 + Double(result.count) * 0.5, distance: 7, from: spawn, z: spawn.z)
            result.append(AssetAssignment(assetID: asset.assetID, slot: "statue", position: p, axis: 0))
        }
        // Empty gallery walls are still placed (frosted), so a world made
        // without photos keeps its shape.
        for spot in spots.prefix(max(0, 3 - result.count)) where theme == .memory || theme == .futureCity {
            result.append(AssetAssignment(assetID: "", slot: spot.2, position: spot.0, axis: spot.1))
        }
        return result
    }
}
