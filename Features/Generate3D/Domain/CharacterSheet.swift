import Foundation

// v1.76: a character turnaround sheet (one picture with front / back /
// side views next to each other) → separate view photos for the
// multi-view carver. The standing figures of the main row are found on the
// plain background; labels read by text recognition (FRONT, BACK,
// LEFT SIDE…) name each view, otherwise the usual order is assumed and
// the user can change it. Pure Swift.

struct SheetPanel: Equatable, Sendable, Identifiable {
    /// Box in source pixels.
    var x0: Int, y0: Int, w: Int, h: Int
    var view: PhotoView?
    /// Label text found under the figure.
    var label: String?
    /// 3/4 (diagonal) views cannot be carved; they are listed but unused.
    var diagonal = false
    var id: Int { x0 * 100_000 + y0 }
}

/// Text found in the picture (normalised 0…1, y down).
struct SheetLabel: Equatable, Sendable {
    var text: String
    var x0: Float, x1: Float, y0: Float, y1: Float
}

enum CharacterSheet {
    /// The most common colour of the picture's border (sheets often have
    /// framed panels along the bottom, so not the median).
    static func background(_ img: RasterImage) -> SIMD3<Float> {
        var buckets: [Int: (n: Int, sum: SIMD3<Float>)] = [:]
        for (x, y) in borderPoints(img) {
            let o = (y * img.width + x) * 4
            let c = SIMD3(Float(img.rgba[o]), Float(img.rgba[o + 1]), Float(img.rgba[o + 2]))
            let key = Int(c.x) / 8 << 10 | Int(c.y) / 8 << 5 | Int(c.z) / 8
            buckets[key, default: (0, .zero)].n += 1
            buckets[key, default: (0, .zero)].sum += c
        }
        guard let best = buckets.values.max(by: { $0.n < $1.n }) else { return SIMD3(255, 255, 255) }
        return best.sum / Float(best.n)
    }

    static func borderPoints(_ img: RasterImage) -> [(Int, Int)] {
        let step = max(1, max(img.width, img.height) / 500)
        var out: [(Int, Int)] = []
        for x in stride(from: 0, to: img.width, by: step) { out.append((x, 0)); out.append((x, img.height - 1)) }
        for y in stride(from: 0, to: img.height, by: step) { out.append((0, y)); out.append((img.width - 1, y)) }
        return out
    }

    /// Colour distance that counts as "not background": a few times the
    /// background's own noise (light hair on a light grey sheet is close).
    static func threshold(_ img: RasterImage, background bg: SIMD3<Float>) -> Float {
        var d: [Float] = []
        for (x, y) in borderPoints(img) {
            let o = (y * img.width + x) * 4
            let c = SIMD3(Float(img.rgba[o]), Float(img.rgba[o + 1]), Float(img.rgba[o + 2])) - bg
            let v = (c * c).sum().squareRoot()
            if v < 20 { d.append(v) }
        }
        d.sort()
        let noise = d.isEmpty ? 2 : d[d.count / 2]
        return min(30, max(6, noise * 3 + 4))
    }

    static func differs(_ img: RasterImage, _ x: Int, _ y: Int, from bg: SIMD3<Float>, threshold: Float) -> Bool {
        let o = (y * img.width + x) * 4
        let d = SIMD3(Float(img.rgba[o]), Float(img.rgba[o + 1]), Float(img.rgba[o + 2])) - bg
        return (d * d).sum() > threshold * threshold
    }

