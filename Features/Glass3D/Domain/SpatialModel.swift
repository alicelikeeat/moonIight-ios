import Foundation

// V2.8 2.5D glass world. The same WorldState as the 2D sandbox gains a
// `spatial` part (schema 11): free-height glass blocks, building groups,
// motion, plants, creatures, bosses, pickups and the generator record.
// Coordinates: x, y are map cells (0..<256, y == the 2D map's z); z is
// height in cell units. Everything here is pure and unit tested.

struct SpatialVector: Codable, Equatable, Hashable, Sendable {
    var x: Double, y: Double, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static let zero = SpatialVector(0, 0, 0)
    static func + (a: Self, b: Self) -> Self { .init(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Self, b: Self) -> Self { .init(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Self, k: Double) -> Self { .init(a.x * k, a.y * k, a.z * k) }
    var flatLength: Double { (x * x + y * y).squareRoot() }
    var finite: Bool { x.isFinite && y.isFinite && z.isFinite }
    static func lerp(_ a: Self, _ b: Self, _ t: Double) -> Self { a + (b - a) * t }
}

/// Glass look per block. Every quality level keeps it translucent.
struct SpatialGlass: Codable, Equatable, Hashable, Sendable {
    /// 6-digit hex tint, nil for clear glass.
    var tintHex: String?
    /// 0.1 (almost clear) … 0.9 (dense glass).
    var density = 0.35
    var frosted = false
    var glow = false
    var valid: Bool { (tintHex.map { $0.count == 6 && $0.allSatisfy(\.isHexDigit) } ?? true) && density.isFinite && (0.1...0.9).contains(density) }
    static let clear = SpatialGlass()
    static func tinted(_ hex: String, density: Double = 0.45) -> SpatialGlass { SpatialGlass(tintHex: hex, density: density) }
}

enum SpatialCollision: String, Codable, CaseIterable, Sendable {
    /// Blocks movement on every side.
    case solid
    /// Decoration: no collision.
    case decor
    /// Media display surface: no collision.
    case media
    /// Stand on it from above, pass through from below and the sides.
    case oneWay
    /// Trigger area: no collision, fires events when the player enters.
    case trigger
    var title: String {
        switch self {
        case .solid: L10n.t("实体", "Solid")
        case .decor: L10n.t("装饰（无碰撞）", "Decor (no collision)")
        case .media: L10n.t("媒体展示面", "Media Surface")
        case .oneWay: L10n.t("单向平台", "One-way Platform")
        case .trigger: L10n.t("触发区域", "Trigger Area")
        }
    }
    var blocksSides: Bool { self == .solid }
    var supports: Bool { self == .solid || self == .oneWay }
}

enum SpatialFace: String, Codable, CaseIterable, Sendable {
    case top, front, side
    var title: String {
        switch self { case .top: L10n.t("顶面", "Top"); case .front: L10n.t("正面", "Front"); case .side: L10n.t("侧面", "Side") }
    }
}

/// Media on a block face; a media grid piece carries its region.
struct SpatialMedia: Codable, Equatable, Hashable, Sendable {
    var bindingID: String
    var face = SpatialFace.top
    var region: RPGMediaRegion?
}

/// Where an object came from: the generator replaces only its own objects
/// when run again; user-made and user-edited objects are kept.
enum SpatialOrigin: String, Codable, Sendable { case user, generated }

/// One free-height glass block. Several may share a cell at any heights.
struct SpatialBlock: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var x: Int
    var y: Int
    /// Bottom height (free, not stepped).
    var elevation: Double
    var thickness: Double = 1
    /// Footprint side in cells (0.2…1).
    var size: Double = 1
    /// Turn around the vertical axis, degrees.
    var yaw: Double = 0
    var glass = SpatialGlass.clear
    var collision = SpatialCollision.solid
    var media: SpatialMedia?
    var groupID: String?
    var origin = SpatialOrigin.user
    /// A button block toggles its target group's motion when touched.
    var buttonTarget: String?

    var top: Double { elevation + thickness }
    static let maximumHeight = 64.0
    var valid: Bool {
        !id.isEmpty && id.count <= 128 && (0..<WorldGeometry.width).contains(x) && (0..<WorldGeometry.width).contains(y) &&
            elevation.isFinite && (-1...Self.maximumHeight).contains(elevation) && thickness.isFinite && (0.05...16).contains(thickness) &&
            size.isFinite && (0.2...1).contains(size) && yaw.isFinite && glass.valid && (media?.region?.valid ?? true)
    }
}

/// Blocks that move, copy and turn together.
struct BuildingGroup: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var motionID: String?
    var origin = SpatialOrigin.user
    var template: String?
}

