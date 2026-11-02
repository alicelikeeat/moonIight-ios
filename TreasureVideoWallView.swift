import AVFoundation
import SwiftUI
import UIKit

struct TreasureVideoWallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @StateObject private var coordinator = TreasurePlaybackCoordinator()
    @AppStorage("treasure-wall-selection-v23") private var savedSelection = Data()
    @AppStorage("treasure-wall-mode-v23") private var savedMode = TreasureWallMode.sequential.rawValue
    @AppStorage("treasure-wall-loop-v23") private var savedLoop = false
    @AppStorage("treasure-wall-muted-v23") private var savedMuted = false
    @State private var selecting = false
    @State private var diagnosticValue = ""
    private var videos: [MediaEntry] { TreasureRules.unique(model.mediaStore.items.filter { TreasurePlaybackCoordinator.playable($0) }, id: \.id) }
    private func entry(_ id: String) -> MediaEntry? { videos.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 12) {
            controls
            Text(coordinator.message).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("wall-message")
            if coordinator.selection.recoveredOverflow {
                Text("旧记录超过 10 个，已保留前 10 个视频。")
                    .font(.caption).accessibilityIdentifier("wall-restored-limit-notice")
            }
            if coordinator.mode == .simultaneous && coordinator.selection.ids.count > coordinator.decoderLimit {
                Text("已选视频均保留；当前最多加载 \(coordinator.decoderLimit) 路可见画面，滚动可切换。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    .accessibilityIdentifier("wall-performance-notice")
            }
            stage
        }
        .sheet(isPresented: $selecting) {
            NavigationStack {
                TreasureVideoSelector(coordinator: coordinator, videos: videos)
            }
        }
        .onAppear { coordinator.activate(items: model.mediaStore.items, data: savedSelection, mode: savedMode, loop: savedLoop, muted: savedMuted) }
        .onDisappear { coordinator.shutdown() }
        .onChange(of: model.mediaStore.items) { coordinator.update($0) }
        .onChange(of: coordinator.selection) { savedSelection = (try? JSONEncoder().encode($0)) ?? Data() }
        .onChange(of: coordinator.mode) { savedMode = $0.rawValue; coordinator.changeMode() }
        .onChange(of: coordinator.loop) { savedLoop = $0 }
        .onChange(of: coordinator.muted) { savedMuted = $0; coordinator.refreshAudio() }
        .onChange(of: phase) { if $0 != .active { coordinator.suspend("已暂停；回到前台后点击播放，从当前视频开头恢复。") } }
        .overlay(alignment: .bottomLeading) { diagnostics }
        .task { await updateDiagnostics() }
    }
    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button("选择视频 · \(coordinator.selection.ids.count)/10") { selecting = true }
                    .accessibilityIdentifier("wall-select")
                Spacer()
                HStack(spacing: 8) {
                    Text("循环")
                    Toggle("循环", isOn: $coordinator.loop).labelsHidden().frame(width: 51, height: 44)
                        .accessibilityIdentifier("wall-loop")
                }.fixedSize()
            }
            Picker("播放模式", selection: $coordinator.mode) {
                ForEach(TreasureWallMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("wall-mode")
            HStack {
                Button(coordinator.playing ? "暂停" : "播放") {
                    if coordinator.playing { coordinator.pause() } else { coordinator.play() }
                }.disabled(coordinator.selection.ids.isEmpty).accessibilityIdentifier("wall-play-pause")
                Button("停止") { coordinator.stop() }.accessibilityIdentifier("wall-stop")
                Spacer()
                HStack(spacing: 8) {
                    Text("全部静音")
                    Toggle("全部静音", isOn: $coordinator.muted).labelsHidden().frame(width: 51, height: 44)
                        .accessibilityIdentifier("wall-muted")
                }.fixedSize()
            }
        }.buttonStyle(MoonGlassButtonStyle()).frame(minHeight: 44).padding(12).moonSingleGlass().padding(.horizontal, 14)
    }
    @ViewBuilder private var stage: some View {
        if coordinator.selection.ids.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.split.2x2").font(.largeTitle)
                Text("选择视频后点击播放").font(.headline)
                Text("默认目标 4 个，可选 1–10 个；当前库内可用 \(videos.count) 个。不会自动添加媒体。")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let id = coordinator.focusedID, let item = entry(id) {
            ScrollView {
                VStack {
                    Button("返回网格") { coordinator.focus(nil) }.buttonStyle(MoonGlassButtonStyle())
                        .accessibilityIdentifier("wall-unfocus")
                    tile(item)
                }.padding(14)
            }.accessibilityIdentifier("wall-focused")
        } else if coordinator.mode == .simultaneous {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: TreasureWallPolicy.columns(coordinator.selection.ids.count)), spacing: 8) {
                    ForEach(coordinator.selection.ids, id: \.self) { id in
                        if let item = entry(id) {
                            tile(item).background {
                                WallVisibilityMarker { visible in coordinator.setVisible(id, visible) }
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                    }
                }.padding(14)
            }
            .onDisappear { coordinator.setVisible([]) }
            .accessibilityIdentifier("wall-grid")
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    if let id = coordinator.currentID ?? coordinator.selection.ids.first, let item = entry(id) { tile(item) }
                    Text("队列：\(coordinator.selection.ids.compactMap { entry($0)?.title }.joined(separator: " → "))")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }.padding(14)
            }.accessibilityIdentifier("wall-single")
        }
    }
    private func tile(_ entry: MediaEntry) -> some View {
        TreasureWallTile(entry: entry, player: coordinator.players[entry.id], state: coordinator.states[entry.id] ?? "待播放",
            audible: coordinator.audioID == entry.id, open: { coordinator.focus(entry.id) }, sound: { coordinator.setAudio(entry.id) })
    }
    @ViewBuilder private var diagnostics: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") {
            Text("视频墙测试状态").font(.system(size: 1)).frame(height: 1).opacity(0.01)
                .accessibilityIdentifier("wall-probe")
                .accessibilityValue(diagnosticValue)
                .allowsHitTesting(false)
        }
        #endif
    }
    private func updateDiagnostics() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--treasure-wall-ui-tests") else { return }
        while !Task.isCancelled {
            let values: [String: Int] = ["selected": coordinator.selection.ids.count, "players": coordinator.players.count,
                "audible": coordinator.players.values.filter { !$0.isMuted }.count,
                "limit": coordinator.decoderLimit, "playing": coordinator.playing ? 1 : 0,
                "loop": coordinator.loop ? 1 : 0, "muted": coordinator.muted ? 1 : 0,
                "advancing": coordinator.players.values.filter { $0.rate > 0 && $0.currentTime().seconds > 0.05 }.count]
            diagnosticValue = String(data: (try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys)) ?? Data(), encoding: .utf8) ?? ""
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        #endif
    }

}

