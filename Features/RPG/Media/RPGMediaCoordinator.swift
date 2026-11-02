import SpriteKit
import Combine
import UIKit

@MainActor struct RPGMediaNode {
    let ownerID:String
    let binding:MediaBinding
    let role:RPGMediaRole
    let sprite:SKSpriteNode
}
@MainActor final class RPGMediaCoordinator:ObservableObject {
    private let pool=CardMediaCoordinator()
    private let store:MediaStore
    private var targets:[RPGMediaNode]=[]
    private weak var scene:SKScene?
    private var subscriptions:[String:AnyCancellable]=[:]
    private var storeSubscription:AnyCancellable?
    private var noticeSubscription:AnyCancellable?
    private var textures=CardFrameLRU<SKTexture>(maxEntries:24,maxCost:12*1024*1024)
    private var localEntries:[MediaEntry]=[]
    private var availableIDs=Set<String>()
    private var ownerIDs:[String:Int]=[:]
    private var nextID=0
    private var budget=2
    private var active=false
    private var lastTime:TimeInterval=0
    private var lastRequests:[RPGMediaRequest]=[]
    private var memory:NSObjectProtocol?
    @Published private(set) var notice=""
    var decoderCount:Int{pool.decoderCount}
    var advancing:Int{pool.advancing}
    var frameCount:Int{pool.renderedFrames}
    var posterCount:Int{pool.posterFrames}
    var completedCount:Int{pool.completedPreviewCount}
    var muted:Bool{pool.muted}
    var cacheBytes:Int{pool.cacheBytes+textures.cost}
    init(store:MediaStore){
        self.store=store
        storeSubscription=store.$items.sink{[weak self] _ in Task{@MainActor [weak self] in self?.configureAssets();self?.sync(force:true)}}
        noticeSubscription=pool.$notice.sink{[weak self] value in self?.notice=value}
        memory=NotificationCenter.default.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:.main){[weak self] _ in
            Task{@MainActor [weak self] in self?.textures.maxEntries=6;self?.textures.maxCost=2*1024*1024;self?.textures.trim();self?.clearEvictedTextures()}
        }
    }
    func install(world:WorldState,targets:[RPGMediaNode],scene:SKScene,active:Bool){
        self.targets=targets;self.scene=scene;self.budget=world.videoBudget;self.active=active
        let mediaIDs=Set(targets.map{$0.binding.mediaID})
        let owners=Set(targets.map(\.ownerID))
        for owner in Array(ownerIDs.keys) where !owners.contains(owner){ownerIDs[owner]=nil}
        for id in Array(subscriptions.keys) where !mediaIDs.contains(id){subscriptions[id]=nil}
        for target in targets {
            if ownerIDs[target.ownerID]==nil{ownerIDs[target.ownerID]=nextID;nextID+=1}
            let id=target.binding.mediaID
            if subscriptions[id]==nil {
                let feed=pool.feed(id)
                subscriptions[id]=feed.$revision.sink{[weak self,weak feed] _ in
                    guard let self else{return}
                    if let image=feed?.image {
                        let texture=SKTexture(image:image);texture.filteringMode = .linear
                        let cost=image.cgImage.map{$0.bytesPerRow*$0.height} ?? 0
                        self.textures.put(texture,key:id,cost:cost)
                    } else {self.textures.remove(id)}
                    self.applyTexture(id);self.clearEvictedTextures()
                }
            }
            applyTexture(id)
        }
        pool.retainSnapshots(for:Set(ownerIDs.values));configureAssets();sync(force:true)
    }
    private func configureAssets(){
        let ids=Set(targets.map{$0.binding.mediaID}),catalog=MediaStoreRPGCatalog(store:store)
        let local=store.items.filter{entry in
            guard ids.contains(entry.id) else{return false}
            if case .available = catalog.resolve(entry.id){return true};return false
        }
        localEntries=local
        let valid=Set(local.map(\.id));availableIDs=valid
        for target in targets where !valid.contains(target.binding.mediaID){target.sprite.texture=nil;textures.remove(target.binding.mediaID)}
    }
    func frame(_ time:TimeInterval){guard active,time-lastTime>=0.1 else{return};lastTime=time;sync()}
    private func sync(force:Bool=false){
        guard let scene else{return}
        let camera=scene.camera,scale=camera?.xScale ?? 1,center=camera?.position ?? CGPoint(x:scene.size.width/2,y:scene.size.height/2)
        let viewport=CGRect(x:center.x-scene.size.width*scale/2,y:center.y-scene.size.height*scale/2,width:scene.size.width*scale,height:scene.size.height*scale)
        let requests=targets.map{target -> RPGMediaRequest in
            let rect=target.sprite.calculateAccumulatedFrame()
            let parent=target.sprite.parent
            let a=parent?.convert(CGPoint(x:rect.minX,y:rect.minY),to:scene) ?? .zero
            let b=parent?.convert(CGPoint(x:rect.maxX,y:rect.maxY),to:scene) ?? .zero
            let frame=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
            return .init(ownerID:target.ownerID,mediaID:target.binding.mediaID,role:target.role,visible:active && target.sprite.parent != nil && frame.intersects(viewport))
        }
        guard force || requests != lastRequests else{return};lastRequests=requests
        let videos=requests.filter{request in availableIDs.contains(request.mediaID) && store.items.first{$0.id==request.mediaID}?.kind == .video}
        let desired=Set(RPGMediaPolicy.schedule(videos,limit:budget))
        let loops=Set(targets.filter{target in target.binding.loop && requests.contains(where:{$0.ownerID==target.ownerID && $0.visible})}.map{$0.binding.mediaID})
        pool.configureLooping(loops)
        pool.configure(entries:localEntries,requested:desired.count,active:active)
        var candidates:[CardMediaCandidate]=[]
        for request in requests {
            let visible=request.visible && availableIDs.contains(request.mediaID)
            let role:CardPreviewRole = request.role == .player || request.role == .cutscene ? .focus : request.role == .background ? .central : .hand
            candidates.append(.init(cardID:ownerIDs[request.ownerID] ?? 0,mediaID:request.mediaID,role:role,z:request.role.rawValue + (desired.contains(request.mediaID) ? 10 : 0),visibility:visible ? .visible : .hidden))
        }
        let sound=targets.first{target in !target.binding.muted && requests.contains(where:{request in request.ownerID==target.ownerID && request.visible && request.mediaID==target.binding.mediaID})}
        let soundID=sound.flatMap{ownerIDs[$0.ownerID]}
        for target in targets where !requests.contains(where:{$0.ownerID==target.ownerID && $0.visible}) { target.sprite.texture=nil }
        pool.update(candidates,focus:soundID)
        for id in Set(requests.filter(\.visible).map(\.mediaID)){applyTexture(id)}
        if soundID != nil && pool.muted {pool.toggleSound()} else if soundID==nil && !pool.muted{pool.mute()}
    }
    private func applyTexture(_ id:String){
        guard let base=textures.value(id) else{for target in targets where target.binding.mediaID==id{target.sprite.texture=nil};return}
        for target in targets where target.binding.mediaID==id && lastRequests.contains(where:{$0.ownerID==target.ownerID && $0.visible}) {
            let binding=target.binding
            target.sprite.texture=SKTexture(rect:CGRect(x:binding.cropX,y:binding.cropY,width:binding.cropWidth,height:binding.cropHeight),in:base)
            target.sprite.anchorPoint=CGPoint(x:binding.anchorX,y:binding.anchorY)
        }
    }
    private func clearEvictedTextures(){for target in targets where !textures.contains(target.binding.mediaID){target.sprite.texture=nil}}
    func pause(){active=false;pool.stop();lastRequests=[]}
    func retry(){textures.maxEntries=24;textures.maxCost=12*1024*1024;pool.retry();configureAssets();sync(force:true)}
    func stop(){
        active=false;pool.dispose();subscriptions.removeAll();storeSubscription=nil;noticeSubscription=nil
        targets.forEach{$0.sprite.texture=nil};targets=[];textures.removeAll();ownerIDs=[:];lastRequests=[];scene=nil
        if let memory{NotificationCenter.default.removeObserver(memory)};memory=nil
    }
}

