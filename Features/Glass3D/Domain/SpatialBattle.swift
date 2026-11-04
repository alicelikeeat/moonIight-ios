import Foundation

/// The running fight in the 3D world: skill casts from the player and
/// bosses, Boss phase changes with summons, hits, knockback and statuses.
/// Runtime only (not saved); creature health and defeat are saved with the
/// world. Deterministic for the same inputs.
struct SpatialBattle: Sendable {
    struct ActiveCast: Sendable { var cast: SkillCast; var casterID: String }
    struct BossRuntime: Sendable { var lastCast = -1_000.0; var phase = 0; var casts = 0; var summoned = 0 }

    static let castLimit = 24
    static let summonLimit = 12
    static let playerID = "player"

    private(set) var casts: [ActiveCast] = []
    /// Skill id → world time when it can be used again (player).
    private(set) var readyAt: [String: Double] = [:]
    private(set) var bossCooldowns: [String: [String: Double]] = [:]
    private(set) var bosses: [String: BossRuntime] = [:]
    var playerStatuses: [StatusEffect] = []

    enum CastResult: Equatable, Sendable { case cast, cooldown(Double), stamina, unknown }

    struct Output: Sendable {
        var playerDamage = 0
        var playerHealing = 0
        var visuals: [SkillVisual] = []
        var defeated: [CreatureEntity] = []
        var phaseChanges: [(id: String, phase: Int, appearance: String?)] = []
        var playerDash = SpatialVector.zero
        var creatureSpeed: [String: Double] = [:]
    }

    /// Built-in templates plus the world's own skills (own ones win).
    static func skill(_ id: String, in world: SpatialWorld) -> SkillDefinition? {
        world.skills?.first { $0.id == id } ?? SkillLibrary.templates().first { $0.id == id }
    }
    static func defaultHotbar() -> [String] { ["tpl.fireball", "tpl.ice", "tpl.beam", "tpl.meteor"] }
    static func script(for creature: CreatureEntity, in world: SpatialWorld) -> BossScript? {
        if let id = creature.bossScriptID { return world.bossScripts?.first { $0.id == id } }
        return creature.kind == .boss ? BossDirector.example(id: "builtin.boss") : nil
    }

    func cooldownLeft(_ skillID: String, clock: Double) -> Double { max(0, (readyAt[skillID] ?? 0) - clock) }

    /// The player casts a skill from the hotbar.
    mutating func castPlayer(_ skillID: String, world: SpatialWorld, origin: SpatialVector, facing: Double, target: String?, clock: Double,
                             stamina: inout Int, health: inout Int) -> CastResult {
        guard let skill = Self.skill(skillID, in: world) else { return .unknown }
        let left = cooldownLeft(skillID, clock: clock)
        guard left <= 0 else { return .cooldown(left) }
        guard stamina >= skill.staminaCost else { return .stamina }
        stamina -= skill.staminaCost
        readyAt[skillID] = clock + skill.cooldown
        let heal = SkillLibrary.healAmount(skill)
        if heal > 0 { health = min(100, health + heal) }
        if casts.count >= Self.castLimit { casts.removeFirst() }
        casts.append(ActiveCast(cast: SkillCast(skill: skill, faction: .player, origin: origin, facing: facing, target: target), casterID: Self.playerID))
        return .cast
    }

