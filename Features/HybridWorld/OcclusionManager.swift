import Foundation

// Roof and wall visibility, per building. Hiding a mesh never removes its
// collision box. Decisions are tags ("<group>|roof", "<group>|south", …),
// so the renderer can merge each building's roof and each wall side into a
// few meshes instead of one object per block.
//
// Inside a building: pixel mode hard-cuts the roof; both modes fade the
// walls on the camera side. Outside: any building between the camera and
// the player is x-rayed (pixel: roof cut, walls faded; 3D: roof and walls
// faded), so neither view loses the player behind a house.

struct BuildingOccluder: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int
    /// Bottom of the roof (absolute height). The player below this, inside the footprint, is indoors.
    var interiorCeiling: Double
    var floorIndex: Int
    /// The building's `BuildingGroup`; its roof and wall blocks carry this group id.
    var groupID: String
    /// Highest point of the roof, for the x-ray test.
    var roofTop: Double
    /// Ground under the building.
    var base: Double

    init(id: String, name: String, minX: Int, maxX: Int, minY: Int, maxY: Int, interiorCeiling: Double, floorIndex: Int = 0, groupID: String, roofTop: Double, base: Double = 0) {
        self.id = id; self.name = name; self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
        self.interiorCeiling = interiorCeiling; self.floorIndex = floorIndex; self.groupID = groupID; self.roofTop = roofTop; self.base = base
    }

    private enum CodingKeys: String, CodingKey { case id, name, minX, maxX, minY, maxY, interiorCeiling, floorIndex, groupID, roofTop, base }

    /// The first hybrid slice saved id lists instead of a group; those occluders decode and are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        minX = try c.decode(Int.self, forKey: .minX); maxX = try c.decode(Int.self, forKey: .maxX)
        minY = try c.decode(Int.self, forKey: .minY); maxY = try c.decode(Int.self, forKey: .maxY)
        interiorCeiling = try c.decode(Double.self, forKey: .interiorCeiling)
        floorIndex = try c.decodeIfPresent(Int.self, forKey: .floorIndex) ?? 0
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        roofTop = try c.decodeIfPresent(Double.self, forKey: .roofTop) ?? interiorCeiling + 1
        base = try c.decodeIfPresent(Double.self, forKey: .base) ?? 0
    }

    var valid: Bool {
        !id.isEmpty && id.count <= 64 && (1...64).contains(name.count) && minX <= maxX && minY <= maxY &&
            (0..<WorldGeometry.width).contains(minX) && (0..<WorldGeometry.width).contains(maxX) &&
            (0..<WorldGeometry.width).contains(minY) && (0..<WorldGeometry.width).contains(maxY) &&
            interiorCeiling.isFinite && interiorCeiling > 0 && interiorCeiling <= SpatialBlock.maximumHeight &&
            roofTop.isFinite && roofTop >= interiorCeiling && roofTop <= SpatialBlock.maximumHeight + 4 &&
            base.isFinite && (SpatialBlock.lowestElevation...SpatialBlock.maximumHeight).contains(base) &&
            (0...8).contains(floorIndex) && groupID.count <= 128
    }

    /// Which wall side a cell of the footprint edge is on (corners go to south / north).
    func side(x: Int, y: Int) -> BuildingSide? {
        if y == minY { return .south }
        if y == maxY { return .north }
        if x == minX { return .west }
        if x == maxX { return .east }
        return nil
    }
}

struct HybridWorldSave: Codable, Equatable, Sendable {
    var schema = 1
    var viewMode: WorldViewMode
    var regionColumn: Int
    var regionRow: Int
    var occluders: [BuildingOccluder]

    static func centralFocus(mode: WorldViewMode) -> HybridWorldSave {
        HybridWorldSave(viewMode: mode, regionColumn: 7, regionRow: 7, occluders: [])
    }

    var valid: Bool {
        schema == 1 && (0..<HybridWorldScale.regionsAlongEdge).contains(regionColumn) && (0..<HybridWorldScale.regionsAlongEdge).contains(regionRow) &&
            occluders.count <= 48 && occluders.allSatisfy(\.valid) && Set(occluders.map(\.id)).count == occluders.count
    }
}

