import SpriteKit
import UIKit

@MainActor final class RPGSideScene: SKScene {
    var onEnemyPosition: ((String, SidePlacement) -> Void)?
    private let enemyLayer = SKNode()
    private var enemyNodes: [String: SKShapeNode] = [:]
    private var enemyStates: [String: RPGEnemyState] = [:]
    private var enemyCells: [String: SidePlacement] = [:]
    private var dashUntil: TimeInterval = 0
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
        enemyLayer.zPosition = 5; addChild(enemyLayer); addChild(floorLayer);addChild(objects);addChild(avatar);addChild(selection);addChild(worldCamera);camera=worldCamera
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
    /// The selected cell in SpriteView (UIKit) coordinates, or nil when
    /// nothing is selected. Used to place the SwiftUI selection glass.
    func selectionRectInView() -> CGRect? {
        guard !selection.isHidden, view != nil else { return nil }
        let half: CGFloat = 12
        let a = convertPoint(toView: CGPoint(x: selection.position.x - half, y: selection.position.y - half))
        let b = convertPoint(toView: CGPoint(x: selection.position.x + half, y: selection.position.y + half))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    /// The yellow outline is hidden when native glass marks the selection.
    var selectionOutlineVisible = true { didSet { selection.alpha = selectionOutlineVisible ? 1 : 0 } }
    func select(_ side:SidePlacement?) { selection.isHidden=side==nil;if let side{selection.position=CGPoint(x:CGFloat(side.horizontal)*24+12,y:CGFloat(side.height)*24+12)} }
    override func update(_ currentTime:TimeInterval) {
        tick=currentTime
        guard !isPaused,let region else{return}
        if currentTime>movementUntil {direction=0}
        avatar.physicsBody?.velocity.dx=direction*(currentTime < dashUntil ? 340:140)
        isOnGround = (avatar.physicsBody?.allContactedBodies().contains{$0.categoryBitMask==2} ?? false) && abs(avatar.physicsBody?.velocity.dy ?? 0)<2
        let u=max(0,min(region.width-1,Int(floor(avatar.position.x/24))))
        let h=max(0,min(63,Int(floor(avatar.position.y/24))))
        let cell=SidePlacement(regionID:region.id,horizontal:u,height:h)
        if cell != lastCell || lastGrounded != isOnGround {lastCell=cell;lastGrounded=isOnGround;onPosition?(cell,isOnGround)}
        updateEnemies();follow();onFrame?(currentTime)
    }
    func dash(_ sign: Int) { direction = CGFloat(sign); dashUntil = tick+0.25; movementUntil = dashUntil }
    func showCombat(_ world: WorldState) {
        let visible = world.combat.enemies.filter { $0.health > 0 && $0.side?.regionID == region?.id && $0.side != nil }
        let ids = Set(visible.map(\.id))
        for id in Array(enemyNodes.keys) where !ids.contains(id) { enemyNodes.removeValue(forKey:id)?.removeFromParent(); enemyCells[id] = nil }
        enemyStates = Dictionary(uniqueKeysWithValues:visible.map{($0.id,$0)})
        for enemy in visible {
            let node: SKShapeNode
            if let existing = enemyNodes[enemy.id] { node = existing }
            else {
                node = SKShapeNode(rectOf:CGSize(width:18,height:20),cornerRadius:5)
                node.name = enemy.id; node.strokeColor = .white
                let body = SKPhysicsBody(rectangleOf:CGSize(width:18,height:20)); body.allowsRotation = false
                body.categoryBitMask = 4; body.collisionBitMask = 2; body.contactTestBitMask = 2; body.restitution = 0
                node.physicsBody = body
                let p = enemy.side!; node.position = CGPoint(x:CGFloat(p.horizontal*24+12),y:CGFloat(p.height*24+12))
                enemyLayer.addChild(node); enemyNodes[enemy.id] = node
                let hp = SKLabelNode(); hp.name = "hp"; hp.fontSize = 9; hp.position.y = 15; node.addChild(hp)
            }
            node.fillColor = enemy.boss ? .systemPurple:.systemRed
            (node.childNode(withName:"hp") as? SKLabelNode)?.text = String(enemy.health)
        }
    }
    private func updateEnemies() {
        guard let region else { return }
        for (id,node) in enemyNodes {
            guard let state = enemyStates[id], let body = node.physicsBody else { continue }
            let delta = avatar.position.x-node.position.x
            body.velocity.dx = state.aggro && abs(delta)>20 ? (delta>0 ? 70:-70):0
            let grounded = body.allContactedBodies().contains{$0.categoryBitMask==2} && abs(body.velocity.dy)<2
            if state.aggro && grounded && avatar.position.y>node.position.y+26 { body.velocity.dy = 260 }
            let cell = SidePlacement(regionID:region.id,horizontal:max(0,min(region.width-1,Int(floor(node.position.x/24)))),height:max(0,min(63,Int(floor(node.position.y/24)))))
            if enemyCells[id] != cell { enemyCells[id] = cell; onEnemyPosition?(id,cell) }
        }
    }
    var reducedMotion=false
    func combatEffect(_ skill: Bool) {
        guard !reducedMotion else{return}
        let effect = SKShapeNode(circleOfRadius:skill ? 90:42); effect.position = avatar.position
        effect.strokeColor = .systemYellow; effect.lineWidth = 3; effect.zPosition = 15
        addChild(effect); effect.run(.sequence([.fadeOut(withDuration:0.25),.removeFromParent()]))
    }
    private func follow(){worldCamera.position=CGPoint(x:avatar.position.x,y:max(size.height*0.4,avatar.position.y+size.height*0.15))}
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent?){
        guard let touch=touches.first,let region else{return}
        let p=touch.location(in:self),u=Int(floor(p.x/24)),h=Int(floor(p.y/24))
        if (0..<region.width).contains(u) && (0..<64).contains(h){onSelectCell?(.init(regionID:region.id,horizontal:u,height:h))}
    }
    func shutdown(){enemyLayer.removeAllChildren();enemyNodes.removeAll();enemyStates.removeAll();enemyCells.removeAll();onEnemyPosition=nil;isPaused=true;onSelectCell=nil;onPosition=nil;onFrame=nil;mediaTargets=[];avatar.physicsBody?.velocity = .zero;objects.removeAllChildren();floorLayer.removeAllChildren();region=nil;sharedIDs=[];removeAllActions()}
}
