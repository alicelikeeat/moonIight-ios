import Foundation

/// v1.86: each continent region's world in its own file (Application
/// Support/MoonlightRegions). The open region lives in the main save as
/// before; a region is written here when the player leaves it.
enum RegionArchive {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MoonlightRegions", isDirectory: true)
    }

    static func url(_ address: RegionAddress) -> URL { folder.appendingPathComponent(RegionTravel.archiveName(address)) }

    static func save(_ world: SpatialWorld, at address: RegionAddress) throws {
        var stored = world
        stored.history = SpatialHistory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url(address), options: .atomic)
    }

    static func load(_ address: RegionAddress) -> SpatialWorld? {
        guard let data = try? Data(contentsOf: url(address)) else { return nil }
        return try? JSONDecoder().decode(SpatialWorld.self, from: data)
    }

    /// Regions with a saved world (visited before).
    static func saved() -> Set<RegionAddress> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var result = Set<RegionAddress>()
        for name in names where name.hasPrefix("region-") && name.hasSuffix(".json") {
            let parts = name.dropFirst("region-".count).dropLast(".json".count).split(separator: "-")
            if parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]) {
                let address = RegionAddress(column: c, row: r)
                if address.valid { result.insert(address) }
            }
        }
        return result
    }
}
