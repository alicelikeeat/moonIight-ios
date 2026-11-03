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
    // GIF cells: frames come from RPGGIFLibrary, not the video pool.
    private let gifs=RPGGIFLibrary()
    private var gifURLs:[String:URL]=[:]
    private struct GIFClock {var start:TimeInterval;var shown:Int}
    private var gifClocks:[String:GIFClock]=[:]
    @Published private(set) var notice=""
    var decoderCount:Int{pool.decoderCount}
    var advancing:Int{pool.advancing}
    var frameCount:Int{pool.renderedFrames}
    var posterCount:Int{pool.posterFrames}
    var completedCount:Int{pool.completedPreviewCount}
    var muted:Bool{pool.muted}
    var cacheBytes:Int{pool.cacheBytes+textures.cost+gifs.cost}
    var gifCount:Int{gifs.count}
    init(store:MediaStore){
        self.store=store
        storeSubscription=store.$items.sink{[weak self] _ in Task{@MainActor [weak self] in self?.configureAssets();self?.sync(force:true)}}
        noticeSubscription=pool.$notice.sink{[weak self] value in self?.notice=value}
        memory=NotificationCenter.default.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:.main){[weak self] _ in
            Task{@MainActor [weak self] in self?.textures.maxEntries=6;self?.textures.maxCost=2*1024*1024;self?.textures.trim();self?.gifs.lowMemory();self?.clearEvictedTextures()}
        }
    }
    func install(world:WorldState,targets all:[RPGMediaNode],scene:SKScene,active:Bool,initialPositions:[String:Double]=[:]){
        // Icon, number and text cells are static textures; only library
        // files go through the decoder pool and visibility scheduling.
        for glyph in all where RPGCellRenderer.isGlyph(glyph.binding) {
            glyph.sprite.texture=RPGCellRenderer.texture(for:glyph.binding)
            glyph.sprite.anchorPoint=CGPoint(x:glyph.binding.anchorX,y:glyph.binding.anchorY)
        }
        let targets=all.filter{!RPGCellRenderer.isGlyph($0.binding)}
        self.targets=targets;self.scene=scene;self.budget=world.videoBudget;self.active=active
        let mediaIDs=Set(targets.map{$0.binding.mediaID})
        let owners=Set(targets.map(\.ownerID))
        for owner in Array(ownerIDs.keys) where !owners.contains(owner){ownerIDs[owner]=nil}
        for id in Array(subscriptions.keys) where !mediaIDs.contains(id){subscriptions[id]=nil}
        for owner in Array(gifClocks.keys) where !owners.contains(owner){gifClocks[owner]=nil}
        for target in targets {
            if ownerIDs[target.ownerID]==nil{ownerIDs[target.ownerID]=nextID;nextID+=1}
            if let seconds=initialPositions[target.ownerID],let ownerID=ownerIDs[target.ownerID] {pool.restorePlayback(cardID:ownerID,mediaID:target.binding.mediaID,seconds:seconds)}
            let id=target.binding.mediaID
            if isGIF(id){continue}
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
        localEntries=local.filter{RPGMediaCatalogKind.kind(for:$0) != .gif}
        gifURLs=Dictionary(local.filter{RPGMediaCatalogKind.kind(for:$0) == .gif}.compactMap{entry in entry.remoteURL.map{(entry.id,$0)}},uniquingKeysWith:{first,_ in first})
        let valid=Set(local.map(\.id).filter{!gifs.isUnreadable($0)});availableIDs=valid
        for target in targets where !valid.contains(target.binding.mediaID){
            textures.remove(target.binding.mediaID)
            // Missing block media shows a placeholder; backgrounds and the
            // player keep their default look as before.
            target.sprite.texture=target.role == .interactive ? RPGCellRenderer.placeholder : nil
            target.sprite.size=RPGMediaSprites.box(of:target.sprite)
            target.sprite.color = .white;target.sprite.colorBlendFactor=0
        }
    }
    func frame(_ time:TimeInterval){guard active else{return};advanceGIFs(time);guard time-lastTime>=0.1 else{return};lastTime=time;sync()}
    private func isGIF(_ id:String)->Bool{
        if gifURLs[id] != nil{return true}
        return store.items.first{$0.id==id}.map(RPGMediaCatalogKind.kind(for:)) == .gif
    }
    /// Steps each visible GIF cell to the frame its clock calls for. Hidden
    /// cells are skipped, so off-screen GIFs cost nothing per frame. A paused
    /// cell holds its frame and resumes from it.
    private func advanceGIFs(_ time:TimeInterval){
        guard !gifURLs.isEmpty else{return}
        let visible=Set(lastRequests.filter(\.visible).map(\.ownerID))
        for target in targets where visible.contains(target.ownerID) {
            let id=target.binding.mediaID
            guard gifURLs[id] != nil,let animation=gifs.peek(id) else{continue}
            var clock=gifClocks[target.ownerID] ?? GIFClock(start:time,shown:-1)
            let index:Int
            if target.binding.paused == true {
                index=max(clock.shown,0);clock.start=time-RPGGIFTiming.offset(of:index,delays:animation.delays)
            } else {
                index=RPGGIFTiming.frameIndex(elapsed:time-clock.start,delays:animation.delays,loop:target.binding.loop)
            }
            if index != clock.shown,animation.textures.indices.contains(index) {
                let layout=RPGCellRenderer.layout(binding:target.binding,base:animation.textures[index],box:RPGMediaSprites.box(of:target.sprite))
                target.sprite.texture=SKTexture(rect:layout.rect,in:animation.textures[index]);target.sprite.size=layout.size
                target.sprite.anchorPoint=CGPoint(x:target.binding.anchorX,y:target.binding.anchorY)
                clock.shown=index
            }
            gifClocks[target.ownerID]=clock
        }
    }
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
        let visibleGIFs=Set(requests.filter{$0.visible && gifURLs[$0.mediaID] != nil}.map(\.mediaID))
        for id in visibleGIFs {
            _=gifs.animation(id)
            gifs.request(id,url:gifURLs[id]!){[weak self] in
                guard let self,self.gifs.isUnreadable(id) else{return}
                self.configureAssets();self.sync(force:true)
            }
        }
        gifs.trim(keeping:visibleGIFs)
        // A paused video cell keeps its frame and does not claim a decoder.
        let paused=Set(targets.filter{$0.binding.paused == true}.map(\.ownerID))
        let videos=requests.filter{request in !paused.contains(request.ownerID) && availableIDs.contains(request.mediaID) && store.items.first{$0.id==request.mediaID}?.kind == .video}
        let desired=Set(RPGMediaPolicy.schedule(videos,limit:budget))
        let loops=Set(targets.filter{target in target.binding.loop && requests.contains(where:{$0.ownerID==target.ownerID && $0.visible})}.map{$0.binding.mediaID})
        pool.configureLooping(loops)
        pool.configure(entries:localEntries,requested:desired.count,active:active)
        var candidates:[CardMediaCandidate]=[]
        for request in requests where gifURLs[request.mediaID]==nil {
            let visible=request.visible && availableIDs.contains(request.mediaID)
            let role:CardPreviewRole = request.role == .player || request.role == .cutscene ? .focus : request.role == .background ? .central : .hand
            candidates.append(.init(cardID:ownerIDs[request.ownerID] ?? 0,mediaID:request.mediaID,role:role,z:request.role.rawValue + (desired.contains(request.mediaID) ? 10 : 0),visibility:visible ? .visible : .hidden))
        }
        let sound=targets.first{target in !target.binding.muted && requests.contains(where:{request in request.ownerID==target.ownerID && request.visible && request.mediaID==target.binding.mediaID})}
        let soundID=sound.flatMap{ownerIDs[$0.ownerID]}
        for target in targets where availableIDs.contains(target.binding.mediaID) && !requests.contains(where:{$0.ownerID==target.ownerID && $0.visible}) {
            target.sprite.texture=nil;gifClocks[target.ownerID]?.shown = -1
        }
        pool.update(candidates,focus:soundID)
        for id in Set(requests.filter(\.visible).map(\.mediaID)){applyTexture(id)}
        if soundID != nil && pool.muted {pool.toggleSound()} else if soundID==nil && !pool.muted{pool.mute()}
    }
    private func applyTexture(_ id:String){
        guard availableIDs.contains(id),gifURLs[id]==nil else{return}
        guard let base=textures.value(id) else{for target in targets where target.binding.mediaID==id{target.sprite.texture=nil};return}
        for target in targets where target.binding.mediaID==id && lastRequests.contains(where:{$0.ownerID==target.ownerID && $0.visible}) {
            let binding=target.binding
            if binding.paused == true && target.sprite.texture != nil {continue}
            let layout=RPGCellRenderer.layout(binding:binding,base:base,box:RPGMediaSprites.box(of:target.sprite))
            target.sprite.texture=SKTexture(rect:layout.rect,in:base);target.sprite.size=layout.size
            target.sprite.anchorPoint=CGPoint(x:binding.anchorX,y:binding.anchorY)
            // A custom icon is a library picture tinted with the icon colour.
            if binding.kind == .icon,let style=binding.style {target.sprite.color=UIColor(rpgHex:style.colorHex);target.sprite.colorBlendFactor=1}
        }
    }
    private func clearEvictedTextures(){for target in targets where availableIDs.contains(target.binding.mediaID) && gifURLs[target.binding.mediaID]==nil && !textures.contains(target.binding.mediaID){target.sprite.texture=nil}}
    func position(_ mediaID:String)->Double{pool.playbackSeconds(mediaID)}
    func pause(){active=false;pool.stop();lastRequests=[]}
    func retry(){textures.maxEntries=24;textures.maxCost=12*1024*1024;gifs.restoreBudget();pool.retry();configureAssets();sync(force:true)}
    func stop(){
        active=false;pool.dispose();subscriptions.removeAll();storeSubscription=nil;noticeSubscription=nil
        targets.forEach{$0.sprite.texture=nil};targets=[];textures.removeAll();gifs.removeAll();gifClocks=[:];gifURLs=[:];ownerIDs=[:];lastRequests=[];scene=nil
        if let memory{NotificationCenter.default.removeObserver(memory)};memory=nil
    }
}

@MainActor enum RPGMediaSprites {
    static func attach(ownerID:String,bindingID:String?,role:RPGMediaRole,parent:SKNode,world:WorldState,size:CGSize)->RPGMediaNode? {
        guard let bindingID,let binding=world.mediaBindings.first(where:{$0.id==bindingID}) else{return nil}
        let box=CGSize(width:size.width*binding.scale,height:size.height*binding.scale)
        let sprite=SKSpriteNode(color:.clear,size:box)
        sprite.userData=["boxWidth":box.width,"boxHeight":box.height]
        sprite.zPosition=1;sprite.name="media:"+ownerID;parent.addChild(sprite)
        return .init(ownerID:ownerID,binding:binding,role:role,sprite:sprite)
    }
    /// The cell area a sprite was created for, before any fit adjustment.
    static func box(of sprite:SKSpriteNode)->CGSize {
        guard let width=sprite.userData?["boxWidth"] as? CGFloat,let height=sprite.userData?["boxHeight"] as? CGFloat else{return sprite.size}
        return CGSize(width:width,height:height)
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
