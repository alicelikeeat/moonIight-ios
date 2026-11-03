import Foundation

// Creatures, enemies and bosses in the 2.5D world: height-aware
// navigation, AI states, telegraphed boss attacks and combat hits that
// respect height difference and walls.

/// Standable surfaces and paths over them. A surface is the ground (0) or
/// the top of a supporting block, with room for a body above it.
final class SpatialNavigator: @unchecked Sendable {
    struct Node: Hashable, Sendable { let x: Int; let y: Int; let level: Int }
    let geometry: SpatialGeometry
    private var cache: [Int: [Double]] = [:]
    static let headroom = 1.5

    init(geometry: SpatialGeometry) { self.geometry = geometry }

    func surfaces(x: Int, y: Int) -> [Double] {
        guard (0..<WorldGeometry.width).contains(x), (0..<WorldGeometry.width).contains(y) else { return [] }
        let key = y * WorldGeometry.width + x
        if let cached = cache[key] { return cached }
        let cx = Double(x) + 0.5, cy = Double(y) + 0.5
        let boxes = geometry.boxes(x: cx, y: cy, radius: 0.25)
        var heights = [0.0] + boxes.filter { $0.collision.supports }.map(\.maxZ)
        heights = Array(Set(heights.map { ($0 * 20).rounded() / 20 })).sorted()
        let result = heights.filter { h in !boxes.contains { $0.collision.blocksSides && $0.maxZ > h + 0.05 && $0.minZ < h + Self.headroom } }
        cache[key] = result
        return result
    }

    func height(_ node: Node) -> Double { Double(node.level) / 20 }
    func node(near point: SpatialVector) -> Node? {
        let x = Int(point.x.rounded(.down)), y = Int(point.y.rounded(.down))
        guard let h = surfaces(x: x, y: y).min(by: { abs($0 - point.z) < abs($1 - point.z) }) else { return nil }
        return Node(x: x, y: y, level: Int((h * 20).rounded()))
    }

    /// Neighbours reachable by walking (`climb` up, `drop` down).
    func neighbours(_ node: Node, climb: Double, drop: Double) -> [Node] {
        let here = height(node)
        var result: [Node] = []
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            for h in surfaces(x: node.x + dx, y: node.y + dy) where h - here <= climb && here - h <= drop {
                result.append(Node(x: node.x + dx, y: node.y + dy, level: Int((h * 20).rounded())))
            }
        }
        return result
    }

    /// A* path; nil when unreachable within `limit` nodes.
    func path(from start: SpatialVector, to goal: SpatialVector, climb: Double = SpatialPhysics.stepUp, drop: Double = 6, limit: Int = 4000) -> [SpatialVector]? {
        guard let a = node(near: start), let b = node(near: goal) else { return nil }
        if a == b { return [] }
        func h(_ n: Node) -> Double { Double(abs(n.x - b.x) + abs(n.y - b.y)) + abs(height(n) - height(b)) }
        var open: [(Node, Double)] = [(a, h(a))], cost: [Node: Double] = [a: 0], came: [Node: Node] = [:], expanded = 0
        while !open.isEmpty && expanded < limit {
            let bestIndex = open.indices.min { open[$0].1 < open[$1].1 }!
            let current = open.remove(at: bestIndex).0
            if current.x == b.x && current.y == b.y && abs(height(current) - height(b)) < 0.3 {
                var path: [SpatialVector] = [], step = current
                while let previous = came[step] { path.append(SpatialVector(Double(step.x) + 0.5, Double(step.y) + 0.5, height(step))); step = previous }
                return path.reversed()
            }
            expanded += 1
            for next in neighbours(current, climb: climb, drop: drop) {
                let g = cost[current]! + 1 + abs(height(next) - height(current))
                if g < cost[next] ?? .infinity { cost[next] = g; came[next] = current; open.append((next, g + h(next))) }
            }
        }
        return nil
    }

    /// Every surface reachable from `start` (generator validation).
    func reachable(from start: SpatialVector, climb: Double, drop: Double = 64, limit: Int = 200_000) -> Set<Node> {
        guard let first = node(near: start) else { return [] }
        var seen: Set<Node> = [first], queue = [first], head = 0
        while head < queue.count && seen.count < limit {
            let current = queue[head]; head += 1
            for next in neighbours(current, climb: climb, drop: drop) where seen.insert(next).inserted { queue.append(next) }
        }
        return seen
    }
}

