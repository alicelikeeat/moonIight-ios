import Foundation

// Height-aware collision, player physics with moving-platform carry, and
// the tilting camera's visible-cell budget.

/// An axis-aligned box in world cells (x, y map; z height).
struct SpatialBox: Equatable, Sendable {
    var id: String
    var minX: Double, maxX: Double, minY: Double, maxY: Double, minZ: Double, maxZ: Double
    var collision: SpatialCollision
    var groupID: String?
    var buttonTarget: String?
    func overlapsFootprint(x: Double, y: Double, radius: Double) -> Bool {
        x + radius > minX && x - radius < maxX && y + radius > minY && y - radius < maxY
    }
    var center: SpatialVector { SpatialVector((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2) }
}

/// Where a moving group is this frame: rest pivot, offset and turn.
struct GroupFrame: Equatable, Sendable {
    var pivot: SpatialVector
    var offset: SpatialVector
    var yaw: Double
    /// A point that sits on the group at rest, moved to this frame.
    func place(_ point: SpatialVector) -> SpatialVector {
        let radians = yaw * .pi / 180, c = cos(radians), s = sin(radians)
        let dx = point.x - pivot.x, dy = point.y - pivot.y
        return SpatialVector(pivot.x + dx * c - dy * s + offset.x, pivot.y + dx * s + dy * c + offset.y, point.z + offset.z)
    }
    /// Moves a rider from where `previous` put it to where this frame does.
    func carry(_ point: SpatialVector, from previous: GroupFrame) -> SpatialVector {
        // Undo the previous pose, then apply this one.
        let radians = -previous.yaw * .pi / 180, c = cos(radians), s = sin(radians)
        let shifted = point - previous.offset
        let dx = shifted.x - pivot.x, dy = shifted.y - pivot.y
        let rest = SpatialVector(pivot.x + dx * c - dy * s, pivot.y + dx * s + dy * c, shifted.z)
        return place(rest)
    }
}

/// The world's collision shapes for one frame.
struct SpatialGeometry: Sendable {
    static let playerRadius = 0.3
    static let playerHeight = 1.6
    private var cells: [Int: [SpatialBox]] = [:]
    private(set) var moving: [SpatialBox] = []
    private(set) var frames: [String: GroupFrame]
    /// Dug-out ground cells: no glass floor at height 0 there.
    var groundHoles: Set<Int> = []
    /// Blocks of moving groups (re-placed every frame by `moved(frames:)`).
    private var movingBlocks: [SpatialBlock] = []

    init(blocks: [SpatialBlock], plants: [PlantEntity] = [], frames: [String: GroupFrame] = [:]) {
        self.frames = frames
        for block in blocks {
            let half = block.size / 2
            var center = SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, 0)
            var lift = 0.0
            if let group = block.groupID, let frame = frames[group] {
                let placed = frame.place(center); center = SpatialVector(placed.x, placed.y, 0); lift = frame.offset.z
            }
            let box = SpatialBox(id: block.id, minX: center.x - half, maxX: center.x + half, minY: center.y - half, maxY: center.y + half,
                                 minZ: block.elevation + lift, maxZ: block.top + lift, collision: block.collision, groupID: block.groupID, buttonTarget: block.buttonTarget)
            if block.groupID.map({ frames[$0] != nil }) == true { moving.append(box); movingBlocks.append(block) } else { insert(box) }
        }
        for plant in plants where plant.kind.solid {
            let r = plant.kind == .tree ? 0.3 : 0.35, cx = Double(plant.x) + 0.5, cy = Double(plant.y) + 0.5
            insert(SpatialBox(id: plant.id, minX: cx - r, maxX: cx + r, minY: cy - r, maxY: cy + r, minZ: plant.z, maxZ: plant.z + (plant.kind == .tree ? 2.4 : 0.9) * plant.scale, collision: .solid))
        }
    }

