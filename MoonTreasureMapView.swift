import SpriteKit
import SwiftUI
import UIKit
import CoreMotion
import ImageIO
import AVFoundation

/// Separate experiences share media, never their playback state.
struct MoonTreasureMapView: View {
    var openVideoWall = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var wall = false
    @State private var initialized = false
    @State private var activeEntry: MediaEntry?
    @State private var actionEntry: MediaEntry?
    @State private var scope = TreasureScope.all
    @AppStorage("treasure-count") private var dropCount = 12
    @AppStorage("treasure-organized") private var organized = false
    @AppStorage("treasure-video-autoplay") private var videoAutoplay = false
    @AppStorage("treasure-appearance-v23") private var appearanceData = Data()
    @AppStorage("treasure-directed-v21") private var legacyAppearance = Data()
    @State private var appearance = TreasureAppearance()
    @State private var showingAppearance = false
    @StateObject private var videoPreviews = TreasureVideoPreviews()
    @State private var visibleGridVideos = Set<String>()
    @State private var scene = MoonTreasureScene()
    @State private var glassFrames: [TreasureGlassFrame] = []
    @State private var sceneDirty = false
    @State private var dragDiagnostics = ""
    @State private var videoDiagnostics = ""
    @State private var pageVisible = false

    private var filteredItems: [MediaEntry] {
        let source: [MediaEntry]
        switch scope {
        case .all: source = model.mediaStore.items
        case .favorites: source = model.mediaStore.items.filter(\.isFavorite)
        case .videos: source = model.mediaStore.items.filter { $0.kind == .video }
        }
        return TreasureRules.unique(source, id: \.id)
    }
    private var items: [MediaEntry] { Array(filteredItems.prefix(TreasureRules.count(selected: dropCount, available: filteredItems.count))) }
    private var darkCards: Bool { appearance.isDark(system: colorScheme) }
    var body: some View {
        VStack(spacing: 10) {
            Picker("月藏图模式", selection: $wall) {
                Text("自由散落").tag(false)
                Text("视频墙").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 14).accessibilityIdentifier("treasure-experience")
            ZStack {
                // Keep the SKView mounted so switching experiences preserves
                // positions, velocities, camera and independently chosen count.
                freeContent.opacity(wall ? 0 : 1).allowsHitTesting(!wall).accessibilityHidden(wall)
                if wall { TreasureVideoWallView().environmentObject(model) }
            }
        }
        .background { TreasureBackgroundSurface(options: appearance).ignoresSafeArea() }
        .preferredColorScheme(appearance.background == .system ? nil : (darkCards ? .dark : .light))
        .navigationTitle("月藏图").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() }.accessibilityIdentifier("treasure-map-close") }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAppearance = true } label: { Image(systemName: "paintpalette").frame(width: 44, height: 44) }
                    .accessibilityLabel("月藏图背景").accessibilityIdentifier("treasure-appearance")
            }
        }
        .sheet(isPresented: $showingAppearance) {
            NavigationStack {
                TreasureAppearanceSettings(options: $appearance)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingAppearance = false } } }
            }
        }
        .onAppear {
            pageVisible = true
            if !initialized {
                appearance = TreasureAppearance.load(appearanceData, legacy: legacyAppearance)
                wall = openVideoWall; initialized = true
            }
            syncFreeState()
        }
        .onDisappear { pageVisible = false; videoPreviews.stopAll(); scene.stopMotion() }
        .onChange(of: wall) { _ in
            if !wall && sceneDirty { configureScene() }
            syncFreeState()
        }
        .onChange(of: appearance) { value in
            appearanceData = (try? JSONEncoder().encode(value)) ?? Data()
            scene.setCardContrast(dark: darkCards)
        }
        .onChange(of: colorScheme) { _ in scene.setCardContrast(dark: darkCards) }
        .onChange(of: scenePhase) { _ in syncFreeState() }
        .onChange(of: activeEntry?.id) { _ in syncFreeState() }
        .onChange(of: scope) { _ in configureScene() }
        .onChange(of: dropCount) { _ in configureScene() }
        .onChange(of: model.mediaStore.items) { _ in
            if wall { sceneDirty = true } else { configureScene() }
        }
        .onChange(of: videoAutoplay) { _ in refreshVideoPreviews() }
        .onChange(of: organized) { _ in
            videoPreviews.stopAll(); scene.setVideoPreviews([:]); refreshVideoPreviews()
        }
        .onReceive(videoPreviews.$players) { scene.setVideoPreviews(organized || wall ? [:] : $0) }
        .fullScreenCover(item: $activeEntry) { entry in
            MediaPlayerView(entry: entry, onShareToMoments: { activeEntry = nil }, onQueueAdvance: { activeEntry = $0 }).environmentObject(model)
        }
        .confirmationDialog(actionEntry?.title ?? "藏品操作", isPresented: Binding(get: { actionEntry != nil }, set: { if !$0 { actionEntry = nil } }), titleVisibility: .visible) {
            Button("打开播放") { activeEntry = actionEntry; actionEntry = nil }
            Button(actionEntry?.isFavorite == true ? "取消收藏" : "收藏") { if let entry = actionEntry { model.mediaStore.toggleFavorite(entry) }; actionEntry = nil }
            Button("加入播放队列") { if let entry = actionEntry { model.mediaStore.enqueue([entry]) }; actionEntry = nil }
            Button("取消", role: .cancel) { actionEntry = nil }
        }
        .overlay(alignment: .bottomTrailing) { debugLabels }
        .task { await updateDiagnostics() }
    }
    private var freeContent: some View {
        VStack(spacing: 10) {
            HStack {
                Picker("藏宝范围", selection: $scope) { ForEach(TreasureScope.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Menu {
                    Picker("掉落数量", selection: $dropCount) { ForEach([6, 12, 20, 30, 42], id: \.self) { Text("\($0) 张").tag($0) } }
                } label: { Text("\(dropCount) 张").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityIdentifier("treasure-drop-count")
                Menu {
                    Picker("视频预览", selection: $videoAutoplay) {
                        Text("静止封面").tag(false); Text("自动播放（最多3张）").tag(true)
                    }
                } label: { Image(systemName: videoAutoplay ? "video.fill" : "video.slash").frame(width: 44, height: 44) }
                    .accessibilityLabel("视频预览").accessibilityValue(videoAutoplay ? "自动播放" : "静止封面").accessibilityIdentifier("treasure-video-mode")
            }.buttonStyle(MoonGlassButtonStyle()).padding(8).moonSingleGlass().padding(.horizontal, 14)
            freeStage
            HStack {
                Text("\(scope.title) · \(organized ? filteredItems.count : items.count) 张").font(.caption).accessibilityIdentifier("treasure-actual-count")
                Spacer()
                Button(organized ? "自由" : "整理") { organized.toggle() }.accessibilityIdentifier("treasure-layout")
                Button("重新散落") { scene.scatterTreasures() }.disabled(organized).accessibilityIdentifier("treasure-scatter")
                Button("重置") { configureScene() }.disabled(organized).accessibilityIdentifier("treasure-reset")
            }.frame(minHeight: 44).buttonStyle(MoonGlassButtonStyle()).padding(10).moonSingleGlass().padding(.horizontal, 14)
            if filteredItems.isEmpty { Text("宝库还是空的，请从库中导入图片或视频。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private var freeStage: some View {
        if organized {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))]) {
                    ForEach(filteredItems) { entry in
                        TreasureOrganizedCard(entry: entry, player: videoPreviews.players[entry.id], onOpen: { activeEntry = entry }, onHold: { actionEntry = entry })
                            .onAppear { if entry.kind == .video { visibleGridVideos.insert(entry.id); refreshVideoPreviews() } }
                            .onDisappear { visibleGridVideos.remove(entry.id); refreshVideoPreviews() }
                    }
                }.padding(14)
            }.accessibilityIdentifier("treasure-grid")
        } else {
            ZStack {
                TreasurePhysicsGlass(frames: glassFrames, sceneSize: scene.size)
                SpriteView(scene: scene, options: [.allowsTransparency])
            }
                .clipShape(RoundedRectangle(cornerRadius: 24)).padding(.horizontal, 14)
                .accessibilityIdentifier("moon-treasure-map")
                .onAppear { if scene.children.isEmpty || !scene.hasCallbacks { configureScene() }; syncFreeState() }
        }
    }
    private func configureScene() {
        sceneDirty = false
        scene.onGlassFrames = { glassFrames = $0 }
        #if DEBUG
        scene.onDragDiagnostics = { dragDiagnostics = $0 }
        #endif
        scene.configure(with: items, onSelect: { id in activeEntry = model.mediaStore.items.first { $0.id == id } }, onLongPress: { id in actionEntry = model.mediaStore.items.first { $0.id == id } })
        scene.setCardContrast(dark: darkCards); syncFreeState()
    }
    private func syncFreeState() {
        if pageVisible && !wall && !organized && scenePhase == .active && activeEntry == nil { scene.startMotion() }
        else { scene.stopMotion() }
        refreshVideoPreviews()
    }
    private func refreshVideoPreviews() {
        let candidates = organized ? filteredItems.filter { visibleGridVideos.contains($0.id) } : items
        videoPreviews.configure(entries: candidates, enabled: pageVisible && !wall && videoAutoplay && scenePhase == .active && activeEntry == nil)
        scene.setVideoPreviews(organized || wall ? [:] : videoPreviews.players)
    }
    @ViewBuilder private var debugLabels: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--treasure-drag-ui-tests") {
            Text("物理拖拽测试状态").font(.system(size: 1)).frame(height: 1).opacity(0.01).allowsHitTesting(false)
                .accessibilityIdentifier("treasure-physics-probe").accessibilityValue(dragDiagnostics)
        }
        if ProcessInfo.processInfo.arguments.contains("--treasure-video-ui-tests") || ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") {
            Text("视频预览测试状态").font(.system(size: 1)).frame(height: 1).opacity(0.01).allowsHitTesting(false)
                .accessibilityIdentifier("treasure-video-probe").accessibilityValue(videoDiagnostics)
        }
        #endif
    }
    private func updateDiagnostics() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--treasure-video-ui-tests") || ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") else { return }
        while !Task.isCancelled {
            let values: [String: Int] = ["players": videoPreviews.players.count,
                "advancing": videoPreviews.players.values.filter { $0.rate > 0 && $0.currentTime().seconds > 0.05 }.count,
                "muted": videoPreviews.players.values.allSatisfy(\.isMuted) ? 1 : 0,
                "nodes": scene.videoPreviewCount, "centerIcons": scene.centerPlayIconCount, "auto": videoAutoplay ? 1 : 0]
            videoDiagnostics = String(data: (try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys)) ?? Data(), encoding: .utf8) ?? ""
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        #endif
    }
}
private enum TreasureScope: String, CaseIterable, Identifiable {
    case all, favorites, videos
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .favorites: "收藏"; case .videos: "视频" } }
}

