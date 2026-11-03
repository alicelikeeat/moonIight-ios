import SwiftUI
import Combine

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
    private var lastFrame: TimeInterval?
    private var lastHUD: TimeInterval = 0
    private var combatObstacles: Set<SurfacePoint> = []
    let combatHUD = RPGCombatHUDModel()
    @Published private(set) var notice = "正在读取世界…"
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
    private var terrainGenerator = RPGWorldGenerator(seed: 20261102)
    private let storage: RPGWorldDiskStore
    private var clipboard: RPGClipboard?
    private static var testReset = false
    #if DEBUG
    private static var testRecoveryPrepared=false
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
    }
    func recoverWorld(_ id:String) {
        guard !ready,!working,recoveryChoices.contains(where:{$0.id==id}) else{return}
        working=true;let epoch=generation,storage=storage
        boot=Task{[weak self] in
            do {
                let value=try await storage.load(id:id);try await storage.save(value)
                guard let self,!Task.isCancelled,self.generation==epoch else{return}
                self.boot=nil;self.assign(value);self.notice="已恢复选中的保留世界。"
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
                let value = try await storage.load() ?? WorldState()
                let recovered = await storage.recoveredFromBackup
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.boot = nil; self.assign(value)
                self.notice = recovered ? "已从保留的有效存档恢复。" : "世界已就绪。"
            } catch {
                guard let self, self.generation == epoch else { return }
                self.boot = nil; self.notice = error.localizedDescription; self.ready = false
                if error as? RPGWorldError != .unsupportedVersion {
                    let choices=(try? await storage.recoverableWorlds()) ?? []
                    guard !Task.isCancelled,self.generation==epoch else{return};self.recoveryChoices=choices
                }
            }
        }
    }
    private func assign(_ value: WorldState) {
        recoveryChoices=[]
        generation = UUID(); loading?.cancel(); saving?.cancel()
        scene.shutdown(); sideScene.shutdown()
        world = value; silenceMedia(); terrainGenerator = .init(seed: world.seed)
        if !world.generated { world.player.surface = generator.anchor(.spawn); world.sideRegions = [generator.sideRegion]; world.generated = true }
        cache = RPGChunkCache(seed: world.seed); chunks = []; displayedChunk = nil; selected = nil; rangeStart = nil
        ready = true; working = false
        bindScenes(); applyScenePause(); scene.tool = tool
        loadVisible(force: true)
    }
    func pause() { guiding?.cancel(); active = false; silenceMedia(); media?.pause(); applyScenePause(); loading?.cancel(); save() }
    func shutdown() {
        guiding?.cancel()
        silenceMedia(); save(); active = false; media?.stop(); media=nil; mediaNotice=nil; generation = UUID(); loading?.cancel(); boot?.cancel(); edit?.cancel(); boot = nil
        scene.shutdown(); sideScene.shutdown(); let old = cache; Task { await old?.clear() }; cache = nil; chunks = []; displayedChunk = nil
    }
    func move(dx: Int, dz: Int) {
        if !followingRoute { guiding?.cancel() }
        guard active, ready, !working, world.player.health > 0, abs(dx) <= 1, abs(dz) <= 1 else { return }
        if world.player.perspective == .side {
            if dx != 0 { world.player.facing = .init(dx: dx, dz: 0) }
            if dz > 0 { sideScene.jump() }; if dx != 0 { sideScene.step(dx) }; return
        }
        if dx != 0 || dz != 0 { world.player.facing = .init(dx: dx, dz: dz) }
        let old = world.player.surface, next = SurfacePoint(x: old.x + dx, z: old.z + dz)
        guard generator.tile(at: next)?.passable == true else { notice = "前方无法通行。"; return }
        if dx != 0 && dz != 0 {
            guard generator.tile(at: .init(x: old.x + dx, z: old.z))?.passable == true,
                  generator.tile(at: .init(x: old.x, z: old.z + dz))?.passable == true else { return }
        }
        guard RPGWorldEditing.entity(at: next, world: world, generator: generator)?.physics.topDownSolid != true else { notice = "前方有方块。"; return }
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
            if point.valid && generator.tile(at: point)?.passable == true && (world.isCreativeCopy || !generator.protected(point)) && RPGWorldEditing.entity(at: point, world: world, generator: generator) == nil {
                selected = point; scene.select(point); notice = "已选附近可建造空地。"; return
            }
        } } }
        notice = "身边是保护区或障碍，请先向外探索，或使用创作副本。"
    }
    private func bindScenes() {
        // Native glass replaces the yellow outline where it is available.
        scene.selectionOutlineVisible = !RPGSelectionGlass.usesNativeGlass
        sideScene.selectionOutlineVisible = !RPGSelectionGlass.usesNativeGlass
        scene.onSelectCell = { [weak self] point in self?.selected = point; self?.scene.select(point);self?.tapBehavior() }
        scene.onStroke = { [weak self] points in self?.stroke(points) }
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
    func setOverlay(_ value: Bool) { overlayVisible = value; if value { silenceMedia(); media?.pause() }; applyScenePause(); syncMedia() }
    func travelToTemple() {
        guard ready, !working, !world.player.inCombat, world.player.perspective == .topDown else { return }
        guard world.player.mode == .creative else { notice = "冒险模式请沿通路探索；创造模式可定位到双界入口。"; return }
        world.player.surface = generator.anchor(.temple); world.revision += 1; loadVisible(force: true)
    }
    func chooseMappedSite() {
        guard ready, world.player.perspective == .topDown else { return }
        let region = generator.sideRegion
        for offset in 3...15 {
            let point = SurfacePoint(x: generator.anchor(.temple).x + offset, z: region.origin.z)
            if generator.tile(at: point)?.passable == true && (world.isCreativeCopy || !generator.protected(point)) && RPGWorldEditing.entity(at: point, world: world, generator: generator) == nil {
                selected = point; scene.select(point); notice = "已选共享映射行上的空格。"; return
            }
        }
        notice = "映射行暂无空地。"
    }
    func toggleProjection() {
        guard ready, !working else { return }
        if world.player.perspective == .side && !sideScene.isOnGround { notice = "请先落地并回到入口。"; return }
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
            notice = world.player.perspective == .side ? "已进入独立侧视切片；靛色平台为侧视专属。" : "已返回俯视地表。"
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
    /// Replaces the selected block's content with `draft` as one undoable edit.
    func applyCellContent(_ draft: MediaBinding, to entityID: String) {
        var value = draft
        if value.kind != .video { value.muted = true }
        if !value.muted && world.videoBudget == 0 { notice = "动态预览已关闭，请先增加播放预算。"; return }
        let content = value
        perform { world, generator in
            // Only one cell may play sound; unmuting this one mutes the rest.
            if !content.muted { for index in world.mediaBindings.indices { world.mediaBindings[index].muted = true } }
            try RPGMediaBindings.assign(content, to: .entity(entityID), world: &world, generator: generator)
        }
    }
    func mediaBinding(for owner:RPGMediaOwner)->MediaBinding? {
        guard let id=RPGMediaBindings.bindingID(for:owner,in:world) else{return nil};return world.mediaBindings.first{$0.id==id}
    }
    func assignMedia(_ entry:MediaEntry,to owner:RPGMediaOwner) {
        guard entry.kind != .embed else{notice="网页素材不能作为世界纹理。";return}
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
            if !muted && world.videoBudget==0 {notice="动态预览已关闭，请先增加播放预算。";return}
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
    private func perform(_ action: @escaping @Sendable (inout WorldState, RPGWorldGenerator) throws -> Void) {
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
                self.notice = "操作已提交。"; self.save()
            case .failure(let error): self.notice = error.localizedDescription
            }
        }
    }
    func placeSelected() {
        if world.player.perspective == .side, let selectedSide {
            let definition = definition
            perform { world, generator in try RPGProjectionRules.placeSide(selectedSide, definitionID: definition, world: &world, generator: generator) }; return
        }
        guard let selected else { notice = "先轻点地表或选择附近空地。"; return }
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
    func markRange() { rangeStart = selected; notice = selected == nil ? "先选择范围起点。" : "已标记起点；再轻点终点。" }
    func fillRange() {
        guard let a = rangeStart, let b = selected else { return }; let definition = definition
        perform { world, generator in let points = try RPGWorldEditing.rectangle(a,b); try RPGWorldEditing.place(points.map { .init(point: $0, definitionID: definition) }, world: &world, generator: generator) }
    }
    func copyRange() {
        guard let a = rangeStart ?? selected, let b = selected else { return }
        do { clipboard = try RPGWorldEditing.copy(from: a, to: b, world: world, generator: generator); hasClipboard = !(clipboard?.cells.isEmpty ?? true); notice = "已复制 \(clipboard?.cells.count ?? 0) 个方块。" } catch { notice = error.localizedDescription }
    }
    func paste() { guard let clipboard, let selected else { return }; perform { world, generator in try RPGWorldEditing.paste(clipboard, at: selected, world: &world, generator: generator) } }
    private func stroke(_ points: [SurfacePoint]) {
        if tool == .paint {
            let definition = definition; perform { world, generator in try RPGWorldEditing.place(points.map { .init(point: $0, definitionID: definition) }, world: &world, generator: generator) }
        } else if tool == .erase, let point = points.last { selected = point; hitSelected(force: true) }
    }
    func saveBeforeExit() async -> Bool {
        guard ready else { return true }
        guard !working else { notice = "请等待当前操作完成。"; return false }
        silenceMedia(); saving?.cancel(); working = true
        do { try await storage.save(world); active = false; working = false; return true }
        catch { working = false; notice = error.localizedDescription; return false }
    }
    func save() {
        guard ready else { return }
        saving?.cancel(); let snapshot = world, epoch = generation, storage = storage
        saving = Task { [weak self] in
            do {
                let started=ProcessInfo.processInfo.systemUptime
                try await storage.save(snapshot)
                let elapsed=(ProcessInfo.processInfo.systemUptime-started)*1000
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                self.saveMilliseconds=elapsed
                self.notice = "世界已保存 · 修订 \(snapshot.revision)"
            } catch {
                guard !Task.isCancelled, let self, self.generation == epoch else { return }; self.notice = error.localizedDescription
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
                guard let self, self.generation == epoch else { return }; self.assign(copy); self.notice = "已进入独立创作副本，原世界保留。"
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }
    func returnToOriginal() {
        guard let id = world.parentWorldID, ready, !working else { return }
        saving?.cancel(); working = true; let snapshot = world, storage = storage, epoch = generation
        Task { [weak self] in
            do {
                try await storage.save(snapshot); let original = try await storage.load(id: id); try await storage.save(original)
                guard let self, self.generation == epoch else { return }; self.assign(original); self.notice = "已返回原世界。"
            } catch { guard let self, self.generation == epoch else { return }; self.working = false; self.notice = error.localizedDescription }
        }
    }
    private func frame(_ time: TimeInterval) {
        media?.frame(time)
        updateSelectionRect()
        guard active, ready, !working, !overlayVisible else { lastFrame = nil; return }
        frameMetrics.sample(time)
        if let started=switchStarted {switchMilliseconds=(ProcessInfo.processInfo.systemUptime-started)*1000;switchStarted=nil}
        guard let previous = lastFrame else { lastFrame = time; return }
        guard time-previous >= 1.0/30 else { return }
        lastFrame = time
        let obstacles = combatObstacles, generator = generator
        let wasCombat = world.player.inCombat, oldHealth = world.player.health
        simulating = true
        RPGCombatRules.advance(world:&world,generator:generator,delta:min(0.1,time-previous),passable:{ generator.tile(at:$0)?.passable == true && !obstacles.contains($0) })
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
            objectWillChange.send(); notice = world.player.health == 0 ? "生命耗尽，请在安全入口复苏。" : world.player.inCombat ? "战斗开始，暂时不能切换视角。":"战斗结束，掉落已记录。"; save()
        }
    }
    private func refreshCombat() {
        combatHUD.update(world)
        if world.player.perspective == .topDown { scene.showCombat(world) } else { sideScene.showCombat(world) }
    }
    func combatAction(_ action: RPGCombatAction) {
        guard ready, active, !working, !overlayVisible else { return }
        let obstacles = combatObstacles, generator = generator
        do {
            try RPGCombatRules.action(action,world:&world,generator:generator,passable:{ generator.tile(at:$0)?.passable == true && !obstacles.contains($0) })
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
        guard ready, !working, !world.player.inCombat else { notice = "请在战斗结束后装备。"; return }
        if equipment == .none { world.player.weapon = .none; world.player.armor = .none }
        else {
            let owned = world.inventory[equipment.rawValue,default:0] > 0
            if !owned {
                let cost = equipment == .moonBlade ? 4:6
                let resource = equipment == .moonBlade ? "wood":"stone"
                guard world.inventory[resource,default:0] >= cost else { notice = "材料不足。"; return }
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
        guard ready, !working, !world.player.inCombat, world.player.perspective == .topDown else { notice = "请在俯视且非战斗时导航。"; return }
        guiding?.cancel()
        let generator = generator, origin = world.player.surface, target = generator.anchor(anchor), epoch = generation
        let entities=world.entities,removed=world.removedGeneratedIDs
        guiding = Task { [weak self] in
            let planner=Task.detached(priority:.userInitiated){
                RPGWorldRoute.path(from:origin,to:target,generator:generator,entities:entities,removedIDs:removed,cancelled:{Task.isCancelled})
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
                guard self.world.player.surface == point else { self.notice = "导航被障碍挡住，请手动绕行。"; return }
                try? await Task.sleep(nanoseconds:90_000_000)
            }
            self.notice = self.world.player.surface == target ? "已沿通路抵达"+anchor.title : "暂无可通行路线。"; self.save()
        }
    }
    func validateRoundTrip() {
        do { let decoded = try RPGWorldCodec.decode(RPGWorldCodec.encode(world)); notice = decoded == world ? "世界数据往返校验通过。" : "世界数据校验失败。" }
        catch { notice = error.localizedDescription }
    }
    private func loadVisible(force: Bool = false) {
        guard active, ready else { return }
        if world.player.perspective == .side { sideScene.show(world: world); updateProjectionEvidence(); return }
        guard force || displayedChunk != world.player.surface.chunk else { return }
        loading?.cancel(); if cache == nil { cache = RPGChunkCache(seed: world.seed) }
        let wanted = generator.priorityChunks(around: world.player.surface), epoch = generation, cache = cache
        loading = Task { [weak self] in
            let started=ProcessInfo.processInfo.systemUptime
            let chunks = await cache?.load(wanted) ?? []
            guard !Task.isCancelled, let self, self.generation == epoch, self.active else { return }
            self.chunkMilliseconds=(ProcessInfo.processInfo.systemUptime-started)*1000
            self.chunks = chunks; self.loadedChunks = chunks.count; self.displayedChunk = self.world.player.surface.chunk
            RPGCombatRules.seedEnemies(world:&self.world,generator:self.generator,coordinates:chunks.map(\.coordinate))
            self.renderCurrent()
            self.notice = "世界已就绪 · \(self.loadedChunks)/64 区块在附近。"
        }
    }
}

@MainActor final class RPGCombatHUDModel: ObservableObject {
    @Published private(set) var text = "生命 100 · 耐力 100"
    @Published private(set) var dead = false
    func update(_ world: WorldState) {
        let value = "生命 \(world.player.health) · 耐力 \(world.player.stamina) · 月晶 \(world.inventory["moon-shard",default:0]) · 技能 \(Int(ceil(world.combat.skillRemaining)))s"
        if text != value { text = value }; if dead != (world.player.health == 0) { dead = world.player.health == 0 }
    }
}
