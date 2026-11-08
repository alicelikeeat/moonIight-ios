import Foundation

// v1.91: reader for Resources/HumanBase/HumanBase.hbm, the universal base
// body built by tools/humanbase/build_humanbase.py from the MakeHuman hm08
// mesh (CC0). Every count and index is checked; a damaged or unknown file
// is refused (nil), never half-read. Pure Swift, tested on Linux.

struct HumanBaseAsset: Sendable {
    struct Joint: Equatable, Sendable {
        var name: String
        var parent: Int?
        var position: SIMD3<Float>
    }
    struct Side: Sendable {
        var indices: [Int]
        var deltas: [SIMD3<Float>]
        /// Joint movement for this side at full strength, one per joint.
        var joints: [SIMD3<Float>]
    }
    struct Channel: Sendable {
        var name: String
        var negative: Side
        var positive: Side
    }
    struct LOD: Sendable {
        /// Render vertex → surface vertex (shares its weights and shape).
        var master: [Int]
        var uvs: [Float]
        var indices: [UInt32]
        var triangleCount: Int { indices.count / 3 }
    }

    static let formatVersion: UInt32 = 1

    var positions: [SIMD3<Float>]
    var influenceJoints: [UInt8]
    var influenceWeights: [Float]
    var joints: [Joint]
    var channels: [Channel]
    var lods: [LOD]

    var vertexCount: Int { positions.count }
    func channel(_ name: String) -> Channel? { channels.first { $0.name == name } }
    func jointIndex(_ name: String) -> Int? { joints.firstIndex { $0.name == name } }

    enum Failure: Error, Equatable { case notHumanBase, newerVersion(UInt32), truncated, bad(String) }

    static func decode(_ data: Data) throws -> HumanBaseAsset {
        var r = ByteReader(bytes: [UInt8](data))
        guard r.bytes.count >= 8, Array(r.bytes[0..<4]) == Array("HBM1".utf8) else { throw Failure.notHumanBase }
        r.offset = 4
        let version = try r.u32()
        guard version <= formatVersion else { throw Failure.newerVersion(version) }
        let n = Int(try r.u32())
        guard (1...65_535).contains(n) else { throw Failure.bad("vertex count \(n)") }
        let flat = try r.f32(n * 3)
        let positions = (0..<n).map { SIMD3(flat[$0 * 3], flat[$0 * 3 + 1], flat[$0 * 3 + 2]) }
        guard positions.allSatisfy(cFinite) else { throw Failure.bad("non-finite vertex") }
        let influenceJoints = try r.u8(n * 4)
        let influenceWeights = try r.f32(n * 4)
        let jointCount = Int(try r.u32())
        guard (1...250).contains(jointCount) else { throw Failure.bad("joint count \(jointCount)") }
        var joints: [Joint] = []
        for i in 0..<jointCount {
            let name = try r.string()
            let parent = try r.u32()
            let p = try r.f32(3)
            let parentIndex: Int? = parent == 0xFFFF_FFFF ? nil : Int(parent)
            if let parentIndex, parentIndex >= i { throw Failure.bad("joint \(name) before its parent") }
            if parentIndex == nil && i != 0 { throw Failure.bad("second root \(name)") }
            guard p.allSatisfy(\.isFinite) else { throw Failure.bad("joint \(name) position") }
            joints.append(Joint(name: name, parent: parentIndex, position: SIMD3(p[0], p[1], p[2])))
        }
        for v in 0..<n {
            var sum: Float = 0
            for k in 0..<4 {
                let j = influenceJoints[v * 4 + k], w = influenceWeights[v * 4 + k]
                guard w.isFinite, w >= 0 else { throw Failure.bad("weight at vertex \(v)") }
                if w > 0 { guard Int(j) < jointCount else { throw Failure.bad("joint index at vertex \(v)") }; sum += w }
            }
            guard abs(sum - 1) < 0.01 else { throw Failure.bad("weights of vertex \(v) sum to \(sum)") }
        }
        let channelCount = Int(try r.u32())
        guard channelCount <= 64 else { throw Failure.bad("channel count") }
        var channels: [Channel] = []
        for _ in 0..<channelCount {
            let name = try r.string()
            var sides: [Side] = []
            for _ in 0..<2 {
                let m = Int(try r.u32())
                guard m <= n else { throw Failure.bad("channel \(name) size") }
                let scale = try r.f32(1)[0]
                guard scale.isFinite, scale > 0 else { throw Failure.bad("channel \(name) scale") }
                let idx = try r.u16(m).map(Int.init)
                guard idx.allSatisfy({ $0 < n }) else { throw Failure.bad("channel \(name) index") }
                let raw = try r.i16(m * 3)
                let deltas = (0..<m).map { SIMD3(Float(raw[$0 * 3]) * scale, Float(raw[$0 * 3 + 1]) * scale, Float(raw[$0 * 3 + 2]) * scale) }
                let jd = try r.f32(jointCount * 3)
                guard jd.allSatisfy(\.isFinite) else { throw Failure.bad("channel \(name) joints") }
                sides.append(Side(indices: idx, deltas: deltas, joints: (0..<jointCount).map { SIMD3(jd[$0 * 3], jd[$0 * 3 + 1], jd[$0 * 3 + 2]) }))
            }
            channels.append(Channel(name: name, negative: sides[0], positive: sides[1]))
        }
        let lodCount = Int(try r.u32())
        guard (1...8).contains(lodCount) else { throw Failure.bad("LOD count") }
        var lods: [LOD] = []
        for _ in 0..<lodCount {
            let rv = Int(try r.u32())
            guard (3...65_535).contains(rv) else { throw Failure.bad("LOD vertices") }
            let master = try r.u16(rv).map(Int.init)
            guard master.allSatisfy({ $0 < n }) else { throw Failure.bad("LOD vertex index") }
            let uvs = try r.f32(rv * 2)
            guard uvs.allSatisfy(\.isFinite) else { throw Failure.bad("LOD UV") }
            let t = Int(try r.u32())
            guard t > 0, t <= 200_000 else { throw Failure.bad("LOD triangles") }
            let indices = try r.u16(t * 3).map(UInt32.init)
            guard indices.allSatisfy({ Int($0) < rv }) else { throw Failure.bad("LOD triangle index") }
            lods.append(LOD(master: master, uvs: uvs, indices: indices))
        }
        guard r.offset == r.bytes.count else { throw Failure.bad("trailing bytes") }
        return HumanBaseAsset(positions: positions, influenceJoints: influenceJoints, influenceWeights: influenceWeights, joints: joints, channels: channels, lods: lods)
    }

