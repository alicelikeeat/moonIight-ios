import SpriteKit

/// P1 host: no terrain generation and no media decoder until later stages.
@MainActor final class RPGTopDownScene: SKScene {
    override init() {
        super.init(size: CGSize(width: 390, height: 500))
        scaleMode = .resizeFill; backgroundColor = .clear; physicsWorld.gravity = .zero
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMove(to view: SKView) {
        guard children.isEmpty else { return }
        let marker = SKShapeNode(circleOfRadius: 12)
        marker.fillColor = .systemTeal; marker.strokeColor = .white; marker.name = "player"
        addChild(marker); layoutMarker()
    }
    override func didChangeSize(_ oldSize: CGSize) { layoutMarker() }
    private func layoutMarker() { childNode(withName: "player")?.position = CGPoint(x: size.width / 2, y: size.height / 2) }
    func shutdown() { isPaused = true; removeAllActions(); removeAllChildren(); physicsWorld.contactDelegate = nil }
}
