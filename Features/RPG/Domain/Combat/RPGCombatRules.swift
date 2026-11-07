import Foundation

struct RPGDirection:Codable,Equatable,Sendable {
    var dx=1
    var dz=0
    var valid:Bool{(-1...1).contains(dx) && (-1...1).contains(dz) && (dx != 0 || dz != 0)}
}
enum RPGEquipment:String,Codable,CaseIterable,Sendable {case none,moonBlade,stoneArmor}
struct RPGEnemyState:Codable,Equatable,Identifiable,Sendable {
    var id:String
    var boss=false
    var scope=ProjectionScope.topDownOnly
    var surface:SurfacePoint?
    var side:SidePlacement?
    var health=30
    var maximumHealth=30
    var phase=1
    var attackRemaining=0.0
    var moveRemaining=0.0
    var aggro=false
    var valid:Bool {
        !id.isEmpty && id.count<=128 && (1...500).contains(maximumHealth) && (0...maximumHealth).contains(health) &&
        (1...3).contains(phase) && [attackRemaining,moveRemaining].allSatisfy{$0.isFinite && (0...3600).contains($0)}
    }
}
struct RPGCombatState:Codable,Equatable,Sendable {
    var clock=0.0
    var attackRemaining=0.0
    var skillRemaining=0.0
    var rollRemaining=0.0
    var invulnerableRemaining=0.0
    var staminaRemainder=0.0
    var enemies:[RPGEnemyState]=[]
    var defeatedIDs:[String]=[]
    var valid:Bool {
        clock.isFinite && (0...1e10).contains(clock) &&
        [attackRemaining,skillRemaining,rollRemaining,invulnerableRemaining,staminaRemainder].allSatisfy{$0.isFinite && (0...3600).contains($0)} &&
        enemies.count<=128 && enemies.allSatisfy(\.valid) && Set(enemies.map(\.id)).count==enemies.count &&
        defeatedIDs.count<=128 && Set(defeatedIDs).count==defeatedIDs.count &&
        defeatedIDs.allSatisfy{id in enemies.contains{$0.id==id && $0.health==0}}
    }
}
/// Gear on the shared save: one rule for every hit in the 3D world.
enum RPGGear {
    /// The moon blade adds 8 to every player attack.
    static func attackDamage(base: Int, weapon: RPGEquipment) -> Int { base + (weapon == .moonBlade ? 8 : 0) }
    /// Stone armour takes 4 off every hit, never below 1.
    static func damageTaken(_ raw: Int, armor: RPGEquipment) -> Int { raw <= 0 ? 0 : max(1, raw - (armor == .stoneArmor ? 4 : 0)) }
}

/// What is left of the old map's combat: the story's bookkeeping. Fights
/// themselves run in the 3D world (`SpatialCombat`, `SpatialBattle`).
enum RPGCombatRules {
    static func event(_ kind:String,enemy:RPGEnemyState,world:inout WorldState) {
        world.events.append(.init(id:"\(kind):\(world.revision+1):\(enemy.id)",kind:kind,entityID:enemy.id,definitionID:enemy.boss ? "boss":"slime"));world.events=Array(world.events.suffix(256))
    }
    static func updateCombatFlag(_ world:inout WorldState){
        let was=world.player.inCombat
        world.player.inCombat=world.player.health>0 && world.combat.enemies.contains{enemy in
            guard enemy.health>0,enemy.aggro else{return false}
            if world.player.perspective == .side{return enemy.side?.regionID==world.player.side?.regionID && enemy.side != nil}
            return enemy.surface != nil && enemy.scope != .sideOnly
        }
        if was && !world.player.inCombat && world.player.health>0{world.events.append(.init(id:"won:\(world.revision+1)",kind:"combatWon",entityID:"player",definitionID:"player"));world.events=Array(world.events.suffix(256))}
    }
}
