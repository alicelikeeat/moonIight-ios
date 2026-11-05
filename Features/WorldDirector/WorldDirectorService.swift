import Foundation
import UIKit
import ImageIO
import AVFoundation
import CryptoKit

// v1.81 World Director, app side: the optional Claude planner (the user's
// own key; only the words and asset kinds / colours are sent, never the
// pictures), asset descriptors from the media library and the AI 3D
// library, and the controller actions that commit a world as one undo step.

/// Cancels a running generation from the UI.
final class WorldDirectorCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Claude fills a WorldIntent (structured output, validated and clamped).
struct ClaudeWorldPlanner: WorldPlanningProvider {
    let apiKey: String
    var model = ClaudeMotion.models[1]
    var timeout: TimeInterval = 30
    var name: String { "claude" }

    static var schema: [String: Any] {
        let colors: [String: Any] = ["type": "array", "items": ["type": "string", "description": "RRGGBB"]]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["colors", "landmark", "islands", "gardens", "bridges", "water", "mountains", "forest", "videoWall", "crystals", "timeOfDay", "buildingScale", "summary"],
            "properties": [
                "colors": colors,
                "landmark": ["type": "string", "enum": ["crystalPalace", "spire", "ancientTree", "megaTower", "galleryHall", "arena"]],
                "islands": ["type": "integer"], "gardens": ["type": "boolean"], "bridges": ["type": "boolean"], "water": ["type": "boolean"],
                "mountains": ["type": "boolean"], "forest": ["type": "boolean"], "videoWall": ["type": "boolean"], "crystals": ["type": "boolean"],
                "timeOfDay": ["type": "string", "enum": ["day", "dusk", "night"]], "buildingScale": ["type": "number"], "summary": ["type": "string"],
            ] as [String: Any],
        ]
    }

    static let system = """
    You plan explorable 3D worlds for a phone game built from glass blocks. Read the user's wish and the chosen theme and fill the plan: \
    up to three colours as RRGGBB (main, accent, structure) that match the wish and look good together; the landmark that best fits; \
    how many floating islands (2-4, sky worlds only); which features to include; the time of day; buildingScale 0.5-1.5 (bigger = grander); \
    and a one-sentence summary in the user's language. Only fill the fields; the game does the layout.
    """

    func intent(for request: WorldGenerationRequest, assets: [AssetDescriptor]) async throws -> WorldIntent {
        guard !apiKey.isEmpty else { throw ClaudeMotionError.noKey }
        var description = "Theme: \(request.theme.rawValue) (\(request.theme.summary))\nWish: \(String(request.prompt.prefix(600)))"
        if !assets.isEmpty {
            // Kinds and colours only — never the pictures themselves.
            let summary = assets.prefix(20).map { "\($0.mediaType.rawValue) \($0.dominantColors.prefix(2).joined(separator: "/")) \($0.styleTags.joined(separator: ","))" }
            description += "\nChosen media (kind, colours, tags): " + summary.joined(separator: "; ")
        }
        var body: [String: Any] = [
            "model": model.id, "max_tokens": 2000, "system": Self.system,
            "messages": [["role": "user", "content": description]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": Self.schema]] as [String: Any],
        ]
        if model.fallbacks { body["fallbacks"] = "default" }
        var urlRequest = URLRequest(url: ClaudeMotion.endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        for (k, v) in ClaudeMotion.headers(apiKey: apiKey, model: model) { urlRequest.setValue(v, forHTTPHeaderField: k) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let text = try ClaudeMotion.answerText(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        guard let intent = WorldIntentResolver.decode(Data(text.utf8), theme: request.theme) else { throw ClaudeMotionError.badReply("plan did not match the schema") }
        return intent
    }
}

/// Runs a provider with a hard time limit.
enum WorldPlanningRunner {
    static func intent(_ provider: any WorldPlanningProvider, request: WorldGenerationRequest, assets: [AssetDescriptor], seconds: Double) async -> Result<WorldIntent, Error> {
        await withTaskGroup(of: Result<WorldIntent, Error>.self) { group in
            group.addTask { do { return .success(try await provider.intent(for: request, assets: assets)) } catch { return .failure(error) } }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return .failure(WorldPlanningTimeout())
            }
            let first = await group.next() ?? .failure(WorldPlanningTimeout())
            group.cancelAll()
            return first
        }
    }
}

struct WorldPlanningTimeout: Error, LocalizedError {
    var errorDescription: String? { L10n.t("超时", "timed out") }
}

/// Library items → asset descriptors (file reads off the main thread).
enum WorldAssetReader {
    static func describe(entries: [(id: String, title: String, url: URL?, kind: RPGMediaKind, source: AssetSourceType, license: String?)]) async -> [AssetDescriptor] {
        await Task.detached(priority: .userInitiated) {
            entries.map { entry -> AssetDescriptor in
                let type: AssetMediaType = entry.kind == .video ? .video : entry.kind == .gif ? .gif : .image
                guard let url = entry.url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
                    return AssetAnalyzer.describe(image: nil, id: entry.id, source: entry.source, type: type, libraryID: entry.id, hash: entry.id,
                                                  title: entry.title, width: 0, height: 0, license: entry.license)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let hash = "\(entry.id)-\(size)"
                if type == .video {
                    let asset = AVURLAsset(url: url)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 96, height: 96)
                    let frame = try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
                    let raster = frame.flatMap { ModelAnimationExport.raster($0) }
                    return AssetAnalyzer.describe(image: raster, id: entry.id, source: entry.source, type: .video, libraryID: entry.id, hash: hash,
                                                  title: entry.title, width: frame?.width ?? 0, height: frame?.height ?? 0, license: entry.license)
                }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 96]
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
                let thumb = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
                return AssetAnalyzer.describe(image: thumb.flatMap { ModelAnimationExport.raster($0) }, id: entry.id, source: entry.source, type: type,
                                              libraryID: entry.id, hash: hash, title: entry.title, width: width, height: height, license: entry.license)
            }
        }.value
    }

    /// An AI-made 3D model as a statue asset.
    static func model(id: String, title: String, triangles: Int) -> AssetDescriptor {
        var a = AssetDescriptor(assetID: "model:" + id, sourceType: .generatedModel, mediaType: .model, libraryID: id, contentHash: "model:" + id)
        a.polygonCount = triangles; a.title = title; a.compatibleWorldTypes = AssetAnalyzer.compatibleThemes(.model)
        return a
    }
}

