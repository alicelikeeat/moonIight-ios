import Foundation

// v1.72: render generated 3D models into frames for GIF / video export and
// for eight-direction picture characters. A small software rasteriser:
// perspective, depth buffer, perspective-correct texture mapping, optional
// lighting, 2× supersampling. Pure Swift (tested on Linux); every frame is
// the real mesh (deformed by its rig when animated), not a stand-in.

/// RGBA8 image, rows top to bottom.
struct RasterImage: Equatable, Sendable {
    var width: Int
    var height: Int
    var rgba: [UInt8]

    init(width: Int, height: Int, fill: [UInt8] = [0, 0, 0, 0]) {
        self.width = width; self.height = height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { rgba[i * 4] = fill[0]; rgba[i * 4 + 1] = fill[1]; rgba[i * 4 + 2] = fill[2]; rgba[i * 4 + 3] = fill[3] }
    }
    init(width: Int, height: Int, rgba: [UInt8]) { self.width = width; self.height = height; self.rgba = rgba }

    func pixel(_ x: Int, _ y: Int) -> [UInt8] { let o = (y * width + x) * 4; return Array(rgba[o..<(o + 4)]) }
    /// Share of pixels with alpha > 0.
    var coverage: Double { Double(stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.count) / Double(max(1, width * height)) }
}

/// How a frame is shot.
struct RasterCamera: Equatable, Sendable {
    /// Turn of the model about its vertical axis, radians (0 = front).
    var yaw: Float = 0
    /// Tilt of the view, radians (positive looks down a little).
    var pitch: Float = 0.12
    var fieldOfView: Float = 35
    /// Extra space around the model.
    var margin: Float = 1.15
    var lighting = false
}

