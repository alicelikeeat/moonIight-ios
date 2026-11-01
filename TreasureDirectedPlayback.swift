import AVKit
import SwiftUI
import UIKit

@MainActor
extension TreasurePlaybackOptions {
    func source(in store: MediaStore) -> [MediaEntry] {
        switch target {
        case .library, .single: return store.items
        case .favorites: return store.items.filter(\.isFavorite)
        case .queue: return store.queueItems
        case .folder:
            guard let folder = store.folders.first(where: { $0.id == folderID }) else { return [] }
            return store.items(in: folder)
        }
    }
    func plan(in store: MediaStore) -> [String] {
        TreasurePlaybackPlan.ids(in: source(in: store).filter { $0.kind != .embed && $0.remoteURL != nil }.map(\.id), startingAt: startID, count: count, single: target == .single)
    }
}
struct TreasureBackgroundSurface: View {
    let options: TreasurePlaybackOptions
    var body: some View {
        switch options.background {
        case .system: Color(uiColor: .systemBackground)
        case .solid: Color(red: options.red, green: options.green, blue: options.blue)
        case .purple: LinearGradient(colors: [.black, Color(red: 0.15, green: 0.11, blue: 0.25)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct TreasurePlaybackRequest: Identifiable {
    let id = UUID()
    let ids: [String]
    let options: TreasurePlaybackOptions
}

struct TreasureDirectedSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var options: TreasurePlaybackOptions
    let confirm: (Bool) -> Void
    @State private var query = ""
    private var source: [MediaEntry] { TreasureRules.unique(options.source(in: model.mediaStore), id: \.id) }
    private var matches: [MediaEntry] {
        source.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.platform.localizedCaseInsensitiveContains(query) }
    }
    private var ids: [String] { options.plan(in: model.mediaStore) }
    var body: some View {
        Form {
            Section("定向播放") {
                Picker("目标范围", selection: $options.target) {
                    ForEach(TreasureTargetKind.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("treasure-target-kind")
                if options.target == .folder {
                    Picker("播放列表", selection: $options.folderID) {
                        Text("请选择文件夹").tag("")
                        ForEach(model.mediaStore.folders) { Text($0.name).tag($0.id) }
                    }
                }
                Stepper("连续播放 \(options.count) 项", value: $options.count, in: 1...10)
                    .accessibilityIdentifier("treasure-sequence-count")
                Toggle("确认目标后自动播放", isOn: $options.autoPlay)
                Toggle("再次进入月藏图时自动播放", isOn: $options.autoPlayOnReturn)
                    .accessibilityIdentifier("treasure-auto-return")
                Stepper("图片展示 \(Int(options.imageSeconds)) 秒", value: $options.imageSeconds, in: 1...30)
                Text("数量表示从所选目标起连续播放的媒体条目数。到列表尾部停止，不重复；单个媒体只播放一次。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("声音") {
                Picker("声音来源", selection: $options.sound) {
                    ForEach(TreasureSound.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("treasure-sound-mode")
                Slider(value: $options.volume, in: 0...100, step: 1) { Text("音量") }
                    .accessibilityIdentifier("treasure-volume")
                Text("音量 \(Int(options.volume))% · 图片没有原声，声音遵循系统静音及耳机设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("月藏图背景") {
                Picker("背景", selection: $options.background) {
                    ForEach(TreasureBackground.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("treasure-background")
                if options.background == .solid {
                    ColorPicker("纯色", selection: Binding(get: {
                        Color(red: options.red, green: options.green, blue: options.blue)
                    }, set: { color in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                        options.red = Double(r); options.green = Double(g); options.blue = Double(b)
                    }), supportsOpacity: false)
                }
                Button("恢复系统背景") { options.background = .system }
                    .accessibilityIdentifier("treasure-background-reset")
                TreasureBackgroundSurface(options: options)
                    .frame(height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("当前背景预览")
            }
            Section("选择起始媒体（\(matches.count)）") {
                if !options.startID.isEmpty && !source.contains(where: { $0.id == options.startID }) {
                    Text("原目标已删除或不在此列表中，请重新选择。")
                        .foregroundStyle(.red).accessibilityIdentifier("treasure-invalid-target")
                }
                if matches.isEmpty { Text("没有匹配的媒体，请更换搜索词或目标范围。") }
                ForEach(matches) { entry in
                    Button {
                        options.startID = entry.id
                    } label: {
                        HStack {
                            if let url = entry.coverURL ?? (entry.kind == .image ? entry.remoteURL : nil) {
                                if url.isFileURL { LocalMediaImage(url: url).frame(width: 48, height: 48).clipped() }
                                else { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.1) }.frame(width: 48, height: 48) }
                            } else { Image(systemName: entry.kind == .image ? "photo" : "video").frame(width: 48, height: 48) }
                            VStack(alignment: .leading) {
                                Text(entry.title).lineLimit(2)
                                Text(entry.kind == .image ? "图片" : entry.kind == .video ? "视频" : "网页媒体：请使用完整播放器")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if options.startID == entry.id { Image(systemName: "checkmark.circle.fill") }
                        }
                    }
                    .disabled(entry.kind == .embed || entry.remoteURL == nil)
                    .accessibilityIdentifier("treasure-target-" + entry.id)
                }
            }
            Section {
                if !ids.isEmpty {
                    Text("本次实际播放 \(ids.count) 项\(ids.count < options.count ? "，不足所选数量，播放到列表末尾停止" : "")")
                        .accessibilityIdentifier("treasure-planned-count")
                }
                Button(options.autoPlay ? "确认并播放" : "确认并保存") {
                    options.confirmed = true
                    confirm(options.autoPlay)
                    dismiss()
                }.disabled(ids.isEmpty).accessibilityIdentifier("treasure-confirm-target")
            }
        }
        .searchable(text: $query, prompt: "搜索标题或来源")
        .navigationTitle("定向播放与背景")
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("完成") { dismiss() }.accessibilityIdentifier("treasure-settings-close")
        } }
    }
}

@MainActor
private final class TreasureSequenceSession: ObservableObject {
    @Published var player: AVPlayer?
    @Published var current: MediaEntry?
    @Published var playing = false
    @Published var index = 0
    @Published var message = ""
    private var ids: [String] = []
    private var options = TreasurePlaybackOptions()
    private var lookup: ((String) -> MediaEntry?)?
    private var imageTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var audioObservers: [NSObjectProtocol] = []
    private var audioOwned = false
    private var wantsPlaying = false
    private var loadingAsset: AVURLAsset?
    private var remaining = 0.0
    private var imageStarted: Date?

    func start(_ request: TreasurePlaybackRequest, lookup: @escaping (String) -> MediaEntry?) {
        stop()
        ids = request.ids; options = request.options; self.lookup = lookup; index = 0
        audioObservers = [
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue == AVAudioSession.InterruptionType.began.rawValue
                if began { Task { @MainActor in self?.pause() } }
            },
            NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let unplugged = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if unplugged { Task { @MainActor in self?.pause() } }
            }
        ]
        open()
    }
    private func open() {
        stopItem()
        guard ids.indices.contains(index) else { message = "本次播放完成"; current = nil; return }
        guard let entry = lookup?(ids[index]) else { message = "目标已删除，请关闭后重新选择。"; current = nil; return }
        current = entry; message = ""; wantsPlaying = true
        guard let url = entry.remoteURL, entry.kind != .embed else { message = "当前目标不可播放，请重新选择。"; return }
        if entry.kind == .image {
            remaining = options.imageSeconds; playing = true; scheduleImage()
        } else {
            let expectedID = entry.id
            loadTask = Task { @MainActor [weak self] in
                let asset = AVURLAsset(url: url)
                self?.loadingAsset = asset
                let valid = (try? await asset.load(.isPlayable)) == true
                guard !Task.isCancelled, let self, self.current?.id == expectedID else { return }
                guard valid else { self.message = "此来源无法直接播放，请重新选择。"; return }
                self.loadingAsset = nil
                var audioAvailable = self.wantsPlaying
                do {
                    guard self.wantsPlaying else { throw CancellationError() }
                    // soloAmbient honors Ring/Silent and never mixes a second
                    // soundtrack over this sequence. No background entitlement.
                    try AVAudioSession.sharedInstance().setCategory(.soloAmbient, mode: .default)
                    try AVAudioSession.sharedInstance().setActive(true)
                    self.audioOwned = true
                } catch {
                    if self.wantsPlaying { self.message = "音频会话不可用，将静音播放。" }
                    audioAvailable = false
                }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.isMuted = !audioAvailable || self.options.sound == .muted
                player.volume = Float(self.options.volume / 100)
                self.player = player
                self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.current?.id == expectedID, self.playing else { return }
                        self.next()
                    }
                }
                self.playing = self.wantsPlaying
                if self.playing { player.play() }
            }
        }
    }
    private func scheduleImage() {
        imageTask?.cancel(); imageStarted = .now
        imageTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, self.remaining) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.next()
        }
    }
    func togglePause() {
        guard current != nil else { return }
        playing.toggle(); wantsPlaying = playing
        if let player {
            if playing {
                if !audioOwned {
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.soloAmbient, mode: .default)
                        try AVAudioSession.sharedInstance().setActive(true)
                        audioOwned = true
                    } catch { message = "音频会话不可用，将静音播放。" }
                }
                player.isMuted = !audioOwned || options.sound == .muted
                player.play()
            } else { player.pause() }
        }
        else if current?.kind == .image {
            if playing { scheduleImage() }
            else {
                if let imageStarted { remaining = max(0.05, remaining - Date().timeIntervalSince(imageStarted)) }
                imageTask?.cancel(); imageTask = nil; imageStarted = nil
            }
        }
    }
    func pause() { wantsPlaying = false; if playing { togglePause() } }
    func next() { index += 1; open() }
    func validate(_ available: Set<String>) {
        if let id = current?.id, !available.contains(id) { stop(); message = "当前目标已删除，请重新选择。" }
    }
    private func stopItem() {
        loadingAsset?.cancelLoading(); loadingAsset = nil
        loadTask?.cancel(); loadTask = nil
        imageTask?.cancel(); imageTask = nil; imageStarted = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        playing = false
        if audioOwned {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioOwned = false
        }
    }
    func stop() {
        wantsPlaying = false; stopItem()
        audioObservers.forEach { NotificationCenter.default.removeObserver($0) }; audioObservers.removeAll()
        current = nil; lookup = nil; message = "已停止"
    }
}

struct TreasureDirectedPlayer: View {
    let request: TreasurePlaybackRequest
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var session = TreasureSequenceSession()
    var body: some View {
        VStack(spacing: 12) {
            Text("定向播放 · \(min(session.index + 1, request.ids.count))/\(request.ids.count)")
                .font(.headline).accessibilityIdentifier("treasure-sequence-position")
            if let player = session.player { FillVideoPlayer(player: player, showsControls: false) }
            else if let entry = session.current, entry.kind == .image, let url = entry.remoteURL {
                if url.isFileURL { LocalMediaImage(url: url) }
                else { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() } }
            } else { Text(session.message.isEmpty ? "正在准备播放" : session.message).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if !session.message.isEmpty { Text(session.message).font(.caption).accessibilityIdentifier("treasure-sequence-message") }
            HStack {
                Button(session.playing ? "暂停" : "继续") { session.togglePause() }
                    .disabled(session.current == nil || (session.current?.kind == .video && session.player == nil)).accessibilityIdentifier("treasure-sequence-pause")
                Button("下一条") { session.next() }.disabled(session.current == nil)
                    .accessibilityIdentifier("treasure-sequence-next")
                Button("停止") { session.stop() }.accessibilityIdentifier("treasure-sequence-stop")
                Button("完成") { session.stop(); dismiss() }.accessibilityIdentifier("treasure-sequence-close")
            }.frame(minHeight: 44).buttonStyle(.plain).padding(10).moonSingleGlass()
        }.padding().background { TreasureBackgroundSurface(options: request.options).ignoresSafeArea() }
            .preferredColorScheme(request.options.background == .system ? nil :
                (request.options.background == .purple || request.options.red * 0.2126 + request.options.green * 0.7152 + request.options.blue * 0.0722 < 0.5 ? .dark : .light))
            .onAppear { session.start(request) { id in model.mediaStore.items.first { $0.id == id } } }
            .onDisappear { session.stop() }
            .onChange(of: phase) { value in if value != .active { session.pause() } }
            .onChange(of: model.mediaStore.items.map(\.id)) { session.validate(Set($0)) }
    }
}
