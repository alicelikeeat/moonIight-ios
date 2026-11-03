import SwiftUI
import SpriteKit
import Combine

struct RPGCutsceneView:View {
    @StateObject private var player:RPGCutscenePlayer
    private let progress:(Double)->Void
    init(world:WorldState,bindingID:String,store:MediaStore,seconds:Double,loop:Bool?=nil,muted:Bool?=nil,progress:@escaping(Double)->Void){
        _player=StateObject(wrappedValue:RPGCutscenePlayer(world:world,bindingID:bindingID,store:store,seconds:seconds,loop:loop,muted:muted))
        self.progress=progress
    }
    var body:some View {
        VStack {
            SpriteView(scene:player.scene,options:[.allowsTransparency]).frame(height:180).clipShape(RoundedRectangle(cornerRadius:16))
                .accessibilityLabel("剧情媒体演出").accessibilityIdentifier("rpg-cutscene")
            Text(player.notice.isEmpty ? "本地媒体 · 可继续或跳过" : player.notice).font(.caption)
            Button(player.audible ? "关闭演出声音":"开启演出声音"){player.toggleSound()}
                .accessibilityIdentifier("rpg-cutscene-sound")
        }.overlay(alignment:.topLeading){
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests"){
                Text("演出测试状态").font(.system(size:1)).opacity(0.01).allowsHitTesting(false).accessibilityIdentifier("rpg-cutscene-probe").accessibilityValue(player.probe)
            }
            #endif
        }.onAppear{player.activate()}
            .onDisappear{progress(player.seconds);player.shutdown()}
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.willResignActiveNotification)){_ in progress(player.seconds);player.pause()}
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification)){_ in player.activate()}
    }
}
@MainActor private final class RPGCutscenePlayer:ObservableObject {
    let scene=RPGCutsceneScene(size:CGSize(width:320,height:180))
    private let media:RPGMediaCoordinator
    private var world:WorldState
    private let bindingID:String
    private var initial:Double
    private var activated=false
    private var targets:[RPGMediaNode]=[]
    @Published private(set) var audible=false
    @Published private(set) var probe=""
    private var lastProbe=0.0
    @Published private(set) var notice=""
    private var observer:AnyCancellable?
    init(world:WorldState,bindingID:String,store:MediaStore,seconds:Double,loop:Bool?,muted:Bool?){
        var configured=world
        for index in configured.mediaBindings.indices {
            if configured.mediaBindings[index].id==bindingID {
                if let loop{configured.mediaBindings[index].loop=loop};if let muted{configured.mediaBindings[index].muted=muted}
            }else{configured.mediaBindings[index].muted=true}
        }
        self.world=configured;self.bindingID=bindingID;self.initial=seconds;media=RPGMediaCoordinator(store:store)
        scene.scaleMode = .resizeFill;scene.backgroundColor = .clear
        let camera=SKCameraNode();camera.position=CGPoint(x:160,y:90);scene.addChild(camera);scene.camera=camera
        let fallback=SKLabelNode(text:"媒体缺失时仍可阅读字幕并继续");fallback.fontSize=12;fallback.position=CGPoint(x:160,y:90);scene.addChild(fallback)
        let parent=SKNode();parent.position=CGPoint(x:160,y:90);scene.addChild(parent)
        if let target=RPGMediaSprites.attach(ownerID:"cutscene",bindingID:bindingID,role:.cutscene,parent:parent,world:configured,size:CGSize(width:320,height:180)){targets=[target]}
        scene.onFrame = { [weak self] time in
            guard let self else{return};self.media.frame(time)
            #if DEBUG
            if time-self.lastProbe>=0.5,ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests"){
                self.lastProbe=time;self.probe="players=\(self.media.decoderCount);frames=\(self.media.frameCount);muted=\(self.media.muted ? 1:0);global=\(CardMediaCoordinator.ownedPlayers)"
            }
            #endif
        }
        observer=media.$notice.sink{[weak self] value in self?.notice=value}
    }
    var seconds:Double{targets.first.map{media.position($0.binding.mediaID)} ?? initial}
    func activate(){
        audible = !activated && targets.first?.binding.muted == false
        activated=true
        targets=targets.map{target in var binding=target.binding;binding.muted = !audible;return .init(ownerID:target.ownerID,binding:binding,role:target.role,sprite:target.sprite,region:target.region)}
        media.install(world:world,targets:targets,scene:scene,active:true,initialPositions:["cutscene":initial]);initial=0
        scene.isPaused=false
    }
    func toggleSound(){
        audible.toggle()
        targets=targets.map{target in var binding=target.binding;binding.muted = !audible;return .init(ownerID:target.ownerID,binding:binding,role:target.role,sprite:target.sprite,region:target.region)}
        media.install(world:world,targets:targets,scene:scene,active:true)
    }
    func pause(){initial=seconds;audible=false;media.pause();scene.isPaused=true}
    func shutdown(){media.stop();scene.isPaused=true}
}

@MainActor private final class RPGCutsceneScene: SKScene {
    var onFrame:((TimeInterval)->Void)?
    override func update(_ currentTime:TimeInterval){onFrame?(currentTime)}
}