/// A saved arrangement of blocks relative to its first block.
struct BuildingTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var blocks: [SpatialBlock]
}

// MARK: Ecology

enum PlantKind: String, Codable, CaseIterable, Sendable {
    case grass, flower, bush, tree, glow
    var title: String {
        switch self {
        case .grass: L10n.t("草丛", "Grass"); case .flower: L10n.t("花朵", "Flower"); case .bush: L10n.t("灌木", "Bush")
        case .tree: L10n.t("树木", "Tree"); case .glow: L10n.t("发光植物", "Glow Plant")
        }
    }
    /// Trees and bushes block walking; the rest are walk-through.
    var solid: Bool { self == .tree || self == .bush }
}

struct PlantEntity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: PlantKind
    var x: Int
    var y: Int
    var z: Double
    var scale = 1.0
    var hue = 0.33
    var origin = SpatialOrigin.user
}

enum CreatureKind: String, Codable, CaseIterable, Sendable {
    case neutral, enemy, guardian, miniBoss, boss
    var title: String {
        switch self {
        case .neutral: L10n.t("中立生物", "Neutral Creature"); case .enemy: L10n.t("普通敌人", "Enemy"); case .guardian: L10n.t("守卫", "Guard")
        case .miniBoss: L10n.t("小 Boss", "Mini Boss"); case .boss: L10n.t("大 Boss", "Boss")
        }
    }
    var hostile: Bool { self != .neutral }
    var isBoss: Bool { self == .miniBoss || self == .boss }
}

enum CreatureState: String, Codable, Sendable {
    case idle, wander, patrol, alert, chase, attack, returning, hurt, dead
}

struct CreatureEntity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: CreatureKind
    var position: SpatialVector
    var home: SpatialVector
    var health: Int
    var maxHealth: Int
    var damage: Int
    var state = CreatureState.idle
    /// Seconds until the next attack may start.
    var cooldown = 0.0
    /// Telegraph: seconds until a wound-up attack lands (nil: none).
    var windUp: Double?
    var phase = 1
    var stateTime = 0.0
    var origin = SpatialOrigin.user
    // v1.60 (optional, so earlier saves open unchanged).
    /// Media character shown for this creature.
    var characterID: String?
    /// Boss phase script driving its skills.
    var bossScriptID: String?
    var statuses: [StatusEffect]?
    var valid: Bool { !id.isEmpty && id.count <= 128 && position.finite && home.finite && (0...100_000).contains(health) && maxHealth > 0 && health <= maxHealth && (0...1000).contains(damage) }
    var alive: Bool { state != .dead && health > 0 }
}

/// A chest or reward on the map.
struct PickupEntity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var position: SpatialVector
    var shards: Int
    var collected = false
    var origin = SpatialOrigin.user
}

// MARK: World

/// The whole 2.5D layer. Empty by default: a new world is a sheet of clear
/// glass with a safe spawn, nothing else (task 3.2).
struct SpatialWorld: Codable, Equatable, Sendable {
    static let blockLimit = 30_000
    var blocks: [SpatialBlock] = []
    var groups: [BuildingGroup] = []
    var motions: [SpatialMotion] = []
    var plants: [PlantEntity] = []
    var creatures: [CreatureEntity] = []
    var pickups: [PickupEntity] = []
    var templates: [BuildingTemplate] = []
    var spawn = SpatialVector(128.5, 128.5, 0)
    var player = SpatialPlayer()
    var generation: SpatialGenerationRecord?
    var history = SpatialHistory()
    /// Seconds of world time; motion and media use this one clock.
    var clock = 0.0
    // v1.60 (optional, so earlier saves open unchanged).
    var characters: [CharacterTemplate]?
    var skills: [SkillDefinition]?
    var bossScripts: [BossScript]?
    /// The player's media character and skill hotbar (skill ids).
    var playerCharacterID: String?
    var hotbar: [String]?

    static func blank() -> SpatialWorld { SpatialWorld() }

