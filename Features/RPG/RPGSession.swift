import SwiftUI
import Combine
import SpriteKit

enum RPGTool: String, CaseIterable { case select, paint, erase }
@MainActor final class RPGSession: ObservableObject {
    private(set) var world = WorldState() { didSet { if !simulating { objectWillChange.send() } } }
    private var simulating = false
    private var guiding: Task<Void,Never>?
    private var followingRoute = false
    private var frameMetrics=RPGFrameMetrics()
    private var behaviorTargets:[WorldEntity]=[]
    private var lastBehaviorCheck:TimeInterval=0
    private var switchStarted:Double?
    private var switchMilliseconds=0.0,saveMilliseconds=0.0,chunkMilliseconds=0.0
    @Published private(set) var pendingStory=false
    @Published private(set) var recoveryChoices:[RPGRecoveryChoice]=[]
    /// Set when the world could not be loaded and nothing is recoverable,
    /// so the sandbox shows a create/retry screen instead of a blank scene.
    @Published private(set) var loadError: String?
    private var lastFrame: TimeInterval?
    private var lastHUD: TimeInterval = 0
    private var combatObstacles: Set<SurfacePoint> = []
    let combatHUD = RPGCombatHUDModel()
    @Published private(set) var notice = L10n.t("正在读取世界…", "Loading world…")
    @Published private(set) var active = false
    @Published private(set) var ready = false
    @Published private(set) var working = false { didSet { applyScenePause() } }
    @Published private(set) var loadedChunks = 0
    @Published private(set) var selected: SurfacePoint?
    @Published private(set) var selectedSide: SidePlacement?
    @Published private(set) var projectionEvidence = ""
    @Published private(set) var overlayVisible = false
    /// The selected cell in SpriteView coordinates, for the selection glass.
    @Published private(set) var selectionRect: CGRect?

    // MARK: Map editor (task E)
    /// The map editor is open: gameplay simulation (enemies, combat, story
    /// and block triggers) is paused while the world keeps drawing.
    @Published private(set) var mapEditorActive = false
    @Published var editorMode = RPGEditorMode(rawValue: UserDefaults.standard.string(forKey: "moonlight.mapEditor.mode") ?? "") ?? .free {
        didSet { UserDefaults.standard.set(editorMode.rawValue, forKey: "moonlight.mapEditor.mode"); if mapEditorActive { applyEditorMode() } }
    }
    @Published private(set) var saveState = RPGSaveState.saved
    /// Map cell at the centre of the free camera.
    @Published private(set) var editorFocus: SurfacePoint?
    private var gameModeBeforeEditor: RPGGameMode?
    /// Current bottom-toolbar tool.
    @Published private(set) var editorTool = RPGEditorTool.select
    /// What brush and fill write.
    @Published var brushPayload = RPGDraftPayload.block("stone") { didSet { if draft != nil && (editorTool == .brush || editorTool == .fill) { restartDraftPayload() } } }
    @Published var terrainBrush = RPGTerrain.road
    /// Unconfirmed edit and what it would do. Never part of the saved world.
    @Published private(set) var draft: RPGEditDraft?
    @Published private(set) var draftPlan: RPGDraftPlan?
    @Published private(set) var area: RPGArea?
    /// Cell shown in the floating property panel, and the kind a content tool asked for.
    @Published var panelPoint: SurfacePoint?
    @Published private(set) var panelKind: RPGMediaKind?
    /// Cell whose long-press menu is open.
    @Published var quickMenuCell: SurfacePoint?
    private var planTask: Task<Void, Never>?