enum OcclusionTag {
    static func roof(_ group: String) -> String { group + "|roof" }
    static func wall(_ group: String, _ side: BuildingSide) -> String { group + "|" + side.rawValue }
    static func walls(_ group: String) -> [String] { BuildingSide.allCases.map { wall(group, $0) } }

    /// The tag a roof or wall block draws under, nil for anything else.
    static func of(_ block: SpatialBlock, occluders: [String: BuildingOccluder]) -> String? {
        guard let part = block.hybridPart, part == .roof || part == .wall, let group = block.groupID, let building = occluders[group] else { return nil }
        if part == .roof { return roof(group) }
        return wall(group, building.side(x: block.x, y: block.y) ?? .south)
    }
}

struct OcclusionDecision: Equatable, Sendable {
    /// Tags drawn not at all.
    var hidden: Set<String> = []
    /// Tags drawn faint.
    var faded: Set<String> = []
}

enum OcclusionManager {
    /// Visual only, and O(buildings): runs every frame. Callers keep the same block list for physics.
    static func resolve(player: SpatialVector, cameraEye: SpatialVector, mode: WorldViewMode, buildings: [BuildingOccluder]) -> OcclusionDecision {
        var decision = OcclusionDecision()
        let head = SpatialVector(player.x, player.y, player.z + 1.2)
        for building in buildings where !building.groupID.isEmpty {
            let group = building.groupID
            if contains(player, building) && player.z < building.interiorCeiling - 0.15 && player.z >= building.base - 0.5 {
                if mode == .pixelRPG { decision.hidden.insert(OcclusionTag.roof(group)) }
                for side in facing(cameraEye, player: player, mode: mode) { decision.faded.insert(OcclusionTag.wall(group, side)) }
            } else if blocksView(from: cameraEye, to: head, building) {
                if mode == .pixelRPG { decision.hidden.insert(OcclusionTag.roof(group)) } else { decision.faded.insert(OcclusionTag.roof(group)) }
                decision.faded.formUnion(OcclusionTag.walls(group))
            }
        }
        return decision
    }

    static func contains(_ player: SpatialVector, _ building: BuildingOccluder) -> Bool {
        player.x >= Double(building.minX) - 0.05 && player.x < Double(building.maxX) + 1.05 &&
            player.y >= Double(building.minY) - 0.05 && player.y < Double(building.maxY) + 1.05
    }

    /// Pixel mode fades the south face (the side the overhead camera sees first),
    /// or the north face if the camera has swung round. 3D fades every side facing the camera.
    private static func facing(_ eye: SpatialVector, player: SpatialVector, mode: WorldViewMode) -> [BuildingSide] {
        let toEye = (eye.x - player.x, eye.y - player.y)
        if mode == .pixelRPG { return [toEye.1 <= 0 ? .south : .north] }
        return BuildingSide.allCases.filter { side in
            let n = side.normal
            return n.x * toEye.0 + n.y * toEye.1 > 0
        }
    }

    /// Segment–box test (slab method) between the eye and the player's head.
    static func blocksView(from eye: SpatialVector, to target: SpatialVector, _ building: BuildingOccluder) -> Bool {
        // The box includes the one-cell eaves overhang.
        let lo = (Double(building.minX) - 1, Double(building.minY) - 1, building.base)
        let hi = (Double(building.maxX) + 2, Double(building.maxY) + 2, building.roofTop)
        let d = (target.x - eye.x, target.y - eye.y, target.z - eye.z)
        var t0 = 0.0, t1 = 1.0
        for (origin, delta, low, high) in [(eye.x, d.0, lo.0, hi.0), (eye.y, d.1, lo.1, hi.1), (eye.z, d.2, lo.2, hi.2)] {
            if abs(delta) < 1e-9 {
                if origin < low || origin > high { return false }
                continue
            }
            var a = (low - origin) / delta, b = (high - origin) / delta
            if a > b { (a, b) = (b, a) }
            t0 = max(t0, a); t1 = min(t1, b)
            if t0 > t1 { return false }
        }
        // Ignore a touch right at the player (standing against the wall outside).
        return t0 < 0.97
    }
}