    /// One fight step.
    mutating func step(_ dt: Double, world: inout SpatialWorld, playerFacing: Double, playerInvulnerable: Bool, playerAlive: Bool,
                       geometry: SpatialGeometry?, clock: Double, roll: (String, Int) -> Double) -> Output {
        var output = Output()
        guard dt > 0 else { return output }
        let player = world.player.position
        // Bosses: phase changes, summons, skill casts.
        for index in world.creatures.indices {
            let creature = world.creatures[index]
            guard creature.alive, creature.kind.isBoss, let script = Self.script(for: creature, in: world) else { continue }
            var runtime = bosses[creature.id] ?? BossRuntime()
            let phase = BossDirector.phase(script, health: creature.health, maxHealth: creature.maxHealth)
            let settings = script.phases[phase]
            if phase != runtime.phase {
                runtime.phase = phase
                output.phaseChanges.append((creature.id, phase, settings.appearanceID))
                output.visuals.append(.particles(.charge, at: creature.position + SpatialVector(0, 0, 1), seconds: 1.2))
                if let summon = settings.summon {
                    let alive = world.creatures.filter { $0.alive && $0.id.hasPrefix("summon:\(creature.id):") }.count
                    let count = min(BossDirector.summonCount(summon, alive: alive), Self.summonLimit - runtime.summoned)
                    for n in 0..<max(0, count) {
                        let angle = Double(n) / Double(max(1, count)) * 2 * .pi
                        let position = creature.position + SpatialVector(cos(angle) * 2.5, sin(angle) * 2.5, 0)
                        runtime.summoned += 1
                        world.creatures.append(CreatureEntity(id: "summon:\(creature.id):\(runtime.summoned)", kind: summon.kind, position: position, home: position,
                                                              health: 30, maxHealth: 30, damage: 6, state: .alert, origin: .generated))
                    }
                }
            }
            output.creatureSpeed[creature.id] = settings.speed
            let distance = (player - creature.position).flatLength
            let engaged = playerAlive && distance <= 12 && abs(player.z - creature.position.z) < 4 && (creature.state == .chase || creature.state == .attack || creature.state == .alert)
            if engaged && clock - runtime.lastCast >= settings.castInterval {
                var cooldowns = bossCooldowns[creature.id] ?? [:]
                let ready = Set(settings.skills.map(\.skillID).filter { (cooldowns[$0] ?? 0) <= clock })
                if let id = BossDirector.pick(settings, ready: ready, roll: roll(creature.id, runtime.casts)), let skill = Self.skill(id, in: world), casts.count < Self.castLimit {
                    let facing = atan2(player.y - creature.position.y, player.x - creature.position.x) * 180 / .pi
                    casts.append(ActiveCast(cast: SkillCast(skill: skill, faction: .enemy, origin: creature.position, facing: facing, target: Self.playerID), casterID: creature.id))
                    cooldowns[id] = clock + skill.cooldown
                    runtime.lastCast = clock; runtime.casts += 1
                    bossCooldowns[creature.id] = cooldowns
                }
            }
            bosses[creature.id] = runtime
        }
        // Casts.
        var targets = [SkillTarget(id: Self.playerID, position: player, radius: 0.35, height: 1.5, faction: .player, invulnerable: playerInvulnerable || !playerAlive)]
        targets += world.creatures.filter { $0.alive && $0.kind != .neutral }.map {
            SkillTarget(id: $0.id, position: $0.position, radius: $0.kind == .boss ? 1.1 : $0.kind == .miniBoss ? 0.7 : 0.4, height: $0.kind == .boss ? 2.8 : 1.4, faction: .enemy)
        }
        var index = 0
        while index < casts.count {
            var active = casts[index]
            // Casts follow their caster (beams and areas are anchored to it).
            if active.casterID == Self.playerID { active.cast.origin = player; active.cast.facing = playerFacing }
            else if let caster = world.creatures.first(where: { $0.id == active.casterID }) {
                if caster.alive { active.cast.origin = caster.position; active.cast.facing = atan2(player.y - caster.position.y, player.x - caster.position.x) * 180 / .pi }
            }
            let result = active.cast.step(dt, targets: targets, geometry: geometry)
            for visual in result.visuals {
                if case .dash(let offset) = visual {
                    if active.casterID == Self.playerID { output.playerDash = output.playerDash + offset }
                    else if let i = world.creatures.firstIndex(where: { $0.id == active.casterID }) { world.creatures[i].position = world.creatures[i].position + offset }
                } else { output.visuals.append(visual) }
            }
            for hit in result.hits { apply(hit, world: &world, geometry: geometry, output: &output) }
            casts[index] = active
            if active.cast.finished { casts.remove(at: index) } else { index += 1 }
        }
        // Statuses.
        for i in world.creatures.indices where world.creatures[i].alive && !(world.creatures[i].statuses ?? []).isEmpty {
            var effects = world.creatures[i].statuses ?? []
            let change = StatusRules.step(&effects, dt: dt)
            world.creatures[i].statuses = effects.isEmpty ? nil : effects
            output.creatureSpeed[world.creatures[i].id] = (output.creatureSpeed[world.creatures[i].id] ?? 1) * change.speed
            if change.health < 0 { damage(i, Int((-change.health).rounded(.up)), world: &world, output: &output) }
        }
        if !playerStatuses.isEmpty {
            let change = StatusRules.step(&playerStatuses, dt: dt)
            if change.health < 0 { output.playerDamage += Int((-change.health).rounded(.up)) } else if change.health > 0 { output.playerHealing += Int(change.health.rounded(.up)) }
        }
        return output
    }

    private mutating func apply(_ hit: SkillHit, world: inout SpatialWorld, geometry: SpatialGeometry?, output: inout Output) {
        if hit.targetID == Self.playerID {
            output.playerDamage += hit.damage
            if let status = hit.status { StatusRules.apply(status, to: &playerStatuses) }
            if hit.knockback.flatLength > 0 { output.playerDash = output.playerDash + hit.knockback * 0.5 }
            return
        }
        guard let i = world.creatures.firstIndex(where: { $0.id == hit.targetID }), world.creatures[i].alive else { return }
        if let status = hit.status { var effects = world.creatures[i].statuses ?? []; StatusRules.apply(status, to: &effects); world.creatures[i].statuses = effects }
        // Knockback (bosses barely move), stopped by walls.
        if hit.knockback.flatLength > 0 {
            let scale = world.creatures[i].kind == .boss ? 0.1 : world.creatures[i].kind == .miniBoss ? 0.4 : 1
            let next = world.creatures[i].position + hit.knockback * scale
            if !(geometry?.blocked(x: next.x, y: next.y, z: world.creatures[i].position.z, radius: 0.3, height: 1.4) ?? false) { world.creatures[i].position = next }
        }
        damage(i, hit.damage, world: &world, output: &output)
    }

    private func damage(_ i: Int, _ amount: Int, world: inout SpatialWorld, output: inout Output) {
        world.creatures[i].health = max(0, world.creatures[i].health - amount)
        if world.creatures[i].health == 0 {
            world.creatures[i].state = .dead; world.creatures[i].windUp = nil; world.creatures[i].statuses = nil
            output.defeated.append(world.creatures[i])
        } else if world.creatures[i].state != .attack {
            world.creatures[i].state = .hurt; world.creatures[i].stateTime = 0
        }
    }
}