    /// The same world with moving groups placed for new frames; static
    /// blocks are shared, so this is cheap enough to call every frame.
    func moved(frames newFrames: [String: GroupFrame]) -> SpatialGeometry {
        var copy = self
        copy.frames = newFrames
        copy.moving = movingBlocks.map { block in
            let half = block.size / 2
            var center = SpatialVector(Double(block.x) + 0.5, Double(block.y) + 0.5, 0), lift = 0.0
            if let group = block.groupID, let frame = newFrames[group] { let placed = frame.place(center); center = SpatialVector(placed.x, placed.y, 0); lift = frame.offset.z }
            return SpatialBox(id: block.id, minX: center.x - half, maxX: center.x + half, minY: center.y - half, maxY: center.y + half,
                              minZ: block.elevation + lift, maxZ: block.top + lift, collision: block.collision, groupID: block.groupID, buttonTarget: block.buttonTarget)
        }
        return copy
    }

    private mutating func insert(_ box: SpatialBox) {
        let x0 = max(0, Int(box.minX.rounded(.down))), x1 = min(WorldGeometry.width - 1, Int((box.maxX - 1e-9).rounded(.down)))
        let y0 = max(0, Int(box.minY.rounded(.down))), y1 = min(WorldGeometry.width - 1, Int((box.maxY - 1e-9).rounded(.down)))
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 { for x in x0...x1 { cells[y * WorldGeometry.width + x, default: []].append(box) } }
    }

    /// Boxes near a footprint (static by cell, plus every moving box).
    func boxes(x: Double, y: Double, radius: Double) -> [SpatialBox] {
        let x0 = max(0, Int((x - radius).rounded(.down))), x1 = min(WorldGeometry.width - 1, Int((x + radius).rounded(.down)))
        let y0 = max(0, Int((y - radius).rounded(.down))), y1 = min(WorldGeometry.width - 1, Int((y + radius).rounded(.down)))
        var seen = Set<String>(), result: [SpatialBox] = []
        if x0 <= x1, y0 <= y1 {
            for cy in y0...y1 { for cx in x0...x1 { for box in cells[cy * WorldGeometry.width + cx] ?? [] where seen.insert(box.id).inserted { result.append(box) } } }
        }
        for box in moving where box.overlapsFootprint(x: x, y: y, radius: radius + 0.5) && seen.insert(box.id).inserted { result.append(box) }
        return result.filter { $0.overlapsFootprint(x: x, y: y, radius: radius) }
    }

    /// The highest surface to stand on at or below `z + stepUp` (the glass
    /// ground at 0 counts everywhere). One-way platforms count only from above.
    func support(x: Double, y: Double, z: Double, radius: Double = playerRadius, stepUp: Double = 0.05, falling: Bool = true) -> (height: Double, box: SpatialBox?) {
        // The glass ground (height 0) holds unless the cell under the centre is dug out.
        let cell = Int(y.rounded(.down)) * WorldGeometry.width + Int(x.rounded(.down))
        var best: (Double, SpatialBox?) = groundHoles.contains(cell) || z < -0.01 ? (-Double.infinity, nil) : (0, nil)
        for box in boxes(x: x, y: y, radius: radius) where box.collision.supports {
            if box.collision == .oneWay && !falling { continue }
            if box.maxZ <= z + stepUp && box.maxZ >= best.0 { best = (box.maxZ, box) }
        }
        return best
    }

    /// True when a solid box occupies the body's span above its feet.
    func blocked(x: Double, y: Double, z: Double, radius: Double = playerRadius, height: Double = playerHeight, stepUp: Double = 0.5) -> Bool {
        boxes(x: x, y: y, radius: radius).contains { box in box.collision.blocksSides && box.maxZ > z + stepUp && box.minZ < z + height }
    }

    /// Headroom: the lowest solid ceiling above `z`.
    func ceiling(x: Double, y: Double, z: Double, radius: Double = playerRadius) -> Double? {
        boxes(x: x, y: y, radius: radius).filter { $0.collision == .solid && $0.minZ >= z + 0.1 }.map(\.minZ).min()
    }