/// Something the AI did this step that the game must react to.
enum CreatureEvent: Equatable, Sendable {
    case hitPlayer(id: String, damage: Int)
    /// An attack is winding up (boss or mini boss area attack).
    case telegraph(id: String, radius: Double, seconds: Double)
    case areaHit(id: String, center: SpatialVector, radius: Double, damage: Int)
}

/// Runtime-only steering (not saved): the path being followed.
struct CreatureBrain: Sendable {
    var path: [SpatialVector] = []
    var repath = 0.0
    var wanderTarget: SpatialVector?
    var areaCooldown = 4.0
}

enum SpatialAI {
    struct Profile { let speed: Double; let detect: Double; let leash: Double; let reach: Double; let windUp: Double; let cooldown: Double }
    static func profile(_ creature: CreatureEntity) -> Profile {
        switch creature.kind {
        case .neutral: Profile(speed: 1.2, detect: 0, leash: 6, reach: 0, windUp: 0, cooldown: 0)
        case .enemy: Profile(speed: 2.2, detect: 7, leash: 14, reach: 1.3, windUp: 0.45, cooldown: 1.2)
        case .guardian: Profile(speed: 2.0, detect: 6, leash: 8, reach: 1.3, windUp: 0.45, cooldown: 1.0)
        case .miniBoss: Profile(speed: 2.1, detect: 8, leash: 12, reach: 1.6, windUp: 0.7, cooldown: 1.4)
        case .boss: Profile(speed: creature.phase >= 2 ? 2.4 : 1.8, detect: 7, leash: 7.5, reach: 2.0, windUp: creature.phase >= 2 ? 0.7 : 1.0, cooldown: creature.phase >= 2 ? 1.0 : 1.6)
        }
    }

