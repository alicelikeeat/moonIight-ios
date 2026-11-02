import SpriteKit
import UIKit

@MainActor final class RPGSideScene: SKScene {
    var onFrame:((TimeInterval)->Void)?
    private(set) var mediaTargets:[RPGMediaNode]=[]
    var onSelectCell: ((SidePlacement) -> Void)?
    var onPosition: ((SidePlacement, Bool) -> Void)?
    private let avatar = SKShapeNode(rectOf: CGSize(width:16,height:22),cornerRadius:5)
    private let worldCamera=SKCameraNode(), objects=SKNode(), floorLayer=SKNode()
    private let selection=SKShapeNode(rectOf:CGSize(width:23,height:23),cornerRadius:3)
    private var region: SideRegion?
    private var lastCell: SidePlacement?
    private var lastGrounded=false
    private(set) var isOnGround=false
    private(set) var sharedIDs: [String]=[]
    private var tick: TimeInterval=0
    private var movementUntil: TimeInterval=0
    private var direction: CGFloat=0
    override init() {
        super.init(size:CGSize(width:390,height:400));scaleMode = .resizeFill;backgroundColor = .clear
        physicsWorld.gravity=CGVector(dx:0,dy:-12)
        addChild(floorLayer);addChild(objects);addChild(avatar);addChild(selection);addChild(worldCamera);camera=worldCamera
        avatar.fillColor = .systemTeal;avatar.strokeColor = .white;avatar.zPosition=10
        let body=SKPhysicsBody(rectangleOf:CGSize(width:16,height:22));body.allowsRotation=false;body.mass=0.08;body.restitution=0;body.friction=0.2;body.categoryBitMask=1;body.collisionBitMask=2;body.contactTestBitMask=2
        avatar.physicsBody=body
        selection.strokeColor = .systemYellow;selection.fillColor = .clear;selection.zPosition=20;selection.isHidden=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func show(world:WorldState, resetPlayer:Bool=false) {
        guard let selectedRegion=world.sideRegions.first else{return}
        let changed=region?.id != selectedRegion.id;region=selectedRegion
        let width=CGFloat(selectedRegion.width)*24
        if changed || floorLayer.children.isEmpty {
            floorLayer.removeAllChildren()
            let ground=SKShapeNode(rectOf:CGSize(width:width,height:24))
            ground.position=CGPoint(x:width/2,y:12);ground.fillColor = .darkGray;ground.strokeColor = .clear
            ground.physicsBody=SKPhysicsBody(rectangleOf:CGSize(width:width,height:24));ground.physicsBody?.isDynamic=false;ground.physicsBody?.categoryBitMask=2
            floorLayer.addChild(ground)
            physicsBody=SKPhysicsBody(edgeLoopFrom:CGRect(x:0,y:0,width:width,height:64*24));physicsBody?.categoryBitMask=2
        }
        objects.removeAllChildren()
        avatar.children.filter{$0.name?.hasPrefix("media:")==true}.forEach{$0.removeFromParent()}
        mediaTargets=RPGMediaSprites.backgrounds(world:world,camera:worldCamera,size:size,topDown:false)
        if let target=RPGMediaSprites.attach(ownerID:"player",bindingID:world.player.mediaBindingID,role:.player,parent:avatar,world:world,size:CGSize(width:24,height:32)){mediaTargets.append(target)}
        let entities=RPGProjectionRules.sideEntities(world:world,generator:RPGWorldGenerator(seed:world.seed))
        sharedIDs=entities.filter{$0.scope == .shared}.map(\.id).sorted()
        for entity in entities {
            guard let side=entity.side,side.regionID==selectedRegion.id else{continue}
            let size=CGSize(width:entity.physics.width*24,height:entity.physics.height*24)
            let node=SKShapeNode(rectOf:size,cornerRadius:3)
            node.position=CGPoint(x:CGFloat(side.horizontal)*24+size.width/2,y:CGFloat(side.height)*24+size.height/2)
            node.fillColor=entity.scope == .sideOnly ? .systemIndigo : entity.definitionID == "wood" ? .systemBrown : .systemGray
            node.strokeColor = .white.withAlphaComponent(0.5);node.name=entity.id
            if entity.physics.sideSolid { node.physicsBody=SKPhysicsBody(rectangleOf:size);node.physicsBody?.isDynamic=false;node.physicsBody?.categoryBitMask=2 }
            objects.addChild(node)
            if let target=RPGMediaSprites.attach(ownerID:entity.id,bindingID:entity.mediaBindingID,role:.interactive,parent:node,world:world,size:size){mediaTargets.append(target)}
        }
        if changed || resetPlayer { respawn(world.player.side ?? selectedRegion.landing) }
    }
    func respawn(_ side:SidePlacement) {
        avatar.position=CGPoint(x:CGFloat(side.horizontal)*24+12,y:CGFloat(side.height)*24+12)
        avatar.physicsBody?.velocity = .zero;lastCell=nil;direction=0;movementUntil=0;isOnGround=false;follow()
    }
    func step(_ sign:Int) { direction=CGFloat(sign);movementUntil=tick+0.2 }
    func jump() { if isOnGround { avatar.physicsBody?.velocity.dy=300;isOnGround=false } }
    func select(_ side:SidePlacement?) { selection.isHidden=side==nil;if let side{selection.position=CGPoint(x:CGFloat(side.horizontal)*24+12,y:CGFloat(side.height)*24+12)} }
    override func update(_ currentTime:TimeInterval) {
        tick=currentTime
        guard !isPaused,let region else{return}
        if currentTime>movementUntil {direction=0}
        avatar.physicsBody?.velocity.dx=direction*140
        isOnGround = (avatar.physicsBody?.allContactedBodies().contains{$0.categoryBitMask==2} ?? false) && abs(avatar.physicsBody?.velocity.dy ?? 0)<2
        let u=max(0,min(region.width-1,Int(floor(avatar.position.x/24))))
        let h=max(0,min(63,Int(floor(avatar.position.y/24))))
        let cell=SidePlacement(regionID:region.id,horizontal:u,height:h)
        if cell != lastCell || lastGrounded != isOnGround {lastCell=cell;lastGrounded=isOnGround;onPosition?(cell,isOnGround)}
        follow();onFrame?(currentTime)
    }
    private func follow(){worldCamera.position=CGPoint(x:avatar.position.x,y:max(size.height*0.4,avatar.position.y+size.height*0.15))}
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?){
        guard let touch=touches.first,let region else{return}
        let p=touch.location(in:self),u=Int(floor(p.x/24)),h=Int(floor(p.y/24))
        if (0..<region.width).contains(u) && (0..<64).contains(h){onSelectCell?(.init(regionID:region.id,horizontal:u,height:h))}
    }
    func shutdown(){isPaused=true;onSelectCell=nil;onPosition=nil;onFrame=nil;mediaTargets=[];avatar.physicsBody?.velocity = .zero;objects.removeAllChildren();floorLayer.removeAllChildren();region=nil;sharedIDs=[];removeAllActions()}
}
