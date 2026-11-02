import Foundation

enum RPGWorldCodec {
    static let maximumBytes = 16 * 1024 * 1024
    static func encode(_ state: WorldState) throws -> Data {
        try state.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= maximumBytes else { throw RPGWorldError.oversized }
        return data
    }
    static func decode(_ data: Data) throws -> WorldState {
        guard data.count <= maximumBytes else { throw RPGWorldError.oversized }
        struct Header: Decodable { let schemaVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        var migrated = data
        if version == 1 || version == 2 {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RPGWorldError.invalidState }
            object["schemaVersion"] = WorldState.currentSchema
            let defaults: [String: Any] = ["videoBudget": 2, "backgroundBindingIDs": [String](), "removedGeneratedIDs": [String](),
                "damage": [String: Int](), "inventory": ["wood":12,"stone":8], "undo": [String](), "redo": [String](), "events": [String](), "isCreativeCopy": false]
            for (key,value) in defaults where object[key] == nil { object[key] = value }
            if object["combat"] == nil { object["combat"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RPGCombatState())) }
            if var player = object["player"] as? [String: Any] {
                if player["facing"] == nil { player["facing"] = ["dx":1,"dz":0] }
                if player["weapon"] == nil { player["weapon"] = "none" }
                if player["armor"] == nil { player["armor"] = "none" }
                object["player"] = player
            }
            migrated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } else if version != WorldState.currentSchema { throw RPGWorldError.unsupportedVersion }
        let value = try JSONDecoder().decode(WorldState.self, from: migrated)
        try value.validate(); return value
    }
}
protocol RPGWorldStorage: Sendable {
    func load() async throws -> WorldState?
    func save(_ state: WorldState) async throws
}