    /// Trigger areas and button blocks the body touches.
    func touching(x: Double, y: Double, z: Double, radius: Double = playerRadius) -> [SpatialBox] {
        boxes(x: x, y: y, radius: radius + 0.05).filter { box in
            (box.collision == .trigger || box.buttonTarget != nil) && box.minZ <= z + SpatialGeometry.playerHeight && box.maxZ >= z - 0.1
        }
    }
}

struct SpatialInput: Equatable, Sendable {
    /// World direction (map x, y), length 0…1.
    var dx = 0.0
    var dy = 0.0
    var jump = false
}

enum SpatialPhysics {
    static let walkSpeed = 4.2
    static let gravity = 22.0
    static let jumpSpeed = 8.2
    static let stepUp = 0.5
    static let fallLimit = -24.0

    /// Jump apex in cells (for reachability checks): v² / 2g.
    static var jumpHeight: Double { jumpSpeed * jumpSpeed / (2 * gravity) }

    /// One physics step. `previous` is last frame's geometry so a player on
    /// a moving platform is carried with it (translation and turn).
    static func step(_ player: inout SpatialPlayer, input: SpatialInput, dt: Double, geometry: SpatialGeometry, previous: SpatialGeometry?) {
        guard dt > 0, dt.isFinite else { return }
        let dt = min(dt, 0.05)
        var p = player.position
        // Ride the platform under the feet.
        if player.grounded, let previous {
            let under = previous.support(x: p.x, y: p.y, z: p.z + 0.01, stepUp: 0.06).box
            if let group = under?.groupID, let before = previous.frames[group], let now = geometry.frames[group] {
                p = now.carry(p, from: before)
                player.facing += now.yaw - before.yaw
            }
        }
        // Walk, one axis at a time so walls slide instead of stopping dead.
        let length = min(1, (input.dx * input.dx + input.dy * input.dy).squareRoot())
        if length > 0.01 {
            let raw = max(1e-9, (input.dx * input.dx + input.dy * input.dy).squareRoot())
            let mx = input.dx / raw * length * walkSpeed * dt, my = input.dy / raw * length * walkSpeed * dt
            player.facing = atan2(input.dy, input.dx) * 180 / .pi
            for (ax, ay) in [(mx, 0.0), (0.0, my)] where ax != 0 || ay != 0 {
                let nx = min(Double(WorldGeometry.width) - 0.31, max(0.31, p.x + ax)), ny = min(Double(WorldGeometry.width) - 0.31, max(0.31, p.y + ay))
                if geometry.blocked(x: nx, y: ny, z: p.z, stepUp: player.grounded ? stepUp : 0.05) { continue }
                p.x = nx; p.y = ny
                // Walk up small steps.
                if player.grounded {
                    let step = geometry.support(x: p.x, y: p.y, z: p.z, stepUp: stepUp)
                    if step.height > p.z { p.z = step.height }
                }
            }
        }
        // Jump and gravity.
        if input.jump && player.grounded { player.verticalSpeed = jumpSpeed; player.grounded = false }
        player.verticalSpeed -= gravity * dt
        var nz = p.z + player.verticalSpeed * dt
        if player.verticalSpeed > 0, let ceiling = geometry.ceiling(x: p.x, y: p.y, z: p.z), nz + SpatialGeometry.playerHeight > ceiling {
            nz = ceiling - SpatialGeometry.playerHeight; player.verticalSpeed = 0
        }
        let floor = geometry.support(x: p.x, y: p.y, z: max(p.z, nz), stepUp: 0.05, falling: player.verticalSpeed <= 0)
        if player.verticalSpeed <= 0 && nz <= floor.height && p.z >= floor.height - stepUp {
            nz = floor.height; player.verticalSpeed = 0; player.grounded = true
        } else {
            player.grounded = false
        }
        p.z = nz
        if p.z < fallLimit {
            p = player.lastSafe; player.verticalSpeed = 0; player.grounded = true
        } else if player.grounded && floor.box?.groupID == nil {
            player.lastSafe = p
        }
        player.position = p
    }
}

