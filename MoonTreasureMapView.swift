import SpriteKit
import SwiftUI
import UIKit
import CoreMotion

/// 月藏图：把库内条目投影成可触碰、可堆叠的“月光宝藏”。
/// 只让当前可见的前 42 件参与物理演算，避免大媒体库拖慢界面。
struct MoonTreasureMapView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var activeEntry: MediaEntry?
    @State private var actionEntry: MediaEntry?
    @State private var scope = TreasureScope.all
    @State private var dropCount = 20
    @State private var interactionMode = TreasureInteractionMode.drag
    @State private var scene = MoonTreasureScene()
    @State private var controlsVisible = true

    private var items: [MediaEntry] {
        let source: [MediaEntry]
        switch scope {
        case .all: source = model.mediaStore.items
        case .favorites: source = model.mediaStore.items.filter(\.isFavorite)
        case .videos: source = model.mediaStore.items.filter { $0.kind == .video }
        }
        return Array(source.prefix(dropCount))
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
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                Picker("藏宝范围", selection: $scope) {
                    ForEach(TreasureScope.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)

                SpriteView(scene: scene, options: [.allowsTransparency])
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.22), lineWidth: 1))
                    .padding(.horizontal, 14)
                    .accessibilityIdentifier("moon-treasure-map")
                    .onAppear { configureScene(); scene.startMotion() }
                    .onDisappear { scene.stopMotion() }
                    .onChange(of: scope) { _ in configureScene() }
                    .onChange(of: dropCount) { _ in configureScene() }
                    .onChange(of: interactionMode) { mode in scene.interactionMode = mode }
                    .onChange(of: model.mediaStore.items.map(\.id)) { _ in configureScene() }
                    .overlay(alignment: .topTrailing) {
                        if !controlsVisible {
                            Button { withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true } } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .frame(width: 38, height: 38)
                                    .background(.ultraThinMaterial, in: Circle())
                            }.padding(12)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        Text(interactionMode == .drag
                             ? "拖拽模式 · \(items.count) 张卡片参与重力与碰撞"
                             : "操作模式 · 点按打开，长按显示操作菜单")
                            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(.black.opacity(0.28), in: Capsule())
                            .padding(14)
                            .opacity(controlsVisible ? 1 : 0)
                    }
                if let selected {
                    TreasureDetail(entry: selected, onOpen: { activeEntry = selected }, onClose: { selectedID = nil })
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
        .fullScreenCover(item: $activeEntry) { entry in
            MediaPlayerView(entry: entry, onShareToMoments: { activeEntry = nil }, onQueueAdvance: { activeEntry = $0 })
                .environmentObject(model)
        }
        .confirmationDialog(actionEntry?.title ?? "藏品操作", isPresented: Binding(
            get: { actionEntry != nil },
            set: { if !$0 { actionEntry = nil } }
        ), titleVisibility: .visible) {
            Button("打开播放") {
                activeEntry = actionEntry
                actionEntry = nil
            }
            Button(actionEntry?.isFavorite == true ? "取消收藏" : "收藏") {
                if let entry = actionEntry { model.mediaStore.toggleFavorite(entry) }
                actionEntry = nil
            }
            Button("加入播放队列") {
                if let entry = actionEntry { model.mediaStore.enqueue([entry]) }
                actionEntry = nil
            }
            Button("取消", role: .cancel) { actionEntry = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("月藏图").font(.title.bold()).foregroundStyle(.white)
                Text("像巨龙宝库一样堆放你的图片与视频").font(.subheadline).foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
            Menu {
                Picker("掉落数量", selection: $dropCount) {
                    ForEach([10, 20, 30, 42], id: \.self) { count in
                        Text("\(count) 张").tag(count)
                    }
                }
            } label: {
                VStack(spacing: 1) {
                    Text("\(min(dropCount, items.count))").font(.subheadline.bold())
                    Text("数量").font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityIdentifier("treasure-drop-count")
            Menu {
                Picker("交互模式", selection: $interactionMode) {
                    ForEach(TreasureInteractionMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
            } label: {
                Image(systemName: interactionMode.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityIdentifier("treasure-interaction-mode")
        }.padding(.horizontal, 22).padding(.top, 8)
    }

    private func configureScene() {
        scene.configure(
            with: items,
            interactionMode: interactionMode,
            onSelect: { id in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                selectedID = id
                controlsVisible = false
                activeEntry = model.mediaStore.items.first { $0.id == id }
            },
            onLongPress: { id in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                actionEntry = model.mediaStore.items.first { $0.id == id }
            }
        )
    }
}

private enum TreasureInteractionMode: String, CaseIterable, Identifiable {
    case drag
    case actions
    var id: Self { self }
    var title: String { self == .drag ? "拖拽碰撞" : "长按操作" }
    var symbol: String { self == .drag ? "hand.draw.fill" : "ellipsis.circle.fill" }
}

private enum TreasureScope: String, CaseIterable, Identifiable {
    case all, favorites, videos
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .favorites: "收藏"; case .videos: "视频" } }
}

private struct TreasureDetail: View {
    let entry: MediaEntry
    let onOpen: () -> Void
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
            Button(action: onOpen) { Image(systemName: "play.fill").font(.subheadline.weight(.bold)) }
                .frame(width: 36, height: 36).background(.white.opacity(0.18), in: Circle())
                .accessibilityLabel("打开藏品")
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title3) }
        }
        .foregroundStyle(.white).padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private final class MoonTreasureScene: SKScene {
    var interactionMode = TreasureInteractionMode.drag
    private var select: ((String) -> Void)?
    private var longPress: ((String) -> Void)?
    private var longPressWorkItem: DispatchWorkItem?
    private var longPressTriggered = false
    private let motionManager = CMMotionManager()
    private var lastShake = Date.distantPast
    private var draggedTreasures: [ObjectIdentifier: SKShapeNode] = [:]
    private var touchStarts: [ObjectIdentifier: CGPoint] = [:]
    private var movedTouches = Set<ObjectIdentifier>()
    private var fusionHalo: SKShapeNode?
    private weak var fusedWith: SKShapeNode?
    private weak var fusionSource: SKShapeNode?
    private var originalFillColors: [ObjectIdentifier: SKColor] = [:]

    override init() { super.init(size: CGSize(width: 390, height: 520)); scaleMode = .resizeFill; backgroundColor = .clear }
    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        // SpriteKit views do not reliably forward two simultaneous fingers
        // unless this is enabled at the hosting SKView level.
        view.isMultipleTouchEnabled = true
    }

    func configure(with entries: [MediaEntry],
                   interactionMode: TreasureInteractionMode,
                   onSelect: @escaping (String) -> Void,
                   onLongPress: @escaping (String) -> Void) {
        self.interactionMode = interactionMode
        select = onSelect
        longPress = onLongPress
        longPressWorkItem?.cancel()
        removeAllChildren()
        originalFillColors.removeAll()
        physicsWorld.gravity = CGVector(dx: 0, dy: -4.6)
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame.insetBy(dx: 6, dy: 8))
        for (index, entry) in entries.enumerated() { addTreasure(entry, index: index) }
    }

    /// The map has real physics: tilting the device redirects gravity and a
    /// deliberate shake scatters the visible treasures without changing data.
    func startMotion() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity
            self.physicsWorld.gravity = CGVector(dx: gravity.x * 8.4, dy: gravity.y * 8.4)
            let acceleration = motion.userAcceleration
            let strength = sqrt(acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z)
            if strength > 1.35, Date().timeIntervalSince(self.lastShake) > 0.75 {
                self.lastShake = Date()
                self.scatterTreasures()
            }
        }
    }

    func stopMotion() {
        motionManager.stopDeviceMotionUpdates()
    }

    private func scatterTreasures() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        for case let treasure as SKShapeNode in children where treasure.name != nil {
            guard let body = treasure.physicsBody else { continue }
            body.isDynamic = true
            let direction = CGVector(dx: CGFloat.random(in: -1...1), dy: CGFloat.random(in: 0.3...1.25))
            body.applyImpulse(CGVector(dx: direction.dx * 3.2, dy: direction.dy * 3.2))
            treasure.run(.sequence([.scale(to: 1.06, duration: 0.08), .scale(to: 1, duration: 0.18)]))
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame.insetBy(dx: 6, dy: 8))
    }

    private func addTreasure(_ entry: MediaEntry, index: Int) {
        let width: CGFloat = entry.kind == .video ? 92 : 78
        let height: CGFloat = entry.kind == .video ? 104 : 86
        let node = SKShapeNode(rectOf: CGSize(width: width, height: height), cornerRadius: 17)
        node.name = entry.id
        // A translucent base plus a frosted metadata strip makes each physical
        // node read as an individual glass treasure instead of a colored tile.
        node.fillColor = .white.withAlphaComponent(0.16)
        originalFillColors[ObjectIdentifier(node)] = node.fillColor
        node.strokeColor = entry.isFavorite ? .yellow.withAlphaComponent(0.92) : .white.withAlphaComponent(0.56)
        node.lineWidth = entry.isFavorite ? 2.1 : 1.2
        node.position = CGPoint(
            x: CGFloat((index * 67) % max(Int(size.width - width), 1)) + width / 2,
            y: size.height - height / 2 - 14 - CGFloat(index / 6) * 3
        )
        node.zRotation = CGFloat((index % 7) - 3) * 0.055
        node.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: width, height: height), center: .zero)
        node.physicsBody?.restitution = 0.28
        node.physicsBody?.friction = 0.62
        node.physicsBody?.linearDamping = 0.52
        node.physicsBody?.angularDamping = 0.58
        node.physicsBody?.allowsRotation = true

        let previewHeight = height * 0.62
        let crop = SKCropNode()
        let mask = SKShapeNode(rectOf: CGSize(width: width - 8, height: previewHeight - 5), cornerRadius: 13)
        mask.fillColor = .white
        crop.maskNode = mask
        crop.position = CGPoint(x: 0, y: height * 0.16)
        let previewSize = CGSize(width: width - 8, height: previewHeight - 5)
        if entry.kind == .video, let url = entry.remoteURL, url.isFileURL {
            let video = SKVideoNode(url: url)
            video.name = "video-preview"
            video.size = previewSize
            video.position = .zero
            crop.addChild(video)
            video.play()
        } else {
            let preview = SKSpriteNode(color: color(for: entry).withAlphaComponent(0.88), size: previewSize)
            preview.name = "preview"
            crop.addChild(preview)
            loadPreview(for: entry, into: preview, fill: preview.size)
        }
        node.addChild(crop)

        let glassStrip = SKShapeNode(rectOf: CGSize(width: width - 7, height: height * 0.30), cornerRadius: 12)
        glassStrip.fillColor = SKColor(white: 0.03, alpha: 0.48)
        glassStrip.strokeColor = .white.withAlphaComponent(0.16)
        glassStrip.lineWidth = 0.8
        glassStrip.position = CGPoint(x: 0, y: -height * 0.30)
        node.addChild(glassStrip)

        if entry.kind == .video {
            let playGlass = SKShapeNode(circleOfRadius: 16)
            playGlass.fillColor = .white.withAlphaComponent(0.76)
            playGlass.strokeColor = .white.withAlphaComponent(0.9)
            playGlass.lineWidth = 1
            playGlass.position = CGPoint(x: 0, y: height * 0.16)
            let icon = SKLabelNode(fontNamed: "SFProDisplay-Semibold")
            icon.text = "▶"; icon.fontColor = .black; icon.fontSize = 15
            icon.verticalAlignmentMode = .center; icon.horizontalAlignmentMode = .center; icon.position = CGPoint(x: 1.5, y: 0)
            playGlass.addChild(icon)
            node.addChild(playGlass)
        } else {
            let icon = SKLabelNode(fontNamed: "SFProDisplay-Semibold")
            icon.text = "✦"; icon.fontColor = .white; icon.fontSize = 17
            icon.verticalAlignmentMode = .center; icon.position = CGPoint(x: 0, y: height * 0.16)
            node.addChild(icon)
        }
        let title = SKLabelNode(fontNamed: "SFProText-Medium")
        title.text = String(entry.title.prefix(8))
        title.fontSize = 9; title.fontColor = .white; title.verticalAlignmentMode = .center; title.position = CGPoint(x: 0, y: -height * 0.31)
        title.preferredMaxLayoutWidth = width - 12; title.numberOfLines = 2
        node.addChild(title)

        // Spawn every requested card inside the edge loop. The old positions
        // started above the top physics boundary, so part of the requested
        // batch could never enter the visible scene.
        node.alpha = 0
        node.setScale(0.82)
        node.physicsBody?.isDynamic = false
        addChild(node)
        node.run(.sequence([
            .wait(forDuration: min(Double(index) * 0.035, 0.9)),
            .group([.fadeIn(withDuration: 0.16), .scale(to: 1, duration: 0.18)]),
            .run { [weak node] in node?.physicsBody?.isDynamic = true }
        ]))
    }

    private func loadPreview(for entry: MediaEntry, into preview: SKSpriteNode, fill size: CGSize) {
        guard let url = entry.coverURL ?? (entry.kind == .image ? entry.remoteURL : nil) else { return }
        Task { @MainActor [weak preview] in
            guard let preview, let image = await TreasurePreviewStore.shared.image(at: url) else { return }
            let texture = SKTexture(image: image)
            let ratio = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            preview.texture = texture
            preview.size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        }
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressWorkItem?.cancel()
        longPressTriggered = false
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let location = touch.location(in: self)
            guard let treasure = treasure(at: location) else { continue }
            draggedTreasures[key] = treasure
            touchStarts[key] = location
            treasure.zPosition = 50 + CGFloat(draggedTreasures.count)
            if interactionMode == .drag {
                // Each finger owns its card; gravity cannot pull it away mid-drag.
                treasure.physicsBody?.affectedByGravity = false
                treasure.physicsBody?.isDynamic = false
            } else if draggedTreasures.count == 1, let id = treasure.name {
                let work = DispatchWorkItem { [weak self, weak treasure] in
                    guard let self, self.draggedTreasures.values.contains(where: { $0 === treasure }),
                          !self.movedTouches.contains(key) else { return }
                    self.longPressTriggered = true
                    self.longPress?(id)
                }
                longPressWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let treasure = draggedTreasures[key], let start = touchStarts[key] else { continue }
            let location = touch.location(in: self)
            let distance = hypot(location.x - start.x, location.y - start.y)
            if distance > (interactionMode == .drag ? 4 : 10) { movedTouches.insert(key) }
            guard interactionMode == .drag else {
                if movedTouches.contains(key) { longPressWorkItem?.cancel() }
                continue
            }
            let halfWidth = treasure.frame.width / 2 + 5
            let halfHeight = treasure.frame.height / 2 + 5
            treasure.position = CGPoint(x: min(max(location.x, halfWidth), size.width - halfWidth),
                                        y: min(max(location.y, halfHeight), size.height - halfHeight))
            updateFusion(for: treasure)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressWorkItem?.cancel()
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let treasure = draggedTreasures[key] else { continue }
            if !movedTouches.contains(key), !longPressTriggered, let id = treasure.name { select?(id) }
            finishDrag(for: key)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressWorkItem?.cancel()
        for touch in touches { finishDrag(for: ObjectIdentifier(touch)) }
    }

    private func treasure(at location: CGPoint) -> SKShapeNode? {
        for node in nodes(at: location) {
            var candidate: SKNode? = node
            while let current = candidate {
                if let treasure = current as? SKShapeNode, treasure.name != nil { return treasure }
                candidate = current.parent
            }
        }
        return nil
    }

    /// Two cards keep their own identities, while this temporary shared
    /// capsule makes the close approach read like liquid-glass droplets.
    private func updateFusion(for treasure: SKShapeNode) {
        let nearest = children.compactMap { $0 as? SKShapeNode }
            .filter { $0 !== treasure && $0.name != nil }
            .min { hypot($0.position.x - treasure.position.x, $0.position.y - treasure.position.y) < hypot($1.position.x - treasure.position.x, $1.position.y - treasure.position.y) }
        guard let other = nearest else { removeFusion(); return }
        let distance = hypot(other.position.x - treasure.position.x, other.position.y - treasure.position.y)
        let threshold = (treasure.frame.width + other.frame.width) * 0.42
        guard distance < threshold else { removeFusion(); return }
        if fusedWith !== other {
            fusedWith = other
            fusionSource = treasure
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.55)
        }
        let center = CGPoint(x: (treasure.position.x + other.position.x) / 2, y: (treasure.position.y + other.position.y) / 2)
        let width = max(distance + min(treasure.frame.width, other.frame.width) * 0.72, 62)
        let height = max(treasure.frame.height, other.frame.height) * 0.82
        let angle = atan2(other.position.y - treasure.position.y, other.position.x - treasure.position.x)
        let halo = fusionHalo ?? SKShapeNode()
        halo.path = CGPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        halo.fillColor = SKColor(red: 0.95, green: 0.68, blue: 0.16, alpha: 0.34)
        halo.strokeColor = SKColor(red: 1.0, green: 0.78, blue: 0.26, alpha: 0.96)
        treasure.fillColor = SKColor(red: 0.92, green: 0.63, blue: 0.14, alpha: 0.34)
        other.fillColor = SKColor(red: 0.92, green: 0.63, blue: 0.14, alpha: 0.34)
        halo.lineWidth = 1.3
        halo.position = center
        halo.zRotation = angle
        halo.zPosition = 4
        if fusionHalo == nil {
            halo.alpha = 0
            addChild(halo)
            halo.run(.fadeIn(withDuration: 0.13))
            fusionHalo = halo
        }
    }

    private func finishDrag(for key: ObjectIdentifier) {
        guard let treasure = draggedTreasures.removeValue(forKey: key) else { return }
        treasure.zPosition = 0
        treasure.physicsBody?.affectedByGravity = true
        treasure.physicsBody?.isDynamic = true
        touchStarts[key] = nil
        movedTouches.remove(key)
        if draggedTreasures.isEmpty {
            longPressTriggered = false
            removeFusion()
        }
    }

    private func removeFusion() {
        if let source = fusionSource {
            source.fillColor = originalFillColors[ObjectIdentifier(source)] ?? .white.withAlphaComponent(0.16)
        }
        if let other = fusedWith {
            other.fillColor = originalFillColors[ObjectIdentifier(other)] ?? .white.withAlphaComponent(0.16)
        }
        fusionSource = nil
        fusedWith = nil
        guard let fusionHalo else { return }
        self.fusionHalo = nil
        fusionHalo.run(.sequence([.fadeOut(withDuration: 0.16), .removeFromParent()]))
    }
}

@MainActor
private final class TreasurePreviewStore {
    static let shared = TreasurePreviewStore()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {}

    func image(at url: URL) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image: UIImage?
        if url.isFileURL {
            image = UIImage(contentsOfFile: url.path)
        } else if let (data, _) = try? await URLSession.shared.data(from: url) {
            image = UIImage(data: data)
        } else {
            image = nil
        }
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