/// Native scroll observation avoids treating LazyVGrid prefetch as visibility.
private struct WallVisibilityMarker: UIViewRepresentable {
    let changed: (Bool) -> Void
    func makeUIView(context: Context) -> WallVisibilityView { let view = WallVisibilityView(); view.changed = changed; return view }
    func updateUIView(_ view: WallVisibilityView, context: Context) { view.changed = changed; view.setNeedsLayout() }
    static func dismantleUIView(_ view: WallVisibilityView, coordinator: ()) { view.detach() }
}
private final class WallVisibilityView: UIView {
    var changed: ((Bool) -> Void)?
    private weak var scroll: UIScrollView?
    private var observation: NSKeyValueObservation?
    private var lastVisible = false
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
    override func layoutSubviews() {
        super.layoutSubviews()
        var parent = superview
        var enclosing: UIScrollView?
        while let view = parent { if let value = view as? UIScrollView { enclosing = value; break }; parent = view.superview }
        if scroll !== enclosing {
            observation?.invalidate(); scroll = enclosing
            observation = enclosing?.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.measure() }
            }
        }
        measure()
    }
    private func measure() {
        guard let window, let scroll else { emit(false); return }
        let frame = convert(bounds, to: window)
        let viewport = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
        let intersection = frame.intersection(viewport)
        let visible = !isHidden && frame.width > 0 && frame.height > 0 && !intersection.isNull && intersection.width * intersection.height > frame.width * frame.height * 0.2
        emit(visible)
    }
    private func emit(_ visible: Bool) {
        guard lastVisible != visible else { return }
        lastVisible = visible
        Task { @MainActor [weak self] in
            guard let self, self.lastVisible == visible else { return }
            self.changed?(visible)
        }
    }
    func detach() {
        observation?.invalidate(); observation = nil; lastVisible = false
        let callback = changed; changed = nil
        Task { @MainActor in callback?(false) }
    }
}

