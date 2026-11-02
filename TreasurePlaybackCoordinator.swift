import AVFoundation
import Combine
import Network
import UIKit

@MainActor final class TreasurePlaybackCoordinator: ObservableObject {
    @Published private(set) var selection = TreasureVideoSelectionModel()
    @Published var mode = TreasureWallMode.sequential
    @Published var loop = false
    @Published var muted = false
    @Published private(set) var playing = false
    @Published private(set) var players: [String: AVPlayer] = [:]
    @Published private(set) var states: [String: String] = [:]
    @Published private(set) var currentID: String?
    @Published private(set) var audioID: String?
    @Published private(set) var focusedID: String?
    @Published private(set) var message = "请选择视频，再点击播放。"
    @Published private(set) var decoderLimit = 2
    private var entries: [String: MediaEntry] = [:]
    private var visible = Set<String>()
    private var queue = TreasureWallQueue(ids: [], random: false)
    private var loads: [String: Task<Void, Never>] = [:]
    private var assets: [String: AVURLAsset] = [:]
    private var observations: [String: NSKeyValueObservation] = [:]
    private var endObservers: [String: NSObjectProtocol] = [:]
    private var failureObservers: [String: NSObjectProtocol] = [:]
    private var notifications: [NSObjectProtocol] = []
    private var monitor: NWPathMonitor?
    private var revisions: [String: UUID] = [:]
    private var finished = Set<String>()
    private var failedIDs = Set<String>()
    private var started = false
    private var audioOwned = false
    private var memoryLimited = false