private struct TreasureGlassFrame: Identifiable, Equatable {
    let id: String
    let center: CGPoint
    let size: CGSize
    let rotation: CGFloat
    let scale: CGFloat
    let z: CGFloat
}
private struct TreasurePhysicsGlass: View {
    let frames: [TreasureGlassFrame]
    let sceneSize: CGSize
    var body: some View {
        GeometryReader { geometry in
            let sx = geometry.size.width / max(1, sceneSize.width)
            let sy = geometry.size.height / max(1, sceneSize.height)
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 0) { surfaces(sx: sx, sy: sy, height: geometry.size.height) }
            } else { surfaces(sx: sx, sy: sy, height: geometry.size.height) }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .transaction { $0.animation = nil }
    }
    private func surfaces(sx: CGFloat, sy: CGFloat, height: CGFloat) -> some View {
        ZStack {
            ForEach(frames) { frame in
                MoonGlassBackdrop(radius: 17)
                    .frame(width: frame.size.width * sx, height: frame.size.height * sy)
                    .scaleEffect(frame.scale).rotationEffect(.radians(-Double(frame.rotation)))
                    .position(x: frame.center.x * sx, y: height - frame.center.y * sy)
                    .zIndex(Double(frame.z))
            }
        }
    }
}

private final class MoonTreasureScene: SKScene {
    var onGlassFrames: (([TreasureGlassFrame]) -> Void)?
    private var lastGlassTime: TimeInterval = 0
    private var lastGlassFrames: [TreasureGlassFrame] = []
    var hasCallbacks: Bool { select != nil && longPress != nil }
    var onDragDiagnostics: ((String) -> Void)?
    private var darkCards = true
    private var videoBindings: [String: AVQueuePlayer] = [:]
    private var select: ((String) -> Void)?
    private var longPress: ((String) -> Void)?
    private var longPressTasks: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var heldTouches = Set<ObjectIdentifier>()
    private var samples: [ObjectIdentifier: [(CGPoint, TimeInterval)]] = [:]
    private var offsets: [ObjectIdentifier: CGPoint] = [:]
    // The finger owns both position and physics until end/cancel. Keeping a
    // separate anchor also holds the card still when no move events arrive.
    private var dragAnchors: [ObjectIdentifier: CGPoint] = [:]
    private var savedPhysics: [ObjectIdentifier: (dynamic: Bool, gravity: Bool, rotation: Bool)] = [:]
    #if DEBUG
    private var lastDiagnosticsTime: TimeInterval = 0
    private var diagnosticMoves = 0
    private var diagnosticCancellations = 0
    private var diagnosticHeldFrames = 0
    private var diagnosticTravel: CGFloat = 0
    private var diagnosticDrift: CGFloat = 0
    private var diagnosticReleasedPhysics = false
    private var diagnosticPhysicsViolations = 0
    #endif
    private var previewTasks: [Task<Void, Never>] = []
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
                   onSelect: @escaping (String) -> Void,
                   onLongPress: @escaping (String) -> Void) {
        select = onSelect
        longPress = onLongPress
        stopMotion()
        previewTasks.forEach { $0.cancel() }
        previewTasks.removeAll()
        children.forEach { $0.removeAllActions() }
        removeAllChildren()
        videoBindings.removeAll()
        originalFillColors.removeAll()
        physicsWorld.gravity = CGVector(dx: 0, dy: -4.6)
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame.insetBy(dx: 6, dy: 8))
        for (index, entry) in TreasureRules.unique(entries, id: \.id).prefix(42).enumerated() { addTreasure(entry, index: index) }
        startMotion()
    }

    /// The map has real physics: tilting the device redirects gravity and a
    /// deliberate shake scatters the visible treasures without changing data.
    func startMotion() {
        isPaused = false
        physicsWorld.gravity = CGVector(dx: 0, dy: -4.6)
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 50.0
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity
            let orientation = self.view?.window?.windowScene?.interfaceOrientation
            switch orientation {
            case .landscapeLeft: self.physicsWorld.gravity = CGVector(dx: -gravity.y * 8.4, dy: gravity.x * 8.4)
            case .landscapeRight: self.physicsWorld.gravity = CGVector(dx: gravity.y * 8.4, dy: -gravity.x * 8.4)
            case .portraitUpsideDown: self.physicsWorld.gravity = CGVector(dx: -gravity.x * 8.4, dy: -gravity.y * 8.4)
            default: self.physicsWorld.gravity = CGVector(dx: gravity.x * 8.4, dy: gravity.y * 8.4)
            }
            let acceleration = motion.userAcceleration
            let strength = sqrt(acceleration.x * acceleration.x + acceleration.y * acceleration.y + acceleration.z * acceleration.z)
            if strength > 1.35, !UIAccessibility.isReduceMotionEnabled, Date().timeIntervalSince(self.lastShake) > 1.5 {
                self.lastShake = Date()
                self.scatterTreasures()
            }
        }
    }

    func stopMotion() {
        isPaused = true
        motionManager.stopDeviceMotionUpdates()
        for key in Array(draggedTreasures.keys) { finishDrag(for: key) }
        removeFusion()
    }

    func scatterTreasures() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let amplitude: CGFloat = UIAccessibility.isReduceMotionEnabled ? 0.25 : 1
        for case let treasure as SKShapeNode in children where treasure.name != nil {
            guard !draggedTreasures.values.contains(where: { $0 === treasure }), let body = treasure.physicsBody else { continue }
            body.isDynamic = true
            let direction = CGVector(dx: CGFloat.random(in: -1...1), dy: CGFloat.random(in: 0.3...1.25))
            body.applyImpulse(CGVector(dx: direction.dx * 3.2 * amplitude, dy: direction.dy * 3.2 * amplitude))
            if !UIAccessibility.isReduceMotionEnabled { treasure.run(.sequence([.scale(to: 1.06, duration: 0.08), .scale(to: 1, duration: 0.18)])) }
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
        // The sole material is a native glass surface behind this scene.
        // The transparent SpriteKit shape still owns physical hit testing.
        node.fillColor = .clear
        originalFillColors[ObjectIdentifier(node)] = node.fillColor
        node.strokeColor = entry.isFavorite ? .yellow.withAlphaComponent(0.75) : .clear
        node.lineWidth = entry.isFavorite ? 1 : 0
        node.position = CGPoint(
            x: 72 + CGFloat(index % max(Int((size.width - 144) / 105) + 1, 1)) * 105,
            y: 80 + CGFloat((index / 3) % max(Int((size.height - 160) / 115) + 1, 1)) * 115
        )
        node.position = clamped(node.position, node: node)
        node.zRotation = CGFloat((index % 7) - 3) * 0.055
        node.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: width, height: height), center: .zero)
        node.physicsBody?.usesPreciseCollisionDetection = true
        node.physicsBody?.restitution = 0.22
        node.physicsBody?.friction = 0.62
        node.physicsBody?.linearDamping = 0.52
        node.physicsBody?.angularDamping = 0.58
        node.physicsBody?.allowsRotation = true

        let previewHeight = height * 0.62
        let crop = SKCropNode()
        crop.name = "preview-crop"
        let mask = SKShapeNode(rectOf: CGSize(width: width - 8, height: previewHeight - 5), cornerRadius: 13)
        mask.fillColor = .white
        crop.maskNode = mask
        crop.position = CGPoint(x: 0, y: height * 0.16)
        let previewSize = CGSize(width: width - 8, height: previewHeight - 5)
        let preview = SKSpriteNode(color: color(for: entry).withAlphaComponent(0.88), size: previewSize)
        crop.addChild(preview)
        loadPreview(for: entry, into: preview, fill: preview.size)
        node.addChild(crop)

        let glassStrip = SKShapeNode(rectOf: CGSize(width: width - 7, height: height * 0.30), cornerRadius: 12)
        glassStrip.fillColor = SKColor(white: 0.03, alpha: 0.48)
        glassStrip.strokeColor = .clear
        glassStrip.lineWidth = 0.8
        glassStrip.position = CGPoint(x: 0, y: -height * 0.30)
        node.addChild(glassStrip)

        if entry.kind == .video {
            let badge = SKLabelNode(fontNamed: "SFProText-Medium")
            badge.text = "视频"; badge.fontSize = 8; badge.fontColor = .white
            badge.position = CGPoint(x: width / 2 - 16, y: height / 2 - 14)
            badge.zPosition = 3
            node.addChild(badge)
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
        addChild(node)
        if !UIAccessibility.isReduceMotionEnabled {
            node.setScale(0.9)
            node.run(.sequence([.wait(forDuration: Double(index) * 0.04), .scale(to: 1, duration: 0.15)]), withKey: "spawn")
        }
    }

    #if DEBUG
    var videoPreviewCount: Int { videoBindings.count }
    var centerPlayIconCount: Int {
        var count = 0
        enumerateChildNodes(withName: "//*") { node, _ in
            if (node as? SKLabelNode)?.text == "▶" { count += 1 }
        }
        return count
    }
    #endif

    func setCardContrast(dark: Bool) {
        darkCards = dark
        for case let card as SKShapeNode in children where card.name != nil {
            card.fillColor = .clear
            originalFillColors[ObjectIdentifier(card)] = card.fillColor
        }
    }

    func setVideoPreviews(_ players: [String: AVQueuePlayer]) {
        for case let card as SKShapeNode in children {
            guard let id = card.name, let crop = card.childNode(withName: "preview-crop") as? SKCropNode else { continue }
            if let player = players[id], videoBindings[id] === player { continue }
            (crop.childNode(withName: "video-preview") as? SKVideoNode)?.pause()
            crop.childNode(withName: "video-preview")?.removeFromParent()
            videoBindings[id] = nil
            guard let player = players[id] else { continue }
            let video = SKVideoNode(avPlayer: player)
            video.name = "video-preview"
            video.size = crop.maskNode?.frame.size ?? CGSize(width: 84, height: 60)
            video.zPosition = 1
            crop.addChild(video)
            videoBindings[id] = player
            video.play()
        }
    }

    private func loadPreview(for entry: MediaEntry, into preview: SKSpriteNode, fill size: CGSize) {
        guard let url = entry.coverURL ?? entry.remoteURL else { return }
        previewTasks.append(Task { @MainActor [weak self, weak preview] in
            let image = await TreasurePreviewStore.shared.image(at: url, video: entry.kind == .video && entry.coverURL == nil)
            guard !Task.isCancelled, let preview, let self, preview.scene === self, let image else { return }
            preview.texture = SKTexture(image: image)
            let ratio = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            preview.size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        })
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
        for touch in touches {
            let key = ObjectIdentifier(touch), point = touch.location(in: self)
            guard let node = treasure(at: point), !draggedTreasures.values.contains(where: { $0 === node }) else { continue }
            draggedTreasures[key] = node
            touchStarts[key] = point
            offsets[key] = CGPoint(x: node.position.x - point.x, y: node.position.y - point.y)
            samples[key] = [(point, touch.timestamp)]
            dragAnchors[key] = node.position
            if let body = node.physicsBody {
                savedPhysics[key] = (body.isDynamic, body.affectedByGravity, body.allowsRotation)
            }
            node.removeAllActions()
            pinToFinger(node, at: node.position)
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.movedTouches.contains(key), let node = self.draggedTreasures[key], let id = node.name else { return }
                self.heldTouches.insert(key)
                self.longPress?(id)
            }
            longPressTasks[key] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let node = draggedTreasures[key], let start = touchStarts[key], !heldTouches.contains(key) else { continue }
            let point = touch.location(in: self)
            #if DEBUG
            diagnosticMoves += 1
            diagnosticTravel = max(diagnosticTravel, hypot(point.x - start.x, point.y - start.y))
            #endif
            if TreasureRules.shouldDrag(distance: hypot(point.x - start.x, point.y - start.y)) {
                longPressTasks.removeValue(forKey: key)?.cancel()
                if movedTouches.insert(key).inserted {
                    node.removeAction(forKey: "spawn")
                    node.physicsBody?.isDynamic = false
                    node.physicsBody?.affectedByGravity = false
                    node.zPosition = 50
                    node.setScale(UIAccessibility.isReduceMotionEnabled ? 1 : 1.05)
                }
            }
            guard movedTouches.contains(key) else { continue }
            let offset = offsets[key] ?? .zero
            let anchor = clamped(CGPoint(x: point.x + offset.x, y: point.y + offset.y), node: node)
            dragAnchors[key] = anchor
            pinToFinger(node, at: anchor)
            samples[key, default: []].append((point, touch.timestamp))
            samples[key] = samples[key]?.filter { touch.timestamp - $0.1 <= 0.12 }
            updateFusion(for: node)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let node = draggedTreasures[key]
            let open = TreasureRules.shouldOpen(dragged: movedTouches.contains(key), held: heldTouches.contains(key))
            var velocity = CGVector.zero
            if movedTouches.contains(key), let first = samples[key]?.first, touch.timestamp - first.1 < 0.16 {
                let point = touch.location(in: self), dt = max(touch.timestamp - first.1, 0.016)
                let dx = (point.x - first.0.x) / dt, dy = (point.y - first.0.y) / dt
                let factor = min(1, 850 / max(hypot(dx, dy), 1))
                velocity = CGVector(dx: dx * factor, dy: dy * factor)
            }
            finishDrag(for: key)
            node?.physicsBody?.velocity = velocity
            if open, let id = node?.name { select?(id) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            #if DEBUG
            if draggedTreasures[key] != nil { diagnosticCancellations += 1 }
            #endif
            finishDrag(for: key)
        }
    }

    override func willMove(from view: SKView) {
        stopMotion()
        previewTasks.forEach { $0.cancel() }
        previewTasks.removeAll()
        select = nil
        longPress = nil
        onDragDiagnostics = nil
        onGlassFrames = nil
        setVideoPreviews([:])
    }

    private func clamped(_ point: CGPoint, node: SKNode) -> CGPoint {
        let x = min(node.frame.width / 2 + 10, size.width / 2)
        let y = min(node.frame.height / 2 + 10, size.height / 2)
        return CGPoint(x: min(max(point.x, x), size.width - x), y: min(max(point.y, y), size.height - y))
    }

    private func pinToFinger(_ node: SKShapeNode, at point: CGPoint) {
        if let body = node.physicsBody {
            body.affectedByGravity = false
            body.isDynamic = false
            body.allowsRotation = false
            body.velocity = .zero
            body.angularVelocity = 0
        }
        node.position = point
    }

    override func update(_ currentTime: TimeInterval) {
        // CoreMotion and collisions may continue for other cards. They must
        // never change a finger-owned card, even during a stationary hold.
        for (key, node) in draggedTreasures {
            guard let point = dragAnchors[key] else { continue }
            let anchor = clamped(point, node: node)
            dragAnchors[key] = anchor
            pinToFinger(node, at: anchor)
        }
    }

    override func didSimulatePhysics() {
        for case let node as SKShapeNode in children where node.name != nil {
            node.position = clamped(node.position, node: node)
            if let body = node.physicsBody {
                body.angularVelocity = min(max(body.angularVelocity, -4), 4)
            }
        }
        for (key, node) in draggedTreasures {
            guard let anchor = dragAnchors[key] else { continue }
            #if DEBUG
            if movedTouches.contains(key) {
                diagnosticHeldFrames += 1
                if let body = node.physicsBody, body.isDynamic || body.affectedByGravity || body.allowsRotation {
                    diagnosticPhysicsViolations += 1
                }
                diagnosticDrift = max(diagnosticDrift, hypot(node.position.x - anchor.x, node.position.y - anchor.y))
            }
            #endif
            pinToFinger(node, at: anchor)
        }
        publishGlassFrames()
        publishDragDiagnostics()
    }
    private func publishGlassFrames() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastGlassTime >= 1.0 / 30 else { return }
        lastGlassTime = now
        let frames = children.compactMap { node -> TreasureGlassFrame? in
            guard let shape = node as? SKShapeNode, let id = shape.name, let path = shape.path else { return nil }
            let center = CGPoint(x: (shape.position.x * 2).rounded() / 2, y: (shape.position.y * 2).rounded() / 2)
            return TreasureGlassFrame(id: id, center: center, size: path.boundingBox.size,
                rotation: (shape.zRotation * 200).rounded() / 200, scale: shape.xScale, z: shape.zPosition)
        }
        guard frames != lastGlassFrames else { return }
        lastGlassFrames = frames; onGlassFrames?(frames)
    }

    private func publishDragDiagnostics() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--treasure-drag-ui-tests"),
              let view, let card = children.first(where: { $0.name != nil }) else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastDiagnosticsTime >= 0.1 else { return }
        lastDiagnosticsTime = now
        let point = view.convert(convertPoint(toView: card.position), to: nil)
        let origin = view.convert(CGPoint.zero, to: nil)
        let values: [String: Double] = [
            "x": Double(point.x), "y": Double(point.y),
            "width": Double(view.bounds.width), "height": Double(view.bounds.height),
            "originX": Double(origin.x), "originY": Double(origin.y),
            "owned": Double(draggedTreasures.count), "moves": Double(diagnosticMoves),
            "cancelled": Double(diagnosticCancellations), "frames": Double(diagnosticHeldFrames),
            "travel": Double(diagnosticTravel), "drift": Double(diagnosticDrift),
            "released": diagnosticReleasedPhysics ? 1 : 0,
            "violations": Double(diagnosticPhysicsViolations)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let value = String(data: data, encoding: .utf8) else { return }
        // SpriteView wraps SKView's accessibility tree. Publish through a
        // separate SwiftUI probe instead of relying on the wrapped SKView.
        onDragDiagnostics?(value)
        #endif
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

        }
        let center = CGPoint(x: (treasure.position.x + other.position.x) / 2, y: (treasure.position.y + other.position.y) / 2)
        let width = max(distance + min(treasure.frame.width, other.frame.width) * 0.72, 62)
        let height = max(treasure.frame.height, other.frame.height) * 0.82
        let angle = atan2(other.position.y - treasure.position.y, other.position.x - treasure.position.x)
        let halo = fusionHalo ?? SKShapeNode()
        halo.path = CGPath(roundedRect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height), cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        halo.fillColor = SKColor(red: 0.95, green: 0.68, blue: 0.16, alpha: 0.16)
        halo.strokeColor = SKColor(red: 1.0, green: 0.78, blue: 0.26, alpha: 0.4)
        treasure.fillColor = SKColor(red: 0.92, green: 0.63, blue: 0.14, alpha: 0.16)
        other.fillColor = SKColor(red: 0.92, green: 0.63, blue: 0.14, alpha: 0.16)
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
        longPressTasks.removeValue(forKey: key)?.cancel()
        heldTouches.remove(key)
        samples[key] = nil
        offsets[key] = nil
        treasure.setScale(1)
        treasure.zPosition = 0
        if let saved = savedPhysics.removeValue(forKey: key), let body = treasure.physicsBody {
            body.affectedByGravity = saved.gravity
            body.isDynamic = saved.dynamic
            body.allowsRotation = saved.rotation
            #if DEBUG
            diagnosticReleasedPhysics = body.isDynamic && body.affectedByGravity
            #endif
        }
        dragAnchors[key] = nil
        touchStarts[key] = nil
        movedTouches.remove(key)
        if draggedTreasures.isEmpty {
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

private struct TreasureOrganizedCard: View {
    let entry: MediaEntry
    let player: AVQueuePlayer?
    let onOpen: () -> Void
    let onHold: () -> Void
    var body: some View {
        VStack {
            TreasureThumbnail(entry: entry, player: player).frame(height: 100)
            Text(entry.title).lineLimit(2)
        }
        .frame(maxWidth: .infinity).padding(8)
        .background { MoonGlassBackdrop(radius: 16) }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .modifier(NativeMediaCardInteractions(holdEnabled: true, onTap: onOpen, onHold: onHold))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(entry.title)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: Text("藏品操作")) { onHold() }
        .accessibilityIdentifier("treasure-grid-" + entry.id)
    }
}

