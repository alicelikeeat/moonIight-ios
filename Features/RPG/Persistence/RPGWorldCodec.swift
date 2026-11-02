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
        let value = try JSONDecoder().decode(WorldState.self, from: data)
        try value.validate(); return value
    }
}
protocol RPGWorldStorage: Sendable {
    func load() async throws -> WorldState?
    func save(_ state: WorldState) async throws
}
