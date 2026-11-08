import Foundation

// v1.74: 3D model from 2, 4 or 6 photos of the same subject (front / back,
// + left / right, + top / bottom). Each photo's subject outline is an
// orthographic silhouette; a voxel grid keeps only what every available
// view sees as subject (visual hull). With only front and back, the depth
// comes from the outline (thicker where the outline is wider). A smooth
// surface is extracted (surface nets) and every face is coloured from the
// photo that looks at it most directly. Concave details between views are
// not recovered (a visual hull fills them). Pure Swift.

enum PhotoView: String, Codable, CaseIterable, Sendable, Identifiable {
    case front, back, left, right, top, bottom
    var id: Self { self }
    var title: String {
        switch self {
        case .front: L10n.t("正面", "Front"); case .back: L10n.t("背面", "Back")
        case .left: L10n.t("左侧", "Left"); case .right: L10n.t("右侧", "Right")
        case .top: L10n.t("顶部", "Top"); case .bottom: L10n.t("底部", "Bottom")
        }
    }
    /// How to take it (the subject faces the camera in the front photo).
    var hint: String {
        switch self {
        case .front: L10n.t("正对着拍，整个人在画面里", "Facing the subject, whole body in frame")
        case .back: L10n.t("绕到背后拍", "From behind")
        case .left: L10n.t("站在人物左手边拍（看到左侧面）", "From the subject's left side")
        case .right: L10n.t("站在人物右手边拍（看到右侧面）", "From the subject's right side")
        case .top: L10n.t("从正上方往下拍，人物正面朝画面下方", "From above, the subject's front towards the bottom of the picture")
        case .bottom: L10n.t("从正下方往上拍，人物正面朝画面下方", "From below, the subject's front towards the bottom of the picture")
        }
    }
    /// Direction from the subject towards this camera.
    var direction: SIMD3<Float> {
        switch self { case .front: [0, 0, 1]; case .back: [0, 0, -1]; case .left: [1, 0, 0]; case .right: [-1, 0, 0]; case .top: [0, 1, 0]; case .bottom: [0, -1, 0] }
    }
}

/// One photo: subject mask (0…1) and colours, same size, rows top first.
struct ViewPhoto: Sendable {
    var width: Int
    var height: Int
    var mask: [Float]
    var image: RasterImage
}

enum MultiViewError: Error, Equatable, LocalizedError {
    case needsFront, noSubject(PhotoView), empty
    var errorDescription: String? {
        switch self {
        case .needsFront: L10n.t("至少需要一张正面照片", "At least a front photo is needed")
        case .noSubject(let v): L10n.t("「\(v.title)」照片里没有找到主体", "No subject found in the \(v.title) photo")
        case .empty: L10n.t("几张照片的轮廓对不上，没有留下任何形体。请确认每张照片的方向", "The outlines do not agree and nothing was left; check each photo's direction")
        }
    }
}

struct MultiViewResult: Sendable {
    var mesh: GeneratedMesh
    var atlas: RasterImage
    var views: [PhotoView]
    var notes: [String]
}

enum MultiViewCarver {
    struct Options: Sendable {
        /// Voxels along the height.
        var resolution = 96
        var tile = 512
        /// Depth / width ratio used when there are no side photos.
        var thickness: Float = 0.55
        /// Outline tolerance (share of the view size) for slightly misaligned photos.
        var tolerance: Float = 0.015
    }

    struct Crop { var x0: Int; var y0: Int; var w: Int; var h: Int }