private struct TreasureThumbnail: View {
    let entry: MediaEntry
    let player: AVQueuePlayer?
    @State private var image: UIImage?
    private var url: URL? { entry.coverURL ?? entry.remoteURL }

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if entry.kind != .video { Image(systemName: "photo") }
            else { Color.white.opacity(0.05) }
            if let player {
                TreasureVideoSurface(player: player).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if entry.kind == .video {
                Text("视频").font(.caption2).padding(4)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 5)).padding(4)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            let loaded = await TreasurePreviewStore.shared.image(at: url, video: entry.kind == .video && entry.coverURL == nil)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// A page-scoped pool owns all preview decoders. Both browsing modes use
/// the same limit; media remains on its existing cover until a playable URL loads.
@MainActor
private final class TreasureVideoPreviews: ObservableObject {
    @Published private(set) var players: [String: AVQueuePlayer] = [:]
    private var loopers: [String: AVPlayerLooper] = [:]
    private var loads: [String: Task<Void, Never>] = [:]
    private var assets: [String: AVURLAsset] = [:]
    private var wanted: [String: URL] = [:]

    func configure(entries: [MediaEntry], enabled: Bool) {
        let candidates = enabled ? Array(entries.filter { $0.kind == .video && $0.remoteURL != nil }.prefix(3)) : []
        let next = Dictionary(candidates.compactMap { entry in entry.remoteURL.map { (entry.id, $0) } },
                              uniquingKeysWith: { first, _ in first })
        for id in Array(wanted.keys) where wanted[id] != next[id] { stop(id) }
        wanted = next
        for (id, url) in next where players[id] == nil && loads[id] == nil {
            // remoteURL is the same canonical source used by MediaPlayerView.
            // Asset validation prevents treating arbitrary web URLs as playable.
            let asset = AVURLAsset(url: url)
            assets[id] = asset
            loads[id] = Task { @MainActor [weak self] in
                let playable = (try? await asset.load(.isPlayable)) == true
                guard !Task.isCancelled, let self, self.wanted[id] == url else { return }
                self.loads[id] = nil
                guard playable else { self.assets[id] = nil; return }
                let player = AVQueuePlayer()
                player.isMuted = true
                let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
                self.loopers[id] = looper
                self.players[id] = player
                player.play()
            }
        }
    }