    /// The shipped file: the app bundle, else (tests, tools) HUMANBASE_PATH or
    /// the repository's Resources folder.
    static func url() -> URL? {
        if let bundled = Bundle.main.url(forResource: "HumanBase", withExtension: "hbm", subdirectory: "HumanBase") { return bundled }
        if let path = ProcessInfo.processInfo.environment["HUMANBASE_PATH"], FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/HumanBase/HumanBase.hbm")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// Loaded once; nil when the file is missing or damaged (callers fall back).
    static let shared: HumanBaseAsset? = url().flatMap { try? Data(contentsOf: $0) }.flatMap { try? decode($0) }
}

/// Little-endian reader that throws instead of reading past the end.
struct ByteReader {
    var bytes: [UInt8]
    var offset = 0

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else { throw HumanBaseAsset.Failure.truncated }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }
    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        return b.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    mutating func u8(_ count: Int) throws -> [UInt8] { Array(try take(count)) }
    mutating func u16(_ count: Int) throws -> [UInt16] {
        let b = Array(try take(count * 2))
        var out = [UInt16](repeating: 0, count: count)
        for i in 0..<count { out[i] = UInt16(b[i * 2]) | (UInt16(b[i * 2 + 1]) << 8) }
        return out
    }
    mutating func i16(_ count: Int) throws -> [Int16] { try u16(count).map { Int16(bitPattern: $0) } }
    mutating func f32(_ count: Int) throws -> [Float] {
        let b = Array(try take(count * 4))
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let b0 = UInt32(b[i * 4]), b1 = UInt32(b[i * 4 + 1]) << 8
            let b2 = UInt32(b[i * 4 + 2]) << 16, b3 = UInt32(b[i * 4 + 3]) << 24
            out[i] = Float(bitPattern: b0 | b1 | b2 | b3)
        }
        return out
    }
    mutating func string() throws -> String {
        let n = Int(try u32())
        guard n <= 256 else { throw HumanBaseAsset.Failure.bad("name length") }
        guard let s = String(bytes: try take(n), encoding: .utf8) else { throw HumanBaseAsset.Failure.bad("name text") }
        return s
    }
}