    static func bounds(_ p: ViewPhoto) -> Crop? {
        var x0 = p.width, y0 = p.height, x1 = -1, y1 = -1
        for y in 0..<p.height { for x in 0..<p.width where p.mask[y * p.width + x] >= 0.5 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 >= x0 + 2, y1 >= y0 + 2 else { return nil }
        return Crop(x0: x0, y0: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
    }

    /// How well opposite photos agree (IoU of front vs mirrored back, left vs
    /// mirrored right, on their crops); the lowest pair, nil without a pair.
    static func agreement(_ photos: [PhotoView: ViewPhoto], crops: [PhotoView: Crop]) -> Float? {
        var lowest: Float?
        for (a, b) in [(PhotoView.front, PhotoView.back), (.left, .right)] {
            guard let pa = photos[a], let pb = photos[b], let ca = crops[a], let cb = crops[b] else { continue }
            // Both outlines on a 64-cell grid; a cell only disagrees when the
            // other outline has nothing within one cell (pixel-wide differences
            // on thin limbs are not misalignment).
            let n = 64
            func grid(_ p: ViewPhoto, _ c: Crop, mirrored: Bool) -> [Bool] {
                var g = [Bool](repeating: false, count: n * n)
                for j in 0..<n { for i in 0..<n {
                    let u = (Float(i) + 0.5) / Float(n), v = (Float(j) + 0.5) / Float(n)
                    let x = c.x0 + Int((mirrored ? 1 - u : u) * Float(c.w - 1)), y = c.y0 + Int(v * Float(c.h - 1))
                    g[j * n + i] = p.mask[y * p.width + x] >= 0.5
                } }
                return g
            }
            let ga = grid(pa, ca, mirrored: false), gb = grid(pb, cb, mirrored: true)
            func near(_ g: [Bool], _ i: Int, _ j: Int) -> Bool {
                for dj in -1...1 { for di in -1...1 {
                    let x = i + di, y = j + dj
                    if x >= 0, x < n, y >= 0, y < n, g[y * n + x] { return true }
                } }
                return false
            }
            var union = 0, missed = 0
            for j in 0..<n { for i in 0..<n {
                let x = ga[j * n + i], y = gb[j * n + i]
                guard x || y else { continue }
                union += 1
                if (x && !near(gb, i, j)) || (y && !near(ga, i, j)) { missed += 1 }
            } }
            guard union > 0 else { continue }
            let score = 1 - Float(missed) / Float(union)
            lowest = min(lowest ?? score, score)
        }
        return lowest
    }

    static func build(_ photos: [PhotoView: ViewPhoto], options: Options = Options(), cancelled: () -> Bool = { false }) throws -> MultiViewResult {
        guard let front = photos[.front] else { throw MultiViewError.needsFront }
        var crops: [PhotoView: Crop] = [:]
        for (view, photo) in photos {
            guard let c = bounds(photo) else { throw MultiViewError.noSubject(view) }
            crops[view] = c
        }
        var notes: [String] = []
        let fc = crops[.front]!
        // Extents in body heights: x from the front, z from a side (else top, else guessed).
        let X = Float(fc.w) / Float(fc.h)
        var Z: Float
        let side = crops[.left] ?? crops[.right]
        if let s = side { Z = Float(s.w) / Float(s.h) }
        else if let t = crops[.top] ?? crops[.bottom] { Z = X * Float(t.h) / Float(t.w) }
        else { Z = X * options.thickness; notes.append(L10n.t("没有侧面照片：厚度按轮廓推测", "No side photo: thickness guessed from the outline")) }
        Z = max(0.05, Z)

        // v1.92: the outline tolerance follows how well opposite photos agree.
        // Front and mirrored back (left and mirrored right) show the same
        // outline; when they match, the photos are aligned and the full
        // tolerance would only fatten thin parts.
        let agreement = MultiViewCarver.agreement(photos, crops: crops)
        let t = options.tolerance * (agreement.map { min(1, max(0.15, (1 - $0) / 0.08)) } ?? 1)
        if let agreement, agreement >= 0.95 {
            notes.append(L10n.t(String(format: "正反面轮廓吻合 %.0f%%：按精确对齐处理", agreement * 100), String(format: "Opposite outlines agree %.0f%%: treated as aligned", agreement * 100)))
        }

        // Mask lookup in a view's crop (u, v in 0…1, v down) with tolerance.
        func inside(_ view: PhotoView, _ u: Float, _ v: Float) -> Bool {
            guard let p = photos[view], let c = crops[view] else { return true }
            guard u >= -t, u <= 1 + t, v >= -t, v <= 1 + t else { return false }
            let r = Int(t * Float(max(c.w, c.h)))
            let cx = c.x0 + Int(min(1, max(0, u)) * Float(c.w - 1)), cy = c.y0 + Int(min(1, max(0, v)) * Float(c.h - 1))
            if r == 0 { return p.mask[cy * p.width + cx] >= 0.5 }
            for dy in stride(from: -r, through: r, by: r) { for dx in stride(from: -r, through: r, by: r) {
                let x = min(p.width - 1, max(0, cx + dx)), y = min(p.height - 1, max(0, cy + dy))
                if p.mask[y * p.width + x] >= 0.5 { return true }
            } }
            return false
        }
        func project(_ view: PhotoView, _ x: Float, _ y: Float, _ z: Float) -> (Float, Float) {
            switch view {
            case .front: ((x + X / 2) / X, 1 - y)
            case .back: ((X / 2 - x) / X, 1 - y)
            case .left: ((Z / 2 - z) / Z, 1 - y)
            case .right: ((z + Z / 2) / Z, 1 - y)
            case .top: ((x + X / 2) / X, (z + Z / 2) / Z)
            case .bottom: ((x + X / 2) / X, (Z / 2 - z) / Z)
            }
        }

        // Thickness from the outline when there is no side / top view.
        let N = max(24, options.resolution)
        let nx = max(8, Int((Float(N) * X).rounded())), ny = N
        var nz = max(8, Int((Float(N) * Z).rounded()))
        var halfDepth: [Float]? = nil
        if side == nil && crops[.top] == nil && crops[.bottom] == nil {
            var occupied = [Bool](repeating: false, count: nx * ny)
            for j in 0..<ny { for i in 0..<nx {
                let x = (Float(i) + 0.5) / Float(nx) * X - X / 2, y = (Float(j) + 0.5) / Float(ny)
                let (u, v) = project(.front, x, y, 0)
                let (bu, bv) = project(.back, x, y, 0)
                occupied[j * nx + i] = inside(.front, u, v) && (photos[.back] == nil || inside(.back, bu, bv))
            } }
            // Each part is about as deep as it is wide where it is (√h is
            // close to the distance to the outline), so arms stay thin.
            let h = DepthRefine.inflation(occupied, width: nx, height: ny)
            // v1.92: 1.6 (was 0.8): the reconstruction benchmark showed bodies
            // carved from front and back at about a third of their real depth.
            // Its best was 2.0 on human bodies; 1.6 keeps most of the gain
            // without inflating flatter objects as much.
            let half = h.map { 1.6 * $0.squareRoot() / Float(ny) }
            halfDepth = half
            Z = 2 * (half.max() ?? 0.05) + 2 / Float(ny)
            nz = max(8, Int((Float(N) * Z).rounded()))
        }

        // v1.92: with a side photo, each part is only as deep as its own
        // thickness. A side view alone gives every part at one height the
        // depth of the deepest one (outstretched arms become slabs as deep as
        // the chest); the front outline says how thick each part is, and the
        // side photo says how deep the thickest part of that row really is.
        var window: [SIMD2<Float>]? = nil
        let sideViews = [PhotoView.left, .right].filter { photos[$0] != nil }
        if halfDepth == nil, !sideViews.isEmpty {
            var occupied = [Bool](repeating: false, count: nx * ny)
            for j in 0..<ny { for i in 0..<nx {
                let x = (Float(i) + 0.5) / Float(nx) * X - X / 2, y = (Float(j) + 0.5) / Float(ny)
                let (u, v) = project(.front, x, y, 0)
                occupied[j * nx + i] = inside(.front, u, v)
            } }
            let thickness = DepthRefine.inflation(occupied, width: nx, height: ny).map { $0.squareRoot() }
            var w = [SIMD2<Float>](repeating: SIMD2(0, -1), count: nx * ny)
            let voxel = Z / Float(nz)
            for j in 0..<ny {
                let y = (Float(j) + 0.5) / Float(ny)
                // The side photos' depth range at this height.
                var lo = Float.infinity, hi = -Float.infinity
                for k in 0..<nz {
                    let z = (Float(k) + 0.5) / Float(nz) * Z - Z / 2
                    if sideViews.allSatisfy({ view in let (u, v) = project(view, 0, y, z); return inside(view, u, v) }) { lo = min(lo, z); hi = max(hi, z) }
                }
                guard lo <= hi else { continue }
                let rowMax = (0..<nx).map { thickness[j * nx + $0] }.max() ?? 0
                guard rowMax > 0 else { continue }
                let centre = (lo + hi) / 2, half = (hi - lo) / 2
                for i in 0..<nx where occupied[j * nx + i] {
                    // Thinner parts fall off with the square of their relative
                    // thickness (the benchmark's best of 1, 1.5, 2 and 3 short of
                    // over-fitting), plus a voxel, and never under two voxels.
                    w[j * nx + i] = SIMD2(centre, max(2 * voxel, half * pow(thickness[j * nx + i] / rowMax, 2) + voxel))
                }
            }
            window = w
        }

        // Carve (padded by one empty voxel all round, so the surface closes).
        let px = nx + 2, py = ny + 2, pz = nz + 2
        var field = [Float](repeating: 0, count: px * py * pz)
        func at(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * py + j) * px + i }
        var kept = 0
        for k in 0..<nz {
            if cancelled() { throw CancellationError() }
            for j in 0..<ny { for i in 0..<nx {
                let x = (Float(i) + 0.5) / Float(nx) * X - X / 2, y = (Float(j) + 0.5) / Float(ny), z = (Float(k) + 0.5) / Float(nz) * Z - Z / 2
                if let halfDepth, abs(z) > halfDepth[j * nx + i] { continue }
                if let window { let w = window[j * nx + i]; if abs(z - w.x) > w.y { continue } }
                var keep = true
                for view in photos.keys {
                    let (u, v) = project(view, x, y, z)
                    if !inside(view, u, v) { keep = false; break }
                }
                if keep { field[at(i + 1, j + 1, k + 1)] = 1; kept += 1 }
            } }
        }
        guard kept > 8 else { throw MultiViewError.empty }

        // Soften once (centre-weighted) so the surface is smooth, while
        // narrow gaps (between the legs, arm and body) stay open.
        do {
            var next = field
            for k in 1..<(pz - 1) { for j in 1..<(py - 1) { for i in 1..<(px - 1) {
                var s = field[at(i, j, k)] * 6
                s += field[at(i - 1, j, k)] + field[at(i + 1, j, k)] + field[at(i, j - 1, k)] + field[at(i, j + 1, k)] + field[at(i, j, k - 1)] + field[at(i, j, k + 1)]
                next[at(i, j, k)] = s / 12
            } } }
            field = next
        }

        // Surface nets at 0.5.
        let iso: Float = 0.5
        var cellVertex = [Int32](repeating: -1, count: px * py * pz)
        var positions: [Float] = []
        func world(_ fi: Float, _ fj: Float, _ fk: Float) -> SIMD3<Float> {
            SIMD3((fi - 1) / Float(nx) * X - X / 2, (fj - 1) / Float(ny), (fk - 1) / Float(nz) * Z - Z / 2)
        }
        let corners: [(Int, Int, Int)] = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        for k in 0..<(pz - 1) { for j in 0..<(py - 1) { for i in 0..<(px - 1) {
            let values = corners.map { field[at(i + $0.0, j + $0.1, k + $0.2)] }
            let insideCount = values.filter { $0 > iso }.count
            guard insideCount > 0 && insideCount < 8 else { continue }
            var sum = SIMD3<Float>.zero, n: Float = 0
            for (a, b) in edges where (values[a] > iso) != (values[b] > iso) {
                let t = (iso - values[a]) / (values[b] - values[a])
                let ca = corners[a], cb = corners[b]
                sum += SIMD3(Float(ca.0) + (Float(cb.0 - ca.0)) * t, Float(ca.1) + Float(cb.1 - ca.1) * t, Float(ca.2) + Float(cb.2 - ca.2) * t)
                n += 1
            }
            let local = sum / n
            // Voxel centres sit at index + 0.5 in the padded grid.
            let p = world(Float(i) + local.x + 0.5, Float(j) + local.y + 0.5, Float(k) + local.z + 0.5)
            cellVertex[at(i, j, k)] = Int32(positions.count / 3)
            positions += [p.x, p.y, p.z]
        } } }
        var indices: [UInt32] = []
        func quad(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, flip: Bool) {
            guard a >= 0, b >= 0, c >= 0, d >= 0 else { return }
            let q = [UInt32(a), UInt32(b), UInt32(c), UInt32(d)]
            indices += flip ? [q[0], q[2], q[1], q[0], q[3], q[2]] : [q[0], q[1], q[2], q[0], q[2], q[3]]
        }
        // Every grid edge with a sign change gets the quad of the 4 cells
        // around it (including edges from the empty border).
        for k in 0..<pz { for j in 0..<py { for i in 0..<px {
            let here = field[at(i, j, k)] > iso
            if i + 1 < px, j >= 1, k >= 1, here != (field[at(i + 1, j, k)] > iso) {
                quad(cellVertex[at(i, j - 1, k - 1)], cellVertex[at(i, j, k - 1)], cellVertex[at(i, j, k)], cellVertex[at(i, j - 1, k)], flip: !here)
            }
            if j + 1 < py, i >= 1, k >= 1, here != (field[at(i, j + 1, k)] > iso) {
                quad(cellVertex[at(i - 1, j, k - 1)], cellVertex[at(i - 1, j, k)], cellVertex[at(i, j, k)], cellVertex[at(i, j, k - 1)], flip: !here)
            }
            if k + 1 < pz, i >= 1, j >= 1, here != (field[at(i, j, k + 1)] > iso) {
                quad(cellVertex[at(i - 1, j - 1, k)], cellVertex[at(i, j - 1, k)], cellVertex[at(i, j, k)], cellVertex[at(i - 1, j, k)], flip: !here)
            }
        } } }
        guard !indices.isEmpty else { throw MultiViewError.empty }

        // Texture: one tile per photo; each triangle uses the photo facing it.
        let views = PhotoView.allCases.filter { photos[$0] != nil }
        let cols = min(3, views.count), rows = (views.count + cols - 1) / cols
        let T = options.tile
        var atlas = RasterImage(width: cols * T, height: rows * T, fill: [128, 128, 128, 255])
        for (n, view) in views.enumerated() {
            let p = photos[view]!, c = crops[view]!
            let ox = (n % cols) * T, oy = (n / cols) * T
            for y in 0..<T { for x in 0..<T {
                let sx = c.x0 + min(c.w - 1, x * c.w / T), sy = c.y0 + min(c.h - 1, y * c.h / T)
                let s = (sy * p.image.width + sx) * 4, d = ((oy + y) * atlas.width + ox + x) * 4
                guard s + 3 < p.image.rgba.count else { continue }
                for q in 0..<4 { atlas.rgba[d + q] = q == 3 ? 255 : p.image.rgba[s + q] }
            } }
        }
        var mesh = GeneratedMesh()
        var remap: [Int: UInt32] = [:]
        for t in 0..<(indices.count / 3) {
            let ids = [Int(indices[t * 3]), Int(indices[t * 3 + 1]), Int(indices[t * 3 + 2])]
            let pts = ids.map { SIMD3(positions[$0 * 3], positions[$0 * 3 + 1], positions[$0 * 3 + 2]) }
            let e1 = pts[1] - pts[0], e2 = pts[2] - pts[0]
            let normal = SIMD3(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x)
            var best = 0, score = -Float.infinity
            for (n, view) in views.enumerated() { let d = (normal * view.direction).sum(); if d > score { score = d; best = n } }
            let view = views[best]
            for (slot, id) in ids.enumerated() {
                let key = id * 8 + best
                if let existing = remap[key] { mesh.indices.append(existing); continue }
                let p = pts[slot]
                let (u, v) = project(view, p.x, p.y, p.z)
                let au = (Float(best % cols) + min(1, max(0, u))) / Float(cols), av = (Float(best / cols) + min(1, max(0, v))) / Float(rows)
                let index = UInt32(mesh.vertexCount)
                mesh.positions += [p.x, p.y, p.z]; mesh.normals += [0, 0, 1]; mesh.uvs += [au, 1 - av]
                remap[key] = index
                mesh.indices.append(index)
            }
        }
        mesh.computeNormals()
        // Seams between photos split vertices; normals are averaged back
        // across them so lighting has no hard creases.
        var shared: [SIMD3<Int32>: SIMD3<Float>] = [:]
        func key(_ v: Int) -> SIMD3<Int32> { SIMD3(Int32((mesh.positions[v * 3] * 1e4).rounded()), Int32((mesh.positions[v * 3 + 1] * 1e4).rounded()), Int32((mesh.positions[v * 3 + 2] * 1e4).rounded())) }
        for v in 0..<mesh.vertexCount { shared[key(v), default: .zero] += SIMD3(mesh.normals[v * 3], mesh.normals[v * 3 + 1], mesh.normals[v * 3 + 2]) }
        for v in 0..<mesh.vertexCount {
            var n = shared[key(v)]!; let l = rigLength(n); if l > 0 { n /= l }
            mesh.normals[v * 3] = n.x; mesh.normals[v * 3 + 1] = n.y; mesh.normals[v * 3 + 2] = n.z
        }
        if views.count < 6 { notes.append(L10n.t("用了 \(views.count) 张照片；没有拍到的方向用相邻照片的颜色", "Used \(views.count) photos; directions without a photo take colours from the nearest one")) }
        notes.append(L10n.t("由轮廓雕刻：照片之间的凹陷细节无法还原", "Carved from outlines: hollows between views cannot be recovered"))
        return MultiViewResult(mesh: mesh, atlas: atlas, views: views, notes: notes)
    }
}
