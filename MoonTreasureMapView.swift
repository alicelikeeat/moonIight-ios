import SpriteKit
import SwiftUI

/// 月藏图：把库内条目投影成可触碰、可堆叠的“月光宝藏”。
/// 只让当前可见的前 42 件参与物理演算，避免大媒体库拖慢界面。
struct MoonTreasureMapView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var scope = TreasureScope.all
    @State private var scene = MoonTreasureScene()

    private var items: [MediaEntry] {
        let source: [MediaEntry]
        switch scope {
        case .all: source = model.mediaStore.items
        case .favorites: source = model.mediaStore.items.filter(\.isFavorite)
        case .videos: source = model.mediaStore.items.filter { $0.kind == .video }
        }
        return Array(source.prefix(42))
    }

    private var selected: MediaEntry? {
        model.mediaStore.items.first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(red: 0.05, green: 0.07, blue: 0.13), Color(red: 0.15, green: 0.11, blue: 0.25)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                header
                Picker("藏宝范围", selection: $scope) {
                    ForEach(TreasureScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)

                SpriteView(scene: scene, options: [.allowsTransparency])
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    .padding(.horizontal, 14)
                    .accessibilityIdentifier("moon-treasure-map")
                    .onAppear { configureScene() }
                    .onChange(of: scope) { _ in configureScene() }
                    .onChange(of: model.mediaStore.items.map(\.id)) { _ in configureScene() }
                    .overlay(alignment: .bottom) {
                        Text("轻拨宝藏，点按一件查看；只让前 \(items.count) 件参与碰撞")
                            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(.black.opacity(0.28), in: Capsule())
                            .padding(14)
                    }
                if let selected {
                    TreasureDetail(entry: selected) { selectedID = nil }
                        .padding(.horizontal, 18)
                } else {
                    Text(items.isEmpty ? "宝库还是空的，先从发现或相册加入内容。" : "\(model.mediaStore.items.count) 件藏品 · \(model.mediaStore.folders.count) 个片单")
                        .font(.footnote).foregroundStyle(.white.opacity(0.75)).padding(.bottom, 12)
                }
            }
        }
        .navigationTitle("月藏图")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("月藏图").font(.title.bold()).foregroundStyle(.white)
                Text("像巨龙宝库一样堆放你的图片与视频").font(.subheadline).foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
            Image(systemName: "sparkles").font(.title2.weight(.bold)).foregroundStyle(.yellow)
        }.padding(.horizontal, 22).padding(.top, 8)
    }

    private func configureScene() {
        scene.configure(with: items) { id in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedID = id
        }
    }
}

private enum TreasureScope: String, CaseIterable, Identifiable {
    case all, favorites, videos
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .favorites: "收藏"; case .videos: "视频" } }
}

private struct TreasureDetail: View {
    let entry: MediaEntry
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .video ? "play.rectangle.fill" : "photo.fill")
                .font(.title2).foregroundStyle(.yellow)
                .frame(width: 46, height: 46).background(.white.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(entry.platform) · \(entry.isFavorite ? "已收藏" : "未收藏")").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
        }
        .foregroundStyle(.white).padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private final class MoonTreasureScene: SKScene {
    private var select: ((String) -> Void)?
    private let floor = SKShapeNode()

    init() { super.init(size: CGSize(width: 390, height: 520)); scaleMode = .resizeFill; backgroundColor = .clear }
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with entries: [MediaEntry], onSelect: @escaping (String) -> Void) {
        select = onSelect
        removeAllChildren()
        physicsWorld.gravity = CGVector(dx: 0, dy: -4.6)
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame.insetBy(dx: 6, dy: 8))
        for (index, entry) in entries.enumerated() { addTreasure(entry, index: index) }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame.insetBy(dx: 6, dy: 8))
    }

    private func addTreasure(_ entry: MediaEntry, index: Int) {
        let width: CGFloat = entry.kind == .video ? 92 : 78
        let height: CGFloat = entry.kind == .video ? 104 : 86
        let node = SKShapeNode(rectOf: CGSize(width: width, height: height), cornerRadius: 17)
        node.name = entry.id
        node.fillColor = color(for: entry)
        node.strokeColor = entry.isFavorite ? .yellow : .white.withAlphaComponent(0.42)
        node.lineWidth = entry.isFavorite ? 2.5 : 1
        node.position = CGPoint(x: CGFloat((index * 67) % max(Int(size.width - width), 1)) + width / 2,
                                y: size.height + CGFloat(index / 4) * 38 + 35)
        node.zRotation = CGFloat((index % 7) - 3) * 0.055
        node.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: width, height: height), center: .zero)
        node.physicsBody?.restitution = 0.28
        node.physicsBody?.friction = 0.62
        node.physicsBody?.linearDamping = 0.52
        node.physicsBody?.angularDamping = 0.58
        node.physicsBody?.allowsRotation = true

        let icon = SKLabelNode(fontNamed: "SFProDisplay-Semibold")
        icon.text = entry.kind == .video ? "▶" : "✦"
        icon.fontSize = 25; icon.verticalAlignmentMode = .center; icon.position = CGPoint(x: 0, y: 16)
        node.addChild(icon)
        let title = SKLabelNode(fontNamed: "SFProText-Medium")
        title.text = String(entry.title.prefix(8))
        title.fontSize = 9; title.verticalAlignmentMode = .center; title.position = CGPoint(x: 0, y: -22)
        title.preferredMaxLayoutWidth = width - 12; title.numberOfLines = 2
        node.addChild(title)
        addChild(node)
    }

    private func color(for entry: MediaEntry) -> SKColor {
        if entry.isFavorite { return SKColor(red: 0.72, green: 0.54, blue: 0.14, alpha: 0.96) }
        if entry.kind == .video { return SKColor(red: 0.30, green: 0.24, blue: 0.72, alpha: 0.94) }
        switch entry.platform.lowercased() {
        case "youtube": return SKColor(red: 0.78, green: 0.18, blue: 0.22, alpha: 0.94)
        case "bili": return SKColor(red: 0.26, green: 0.58, blue: 0.78, alpha: 0.94)
        default: return SKColor(red: 0.22, green: 0.53, blue: 0.48, alpha: 0.94)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let location = touches.first?.location(in: self), let id = nodes(at: location).compactMap(\.name).first else { return }
        select?(id)
    }
}

