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
enum RPGCombatAction:Equatable,Sendable {case attack,skill,roll}
enum RPGCombatError:Error,LocalizedError {
    case exhausted,cooldown,dead,locked
    var errorDescription:String? {
        switch self {case .exhausted:"耐力不足。";case .cooldown:"动作仍在冷却。";case .dead:"请先在安全入口复苏。";case .locked:"战斗中不能更换装备。"}
    }
}
enum RPGCombatRules {
    private static func distance(_ a:SurfacePoint,_ b:SurfacePoint)->Int{abs(a.x-b.x)+abs(a.z-b.z)}
    static func seedEnemies(world:inout WorldState,generator:RPGWorldGenerator,coordinates:[ChunkCoordinate]) {
        var candidates:[RPGEnemyState]=[]
        for coordinate in coordinates {
            let n=RPGWorldGenerator.hash(seed:world.seed,x:coordinate.x,z:coordinate.z,salt:321)
            guard n%3==0 else{continue}
            let id="enemy:g1:\(world.seed):\(coordinate.id)"
            let point=SurfacePoint(x:coordinate.x*32+3+Int(n%26),z:coordinate.z*32+3+Int((n>>8)%26))
            if generator.tile(at:point)?.passable==true && !generator.protected(point) && distance(point,generator.anchor(.spawn))>10 {
                candidates.append(.init(id:id,surface:point))
            }
        }
        let region=generator.sideRegion
        if distance(world.player.surface,generator.anchor(.temple))<30 || world.player.perspective == .side {
            let u=(22..<min(36,region.width)).first{u in let p=SurfacePoint(x:region.origin.x+u,z:region.origin.z);return generator.tile(at:p)?.passable==true && RPGWorldEditing.entity(at:p,world:world,generator:generator)==nil} ?? 22
            candidates.append(.init(id:"enemy:shared:\(world.seed)",scope:.shared,surface:.init(x:region.origin.x+u,z:region.origin.z),side:.init(regionID:region.id,horizontal:u,height:1)))
            candidates.append(.init(id:"enemy:side:\(world.seed)",scope:.sideOnly,surface:nil,side:.init(regionID:region.id,horizontal:38,height:1)))
        }
        if distance(world.player.surface,generator.anchor(.boss))<25 {
            let p=generator.anchor(.boss)
            candidates.append(.init(id:"enemy:boss:\(world.seed)",boss:true,surface:.init(x:p.x+3,z:p.z),health:120,maximumHealth:120))
        }
        let existing=Set(world.combat.enemies.map(\.id))
        for candidate in candidates where !existing.contains(candidate.id) && world.combat.enemies.count<128 {world.combat.enemies.append(candidate);world.revision+=1}
    }
    static func nextStep(from:SurfacePoint,to:SurfacePoint,passable:(SurfacePoint)->Bool)->SurfacePoint? {
        guard from.valid,to.valid else{return nil}
        var queue=[from],parent:[SurfacePoint:SurfacePoint]=[:],visited:Set<SurfacePoint>=[from],head=0
        while head<queue.count && visited.count<=512 {
            let p=queue[head];head+=1
            if p==to {
                var cursor=p
                while let previous=parent[cursor],previous != from{cursor=previous}
                return cursor==from ? nil : cursor
            }
            for d in [(1,0),(-1,0),(0,1),(0,-1)] {
                let next=SurfacePoint(x:p.x+d.0,z:p.z+d.1)
                if next.valid && distance(next,from)<=12 && !visited.contains(next) && passable(next){visited.insert(next);parent[next]=p;queue.append(next)}
            }
        }
        return nil
    }
    static func trainingEncounter(world:inout WorldState,generator:RPGWorldGenerator) {
        guard world.player.health>0,!world.player.inCombat,world.combat.enemies.count<128 else{return}
        let id="enemy:training:\(world.seed):\(world.revision)"
        guard !world.combat.enemies.contains(where:{$0.id==id}) else{return}
        if world.player.perspective == .side,let player=world.player.side,let region=world.sideRegions.first {
            let u=min(region.width-1,player.horizontal+2)
            world.combat.enemies.append(.init(id:id,scope:.sideOnly,surface:nil,side:.init(regionID:player.regionID,horizontal:u,height:player.height),aggro:true))
        }else{
            let p=world.player.surface
            let point=[SurfacePoint(x:p.x+2,z:p.z),.init(x:p.x-2,z:p.z)].first{$0.valid && generator.tile(at:$0)?.passable==true} ?? p
            world.combat.enemies.append(.init(id:id,surface:point,aggro:true))
        }
        world.player.inCombat=true;world.revision+=1
    }
    static func action(_ action:RPGCombatAction,world:inout WorldState,generator:RPGWorldGenerator,passable:(SurfacePoint)->Bool)throws {
        guard world.player.health>0 else{throw RPGCombatError.dead}
        var next=world
        let cost:Int,damage:Int,radius:Int
        switch action {
        case .attack:
            guard next.combat.attackRemaining<=0 else{throw RPGCombatError.cooldown};cost=8;damage=12+(world.player.weapon == .moonBlade ? 8:0);radius=2;next.combat.attackRemaining=0.35
        case .skill:
            guard next.combat.skillRemaining<=0 else{throw RPGCombatError.cooldown};cost=25;damage=25+(world.player.weapon == .moonBlade ? 8:0);radius=4;next.combat.skillRemaining=3
        case .roll:
            guard next.combat.rollRemaining<=0 else{throw RPGCombatError.cooldown};cost=18;damage=0;radius=0;next.combat.rollRemaining=1.2;next.combat.invulnerableRemaining=0.35
        }
        guard next.player.stamina>=cost else{throw RPGCombatError.exhausted};next.player.stamina-=cost
        if case .roll=action,world.player.perspective == .topDown {
            for _ in 0..<2 {
                let p=SurfacePoint(x:next.player.surface.x+world.player.facing.dx,z:next.player.surface.z+world.player.facing.dz)
                if passable(p){next.player.surface=p}
            }
        }
        if damage>0 {
            for index in next.combat.enemies.indices where next.combat.enemies[index].health>0 {
                let enemy=next.combat.enemies[index]
                let inRange:Bool
                if world.player.perspective == .side {
                    if let p=world.player.side,let e=enemy.side,p.regionID==e.regionID {
                        let u=e.horizontal-p.horizontal,h=e.height-p.height
                        inRange=abs(u)+abs(h)<=radius && (action == .skill || u*world.player.facing.dx>=0)
                    }else{inRange=false}
                }else if let p=enemy.surface,enemy.scope != .sideOnly {
                    let u=p.x-world.player.surface.x,v=p.z-world.player.surface.z
                    inRange=abs(u)+abs(v)<=radius && (action == .skill || u*world.player.facing.dx+v*world.player.facing.dz>=0)
                }else{inRange=false}
                guard inRange else{continue}
                next.combat.enemies[index].health=max(0,enemy.health-damage);next.combat.enemies[index].aggro=true
                if enemy.boss && enemy.phase==1 && next.combat.enemies[index].health<=enemy.maximumHealth/2 && next.combat.enemies[index].health>0 {
                    next.combat.enemies[index].phase=2;event("bossPhaseChanged",enemy:enemy,world:&next)
                }
                if next.combat.enemies[index].health==0 && !next.combat.defeatedIDs.contains(enemy.id) {
                    next.combat.defeatedIDs.append(enemy.id);next.combat.defeatedIDs.sort()
                    next.inventory["moon-shard",default:0]+=enemy.boss ? 3:1
                    event(enemy.boss ? "bossDefeated":"enemyDefeated",enemy:enemy,world:&next)
                }
            }
        }
        updateCombatFlag(&next);next.revision+=1
        guard next.combat.valid else{throw RPGWorldError.invalidState};world=next
    }
    static func advance(world:inout WorldState,generator:RPGWorldGenerator,delta:Double,passable:(SurfacePoint)->Bool) {
        guard delta.isFinite,delta>0,world.player.health>0 else{return}
        let dt=min(0.1,delta)
        world.combat.clock+=dt
        world.combat.attackRemaining=max(0,world.combat.attackRemaining-dt);world.combat.skillRemaining=max(0,world.combat.skillRemaining-dt)
        world.combat.rollRemaining=max(0,world.combat.rollRemaining-dt);world.combat.invulnerableRemaining=max(0,world.combat.invulnerableRemaining-dt)
        world.combat.staminaRemainder+=dt*12
        let stamina=Int(world.combat.staminaRemainder);world.combat.staminaRemainder-=Double(stamina)
        world.player.stamina=min(100,world.player.stamina+stamina)
        for index in world.combat.enemies.indices where world.combat.enemies[index].health>0 {
            world.combat.enemies[index].attackRemaining=max(0,world.combat.enemies[index].attackRemaining-dt)
            world.combat.enemies[index].moveRemaining=max(0,world.combat.enemies[index].moveRemaining-dt)
            let enemy=world.combat.enemies[index]
            let d:Int
            if world.player.perspective == .side {
                guard let p=world.player.side,let e=enemy.side,p.regionID==e.regionID else{continue};d=abs(p.horizontal-e.horizontal)+abs(p.height-e.height)
            }else{guard let p=enemy.surface,enemy.scope != .sideOnly else{continue};d=distance(p,world.player.surface)}
            if d>12{world.combat.enemies[index].aggro=false;continue}
            if d<=6 && !generator.protected(world.player.surface){world.combat.enemies[index].aggro=true}
            guard world.combat.enemies[index].aggro else{continue}
            if world.player.perspective == .topDown,d>1,enemy.moveRemaining<=0,let point=enemy.surface {
                if let step=nextStep(from:point,to:world.player.surface,passable:{ candidate in passable(candidate) && (enemy.scope != .shared || generator.sideRegion.contains(candidate)) }){world.combat.enemies[index].surface=step
                    if enemy.scope == .shared,let region=world.sideRegions.first,region.contains(step){world.combat.enemies[index].side?.horizontal=step.x-region.origin.x}
                }
                world.combat.enemies[index].moveRemaining=enemy.phase==2 ? 0.25:0.45
            }
            let reach=enemy.boss ? 2:1
            if d<=reach,enemy.attackRemaining<=0 {
                if world.combat.invulnerableRemaining<=0 {
                    let damage=max(1,(enemy.boss ? (enemy.phase==2 ? 14:10):7)-(world.player.armor == .stoneArmor ? 4:0))
                    world.player.health=max(0,world.player.health-damage)
                    world.combat.invulnerableRemaining=0.25
                }
                world.combat.enemies[index].attackRemaining=enemy.phase==2 ? 0.7:1.1
            }
            if world.player.health==0 {
                world.events.append(.init(id:"death:\(world.revision+1)",kind:"playerDied",entityID:"player",definitionID:"player"));break
            }
        }
        updateCombatFlag(&world);world.events=Array(world.events.suffix(256));world.revision+=1
    }
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
