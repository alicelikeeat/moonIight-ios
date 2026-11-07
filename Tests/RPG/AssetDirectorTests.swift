import Foundation

// v1.87 AI Asset Director — domain checks (run with the RPG domain tests).

private let assetNow = Date(timeIntervalSince1970: 1_800_000_000)

private func record(_ id: String, _ type: AssetMediaType, _ signals: AssetSignals, origin: AssetSourceType = .files, storage: AssetStorageReference? = nil,
                    license: String? = nil, calibration: AssetCalibration = .starter) -> AssetIntelligenceRecord {
    var r = AssetIntelligenceRecord(assetID: id, contentHash: "sha-" + id, mediaType: type, storage: storage ?? .library("lib-" + id), title: id,
                                    createdAt: assetNow, updatedAt: assetNow, provenance: .initial(origin: origin, license: license, author: nil, proof: nil))
    let c = AssetClassifier.classify(signals, calibration: calibration)
    AssetClassifier.apply(c, to: &r, signals: signals,
                          analysis: AssetAnalysisInfo(analyzerID: AssetClassifier.id, analyzerVersion: AssetClassifier.version, configurationVersion: 1, analyzedAt: assetNow, cloud: false, milliseconds: 1),
                          now: assetNow)
    return r
}

private func raster(_ w: Int, _ h: Int, _ f: (Int, Int) -> [UInt8]) -> RasterImage {
    var px: [UInt8] = []
    for y in 0..<h { for x in 0..<w { px += f(x, y) } }
    return RasterImage(width: w, height: h, rgba: px)
}

