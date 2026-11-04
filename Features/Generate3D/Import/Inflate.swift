import Foundation

// v1.76: DEFLATE (RFC 1951), zlib (RFC 1950) and ZIP reading in pure Swift,
// for 3MF packages and compressed FBX arrays. Small and portable (tested on
// Linux); speed is fine for model files.

enum InflateError: Error, Equatable { case corrupt(String), unsupported(String) }

enum Inflate {
    /// zlib stream: 2-byte header, deflate data, Adler-32.
    static func zlib(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 2, (UInt16(data[0]) << 8 | UInt16(data[1])) % 31 == 0, data[0] & 0x0F == 8 else { throw InflateError.corrupt("zlib header") }
        guard data[1] & 0x20 == 0 else { throw InflateError.unsupported("preset dictionary") }
        return try raw(Array(data[2...]))
    }

    /// Raw deflate.
    static func raw(_ input: [UInt8], expectedSize: Int = 0) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(max(expectedSize, input.count * 3))
        var pos = 0, bit = 0
        func bits(_ n: Int) throws -> Int {
            var v = 0
            for i in 0..<n {
                guard pos < input.count else { throw InflateError.corrupt("end of data") }
                v |= Int((input[pos] >> UInt8(bit)) & 1) << i
                bit += 1
                if bit == 8 { bit = 0; pos += 1 }
            }
            return v
        }
        struct Huffman { var counts: [Int]; var symbols: [Int] }
        func build(_ lengths: [Int]) -> Huffman {
            var counts = [Int](repeating: 0, count: 16)
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offsets[i] = offsets[i - 1] + counts[i - 1] }
            var symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l > 0 { symbols[offsets[l]] = s; offsets[l] += 1 }
            return Huffman(counts: counts, symbols: symbols)
        }
        func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1..<16 {
                code |= try bits(1)
                let count = h.counts[len]
                if code - count < first { return h.symbols[index + (code - first)] }
                index += count; first += count; first <<= 1; code <<= 1
            }
            throw InflateError.corrupt("bad code")
        }
        let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
        var fixedLit: Huffman?, fixedDist: Huffman?
        var final = 0
        repeat {
            final = try bits(1)
            let type = try bits(2)
            switch type {
            case 0:
                if bit != 0 { bit = 0; pos += 1 }
                guard pos + 4 <= input.count else { throw InflateError.corrupt("stored header") }
                let len = Int(input[pos]) | Int(input[pos + 1]) << 8
                pos += 4
                guard pos + len <= input.count else { throw InflateError.corrupt("stored length") }
                out += input[pos..<(pos + len)]
                pos += len
            case 1, 2:
                let lit: Huffman, dist: Huffman
                if type == 1 {
                    if fixedLit == nil {
                        var l = [Int](repeating: 8, count: 288)
                        for i in 144..<256 { l[i] = 9 }
                        for i in 256..<280 { l[i] = 7 }
                        fixedLit = build(l); fixedDist = build([Int](repeating: 5, count: 30))
                    }
                    lit = fixedLit!; dist = fixedDist!
                } else {
                    let hlit = try bits(5) + 257, hdist = try bits(5) + 1, hclen = try bits(4) + 4
                    let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                    var cl = [Int](repeating: 0, count: 19)
                    for i in 0..<hclen { cl[order[i]] = try bits(3) }
                    let clh = build(cl)
                    var lengths: [Int] = []
                    while lengths.count < hlit + hdist {
                        let sym = try decode(clh)
                        switch sym {
                        case 0..<16: lengths.append(sym)
                        case 16:
                            guard let last = lengths.last else { throw InflateError.corrupt("repeat") }
                            lengths += [Int](repeating: last, count: 3 + (try bits(2)))
                        case 17: lengths += [Int](repeating: 0, count: 3 + (try bits(3)))
                        default: lengths += [Int](repeating: 0, count: 11 + (try bits(7)))
                        }
                    }
                    lit = build(Array(lengths[0..<hlit])); dist = build(Array(lengths[hlit..<(hlit + hdist)]))
                }
                while true {
                    let sym = try decode(lit)
                    if sym < 256 { out.append(UInt8(sym)); continue }
                    if sym == 256 { break }
                    let li = sym - 257
                    guard li < 29 else { throw InflateError.corrupt("length") }
                    let length = lengthBase[li] + (try bits(lengthExtra[li]))
                    let di = try decode(dist)
                    guard di < 30 else { throw InflateError.corrupt("distance") }
                    let distance = distBase[di] + (try bits(distExtra[di]))
                    guard distance <= out.count else { throw InflateError.corrupt("distance too far") }
                    let start = out.count - distance
                    for k in 0..<length { out.append(out[start + k]) }
                }
            default: throw InflateError.corrupt("block type")
            }
        } while final == 0
        return out
    }
}

/// Files of a ZIP archive (stored or deflated entries).
enum ZipReader {
    static func entries(_ data: Data) throws -> [String: [UInt8]] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // End of central directory.
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 65_557) { if u32(i) == 0x06054B50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw InflateError.corrupt("not a zip") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [String: [UInt8]] = [:]
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014B50 else { throw InflateError.corrupt("central directory") }
            let method = u16(p + 10), compressed = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLen <= b.count else { throw InflateError.corrupt("name") }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard local + 30 <= b.count, u32(local) == 0x04034B50 else { throw InflateError.corrupt("local header") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= b.count, size < 512 * 1024 * 1024 else { throw InflateError.corrupt("entry") }
            if name.hasSuffix("/") { continue }
            let body = Array(b[start..<(start + compressed)])
            switch method {
            case 0: out[name] = body
            case 8: out[name] = try Inflate.raw(body, expectedSize: size)
            default: throw InflateError.unsupported("zip method \(method)")
            }
        }
        return out
    }
}