    /// One AI step. Hostiles only notice a living player inside their
    /// detection range, so nothing attacks a player who just spawned.
    static func step(_ creature: inout CreatureEntity, brain: inout CreatureBrain, player: SpatialVector, playerAlive: Bool,
                     dt: Double, geometry: SpatialGeometry, navigator: SpatialNavigator?, random: Double) -> [CreatureEvent] {
        guard creature.alive, dt > 0 else { return [] }
        let profile = profile(creature)
        creature.stateTime += dt
        creature.cooldown = max(0, creature.cooldown - dt)
        brain.areaCooldown = max(0, brain.areaCooldown - dt)
        if creature.kind == .boss { creature.phase = creature.health * 2 <= creature.maxHealth ? 2 : 1 }
        var events: [CreatureEvent] = []
        let toPlayer = player - creature.position
        let distance = toPlayer.flatLength, heightGap = abs(toPlayer.z)
        let fromHome = (creature.position - creature.home).flatLength
        let playerFromHome = (player - creature.home).flatLength

        // A wound-up attack lands when its timer runs out.
        if let windUp = creature.windUp {
            let left = windUp - dt
            if left > 0 { creature.windUp = left; return events }
            creature.windUp = nil
            if creature.state == .attack {
                if creature.kind.isBoss && brain.areaCooldown <= 0.05 && creature.stateTime > 0 {
                    let radius = creature.kind == .boss ? (creature.phase >= 2 ? 4.0 : 3.0) : 2.5
                    events.append(.areaHit(id: creature.id, center: creature.position, radius: radius, damage: creature.damage + 4))
                    brain.areaCooldown = creature.kind == .boss ? (creature.phase >= 2 ? 4.5 : 7) : 6
                } else if distance <= profile.reach + 0.4 && heightGap <= 1.3 && playerAlive {
                    events.append(.hitPlayer(id: creature.id, damage: creature.damage))
                }
                creature.cooldown = profile.cooldown
                creature.state = .chase
            }
            return events
        }

        if creature.state == .hurt && creature.stateTime < 0.25 { return events }

        switch creature.kind {
        case .neutral:
            if creature.state != .wander || brain.wanderTarget == nil {
                if creature.stateTime > 2 + random * 2 || creature.state == .hurt {
                    let angle = random * 2 * .pi, radius = 1.5 + random * 3.5
                    brain.wanderTarget = SpatialVector(creature.home.x + cos(angle) * radius, creature.home.y + sin(angle) * radius, creature.home.z)
                    set(&creature, .wander)
                } else if creature.state != .idle && creature.state != .wander { set(&creature, .idle) }
            }
            if creature.state == .wander, let target = brain.wanderTarget {
                if advance(&creature, toward: target, speed: profile.speed, dt: dt, geometry: geometry, brain: &brain, navigator: navigator) {
                    brain.wanderTarget = nil; set(&creature, .idle)
                }
            }
        case .enemy, .guardian, .miniBoss, .boss:
            let noticed = playerAlive && heightGap <= 3 && (creature.kind == .boss ? playerFromHome <= profile.leash - 1 : distance <= profile.detect)
            let tooFar = fromHome > profile.leash || (creature.kind != .boss && distance > profile.detect * 1.7) || (creature.kind == .boss && playerFromHome > profile.leash)
            switch creature.state {
            case .idle, .patrol, .wander, .hurt:
                if noticed { set(&creature, .alert) }
                else if creature.kind == .guardian {
                    // Patrol back and forth across the post.
                    let side = Int(creature.stateTime / 3) % 2 == 0 ? 1.0 : -1.0
                    let post = SpatialVector(creature.home.x + 2.5 * side, creature.home.y, creature.home.z)
                    if creature.state != .patrol { creature.state = .patrol }
                    _ = advance(&creature, toward: post, speed: profile.speed * 0.6, dt: dt, geometry: geometry, brain: &brain, navigator: navigator)
                } else if creature.state == .hurt { set(&creature, .idle) }
            case .alert:
                if creature.stateTime > 0.35 { set(&creature, noticed ? .chase : .returning) }
            case .chase:
                if !playerAlive || tooFar { set(&creature, .returning); break }
                if creature.kind.isBoss && brain.areaCooldown <= 0 && distance <= 6 {
                    let radius = creature.kind == .boss ? (creature.phase >= 2 ? 4.0 : 3.0) : 2.5
                    creature.windUp = profile.windUp + 0.3; set(&creature, .attack)
                    events.append(.telegraph(id: creature.id, radius: radius, seconds: profile.windUp + 0.3))
                } else if distance <= profile.reach && heightGap <= 1.3 {
                    if creature.cooldown <= 0 {
                        creature.windUp = profile.windUp; set(&creature, .attack)
                        if creature.kind.isBoss { events.append(.telegraph(id: creature.id, radius: profile.reach, seconds: profile.windUp)) }
                    }
                } else {
                    _ = advance(&creature, toward: player, speed: profile.speed, dt: dt, geometry: geometry, brain: &brain, navigator: navigator)
                }
            case .attack:
                set(&creature, .chase)
            case .returning:
                if noticed && !tooFar && fromHome < profile.leash * 0.8 { set(&creature, .chase); break }
                if advance(&creature, toward: creature.home, speed: profile.speed, dt: dt, geometry: geometry, brain: &brain, navigator: navigator) {
                    // Back on post: recover a little, like most action games.
                    creature.health = min(creature.maxHealth, creature.health + creature.maxHealth / 4)
                    set(&creature, .idle)
                }
            case .dead: break
            }
        }
        return events
    }

    private static func set(_ creature: inout CreatureEntity, _ state: CreatureState) {
        creature.state = state; creature.stateTime = 0
    }