private struct TreasureVideoSelector: View {
    @ObservedObject var coordinator: TreasurePlaybackCoordinator
    let videos: [MediaEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var matches: [MediaEntry] { videos.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.platform.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Section {
                Stepper("目标 \(coordinator.selection.target) 个", value: Binding(get: { coordinator.selection.target }, set: { coordinator.setTarget($0) }), in: 1...10)
                    .accessibilityIdentifier("wall-target-count")
                Text("已选 \(coordinator.selection.ids.count)/10 · 最多 10 个不同视频，选择顺序即播放顺序。")
                    .accessibilityIdentifier("wall-selection-count")
                Button("清空选择") { coordinator.clear() }.accessibilityIdentifier("wall-clear")
                Text(coordinator.message).font(.caption).foregroundStyle(.secondary)
                if coordinator.selection.ids.count == 10 { Text("已达 10 个上限；取消一项后可继续选择。").accessibilityIdentifier("wall-limit-notice") }
            }
            Section("可播放视频（\(matches.count)）") {
                if matches.isEmpty { Text("没有可用视频，请先导入视频或调整搜索词。") }
                ForEach(matches) { item in
                    let index = coordinator.selection.ids.firstIndex(of: item.id)
                    Button { coordinator.toggle(item.id) } label: {
                        HStack {
                            if let url = item.coverURL {
                                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "video") }
                                    .frame(width: 48, height: 48).clipped()
                            } else { Image(systemName: "video").frame(width: 48, height: 48) }
                            Text(item.title).lineLimit(2)
                            Spacer()
                            Text(index.map { "\($0 + 1)" } ?? "")
                            Image(systemName: index == nil ? "circle" : "checkmark.circle.fill")
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(index == nil && coordinator.selection.ids.count >= 10)
                    .accessibilityIdentifier("wall-pick-" + item.id)
                    .accessibilityValue(index == nil ? "未选择" : "已选择")
                }
            }
        }.searchable(text: $query, prompt: "搜索视频标题或来源")
            .navigationTitle("选择视频")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("wall-selection-done") } }
    }
}

private struct TreasureWallTile: View {
    let entry: MediaEntry
    let player: AVPlayer?
    let state: String
    let audible: Bool
    let open: () -> Void
    let sound: () -> Void
    var body: some View {
        VStack(spacing: 4) {
            Button(action: open) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit).overlay {
                    if let player { TreasureWallVideoSurface(player: player) }
                    else if let url = entry.coverURL {
                        AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Image(systemName: "video") }
                    } else { Image(systemName: "video").font(.title) }
                    if state == "加载中" { ProgressView() }
                }.frame(maxWidth: .infinity, minHeight: 44).clipped().contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("放大 " + entry.title).accessibilityIdentifier("wall-tile-" + entry.id)
            Text(entry.title).font(.caption).lineLimit(2)
            if player == nil || state != "就绪" { Text(state).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
            Button(action: sound) { Label(audible ? "当前音轨" : "选择音轨", systemImage: audible ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.caption2).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                .buttonStyle(.plain).accessibilityIdentifier("wall-audio-" + entry.id)
        }.padding(6).moonSingleGlass(radius: 16)
    }
}

private struct TreasureWallVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> WallVideoLayerView { let view = WallVideoLayerView(); view.isUserInteractionEnabled = false; view.layerPlayer.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: WallVideoLayerView, context: Context) { view.layerPlayer.player = player }
    static func dismantleUIView(_ view: WallVideoLayerView, coordinator: ()) { view.layerPlayer.player = nil }
}
private final class WallVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
