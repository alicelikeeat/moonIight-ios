import Foundation

/// HumanBase: the shipped MakeHuman-based body loads, shapes and rigs.
func humanBaseTests() {
    guard let asset = HumanBaseAsset.shared else { check(false, "HumanBase: the shipped file loads (Resources/HumanBase/HumanBase.hbm)"); return }
    check(asset.vertexCount == 13_380 && asset.joints.count == 60 && asset.channels.count == 18 && asset.lods.count == 3,
          "HumanBase: 13 380 surface vertices, 60 joints, 18 shape channels, 3 LODs (\(asset.vertexCount), \(asset.joints.count), \(asset.channels.count), \(asset.lods.count))")
    let budgets = [20_000, 8_000, 2_000]
    check(zip(asset.lods, budgets).allSatisfy { $0.triangleCount <= $1 } && asset.lods[0].triangleCount > asset.lods[1].triangleCount && asset.lods[1].triangleCount > asset.lods[2].triangleCount,
          "HumanBase: LODs within 20k / 8k / 2k triangles (\(asset.lods.map(\.triangleCount)))")

    // Damaged files are refused, never half-read.
    if let url = HumanBaseAsset.url(), let data = try? Data(contentsOf: url) {
        var truncated = false, wrong = false, newer = false
        do { _ = try HumanBaseAsset.decode(data.prefix(data.count / 2)) } catch { truncated = true }
        do { _ = try HumanBaseAsset.decode(Data("NOPE".utf8) + data.dropFirst(4)) } catch HumanBaseAsset.Failure.notHumanBase { wrong = true } catch {}
        var bumped = data; bumped[4] = 9
        do { _ = try HumanBaseAsset.decode(bumped) } catch HumanBaseAsset.Failure.newerVersion(9) { newer = true } catch {}
        var bad = data; for k in 12..<16 { bad[k] = 0xFF }   // first x becomes NaN
        let nan = (try? HumanBaseAsset.decode(bad)) == nil
        check(truncated && wrong && newer && nan, "HumanBase: truncated, foreign, newer-version and NaN files are refused")
    }

    guard let body = HumanBase.build(.standard) else { check(false, "HumanBase: builds"); return }
    do { try body.skeleton.validate() } catch { check(false, "HumanBase: the skeleton validates (\(error))") }
    let standardTags = Set(body.skeleton.joints.map(\.semanticTag)).subtracting([.other])
    check(standardTags.count == 27 && body.skeleton.joints.filter(\.isExtension).count == 33,
          "HumanBase: the 27 standard joints plus 33 extensions (fingers, jaw, eyes)")
    check(body.skeleton.joints.allSatisfy { $0.source == .authored }, "HumanBase: every joint is marked as authored")
    let m = body.mesh, b = m.bounds
    check(m.valid && m.positions.allSatisfy(\.isFinite) && m.normals.allSatisfy(\.isFinite) && m.uvs.allSatisfy { $0.isFinite && $0 >= -0.01 && $0 <= 1.01 },
          "HumanBase: valid mesh, finite positions, normals and UVs")
    check(abs(b.max[1] - 1.75) < 0.01 && abs(b.min[1]) < 0.001 && abs(b.min[0] + b.max[0]) < 0.02, "HumanBase: 1.75 m, feet on the ground, mirrored (\(b.min) … \(b.max))")
    // T-pose: hands level with the shoulders, out to the sides; right is −x.
    if let rs = body.skeleton.position(.rightUpperArm), let rh = body.skeleton.position(.rightHand), let lh = body.skeleton.position(.leftHand) {
        check(abs(rh.y - rs.y) < 0.05 && rh.x < rs.x - 0.4 && lh.x > 0.4, "HumanBase: bound in a T-pose (hand \(rh), shoulder \(rs))")
    }
    var sums = true
    for v in 0..<m.vertexCount {
        var s: Float = 0
        for k in 0..<4 where body.skin.joints[v * 4 + k] != 255 { s += body.skin.weights[v * 4 + k] }
        if abs(s - 1) > 0.01 { sums = false }
    }
    check(sums && body.skin.valid(jointCount: body.skeleton.joints.count, vertexCount: m.vertexCount), "HumanBase: four weights per vertex summing to 1")
    // Weights follow anatomy: the fingertips move with the fingers, the shins with the shins.
    var lowest = 0, leftmost = 0
    for v in 0..<m.vertexCount {
        if m.positions[v * 3 + 1] < m.positions[lowest * 3 + 1] { lowest = v }
        if m.positions[v * 3] < m.positions[leftmost * 3] { leftmost = v }
    }
    func strongest(_ v: Int) -> String {
        var best = 0
        for k in 1..<4 where body.skin.weights[v * 4 + k] > body.skin.weights[v * 4 + best] { best = k }
        return body.skeleton.joints[Int(body.skin.joints[v * 4 + best])].jointID
    }
    check(["rightFoot", "rightToe", "leftFoot", "leftToe"].contains(strongest(lowest)) && strongest(leftmost).hasPrefix("ext.rightFinger"),
          "HumanBase: the soles follow the feet, the right fingertip follows a right finger (\(strongest(lowest)), \(strongest(leftmost)))")

    // LODs: the same skeleton, fewer triangles, weights carried.
    let lods = (0..<3).compactMap { HumanBase.build(.standard, lod: $0) }
    check(lods.count == 3 && lods.allSatisfy { $0.skeleton == body.skeleton } && lods.map(\.mesh.triangleCount) == asset.lods.map(\.triangleCount),
          "HumanBase: every LOD shares the one skeleton")

    // Three different bodies from one base.
    let presets: [(String, HumanShape)] = [("standard", .standard), ("tall", .tall), ("chibi", .chibi)]
    var ratios: [String: BodyShape] = [:]
    for (name, shape) in presets {
        guard let built = HumanBase.build(shape) else { check(false, "HumanBase: \(name) builds"); continue }
        do { try built.skeleton.validate() } catch { check(false, "HumanBase: the \(name) skeleton validates (\(error))") }
        let bb = built.mesh.bounds
        check(abs(bb.max[1] - shape.height) < 0.02 && abs(bb.min[1]) < 0.001, "HumanBase: \(name) stands \(shape.height) m tall (\(bb.max[1]))")
        check(built.mesh.indices == body.mesh.indices && built.skin == body.skin, "HumanBase: \(name) keeps the topology and weights")
        // Joints sit inside the reshaped body: each hand joint is near hand vertices.
        if let hand = built.skeleton.position(.rightHand) {
            var near: Float = 9
            let pos = built.mesh.positions
            for v in 0..<built.mesh.vertexCount {
                let q = SIMD3<Float>(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2])
                near = min(near, cLength(q - hand))
            }
            check(near < 0.04 * shape.height, "HumanBase: \(name) wrist joint stays in the wrist (\(near) m from the surface)")
        }
        ratios[name] = built.bodyShape
    }
    if let s = ratios["standard"], let t = ratios["tall"], let c = ratios["chibi"] {
        check(c.headRatio > s.headRatio + 0.05 && c.legRatio < s.legRatio - 0.05 && t.legRatio > s.legRatio,
              "HumanBase: the chibi has a big head and short legs, the tall one long legs (head \(c.headRatio)/\(s.headRatio), legs \(c.legRatio)/\(s.legRatio)/\(t.legRatio))")
    }
    let wild = HumanShape(height: .nan, build: 9, legLength: -4, headSize: .infinity).clamped
    check(wild.height == 1.75 && wild.build == 1 && wild.legLength == 0.55 && wild.headSize == 1, "HumanBase: impossible parameters are clamped")
    print("RPG HumanBase: \(asset.vertexCount) vertices, \(asset.joints.count) joints, LOD triangles \(asset.lods.map(\.triangleCount))")
}