    func validate(bindings: Set<String>) throws {
        guard blocks.count <= Self.blockLimit, plants.count <= 20_000, creatures.count <= 2_000, pickups.count <= 2_000,
              groups.count <= 4_000, motions.count <= 2_000, templates.count <= 200 else { throw RPGWorldError.oversized }
        guard Set(blocks.map(\.id)).count == blocks.count, Set(groups.map(\.id)).count == groups.count, Set(motions.map(\.id)).count == motions.count,
              Set(plants.map(\.id)).count == plants.count, Set(creatures.map(\.id)).count == creatures.count, Set(pickups.map(\.id)).count == pickups.count
        else { throw RPGWorldError.duplicateIdentity }
        let groupIDs = Set(groups.map(\.id)), motionIDs = Set(motions.map(\.id))
        guard blocks.allSatisfy({ $0.valid && ($0.groupID.map(groupIDs.contains) ?? true) && ($0.buttonTarget.map(groupIDs.contains) ?? true) }),
              groups.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 128 && $0.name.count <= 64 && ($0.motionID.map(motionIDs.contains) ?? true) }),
              motions.allSatisfy(\.valid), plants.allSatisfy({ $0.z.isFinite && $0.scale.isFinite && (0..<256).contains($0.x) && (0..<256).contains($0.y) }),
              creatures.allSatisfy(\.valid), pickups.allSatisfy({ $0.position.finite && (0...10_000).contains($0.shards) }),
              spawn.finite, player.valid, clock.isFinite, clock >= 0
        else { throw RPGWorldError.invalidState }
        for block in blocks { if let media = block.media, !bindings.contains(media.bindingID) { throw RPGWorldError.missingReference } }
        let characterList = characters ?? [], skillList = skills ?? [], scripts = bossScripts ?? []
        guard characterList.count <= 200, skillList.count <= 200, scripts.count <= 50, (hotbar ?? []).count <= 6,
              characterList.allSatisfy(\.valid), skillList.allSatisfy(\.valid), scripts.allSatisfy(\.valid),
              Set(characterList.map(\.id)).count == characterList.count, Set(skillList.map(\.id)).count == skillList.count else { throw RPGWorldError.invalidState }
        let characterIDs = Set(characterList.map(\.id)), scriptIDs = Set(scripts.map(\.id))
        guard playerCharacterID.map(characterIDs.contains) ?? true,
              creatures.allSatisfy({ ($0.characterID.map(characterIDs.contains) ?? true) && ($0.bossScriptID.map(scriptIDs.contains) ?? true) && ($0.statuses ?? []).count <= 6 }) else { throw RPGWorldError.missingReference }
        for clip in characterList.flatMap({ $0.clips.values }) { for id in clip.bindingIDs where !bindings.contains(id) { throw RPGWorldError.missingReference } }
        try history.validate()
    }
}

/// The player body in the 2.5D world (health and stamina stay on the
/// shared RPG player).
struct SpatialPlayer: Codable, Equatable, Sendable {
    var position = SpatialVector(128.5, 128.5, 0)
    var verticalSpeed = 0.0
    var grounded = true
    var facing = 0.0
    var lastSafe = SpatialVector(128.5, 128.5, 0)
    var valid: Bool { position.finite && lastSafe.finite && verticalSpeed.isFinite && facing.isFinite }
}

/// Generator settings and version, saved with the world so a reload shows
/// what the user saw instead of regenerating over their edits.
struct SpatialGenerationRecord: Codable, Equatable, Sendable {
    var configuration: WorldGenerationConfiguration
    var version: Int
    var attempts: Int
}

// MARK: Undo history (2.5D edits)

struct SpatialChange<Value: Codable & Equatable & Sendable & Identifiable>: Codable, Equatable, Sendable where Value.ID == String {
    var id: String
    var before: Value?
    var after: Value?
}

/// One undoable 2.5D edit: every object it touched, before and after.
struct SpatialDiff: Codable, Equatable, Sendable {
    var title: String
    var blocks: [SpatialChange<SpatialBlock>] = []
    var groups: [SpatialChange<BuildingGroup>] = []
    var motions: [SpatialChange<SpatialMotion>] = []
    var plants: [SpatialChange<PlantEntity>] = []
    var creatures: [SpatialChange<CreatureEntity>] = []
    var pickups: [SpatialChange<PickupEntity>] = []
    var templates: [SpatialChange<BuildingTemplate>] = []
    var generationBefore: SpatialGenerationRecord?
    var generationAfter: SpatialGenerationRecord?

    var size: Int { blocks.count + groups.count + motions.count + plants.count + creatures.count + pickups.count + templates.count }
    var isEmpty: Bool { size == 0 && generationBefore == generationAfter }