    /// Standing figures of the main row, left to right: the row is the band
    /// of the tallest figure; inside it, figures are column runs separated
    /// by background.
    static func panels(_ img: RasterImage, maxSide: Int = 640) -> [SheetPanel] {
        guard img.width > 8, img.height > 8 else { return [] }
        let bg = background(img), limit = threshold(img, background: bg)
        let s = max(1, (max(img.width, img.height) + maxSide - 1) / maxSide)
        let W = img.width / s, H = img.height / s
        guard W > 4, H > 4 else { return [] }
        var fg = [Bool](repeating: false, count: W * H)
        for y in 0..<H { for x in 0..<W { fg[y * W + x] = differs(img, x * s + s / 2, y * s + s / 2, from: bg, threshold: limit) } }

        // Connected pieces (8-neighbour) to find the tallest figure.
        struct Box { var x0: Int, y0: Int, x1: Int, y1: Int, n: Int; var w: Int { x1 - x0 + 1 }; var h: Int { y1 - y0 + 1 } }
        var label = [Bool](repeating: false, count: W * H)
        var tallest: Box?
        var stack: [Int] = []
        for start in 0..<(W * H) where fg[start] && !label[start] {
            var b = Box(x0: W, y0: H, x1: -1, y1: -1, n: 0)
            label[start] = true; stack = [start]
            while let p = stack.popLast() {
                let x = p % W, y = p / W
                b.x0 = min(b.x0, x); b.x1 = max(b.x1, x); b.y0 = min(b.y0, y); b.y1 = max(b.y1, y); b.n += 1
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < W, ny < H else { continue }
                    let q = ny * W + nx
                    if fg[q] && !label[q] { label[q] = true; stack.append(q) }
                } }
            }
            // A standing figure: tall, narrow, not a hollow frame.
            if Float(b.h) >= Float(H) * 0.2, Float(b.h) >= Float(b.w) * 1.3, Float(b.n) >= Float(b.w * b.h) * 0.08, b.h > (tallest?.h ?? 0) { tallest = b }
        }
        guard let row = tallest else { return [] }
        let top = max(0, row.y0 - H / 30), bottom = row.y1
        // Column runs inside the band.
        var count = [Int](repeating: 0, count: W)
        for x in 0..<W { for y in top...bottom where fg[y * W + x] { count[x] += 1 } }
        let minimum = max(1, (bottom - top) / 200)
        var runs: [(Int, Int)] = []
        var start: Int?
        for x in 0...W {
            let on = x < W && count[x] >= minimum
            if on, start == nil { start = x }
            if !on, let s0 = start { runs.append((s0, x - 1)); start = nil }
        }
        var out: [SheetPanel] = []
        for (x0, x1) in runs where x1 - x0 + 1 >= max(3, W / 60) {
            var y0 = bottom, y1 = top
            for y in top...bottom { for x in x0...x1 where fg[y * W + x] { y0 = min(y0, y); y1 = max(y1, y); break } }
            guard y1 > y0, Float(y1 - y0) >= Float(bottom - top) * 0.45 else { continue }
            let pad = max(2, (y1 - y0) / 40)
            let px0 = max(0, (x0 - pad) * s), py0 = max(0, (y0 - pad) * s)
            let px1 = min(img.width, (x1 + 1 + pad) * s), py1 = min(img.height, (y1 + 1 + pad) * s)
            out.append(SheetPanel(x0: px0, y0: py0, w: px1 - px0, h: py1 - py0))
        }
        return out
    }

    /// The view a label names (nil for 3/4 views or unknown text).
    static func view(forLabel raw: String) -> (view: PhotoView?, diagonal: Bool) {
        let t = raw.uppercased().replacingOccurrences(of: " ", with: "")
        if t.contains("3/4") || t.contains("¾") || t.contains("QUARTER") || t.contains("四分之三") || t.contains("斜") { return (nil, true) }
        if t.contains("FRONT") || t.contains("正面") || t == "正" { return (.front, false) }
        if t.contains("BACK") || t.contains("REAR") || t.contains("背") || t.contains("后") { return (.back, false) }
        if t.contains("LEFT") || t.contains("左") { return (.left, false) }
        if t.contains("RIGHT") || t.contains("右") { return (.right, false) }
        if t.contains("TOP") || t.contains("顶") { return (.top, false) }
        if t.contains("SIDE") || t.contains("侧") || t.contains("PROFILE") { return (.left, false) }
        return (nil, false)
    }

    /// Names each panel from the label under it; with no labels at all the
    /// usual order (front, back, left, right) is assumed.
    static func assign(_ input: [SheetPanel], labels: [SheetLabel], imageWidth: Int, imageHeight: Int) -> [SheetPanel] {
        var panels = input
        let W = Float(max(1, imageWidth)), H = Float(max(1, imageHeight))
        for i in panels.indices {
            let p = panels[i]
            let px0 = Float(p.x0) / W, px1 = Float(p.x0 + p.w) / W, bottom = Float(p.y0 + p.h) / H, top = Float(p.y0) / H
            // Labels below (or just above) the figure, centred within its width.
            let near = labels.filter { l in
                let c = (l.x0 + l.x1) / 2
                guard c >= px0 - 0.02, c <= px1 + 0.02 else { return false }
                return (l.y0 >= bottom - 0.04 && l.y0 <= bottom + 0.12) || (l.y1 <= top + 0.02 && l.y1 >= top - 0.08)
            }
            .sorted { abs($0.y0 - bottom) < abs($1.y0 - bottom) }
            for l in near {
                let v = view(forLabel: l.text)
                if v.view != nil || v.diagonal { panels[i].label = l.text; panels[i].view = v.view; panels[i].diagonal = v.diagonal; break }
            }
        }
        // A generic "SIDE" used twice: the second is the right side.
        var used = Set<PhotoView>()
        for i in panels.indices {
            guard let v = panels[i].view else { continue }
            if used.contains(v) { panels[i].view = v == .left && !used.contains(.right) ? .right : nil }
            if let v2 = panels[i].view { used.insert(v2) }
        }
        // Nothing labelled: the usual reading order (front, back, sides;
        // three views are front, side, back).
        if !panels.contains(where: { $0.view != nil || $0.diagonal }) {
            let order: [PhotoView] = panels.count == 3 ? [.front, .left, .back] : [.front, .back, .left, .right]
            for (i, v) in zip(panels.indices, order) { panels[i].view = v }
        }
        return panels
    }

    /// One panel as a view photo: its pixels and the figure's outline (the
    /// biggest piece that differs from the background, holes filled).
    static func photo(_ img: RasterImage, panel p: SheetPanel) -> ViewPhoto {
        let bg = background(img), threshold = threshold(img, background: bg)
        let w = p.w, h = p.h
        var crop = RasterImage(width: w, height: h)
        var fg = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let sx = p.x0 + x, sy = p.y0 + y
            guard sx < img.width, sy < img.height else { continue }
            let o = (sy * img.width + sx) * 4, d = (y * w + x) * 4
            for k in 0..<4 { crop.rgba[d + k] = img.rgba[o + k] }
            fg[y * w + x] = differs(img, sx, sy, from: bg, threshold: threshold)
        } }
        // Close small bites (grey shading on a glossy surface reads like the
        // background) before deciding what is outside.
        fg = close(fg, w, h, radius: max(1, h / 120))
        // Background = what the border reaches without crossing the figure.
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func seed(_ x: Int, _ y: Int) { let i = y * w + x; if !fg[i] && !outside[i] { outside[i] = true; stack.append(i) } }
        for x in 0..<w { seed(x, 0); seed(x, h - 1) }
        for y in 0..<h { seed(0, y); seed(w - 1, y) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { seed(x - 1, y) }; if x < w - 1 { seed(x + 1, y) }
            if y > 0 { seed(x, y - 1) }; if y < h - 1 { seed(x, y + 1) }
        }
        // Enclosed background (between the legs, closed off by the floor
        // shadow) stays background; only small holes are filled.
        var seen = [Bool](repeating: false, count: w * h)
        let small = max(4, w * h / 400)
        for start in 0..<(w * h) where !outside[start] && !fg[start] && !seen[start] {
            var region: [Int] = []
            seen[start] = true; stack = [start]
            while let i = stack.popLast() {
                region.append(i)
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let q = ny * w + nx
                    if !outside[q] && !fg[q] && !seen[q] { seen[q] = true; stack.append(q) }
                }
            }
            if region.count > small { for i in region { outside[i] = true } }
        }
        // Keep the biggest piece (neighbouring figures can poke in).
        var piece = [Int32](repeating: -1, count: w * h)
        var sizes: [Int] = []
        for start in 0..<(w * h) where !outside[start] && piece[start] < 0 {
            let id = Int32(sizes.count)
            var n = 0
            piece[start] = id; stack = [start]
            while let i = stack.popLast() {
                n += 1
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let q = ny * w + nx
                    if !outside[q] && piece[q] < 0 { piece[q] = id; stack.append(q) }
                }
            }
            sizes.append(n)
        }
        let best = sizes.indices.max { sizes[$0] < sizes[$1] }.map(Int32.init) ?? -1
        let mask = piece.map { $0 == best && best >= 0 ? Float(1) : 0 }
        return ViewPhoto(width: w, height: h, mask: mask, image: crop)
    }

    /// Dilate then erode with a square of side 2r + 1 (separable).
    static func close(_ m: [Bool], _ w: Int, _ h: Int, radius r: Int) -> [Bool] {
        func pass(_ src: [Bool], horizontal: Bool, dilate: Bool) -> [Bool] {
            var out = src
            let (outer, inner) = horizontal ? (h, w) : (w, h)
            for a in 0..<outer {
                // Running count of set pixels in the window.
                var count = 0
                func at(_ b: Int) -> Bool { horizontal ? src[a * w + b] : src[b * w + a] }
                for b in 0..<min(inner, r) where at(b) { count += 1 }
                for b in 0..<inner {
                    if b + r < inner, at(b + r) { count += 1 }
                    if b - r - 1 >= 0, at(b - r - 1) { count -= 1 }
                    let lo = max(0, b - r), hi = min(inner - 1, b + r)
                    let v = dilate ? count > 0 : count == hi - lo + 1
                    if horizontal { out[a * w + b] = v } else { out[b * w + a] = v }
                }
            }
            return out
        }
        let d = pass(pass(m, horizontal: true, dilate: true), horizontal: false, dilate: true)
        return pass(pass(d, horizontal: true, dilate: false), horizontal: false, dilate: false)
    }
}