    static func playable(_ entry: MediaEntry) -> Bool {
        guard entry.kind == .video, let url = entry.remoteURL else { return false }
        return ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
    func activate(items: [MediaEntry], data: Data, mode: String, loop: Bool, muted: Bool) {
        shutdown()
        selection = (try? JSONDecoder().decode(TreasureVideoSelectionModel.self, from: data)) ?? TreasureVideoSelectionModel()
        self.mode = TreasureWallMode(rawValue: mode) ?? .sequential; self.loop = loop; self.muted = muted
        update(items)
        if selection.recoveredOverflow { message = "旧选择超过 10 个，已保留前 10 个。" }
        updateBudget()
        let center = NotificationCenter.default
        notifications = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.began.rawValue
                if began { Task { @MainActor in self?.suspend("音频中断，点击播放恢复。") } }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let removed = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if removed { Task { @MainActor in self?.suspend("耳机已断开，点击播放恢复。") } }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateBudget() }
            },
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateBudget() }
            },
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.memoryLimited = true; self?.updateBudget() }
            }
        ]
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let disconnected = path.status == .unsatisfied
            if disconnected { Task { @MainActor in
                guard let self, self.playing,
                      self.selection.ids.contains(where: { self.entries[$0]?.remoteURL?.isFileURL == false }) else { return }
                self.suspend("网络不可用，恢复连接后点击播放。")
            } }
        }
        monitor.start(queue: DispatchQueue(label: "moonlight.wall.network"))
    }
    func update(_ items: [MediaEntry]) {
        let next = Dictionary(TreasureRules.unique(items.filter { Self.playable($0) }, id: \.id).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changedURL = selection.ids.contains { entries[$0] != nil && entries[$0]?.remoteURL != next[$0]?.remoteURL }
        entries = next
        if selection.prune(available: Set(next.keys)) || changedURL {
            stop(); message = "失效或已删除的视频已移除，请检查选择后播放。"
        }
        if audioID == nil || !selection.ids.contains(audioID ?? "") { audioID = selection.ids.first }
    }
    func toggle(_ id: String) {
        switch selection.toggle(id, available: Set(entries.keys)) {
        case .full: message = "最多选择 10 个不同视频。"; return
        case .unavailable: message = "此视频不可用，请重新选择。"; return
        case .added, .removed: stop(); message = "已选 \(selection.ids.count)/10，点击播放开始。"
        }
        if !selection.ids.contains(audioID ?? "") { audioID = selection.ids.first }
    }
    func setTarget(_ target: Int) { selection.target = min(10, max(1, target)) }
    func clear() { stop(); selection.clear(); audioID = nil; message = "选择已清空。" }
    func setVisible(_ id: String, _ value: Bool) {
        if value { visible.insert(id) } else { visible.remove(id) }
        reconcile()
    }
    func setVisible(_ ids: Set<String>) {
        guard visible != ids else { return }
        visible = ids; reconcile()
    }
    func focus(_ id: String?) {
        guard id == nil || selection.ids.contains(id ?? "") else { return }
        focusedID = id
        if let id { audioID = id }
        reconcile()
    }
    func setAudio(_ id: String) {
        guard selection.ids.contains(id) else { return }
        audioID = id; refreshAudio()
    }
    func play() {
        guard !selection.ids.isEmpty else { message = "请先选择 1–10 个视频。"; return }
        if !started {
            queue = TreasureWallQueue(ids: selection.ids, random: mode == .random)
            currentID = queue.current; started = true; finished.removeAll(); failedIDs.removeAll()
        }
        playing = true; message = "播放中"; reconcile()
    }
    func pause() {
        playing = false
        for id in Array(loads.keys) { release(id) }
        players.values.forEach { $0.pause(); $0.isMuted = true }
        releaseAudio(); message = "已暂停，点击播放继续。"
    }
    func stop() {
        playing = false; started = false; currentID = nil; finished.removeAll(); failedIDs.removeAll(); focusedID = nil
        releasePlayers(); message = "已停止。"
    }
    func changeMode() { stop(); message = "已切换为\(mode.title)播放，点击播放开始。" }
    func suspend(_ reason: String) {
        playing = false; releasePlayers(); message = reason
    }
    func shutdown() {
        stop(); notifications.forEach { NotificationCenter.default.removeObserver($0) }; notifications.removeAll()
        monitor?.cancel(); monitor = nil; visible.removeAll()
    }
    private var wanted: [String] {
        guard playing else { return [] }
        if mode != .simultaneous { return currentID.map { [$0] } ?? [] }
        if let focusedID { return finished.contains(focusedID) || failedIDs.contains(focusedID) ? [] : [focusedID] }
        let pending = selection.ids.filter { !finished.contains($0) && !failedIDs.contains($0) }
        return TreasureWallPolicy.visible(ids: pending, visible: visible, limit: decoderLimit)
    }
    private func updateBudget() {
        let process = ProcessInfo.processInfo
        decoderLimit = TreasureWallPolicy.decoderLimit(memory: process.physicalMemory,
            constrained: process.isLowPowerModeEnabled || process.thermalState == .serious,
            critical: memoryLimited || process.thermalState == .critical)
        reconcile()
    }
    private func reconcile() {
        guard playing else { return }
        let desired = Set(wanted)
        for id in Set(players.keys).union(loads.keys) where !desired.contains(id) { release(id) }
        for id in wanted where players[id] == nil && loads[id] == nil { load(id) }
        refreshAudio()
    }
    private func load(_ id: String) {
        guard let url = entries[id]?.remoteURL else { return }
        let token = UUID(); revisions[id] = token
        states[id] = "加载中"
        let asset = AVURLAsset(url: url); assets[id] = asset
        loads[id] = Task { @MainActor [weak self] in
            let playable = (try? await asset.load(.isPlayable)) == true
            guard !Task.isCancelled, let self, self.revisions[id] == token, self.wanted.contains(id) else { return }
            self.loads[id] = nil
            guard playable else { self.failed(id); return }
            let item = AVPlayerItem(asset: asset)
            item.preferredMaximumResolution = CGSize(width: 960, height: 540)
            item.preferredPeakBitRate = 800_000; item.preferredForwardBufferDuration = 2
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            self.players[id] = player
            self.observations[id] = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.revisions[id] == token, let item = self.players[id]?.currentItem else { return }
                    if item.status == .failed { self.failed(id) }
                    else if item.status == .readyToPlay { self.states[id] = "就绪" }
                }
            }
            self.endObservers[id] = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self, self.revisions[id] == token else { return }; self.ended(id) }
            }
            self.failureObservers[id] = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self, self.revisions[id] == token else { return }; self.failed(id) }
            }
            self.refreshAudio()
        }
    }
    private func failed(_ id: String) {
        failedIDs.insert(id)
        states[id] = "播放失败，请检查网络或重新选择。"
        release(id)
        if mode != .simultaneous { playing = false; started = false; releaseAudio() }
        message = "有视频加载失败，可重新选择或停止后重试。"
        if mode == .simultaneous { reconcile() }
    }
    private func ended(_ id: String) {
        guard playing, players[id] != nil else { return }
        if mode == .simultaneous {
            if loop { players[id]?.seek(to: .zero); players[id]?.play() }
            else {
                finished.insert(id); states[id] = "已结束"; release(id)
                if Set(selection.ids).isSubset(of: finished) { playing = false; started = false; releaseAudio(); message = "本轮播放完成。" }
                else { reconcile() }
            }
        } else {
            guard currentID == id else { return }
            currentID = queue.advance(loop: loop, random: mode == .random)
            if currentID == nil { stop(); message = "本轮播放完成。" }
            else { releasePlayers(); reconcile() }
        }
    }
    func refreshAudio() {
        // Silence every previous owner before enabling the new owner.
        players.values.forEach { $0.isMuted = true }
        let audible = mode == .simultaneous ? audioID : currentID
        let canSound = playing && !muted && players[audible ?? ""] != nil && !finished.contains(audible ?? "")
        if canSound && !audioOwned {
            do {
                try AVAudioSession.sharedInstance().setCategory(.soloAmbient, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true); audioOwned = true
            } catch { message = "音频会话不可用，当前静音播放。" }
        } else if !canSound { releaseAudio() }
        for (id, player) in players {
            player.isMuted = !(canSound && audioOwned && id == audible)
            if playing && !finished.contains(id) { player.play() } else { player.pause() }
        }
    }
    private func releaseAudio() {
        if audioOwned { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation); audioOwned = false }
    }
    private func release(_ id: String) {
        revisions[id] = nil
        loads.removeValue(forKey: id)?.cancel(); assets.removeValue(forKey: id)?.cancelLoading()
        observations.removeValue(forKey: id)?.invalidate()
        if let token = endObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        if let token = failureObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
        if let player = players.removeValue(forKey: id) { player.isMuted = true; player.pause(); player.replaceCurrentItem(with: nil) }
    }
    private func releasePlayers() {
        for id in Set(players.keys).union(loads.keys).union(assets.keys) { release(id) }
        releaseAudio()
    }
}