enum ModelRasterizer {
    /// Renders `positions` (the model, deformed or not) with the mesh's
    /// normals, UVs and triangles. The model is expected inside the unit
    /// cube (generated models are normalised that way).
    static func render(_ mesh: GeneratedMesh, positions: [Float]? = nil, normals: [Float]? = nil, texture: RasterImage?,
                       camera: RasterCamera, width: Int, height: Int, background: [UInt8] = [0, 0, 0, 0], supersample: Int = 2) -> RasterImage {
        let ss = max(1, supersample), w = width * ss, h = height * ss
        let p = positions ?? mesh.positions, n = normals ?? mesh.normals
        var color = [Float](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) { for k in 0..<4 { color[i * 4 + k] = Float(background[k]) } }
        var depth = [Float](repeating: .infinity, count: w * h)
        // Camera: model turned by yaw and pitch, eye on +z looking at the origin.
        let cy = cos(camera.yaw), sy = sin(camera.yaw), cp = cos(camera.pitch), sp = sin(camera.pitch)
        let f = 1 / tan(camera.fieldOfView * .pi / 360)
        let distance = 0.5 * camera.margin * f + 0.6
        let aspect = Float(w) / Float(h)
        func view(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
            let x1 = x * cy + z * sy, z1 = -x * sy + z * cy
            let y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp
            return (x1, y2, z2)
        }
        let count = mesh.vertexCount
        var sx = [Float](repeating: 0, count: count), syv = sx, inv = sx, lit = [Float](repeating: 1, count: count)
        let light: (Float, Float, Float) = (0.35, 0.6, 0.72)
        for i in 0..<count {
            let v = view(p[i * 3], p[i * 3 + 1], p[i * 3 + 2])
            let zc = distance - v.2
            inv[i] = zc > 0.01 ? 1 / zc : 0
            sx[i] = (v.0 * f * inv[i] / aspect * 0.5 + 0.5) * Float(w)
            syv[i] = (0.5 - v.1 * f * inv[i] * 0.5) * Float(h)
            if camera.lighting {
                let nv = view(n[i * 3], n[i * 3 + 1], n[i * 3 + 2])
                lit[i] = 0.45 + 0.55 * max(0, nv.0 * light.0 + nv.1 * light.1 + nv.2 * light.2)
            }
        }
        for t in 0..<mesh.triangleCount {
            let a = Int(mesh.indices[t * 3]), b = Int(mesh.indices[t * 3 + 1]), c = Int(mesh.indices[t * 3 + 2])
            guard inv[a] > 0, inv[b] > 0, inv[c] > 0 else { continue }
            let ax = sx[a], ay = syv[a], bx = sx[b], by = syv[b], cx = sx[c], cyy = syv[c]
            let area = (bx - ax) * (cyy - ay) - (by - ay) * (cx - ax)
            // Counter-clockwise in model space is clockwise on screen (y down): front faces have area < 0.
            guard area < -1e-6 else { continue }
            let minX = max(0, Int(min(ax, bx, cx))), maxX = min(w - 1, Int(max(ax, bx, cx)) + 1)
            let minY = max(0, Int(min(ay, by, cyy))), maxY = min(h - 1, Int(max(ay, by, cyy)) + 1)
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let px = Float(x) + 0.5
                    var w0 = (bx - px) * (cyy - py) - (by - py) * (cx - px)
                    var w1 = (cx - px) * (ay - py) - (cyy - py) * (ax - px)
                    var w2 = (ax - px) * (by - py) - (ay - py) * (bx - px)
                    guard w0 <= 0, w1 <= 0, w2 <= 0 else { continue }
                    w0 /= area; w1 /= area; w2 /= area
                    let iz = w0 * inv[a] + w1 * inv[b] + w2 * inv[c]
                    let z = 1 / iz
                    let index = y * w + x
                    guard z < depth[index] else { continue }
                    depth[index] = z
                    // Perspective-correct texture coordinates.
                    let u = (w0 * mesh.uvs[a * 2] * inv[a] + w1 * mesh.uvs[b * 2] * inv[b] + w2 * mesh.uvs[c * 2] * inv[c]) * z
                    let v = (w0 * mesh.uvs[a * 2 + 1] * inv[a] + w1 * mesh.uvs[b * 2 + 1] * inv[b] + w2 * mesh.uvs[c * 2 + 1] * inv[c]) * z
                    let shade = w0 * lit[a] + w1 * lit[b] + w2 * lit[c]
                    var rgb: (Float, Float, Float) = (230, 230, 235)
                    if let texture {
                        let tx = min(texture.width - 1, max(0, Int(u * Float(texture.width - 1) + 0.5)))
                        let ty = min(texture.height - 1, max(0, Int((1 - v) * Float(texture.height - 1) + 0.5)))
                        let o = (ty * texture.width + tx) * 4
                        rgb = (Float(texture.rgba[o]), Float(texture.rgba[o + 1]), Float(texture.rgba[o + 2]))
                    }
                    color[index * 4] = rgb.0 * shade; color[index * 4 + 1] = rgb.1 * shade; color[index * 4 + 2] = rgb.2 * shade; color[index * 4 + 3] = 255
                }
            }
        }
        // Downsample (box filter); colour averaged over covered samples so
        // transparent edges do not darken.
        var out = RasterImage(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            var r: Float = 0, g: Float = 0, b: Float = 0, alpha: Float = 0, covered: Float = 0
            for j in 0..<ss { for i in 0..<ss {
                let o = ((y * ss + j) * w + (x * ss + i)) * 4
                alpha += color[o + 3]
                if color[o + 3] > 0 { r += color[o]; g += color[o + 1]; b += color[o + 2]; covered += 1 }
            } }
            let o = (y * width + x) * 4
            let k = Float(ss * ss)
            if covered > 0 {
                out.rgba[o] = UInt8(min(255, r / covered)); out.rgba[o + 1] = UInt8(min(255, g / covered)); out.rgba[o + 2] = UInt8(min(255, b / covered))
            }
            out.rgba[o + 3] = UInt8(min(255, alpha / k))
        }}
        return out
    }
}

/// What to export and how.
enum ModelExportPlan {
    /// Turntable: one full turn.
    static func turntable(frames: Int) -> [RasterCamera] {
        (0..<max(1, frames)).map { RasterCamera(yaw: 2 * .pi * Float($0) / Float(max(1, frames))) }
    }

    /// Eight directions in the order picture characters use: front first,
    /// then clockwise seen from above.
    static let directionYaws: [Float] = (0..<8).map { -Float($0) * .pi / 4 }

    /// Clips baked into eight-direction picture characters, and the
    /// character action each one stands for.
    static let spriteClips: [(clip: String, actions: [CharacterAction])] = [
        ("idle", [.idle, .fall, .hurt, .death, .interact]),
        ("walk", [.walk, .run, .jump, .dodge]),
        ("wave", [.attack, .skill, .transform]),
    ]

    /// Frame times for one loop of a clip at `fps`.
    static func times(period: Float, fps: Float) -> [Float] {
        let n = max(2, Int((period * fps).rounded()))
        return (0..<n).map { period * Float($0) / Float(n) }
    }
}