// MARK: Camera

/// The tilting, turning camera. Tilt is measured from straight down:
/// 0° looks straight down (editing), 45° is the play view, 65° the most.
struct SpatialCameraState: Equatable, Sendable {
    var target = SpatialVector(128.5, 128.5, 0)
    var tilt = 45.0
    var yaw = 0.0
    var distance = 14.0
}

enum SpatialCameraRules {
    static let maxTilt = 65.0
    static let fieldOfView = 30.0
    static let editTilt = 0.0
    static let playTilt = 45.0
    static let minDistance = 3.0

    static func clampTilt(_ tilt: Double) -> Double { min(maxTilt, max(0, tilt.isFinite ? tilt : playTilt)) }

    /// Camera position for a state (world cells, z up).
    static func position(_ camera: SpatialCameraState) -> SpatialVector {
        let tilt = clampTilt(camera.tilt) * .pi / 180, yaw = camera.yaw * .pi / 180
        // At yaw 0 the camera leans back toward −y (south) of the target.
        let horizontal = sin(tilt) * camera.distance
        return SpatialVector(camera.target.x + sin(yaw) * horizontal, camera.target.y - cos(yaw) * horizontal, camera.target.z + cos(tilt) * camera.distance)
    }

    /// Ground cells inside the view, counting partly visible ones.
    static func visibleCells(_ camera: SpatialCameraState, aspect: Double) -> Int {
        let yaw = camera.yaw * .pi / 180
        let halfV = fieldOfView / 2 * .pi / 180, halfH = atan(tan(halfV) * aspect)
        let eye = position(camera)
        // Camera basis: forward toward the target, right, up.
        let forward = normalize(camera.target - eye)
        let right = normalize(SpatialVector(cos(yaw), sin(yaw), 0))
        let up = cross(right, forward)
        var corners: [SpatialVector] = []
        for (u, v) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
            let direction = forward + right * (u * tan(halfH)) + up * (v * tan(halfV))
            guard direction.z < -1e-6 else { return Int.max }
            let t = (camera.target.z - eye.z) / direction.z
            corners.append(eye + direction * t)
        }
        var area = 0.0, perimeter = 0.0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
            perimeter += (b - a).flatLength
        }
        let estimate = abs(area) / 2 + perimeter / 2 + 1
        return estimate > Double(Int.max / 2) ? Int.max : Int(estimate.rounded(.up))
    }

    /// The farthest distance that keeps at most `budget` ground cells in view.
    static func maxDistance(tilt: Double, yaw: Double = 0, aspect: Double, budget: Int = RPGCameraRules.visibleBudget) -> Double {
        var low = minDistance, high = 200.0
        let probe = { (distance: Double) in visibleCells(SpatialCameraState(target: SpatialVector(128, 128, 0), tilt: tilt, yaw: yaw, distance: distance), aspect: aspect) }
        if probe(low) > budget { return low }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if probe(middle) <= budget { low = middle } else { high = middle }
        }
        return low
    }

    static func clampDistance(_ camera: SpatialCameraState, aspect: Double) -> Double {
        min(maxDistance(tilt: camera.tilt, yaw: camera.yaw, aspect: aspect), max(minDistance, camera.distance.isFinite ? camera.distance : 14))
    }

    /// Stick input (screen x right, y down) to a world direction for the
    /// current camera turn: pushing up walks away from the camera.
    static func worldDirection(stickX: Double, stickY: Double, yaw: Double) -> (dx: Double, dy: Double) {
        let radians = yaw * .pi / 180
        let forward = (x: -sin(radians), y: cos(radians)), right = (x: cos(radians), y: sin(radians))
        return (right.x * stickX - forward.x * stickY, right.y * stickX - forward.y * stickY)
    }

    private static func normalize(_ v: SpatialVector) -> SpatialVector {
        let length = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return length > 0 ? v * (1 / length) : v
    }
    private static func cross(_ a: SpatialVector, _ b: SpatialVector) -> SpatialVector {
        SpatialVector(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
