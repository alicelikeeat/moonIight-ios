import Foundation

// Golden Scene Quality Gate: data checks a generated town must pass before
// it counts as golden. It runs on the built world (the same blocks the game
// walks on and both cameras draw), not on the plan.
//
// Passing this gate is necessary, not sufficient. The reference viewpoints
// still need a person to compare both views by eye
// (docs/golden-world/GOLDEN_WORLD_SPEC.md); a high score is not "looks good".

struct GoldenSceneReport: Equatable, Sendable {
    var violations: [String] = []
    /// 0…100 per dimension.
    var focal = 0.0
    var variety = 0.0
    var connectivity = 0.0
    var pixelClarity = 0.0
    var completeness = 0.0
    var materials = 0.0
    var budget = 0.0
    var blocks = 0
    var plants = 0
    var buildings = 0
    var unreachableDoors: [String] = []
    var blockedViewpoints: [String] = []

    var passed: Bool { violations.isEmpty }
    var total: Double { (focal + variety + connectivity + pixelClarity + completeness + materials + budget) / 7 }
}

enum GoldenSceneQualityGate {
    /// `isTown` tells town blocks from everything else (id prefix or World Director layer).
    static func evaluate(_ world: SpatialWorld, plan: GoldenCityPlan, budget: GoldenBudget, isTown: (SpatialBlock) -> Bool) -> GoldenSceneReport {
        var report = GoldenSceneReport()
        let town = world.blocks.filter(isTown)
        report.blocks = town.count
        let occluders = world.hybrid?.occluders ?? []
        let groupNames = Dictionary(world.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let placedGroups = Set(town.compactMap(\.groupID))
        let placed = occluders.filter { placedGroups.contains($0.groupID) }
        report.buildings = placed.count
        let specByName = Dictionary(plan.buildings.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        func spec(_ occluder: BuildingOccluder) -> KitBuildingSpec? {
            plan.buildings.first { $0.x0 == occluder.minX && $0.y0 == occluder.minY && $0.x1 == occluder.maxX && $0.y1 == occluder.maxY }
                ?? groupNames[occluder.groupID].flatMap { specByName[$0] }
        }
        let byCell = Dictionary(grouping: world.blocks, by: { $0.y * WorldGeometry.width + $0.x })

        // 1. A clear visual centre: the landmark is the tallest town structure by a margin, on the avenue axis.
        let landmark = plan.landmark
        let landmarkOccluder = placed.first { o in landmark.map { o.minX == $0.x0 && o.minY == $0.y0 } ?? false }
        if let landmark, let lo = landmarkOccluder {
            let landmarkTop = town.filter { $0.groupID == lo.groupID }.map(\.top).max() ?? 0
            let others = town.filter { $0.groupID != lo.groupID && $0.collision == .solid }.map(\.top).max() ?? 0
            let margin = landmarkTop - others
            let axis = abs(Double(landmark.x0 + landmark.x1) / 2 + 0.5 - 128) <= 2
            report.focal = min(100, max(0, margin) * 15) * (axis ? 1 : 0.5)
            if margin < 4 { report.violations.append("no clear focal point (landmark only \(String(format: "%.1f", margin)) above the rest)") }
            if !axis { report.violations.append("landmark is off the main avenue axis") }
        } else {
            report.violations.append("landmark missing")
        }

        // 2. No copies: every non-repeating building looks different.
        let specs = placed.compactMap(spec)
        let distinct = specs.filter { !$0.kind.repeats }
        let signatures = distinct.map(\.signature)
        let unique = Set(signatures).count
        report.variety = distinct.isEmpty ? 0 : 100 * Double(unique) / Double(distinct.count)
        if unique < signatures.count { report.violations.append("repeated buildings") }
        if distinct.count < 12 { report.violations.append("only \(distinct.count) key buildings (12 needed)") }

        // 3. No intersections and nothing floating.
        var intersecting = 0, floating = 0
        for (_, column) in byCell {
            let solids = column.filter { $0.collision == .solid }.sorted { $0.elevation < $1.elevation }
            for (i, a) in solids.enumerated() where i + 1 < solids.count {
                for b in solids[(i + 1)...] where b.elevation < a.top - 0.02 && a.elevation < b.top - 0.02 && (isTown(a) || isTown(b)) { intersecting += 1 }
            }
        }
        for block in town where block.collision == .solid && block.elevation > 0.05 {
            let k = block.y * WorldGeometry.width + block.x
            let below = (byCell[k] ?? []).contains { $0.id != block.id && $0.collision == .solid && abs($0.top - block.elevation) < 0.15 }
            if below { continue }
            var attached = false
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where !attached {
                let n = (block.y + dy) * WorldGeometry.width + block.x + dx
                attached = (byCell[n] ?? []).contains { $0.collision == .solid && $0.elevation < block.top + 0.01 && block.elevation < $0.top + 0.01 }
            }
            if !attached { floating += 1 }
        }
        if intersecting > 0 { report.violations.append("\(intersecting) intersecting blocks") }
        if floating > 0 { report.violations.append("\(floating) floating blocks") }

        // 4. Connected: every door, the bridge, the gate and the castle can be walked to from the spawn.
        let geometry = SpatialGeometry(blocks: world.blocks, plants: world.plants)
        let navigator = SpatialNavigator(geometry: geometry)
        let reach = navigator.reachable(from: plan.spawn.position, climb: 0.5, drop: 64)
        func reachable(_ x: Int, _ y: Int, near z: Double, slack: Int = 1) -> Bool {
            for dx in -slack...slack { for dy in -slack...slack {
                for h in navigator.surfaces(x: x + dx, y: y + dy) where abs(h - z) < 0.6 {
                    if reach.contains(SpatialNavigator.Node(x: x + dx, y: y + dy, level: Int((h * 20).rounded()))) { return true }
                }
            } }
            return false
        }
        var doors = 0, reachedDoors = 0
        for building in specs where !building.open {
            doors += 1
            let ok = building.doorSocket.contains { reachable($0.x, $0.y, near: building.base) }
            if ok { reachedDoors += 1 } else { report.unreachableDoors.append(building.name) }
        }
        let anchors = plan.viewpoints.filter { !$0.indoor }
        let reachedAnchors = anchors.filter { reachable(Int($0.x), Int($0.y), near: $0.z, slack: 2) }.count
        report.connectivity = 100 * (0.6 * (doors == 0 ? 1 : Double(reachedDoors) / Double(doors)) + 0.4 * (anchors.isEmpty ? 1 : Double(reachedAnchors) / Double(anchors.count)))
        if !report.unreachableDoors.isEmpty { report.violations.append("unreachable doors: " + report.unreachableDoors.joined(separator: ", ")) }
        if reachedAnchors < anchors.count { report.violations.append("\(anchors.count - reachedAnchors) viewpoints cannot be walked to") }

        // 5. Pixel view: after the roof cut and x-ray, the player stays visible on streets and at viewpoints.
        let occluderMap = Dictionary(occluders.map { ($0.groupID, $0) }, uniquingKeysWith: { first, _ in first })
        /// Sight from the player's head to the eye. With `xray`, what the occlusion pass hides or fades does not count.
        func clearSight(from p: SpatialVector, eye: SpatialVector, mode: WorldViewMode, xray: Bool = true, ignoring extra: Set<String> = []) -> Bool {
            let skipped: Set<String>
            if xray {
                let decision = OcclusionManager.resolve(player: p, cameraEye: eye, mode: mode, buildings: occluders)
                skipped = decision.hidden.union(decision.faded)
            } else {
                skipped = []
            }
            let head = SpatialVector(p.x, p.y, p.z + 1.2)
            let d = SpatialVector(eye.x - head.x, eye.y - head.y, eye.z - head.z)
            let length = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
            guard length > 0.5 else { return true }
            var t = 0.6
            while t < length {
                let q = SpatialVector(head.x + d.x * t / length, head.y + d.y * t / length, head.z + d.z * t / length)
                let k = Int(q.y.rounded(.down)) * WorldGeometry.width + Int(q.x.rounded(.down))
                for block in byCell[k] ?? [] where block.collision == .solid && q.z >= block.elevation && q.z <= block.top {
                    let half = block.size / 2
                    guard abs(q.x - (Double(block.x) + 0.5)) <= half, abs(q.y - (Double(block.y) + 0.5)) <= half else { continue }
                    if let group = block.groupID, extra.contains(group) { continue }
                    if let tag = OcclusionTag.of(block, occluders: occluderMap), skipped.contains(tag) { continue }
                    return false
                }
                t += 0.5
            }
            return true
        }
        let pixel = PixelRPGProfile()
        var samples = 0, clear = 0
        for (k, surface) in plan.roads.sorted(by: { $0.key < $1.key }) where surface != .outer && k % 3 == 0 {
            let c = GoldenCityPlan.cell(k)
            let p = SpatialVector(Double(c.x) + 0.5, Double(c.y) + 0.5, 0)
            samples += 1
            if clearSight(from: p, eye: DualPerspectiveCamera.pixelEye(target: p, profile: pixel), mode: .pixelRPG) { clear += 1 }
        }
        for vp in plan.viewpoints {
            let pixelOK = clearSight(from: vp.position, eye: DualPerspectiveCamera.pixelEye(target: vp.position, profile: pixel), mode: .pixelRPG)
            if !pixelOK { report.blockedViewpoints.append(vp.name + "（像素）") }
        }
        if !report.blockedViewpoints.isEmpty { report.violations.append("viewpoints hidden in pixel view: " + report.blockedViewpoints.joined(separator: ", ")) }
        let share = samples == 0 ? 1 : Double(clear) / Double(samples)
        report.pixelClarity = 100 * share
        if share < 0.9 { report.violations.append("pixel view hides the player on \(Int(((1 - share) * 100).rounded()))% of streets") }

        // 6. 3D view: complete buildings, and the landmark is in sight from the gate.
        var incomplete: [String] = []
        for building in specs {
            let group = placed.first { $0.minX == building.x0 && $0.minY == building.y0 }?.groupID
            let pieces = town.filter { $0.groupID == group }
            let roof = pieces.filter { $0.hybridPart == .roof }.count
            let sides = Set(pieces.filter { $0.hybridPart == .wall }.compactMap { building.side(x: $0.x, y: $0.y) })
            if roof < building.width * building.depth || (!building.open && sides.count < 4) { incomplete.append(building.name) }
        }
        report.completeness = specs.isEmpty ? 0 : 100 * Double(specs.count - incomplete.count) / Double(specs.count)
        if !incomplete.isEmpty { report.violations.append("incomplete buildings: " + incomplete.joined(separator: ", ")) }
        if let gate = plan.viewpoints.first(where: { $0.key == "gate" }), let landmark, let lo = landmarkOccluder {
            let state = SpatialCameraState(target: gate.position, tilt: SpatialCameraRules.playTilt, yaw: gate.yaw, distance: 14)
            let eye = SpatialCameraRules.position(state)
            let tip = SpatialVector(Double(landmark.x0 + landmark.x1) / 2 + 0.5, Double(landmark.y0 + landmark.y1) / 2 + 0.5, landmark.roofTop - 0.5)
            // Sight from the camera to the spire tip, ignoring the spire itself.
            if !clearSight(from: SpatialVector(tip.x, tip.y, tip.z - 1.2), eye: eye, mode: .spatial3D, xray: false, ignoring: [lo.groupID]) {
                report.blockedViewpoints.append(gate.name + "（3D 看不到尖塔）")
                report.violations.append("landmark hidden from the gate in 3D")
            }
        }

        // 7. One material family.
        let palette = plan.pack.palette
        let off = town.filter { !palette.contains($0.glass.tintHex ?? "") }.count
        report.materials = town.isEmpty ? 0 : 100 * Double(town.count - off) / Double(town.count)
        if off > 0 { report.violations.append("\(off) blocks outside the style palette") }

        // 8. Device budget.
        let townPlants = world.plants.filter { $0.origin == .generated }.count
        report.plants = townPlants
        let load = Double(town.count) / Double(max(1, budget.maxBlocks))
        report.budget = 100 * max(0, min(1, 1.2 - load * 0.5))
        if town.count > budget.maxBlocks { report.violations.append("over block budget (\(town.count) > \(budget.maxBlocks))") }
        if townPlants > budget.maxPlants { report.violations.append("over plant budget") }
        return report
    }
}
