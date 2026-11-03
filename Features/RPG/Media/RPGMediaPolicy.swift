import Foundation

enum RPGMediaRole: Int, Sendable { case interactive=1, background=2, player=3, cutscene=4 }
struct RPGMediaRequest: Equatable, Sendable {
    let ownerID: String
    let mediaID: String
    let role: RPGMediaRole
    let visible: Bool
}
enum RPGMediaPolicy {
    static func schedule(_ requests: [RPGMediaRequest], limit: Int) -> [String] {
        var seen=Set<String>(), counts:[RPGMediaRole:Int]=[:]
        return Array(requests.filter(\.visible).sorted {
            $0.role == $1.role ? $0.ownerID < $1.ownerID : $0.role.rawValue > $1.role.rawValue
        }.compactMap { request -> String? in
            if seen.contains(request.mediaID){return nil}
            let maximum = request.role == .interactive ? 2 : 1
            guard counts[request.role,default:0] < maximum else { return nil }; counts[request.role,default:0] += 1
            seen.insert(request.mediaID);return request.mediaID
        }.prefix(max(0,min(2,limit))))
    }
}
enum RPGMediaOwner: Equatable, Sendable {
    case player, background(Int), entity(String)
}
enum RPGMediaBindings {
    static func bindingID(for owner:RPGMediaOwner,in world:WorldState)->String? {
        switch owner {
        case .player:world.player.mediaBindingID
        case .background(let index):world.backgroundBindingIDs.indices.contains(index) ? world.backgroundBindingIDs[index] : nil
        case .entity(let id):world.entities.first{$0.id==id}?.mediaBindingID
        }
    }
    static func assign(mediaID:String,kind:RPGMediaKind,to owner:RPGMediaOwner,world:inout WorldState,generator:RPGWorldGenerator)throws {
        guard !mediaID.isEmpty else{throw RPGWorldError.invalidState}
        try assign(MediaBinding(id:"",mediaID:mediaID,kind:kind),to:owner,world:&world,generator:generator)
    }
    /// Binds a copy of `template` (any content kind) under a fresh identity.
    /// The previous binding stays in place for undo; unreferenced ones are
    /// pruned once the world approaches its binding limit.
    static func assign(_ template:MediaBinding,to owner:RPGMediaOwner,world:inout WorldState,generator:RPGWorldGenerator)throws {
        var binding=template;binding.id=UUID().uuidString
        guard binding.valid else{throw RPGWorldError.invalidState}
        var next=world
        if next.mediaBindings.count>=960 {try pruneUnreferenced(&next)}
        guard next.mediaBindings.count<1024 else{throw RPGWorldError.invalidState}
        next.mediaBindings.append(binding)
        switch owner {
        case .player:next.player.mediaBindingID=binding.id;next.revision+=1
        case .background(let index):
            guard (0..<3).contains(index),index<=next.backgroundBindingIDs.count else{throw RPGWorldError.invalidState}
            if index==next.backgroundBindingIDs.count{next.backgroundBindingIDs.append(binding.id)}else{next.backgroundBindingIDs[index]=binding.id}
            next.revision+=1
        case .entity(let id):
            let original=world.entities.first{$0.id==id} ?? generator.priorityChunks(around:world.player.surface).flatMap{generator.chunk($0)?.entities ?? []}.first{$0.id==id} ?? RPGProjectionRules.sideBaseEntities(world:world,generator:generator).first{$0.id==id}
            guard var entity=original,!world.removedGeneratedIDs.contains(id) else{throw RPGWorldError.missingReference}
            if let surface=entity.surface,!world.isCreativeCopy && generator.protected(surface){throw RPGEditError.protectedArea}
            let before=world.entities.first{$0.id==id};entity.mediaBindingID=binding.id
            next.entities.removeAll{$0.id==id};next.entities.append(entity)
            let change=RPGEntityChange(id:id,before:before,after:entity,removedBefore:false,removedAfter:false,damageBefore:world.damage[id],damageAfter:world.damage[id])
            try RPGWorldEditing.finish(next:&next,changes:[change],inventoryBefore:world.inventory,title:"绑定媒体牌面")
        }
        try next.validate();world=next
    }
    /// Drops bindings whose identity appears nowhere else in the world
    /// (entities, undo/redo history, story graphs, backgrounds, player).
    /// Matching on the raw encoded text is deliberately conservative: a
    /// binding mentioned anywhere is kept.
    static func pruneUnreferenced(_ world:inout WorldState)throws {
        var probe=world;probe.mediaBindings=[]
        let text=String(decoding:try JSONEncoder().encode(probe),as:UTF8.self)
        world.mediaBindings.removeAll{!text.contains($0.id)}
    }
    static func clear(_ owner:RPGMediaOwner,world:inout WorldState)throws {
        var next=world
        switch owner {
        case .player:next.player.mediaBindingID=nil
        case .background(let index):guard next.backgroundBindingIDs.indices.contains(index) else{return};next.backgroundBindingIDs.remove(at:index)
        case .entity(let id):
            guard let index=next.entities.firstIndex(where:{$0.id==id}) else{return}
            let before=next.entities[index];next.entities[index].mediaBindingID=nil
            let change=RPGEntityChange(id:id,before:before,after:next.entities[index],removedBefore:false,removedAfter:false,damageBefore:world.damage[id],damageAfter:world.damage[id])
            try RPGWorldEditing.finish(next:&next,changes:[change],inventoryBefore:world.inventory,title:"清除媒体绑定")
            world=next;return
        }
        next.revision+=1;try next.validate();world=next
    }
}