func assetDirectorTests() {
    // MARK: Pixels
    let checker = raster(32, 32) { x, y in ((x / 4 + y / 4) % 2 == 0) ? [150, 90, 60, 255] : [120, 70, 50, 255] }
    let checkerStats = AssetPixelStats.measure(checker)!
    check(checkerStats.tileability > 0.7 && checkerStats.transparentShare == 0, "a repeating brick pattern tiles past the classifier threshold (\(checkerStats.tileability))")
    let sprite = raster(32, 32) { x, y in abs(x - 16) < 6 && abs(y - 16) < 12 ? [220, 180, 150, 255] : [0, 0, 0, 0] }
    let spriteStats = AssetPixelStats.measure(sprite)!
    check(spriteStats.transparentShare > 0.6 && spriteStats.tileability == 0, "a cut-out is mostly transparent and never a tile")
    let gradient = raster(32, 32) { x, y in [UInt8(x * 8), UInt8(y * 8), 128, 255] }
    check(AssetPixelStats.measure(gradient)!.tileability < 0.5, "a gradient does not tile")
    check(AssetPixelStats.measure(RasterImage(width: 1, height: 1)) == nil, "too small to measure")

    // MARK: Classification per media type
    var portrait = AssetSignals(mediaType: .image)
    portrait.pixel = spriteStats
    portrait.labels = [AssetTag(name: "people", score: 0.8, source: .vision), AssetTag(name: "cartoon", score: 0.5, source: .vision)]
    portrait.technical.pixelWidth = 512; portrait.technical.pixelHeight = 1024
    let portraitRecord = record("portrait", .image, portrait)
    check(portraitRecord.primaryCategory == .character && portraitRecord.recommendedUses.contains(.sprite), "a transparent character picture is a character sprite")
    check(portraitRecord.confidence?.kind == .modelScore, "uncalibrated scores are labelled as model scores, not accuracy")

    var brick = AssetSignals(mediaType: .image)
    brick.pixel = checkerStats; brick.technical.pixelWidth = 1024; brick.technical.pixelHeight = 1024
    brick.labels = [AssetTag(name: "brick", score: 0.6, source: .vision), AssetTag(name: "wall", score: 0.4, source: .vision)]
    let brickRecord = record("brick", .image, brick)
    check(brickRecord.primaryCategory == .material && brickRecord.recommendedUses.contains(.texture), "a tiling brick texture is a material (\(brickRecord.candidates))")
    check(brickRecord.categories.count >= 1, "classification gives at least one category")

    var castle = AssetSignals(mediaType: .image)
    castle.pixel = AssetPixelStats.measure(gradient)
    castle.labels = [AssetTag(name: "castle", score: 0.85, source: .vision), AssetTag(name: "sky", score: 0.5, source: .vision), AssetTag(name: "structure", score: 0.4, source: .vision)]
    castle.dominantColors = ["E8EEF5", "8FB8E0"]
    let castleRecord = record("castle", .image, castle)
    check(castleRecord.primaryCategory == .building && castleRecord.secondaryCategories.contains(.nature), "a castle photo is a building with nature as a second category (\(castleRecord.categories))")
    check(castleRecord.sceneContext.contains(.castle) && castleRecord.sceneContext.contains(.sky), "scene context comes from the labels")
    check(castleRecord.recommendedUses.contains(.styleReference) && !castleRecord.recommendedUses.contains(.texture), "a photo that does not tile is a reference, not a texture")

    var unknown = AssetSignals(mediaType: .image)
    unknown.pixel = AssetPixelStats.measure(gradient)
    let unknownRecord = record("blur", .image, unknown)
    check(unknownRecord.primaryCategory == nil && unknownRecord.status == .needsReview, "without evidence the category waits for the user")

    var rigged = AssetSignals(mediaType: .model)
    rigged.technical.hasSkeleton = true; rigged.technical.triangleCount = 8000; rigged.humanoidShape = true; rigged.technical.bounds = [0.5, 1.8, 0.3]
    let riggedRecord = record("hero", .model, rigged, storage: .generatedModel("m1"))
    check(riggedRecord.primaryCategory == .character && riggedRecord.recommendedUses.contains(.characterModel), "a rigged human-shaped model is a character")
    var boxy = AssetSignals(mediaType: .model)
    boxy.technical.hasSkeleton = false; boxy.technical.triangleCount = 2400; boxy.humanoidShape = false; boxy.technical.bounds = [4, 3, 4]
    let houseRecord = record("house", .model, boxy, storage: .generatedModel("m2"))
    check(houseRecord.categories.contains(.building) && houseRecord.primaryCategory != .character, "a wide model without a skeleton is not called a character (\(houseRecord.candidates))")
    var oddRig = AssetSignals(mediaType: .model)
    oddRig.technical.hasSkeleton = true; oddRig.humanoidShape = false; oddRig.technical.triangleCount = 600
    let oddRecord = record("crane", .model, oddRig, storage: .generatedModel("m3"))
    check(oddRecord.primaryCategory != .character || oddRecord.decision != .automatic, "a skeleton alone does not make a confident character")
    var bareHuman = AssetSignals(mediaType: .model)
    bareHuman.technical.hasSkeleton = false; bareHuman.humanoidShape = true; bareHuman.technical.triangleCount = 5000; bareHuman.technical.bounds = [0.5, 1.7, 0.3]
    let bareRecord = record("statue", .model, bareHuman, storage: .generatedModel("m4"))

    var gif = AssetSignals(mediaType: .gif)
    gif.pixel = spriteStats; gif.motionEnergy = 0.08; gif.loopSimilarity = 0.95
    gif.labels = [AssetTag(name: "cartoon", score: 0.4, source: .vision)]
    check(record("walk", .gif, gif).primaryCategory == .character, "a transparent looping cartoon GIF is a character sprite animation")
    var magic = AssetSignals(mediaType: .gif)
    magic.pixel = AssetPixelStats(transparentShare: 0, colourVariety: 0.2, meanSaturation: 0.6, meanBrightness: 0.8, grayscaleShare: 0.1, edgeEnergy: 0.1, hardEdgeShare: 0.5, tileability: 0.2)
    magic.motionEnergy = 0.3; magic.labels = [AssetTag(name: "fireworks", score: 0.5, source: .vision)]
    check(record("spell", .gif, magic).primaryCategory == .effect, "a bright, fast GIF with sparks is an effect")

    var fountainVideo = AssetSignals(mediaType: .video)
    fountainVideo.labels = [AssetTag(name: "fountain", score: 0.7, source: .vision), AssetTag(name: "water", score: 0.6, source: .vision)]
    fountainVideo.motionEnergy = 0.06; fountainVideo.technical.duration = 12
    fountainVideo.technical.pixelWidth = 1280; fountainVideo.technical.pixelHeight = 720
    fountainVideo.motionSegments = [AssetMotionSegment(start: 2, end: 4, label: "person", score: 0.6)]
    let fountainRecord = record("fountain", .video, fountainVideo)
    check(fountainRecord.categories.contains(.nature) && fountainRecord.sceneContext.contains(.water) && fountainRecord.recommendedUses.contains(.mediaScreen), "fountain footage is water / nature for screens")
    check(fountainRecord.recommendedUses.contains(.motionReference) && fountainRecord.evidence.contains { $0.contains("不是骨骼动画") || $0.contains("not skeletal") }, "a person in a video is a motion reference, stated as not animation data")

    var music = AssetSignals(mediaType: .audio)
    music.labels = [AssetTag(name: "music", score: 0.9, source: .sound), AssetTag(name: "piano", score: 0.6, source: .sound)]
    check(record("song", .audio, music).recommendedUses.first == .music, "sound labels choose music")
    let silent = record("clip", .audio, AssetSignals(mediaType: .audio))
    check(silent.primaryCategory == .audio && silent.recommendedUses.isEmpty && silent.evidence.contains { $0.contains("没有可用的声音分类") || $0.contains("No sound") }, "without a sound classifier only metadata is claimed")

    // MARK: Corrections, locks, multi-category, re-analysis
    var state = AssetLibraryState()
    for r in [portraitRecord, brickRecord, castleRecord, unknownRecord, riggedRecord, houseRecord, fountainRecord, bareRecord] { SemanticAssetLibrary.upsert(r, into: &state) }
    check(SemanticAssetLibrary.upsert(record("again", .image, castle).withHash("sha-castle"), into: &state).duplicate, "the same content is found by hash and not added twice")
    SemanticAssetLibrary.setCategory("blur", primary: .reference, secondary: [.nature], in: &state, now: assetNow)
    check(state.records["blur"]?.primaryCategory == .reference && state.records["blur"]?.categories == [.reference, .nature] && state.records["blur"]?.status == .ready, "the user's category applies with a second category")
    var reanalysed = state.records["blur"]!
    var newSignals = castle; newSignals.labels = [AssetTag(name: "castle", score: 0.95, source: .vision)]
    AssetClassifier.apply(AssetClassifier.classify(newSignals), to: &reanalysed, signals: newSignals, analysis: reanalysed.analysis!, now: assetNow)
    check(reanalysed.primaryCategory == .reference && reanalysed.confidence?.kind == .user, "re-analysis never overrides a corrected (locked) category")
    SemanticAssetLibrary.addTag("castle", tag: "  月光城堡  ", in: &state, now: assetNow)
    SemanticAssetLibrary.removeTag("castle", tag: "sky", in: &state, now: assetNow)
    check(state.records["castle"]?.userTags == ["月光城堡"] && state.records["castle"]?.semanticTags.contains { $0.name == "sky" } == false && state.records["castle"]?.locks.contains(.tags) == true, "custom tags are trimmed, removed tags stay removed")
    check(SemanticAssetLibrary.search(AssetQuery(text: "月光城堡"), in: state).map(\.assetID) == ["castle"], "search finds user tags")
    check(SemanticAssetLibrary.search(AssetQuery(category: .building), in: state).contains { $0.assetID == "castle" }, "search by category")
    SemanticAssetLibrary.setCategory(["portrait", "brick"], primary: .reference, in: &state, now: assetNow)
    check(state.records["portrait"]?.primaryCategory == .reference && state.records["brick"]?.corrections.count == 1, "batch category change, one correction each")
    let restored = try! JSONDecoder().decode(AssetLibraryState.self, from: JSONEncoder().encode(state))
    check(restored == state, "corrections, locks and tags survive saving and loading")

    // MARK: Cache
    let key = AssetCacheKey(contentHash: "abc", analyzerID: AssetClassifier.id, analyzerVersion: 1, configurationVersion: 1)
    check(key != AssetCacheKey(contentHash: "abc", analyzerID: AssetClassifier.id, analyzerVersion: 2, configurationVersion: 1) &&
          key != AssetCacheKey(contentHash: "abc", analyzerID: AssetClassifier.id, analyzerVersion: 1, configurationVersion: 2) && key.string.hasPrefix("abc|"),
          "a new analyzer or configuration version invalidates the cache")

    // MARK: Routing
    let caps = AssetCapabilities(depthModelBundled: true, cloudKeyPresent: false, cloudConsent: false)
    let bareRoutes = AssetRouter.route(state.records["statue"]!, capabilities: caps)
    if state.records["statue"]?.primaryCategory == .character {
        check(bareRoutes.first?.operation == .autoRig && bareRoutes.first?.state == .available && bareRoutes.first?.needsConfirmation == true, "an unrigged character model goes to auto-rig, with confirmation")
    }
    let heroRoutes = AssetRouter.route(state.records["hero"]!, capabilities: caps)
    check(heroRoutes.contains { $0.operation == .generateMotion && !$0.state.usable && $0.external }, "motion for a rigged model needs a key: it is not offered as runnable")
    check(heroRoutes.contains { $0.operation == .placeModel && $0.state.usable }, "a rigged model can be placed")
    var nature = AssetSignals(mediaType: .image); nature.pixel = AssetPixelStats.measure(gradient)
    nature.labels = [AssetTag(name: "mountain", score: 0.9, source: .vision), AssetTag(name: "landscape", score: 0.6, source: .vision)]
    let natureRoutes = AssetRouter.route(record("hills", .image, nature), capabilities: caps)
    check(natureRoutes.contains { $0.operation == .terrainFromPhoto && !$0.state.usable } && natureRoutes.contains { $0.operation == .useAsStyleReference && $0.state.usable },
          "a terrain photo does not pretend to make heights; it is a style reference")
    check(AssetRouter.route(castleRecord, capabilities: caps).allSatisfy { $0.operation == .useAsStyleReference }, "a castle picture is only a style reference")
    check(AssetCapabilities(depthModelBundled: false, cloudKeyPresent: true, cloudConsent: true).state(.generateModelFromImage) != .available, "no bundled depth model: image→3D is unavailable")
    check(AssetCapabilities(depthModelBundled: true, cloudKeyPresent: true, cloudConsent: false).state(.generateMotion) != .available, "a key without the Asset Director's own consent is not enough")

    // MARK: Safety
    func head(_ s: String) -> [UInt8] { Array(s.utf8) }
    check(AssetFileSafety.check(fileName: "a.png", size: 0, head: []) == .failure(.empty), "empty files are refused")
    check(AssetFileSafety.check(fileName: "a.png", size: 100 << 20, head: [0x89, 0x50, 0x4E, 0x47]) == .failure(.tooLarge(60 << 20)), "oversized images are refused")
    check(AssetFileSafety.check(fileName: "a.exe", size: 10, head: [1, 2]) == .failure(.unsupported("exe")), "unknown formats are refused")
    check(AssetFileSafety.check(fileName: "photo.png", size: 100, head: [0xFF, 0xD8, 0xFF, 0xE0]) == .failure(.mismatch("png ≠ jpg")), "a JPEG named .png is refused")
    check(AssetFileSafety.check(fileName: "song.m4a", size: 100, head: [0, 0, 0, 0x20] + head("ftypM4A ")) == .success(.audio), "an m4a is audio")
    check(AssetFileSafety.check(fileName: "clip.mov", size: 100, head: [0, 0, 0, 0x14] + head("ftypqt  ")) == .success(.video), "a QuickTime movie is video")
    let gltf = Data(#"{"asset":{"version":"2.0"},"buffers":[{"uri":"https://evil.example/x.bin"},{"uri":"mesh.bin"}],"images":[{"uri":"../../secret.png"},{"uri":"data:image/png;base64,AAAA"}]}"#.utf8)
    check(AssetFileSafety.externalReferences(modelExtension: "gltf", data: gltf) == ["https://evil.example/x.bin", "../../secret.png"], "glTF network and parent-folder references are found; siblings and data URIs are fine")
    check(AssetFileSafety.externalReferences(modelExtension: "obj", data: Data("mtllib /etc/passwd\nv 0 0 0\nmtllib house.mtl\n".utf8)) == ["/etc/passwd"], "OBJ absolute paths are found")
    check(AssetFileSafety.externalReferences(modelExtension: "usda", data: Data("#usda 1.0\ndef \"X\" ( references = @http://x.com/a.usd@ ) {}\nasset a = @./tex.png@".utf8)) == ["http://x.com/a.usd"], "USDA network references are found")

    // MARK: Cloud and AI output
    var settings = AssetDirectorSettings()
    check(AssetCloudPolicy.may(upload: 1, settings: settings, keyPresent: true, now: assetNow) != .allowed, "cloud vision is off by default: nothing is uploaded")
    settings.cloudVision = true; settings.cloudDailyLimit = 2
    check(AssetCloudPolicy.may(upload: 1, settings: settings, keyPresent: false, now: assetNow) != .allowed, "no key, no upload")
    AssetCloudPolicy.record(2, in: &settings, now: assetNow)
    check(AssetCloudPolicy.may(upload: 1, settings: settings, keyPresent: true, now: assetNow) != .allowed && AssetCloudPolicy.may(upload: 1, settings: settings, keyPresent: true, now: assetNow.addingTimeInterval(86_400)) == .allowed,
          "the daily budget stops uploads and resets the next day")
    check(AssetAIOutputValidator.parse(Data("not json".utf8)) == nil && AssetAIOutputValidator.parse(Data(#"{"category":"weapon"}"#.utf8)) == nil, "junk and unknown categories are rejected")
    let hostile = AssetAIOutputValidator.parse(Data(#"{"category":"Building","labels":[{"name":"../../etc/passwd","score":9},{"name":"castle; rm -rf /","score":0.7},{"name":42}],"styles":["pixel","<script>"],"path":"/tmp/x"}"#.utf8))
    check(hostile?.category == .building && hostile?.labels.map(\.name) == ["etcpasswd", "castle rm rf"] && hostile?.labels.first?.score == 1 && hostile?.styles == ["pixel"],
          "AI labels are stripped to letters, scores clamped, unknown styles and fields dropped")

    // MARK: Licences
    let photo = AssetProvenance.initial(origin: .photos, license: nil, author: nil, proof: nil)
    check(photo.commercialUse == .unknown && photo.personalUse == .allowed, "an album photo is usable in your world, commercial use unknown")
    check(AssetProvenance.initial(origin: .builtin, license: "CC0 1.0", author: "Kenney", proof: "LICENSE-Kenney.txt").commercialUse == .allowed, "a recorded CC0 licence allows commercial use")
    check(AssetProvenance.initial(origin: .internet, license: "CC BY-NC 4.0", author: nil, proof: nil).commercialUse == .unknown, "a non-commercial licence is not called commercial")

    // MARK: Relationships, missing resources, deleting
    var graph = AssetLibraryState()
    var picture = portraitRecord; picture.dominantColors = ["E0B090"]
    var model = riggedRecord; model.dominantColors = ["E0B090"]
    SemanticAssetLibrary.upsert(picture, into: &graph); SemanticAssetLibrary.upsert(model, into: &graph); SemanticAssetLibrary.upsert(bareRecord, into: &graph)
    SemanticAssetLibrary.suggestRelationships(in: &graph)
    check(graph.relationships.contains { $0.kind == .sameCharacter && !$0.confirmed && $0.origin == .suggested }, "a look-alike picture and model are only a suggestion")
    check(SemanticAssetLibrary.missingResources(in: graph).contains { $0.operation == .generateMotion && $0.assetID == "hero" }, "a rigged model without motion asks for idle / walk / attack")
    SemanticAssetLibrary.confirm("portrait", "hero", kind: .sameCharacter, accept: true, in: &graph)
    check(!SemanticAssetLibrary.references(to: "hero", in: graph, worldMediaIDs: [], worldModelIDs: []).isEmpty, "a confirmed link counts as a reference")
    check(!SemanticAssetLibrary.references(to: "hero", in: graph, worldMediaIDs: [], worldModelIDs: ["m1"]).isEmpty, "a model used in the world blocks a silent delete")
    check(SemanticAssetLibrary.references(to: "statue", in: graph, worldMediaIDs: [], worldModelIDs: []).isEmpty, "an unused asset is safe to remove")
    SemanticAssetLibrary.removeRecord("portrait", in: &graph)
    check(graph.records["portrait"] == nil && !graph.relationships.contains { $0.from == "portrait" || $0.to == "portrait" }, "removing a record removes its links (the file is not touched)")

    // MARK: Queue
    var queue = AssetQueueState()
    AssetQueuePolicy.enqueue(["a", "b", "c", "a"], into: &queue, now: assetNow)
    check(queue.jobs.count == 3, "a queued asset is not queued twice")
    check(AssetQueuePolicy.concurrency(AssetDeviceConditions(thermal: 0, lowPower: false, memoryMB: 6144)) == 3 &&
          AssetQueuePolicy.concurrency(AssetDeviceConditions(thermal: 2, lowPower: false, memoryMB: 6144)) == 1 &&
          AssetQueuePolicy.concurrency(AssetDeviceConditions(thermal: 0, lowPower: true, memoryMB: 6144)) == 1 &&
          AssetQueuePolicy.concurrency(AssetDeviceConditions(thermal: 3)) == 0 && AssetQueuePolicy.concurrency(AssetDeviceConditions(background: true)) == 0,
          "concurrency follows heat, Low Power Mode and background state")
    let first = AssetQueuePolicy.next(queue, limit: 2)
    first.forEach { AssetQueuePolicy.start($0, in: &queue) }
    check(first == ["a", "b"] && AssetQueuePolicy.next(queue, limit: 2).isEmpty, "the limit is respected")
    AssetQueuePolicy.fail("a", error: "low memory", retryable: true, in: &queue)
    AssetQueuePolicy.finish("b", in: &queue)
    check(queue.jobs.first { $0.assetID == "a" }?.state == .waiting, "a retryable failure goes back to waiting")
    AssetQueuePolicy.start("a", in: &queue); AssetQueuePolicy.fail("a", error: "x", retryable: true, in: &queue)
    AssetQueuePolicy.start("a", in: &queue); AssetQueuePolicy.fail("a", error: "x", retryable: true, in: &queue)
    check(queue.jobs.first { $0.assetID == "a" }?.state == .failed, "after three attempts it stays failed")
    AssetQueuePolicy.start("c", in: &queue); AssetQueuePolicy.recover(&queue)
    check(queue.jobs.first { $0.assetID == "c" }?.state == .waiting, "a relaunch puts interrupted jobs back in the queue")
    queue.paused = true
    check(AssetQueuePolicy.next(queue, limit: 3).isEmpty, "a paused queue starts nothing")
    AssetQueuePolicy.cancel(in: &queue)
    check(queue.jobs.first { $0.assetID == "c" }?.state == .cancelled, "cancel stops waiting jobs")
    AssetQueuePolicy.retryFailed(in: &queue)
    check(queue.jobs.filter { $0.state == .waiting }.count == 2, "retry brings back failed and cancelled jobs")

    // MARK: Calibration and evaluation
    var samples: [(scores: [AssetScoredCategory], truth: AssetCategory)] = []
    for i in 0..<30 {
        let right = i % 5 != 0
        let score = 0.3 + Double(i) / 50
        samples.append(([AssetScoredCategory(category: right ? .character : .prop, score: score), AssetScoredCategory(category: .character, score: score / 2)], .character))
    }
    let fitted = AssetCalibration.fit(samples)
    check(fitted.fitted && fitted.sampleCount == 30 && fitted.candidates <= fitted.automatic, "calibration is fitted from labelled samples")
    check(AssetCalibration.fit(Array(samples.prefix(3))) == .starter, "too few samples keep the starter thresholds (and say they are not fitted)")
    let evaluation = AssetEvaluation.measure(samples.enumerated().map { ("s\($0.offset)", $0.element.scores, $0.element.truth) })
    check(evaluation.samples == 30 && abs(evaluation.top1 - 24.0 / 30) < 1e-9 && evaluation.top3 == 1 && evaluation.confusions.count == 6, "top-1 / top-3 are counted, with the confusions listed")

    // MARK: World Director — 月光水晶城 with imported assets
    var lib = AssetLibraryState()
    var houseModel = houseRecord; houseModel.storage = .generatedModel("house-model")
    var heroModel = riggedRecord; heroModel.storage = .generatedModel("hero-model")
    var glass = AssetSignals(mediaType: .image); glass.pixel = checkerStats; glass.dominantColors = ["9FD3F0"]
    glass.labels = [AssetTag(name: "glass", score: 0.7, source: .vision), AssetTag(name: "pattern", score: 0.5, source: .vision)]
    let glassRecord = record("glass", .image, glass)
    var online = record("stranger", .image, castle, origin: .internet)
    online.contentHash = "sha-online"
    for r in [castleRecord, houseModel, glassRecord, fountainRecord, heroModel, online] { SemanticAssetLibrary.upsert(r, into: &lib) }
    let selection = AssetWorldMatcher.select(Array(lib.records.values), theme: .crystalKingdom)
    let role = Dictionary(uniqueKeysWithValues: selection.usage.map { ($0.assetID, $0.role) })
    check(role["castle"] == .styleOnly && role["glass"] == .material && role["fountain"] == .fountainMedia && role["hero"] == .character && role["house"] == .sceneModel,
          "the matcher gives each imported asset its town role (\(selection.usage.map { "\($0.assetID)=\($0.role?.rawValue ?? "-")" }))")
    check(selection.skipped.contains { $0.assetID == "stranger" }, "an online asset without a licence is left out, with a reason")
    check(selection.descriptors.first { $0.assetID == "castle" }?.libraryID == nil, "a reference picture can never be placed (no library file handed over)")

    // A player's own build stands in the region before the director runs.
    var base = SpatialWorld()
    base.blocks.append(SpatialBlock(id: "my-tower", x: 210, y: 210, elevation: 0, thickness: 3, origin: .user))
    var request = WorldGenerationRequest(theme: .crystalKingdom, prompt: "")
    request.seed = 11; request.assets = selection.descriptors
    let blueprint = WorldPlanner.plan(request)
    check(blueprint.town?.glassTint == "9FD3F0", "the material picture tints the town's glass")
    check(blueprint.assetAssignments.contains { $0.slot == "fountainMedia" && $0.assetID == "fountain" } &&
          blueprint.assetAssignments.filter { $0.slot == "statue" }.map(\.assetID).sorted() == ["hero", "house"],
          "the plan puts the footage on the fountain and both models on town spots")
    let built = try! SpatialWorldBuilder.build(blueprint, assets: request.assets, onto: base)
    check(built.world.blocks.contains { $0.id == "my-tower" && $0.origin == .user }, "the player's own build is kept")
    check(built.statues.map(\.modelID).sorted() == ["hero-model", "house-model"], "both models stand in the town (\(built.notes))")
    let fountainBinding = built.bindings.first { $0.mediaID == "lib-fountain" }
    check(fountainBinding?.kind == .video && built.world.blocks.contains { $0.media?.bindingID == fountainBinding?.id && $0.media?.face == .top },
          "the fountain footage plays on the fountain's water surface")
    check(!built.bindings.contains { $0.mediaID == "lib-castle" || $0.mediaID == "lib-glass" }, "reference and material pictures are not put on blocks")
    let gate = WorldQualityEvaluator.evaluate(built, blueprint: blueprint, assets: request.assets)
    check(gate.passed, "the town with imported assets still passes both quality gates (\(gate.violations))")
    let withoutAssets = try! SpatialWorldBuilder.build(WorldPlanner.plan(WorldGenerationRequest(theme: .crystalKingdom, prompt: "")), assets: [], onto: SpatialWorld())
    check(withoutAssets.statues.isEmpty && !withoutAssets.world.blocks.isEmpty, "without analysed assets the director works as before")
    var pixelView = built.world; pixelView.hybrid?.viewMode = .pixelRPG
    check(pixelView.blocks == built.world.blocks && pixelView.player == built.world.player, "pixel and 3D views share the same world data")
    let oldRecord = try! JSONDecoder().decode(AssetDescriptor.self, from: Data(#"{"assetID":"a","sourceType":"photos","mediaType":"image","contentHash":"h","dominantColors":[],"styleTags":[],"semanticTags":[],"textureMemoryEstimate":0,"compatibleWorldTypes":[],"pixelWidth":1,"pixelHeight":1,"hasAlpha":false,"title":""}"#.utf8))
    check(oldRecord.assetRole == nil, "a v1.86 asset descriptor still decodes")
    let oldTown = try! JSONDecoder().decode(GoldenTownIntent.self, from: Data(#"{"style":"crystalFantasy","water":"river","forest":true,"mountains":true,"gardens":true,"winding":true}"#.utf8))
    check(oldTown.glassTint == nil, "a v1.86 town intent still decodes")
    print("Asset Director: town roles \(selection.usage.count), skipped \(selection.skipped.count), statues \(built.statues.count), gate passed \(gate.passed)")
}

private extension AssetIntelligenceRecord {
    func withHash(_ hash: String) -> AssetIntelligenceRecord { var r = self; r.contentHash = hash; r.assetID = "dup-" + assetID; return r }
}
