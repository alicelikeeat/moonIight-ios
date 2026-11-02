import Foundation

enum RPGWorldRoute {
    static func path(from origin:SurfacePoint,to target:SurfacePoint,generator:RPGWorldGenerator,entities:[WorldEntity],removedIDs:[String],cancelled:()->Bool={false})->[SurfacePoint] {
        guard origin.valid,target.valid,origin != target else{return []}
        let overrides=Set(entities.map(\.id)),removed=Set(removedIDs)
        let occupied=Set(entities.filter{$0.physics.topDownSolid}.compactMap(\.surface))
        func walkable(_ point:SurfacePoint)->Bool {
            guard generator.tile(at:point)?.passable==true,!occupied.contains(point) else{return false}
            guard let entity=generator.baseEntity(at:point) else{return true}
            return removed.contains(entity.id) || overrides.contains(entity.id) || !entity.physics.topDownSolid
        }
        func search(protectedOnly:Bool)->[SurfacePoint] {
            var queue=[origin],head=0,visited:Set<SurfacePoint>=[origin],parent:[SurfacePoint:SurfacePoint]=[:]
            while head<queue.count && visited.count<=65536 {
                if cancelled(){return []}
                let p=queue[head];head+=1
                if p==target {
                    var result:[SurfacePoint]=[],cursor=p
                    while cursor != origin {result.append(cursor);guard let previous=parent[cursor] else{return []};cursor=previous}
                    return Array(result.reversed())
                }
                for d in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let next=SurfacePoint(x:p.x+d.0,z:p.z+d.1)
                    if !visited.contains(next),(!protectedOnly || generator.protected(next)),walkable(next){visited.insert(next);parent[next]=p;queue.append(next)}
                }
            }
            return []
        }
        if generator.protected(origin),generator.protected(target) {
            let reserved=search(protectedOnly:true);if !reserved.isEmpty{return reserved}
        }
        return search(protectedOnly:false)
    }
}
