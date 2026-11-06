import Foundation

// Hybrid open world (V2 slice). The live map is still one 256×256
// `WorldGeometry` region — the same unit saves, physics and World Director
// already use. A 4096×4096 continent is an index of those regions, not a
// wider `SpatialBlock` coordinate. Branch worlds keep their own ids.

enum HybridWorldScale {
    /// Matches `WorldGeometry.width`. Do not retarget block coordinates at the continent size.
    static let regionSide = 256
    static let regionsAlongEdge = 16
    /// Logical continent. Not loaded as one mesh.
    static let continentSide = 4096
    /// Same streaming chunk the current ground and culling already use.
    static let streamChunk = 32
    static var logicalChunkCount: Int { (continentSide / streamChunk) * (continentSide / streamChunk) }

    static func matchesLegacyMap() -> Bool {
        regionSide == WorldGeometry.width && streamChunk == WorldGeometry.chunkSide && continentSide == regionSide * regionsAlongEdge && logicalChunkCount == 16_384
    }
}

enum WorldNodeKind: String, Codable, Sendable {
    case main, region, branch
}

struct WorldNodeID: Codable, Hashable, Sendable {
    var kind: WorldNodeKind
    var key: String
    var raw: String { "\(kind.rawValue):\(key)" }
    var valid: Bool { !key.isEmpty && key.count <= 64 && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
}

struct RegionAddress: Codable, Hashable, Sendable {
    var column: Int
    var row: Int
    var valid: Bool { (0..<HybridWorldScale.regionsAlongEdge).contains(column) && (0..<HybridWorldScale.regionsAlongEdge).contains(row) }
    var originX: Int { column * HybridWorldScale.regionSide }
    var originY: Int { row * HybridWorldScale.regionSide }
}

/// A cell on the logical continent. Local block coordinates stay inside one region.
struct GlobalCell: Hashable, Sendable {
    var x: Int
    var y: Int
    var valid: Bool { (0..<HybridWorldScale.continentSide).contains(x) && (0..<HybridWorldScale.continentSide).contains(y) }
}

struct WorldRegionRecord: Codable, Equatable, Sendable, Identifiable {
    var id: WorldNodeID
    var name: String
    var address: RegionAddress
    /// Geometry exists in this build. Stubs are indexed so later regions can plug in.
    var authored: Bool
    var landmark: String?
    var identifier: String { id.raw }
}

struct WorldBranchRecord: Codable, Equatable, Sendable, Identifiable {
    var id: WorldNodeID
    var title: String
    /// Independent save. Not a second copy of the continent coordinates.
    var saveKey: String
    var identifier: String { id.raw }
}

struct WorldLink: Codable, Equatable, Sendable {
    var from: WorldNodeID
    var to: WorldNodeID
    /// "road" stays on the continent. "portal" enters a branch world.
    var kind: String
}

struct WorldGraph: Codable, Equatable, Sendable {
    var main: WorldNodeID
    var regions: [WorldRegionRecord]
    var branches: [WorldBranchRecord]
    var links: [WorldLink]

    static let mainKey = "moonlight-continent"

    /// The slice's continent index: one authored hub, named region stubs, the rest reserved.
    static func continentIndex() -> WorldGraph {
        let named: [RegionAddress: (key: String, name: String, landmark: String?, authored: Bool)] = [
            RegionAddress(column: 7, row: 7): ("central-town", "月光中央城", "月光尖塔", true),
            RegionAddress(column: 7, row: 9): ("spirit-forest", "精灵森林", "古树", false),
            RegionAddress(column: 9, row: 7): ("crystal-mountains", "水晶山脉", "晶峰", false),
            RegionAddress(column: 7, row: 5): ("ancient-castle", "古代王城", "王城门", false),
            RegionAddress(column: 5, row: 7): ("sky-isles", "天空群岛", "浮岛桥", false),
        ]
        var regions: [WorldRegionRecord] = []
        regions.reserveCapacity(HybridWorldScale.regionsAlongEdge * HybridWorldScale.regionsAlongEdge)
        for row in 0..<HybridWorldScale.regionsAlongEdge {
            for column in 0..<HybridWorldScale.regionsAlongEdge {
                let address = RegionAddress(column: column, row: row)
                if let spec = named[address] {
                    regions.append(WorldRegionRecord(id: WorldNodeID(kind: .region, key: spec.key), name: spec.name, address: address, authored: spec.authored, landmark: spec.landmark))
                } else {
                    let key = String(format: "c%02d-r%02d", column, row)
                    regions.append(WorldRegionRecord(id: WorldNodeID(kind: .region, key: key), name: "待接入区域", address: address, authored: false, landmark: nil))
                }
            }
        }
        let main = WorldNodeID(kind: .main, key: Self.mainKey)
        let town = WorldNodeID(kind: .region, key: "central-town")
        let abyss = WorldBranchRecord(id: WorldNodeID(kind: .branch, key: "shadow-abyss"), title: "暗影深渊", saveKey: "branch-shadow-abyss")
        var links = ["spirit-forest", "crystal-mountains", "ancient-castle", "sky-isles"].map { key in
            WorldLink(from: town, to: WorldNodeID(kind: .region, key: key), kind: "road")
        }
        links.append(WorldLink(from: town, to: abyss.id, kind: "portal"))
        return WorldGraph(main: main, regions: regions, branches: [abyss], links: links)
    }

    func problems() -> [String] {
        var problems: [String] = []
        if main.kind != .main || main.key != Self.mainKey || !main.valid { problems.append("main id") }
        if !HybridWorldScale.matchesLegacyMap() { problems.append("scale drifted from the 256 map") }
        if regions.count != HybridWorldScale.regionsAlongEdge * HybridWorldScale.regionsAlongEdge { problems.append("region count") }
        if Set(regions.map(\.id.raw)).count != regions.count { problems.append("duplicate region id") }
        if Set(regions.map(\.address)).count != regions.count { problems.append("duplicate address") }
        if regions.contains(where: { $0.id.kind != .region || !$0.id.valid || !$0.address.valid || $0.name.isEmpty || $0.name.count > 32 }) { problems.append("bad region") }
        if Set(regions.filter(\.authored).map(\.id.key)) != Set(["central-town"]) { problems.append("authored set") }
        if !regions.contains(where: { $0.id.key == "central-town" && $0.authored && $0.address == RegionAddress(column: 7, row: 7) && $0.name == "月光中央城" }) {
            problems.append("central town")
        }
        if branches.contains(where: { $0.id.kind != .branch || !$0.id.valid || $0.saveKey.isEmpty || $0.saveKey == main.key || $0.id.key == main.key }) {
            problems.append("branch")
        }
        if Set(branches.map(\.id.raw)).count != branches.count { problems.append("duplicate branch") }
        let known = Set(regions.map(\.id.raw) + branches.map(\.id.raw))
        if links.contains(where: { !known.contains($0.from.raw) || !known.contains($0.to.raw) || ($0.kind != "road" && $0.kind != "portal") }) {
            problems.append("link")
        }
        if !links.contains(where: { $0.kind == "portal" && $0.to.key == "shadow-abyss" }) { problems.append("abyss portal") }
        return problems
    }
}
