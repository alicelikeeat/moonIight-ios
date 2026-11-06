import Foundation

// Roof and wall visibility. Hiding a mesh does not remove its collision box.
// Pixel mode drops roofs with a hard cut. 3D mode keeps roofs and fades the
// wall facing the camera. Floors are separate groups so a later storey can
// plug in without making the whole building transparent.

struct BuildingOccluder: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var minX: Int
    var maxX: Int
    var minY: Int
    var maxY: Int
    /// Bottom of the roof. The player below this, inside the footprint, is indoors.
    var interiorCeiling: Double
    var floorIndex: Int
    var roofIDs: [String]
    var wallIDs: [String]

    var valid: Bool {
        !id.isEmpty && id.count <= 64 && (1...64).contains(name.count) && minX <= maxX && minY <= maxY &&
            (0..<WorldGeometry.width).contains(minX) && (0..<WorldGeometry.width).contains(maxX) &&
            (0..<WorldGeometry.width).contains(minY) && (0..<WorldGeometry.width).contains(maxY) &&
            interiorCeiling.isFinite && interiorCeiling > 0 && interiorCeiling <= SpatialBlock.maximumHeight &&
            (0...8).contains(floorIndex) && roofIDs.count <= 2_000 && wallIDs.count <= 4_000 &&
            roofIDs.allSatisfy { !$0.isEmpty && $0.count <= 128 } && wallIDs.allSatisfy { !$0.isEmpty && $0.count <= 128 }
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
            occluders.count <= 32 && occluders.allSatisfy(\.valid) && Set(occluders.map(\.id)).count == occluders.count
    }
}

struct OcclusionDecision: Equatable, Sendable {
    var hidden: Set<String> = []
    var faded: Set<String> = []
}

enum OcclusionManager {
    /// Visual only. Callers keep the same `SpatialBlock` list for physics.
    static func resolve(player: SpatialVector, cameraEye: SpatialVector, mode: WorldViewMode, buildings: [BuildingOccluder], blocks: [SpatialBlock]) -> OcclusionDecision {
        // Runs every frame: find the building first and only then index walls,
        // so walking outdoors does not scan the whole block list.
        let indoors = buildings.filter { contains(player, $0) && player.z < $0.interiorCeiling - 0.15 }
        guard !indoors.isEmpty else { return OcclusionDecision() }
        var decision = OcclusionDecision()
        let wanted = Set(indoors.flatMap(\.wallIDs))
        var wallsByID: [String: SpatialBlock] = [:]
        for block in blocks where block.hybridPart == .wall && wanted.contains(block.id) { wallsByID[block.id] = block }
        for building in indoors {
            if mode == .pixelRPG { decision.hidden.formUnion(building.roofIDs) }
            let walls = building.wallIDs.compactMap { wallsByID[$0] }
            decision.faded.formUnion(wallsFacing(cameraEye, player: player, building: building, walls: walls, mode: mode))
        }
        return decision
    }

    private static func contains(_ player: SpatialVector, _ building: BuildingOccluder) -> Bool {
        player.x >= Double(building.minX) - 0.05 && player.x < Double(building.maxX) + 1.05 &&
            player.y >= Double(building.minY) - 0.05 && player.y < Double(building.maxY) + 1.05
    }

    /// Pixel mode fades the south face (the side the fixed overhead camera sees first)
    /// unless the camera has swung mostly the other way. 3D fades every wall on the camera side of the player.
    private static func wallsFacing(_ eye: SpatialVector, player: SpatialVector, building: BuildingOccluder, walls: [SpatialBlock], mode: WorldViewMode) -> [String] {
        let toEye = (eye.x - player.x, eye.y - player.y)
        if mode == .pixelRPG {
            let south = toEye.1 <= 0
            return walls.compactMap { wall in
                let onSouth = wall.y == building.minY
                let onNorth = wall.y == building.maxY
                if south && onSouth { return wall.id }
                if !south && onNorth { return wall.id }
                return nil
            }
        }
        return walls.compactMap { wall in
            let toWall = (Double(wall.x) + 0.5 - player.x, Double(wall.y) + 0.5 - player.y)
            return toEye.0 * toWall.0 + toEye.1 * toWall.1 > 0 ? wall.id : nil
        }
    }
}
