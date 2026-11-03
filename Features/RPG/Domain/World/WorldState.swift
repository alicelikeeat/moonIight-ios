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
        !id.isEmpty && id.count <= 64 && origin.valid && (1...256).contains(width) && width <= 256 - origin.x &&
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
enum RPGMediaKind: String, Codable, CaseIterable, Sendable {
    case image, video, gif, icon, number, text
    /// Kinds whose pixels come from a library file.
    var usesLibraryFile: Bool { self == .image || self == .video || self == .gif }
    var title: String {
        switch self {
        case .image: L10n.t("图片", "Image"); case .video: L10n.t("视频", "Video"); case .gif: "GIF"; case .icon: L10n.t("图标", "Icon"); case .number: L10n.t("数字", "Number"); case .text: L10n.t("文字", "Text")
        }
    }
}
enum RPGContentFit: String, Codable, CaseIterable, Sendable { case fill, fit }
enum RPGTextDesign: String, Codable, CaseIterable, Sendable { case rounded, standard, serif, monospaced }
enum RPGTextAlignment: String, Codable, CaseIterable, Sendable { case leading, center, trailing }
/// Glyph content for icon, number and text cells. For an icon, `value` is an
/// SF Symbol name; a custom icon instead uses the binding's library image
/// (tinted with `colorHex`) and leaves `value` empty.
struct RPGCellStyle: Codable, Equatable, Sendable {
    var value = ""
    var colorHex = "FFFFFF"
    var backgroundHex: String?
    var size = 0.6
    var design = RPGTextDesign.rounded
    var alignment = RPGTextAlignment.center
    var bold = true
    static func validHex(_ value: String) -> Bool { value.count == 6 && value.allSatisfy(\.isHexDigit) }
    static func validNumber(_ value: String) -> Bool {
        value.range(of: #"^-?[0-9]{1,12}(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil
    }
    static func validSymbol(_ value: String) -> Bool {
        (1...128).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".") }
    }
    var validAppearance: Bool {
        Self.validHex(colorHex) && (backgroundHex.map(Self.validHex) ?? true) && size.isFinite && (0.2...1).contains(size)
    }
}
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
    // Schema 7. Optional so schema 6 files decode unchanged.
    var style: RPGCellStyle?
    var fit: RPGContentFit?
    var paused: Bool?
    var contentValid: Bool {
        switch kind {
        case .image, .video, .gif: return !mediaID.isEmpty && (style?.validAppearance ?? true)
        case .icon:
            guard let style, style.validAppearance else { return false }
            return mediaID.isEmpty ? RPGCellStyle.validSymbol(style.value) : style.value.isEmpty
        case .number:
            guard let style, style.validAppearance else { return false }
            return mediaID.isEmpty && RPGCellStyle.validNumber(style.value)
        case .text:
            guard let style, style.validAppearance else { return false }
            return mediaID.isEmpty && (1...64).contains(style.value.count) && style.value.filter(\.isNewline).count <= 2
        }
    }
    var valid: Bool {
        !id.isEmpty && id.count<=128 && contentValid && mediaID.count<=512 && (coverMediaID?.count ?? 0)<=512 && scale.isFinite && (0.1...8).contains(scale) &&
        [anchorX, anchorY, cropX, cropY, cropWidth, cropHeight].allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        cropWidth > 0 && cropHeight > 0 && cropX + cropWidth <= 1.000001 && cropY + cropHeight <= 1.000001
    }
}
struct RPGPlayerState: Codable, Equatable, Sendable {
    var surface = SurfacePoint(x: 16, z: 16)
    var side: SidePlacement?
    var health = 100
    var stamina = 100
    var facing = RPGDirection()
    var weapon = RPGEquipment.none
    var armor = RPGEquipment.none
    var perspective = RPGPerspective.topDown
    var mode = RPGGameMode.adventure
    var inCombat = false
    var mediaBindingID: String?
}
/// Pure state. Seed/generator identity is distinct from file schema identity.
struct WorldState: Codable, Equatable, Sendable {
    static let currentSchema = 8
    var schemaVersion = 8
    var generatorVersion = 1
    var id = UUID().uuidString
    var seed: UInt64
    var revision: UInt64 = 0
    var player = RPGPlayerState()
    var combat = RPGCombatState()
    var story = RPGStoryState()
    var behaviors = RPGBehaviorState()
    var entities: [WorldEntity] = []
    var mediaBindings: [MediaBinding] = []
    var sideRegions: [SideRegion] = []
    var generated = false
    var videoBudget = 2
    var backgroundBindingIDs: [String] = []
    var parentWorldID: String?
    var isCreativeCopy = false
    var removedGeneratedIDs: [String] = []
    var damage: [String: Int] = [:]
    var inventory: [String: Int] = ["wood": 12, "stone": 8]
    var undo: [RPGEditTransaction] = []
    var redo: [RPGEditTransaction] = []
    var events: [RPGWorldEvent] = []
    /// Schema 8: map-editor terrain edits, "x,z" -> terrain. Optional so
    /// schema 7 files decode unchanged; nil means the generated terrain.
    var terrainOverrides: [String: RPGTerrain]?
    init(seed: UInt64 = 20261102) { self.seed = seed }
    func validate() throws {
        guard schemaVersion == Self.currentSchema, generatorVersion == 1 else { throw RPGWorldError.unsupportedVersion }
        guard !id.isEmpty, id.count <= 128, revision <= UInt64.max - 65536, player.surface.valid, (0...100).contains(player.health), (0...100).contains(player.stamina),
              entities.count <= 65536, mediaBindings.count <= 1024, sideRegions.count <= 64 else { throw RPGWorldError.invalidState }
        guard Set(entities.map(\.id)).count == entities.count, Set(mediaBindings.map(\.id)).count == mediaBindings.count,
              Set(sideRegions.map(\.id)).count == sideRegions.count else { throw RPGWorldError.duplicateIdentity }
        guard mediaBindings.allSatisfy(\.valid), sideRegions.allSatisfy(\.valid) else { throw RPGWorldError.invalidState }
        guard removedGeneratedIDs.count <= 65536, Set(removedGeneratedIDs).count == removedGeneratedIDs.count,
              damage.count <= 65536, damage.values.allSatisfy({ (0...10000).contains($0) }),
              inventory.count <= 128, inventory.values.allSatisfy({ (0...1000000).contains($0) }),
              undo.count <= RPGWorldEditing.undoLimit, redo.count <= RPGWorldEditing.undoLimit, events.count <= 256, Set(events.map(\.id)).count == events.count,
              events.allSatisfy({ !$0.id.isEmpty && $0.id.count<=512 && !$0.kind.isEmpty && $0.kind.count<=128 && $0.entityID.count<=128 && $0.definitionID.count<=128 }),
              (undo + redo).allSatisfy({ !$0.id.isEmpty && (!$0.changes.isEmpty || !($0.terrainChanges ?? []).isEmpty) && $0.changes.count <= RPGWorldEditing.maximumBatch && ($0.terrainChanges ?? []).count <= RPGWorldEditing.maximumBatch && ($0.terrainChanges ?? []).allSatisfy({ $0.point.valid }) && Set($0.changes.map(\.id)).count == $0.changes.count && $0.changes.allSatisfy { change in (change.before == nil || change.before?.id == change.id) && (change.after == nil || change.after?.id == change.id) } }),
              !isCreativeCopy || parentWorldID != nil,
              (terrainOverrides ?? [:]).count <= 65536, (terrainOverrides ?? [:]).keys.allSatisfy({ RPGWorldTerrain.point($0) != nil }) else { throw RPGWorldError.invalidState }
        guard combat.valid, player.facing.valid, player.weapon != .stoneArmor, player.armor != .moonBlade else { throw RPGWorldError.invalidState }
        try story.validate()
        try behaviors.validate(graphIDs:Set(([RPGOfficialStory.graph]+story.customGraphs).map(\.id)))
        let bindings = Set(mediaBindings.map(\.id))
        guard (0...2).contains(videoBudget), backgroundBindingIDs.count <= 3, Set(backgroundBindingIDs).count == backgroundBindingIDs.count,
              backgroundBindingIDs.allSatisfy({ bindings.contains($0) }), mediaBindings.filter({ !$0.muted }).count <= 1 else { throw RPGWorldError.invalidState }
        func validSide(_ side: SidePlacement) -> Bool {
            guard let region = sideRegions.first(where: { $0.id == side.regionID }) else { return false }
            return (0..<region.width).contains(side.horizontal) && (0..<64).contains(side.height)
        }
        if let side = player.side, !validSide(side) { throw RPGWorldError.invalidProjection }
        if player.perspective == .side && player.side == nil { throw RPGWorldError.invalidProjection }
        if let binding = player.mediaBindingID, !bindings.contains(binding) { throw RPGWorldError.missingReference }
        for enemy in combat.enemies {
            guard !entities.contains(where: { $0.id == enemy.id }) else { throw RPGWorldError.duplicateIdentity }
            if let p = enemy.surface, !p.valid { throw RPGWorldError.invalidState }
            if let p = enemy.side, !validSide(p) { throw RPGWorldError.invalidProjection }
            switch enemy.scope {
            case .topDownOnly: guard enemy.surface != nil && enemy.side == nil else { throw RPGWorldError.invalidProjection }
            case .sideOnly: guard enemy.surface == nil && enemy.side != nil else { throw RPGWorldError.invalidProjection }
            case .shared:
                guard let p = enemy.surface, let side = enemy.side, let region = sideRegions.first(where: { $0.id == side.regionID }), region.contains(p), side.horizontal == p.x - region.origin.x else { throw RPGWorldError.invalidProjection }
            }
        }
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
