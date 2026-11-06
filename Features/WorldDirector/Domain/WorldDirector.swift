import Foundation

// v1.81 World Director: quality evaluation, the three-candidate run,
// local regeneration, and the replaceable planning provider (local rules
// or an AI that only fills a WorldIntent — data, validated and clamped).

// MARK: Quality

struct WorldQualityReport: Codable, Equatable, Sendable {
    /// Hard constraints that failed (any → the candidate is not offered).
    var violations: [String]
    /// 0…100 per dimension.
    var composition: Double
    var harmony: Double
    var lighting: Double
    var exploration: Double
    var consistency: Double
    var performance: Double
    var reachableShare: Double
    var blocks: Int
    var plants: Int
    var creatures: Int

    static let weights = (composition: 0.25, harmony: 0.20, lighting: 0.20, exploration: 0.15, consistency: 0.10, performance: 0.10)
    var total: Double {
        let w = Self.weights
        return composition * w.composition + harmony * w.harmony + lighting * w.lighting + exploration * w.exploration + consistency * w.consistency + performance * w.performance
    }
    var passed: Bool { violations.isEmpty }
}

enum WorldQualityEvaluator {
    /// Scores a built world against its blueprint. Reachability, data
    /// validity, licences and the budget are hard constraints.
    static func evaluate(_ output: WorldBuildOutput, blueprint bp: WorldBlueprint, assets: [AssetDescriptor]) -> WorldQualityReport {
        let world = output.world
        var violations: [String] = []
        let generatedBlocks = world.blocks.filter { $0.origin == .generated }
        let generatedPlants = world.plants.filter { $0.origin == .generated }
        let generatedCreatures = world.creatures.filter { $0.origin == .generated }
        // Data validity (the same rules a save must pass).
        let bindingIDs = Set(output.bindings.map(\.id))
        // Pictures the world already used before generating (block media,
        // characters' action clips) live in the session's bindings, not in
        // this output: they are known, not missing. v1.85: characters were
        // left out, so any world with characters failed every candidate.
        let referenced = Set(world.blocks.compactMap { $0.media?.bindingID })
            .union((world.characters ?? []).flatMap { $0.clips.values.flatMap(\.bindingIDs) })
        do { try world.validate(bindings: bindingIDs.union(referenced)) } catch { violations.append("invalid world data") }
        if !world.blocks.allSatisfy(\.valid) { violations.append("invalid block") }
        // Budget.
        if generatedBlocks.count > bp.performanceBudget.maxBlocks { violations.append("over block budget") }
        if generatedPlants.count > bp.performanceBudget.maxPlants { violations.append("over plant budget") }
        let videoBindings = output.bindings.filter { $0.kind == .video }.count
        if videoBindings > bp.performanceBudget.maxVideos { violations.append("too many videos") }
        // Licences: every asset in a binding must be usable.
        let byLibrary = Dictionary(assets.compactMap { a in a.libraryID.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        for binding in output.bindings {
            if let asset = byLibrary[binding.mediaID], AssetRules.check(asset) != .ok { violations.append("unlicensed or unusable asset"); break }
        }
        // Overlap between solid generated blocks.
        var columns: [Int: [ClosedRange<Double>]] = [:]
        var overlap = false
        for block in world.blocks where block.collision == .solid {
            let key = block.y * WorldGeometry.width + block.x
            let range = block.elevation...block.top
            if columns[key, default: []].contains(where: { $0.lowerBound < range.upperBound - 0.02 && range.lowerBound < $0.upperBound - 0.02 }) { overlap = true }
            columns[key, default: []].append(range)
        }
        if overlap { violations.append("overlapping blocks") }
        // Reachability from the spawn.
        let geometry = SpatialGeometry(blocks: world.blocks, plants: world.plants)
        let navigator = SpatialNavigator(geometry: geometry)
        if geometry.blocked(x: world.spawn.x, y: world.spawn.y, z: world.spawn.z + 0.05) { violations.append("spawn blocked") }
        let reach = navigator.reachable(from: world.spawn, climb: 1.0, drop: 64)
        if reach.count < 300 { violations.append("spawn enclosed") }
        func reachable(_ p: WorldPoint, slack: Int) -> Bool {
            for dx in -slack...slack { for dy in -slack...slack {
                for h in navigator.surfaces(x: p.x + dx, y: p.y + dy) where reach.contains(SpatialNavigator.Node(x: p.x + dx, y: p.y + dy, level: Int((h * 20).rounded()))) {
                    if h > 0.3 || p.z < 0.3 || !bp.terrainPlan.features.contains(where: { $0.kind == .island }) { return true }
                }
            } }
            return false
        }
        if !reachable(bp.landmarkPlan.position, slack: 7) { violations.append("landmark unreachable") }
        let mainRegions = bp.biomeRegions.filter { ["safe", "plaza", "garden", "district", "combat", "reward", "arena", "ruins", "forest"].contains($0.kind) }
        let reachedRegions = mainRegions.filter { reachable($0.center, slack: max(2, $0.radius / 2)) }.count
        let reachableShare = mainRegions.isEmpty ? 1 : Double(reachedRegions) / Double(mainRegions.count)
        if reachableShare < 0.75 { violations.append("main areas unreachable") }
        for route in bp.explorationRoutes.prefix(1) where !route.waypoints.allSatisfy({ reachable($0, slack: 6) }) { violations.append("main route broken"); break }

        // Scores.
        let spawn = bp.spawnPlan.position, landmark = bp.landmarkPlan.position
        let distance = spawn.distance(landmark)
        let distanceScore = distance >= 25 && distance <= 75 ? 1 : max(0, 1 - abs(distance - 50) / 60)
        func band(_ lo: Double, _ hi: Double) -> Bool {
            generatedBlocks.contains { b in let d = hypot(Double(b.x) - spawn.vector.x, Double(b.y) - spawn.vector.y); return d >= lo && d < hi }
        }
        let layersPresent = [band(0, 16), band(16, 50), band(50, 200)].filter { $0 }.count
        let landmarkHeight = generatedBlocks.filter { abs($0.x - landmark.x) <= 7 && abs($0.y - landmark.y) <= 7 }.map(\.top).max() ?? 0
        let tall = min(1, landmarkHeight / 14)
        let composition = 100 * (0.35 * distanceScore + 0.35 * Double(layersPresent) / 3 + 0.3 * tall)

        let structure = generatedBlocks.filter { $0.collision == .solid }
        let grounded = structure.filter { b in b.elevation < 0.05 || columns[b.y * WorldGeometry.width + b.x, default: []].contains { abs($0.upperBound - b.elevation) < 0.15 } || SpatialWorldBuilder.layer(of: b.id) == .roads || SpatialWorldBuilder.layer(of: b.id) == .terrain }
        let harmony = structure.isEmpty ? 50 : 100 * (0.6 * Double(grounded.count) / Double(structure.count) + 0.4 * reachableShare)

        let opaque = generatedBlocks.filter { $0.glass.surface == .stone || $0.glass.surface == .metal }.count
        let opaqueShare = generatedBlocks.isEmpty ? 0 : Double(opaque) / Double(generatedBlocks.count)
        let supportScore = opaqueShare >= 0.15 && opaqueShare <= 0.92 ? 1 : 0.4
        let sky = AssetAnalyzer.rgb(bp.lightingProfile.skyTop).map { ($0.0 + $0.1 + $0.2) / 3 } ?? 0.5
        let primary = AssetAnalyzer.rgb(bp.palette.primary).map { ($0.0 + $0.1 + $0.2) / 3 } ?? 0.5
        let contrast = min(1, abs(sky - primary) * 2)
        let lighting = 100 * (0.5 * supportScore + 0.5 * max(0.3, contrast))

        let routeLength = bp.explorationRoutes.reduce(0.0) { sum, r in sum + zip(r.waypoints, r.waypoints.dropFirst()).reduce(0) { $0 + $1.0.distance($1.1) } }
        let pointsOfInterest = bp.biomeRegions.count + world.pickups.filter { $0.origin == .generated }.count / 2
        let exploration = 100 * (0.4 * min(1, routeLength / 140) + 0.3 * min(1, Double(pointsOfInterest) / 10) + 0.3 * reachableShare)

        let palette = Set([bp.palette.primary, bp.palette.secondary, bp.palette.accent, "FFFFFF", "6FB7E8", "EEF2F7", "8E99AE", "86B07A", "7A5A3C", "7FD88A", "3A4152"])
        let inPalette = generatedBlocks.filter { palette.contains($0.glass.tintHex ?? "") }.count
        let consistency = generatedBlocks.isEmpty ? 50 : 100 * Double(inPalette) / Double(generatedBlocks.count)

        let load = Double(generatedBlocks.count) / Double(max(1, bp.performanceBudget.maxBlocks))
        let performance = 100 * max(0, min(1, 1.15 - load * 0.6)) * (videoBindings <= bp.performanceBudget.maxVideos ? 1 : 0.3)

        return WorldQualityReport(violations: violations, composition: composition, harmony: harmony, lighting: lighting, exploration: exploration,
                                  consistency: consistency, performance: performance, reachableShare: reachableShare,
                                  blocks: generatedBlocks.count, plants: generatedPlants.count, creatures: generatedCreatures.count)
    }
}

// MARK: Candidates

struct WorldCandidate: Sendable, Identifiable {
    var blueprint: WorldBlueprint
    var output: WorldBuildOutput
    var report: WorldQualityReport
    var id: String { blueprint.blueprintID }
}

enum WorldGenerationStage: String, Sendable {
    case assets, planning, building, evaluating, done
    var title: String {
        switch self {
        case .assets: L10n.t("分析素材", "Analysing assets"); case .planning: L10n.t("规划世界", "Planning the world")
        case .building: L10n.t("搭建方案", "Building candidates"); case .evaluating: L10n.t("评估质量", "Checking quality"); case .done: L10n.t("完成", "Done")
        }
    }
}

enum WorldDirectorEngine {
    /// Three (or `count`) candidate worlds from one request, best first.
    /// Each is retried with derived seeds until it passes the hard
    /// constraints. Pure: `base` is not changed; cancelling leaves nothing.
    static func candidates(_ request: WorldGenerationRequest, intent: WorldIntent?, planner: String = "local", base: SpatialWorld, count: Int = 3,
                           progress: (WorldGenerationStage, Double) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws -> [WorldCandidate] {
        progress(.assets, 0)
        var result: [WorldCandidate] = []
        for variant in 0..<count {
            if cancelled() { throw WorldDirectorError.cancelled }
            var best: WorldCandidate?
            for attempt in 0..<4 {
                if cancelled() { throw WorldDirectorError.cancelled }
                progress(.planning, (Double(variant) + Double(attempt) * 0.1) / Double(count))
                var tweaked = request
                tweaked.seed = request.seed &+ UInt64(attempt) &* 0xA24B_AED4_963E_E407
                let blueprint = WorldPlanner.plan(tweaked, intent: intent, variant: variant, planner: planner)
                progress(.building, (Double(variant) + 0.4) / Double(count))
                let output = try SpatialWorldBuilder.build(blueprint, assets: request.assets, onto: base, difficulty: request.difficulty, cancelled: cancelled)
                progress(.evaluating, (Double(variant) + 0.8) / Double(count))
                let report = WorldQualityEvaluator.evaluate(output, blueprint: blueprint, assets: request.assets)
                let candidate = WorldCandidate(blueprint: blueprint, output: output, report: report)
                if best == nil || (report.passed && !(best!.report.passed)) || (report.passed == best!.report.passed && report.total > best!.report.total) { best = candidate }
                if report.passed { break }
            }
            if let best { result.append(best) }
        }
        progress(.done, 1)
        guard !result.isEmpty else { throw WorldDirectorError.nothingBuilt }
        return result.sorted { ($0.report.passed ? 1 : 0, $0.report.total) > ($1.report.passed ? 1 : 0, $1.report.total) }
    }

    /// Regenerates some layers (optionally only around a point) of the
    /// world's saved blueprint with a new seed. User objects stay.
    static func regenerate(_ world: SpatialWorld, layers: Set<WorldLayer>, area: (center: WorldPoint, radius: Int)?, seedOffset: UInt64,
                           assets explicit: [AssetDescriptor]? = nil, difficulty: GameDifficulty = .normal) throws -> WorldBuildOutput {
        guard var blueprint = world.director?.blueprint else { throw WorldDirectorError.nothingBuilt }
        let assets = explicit ?? world.director?.assets ?? []
        // A new arrangement for the chosen layers: same plan, new seed.
        blueprint.seed = blueprint.seed &+ seedOffset &* 0x9E37_79B9_7F4A_7C15
        var output = try SpatialWorldBuilder.build(blueprint, assets: assets, onto: world, layers: layers, area: area, difficulty: difficulty, updateAtmosphere: false)
        // Keep the original seed on record (the plan did not change).
        if var record = output.world.director { record.blueprint.seed = world.director!.blueprint.seed; output.world.director = record }
        return output
    }

    /// A new sky for the same world (time of day).
    static func relight(_ world: SpatialWorld, time: WorldTimeOfDay) -> SpatialWorld {
        var w = world
        guard let theme = world.director?.blueprint.theme else { return w }
        let lighting = WorldThemeStyle.lighting(theme, time: time)
        w.atmosphere = SpatialAtmosphere(lighting)
        w.director?.blueprint.lightingProfile = lighting
        return w
    }
}

// MARK: Planning providers

/// Turns words (and the asset list) into an intent. The local provider
/// always works; an AI provider may do better and may fail.
protocol WorldPlanningProvider: Sendable {
    var name: String { get }
    func intent(for request: WorldGenerationRequest, assets: [AssetDescriptor]) async throws -> WorldIntent
}

struct LocalWorldPlanner: WorldPlanningProvider {
    var name: String { "local" }
    func intent(for request: WorldGenerationRequest, assets: [AssetDescriptor]) async throws -> WorldIntent {
        WorldIntentParser.parse(request.prompt, theme: request.theme)
    }
}

enum WorldIntentResolver {
    /// The AI answer when it is usable, else the local intent; with a note
    /// saying which was used and why.
    static func resolve(ai: Result<WorldIntent, Error>?, request: WorldGenerationRequest) -> (intent: WorldIntent, planner: String, note: String?) {
        let local = WorldIntentParser.parse(request.prompt, theme: request.theme)
        switch ai {
        case .none: return (local, "local", nil)
        case .success(let intent):
            var clamped = intent.clamped()
            clamped.theme = request.theme
            if clamped.summary.isEmpty { clamped.summary = local.summary }
            return (clamped, "claude", nil)
        case .failure(let error):
            let why = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return (local, "local", L10n.t("AI 规划不可用（\(why)），已改用本机规则", "AI planning unavailable (\(why)); local rules used"))
        }
    }

    /// JSON from an AI → intent, or nil when it does not match the schema.
    static func decode(_ data: Data, theme: WorldTheme) -> WorldIntent? {
        struct Wire: Decodable {
            var colors: [String]?; var landmark: String?; var islands: Int?; var gardens: Bool?; var bridges: Bool?; var water: Bool?
            var mountains: Bool?; var forest: Bool?; var videoWall: Bool?; var crystals: Bool?; var timeOfDay: String?; var buildingScale: Double?; var summary: String?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        var intent = WorldIntent(theme: theme)
        intent.colors = wire.colors ?? []
        intent.landmark = wire.landmark.flatMap(LandmarkKind.init(rawValue:))
        intent.islands = wire.islands
        intent.gardens = wire.gardens ?? false; intent.bridges = wire.bridges ?? false; intent.water = wire.water ?? false
        intent.mountains = wire.mountains ?? false; intent.forest = wire.forest ?? false; intent.videoWall = wire.videoWall ?? false
        intent.crystals = wire.crystals ?? false
        intent.timeOfDay = wire.timeOfDay.flatMap(WorldTimeOfDay.init(rawValue:))
        intent.buildingScale = wire.buildingScale ?? 1
        intent.summary = wire.summary ?? ""
        return intent.clamped()
    }
}

// MARK: Preview

/// A small top-down picture of a candidate (no 3D needed): terrain and
/// buildings in their colours, brighter when higher; plants green; the
/// spawn and the landmark marked.
enum WorldPreview {
    static func raster(_ world: SpatialWorld, blueprint: WorldBlueprint, size: Int = 128) -> RasterImage {
        let scale = max(1, WorldGeometry.width / size)
        var image = RasterImage(width: size, height: size, fill: [22, 26, 38, 255])
        var top = [Double](repeating: -1, count: size * size)
        func put(_ x: Int, _ y: Int, _ rgb: (Double, Double, Double), height: Double) {
            let px = x / scale, py = (WorldGeometry.width - 1 - y) / scale
            guard (0..<size).contains(px), (0..<size).contains(py) else { return }
            let i = py * size + px
            guard height >= top[i] else { return }
            top[i] = height
            let light = min(1.25, 0.55 + height / 24)
            let o = i * 4
            image.rgba[o] = UInt8(min(255, rgb.0 * 255 * light)); image.rgba[o + 1] = UInt8(min(255, rgb.1 * 255 * light)); image.rgba[o + 2] = UInt8(min(255, rgb.2 * 255 * light))
        }
        for b in world.blocks {
            let rgb = AssetAnalyzer.rgb(b.glass.tintHex ?? "E6EEF8") ?? (0.9, 0.93, 0.97)
            put(b.x, b.y, rgb, height: b.top)
        }
        for p in world.plants { put(p.x, p.y, p.kind == .glow ? (1, 0.9, 0.5) : (0.35, 0.8, 0.4), height: p.z + 0.5) }
        func mark(_ p: WorldPoint, _ rgb: (UInt8, UInt8, UInt8), radius: Int) {
            let cx = p.x / scale, cy = (WorldGeometry.width - 1 - p.y) / scale
            for dy in -radius...radius { for dx in -radius...radius where abs(dx) + abs(dy) <= radius {
                let x = cx + dx, y = cy + dy
                guard (0..<size).contains(x), (0..<size).contains(y) else { continue }
                let o = (y * size + x) * 4
                image.rgba[o] = rgb.0; image.rgba[o + 1] = rgb.1; image.rgba[o + 2] = rgb.2
            } }
        }
        mark(blueprint.landmarkPlan.position, (255, 120, 200), radius: 2)
        mark(blueprint.spawnPlan.position, (255, 220, 60), radius: 2)
        return image
    }
}