@MainActor enum RPGMediaSprites {
    static func attach(ownerID:String,bindingID:String?,role:RPGMediaRole,parent:SKNode,world:WorldState,size:CGSize)->RPGMediaNode? {
        guard let bindingID,let binding=world.mediaBindings.first(where:{$0.id==bindingID}) else{return nil}
        let sprite=SKSpriteNode(color:.clear,size:CGSize(width:size.width*binding.scale,height:size.height*binding.scale))
        sprite.zPosition=1;sprite.name="media:"+ownerID;parent.addChild(sprite)
        return .init(ownerID:ownerID,binding:binding,role:role,sprite:sprite)
    }
    static func backgrounds(world:WorldState,camera:SKCameraNode,size:CGSize,topDown:Bool)->[RPGMediaNode] {
        camera.children.filter{$0.name?.hasPrefix("media:background:")==true}.forEach{$0.removeFromParent()}
        return world.backgroundBindingIDs.enumerated().compactMap{index,id in
            guard let target=attach(ownerID:"background:\(index)",bindingID:id,role:.background,parent:camera,world:world,size:size) else{return nil}
            target.sprite.zPosition=topDown ? 0.2+Double(index)*0.01 : -20+Double(index)
            target.sprite.alpha=topDown ? 0.22 : 1
            return target
        }
    }
}
