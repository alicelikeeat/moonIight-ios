import Foundation

enum WorldGeometry {
    static let width = 256
    static let chunkSide = 32
    static let chunkColumns = 8
    static let sideHeight = 64
}
struct SurfacePoint: Codable, Hashable, Sendable {
    var x: Int
    var z: Int
    var valid: Bool { (0..<256).contains(x) && (0..<256).contains(z) }
    var chunk: ChunkCoordinate? { valid ? .init(x: x / 32, z: z / 32) : nil }
}
struct ChunkCoordinate: Codable, Hashable, Identifiable, Sendable {
    var x: Int
    var z: Int
    var id: Int { z * 8 + x }
    var valid: Bool { (0..<8).contains(x) && (0..<8).contains(z) }
    static let all = (0..<8).flatMap { z in (0..<8).map { ChunkCoordinate(x: $0, z: z) } }
}
enum ProjectionScope: String, Codable, Sendable { case shared, topDownOnly, sideOnly }
enum RPGPerspective: String, Codable, CaseIterable, Sendable { case topDown, side }
enum RPGGameMode: String, Codable, CaseIterable, Sendable { case adventure, creative }
struct SidePlacement: Codable, Equatable, Sendable {
    var regionID: String
    var horizontal: Int
    var height: Int
}
/// A side region is one explicitly declared surface row, not a rotated map.
struct SideRegion: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var origin: SurfacePoint
    var width: Int
    var landing: SidePlacement
    func contains(_ point: SurfacePoint) -> Bool {
        point.z == origin.z && point.x >= origin.x && point.x - origin.x < width
    }
    var valid: Bool {
        !id.isEmpty && origin.valid && (1...256).contains(width) && width <= 256 - origin.x &&
        landing.regionID == id && (0..<width).contains(landing.horizontal) && (0..<64).contains(landing.height)
    }
}
struct PhysicsProfile: Codable, Equatable, Sendable {
    var topDownSolid = true
    var sideSolid = true
    var sideGravity = false
    var pushable = false
    var hitPoints = 3
    var width = 1.0
    var height = 1.0
    var valid: Bool { (1...10000).contains(hitPoints) && width.isFinite && height.isFinite && width > 0 && height > 0 && width <= 16 && height <= 16 }
}
enum RPGEntityKind: String, Codable, Sendable { case block, npc, enemy, trigger, decoration }
struct WorldEntity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var definitionID: String
    var kind: RPGEntityKind = .block
    var scope: ProjectionScope
    var surface: SurfacePoint?
    var side: SidePlacement?
    var physics = PhysicsProfile()
    var mediaBindingID: String?
}
enum RPGMediaKind: String, Codable, Sendable { case image, video }
struct MediaBinding: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var mediaID: String
    var kind: RPGMediaKind
    var coverMediaID: String?
    var scale = 1.0
    var anchorX = 0.5
    var anchorY = 0.5
    var cropX = 0.0
    var cropY = 0.0
    var cropWidth = 1.0
    var cropHeight = 1.0
    var loop = true
    var muted = true
    var valid: Bool {
        !id.isEmpty && !mediaID.isEmpty && scale.isFinite && (0.1...8).contains(scale) &&
        [anchorX, anchorY, cropX, cropY, cropWidth, cropHeight].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        cropWidth > 0 && cropHeight > 0 && cropX + cropWidth <= 1.000001 && cropY + cropHeight <= 1.000001
    }
}
struct RPGPlayerState: Codable, Equatable, Sendable {
    var surface = SurfacePoint(x: 16, z: 16)
    var side: SidePlacement?
    var health = 100
    var stamina = 100
    var perspective = RPGPerspective.topDown
    var mode = RPGGameMode.adventure
    var inCombat = false
    var mediaBindingID: String?
}
/// Pure state. Seed/generator identity is distinct from file schema identity.
struct WorldState: Codable, Equatable, Sendable {
    static let currentSchema = 1
    var schemaVersion = 1
    var generatorVersion = 1
    var id = UUID().uuidString
    var seed: UInt64
    var revision: UInt64 = 0
    var player = RPGPlayerState()
    var entities: [WorldEntity] = []
    var mediaBindings: [MediaBinding] = []
    var sideRegions: [SideRegion] = []
    var generated = false
    init(seed: UInt64 = 20261102) { self.seed = seed }
    func validate() throws {
        guard schemaVersion == Self.currentSchema, generatorVersion == 1 else { throw RPGWorldError.unsupportedVersion }
        guard !id.isEmpty, id.count <= 128, player.surface.valid, (0...100).contains(player.health), (0...100).contains(player.stamina),
              entities.count <= 65536, mediaBindings.count <= 1024, sideRegions.count <= 64 else { throw RPGWorldError.invalidState }
        guard Set(entities.map(\.id)).count == entities.count, Set(mediaBindings.map(\.id)).count == mediaBindings.count,
              Set(sideRegions.map(\.id)).count == sideRegions.count else { throw RPGWorldError.duplicateIdentity }
        guard mediaBindings.allSatisfy(\.valid), sideRegions.allSatisfy(\.valid) else { throw RPGWorldError.invalidState }
        let bindings = Set(mediaBindings.map(\.id))
        func validSide(_ side: SidePlacement) -> Bool {
            guard let region = sideRegions.first(where: { $0.id == side.regionID }) else { return false }
            return (0..<region.width).contains(side.horizontal) && (0..<64).contains(side.height)
        }
        if let side = player.side, !validSide(side) { throw RPGWorldError.invalidProjection }
        if player.perspective == .side && player.side == nil { throw RPGWorldError.invalidProjection }
        if let binding = player.mediaBindingID, !bindings.contains(binding) { throw RPGWorldError.missingReference }
        for entity in entities {
            guard !entity.id.isEmpty, entity.id.count <= 128, !entity.definitionID.isEmpty, entity.physics.valid else { throw RPGWorldError.invalidState }
            if let binding = entity.mediaBindingID, !bindings.contains(binding) { throw RPGWorldError.missingReference }
            if let surface = entity.surface, !surface.valid { throw RPGWorldError.invalidState }
            if let side = entity.side, !validSide(side) { throw RPGWorldError.invalidProjection }
            switch entity.scope {
            case .topDownOnly: guard entity.surface != nil && entity.side == nil else { throw RPGWorldError.invalidProjection }
            case .sideOnly: guard entity.surface == nil && entity.side != nil else { throw RPGWorldError.invalidProjection }
            case .shared:
                guard let surface = entity.surface, let side = entity.side,
                      let region = sideRegions.first(where: { $0.id == side.regionID }), region.contains(surface),
                      side.horizontal == surface.x - region.origin.x else { throw RPGWorldError.invalidProjection }
            }
        }
    }
}
enum RPGWorldError: Error, Equatable, LocalizedError {
    case unsupportedVersion, invalidState, duplicateIdentity, invalidProjection, missingReference, oversized
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "世界版本不兼容，保留原文件。"
        case .invalidState: "世界数据不合法。"
        case .duplicateIdentity: "世界中存在重复身份。"
        case .invalidProjection: "投影区域或坐标映射不合法。"
        case .missingReference: "世界数据引用缺失。"
        case .oversized: "世界文件超过读取上限。"
        }
    }
}
