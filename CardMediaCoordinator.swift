import SwiftUI
import AVFoundation
import ImageIO
import CoreImage

@MainActor final class CardMediaFrameFeed: ObservableObject {
    @Published var revision = 0
    weak var image: UIImage?
    func show(_ value: UIImage?) { image = value; revision &+= 1 }
}
private struct CardPixel: @unchecked Sendable { let buffer: CVPixelBuffer }
private struct CardRendered: @unchecked Sendable { let image: CGImage }
private actor CardFrameRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func render(_ pixel: CardPixel) -> CardRendered? {
        let source = CIImage(cvPixelBuffer: pixel.buffer)
        let scale = min(1, 320 / max(source.extent.width, source.extent.height))
        let reduced = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(reduced, from: reduced.extent).map { CardRendered(image: $0) }
    }
    func loadPoster(_ url: URL) async -> CardRendered? {
        if Task.isCancelled { return nil }
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return poster(data)
        }
        guard ["http", "https"].contains(url.scheme ?? ""),
              let (bytes, response) = try? await URLSession.shared.bytes(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              response.expectedContentLength <= 8 * 1024 * 1024 else { return nil }
        var buffer = Data()
        do {
            for try await byte in bytes {
                if buffer.count >= 8 * 1024 * 1024 || Task.isCancelled { return nil }
                buffer.append(byte)
            }
        } catch { return nil }
        return poster(buffer)
    }
    func poster(_ data: Data) -> CardRendered? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return CardRendered(image: image)
    }
}