    /// Moves toward a point; walks straight while it can, follows an A*
    /// path around walls and up steps otherwise. True when arrived.
    @discardableResult
    static func advance(_ creature: inout CreatureEntity, toward target: SpatialVector, speed: Double, dt: Double,
                        geometry: SpatialGeometry, brain: inout CreatureBrain, navigator: SpatialNavigator?) -> Bool {
        var goal = target
        if let next = brain.path.first { goal = next }
        let delta = goal - creature.position, length = delta.flatLength
        if length < 0.2 {
            if !brain.path.isEmpty { brain.path.removeFirst(); return false }
            return (target - creature.position).flatLength < 0.6
        }
        let stepLength = min(length, speed * dt)
        let nx = creature.position.x + delta.x / length * stepLength, ny = creature.position.y + delta.y / length * stepLength
        let radius = creature.kind == .boss ? 0.6 : 0.3
        if geometry.blocked(x: nx, y: ny, z: creature.position.z, radius: radius, height: 1.4, stepUp: SpatialPhysics.stepUp) {
            brain.repath -= dt
            if brain.path.isEmpty || brain.repath <= 0, let navigator {
                brain.path = navigator.path(from: creature.position, to: target, limit: 1500) ?? []
                brain.repath = 1
                if brain.path.isEmpty { return true }
            }
            return false
        }
        let floor = geometry.support(x: nx, y: ny, z: creature.position.z + SpatialPhysics.stepUp, radius: radius * 0.6, stepUp: 0)
        // Do not walk off a ledge higher than a short drop.
        if creature.position.z - floor.height > 2.5 { brain.path = []; return true }
        creature.position = SpatialVector(nx, ny, floor.height)
        return false
    }
}

enum SpatialCombat {
    enum Attack: Sendable { case strike, skill }

    /// True when a solid block stands between two points at body height.
    static func occluded(_ a: SpatialVector, _ b: SpatialVector, geometry: SpatialGeometry) -> Bool {
        let steps = max(2, Int((b - a).flatLength * 3))
        for i in 1..<steps {
            let p = SpatialVector.lerp(a, b, Double(i) / Double(steps))
            let z = p.z + 0.8
            if geometry.boxes(x: p.x, y: p.y, radius: 0.05).contains(where: { $0.collision == .solid && $0.minZ < z && $0.maxZ > z }) { return true }
        }
        return false
    }

    /// Player attack: a strike hits in front within reach, the skill hits all
    /// around; both need a small height gap and a clear line.
    static func attack(_ attack: Attack, from player: SpatialVector, facing: Double, damage: Int,
                       creatures: inout [CreatureEntity], geometry: SpatialGeometry) -> [String] {
        let reach = attack == .strike ? 1.7 : 3.5, gap = attack == .strike ? 1.3 : 1.8
        var hits: [String] = []
        for i in creatures.indices where creatures[i].alive && creatures[i].kind != .neutral {
            let offset = creatures[i].position - player
            guard offset.flatLength <= reach + (creatures[i].kind == .boss ? 0.6 : 0), abs(offset.z) <= gap else { continue }
            if attack == .strike && offset.flatLength > 0.3 {
                let angle = atan2(offset.y, offset.x) * 180 / .pi
                var difference = abs(angle - facing).truncatingRemainder(dividingBy: 360); if difference > 180 { difference = 360 - difference }
                if difference > 70 { continue }
            }
            if occluded(player, creatures[i].position, geometry: geometry) { continue }
            creatures[i].health = max(0, creatures[i].health - damage)
            creatures[i].state = creatures[i].health == 0 ? .dead : .hurt
            creatures[i].stateTime = 0; creatures[i].windUp = creatures[i].health == 0 ? nil : creatures[i].windUp
            hits.append(creatures[i].id)
        }
        return hits
    }

    /// Shards for defeating a creature.
    static func reward(_ kind: CreatureKind) -> Int {
        switch kind { case .neutral: 0; case .enemy: 1; case .guardian: 2; case .miniBoss: 8; case .boss: 25 }
    }
}
