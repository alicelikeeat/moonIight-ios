import Foundation

/// v1.93: skin mask, roughness and detail normals from a colour texture.
func surfaceMapsTests() {
    let skins: [(UInt8, UInt8, UInt8)] = [(255, 219, 172), (224, 172, 105), (198, 134, 66), (141, 85, 36)]
    let others: [(UInt8, UInt8, UInt8)] = [(40, 80, 200), (60, 160, 60), (128, 128, 128), (250, 250, 250), (10, 10, 10), (30, 20, 15)]
    check(skins.allSatisfy { SurfaceMaps.isSkin($0.0, $0.1, $0.2) } && !others.contains { SurfaceMaps.isSkin($0.0, $0.1, $0.2) },
          "surface maps: light to dark skin tones are skin; blue, green, grey, white, black and dark hair are not")

    // Left half skin, right half blue cloth.
    var picture = RasterImage(width: 64, height: 32)
    for y in 0..<32 { for x in 0..<64 {
        let c: [UInt8] = x < 32 ? [224, 172, 105, 255] : [40, 80, 200, 255]
        for k in 0..<4 { picture.rgba[(y * 64 + x) * 4 + k] = c[k] }
    } }
    let maps = SurfaceMaps.build(picture)
    func px(_ image: RasterImage, _ x: Int, _ y: Int) -> [UInt8] { image.pixel(x, y) }
    check(px(maps.mask, 10, 16)[0] == 255 && px(maps.mask, 50, 16)[0] == 0 && abs(maps.skinShare - 0.5) < 0.05,
          "surface maps: the skin mask covers the skin half only (\(maps.skinShare))")
    check(px(maps.roughness, 10, 16)[0] == 128 && px(maps.roughness, 50, 16)[0] >= 209, "surface maps: skin is smoother than cloth")
    let flat = px(maps.normal, 10, 16), flat2 = px(maps.normal, 50, 16)
    check(abs(Int(flat[0]) - 128) <= 1 && abs(Int(flat[1]) - 128) <= 1 && flat[2] == 255 && abs(Int(flat2[0]) - 128) <= 1 && flat2[2] == 255,
          "surface maps: flat colour gives a flat normal (\(flat), \(flat2))")

    // Brightness ramps tilt the normals away from the brighter side.
    var right = RasterImage(width: 32, height: 32), up = RasterImage(width: 32, height: 32)
    for y in 0..<32 { for x in 0..<32 {
        let a = UInt8(x * 8), b = UInt8(255 - y * 8)
        for k in 0..<3 { right.rgba[(y * 32 + x) * 4 + k] = a; up.rgba[(y * 32 + x) * 4 + k] = b }
        right.rgba[(y * 32 + x) * 4 + 3] = 255; up.rgba[(y * 32 + x) * 4 + 3] = 255
    } }
    let nr = px(SurfaceMaps.build(right).normal, 16, 16), nu = px(SurfaceMaps.build(up).normal, 16, 16)
    check(nr[0] < 118 && abs(Int(nr[1]) - 128) <= 2 && nu[1] < 118 && abs(Int(nu[0]) - 128) <= 2,
          "surface maps: a surface brighter to the right / at the top leans its normal the other way (\(nr), \(nu))")
    let normalsUnit = stride(from: 0, to: maps.normal.rgba.count, by: 4).allSatisfy { o -> Bool in
        let v = (0..<3).map { Float(maps.normal.rgba[o + $0]) / 255 * 2 - 1 }
        let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
        return abs(l - 1) < 0.03 && v[2] > 0
    }
    check(normalsUnit, "surface maps: every normal is unit length and faces out")

    let wide = SurfaceMaps.fitted(RasterImage(width: 3000, height: 10, fill: [9, 9, 9, 255]), maxSide: 1024)
    check(wide.width == 1024 && wide.height == 3 && wide.pixel(500, 1) == [9, 9, 9, 255], "surface maps: large textures are scaled down first (\(wide.width)×\(wide.height))")
    print("RPG surface maps: skin share \(maps.skinShare)")
}