/// One decoder per scheduled asset, shared across every card referencing it.
/// Views receive bounded thumbnail frames, never individual AVPlayerLayers.
@MainActor final class CardMediaCoordinator: ObservableObject {
    @MainActor private final class Slot {
        let player: AVPlayer
        let output: AVPlayerItemVideoOutput
        var end: NSObjectProtocol?
        var rendering = false
        init(url: URL) {
            let item = AVPlayerItem(url: url)
            item.preferredMaximumResolution = CGSize(width: 480, height: 360)
            item.preferredPeakBitRate = 500_000
            item.preferredForwardBufferDuration = 1
            output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(output)
            player = AVPlayer(playerItem: item); player.isMuted = true
            player.actionAtItemEnd = .none
        }
        func close() {
            player.pause(); player.isMuted = true
            if let end { NotificationCenter.default.removeObserver(end) }; end = nil
            player.currentItem?.remove(output); player.replaceCurrentItem(with: nil)
        }
    }
    private(set) static var ownedPlayers = 0
    private var slots: [String: Slot] = [:]
    private struct GIFSlot {
        let frames: RPGGIFFrames
        let started: CFTimeInterval
        let resume: Double
        var index = -1
    }
    private var gifs: [String: GIFSlot] = [:]
    private var gifTasks: [String: Task<Void, Never>] = [:]
    private var desiredGIFs: Set<String> = []
    private var feeds: [String: CardMediaFrameFeed] = [:]
    private var cache = CardFrameLRU<UIImage>(maxEntries: 24, maxCost: 12 * 1024 * 1024)
    private let renderer = CardFrameRenderer()
    private(set) var renderedFrames = 0
    private(set) var posterFrames = 0
    private var lastTick: CFTimeInterval = 0
    private var posterTasks: [String: Task<Void, Never>] = [:]
    private var posterQueue: [String] = []
    private var candidates: [CardMediaCandidate] = []
    private var entries: [String: MediaEntry] = [:]
    private var requested = 2
    private var active = false
    private var resumeAfterInterruption = false
    private var interrupted = false
    private var pressure = false
    private var slow = false
    private var generation = UUID()
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    private var audioBefore: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var failed = Set<String>()
    private var loopingMediaIDs: Set<String>?
    private var completed = Set<String>()
    var completedPreviewCount: Int { completed.count }
    private(set) var snapshots: [Int: CardPlaybackSnapshot] = [:]
    private(set) var focusID: Int?
    @Published private(set) var audible = false
    @Published private(set) var notice = ""
    var decoderCount: Int { slots.count + gifs.count + gifTasks.count }
    var isUnderPressure: Bool { pressure }
    var cacheBytes: Int { cache.cost + gifs.values.reduce(0) { $0 + $1.frames.cost } }
    var advancing: Int { slots.values.filter { $0.player.rate > 0 && $0.player.currentTime().seconds > 0.05 }.count }
    var muted: Bool { slots.values.allSatisfy { $0.player.isMuted } }
    init() {}
    private func observe() {
        guard observations.isEmpty else { return }
        let epoch = generation
        for name in [UIApplication.didReceiveMemoryWarningNotification, ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange, AVAudioSession.interruptionNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let isMemory = notification.name == UIApplication.didReceiveMemoryWarningNotification
                let interrupted = notification.name == AVAudioSession.interruptionNotification
                let ended = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
                Task { @MainActor [weak self] in
                    guard let self, self.generation == epoch else { return }
                    if isMemory {
                        self.pressure = true; self.cache.maxEntries = 6; self.cache.maxCost = 2 * 1024 * 1024; self.cache.trim()
                        for (id, feed) in self.feeds { feed.show(self.cache.value(id)) }
                        self.notice = "内存紧张，已切换静态牌面；可在媒体设置中重新启用。"
                    }
                    if interrupted {
                        if ended {
                            if self.interrupted { self.active = self.active || self.resumeAfterInterruption; self.resumeAfterInterruption = false; self.interrupted = false }
                        } else { self.interrupted = true; self.resumeAfterInterruption = self.active; self.active = false }
                        self.mute()
                    }
                    self.reconcile()
                }
            })
        }
    }
    func feed(_ id: String) -> CardMediaFrameFeed {
        if let feed = feeds[id] { return feed }
        let feed = CardMediaFrameFeed(); feed.show(cache.value(id)); feeds[id] = feed; return feed
    }
    func configure(entries: [MediaEntry], requested: Int, active: Bool) {
        let oldIDs = Set(self.entries.keys)
        self.entries = Dictionary(entries.filter { $0.kind != .embed }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in oldIDs.subtracting(self.entries.keys) { cache.remove(id); feeds[id]?.show(nil) }
        self.requested = requested; self.active = active
        if active || cache.count > 0 { observe() }
        if !active { mute() }
        reconcile()
    }
    func configureLooping(_ ids: Set<String>) {
        loopingMediaIDs = ids
        completed.subtract(ids)
    }
    // RPG cutscenes restore a bounded snapshot before the slot is created.
    func restorePlayback(cardID:Int,mediaID:String,seconds:Double) {
        guard seconds.isFinite,(0...10_000_000).contains(seconds),slots[mediaID] == nil else { return }
        snapshots[cardID] = CardPlaybackSnapshot(mediaID:mediaID,seconds:seconds)
    }
    func playbackSeconds(_ mediaID:String)->Double {
        let seconds = slots[mediaID]?.player.currentTime().seconds ?? snapshots.values.first(where:{$0.mediaID==mediaID})?.seconds ?? 0
        return seconds.isFinite ? max(0,min(10_000_000,seconds)):0
    }
    func retainSnapshots(for ids: Set<Int>) { for id in Array(snapshots.keys) where !ids.contains(id) { snapshots[id] = nil } }
    func retry() {
        for key in Array(snapshots.keys) where completed.contains(snapshots[key]?.mediaID ?? "") { snapshots[key]?.seconds = 0 }
        completed.removeAll(); pressure = false; slow = false; failed.removeAll(); cache.maxEntries = 24; cache.maxCost = 12 * 1024 * 1024; notice = ""; reconcile() }
    func update(_ values: [CardMediaCandidate], focus: Int?) {
        let newlyHidden = Set(candidates.filter { $0.visibility != .hidden }.map(\.cardID)).subtracting(values.filter { $0.visibility != .hidden }.map(\.cardID))
        for id in newlyHidden {
            if let mediaID = snapshots[id]?.mediaID, let slot = slots[mediaID] {
                let seconds = slot.player.currentTime().seconds
                if seconds.isFinite { snapshots[id]?.seconds = max(0, seconds) }
                snapshots[id]?.frameReference = cache.contains(mediaID) ? mediaID : nil
            }
        }
        let visibleMedia = Set(values.filter { $0.visibility != .hidden }.map(\.mediaID))
        let leaving = completed.subtracting(visibleMedia)
        for key in Array(snapshots.keys) where leaving.contains(snapshots[key]?.mediaID ?? "") { snapshots[key]?.seconds = 0 }
        completed.subtract(leaving)
        candidates = values; focusID = focus
        let visibleIDs = Set(values.filter { $0.visibility != .hidden }.map(\.cardID))
        for id in Array(snapshots.keys) where !visibleIDs.contains(id) { snapshots[id]?.visibility = .hidden }
        for value in values {
            var snapshot = snapshots[value.cardID].flatMap { $0.mediaID == value.mediaID ? $0 : nil } ?? CardPlaybackSnapshot(mediaID: value.mediaID)
            snapshot.visibility = value.visibility
            snapshots[value.cardID] = snapshot
        }
        reconcile()
    }
    func mute() {
        for slot in slots.values { slot.player.isMuted = true }; audible = false
        if let previous = audioBefore {
            let audio = AVAudioSession.sharedInstance()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(previous.0, mode: previous.1, options: previous.2)
        }
        audioBefore = nil
    }
    func toggleSound() {
        if audible { mute(); return }
        guard let focusID, let id = candidates.first(where: { $0.cardID == focusID })?.mediaID,
              let slot = slots[id] else { notice = "当前牌面没有动态视频，无法开启声音。"; return }
        mute()
        let audio = AVAudioSession.sharedInstance()
        audioBefore = (audio.category, audio.mode, audio.categoryOptions)
        do { try audio.setCategory(.soloAmbient); try audio.setActive(true); slot.player.isMuted = false; audible = true }
        catch { mute(); notice = "声音暂不可用，继续静音预览。" }
    }
    private var budget: Int {
        CardMediaPolicy.budget(requested: requested, serious: ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled || slow,
                               critical: ProcessInfo.processInfo.thermalState == .critical, memoryPressure: pressure)
    }
    private func reconcile() {
        let visible = active ? candidates.filter { $0.visibility != .hidden && (focusID == nil || $0.cardID == focusID) } : []
        let dynamic = visible.filter { candidate in
            guard let entry = entries[candidate.mediaID] else { return false }
            return (entry.kind == .video || isGIF(entry)) && !failed.contains(candidate.mediaID) && !completed.contains(candidate.mediaID)
        }
        let scheduled = Set(CardMediaPolicy.scheduled(dynamic, budget: budget))
        let desired = Set(scheduled.filter { entries[$0]?.kind == .video })
        desiredGIFs = scheduled.subtracting(desired)
        for id in Set(gifs.keys).union(gifTasks.keys).subtracting(desiredGIFs) { releaseGIF(id) }
        for id in desiredGIFs where gifs[id] == nil && gifTasks[id] == nil {
            guard let url = entries[id]?.remoteURL else { continue }
            let epoch = generation
            gifTasks[id] = Task { [weak self] in
                let decoding = Task.detached(priority: .utility) { RPGGIFDecoder.decode(url) }
                let decoded = await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
                guard !Task.isCancelled, let self, generation == epoch, desiredGIFs.contains(id) else { return }
                gifTasks[id] = nil
                if let decoded {
                    let seconds = snapshots.values.first { $0.mediaID == id }?.seconds ?? 0
                    gifs[id] = GIFSlot(frames: decoded, started: CACurrentMediaTime(), resume: seconds)
                } else { failed.insert(id); notice = "部分 GIF 无法解码，已保留封面或默认牌面。" }
                reconcile()
            }
        }
        for id in Array(slots.keys) where !desired.contains(id) { release(id) }
        for id in desired where slots[id] == nil {
            guard let url = entries[id]?.remoteURL, ["file", "http", "https"].contains(url.scheme ?? "") else { continue }
            let slot = Slot(url: url); slots[id] = slot; Self.ownedPlayers += 1
            let seconds = visible.filter { $0.mediaID == id }.sorted { $0.role.rawValue > $1.role.rawValue }.compactMap { snapshots[$0.cardID]?.seconds }.first ?? 0
            if seconds.isFinite && seconds > 0 { slot.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            slot.end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: slot.player.currentItem, queue: .main) { [weak self, weak slot] _ in
                Task { @MainActor [weak self, weak slot] in
                    guard let self, let slot, self.slots[id] === slot else { return }
                    if self.loopingMediaIDs?.contains(id) != false {
                        slot.player.seek(to: .zero); slot.player.play()
                    } else { self.completed.insert(id); self.release(id); self.reconcile() }
                }
            }
            slot.player.play()
        }
        for candidate in visible { enqueuePoster(candidate.mediaID) }
        startPoster()
        if slots.isEmpty && gifs.isEmpty { timer?.invalidate(); timer = nil }
        else if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    private func isGIF(_ entry: MediaEntry) -> Bool {
        entry.kind == .image && entry.remoteURL?.isFileURL == true && entry.remoteURL?.pathExtension.lowercased() == "gif"
    }
    private func releaseGIF(_ id: String) {
        gifTasks.removeValue(forKey: id)?.cancel()
        if let gif = gifs.removeValue(forKey: id) {
            let seconds = gif.resume + CACurrentMediaTime() - gif.started
            for key in Array(snapshots.keys) where snapshots[key]?.mediaID == id {
                snapshots[key]?.seconds = max(0, seconds); snapshots[key]?.frameReference = cache.contains(id) ? id : nil
            }
        }
    }
    private func release(_ id: String) {
        guard let slot = slots.removeValue(forKey: id) else { return }; Self.ownedPlayers -= 1
        let seconds = slot.player.currentTime().seconds
        for key in Array(snapshots.keys) where snapshots[key]?.mediaID == id {
            if seconds.isFinite && snapshots[key]?.visibility != .hidden { snapshots[key]?.seconds = max(0, seconds) }
            if cache.value(id) != nil { snapshots[key]?.frameReference = id }
        }
        if !slot.player.isMuted { mute() }
        slot.close()
    }
    private func tick() {
        let now = CACurrentMediaTime()
        let reduced = slow || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled
        if reduced && now - lastTick < 1.0 / 6 { return }
        lastTick = now
        let epoch = generation
        for (id, gif) in Array(gifs) {
            let elapsed = gif.resume + now - gif.started
            let looping = loopingMediaIDs?.contains(id) != false
            let index = RPGGIFTiming.frameIndex(elapsed: elapsed, delays: gif.frames.delays, loop: looping)
            if index != gif.index {
                gifs[id]?.index = index
                renderedFrames += 1
                publish(CardRendered(image: gif.frames.images[index]), id: id)
            }
            if !looping && elapsed >= gif.frames.delays.reduce(0, +) { completed.insert(id); releaseGIF(id); reconcile() }
        }
        for (id, slot) in Array(slots) {
            if slot.player.currentItem?.status == .failed {
                failed.insert(id); notice = "部分素材无法播放，已保留封面或经典牌面。"; release(id); continue
            }
            guard !slot.rendering else { continue }
            let time = slot.player.currentTime()
            guard slot.output.hasNewPixelBuffer(forItemTime: time), let pixel = slot.output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { continue }
            slot.rendering = true
            let started = CACurrentMediaTime()
            Task { [weak self, weak slot, renderer] in
                let frame = await renderer.render(CardPixel(buffer: pixel))
                guard let self, let slot, self.generation == epoch, self.slots[id] === slot else { return }
                slot.rendering = false
                if let frame { self.renderedFrames += 1; self.publish(frame, id: id) }
                // Sustained slow rendering reduces the decoder budget. No FPS promise.
                if CACurrentMediaTime() - started > 0.25 { self.slow = true; self.reconcile() }
            }
        }
    }
    private func publish(_ frame: CardRendered, id: String) {
        let image = UIImage(cgImage: frame.image)
        cache.put(image, key: id, cost: frame.image.bytesPerRow * frame.image.height)
        feed(id).show(cache.value(id))
        for (key, feed) in feeds where !cache.contains(key) && feed.image != nil { feed.show(nil) }
    }
    private func enqueuePoster(_ id: String) {
        guard cache.value(id) == nil, posterTasks[id] == nil, !posterQueue.contains(id), !failed.contains("poster:" + id), let entry = entries[id], entry.kind == .image || entry.coverURL != nil else { return }
        posterQueue.append(id)
    }
    private func startPoster() {
        guard active, posterTasks.isEmpty, !posterQueue.isEmpty else { return }
        let id = posterQueue.removeFirst(), epoch = generation
        guard let entry = entries[id], let url = entry.kind == .image ? entry.remoteURL : entry.coverURL else { startPoster(); return }
        posterTasks[id] = Task { [weak self, renderer] in
            let result = await renderer.loadPoster(url)
            guard let self, self.generation == epoch, !Task.isCancelled else { return }
            self.posterTasks[id] = nil
            if let result { self.posterFrames += 1; self.publish(result, id: id) } else { self.failed.insert("poster:" + id) }
            self.startPoster()
        }
    }
    func stop(clear: Bool = false) {
        active = false; resumeAfterInterruption = false; interrupted = false; generation = UUID(); mute()
        timer?.invalidate(); timer = nil
        for id in Set(gifs.keys).union(gifTasks.keys) { releaseGIF(id) }; desiredGIFs = []
        for id in Array(slots.keys) { release(id) }
        for task in posterTasks.values { task.cancel() }; posterTasks.removeAll(); posterQueue.removeAll()
        for token in observations { NotificationCenter.default.removeObserver(token) }; observations.removeAll()
        if !clear && cache.count > 0 { observe() }
        if clear { candidates.removeAll(); focusID = nil; snapshots.removeAll(); cache.removeAll(); for feed in feeds.values { feed.show(nil) }; feeds.removeAll(); failed.removeAll(); completed.removeAll() }
    }
    func dispose() { stop(clear: true) }
}