    // MARK: Glass lab (experimental all-cell glass)
    @Published var glassMode = RPGGlassMode(rawValue: UserDefaults.standard.string(forKey: "moonlight.world.glassMode") ?? "") ?? .selected {
        didSet { UserDefaults.standard.set(glassMode.rawValue, forKey: "moonlight.world.glassMode"); updateGlass(force: true) }
    }
    @Published var glassNearest = max(16, UserDefaults.standard.integer(forKey: "moonlight.world.glassNearest")) {
        didSet { UserDefaults.standard.set(glassNearest, forKey: "moonlight.world.glassNearest"); updateGlass(force: true) }
    }
    @Published private(set) var glassRender = RPGGlassRender.selectedOnly
    @Published private(set) var glassReason: String?
    /// Where a cell corner lands in the SpriteView, the on-screen cell size
    /// and the view size; only republished once the camera settles.
    @Published private(set) var glassGrid: (corner: CGPoint, cell: CGFloat, bounds: CGSize, player: CGPoint)?
    @Published private(set) var glassSamples: [RPGGlassSample] = []
    @Published private(set) var glassSampleRemaining: Int?
    private var glassConditions = RPGGlassConditions()
    private var lastGlassCorner: CGPoint?
    private var lastGlassMove: TimeInterval = 0
    private var lastConditionCheck: TimeInterval = 0
    private var samplePending = false
    private var sampleStart: TimeInterval?
    private var sampleThermalStart = 0
    private var sampleLastTime: TimeInterval?
    private var sampleNativeSeconds = 0.0
    /// Exact hardware identifier, e.g. "iPhone17,1" (UIDevice only says "iPhone").
    private static let deviceModel: String = {
        var info = utsname(); uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }()
    private var sampleSeconds: Double {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glass-sample-short") { return 5 }
        #endif
        return 60
    }
    let sideScene = RPGSideScene()
    @Published var definition = "wood"
    @Published var tool = RPGTool.select { didSet { scene.tool = tool } }
    @Published private(set) var rangeStart: SurfacePoint?
    @Published private(set) var hasClipboard = false
    @Published private(set) var media: RPGMediaCoordinator?
    private var mediaNotice: AnyCancellable?
    let scene = RPGTopDownScene()
    private var chunks: [RPGChunk] = []
    private var cache: RPGChunkCache?
    private var loading: Task<Void, Never>?
    private var boot: Task<Void, Never>?
    private var edit: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    private var generation = UUID()
    private var displayedChunk: ChunkCoordinate?
    private var displayedRadius = 1
    private var displayedKey = ""
    private var terrainGenerator = RPGWorldGenerator(seed: 20261102)
    private let storage: RPGWorldDiskStore
    private var clipboard: RPGClipboard?
    private static var testReset = false
    #if DEBUG
    private static var testRecoveryPrepared=false
    private static var testFuturePrepared=false
    #endif
    var generator: RPGWorldGenerator { terrainGenerator }
    init() {
        var root = RPGWorldDiskStore.defaultURL()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rpg-ui-tests") {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RPG-UITests", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--rpg-reset-world") && !Self.testReset {
                try? FileManager.default.removeItem(at: root); Self.testReset = true
            }
        }
        #endif
        storage = RPGWorldDiskStore(root: root)
        #if DEBUG
        // Other UI tests always run with the shipping default.
        if ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests") && !ProcessInfo.processInfo.arguments.contains("--glass-lab-ui-tests") { glassMode = .selected }
        #endif
    }
    func recoverWorld(_ id:String) {
        guard !ready,!working,recoveryChoices.contains(where:{$0.id==id}) else{return}
        working=true;let epoch=generation,storage=storage
        boot=Task{[weak self] in
            do {
                let value=try await storage.load(id:id);try await storage.save(value)
                guard let self,!Task.isCancelled,self.generation==epoch else{return}
                self.boot=nil;self.assign(value);self.notice=L10n.t("已恢复选中的保留世界。", "Restored the selected saved world.")
            }catch{guard let self,self.generation==epoch else{return};self.boot=nil;self.working=false;self.notice=error.localizedDescription}
        }
    }
    func activate() {
        active = true; silenceMedia(); bindScenes(); applyScenePause()
        if ready { loadVisible(force: true) } else if boot == nil { loadWorld() }
    }
    func loadWorld() {
        let epoch = generation, storage = storage
        boot = Task { [weak self] in
            do {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--rpg-recovery-ui-tests"),!Self.testRecoveryPrepared {
                    Self.testRecoveryPrepared=true
                    let root=await storage.root
                    enum Interrupted:Error{case beforeIndex}
                    let interrupted=RPGWorldDiskStore(root:root,fault:{if $0 == .beforePointer{throw Interrupted.beforeIndex}})
                    for id in ["recover-target","recover-other"] {
                        var fixture=WorldState(seed:id == "recover-target" ? 42:43);fixture.id=id
                        let generator=RPGWorldGenerator(seed:fixture.seed);fixture.generated=true;fixture.player.surface=generator.anchor(.spawn);fixture.sideRegions=[generator.sideRegion]
                        fixture.entities=[.init(id:"recovered-building",definitionID:"wood",scope:.topDownOnly,surface:.init(x:30,z:30))]
                        let graph=RPGStoryGraph(id:"recovery.graph",title:"恢复回执",start:"end",nodes:[.init(id:"end",kind:.end,text:"奖励已经保存",actions:[.init(kind:.giveItem,key:"moon-shard",value:7)])])
                        try RPGStoryAuthoring.install(graph,bindings:[],world:&fixture);try RPGStoryRuntime.start(graphID:graph.id,world:&fixture);try RPGStoryRuntime.advance(world:&fixture,generator:generator)
                        do {try await interrupted.save(fixture)}catch Interrupted.beforeIndex{}
                    }
                }
                #endif
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--rpg-future-world-ui-tests"),!Self.testFuturePrepared {
                    // A world saved by a newer app version: it must not open,
                    // must not be overwritten, and must not leave a blank screen.
                    Self.testFuturePrepared=true
                    let root=await storage.root,folder=root.appendingPathComponent("Worlds/future-world",isDirectory:true)
                    var fixture=WorldState(seed:7);fixture.id="future-world"
                    if var object=try JSONSerialization.jsonObject(with:RPGWorldCodec.encode(fixture)) as? [String:Any] {
                        object["schemaVersion"]=WorldState.currentSchema+1
                        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                        try JSONSerialization.data(withJSONObject:object).write(to:folder.appendingPathComponent("world.json"))
                        try Data(#"{"id":"future-world"}"#.utf8).write(to:root.appendingPathComponent("active.json"))
                    }
                }
                #endif
                let value = try await storage.load() ?? WorldState()
                let recovered = await storage.recoveredFromBackup
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.boot = nil; self.assign(value)
                self.notice = recovered ? L10n.t("已从保留的有效存档恢复。", "Restored from the last valid save.") : L10n.t("世界已就绪。", "World ready.")
            } catch {
                guard let self, self.generation == epoch else { return }
                self.boot = nil; self.notice = error.localizedDescription; self.ready = false; self.loadError = error.localizedDescription
                if error as? RPGWorldError != .unsupportedVersion {
                    let choices=(try? await storage.recoverableWorlds()) ?? []
                    guard !Task.isCancelled,self.generation==epoch else{return};self.recoveryChoices=choices
                }
            }
        }
    }
    private func assign(_ value: WorldState) {
        recoveryChoices=[]; loadError=nil
        // A different world opens outside the editor, with a centred camera.
        mapEditorActive = false; gameModeBeforeEditor = nil; editorFocus = nil
        generation = UUID(); loading?.cancel(); saving?.cancel()
        scene.shutdown(); sideScene.shutdown()
        world = value; silenceMedia(); terrainGenerator = .init(seed: world.seed)
        if !world.generated { world.player.surface = generator.anchor(.spawn); world.sideRegions = [generator.sideRegion]; world.generated = true }
        cache = RPGChunkCache(seed: world.seed); chunks = []; displayedChunk = nil; displayedKey = ""; selected = nil; rangeStart = nil
        ready = true; working = false
        bindScenes(); applyScenePause(); scene.tool = tool
        loadVisible(force: true)
    }
    /// Name shown for the current world. Saves have no name field, so it is
    /// derived from what identifies the world.
    var worldTitle: String { (world.isCreativeCopy ? L10n.t("创作副本", "Creative Copy") : L10n.t("原世界", "Original World")) + " · Seed \(world.seed)" }
    var modeTitle: String { world.player.mode == .creative ? L10n.t("创造模式", "Creative") : L10n.t("冒险模式", "Adventure") }
    var perspectiveTitle: String { world.player.perspective == .side ? L10n.t("侧视切片", "Side Slice") : L10n.t("俯视地表", "Top-Down") }
    /// The active story and the step the player is on.
    var questSummary: String {
        let graph = world.story.activeGraph, progress = world.story.activeProgress
        if progress?.ended == true { return graph.title + L10n.t(" · 已完成", " · Done") }
        guard let node = graph.nodes.first(where: { $0.id == (progress?.current ?? graph.start) }) else { return graph.title }
        let text = node.text.isEmpty ? node.kind.rawValue : node.text
        return graph.title + " · " + (text.count > 28 ? String(text.prefix(28)) + "…" : text)
    }
    /// Every world kept on disk, for the control center's world switcher.
    func listWorlds() async -> [RPGRecoveryChoice] { (try? await storage.recoverableWorlds()) ?? [] }
    /// Saves the current world, then opens another one kept on disk.
    func switchWorld(_ id: String) {
        guard !working, id != world.id || !ready else { return }
        replaceWorld { storage in try await storage.load(id: id) }
    }
    /// Saves the current world (if any), then starts a new one with a fresh
    /// seed. Existing worlds, readable or not, stay on disk untouched.
    func createWorld() {
        guard !working else { return }
        replaceWorld { _ in WorldState(seed: UInt64.random(in: 1...999_999_999)) }
    }
    private func replaceWorld(_ next: @escaping @Sendable (RPGWorldDiskStore) async throws -> WorldState) {
        working = true; silenceMedia()
        let current = ready ? world : nil, epoch = generation, storage = storage
        boot = Task { [weak self] in
            do {
                if let current { try await storage.save(current) }
                let value = try await next(storage); try await storage.save(value)
                guard let self, !Task.isCancelled, self.generation == epoch else { return }
                self.boot = nil; self.assign(value); self.notice = L10n.t("已打开：", "Opened: ") + self.worldTitle
            } catch {
                guard let self, self.generation == epoch else { return }
                self.boot = nil; self.working = false; self.notice = error.localizedDescription
            }
        }
    }
    func pause() { guiding?.cancel(); active = false; silenceMedia(); media?.pause(); applyScenePause(); loading?.cancel(); save() }
    func shutdown() {
        guiding?.cancel()
        silenceMedia(); save(); active = false; media?.stop(); media=nil; mediaNotice=nil; generation = UUID(); loading?.cancel(); boot?.cancel(); edit?.cancel(); boot = nil
        scene.shutdown(); sideScene.shutdown(); let old = cache; Task { await old?.clear() }; cache = nil; chunks = []; displayedChunk = nil; displayedKey = ""
    }
    func move(dx: Int, dz: Int) {
        if mapEditorActive && editorMode == .free { return }
        if !followingRoute { guiding?.cancel() }
        guard active, ready, !working, world.player.health > 0, abs(dx) <= 1, abs(dz) <= 1 else { return }
        if world.player.perspective == .side {
            if dx != 0 { world.player.facing = .init(dx: dx, dz: 0) }
            if dz > 0 { sideScene.jump() }; if dx != 0 { sideScene.step(dx) }; return
        }
        if dx != 0 || dz != 0 { world.player.facing = .init(dx: dx, dz: dz) }
        let old = world.player.surface, next = SurfacePoint(x: old.x + dx, z: old.z + dz)
        guard RPGWorldTerrain.passable(next, world: world, generator: generator) else { notice = L10n.t("前方无法通行。", "The way ahead is blocked."); return }
        if dx != 0 && dz != 0 {
            guard RPGWorldTerrain.passable(.init(x: old.x + dx, z: old.z), world: world, generator: generator),
                  RPGWorldTerrain.passable(.init(x: old.x, z: old.z + dz), world: world, generator: generator) else { return }
        }
        guard RPGWorldEditing.entity(at: next, world: world, generator: generator)?.physics.topDownSolid != true else { notice = L10n.t("前方有方块。", "A block is in the way."); return }
        world.player.surface = next; world.revision += 1; scene.movePlayer(next); loadVisible()
    }
    func returnToSpawn() {
        guard ready, !working, !world.player.inCombat else { return }
        if world.player.perspective == .side {
            world.player.side = generator.sideRegion.landing; world.player.surface = generator.anchor(.temple); world.revision += 1
            sideScene.respawn(generator.sideRegion.landing)
        } else { world.player.surface = generator.anchor(.spawn); world.revision += 1; scene.movePlayer(world.player.surface); loadVisible(force: true) }
    }
    func setMode(_ mode: RPGGameMode) { guard ready, !working, !world.player.inCombat else { return }; world.player.mode = mode; world.revision += 1; save() }
    func chooseSite() {
        guard ready else { return }
        let p = world.player.surface
        for radius in 1...8 { for dz in -radius...radius { for dx in -radius...radius where max(abs(dx),abs(dz)) == radius {
            let point = SurfacePoint(x: p.x+dx, z: p.z+dz)
            if world.player.mode == .adventure && abs(dx)+abs(dz)>4 { continue }
            if point.valid && RPGWorldTerrain.passable(point, world: world, generator: generator) && (world.isCreativeCopy || !generator.protected(point)) && RPGWorldEditing.entity(at: point, world: world, generator: generator) == nil {
                selected = point; scene.select(point); notice = L10n.t("已选附近可建造空地。", "Selected a nearby buildable cell."); return
            }
        } } }
        notice = L10n.t("身边是保护区或障碍，请先向外探索，或使用创作副本。", "Protected area or obstacle nearby. Explore outward or use a creative copy.")
    }
    private func bindScenes() {
        // Native glass replaces the yellow outline where it is available.
        scene.selectionOutlineVisible = !RPGSelectionGlass.usesNativeGlass
        sideScene.selectionOutlineVisible = !RPGSelectionGlass.usesNativeGlass
        scene.onSelectCell = { [weak self] point in
            guard let self else { return }
            self.selected = point; self.scene.select(point); self.syncSelectedMedia()
            if self.mapEditorActive { self.panelKind = nil; self.panelPoint = point } else { self.tapBehavior() }
        }
        scene.onStroke = { [weak self] points in self?.stroke(points) }
        scene.onCameraMoved = { [weak self] center, zoom in self?.cameraMoved(center: center, zoom: zoom) }
        scene.onEditorStroke = { [weak self] a, b in self?.editorStroke(a, b) }
        scene.onEditorRectangle = { [weak self] a, b, final in self?.editorRectangle(a, b, final: final) }
        scene.onEditorTap = { [weak self] point in self?.editorTap(point) }
        scene.onLongPressCell = { [weak self] point in
            guard let self else { return }; self.selected = point; self.scene.select(point); self.quickMenuCell = point; self.syncSelectedMedia()
        }
        scene.onFrame = { [weak self] time in self?.frame(time) }
        sideScene.onFrame = { [weak self] time in self?.frame(time) }
        sideScene.onSelectCell = { [weak self] point in
            guard let self else { return }; self.selectedSide = point; self.sideScene.select(point)
            if let region = self.world.sideRegions.first(where: { $0.id == point.regionID }) { self.selected = .init(x: region.origin.x + point.horizontal, z: region.origin.z) }; self.tapBehavior()
        }
        sideScene.onEnemyPosition = { [weak self] id, point in
            guard let self, self.world.player.perspective == .side, let index = self.world.combat.enemies.firstIndex(where:{$0.id == id}) else { return }
            self.simulating = true; defer { self.simulating = false }
            self.world.combat.enemies[index].side = point
            if self.world.combat.enemies[index].scope == .shared, let region = self.world.sideRegions.first(where:{$0.id == point.regionID}) {
                self.world.combat.enemies[index].surface = .init(x:region.origin.x+point.horizontal,z:region.origin.z)
            }
            self.world.revision += 1
        }
        sideScene.onPosition = { [weak self] point, _ in
            guard let self, self.ready, self.active, self.world.player.perspective == .side, self.world.player.side != point else { return }
            self.world.player.side = point
            if let region = self.world.sideRegions.first(where: { $0.id == point.regionID }) { self.world.player.surface = .init(x: region.origin.x + point.horizontal, z: region.origin.z) }
            self.world.revision += 1
        }
    }
    private func applyScenePause() {
        lastFrame = nil;frameMetrics.pause()
        scene.isPaused = !active || working || overlayVisible || world.player.perspective != .topDown
        sideScene.isPaused = !active || working || overlayVisible || world.player.perspective != .side
    }
    func setOverlay(_ value: Bool) {
        overlayVisible = value; if value { silenceMedia(); media?.pause() }; applyScenePause(); syncMedia()
        if !value && samplePending { beginGlassSample() }
    }
    func travelToTemple() {
        guard ready, !working, !world.player.inCombat, world.player.perspective == .topDown else { return }
        guard world.player.mode == .creative else { notice = L10n.t("冒险模式请沿通路探索；创造模式可定位到双界入口。", "In adventure mode follow the paths; creative mode can jump to the portal."); return }
        world.player.surface = generator.anchor(.temple); world.revision += 1; loadVisible(force: true)
    }
    func chooseMappedSite() {
        guard ready, world.player.perspective == .topDown else { return }
        let region = generator.sideRegion
        for offset in 3...15 {
            let point = SurfacePoint(x: generator.anchor(.temple).x + offset, z: region.origin.z)
            if RPGWorldTerrain.passable(point, world: world, generator: generator) && (world.isCreativeCopy || !generator.protected(point)) && RPGWorldEditing.entity(at: point, world: world, generator: generator) == nil {
                selected = point; scene.select(point); notice = L10n.t("已选共享映射行上的空格。", "Selected an empty cell on the shared row."); return
            }
        }
        notice = L10n.t("映射行暂无空地。", "No empty cell on the shared row.")
    }
    func toggleProjection() {
        guard ready, !working else { return }
        if world.player.perspective == .side && !sideScene.isOnGround { notice = L10n.t("请先落地并回到入口。", "Land first and return to the portal."); return }
        do {
            switchStarted=ProcessInfo.processInfo.systemUptime
            try RPGProjectionRules.switchPerspective(world: &world, generator: generator)
            selected = nil; selectedSide = nil
            if world.player.perspective == .side {
                if world.player.facing.dx == 0 { world.player.facing = .init() }
                RPGCombatRules.seedEnemies(world:&world,generator:generator,coordinates:[])
            }
            applyScenePause(); refreshCombat()
            if world.player.perspective == .side { sideScene.show(world: world, resetPlayer: true); updateProjectionEvidence() }
            else { loadVisible(force: true) }
            notice = world.player.perspective == .side ? L10n.t("已进入独立侧视切片；靛色平台为侧视专属。", "Entered the side slice; indigo platforms exist only here.") : L10n.t("已返回俯视地表。", "Back to the top-down surface.")
            save()
        } catch { switchStarted=nil;notice = error.localizedDescription }
    }
    private func updateProjectionEvidence() {
        let ids = world.player.perspective == .side ? sideScene.sharedIDs : scene.sharedIDs
        projectionEvidence = world.player.perspective.rawValue + ":" + ids.sorted().joined(separator: ",")
        syncMedia()
    }
    func attachMediaStore(_ store:MediaStore) {
        if media == nil {
            media=RPGMediaCoordinator(store:store)
            mediaNotice=media?.$notice.sink{[weak self] value in if !value.isEmpty { self?.notice=value } }
        }
        syncMedia()
    }
    private func syncMedia() {
        let top=world.player.perspective == .topDown
        media?.install(world:world,targets:top ? scene.mediaTargets : sideScene.mediaTargets,scene:top ? scene : sideScene,active:active && ready && !overlayVisible)
    }
    private func silenceMedia() {
        if world.mediaBindings.contains(where:{!$0.muted}) {
            for index in world.mediaBindings.indices { world.mediaBindings[index].muted=true };world.revision+=1
        }
    }
    var selectedEntity:WorldEntity? {
        if world.player.perspective == .side,let point=selectedSide { return RPGProjectionRules.sideEntities(world:world,generator:generator).first{RPGProjectionRules.occupies($0,point)} }
        guard let selected else{return nil};return RPGWorldEditing.entity(at:selected,world:world,generator:generator)
    }
    /// Requests a glass sample; it starts once the world is uncovered, so
    /// paused time under a sheet is never measured.
    func startGlassSample() { samplePending = true; if !overlayVisible { beginGlassSample() } }
    private func beginGlassSample() {
        samplePending = false; frameMetrics.reset(); sampleStart = nil; sampleLastTime = nil; sampleNativeSeconds = 0
        sampleThermalStart = ProcessInfo.processInfo.thermalState.rawValue
        glassSampleRemaining = Int(sampleSeconds)
    }
    private func glassFrame(_ time: TimeInterval) {
        if time - lastConditionCheck >= 1 {
            lastConditionCheck = time
            var conditions = glassConditions
            if #available(iOS 26.0, *) { conditions.nativeAvailable = true } else { conditions.nativeAvailable = false }
            conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            conditions.thermal = ProcessInfo.processInfo.thermalState.rawValue
            conditions.reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
            if conditions != glassConditions { glassConditions = conditions; updateGlass(force: true) }
        }
        if glassMode.isNative { trackGlassCamera(time) }
        guard glassSampleRemaining != nil else { return }
        guard active, ready, !overlayVisible else { return }
        let start = sampleStart ?? time; sampleStart = start
        if let last = sampleLastTime, time > last, time - last < 1 {
            switch glassRender { case .nativeMerged, .nativeNearest: sampleNativeSeconds += time - last; default: break }
        }
        sampleLastTime = time
        let remaining = max(0, Int((sampleSeconds - (time - start)).rounded(.up)))
        if remaining != glassSampleRemaining { glassSampleRemaining = remaining }
        guard time - start >= sampleSeconds else { return }
        glassSamples.append(RPGGlassSample(id: glassSamples.count + 1, mode: glassMode, nearest: glassNearest, effective: glassRender.label,
                                           seconds: time - start, averageFramesPerSecond: frameMetrics.averageFramesPerSecond, measuredSeconds: frameMetrics.sampledSeconds,
                                           nativeSeconds: sampleNativeSeconds, framesPerSecond: frameMetrics.framesPerSecond, p95Milliseconds: frameMetrics.p95Milliseconds,
                                           hitches: frameMetrics.hitches, frames: frameMetrics.totalFrames, memoryMB: RPGMemoryMetrics.footprintMB,
                                           thermalStart: sampleThermalStart, thermalEnd: ProcessInfo.processInfo.thermalState.rawValue,
                                           device: Self.deviceModel + " iOS " + UIDevice.current.systemVersion))
        glassSampleRemaining = nil; sampleStart = nil
        notice = L10n.t("玻璃采样完成：", "Glass sampling done: ") + glassSamples.last!.line
    }
    /// Native glass stays aligned only while the camera is still. While it
    /// moves the texture (A) stands in; the grid is republished on settle.
    private func trackGlassCamera(_ time: TimeInterval) {
        let current: SKScene = world.player.perspective == .side ? sideScene : scene
        guard let view = current.view else { return }
        let corner = current.convertPoint(toView: .zero), unit = current.convertPoint(toView: CGPoint(x: 24, y: 0))
        let moved = lastGlassCorner.map { abs($0.x - corner.x) > 0.5 || abs($0.y - corner.y) > 0.5 } ?? true
        lastGlassCorner = corner
        if moved {
            lastGlassMove = time
            if !glassConditions.cameraMoving { glassConditions.cameraMoving = true; updateGlass(force: true) }
        } else if glassConditions.cameraMoving && time - lastGlassMove > 0.25 {
            let player = world.player.perspective == .side ? sideScene.playerViewPoint() : scene.playerViewPoint()
            glassGrid = (corner, abs(unit.x - corner.x), view.bounds.size, player ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            glassConditions.cameraMoving = false; updateGlass(force: true)
        }
    }
    private func updateGlass(force: Bool = false) {
        let result = RPGGlassPolicy.resolve(glassMode, nearest: glassNearest, glassConditions)
        if result.render != glassRender { glassRender = result.render }
        if result.reason != glassReason { glassReason = result.reason }
        let texture = result.render == .texture
        scene.glassTextureVisible = texture; sideScene.glassTextureVisible = texture
    }
    /// Publishes the selection's on-screen rectangle only when it moves, so
    /// SwiftUI is not invalidated every frame while the camera is still.
    private func updateSelectionRect() {
        let rect = world.player.perspective == .side ? sideScene.selectionRectInView() : scene.selectionRectInView()
        switch (rect, selectionRect) {
        case (nil, nil): return
        case let (new?, old?) where abs(new.minX-old.minX) < 0.5 && abs(new.minY-old.minY) < 0.5 && abs(new.width-old.width) < 0.5: return
        default: selectionRect = rect
        }
    }
    /// Content of the selected block, e.g. "number:42", "empty" or "none".
    var selectedCellSummary: String {
        guard let entity = selectedEntity else { return "none" }
        guard let id = entity.mediaBindingID, let binding = world.mediaBindings.first(where: { $0.id == id }) else { return "empty" }
        return binding.kind.rawValue + ":" + (binding.style?.value.isEmpty == false ? binding.style!.value : binding.mediaID) + (binding.paused == true ? ":paused" : "")
    }
    /// Every block's content in the world, sorted, e.g. "number:42,text:门".
    /// Lets tests check saved content without depending on a selection.
    var cellContentSummaries: String {
        world.entities.compactMap { entity -> String? in
            guard let id = entity.mediaBindingID, let binding = world.mediaBindings.first(where: { $0.id == id }) else { return nil }
            return binding.kind.rawValue + ":" + (binding.style?.value.isEmpty == false ? binding.style!.value : binding.mediaID)
        }.sorted().joined(separator: ",")
    }
    /// Replaces the selected block's content with `draft` as one undoable edit.
    func applyCellContent(_ draft: MediaBinding, to entityID: String) {
        var value = draft
        if value.kind != .video { value.muted = true }
        if !value.muted && world.videoBudget == 0 { notice = L10n.t("动态预览已关闭，请先增加播放预算。", "Live preview is off. Raise the playback budget first."); return }
        let content = value
        perform { world, generator in
            // Only one cell may play sound; unmuting this one mutes the rest.
            if !content.muted { for index in world.mediaBindings.indices { world.mediaBindings[index].muted = true } }
            try RPGMediaBindings.assign(content, to: .entity(entityID), world: &world, generator: generator)
        }
    }
    /// Opens the map editor in the remembered sub-mode. Top-down only: the
    /// free camera and painting work on the surface map.
    func enterMapEditor() {
        guard ready, !working, !mapEditorActive else { return }
        guard world.player.perspective == .topDown else { notice = L10n.t("请先返回俯视，再进入地图编辑。", "Return to top-down view before editing the map."); return }
        gameModeBeforeEditor = world.player.mode
        mapEditorActive = true
        applyEditorMode()
        notice = L10n.t("地图编辑 · ", "Map Editor · ") + editorMode.title + L10n.t("：敌人、战斗与剧情已暂停。", ": enemies, combat and story are paused.")
    }
    /// Leaves the editor: restores the game mode it was opened in, puts the
    /// camera back on the player and resumes gameplay.
    func exitMapEditor() {
        guard mapEditorActive else { return }
        mapEditorActive = false
        if let previous = gameModeBeforeEditor, previous != world.player.mode { world.player.mode = previous; world.revision += 1; save() }
        gameModeBeforeEditor = nil; editorFocus = nil
        discardDraft(); area = nil; panelPoint = nil; quickMenuCell = nil; scene.showArea(nil)
        scene.editorTouch = .legacy; scene.editorLongPressEnabled = false; scene.tool = tool
        scene.cameraFollowsPlayer = true; scene.freePan = false; scene.cameraGesturesEnabled = false
        scene.setCamera(center: scene.cameraCenter, zoom: 1); scene.recenterOnPlayer()
        loadVisible(force: true); notice = L10n.t("已返回沙盒。", "Back to the sandbox.")
    }
    /// Free edit: whole map, free camera, no joystick. Character build:
    /// camera follows the player, edits limited to cells near the player.
    private func applyEditorMode() {
        let mode = editorMode.gameMode
        if world.player.mode != mode { world.player.mode = mode; world.revision += 1; save() }
        let free = editorMode == .free
        scene.cameraFollowsPlayer = !free; scene.cameraGesturesEnabled = true; scene.editorLongPressEnabled = true
        applyEditorTouch()
        // A draft made in free edit is kept; character build shows how much
        // of it is out of range and will not commit it.
        refreshPlan()
        if free { editorFocus = RPGCameraRules.cell(at: scene.cameraCenter) ?? world.player.surface }
        else { scene.recenterOnPlayer(); editorFocus = nil }
        loadVisible(force: true)
    }
    private func cameraMoved(center: CGPoint, zoom: CGFloat) {
        guard mapEditorActive else { return }
        if editorMode == .free { editorFocus = RPGCameraRules.cell(at: center) ?? editorFocus }
        loadVisible()
    }
    /// Chooses a tool. Callers handle an unconfirmed draft first.
    func selectTool(_ tool: RPGEditorTool) {
        editorTool = tool
        // The area outline belongs to the multi tool only.
        scene.showArea(tool == .multi ? area.map { ($0.a, $0.b) } : nil)
        applyEditorTouch()
    }
    private func applyEditorTouch() {
        guard mapEditorActive else { return }
        scene.tool = .select
        let tool = editorTool
        scene.editorTouch = tool == .select ? (editorMode == .free ? .panSelect : .legacy)
            : tool.contentKind != nil ? .tapOnly : tool.draws ? .stroke : .rectangle
    }
    private func payload(for tool: RPGEditorTool) -> RPGDraftPayload? {
        switch tool {
        case .erase: .erase
        case .terrain: .terrain(terrainBrush)
        case .brush, .fill: brushPayload
        default: nil
        }
    }
    private func editorStroke(_ a: SurfacePoint, _ b: SurfacePoint) {
        guard mapEditorActive, let payload = payload(for: editorTool) else { return }
        if draft?.payload != payload { draft = RPGEditDraft(payload: payload) }
        if a == b { draft?.add([a]) } else { draft?.addStroke(from: a, to: b) }
        showDraft()
    }
    private func editorRectangle(_ a: SurfacePoint, _ b: SurfacePoint, final: Bool) {
        guard mapEditorActive else { return }
        if editorTool == .multi { area = RPGArea(a: a, b: b); scene.showArea((a, b)); if final { notice = L10n.t("已选 \(area!.count) 格：可擦除、填充、复制或替换。", "\(area!.count) cells selected: erase, fill, copy or replace.") }; return }
        guard let payload = payload(for: editorTool) else { return }
        var next = RPGEditDraft(payload: payload); next.setRectangle(a, b); draft = next
        showDraft()
    }
    private func editorTap(_ point: SurfacePoint) {
        selected = point; panelKind = editorTool.contentKind; panelPoint = point; syncSelectedMedia()
    }
    private func restartDraftPayload() {
        guard let cells = draft?.cells, let payload = payload(for: editorTool) else { return }
        var next = RPGEditDraft(payload: payload); next.add(cells); draft = next; showDraft()
    }
    /// Shows the draft cells at once and works out the plan just after, so
    /// a long stroke never waits on per-cell checks.
    private func showDraft() {
        guard let draft else { scene.showPreview([], tint: .clear); return }
        let cells: [SurfacePoint]
        if case .paste(let clipboard) = draft.payload, let origin = draft.cells.first { cells = RPGEditDraft.footprint(clipboard, at: origin).filter(\.valid) }
        else { cells = draft.cells }
        scene.showPreview(cells, tint: Self.tint(draft.payload))
        refreshPlan()
    }
    private func refreshPlan() {
        planTask?.cancel()
        guard let draft else { draftPlan = nil; return }
        let world = world, generator = generator
        planTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let plan = await Task.detached(priority: .userInitiated) { RPGDraftCommit.plan(draft, world: world, generator: generator) }.value
            guard !Task.isCancelled, let self, self.draft == draft else { return }
            self.draftPlan = plan
        }
    }
    static func tint(_ payload: RPGDraftPayload) -> UIColor {
        switch payload {
        case .erase: .systemRed
        case .terrain(let terrain): terrain == .water ? .systemBlue : terrain == .cliff ? .darkGray : terrain == .sand ? .systemYellow : terrain == .road ? .brown : .systemGreen
        case .block: .systemOrange
        case .content: .systemCyan
        case .paste: .systemPurple
        case .replace: .systemPink
        }
    }
    /// Commits the draft as one transaction; it stays on screen if refused.
    func confirmDraft() {
        guard let value = draft else { return }
        perform({ world, generator in try RPGDraftCommit.commit(value, world: &world, generator: generator) }) { [weak self] in
            guard let self else { return }
            self.notice = L10n.t("已提交：", "Committed: ") + value.payload.title + L10n.t(" · \(self.draftPlan?.cells.count ?? value.count) 格", " · \(self.draftPlan?.cells.count ?? value.count) cells")
            self.discardDraft()
        }
    }
    func discardDraft() { planTask?.cancel(); draft = nil; draftPlan = nil; scene.showPreview([], tint: .clear) }

    // Multi-select actions: each becomes a draft to confirm.
    func eraseArea() { draftOverArea(.erase) }
    func fillArea() { draftOverArea(brushPayload) }
    func replaceInArea() {
        guard let from = selectedEntity?.definitionID else { notice = L10n.t("先轻点选区内一个方块，作为要替换的材质。", "Tap a block inside the area first as the material to replace."); return }
        guard case .block(let to) = brushPayload else { notice = L10n.t("画笔需选择一种方块材质作为替换目标。", "Pick a block material for the brush as the replacement."); return }
        draftOverArea(.replace(from: from, to: to))
    }
    func copyArea() {
        guard let area else { return }
        do { clipboard = try RPGWorldEditing.copy(from: area.a, to: area.b, world: world, generator: generator); hasClipboard = !(clipboard?.cells.isEmpty ?? true); notice = L10n.t("已复制 \(clipboard?.cells.count ?? 0) 个方块。", "Copied \(clipboard?.cells.count ?? 0) blocks.") }
        catch { notice = error.localizedDescription }
    }
    /// Paste preview with the copied area's corner at `point`.
    func pastePreview(at point: SurfacePoint) {
        guard let clipboard, !clipboard.cells.isEmpty else { notice = L10n.t("没有可粘贴的内容。", "Nothing to paste."); return }
        var next = RPGEditDraft(payload: .paste(clipboard)); next.add([point]); draft = next; showDraft()
    }
    func clearArea() { area = nil; scene.showArea(nil) }
    private func draftOverArea(_ payload: RPGDraftPayload) {
        guard let area else { return }
        var next = RPGEditDraft(payload: payload); next.setRectangle(area.a, area.b); draft = next; showDraft()
    }
    /// Long-press menu actions.
    func eraseCell(_ point: SurfacePoint) { var next = RPGEditDraft(payload: .erase); next.add([point]); draft = next; showDraft() }
    func copyCell(_ point: SurfacePoint) { area = RPGArea(a: point, b: point); copyArea(); area = nil }
    func openPanel(_ point: SurfacePoint, kind: RPGMediaKind? = nil) { selected = point; scene.select(point); panelKind = kind; panelPoint = point; syncSelectedMedia() }
    /// Content for a cell without a block: one display cell plus content,
    /// as one undoable edit (A+).
    func applyContent(_ template: MediaBinding, at point: SurfacePoint) {
        var value = template; if value.kind != .video { value.muted = true }
        var single = RPGEditDraft(payload: .content(value)); single.add([point])
        let draft = single
        perform { world, generator in try RPGDraftCommit.commit(draft, world: &world, generator: generator) }
    }
    func entity(at point: SurfacePoint) -> WorldEntity? { RPGWorldEditing.entity(at: point, world: world, generator: generator) }
    func terrain(at point: SurfacePoint) -> RPGTerrain? { RPGWorldTerrain.tile(at: point, world: world, generator: generator) }
    /// The selected cell's media plays first.
    private func syncSelectedMedia() { media?.selectedOwnerID = selectedEntity?.id }

    /// The cell the editor toolbar shows: the selection, else the camera centre.
    var editorCoordinate: SurfacePoint? { selected ?? editorFocus ?? world.player.surface }
    func mediaBinding(for owner:RPGMediaOwner)->MediaBinding? {
        guard let id=RPGMediaBindings.bindingID(for:owner,in:world) else{return nil};return world.mediaBindings.first{$0.id==id}
    }
    func assignMedia(_ entry:MediaEntry,to owner:RPGMediaOwner) {
        guard entry.kind != .embed else{notice=L10n.t("网页素材不能作为世界纹理。", "Web items can't be used as world textures.");return}
        let id=entry.id,kind=RPGMediaCatalogKind.kind(for:entry)
        perform{world,generator in try RPGMediaBindings.assign(mediaID:id,kind:kind,to:owner,world:&world,generator:generator)}
    }
    func clearMedia(_ owner:RPGMediaOwner) { perform{world,_ in try RPGMediaBindings.clear(owner,world:&world)} }
    func changeBinding(_ id:String,scale:Double?=nil,anchorX:Double?=nil,anchorY:Double?=nil,loop:Bool?=nil,muted:Bool?=nil,cropWidth:Double?=nil) {
        guard ready,!working,let index=world.mediaBindings.firstIndex(where:{$0.id==id}) else{return}
        var next=world
        if let scale{next.mediaBindings[index].scale=scale}
        if let anchorX{next.mediaBindings[index].anchorX=anchorX}
        if let anchorY{next.mediaBindings[index].anchorY=anchorY}
        if let loop{next.mediaBindings[index].loop=loop}
        if let cropWidth{next.mediaBindings[index].cropWidth=cropWidth;next.mediaBindings[index].cropX=(1-cropWidth)/2}
        if let muted {
            if !muted && world.videoBudget==0 {notice=L10n.t("动态预览已关闭，请先增加播放预算。", "Live preview is off. Raise the playback budget first.");return}
            if !muted {for i in next.mediaBindings.indices{next.mediaBindings[i].muted=true}}
            next.mediaBindings[index].muted=muted
        }
        do {next.revision+=1;try next.validate();world=next;renderCurrent();save()}catch{notice=error.localizedDescription}
    }
    func setVideoBudget(_ value:Int){guard (0...2).contains(value) else{return};world.videoBudget=value;world.revision+=1;syncMedia();save()}
    private func renderCurrent() {
        behaviorTargets = world.player.perspective == .side ? RPGProjectionRules.sideEntities(world:world,generator:generator) : chunks.flatMap{RPGWorldEditing.entities(in:$0,world:world)}
        combatObstacles = Set(chunks.flatMap { RPGWorldEditing.entities(in:$0,world:world) }.filter { $0.physics.topDownSolid }.compactMap(\.surface))
        if world.player.perspective == .side { sideScene.show(world: world); sideScene.select(selectedSide) }
        else { scene.show(chunks: chunks, world: world); scene.select(selected) }
        updateProjectionEvidence(); refreshCombat()
    }
    private func perform(_ action: @escaping @Sendable (inout WorldState, RPGWorldGenerator) throws -> Void, onSuccess: (() -> Void)? = nil) {
        guard ready, active, !working, world.player.health > 0 else { return }
        working = true; let snapshot = world, generator = generator, epoch = generation
        edit = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<WorldState, Error> in
                do { var value = snapshot; try action(&value, generator); return .success(value) } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self, self.generation == epoch else { return }
            self.working = false
            switch result {
            case .success(let value):
                guard self.world.revision == snapshot.revision else { self.notice = RPGEditError.stale.localizedDescription; return }
                self.world = value
                if value.behaviors.firedIDs.count > snapshot.behaviors.firedIDs.count { self.pendingStory=true }
                RPGStoryRuntime.recordEvents(world:&self.world); self.renderCurrent()
                self.notice = L10n.t("操作已提交。", "Done."); self.save(); onSuccess?()
            case .failure(let error): self.notice = error.localizedDescription
            }
        }
    }
    func placeSelected() {
        if world.player.perspective == .side, let selectedSide {
            let definition = definition
            perform { world, generator in try RPGProjectionRules.placeSide(selectedSide, definitionID: definition, world: &world, generator: generator) }; return
        }
        guard let selected else { notice = L10n.t("先轻点地表或选择附近空地。", "Tap the ground or pick a nearby empty cell first."); return }
        let definition = definition
        perform { world, generator in try RPGWorldEditing.place([.init(point: selected, definitionID: definition)], world: &world, generator: generator) }
    }
    func hitSelected(force: Bool = false) {
        let surface=selected,side=selectedSide,target=selectedEntity
        guard surface != nil || side != nil else{return}
        perform { world,generator in
            if world.player.perspective == .side,let side {try RPGProjectionRules.hitSide(side,world:&world,generator:generator,force:force)}
            else if let surface {try RPGWorldEditing.hit(surface,world:&world,generator:generator,force:force)}
            if let target {try RPGBehaviorRules.fire(.attack,targetID:target.id,entities:[target],world:&world,generator:generator)}
        }
    }
    func undo() { perform { world, _ in try RPGWorldEditing.undo(world: &world) } }
    func redo() { perform { world, _ in try RPGWorldEditing.redo(world: &world) } }
    func markRange() { rangeStart = selected; notice = selected == nil ? L10n.t("先选择范围起点。", "Pick the range start first.") : L10n.t("已标记起点；再轻点终点。", "Start marked; now tap the end.") }
    func fillRange() {
        guard let a = rangeStart, let b = selected else { return }; let definition = definition
        perform { world, generator in let points = try RPGWorldEditing.rectangle(a,b); try RPGWorldEditing.place(points.map { .init(point: $0, definitionID: definition) }, world: &world, generator: generator) }
    }
    func copyRange() {
        guard let a = rangeStart ?? selected, let b = selected else { return }
        do { clipboard = try RPGWorldEditing.copy(from: a, to: b, world: world, generator: generator); hasClipboard = !(clipboard?.cells.isEmpty ?? true); notice = L10n.t("已复制 \(clipboard?.cells.count ?? 0) 个方块。", "Copied \(clipboard?.cells.count ?? 0) blocks.") } catch { notice = error.localizedDescription }
    }
    func paste() { guard let clipboard, let selected else { return }; perform { world, generator in try RPGWorldEditing.paste(clipboard, at: selected, world: &world, generator: generator) } }
    private func stroke(_ points: [SurfacePoint]) {
        if tool == .paint {
            let definition = definition; perform { world, generator in try RPGWorldEditing.place(points.map { .init(point: $0, definitionID: definition) }, world: &world, generator: generator) }
        } else if tool == .erase, let point = points.last { selected = point; hitSelected(force: true) }
    }
    func saveBeforeExit() async -> Bool {
        guard ready else { return true }
        guard !working else { notice = L10n.t("请等待当前操作完成。", "Please wait for the current action to finish."); return false }
        silenceMedia(); saving?.cancel(); working = true
        do { try await storage.save(world); active = false; working = false; return true }
        catch { working = false; notice = error.localizedDescription; return false }
    }
    func save() {
        guard ready else { return }
        saveState = .saving
        saving?.cancel(); let snapshot = world, epoch = generation, storage = storage
        saving = Task { [weak self] in
            do {
                let started=ProcessInfo.processInfo.systemUptime
                try await storage.save(snapshot)
                let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.saveMilliseconds=elapsed
                self.notice = L10n.t("世界已保存 · 修订 \(snapshot.revision)", "World saved · revision \(snapshot.revision)"); self.saveState = .saved
            } catch {
                guard !Task.isCancelled, let self, self.generation == epoch else { return }; self.notice = error.localizedDescription
                self.saveState = .failed(error.localizedDescription)
            }
        }
    }
    func creativeCopy() {
        guard ready, !working else { return }
        saving?.cancel(); working = true; let snapshot = world, storage = storage, epoch = generation
        Task { [weak self] in
            do {
                try await storage.save(snapshot)
                var copy = snapshot; copy.parentWorldID = snapshot.parentWorldID ?? snapshot.id; copy.id = UUID().uuidString
                copy.isCreativeCopy = true; copy.player.mode = .creative; copy.player.surface = RPGWorldGenerator(seed: copy.seed).anchor(.creation)
                copy.undo = []; copy.redo = []; copy.events = []; copy.revision = 0
                try await storage.save(copy)
                guard let self, self.generation == epoch else { return }; self.assign(copy); self.notice = L10n.t("已进入独立创作副本，原世界保留。", "Entered a creative copy; the original world is kept.")
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }
    func returnToOriginal() {
        guard let id = world.parentWorldID, ready, !working else { return }
        saving?.cancel(); working = true; let snapshot = world, storage = storage, epoch = generation
        Task { [weak self] in
            do {
                try await storage.save(snapshot); let original = try await storage.load(id: id); try await storage.save(original)
                guard let self, self.generation == epoch else { return }; self.assign(original); self.notice = L10n.t("已返回原世界。", "Back to the original world.")
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }
    private func frame(_ time: TimeInterval) {
        media?.frame(time)
        updateSelectionRect()
        glassFrame(time)
        guard active, ready, !working, !overlayVisible else { lastFrame = nil; return }
        frameMetrics.sample(time)
        if let started=switchStarted {switchMilliseconds=(ProcessInfo.processInfo.systemUptime-started)*1000;switchStarted=nil}
        if mapEditorActive { lastFrame = nil; return }
        guard let previous = lastFrame else { lastFrame = time; return }
        guard time-previous >= 1.0/30 else { return }
        lastFrame = time
        let obstacles = combatObstacles, generator = generator, terrain = world.terrainOverrides ?? [:]
        let wasCombat = world.player.inCombat, oldHealth = world.player.health
        simulating = true
        RPGCombatRules.advance(world:&world,generator:generator,delta:min(0.1,time-previous),passable:{ RPGWorldTerrain.passable($0, overrides: terrain, generator: generator) && !obstacles.contains($0) })
        RPGStoryRuntime.recordEvents(world:&world)
        var fired=false
        if time-lastBehaviorCheck>=0.25,!world.behaviors.bindings.isEmpty {
            lastBehaviorCheck=time
            for trigger in [RPGBehaviorTrigger.proximity,.timer,.storyEvent] {
                if (try? RPGBehaviorRules.fire(trigger,entities:behaviorTargets,world:&world,generator:generator)) == true {fired=true;break}
            }
        }
        simulating = false
        if fired {pendingStory=true;save()}
        if world.player.perspective == .topDown { scene.showCombat(world) } else { sideScene.showCombat(world) }
        if time-lastHUD > 0.1 || oldHealth != world.player.health { combatHUD.update(world); lastHUD = time }
        if wasCombat != world.player.inCombat || oldHealth > 0 && world.player.health == 0 {
            objectWillChange.send(); notice = world.player.health == 0 ? L10n.t("生命耗尽，请在安全入口复苏。", "Out of health. Revive at the safe portal.") : world.player.inCombat ? L10n.t("战斗开始，暂时不能切换视角。", "Combat started; view switching is paused."):L10n.t("战斗结束，掉落已记录。", "Combat over; loot recorded."); save()
        }
    }
    private func refreshCombat() {
        combatHUD.update(world)
        if world.player.perspective == .topDown { scene.showCombat(world) } else { sideScene.showCombat(world) }
    }
    func combatAction(_ action: RPGCombatAction) {
        guard ready, active, !working, !overlayVisible else { return }
        let obstacles = combatObstacles, generator = generator, terrain = world.terrainOverrides ?? [:]
        do {
            try RPGCombatRules.action(action,world:&world,generator:generator,passable:{ RPGWorldTerrain.passable($0, overrides: terrain, generator: generator) && !obstacles.contains($0) })
            if action == .roll {
                if world.player.perspective == .side { sideScene.dash(world.player.facing.dx) }
                else { scene.movePlayer(world.player.surface); loadVisible() }
            } else if world.player.perspective == .side { sideScene.combatEffect(action == .skill) }
            else { scene.combatEffect(action == .skill) }
            RPGStoryRuntime.recordEvents(world:&world); refreshCombat(); save()
        } catch { notice = error.localizedDescription }
    }
    func trainingEncounter() {
        guard ready, !working else { return }
        RPGCombatRules.trainingEncounter(world:&world,generator:generator); refreshCombat(); save()
    }
    func equip(_ equipment: RPGEquipment) {
        guard ready, !working, !world.player.inCombat else { notice = L10n.t("请在战斗结束后装备。", "Equip after combat ends."); return }
        if equipment == .none { world.player.weapon = .none; world.player.armor = .none }
        else {
            let owned = world.inventory[equipment.rawValue,default:0] > 0
            if !owned {
                let cost = equipment == .moonBlade ? 4:6
                let resource = equipment == .moonBlade ? "wood":"stone"
                guard world.inventory[resource,default:0] >= cost else { notice = L10n.t("材料不足。", "Not enough materials."); return }
                world.inventory[resource,default:0] -= cost; world.inventory[equipment.rawValue] = 1
            }
            if equipment == .moonBlade { world.player.weapon = equipment } else { world.player.armor = equipment }
        }
        world.revision += 1; refreshCombat(); save()
    }
    func revive() {
        guard ready, !working, world.player.health == 0 else { return }
        world.player.health = 100; world.player.stamina = 100; world.player.inCombat = false
        for i in world.combat.enemies.indices { world.combat.enemies[i].aggro = false }
        world.combat.invulnerableRemaining = 2
        returnToSpawn(); refreshCombat(); save()
    }
    func acknowledgeStory(){pendingStory=false}
    private func tapBehavior() {
        guard let target=selectedEntity,world.behaviors.bindings.contains(where:{$0.entityID==target.id && $0.trigger == .tap && !world.behaviors.firedIDs.contains($0.id)}) else{return}
        perform{world,generator in try RPGBehaviorRules.fire(.tap,targetID:target.id,entities:[target],world:&world,generator:generator)}
    }
    func bindBehavior(_ binding:RPGBehaviorBinding,target:WorldEntity){perform{world,generator in try RPGBehaviorRules.bind(binding,target:target,world:&world,generator:generator)}}
    func clearBehaviors(_ entityID:String){perform{world,_ in
        let ids=Set(world.behaviors.bindings.filter{$0.entityID==entityID}.map(\.id))
        world.behaviors.bindings.removeAll{ids.contains($0.id)};world.behaviors.firedIDs.removeAll{ids.contains($0)};world.revision+=1;try world.validate()
    }}
    func setReducedMotion(_ value:Bool){scene.reducedMotion=value;sideScene.reducedMotion=value}
    func diagnosticReport()->String {
        let memory=RPGMemoryMetrics.footprintMB.map{String(format:"%.1f MB",$0)} ?? "不可读取"
        #if targetEnvironment(simulator)
        let device="iOS Simulator（非真机性能验证）"
        #else
        let device=UIDevice.current.model+" / "+UIDevice.current.systemVersion
        #endif
        return "设备：\(device)\n视角：\(world.player.perspective.rawValue)\n采样：\(frameMetrics.count)/600，FPS \(String(format:"%.1f",frameMetrics.framesPerSecond))，p95 \(String(format:"%.2f",frameMetrics.p95Milliseconds)) ms\n累计 >50ms 帧：\(frameMetrics.hitches)/\(frameMetrics.totalFrames)\n内存 footprint：\(memory)\n区块：\(loadedChunks)/64\n解码器：\(media?.decoderCount ?? 0)，运行：\(media?.advancing ?? 0)，全局池：\(CardMediaCoordinator.ownedPlayers)\n媒体缓存：\(media?.cacheBytes ?? 0) bytes\n最近区块加载：\(String(format:"%.2f",chunkMilliseconds)) ms\n最近保存：\(String(format:"%.2f",saveMilliseconds)) ms\n最近视角切换首帧：\(String(format:"%.2f",switchMilliseconds)) ms\n敌人：\(world.combat.enemies.count)/128，事件：\(world.events.count)/256，行为：\(world.behaviors.bindings.count)/256\n世界：\(world.id) rev \(world.revision) schema \(world.schemaVersion)\n真实 iPhone Instruments 与持续性能：待验证"
    }
    func installStory(_ graph:RPGStoryGraph,bindings:[MediaBinding])->Bool {
        guard ready,!working else{return false}
        do {try RPGStoryAuthoring.install(graph,bindings:bindings,world:&world);save();return true}
        catch{notice=error.localizedDescription;return false}
    }
    func recordStoryMedia(_ nodeID:String,seconds:Double) {
        guard ready,seconds.isFinite,(0...10_000_000).contains(seconds) else{return}
        let key=world.story.activeGraphID+":"+nodeID
        guard world.story.mediaPositions[key] != nil || world.story.mediaPositions.count<4096 else{return}
        world.story.mediaPositions[key]=seconds;world.revision+=1;save()
    }
    func prepareStory() {
        guard ready, world.story.activeProgress == nil else { return }
        beginStory(world.story.activeGraphID)
    }
    func beginStory(_ id: String) {
        guard ready, !working else { return }
        do {
            let new = !world.story.progress.contains { $0.id == id }
            try RPGStoryRuntime.start(graphID:id,world:&world)
            if new { try RPGStoryRuntime.advance(world:&world,generator:generator) }
            renderCurrent(); save()
        } catch { notice = error.localizedDescription }
    }
    func advanceStory(choice: String? = nil) {
        perform { world, generator in try RPGStoryRuntime.advance(choiceID:choice,world:&world,generator:generator) }
    }
    func guideTo(_ anchor: RPGAnchorID) {
        guard ready, !working, !world.player.inCombat, world.player.perspective == .topDown else { notice = L10n.t("请在俯视且非战斗时导航。", "Navigate in top-down view, outside combat."); return }
        guiding?.cancel()
        let generator = generator, origin = world.player.surface, target = generator.anchor(anchor), epoch = generation
        let entities=world.entities,removed=world.removedGeneratedIDs,terrain=world.terrainOverrides ?? [:]
        guiding = Task { [weak self] in
            let planner=Task.detached(priority:.userInitiated){
                RPGWorldRoute.path(from:origin,to:target,generator:generator,entities:entities,removedIDs:removed,terrainOverrides:terrain,cancelled:{Task.isCancelled})
            }
            let path=await withTaskCancellationHandler(operation:{await planner.value},onCancel:{planner.cancel()})
            guard let self, !Task.isCancelled, self.generation == epoch, self.world.player.surface == origin else { return }
            // Let the tool sheet dismiss before starting the walk.
            try? await Task.sleep(nanoseconds:250_000_000)
            for point in path {
                guard !Task.isCancelled, self.active, !self.overlayVisible, !self.working, !self.world.player.inCombat, self.world.player.health > 0 else { return }
                let old = self.world.player.surface
                guard abs(point.x-old.x)+abs(point.z-old.z)==1 else { return }
                self.followingRoute = true; self.move(dx:point.x-old.x,dz:point.z-old.z); self.followingRoute = false
                guard self.world.player.surface == point else { self.notice = L10n.t("导航被障碍挡住，请手动绕行。", "Navigation blocked; walk around manually."); return }
                try? await Task.sleep(nanoseconds:90_000_000)
            }
            self.notice = self.world.player.surface == target ? L10n.t("已沿通路抵达", "Arrived at ")+anchor.title : L10n.t("暂无可通行路线。", "No passable route."); self.save()
        }
    }
    func validateRoundTrip() {
        do { let decoded = try RPGWorldCodec.decode(RPGWorldCodec.encode(world)); notice = decoded == world ? L10n.t("世界数据往返校验通过。", "World data round-trip check passed.") : L10n.t("世界数据校验失败。", "World data check failed.") }
        catch { notice = error.localizedDescription }
    }
    private func loadVisible(force: Bool = false) {
        guard active, ready else { return }
        if world.player.perspective == .side { sideScene.show(world: world); updateProjectionEvidence(); return }
        // Free edit loads around the camera; otherwise around the player.
        let focus = mapEditorActive && editorMode == .free ? (editorFocus ?? world.player.surface) : world.player.surface
        let radius = RPGCameraRules.chunkRadius(zoom: scene.cameraZoom)
        // Free edit covers the whole visible screen (wide landscape views
        // showed unloaded ground at the edges with a fixed ring).
        var wanted = generator.priorityChunks(around: focus, radius: radius)
        if mapEditorActive && editorMode == .free {
            let viewport = RPGCameraRules.chunks(center: scene.cameraCenter, viewSize: scene.size, zoom: scene.cameraZoom)
            if !viewport.isEmpty { wanted = Array(viewport.prefix(36)) }
        }
        let key = wanted.map(\.id).sorted().map(String.init).joined(separator: ",")
        guard force || displayedKey != key else { return }
        loading?.cancel(); if cache == nil { cache = RPGChunkCache(seed: world.seed) }
        let epoch = generation, cache = cache
        loading = Task { [weak self] in
            let started=ProcessInfo.processInfo.systemUptime
            let chunks = await cache?.load(wanted) ?? []
            guard !Task.isCancelled, let self, self.generation == epoch, self.active else { return }
            self.chunkMilliseconds=(ProcessInfo.processInfo.systemUptime-started)*1000
            self.chunks = chunks; self.loadedChunks = chunks.count; self.displayedChunk = focus.chunk; self.displayedRadius = radius; self.displayedKey = key
            RPGCombatRules.seedEnemies(world:&self.world,generator:self.generator,coordinates:chunks.map(\.coordinate))
            self.renderCurrent()
            self.notice = L10n.t("世界已就绪 · \(self.loadedChunks)/64 区块在附近。", "World ready · \(self.loadedChunks)/64 chunks nearby.")
        }
    }
}

@MainActor final class RPGCombatHUDModel: ObservableObject {
    @Published private(set) var text = "生命 100 · 耐力 100"
    @Published private(set) var dead = false
    func update(_ world: WorldState) {
        let health = world.player.health, stamina = world.player.stamina, shards = world.inventory["moon-shard",default:0], skill = Int(ceil(world.combat.skillRemaining))
        let value = L10n.t("生命 \(health) · 耐力 \(stamina) · 月晶 \(shards) · 技能 \(skill)s", "HP \(health) · Stamina \(stamina) · Shards \(shards) · Skill \(skill)s")
        if text != value { text = value }; if dead != (world.player.health == 0) { dead = world.player.health == 0 }
    }
}