    static func between(_ old: SpatialWorld, _ new: SpatialWorld, title: String) -> SpatialDiff {
        func changes<V>(_ a: [V], _ b: [V]) -> [SpatialChange<V>] where V: Codable & Equatable & Sendable & Identifiable, V.ID == String {
            let before = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let after = Dictionary(b.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var result: [SpatialChange<V>] = []
            for item in a where after[item.id] != item { result.append(.init(id: item.id, before: item, after: after[item.id])) }
            for item in b where before[item.id] == nil { result.append(.init(id: item.id, before: nil, after: item)) }
            return result
        }
        return SpatialDiff(title: title, blocks: changes(old.blocks, new.blocks), groups: changes(old.groups, new.groups),
                           motions: changes(old.motions, new.motions), plants: changes(old.plants, new.plants),
                           creatures: changes(old.creatures, new.creatures), pickups: changes(old.pickups, new.pickups),
                           templates: changes(old.templates, new.templates),
                           generationBefore: old.generation, generationAfter: new.generation)
    }

    /// Applies (or reverts) this diff to `world`.
    func apply(to world: inout SpatialWorld, inverse: Bool) {
        func patch<V>(_ list: inout [V], _ changes: [SpatialChange<V>]) where V: Codable & Equatable & Sendable & Identifiable, V.ID == String {
            guard !changes.isEmpty else { return }
            var index = Dictionary(list.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            var removed = Set<String>()
            for change in changes {
                let target = inverse ? change.before : change.after
                if let target {
                    if let i = index[change.id] { list[i] = target } else { list.append(target); index[change.id] = list.count - 1 }
                    removed.remove(change.id)
                } else { removed.insert(change.id) }
            }
            if !removed.isEmpty { list.removeAll { removed.contains($0.id) } }
        }
        patch(&world.blocks, blocks); patch(&world.groups, groups); patch(&world.motions, motions)
        patch(&world.plants, plants); patch(&world.creatures, creatures); patch(&world.pickups, pickups); patch(&world.templates, templates)
        world.generation = inverse ? generationBefore : generationAfter
    }
}

/// Undo and redo for 2.5D edits: at least 50 steps, within a change budget
/// so a large generation does not bloat the save.
struct SpatialHistory: Codable, Equatable, Sendable {
    static let limit = 50
    static let changeBudget = 60_000
    var undo: [SpatialDiff] = []
    var redo: [SpatialDiff] = []

    mutating func push(_ diff: SpatialDiff) {
        guard !diff.isEmpty else { return }
        undo.append(diff); redo = []
        trim()
    }
    mutating func trim() {
        while undo.count > Self.limit { undo.removeFirst() }
        while undo.count > 1, undo.reduce(0, { $0 + $1.size }) > Self.changeBudget { undo.removeFirst() }
    }
    func validate() throws {
        guard undo.count <= Self.limit, redo.count <= Self.limit else { throw RPGWorldError.invalidState }
    }
}

extension SpatialWorld {
    /// Commits an edit as one undoable step.
    mutating func edit(_ title: String, _ body: (inout SpatialWorld) throws -> Void) rethrows {
        var next = self
        next.history = SpatialHistory()
        try body(&next)
        let diff = SpatialDiff.between(self, next, title: title)
        guard !diff.isEmpty else { return }
        var history = self.history
        history.push(diff)
        next.history = history
        self = next
    }
    @discardableResult mutating func undoLast() -> String? {
        guard let diff = history.undo.popLast() else { return nil }
        diff.apply(to: &self, inverse: true); history.redo.append(diff); return diff.title
    }
    @discardableResult mutating func redoLast() -> String? {
        guard let diff = history.redo.popLast() else { return nil }
        diff.apply(to: &self, inverse: false); history.undo.append(diff); return diff.title
    }
}

// MARK: Spatial index

/// Blocks by cell for collision and picking. Rebuilt after edits; moving
/// blocks are looked up separately with their current offset.
struct SpatialIndex: Sendable {
    private var cells: [Int: [Int]] = [:]
    let blocks: [SpatialBlock]
    let moving: Set<String>

    init(blocks: [SpatialBlock], movingGroups: Set<String> = []) {
        self.blocks = blocks
        var moving = Set<String>()
        for (index, block) in blocks.enumerated() {
            if let group = block.groupID, movingGroups.contains(group) { moving.insert(block.id) }
            cells[block.y * WorldGeometry.width + block.x, default: []].append(index)
        }
        self.moving = moving
    }

    func blocks(atX x: Int, y: Int) -> [SpatialBlock] {
        guard (0..<WorldGeometry.width).contains(x), (0..<WorldGeometry.width).contains(y) else { return [] }
        return (cells[y * WorldGeometry.width + x] ?? []).map { blocks[$0] }
    }
}