// MARK: Controller actions

@available(iOS 18.0, *)
extension Glass3DController {
    /// Candidates for a request, computed off the main thread.
    func directorCandidates(_ request: WorldGenerationRequest, intent: WorldIntent?, planner: String, flag: WorldDirectorCancelFlag,
                            progress: @escaping @Sendable (WorldGenerationStage, Double) -> Void) async throws -> [WorldCandidate] {
        let base = world
        return try await Task.detached(priority: .userInitiated) {
            try WorldDirectorEngine.candidates(request, intent: intent, planner: planner, base: base, progress: progress, cancelled: { flag.isSet })
        }.value
    }

    /// Commits a chosen candidate as one undo step (sky and plan included).
    func applyDirector(_ candidate: WorldCandidate) {
        directorBackup = world
        // AI 3D models become characters standing in the world.
        var statues: [CreatureEntity] = []
        for statue in candidate.output.statues {
            guard let manifest = Generated3DStore.shared.models.first(where: { $0.id == statue.modelID }) else { continue }
            let look = characterID(forGenerated: manifest)
            var c = CreatureEntity(id: "wdstatue:" + UUID().uuidString, kind: .neutral, position: statue.position, home: statue.position, health: 10, maxHealth: 10, damage: 0, origin: .generated)
            c.characterID = look
            statues.append(c)
        }
        let built = candidate.output.world, characters = world.characters
        edit(L10n.t("世界导演：", "World Director: ") + candidate.blueprint.theme.title, bindings: candidate.output.bindings) { w in
            let history = w.history, clock = w.clock
            w = built; w.history = history; w.clock = clock
            w.characters = characters
            w.creatures.append(contentsOf: statues)
        }
        moveToSpawn()
        resetCreatureBrains()
        persist(force: true)
    }

    /// New arrangement for some layers (around the camera, or everywhere).
    func regenerateDirector(layers: Set<WorldLayer>, nearCamera: Bool) async throws -> [String] {
        let base = world
        let area: (center: WorldPoint, radius: Int)? = nearCamera ? (WorldPoint(x: Int(camera.target.x), y: Int(camera.target.y), z: 0), 24) : nil
        let offset = UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFF_FFFF
        let output = try await Task.detached(priority: .userInitiated) {
            try WorldDirectorEngine.regenerate(base, layers: layers, area: area, seedOffset: offset)
        }.value
        let names = layers.map(\.title).sorted().joined(separator: "、")
        edit(L10n.t("局部重生成：", "Regenerate: ") + names, bindings: output.bindings) { w in
            let history = w.history, clock = w.clock
            w = output.world; w.history = history; w.clock = clock
        }
        return output.notes
    }

    func relightDirector(_ time: WorldTimeOfDay) {
        edit(L10n.t("天空：", "Sky: ") + time.title) { w in w = WorldDirectorEngine.relight(w, time: time) }
    }

    /// Selected blocks become the user's: regeneration will not touch them.
    func lockSelection() {
        guard !selection.isEmpty else { notice = L10n.t("先选中要锁定的方块", "Select the blocks to lock first"); return }
        updateSelected(L10n.t("锁定 \(selection.count) 个方块", "Lock \(selection.count) blocks")) { _ in }
        notice = L10n.t("已锁定：重新生成不会改动它们", "Locked: regeneration will not change them")
    }

    var canRestoreBeforeDirector: Bool { directorBackup != nil }
    /// The whole world as it was before the last World Director run.
    func restoreBeforeDirector() {
        guard let backup = directorBackup else { return }
        edit(L10n.t("恢复生成前的世界", "Restore the world before generating")) { w in
            let history = w.history, clock = w.clock
            w = backup; w.history = history; w.clock = clock
        }
        directorBackup = nil
        moveToSpawn()
        persist(force: true)
    }
}
