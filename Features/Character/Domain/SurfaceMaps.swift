import Foundation

// v1.93: surface maps from a colour texture, so a painted skin or a garment
// stops looking like one plastic material:
//   - a skin mask (where the picture shows skin, by colour), cleaned up;
//   - a roughness map (skin smoother than cloth, cloth texture rougher in
//     its folds);
//   - a detail normal map from the picture's brightness (folds, seams,
//     stitching catch the light).
// The normals are inferred from shading in the picture, not from real
// geometry: a good approximation for small detail, wrong for large forms
// (which the mesh carries). Pure Swift (tested on Linux).

struct SurfaceMapSet: Sendable {
    /// Grey: 255 = skin.
    var mask: RasterImage
    /// Grey: roughness 0…1 as 0…255.
    var roughness: RasterImage
    /// Tangent-space normals, RGB = n × 0.5 + 0.5 (green up).
    var normal: RasterImage
    /// Share of the picture that is skin.
    var skinShare: Float
}

enum SurfaceMaps {
    static let skinRoughness: Float = 0.5
    static let clothRoughness: Float = 0.82

    /// Skin colour by the classic YCbCr range (all skin tones share it; hair,
    /// most clothes and backgrounds fall outside).
    static func isSkin(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
        let R = Float(r), G = Float(g), B = Float(b)
        let y = 0.299 * R + 0.587 * G + 0.114 * B
        let cb = 128 - 0.168736 * R - 0.331264 * G + 0.5 * B
        let cr = 128 + 0.5 * R - 0.418688 * G - 0.081312 * B
        return y > 45 && y < 245 && cb >= 77 && cb <= 127 && cr >= 135 && cr <= 173 && R > B
    }

    /// Box-downscales so the longer side is at most `maxSide`.
    static func fitted(_ image: RasterImage, maxSide: Int) -> RasterImage {
        let longer = max(image.width, image.height)
        guard longer > maxSide, maxSide > 0 else { return image }
        let k = Float(longer) / Float(maxSide)
        let w = max(1, Int(Float(image.width) / k)), h = max(1, Int(Float(image.height) / k))
        var out = RasterImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w {
            let x0 = Int(Float(x) * k), x1 = max(x0 + 1, min(image.width, Int(Float(x + 1) * k)))
            let y0 = Int(Float(y) * k), y1 = max(y0 + 1, min(image.height, Int(Float(y + 1) * k)))
            var acc: [Int] = [0, 0, 0, 0]
            for yy in y0..<y1 { for xx in x0..<x1 { let o = (yy * image.width + xx) * 4; for c in 0..<4 { acc[c] += Int(image.rgba[o + c]) } } }
            let n = (x1 - x0) * (y1 - y0), o = (y * w + x) * 4
            for c in 0..<4 { out.rgba[o + c] = UInt8(acc[c] / max(1, n)) }
        } }
        return out
    }

    static func build(_ albedo: RasterImage, maxSide: Int = 1024, skinStrength: Float = 0.8, clothStrength: Float = 2.5) -> SurfaceMapSet {
        let img = fitted(albedo, maxSide: maxSide)
        let w = img.width, h = img.height, n = w * h
        guard n > 0, img.rgba.count >= n * 4 else {
            let empty = RasterImage(width: 1, height: 1, fill: [128, 128, 255, 255])
            return SurfaceMapSet(mask: RasterImage(width: 1, height: 1, fill: [0, 0, 0, 255]), roughness: RasterImage(width: 1, height: 1, fill: [209, 209, 209, 255]), normal: empty, skinShare: 0)
        }
        // Skin, then a 3×3 majority vote (removes speckles at edges and in noise).
        var raw = [Bool](repeating: false, count: n)
        var lum = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let o = i * 4
            raw[i] = isSkin(img.rgba[o], img.rgba[o + 1], img.rgba[o + 2])
            lum[i] = (0.299 * Float(img.rgba[o]) + 0.587 * Float(img.rgba[o + 1]) + 0.114 * Float(img.rgba[o + 2])) / 255
        }
        var skin = raw
        var count = 0
        for y in 0..<h { for x in 0..<w {
            var votes = 0, total = 0
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                total += 1; if raw[yy * w + xx] { votes += 1 }
            } }
            skin[y * w + x] = votes * 2 > total
            if skin[y * w + x] { count += 1 }
        } }
        // Height: the brightness, softened once (picture noise is not relief).
        var height = lum
        for y in 0..<h { for x in 0..<w {
            var s: Float = 0, c: Float = 0
            for dy in -1...1 { for dx in -1...1 {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                s += lum[yy * w + xx]; c += 1
            } }
            height[y * w + x] = s / c
        } }
        func at(_ x: Int, _ y: Int) -> Float { height[min(h - 1, max(0, y)) * w + min(w - 1, max(0, x))] }
        var mask = RasterImage(width: w, height: h), rough = RasterImage(width: w, height: h), normal = RasterImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, o = i * 4
            // Sobel; image rows run down, so "up" is the row above.
            let gx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1))
            let gyUp = (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1)) - (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1))
            let k = skin[i] ? skinStrength : clothStrength
            var nx = -gx * k, ny = -gyUp * k, nz: Float = 1
            let l = (nx * nx + ny * ny + nz * nz).squareRoot()
            nx /= l; ny /= l; nz /= l
            normal.rgba[o] = UInt8(max(0, min(255, (nx * 0.5 + 0.5) * 255 + 0.5)))
            normal.rgba[o + 1] = UInt8(max(0, min(255, (ny * 0.5 + 0.5) * 255 + 0.5)))
            normal.rgba[o + 2] = UInt8(max(0, min(255, (nz * 0.5 + 0.5) * 255 + 0.5)))
            normal.rgba[o + 3] = 255
            // Cloth is rougher where its picture has fine detail (weave, folds).
            let detail = min(1, (gx * gx + gyUp * gyUp).squareRoot() * 2)
            let r = skin[i] ? skinRoughness : min(0.95, clothRoughness + 0.1 * detail)
            let rv = UInt8(max(0, min(255, r * 255 + 0.5)))
            rough.rgba[o] = rv; rough.rgba[o + 1] = rv; rough.rgba[o + 2] = rv; rough.rgba[o + 3] = 255
            let mv: UInt8 = skin[i] ? 255 : 0
            mask.rgba[o] = mv; mask.rgba[o + 1] = mv; mask.rgba[o + 2] = mv; mask.rgba[o + 3] = 255
        } }
        return SurfaceMapSet(mask: mask, roughness: rough, normal: normal, skinShare: Float(count) / Float(n))
    }
}
