import Foundation

enum RPGProjectionError: Error, LocalizedError, Equatable {
    case combat, entrance, blocked, mapping
    var errorDescription: String? {
        switch self {
        case .combat: "战斗中不能切换视角。"
        case .entrance: "请先回到双界神殿入口，再切换视角。"
        case .blocked: "目标落点被挡住，保持当前视角。"
        case .mapping: "当前区域没有可用的侧视映射。"
        }
    }
}
enum RPGProjectionRules {
    static func sideBaseEntities(world: WorldState, generator: RPGWorldGenerator) -> [WorldEntity] {
        guard let region = world.sideRegions.first else { return [] }
        let coordinates = Set((0..<region.width).compactMap { SurfacePoint(x: region.origin.x + $0, z: region.origin.z).chunk })
        var values = coordinates.sorted { $0.id < $1.id }.flatMap { generator.chunk($0)?.entities ?? [] }.filter { $0.side?.regionID == region.id }
        for (index, pair) in [(6,3),(10,5),(23,3),(28,5),(34,7),(40,4)].enumerated() where pair.0 + 3 < region.width {
            values.append(.init(id: "s1:\(world.seed):\(region.id):\(index)", definitionID: "platform", scope: .sideOnly, surface: nil,
                side: .init(regionID: region.id, horizontal: pair.0, height: pair.1),
                physics: .init(topDownSolid: false, sideSolid: true, sideGravity: false, pushable: false, hitPoints: 4, width: 3, height: 1)))
        }
        return values
    }
    static func sideEntities(world: WorldState, generator: RPGWorldGenerator) -> [WorldEntity] {
        let overrides = Set(world.entities.map(\.id)), removed = Set(world.removedGeneratedIDs)
        return sideBaseEntities(world: world, generator: generator).filter { !overrides.contains($0.id) && !removed.contains($0.id) } + world.entities.filter { $0.scope != .topDownOnly && $0.side != nil }
    }
    static func occupies(_ entity: WorldEntity, _ point: SidePlacement) -> Bool {
        guard let side = entity.side, side.regionID == point.regionID else { return false }
        return point.horizontal >= side.horizontal && Double(point.horizontal - side.horizontal) < entity.physics.width &&
               point.height >= side.height && Double(point.height - side.height) < entity.physics.height
    }
    static func switchPerspective(world: inout WorldState, generator: RPGWorldGenerator) throws {
        guard !world.player.inCombat else { throw RPGProjectionError.combat }
        guard let region = world.sideRegions.first(where: { $0.id == generator.sideRegion.id }) else { throw RPGProjectionError.mapping }
        var next = world
        if world.player.perspective == .topDown {
            guard world.player.surface == generator.anchor(.temple) else { throw RPGProjectionError.entrance }
            guard !sideEntities(world: world,generator: generator).contains(where: { $0.physics.sideSolid && occupies($0,region.landing) }) else { throw RPGProjectionError.blocked }
            next.player.side = region.landing; next.player.perspective = .side
        } else {
            guard let side = world.player.side, side.regionID == region.id,
                  abs(side.horizontal - region.landing.horizontal) <= 1, (1...3).contains(side.height) else { throw RPGProjectionError.entrance }
            let point = generator.anchor(.temple)
            guard generator.tile(at: point)?.passable == true, RPGWorldEditing.entity(at: point,world:world,generator:generator)?.physics.topDownSolid != true else { throw RPGProjectionError.blocked }
            next.player.surface = point; next.player.perspective = .topDown
        }
        next.revision += 1; try next.validate(); world = next
    }
    static func placeSide(_ point: SidePlacement, definitionID: String, world: inout WorldState, generator: RPGWorldGenerator) throws {
        guard world.player.perspective == .side else { throw RPGProjectionError.mapping }
        guard let region = world.sideRegions.first(where: { $0.id == point.regionID }), (0..<region.width).contains(point.horizontal), (1..<64).contains(point.height) else { throw RPGEditError.outside }
        if let player = world.player.side, world.player.mode == .adventure && abs(player.horizontal-point.horizontal)+abs(player.height-point.height)>4 { throw RPGEditError.tooFar }
        if point.height == 2 {
            let surface = SurfacePoint(x: region.origin.x + point.horizontal,z:region.origin.z)
            try RPGWorldEditing.place([.init(point:surface,definitionID:definitionID)],world:&world,generator:generator)
            return
        }
        let surface = SurfacePoint(x:region.origin.x+point.horizontal,z:region.origin.z)
        if !world.isCreativeCopy && generator.protected(surface) { throw RPGEditError.protectedArea }
        if let player = world.player.side, world.player.mode == .adventure && abs(player.horizontal-point.horizontal)+abs(player.height-point.height)>4 { throw RPGEditError.tooFar }
        guard let definition = BlockDefinition.find(definitionID) else { throw RPGEditError.unknownDefinition }
        guard world.player.side != point, !sideEntities(world:world,generator:generator).contains(where:{ occupies($0,point) }) else { throw RPGEditError.occupied }
        var next=world
        if world.player.mode == .adventure, let cost=definition.cost {
            guard next.inventory[cost,default:0]>0 else { throw RPGEditError.resources }; next.inventory[cost,default:0]-=1
        }
        let entity = WorldEntity(id:"placed:\(world.id):\(world.revision+1):side",definitionID:definition.id,scope:.sideOnly,surface:nil,side:point,
            physics:.init(topDownSolid:false,sideSolid:definition.solid,sideGravity:false,pushable:false,hitPoints:definition.durability,width:1,height:1))
        next.entities.append(entity)
        let change=RPGEntityChange(id:entity.id,before:nil,after:entity,removedBefore:false,removedAfter:false,damageBefore:nil,damageAfter:nil)
        try RPGWorldEditing.finish(next:&next,changes:[change],inventoryBefore:world.inventory,title:"侧视专属放置")
        world=next
    }
    static func hitSide(_ point: SidePlacement, world: inout WorldState, generator: RPGWorldGenerator, force: Bool=false) throws {
        guard world.player.perspective == .side else { throw RPGProjectionError.mapping }
        guard let target=sideEntities(world:world,generator:generator).first(where:{ occupies($0,point) }), let definition=BlockDefinition.find(target.definitionID) else { throw RPGEditError.unknownDefinition }
        if let player=world.player.side, world.player.mode == .adventure && abs(player.horizontal-point.horizontal)+abs(player.height-point.height)>4 { throw RPGEditError.tooFar }
        if let surface=target.surface { try RPGWorldEditing.hit(surface,world:&world,generator:generator,force:force); return }
        guard let region=world.sideRegions.first(where:{$0.id==point.regionID}) else { throw RPGProjectionError.mapping }
        let surface=SurfacePoint(x:region.origin.x+point.horizontal,z:region.origin.z)
        if !world.isCreativeCopy && generator.protected(surface) { throw RPGEditError.protectedArea }
        if let player=world.player.side, world.player.mode == .adventure && abs(player.horizontal-point.horizontal)+abs(player.height-point.height)>4 { throw RPGEditError.tooFar }
        var next=world; let damage=world.damage[target.id]
        let destroyed=(force && world.player.mode == .creative) || (damage ?? 0)+1>=target.physics.hitPoints
        if destroyed {
            next.entities.removeAll{$0.id==target.id}; next.damage[target.id]=nil
            if target.id.hasPrefix("s1:") { next.removedGeneratedIDs.append(target.id); next.removedGeneratedIDs.sort() }
            if let drop=definition.drop { next.inventory[drop,default:0]+=1 }
            next.events.append(.init(id:"event:\(world.revision+1):\(target.id)",kind:"blockDestroyed",entityID:target.id,definitionID:target.definitionID));next.events=Array(next.events.suffix(256))
        } else { next.damage[target.id]=(damage ?? 0)+1 }
        let change=RPGEntityChange(id:target.id,before:world.entities.first{$0.id==target.id},after:next.entities.first{$0.id==target.id},removedBefore:world.removedGeneratedIDs.contains(target.id),removedAfter:next.removedGeneratedIDs.contains(target.id),damageBefore:damage,damageAfter:next.damage[target.id])
        try RPGWorldEditing.finish(next:&next,changes:[change],inventoryBefore:world.inventory,title:destroyed ? "侧视破坏与掉落" : "侧视受击");world=next
    }
}