    private func stop(_ id: String) {
        loads.removeValue(forKey: id)?.cancel()
        assets.removeValue(forKey: id)?.cancelLoading()
        loopers.removeValue(forKey: id)?.disableLooping()
        if let player = players.removeValue(forKey: id) {
            player.pause()
            player.removeAllItems()
        }
        wanted[id] = nil
    }

    func stopAll() { for id in Array(wanted.keys) { stop(id) } }
}

private struct TreasureVideoSurface: UIViewRepresentable {
    let player: AVQueuePlayer
    func makeUIView(context: Context) -> TreasureVideoLayerView {
        let view = TreasureVideoLayerView()
        view.videoLayer.videoGravity = .resizeAspectFill
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: TreasureVideoLayerView, context: Context) { view.videoLayer.player = player }
    static func dismantleUIView(_ view: TreasureVideoLayerView, coordinator: ()) { view.videoLayer.player = nil }
}

private final class TreasureVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private actor TreasurePreviewStore {
    static let shared = TreasurePreviewStore()
    private let cache = NSCache<NSURL, UIImage>()
    private init() { cache.countLimit = 84; cache.totalCostLimit = 24 * 1024 * 1024 }

    func image(at url: URL, video: Bool) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image: UIImage?
        if video {
            guard url.isFileURL else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            if let result = try? await generator.image(at: .zero) { image = UIImage(cgImage: result.image) }
            else { image = nil }
        } else {
            let source: CGImageSource?
            if url.isFileURL { source = CGImageSourceCreateWithURL(url as CFURL, nil) }
            else if let (data, _) = try? await URLSession.shared.data(from: url) { source = CGImageSourceCreateWithData(data as CFData, nil) }
            else { source = nil }
            if let source, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary) { image = UIImage(cgImage: cg) }
            else { image = nil }
        }
        if let image { cache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }
}
