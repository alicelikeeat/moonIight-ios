import SwiftUI

private struct CardLayout: Equatable, Sendable {
    let card: Int
    let rect: CGRect
    let viewport: CGRect
    let role: CardPreviewRole
    let z: Int
}
private struct CardLayoutKey: PreferenceKey {
    static let defaultValue: [CardLayout] = []
    static func reduce(value: inout [CardLayout], nextValue: () -> [CardLayout]) { value += nextValue() }
}

struct LandlordGameView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store = LandlordGameStore()
    @StateObject private var media = CardMediaCoordinator()
    @State private var settings = false
    @State private var history = false
    @State private var focus: LandlordCard?
    @State private var layouts: [CardLayout] = []
    @State private var present = false
    @State private var diagnostic = ""
    @Namespace private var movement
    private var assets: [MediaEntry] { model.mediaStore.items.filter { $0.kind != .embed } }
    private var mapping: CardMediaMapping { store.mapping }
    private func name(_ player: Int) -> String { ["我", "右家", "左家"][player] }
    var body: some View {
        GeometryReader { outer in
            let viewport = outer.frame(in: .global)
            ZStack {
                VStack(spacing: 8) {
                    header
                    opponents
                    pile(viewport: viewport).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(status).font(.callout).accessibilityIdentifier("landlord-status").padding(.horizontal)
                    if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.secondary) }
                    if !media.notice.isEmpty { Text(media.notice).font(.caption).foregroundStyle(.secondary) }
                    hand(viewport: viewport)
                    controls
                }
                if let focus {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Text("\(focus.label) · 牌面预览").font(.headline)
                        face(focus, role: .focus, z: 10000, viewport: viewport, width: 240, height: 340)
                        Button(media.audible ? "关闭声音" : "开启声音") { media.toggleSound() }
                            .accessibilityIdentifier("landlord-focus-sound").frame(minHeight: 44)
                        Button("关闭预览") { self.focus = nil; media.mute() }.frame(minHeight: 44).accessibilityIdentifier("landlord-focus-close")
                    }.buttonStyle(MoonGlassButtonStyle()).padding()
                }
            }
            .onPreferenceChange(CardLayoutKey.self) { values in layouts = values; updateVisibility() }
        }
        .accessibilityIdentifier("landlord-table")
        .onAppear {
            present = true
            store.preferences.normalize(available: Set(assets.map(\.id)))
            store.activate(scenePhase == .active); configureMedia()
        }
        .onDisappear { present = false; store.activate(false); media.dispose() }
        .onChange(of: scenePhase) { phase in
            store.activate(present && phase == .active)
            if phase != .active { media.stop() } else { configureMedia(); updateVisibility() }
        }
        .onChange(of: store.game.id) { _ in focus = nil; media.stop(clear: true); configureMedia(); updateVisibility() }
        .onChange(of: store.preferences) { _ in
            store.preferences.normalize(available: Set(assets.map(\.id)))
            store.persist()
            if store.preferences.style == .classic { media.stop(clear: true) }
            configureMedia(); updateVisibility()
        }
        .onChange(of: assets) { _ in store.preferences.normalize(available: Set(assets.map(\.id))); configureMedia(); updateVisibility() }
        .onChange(of: store.automatic) { _ in store.refresh() }
        .onChange(of: focus?.id) { _ in updatePause(); media.mute(); updateVisibility() }
        .onChange(of: settings) { _ in updatePause(); configureMedia(); updateVisibility() }
        .onChange(of: history) { _ in updatePause(); configureMedia(); updateVisibility() }
        .sheet(isPresented: $settings) { mediaSettings }
        .sheet(isPresented: $history) { historySheet }
        .overlay(alignment: .topLeading) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") {
                Text("对局测试状态").font(.system(size: 1)).frame(height: 1).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("landlord-probe").accessibilityValue(diagnostic)
            }
            #endif
        }
        .task {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") else { return }
            while !Task.isCancelled {
                diagnostic = "players=\(media.decoderCount);advancing=\(media.advancing);frames=\(media.renderedFrames);muted=\(media.muted ? 1 : 0);cache=\(media.cacheBytes);history=\(store.game.history.count);cards=\(store.game.hands.flatMap { $0 }.count);phase=\(store.game.phase.rawValue);valid=\(store.game.conserved ? 1 : 0)"
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            #endif
        }
    }
    private var header: some View {
        HStack {
            Text("三人单机").font(.headline)
            Spacer()
            Button("牌面") { settings = true }.accessibilityIdentifier("landlord-settings")
            Button("记录") { history = true }.accessibilityIdentifier("landlord-history")
            Button("新一局") { store.newGame() }.accessibilityIdentifier("landlord-new-game")
        }.frame(minHeight: 44).buttonStyle(MoonGlassButtonStyle()).padding(.horizontal, 12)
    }
    private var opponents: some View {
        HStack {
            ForEach([2, 1], id: \.self) { player in
                Text("\(name(player))\(store.game.landlord == player ? " · 地主" : " · 农民") · \(store.game.hands[player].count) 张\(store.game.turn == player ? " · 行动中" : "")")
                    .font(.caption).padding(10).frame(maxWidth: .infinity).moonSingleGlass(radius: 12)
            }
        }.padding(.horizontal, 12)
    }
    private var status: String {
        let game = store.game
        switch game.phase {
        case .bidding: return "\(name(game.turn))叫分 · 当前 \(game.highestBid) 分"
        case .playing: return "\(name(game.turn))出牌 · 第 \(game.trick) 轮 · \(game.highestBid) 分 × \(game.multiplier)\(game.landlord == 0 ? " · 我是地主" : " · 我是农民")"
        case .redeal: return "三家不叫，请重新发牌。"
        case .finished: return "\(game.winner == game.landlord ? "地主" : "农民")获胜\(game.spring ? " · 春天" : "") · 我：\(game.scores[0]) 分（虚拟积分）"
        }
    }
    private func pile(viewport: CGRect) -> some View {
        GeometryReader { geometry in
            let groups = Array(store.game.history.suffix(3))
            ZStack(alignment: .topLeading) {
                if groups.isEmpty { Text("出牌后按实际顺序叠放于此").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                ForEach(Array(groups.enumerated()), id: \.element.id) { level, group in
                    pileGroup(group, level: level, top: level == groups.count - 1,
                              size: geometry.size, viewport: viewport.intersection(geometry.frame(in: .global)))
                }
            }
        }.padding(.horizontal, 12).clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.game.history.count)
    }
    private func pileGroup(_ group: LandlordPlay, level: Int, top: Bool, size: CGSize, viewport: CGRect) -> some View {
        let cardWidth: CGFloat = 62
        let spaces: CGFloat = CGFloat(max(1, group.cards.count - 1))
        let available: CGFloat = size.width - cardWidth - 16
        let step: CGFloat = min(CGFloat(34), max(CGFloat(5), available / spaces))
        let yStep: CGFloat = min(CGFloat(58), max(CGFloat(22), (size.height - 112) / 2))
        return VStack(alignment: .leading, spacing: 3) {
            Text(groupTitle(group)).font(.caption2).padding(3)
                .background(Color(uiColor: .systemBackground), in: Capsule())
            ZStack(alignment: .topLeading) {
                ForEach(Array(group.cards.enumerated()), id: \.element.id) { index, card in
                    face(card, role: top ? .central : .other, z: group.id * 100 + index + 100,
                         viewport: viewport, width: cardWidth, height: 88)
                        .matchedGeometryEffect(id: card.id, in: movement)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 2)
                        .offset(x: CGFloat(index) * step).zIndex(Double(index))
                        .onTapGesture { focus = card }
                }
            }.frame(width: max(1, size.width - 16), height: 88, alignment: .leading)
        }.offset(x: CGFloat(level) * 3 + 4, y: CGFloat(level) * yStep).zIndex(Double(level))
    }
    private func groupTitle(_ group: LandlordPlay) -> String {
        name(group.player) + " · 第 " + String(group.trick) + " 轮 · " + group.pattern.title
    }
    private func hand(viewport: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("我的手牌 · \(store.game.hands[0].count) 张\(store.game.landlord == 0 ? " · 地主" : "") · 长按预览")
                .font(.caption).padding(.horizontal, 12)
            ScrollView(.horizontal) {
                HStack(spacing: -12) {
                    ForEach(Array(store.game.hands[0].enumerated()), id: \.element.id) { index, card in
                        face(card, role: .hand, z: index, viewport: viewport, width: 66, height: 96)
                            .overlay { if store.selection.contains(card.id) { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3) } }
                            .matchedGeometryEffect(id: card.id, in: movement, isSource: true)
                            .offset(y: store.selection.contains(card.id) ? -9 : 0)
                            .onTapGesture { store.choose(card.id) }
                            .onLongPressGesture { focus = card }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityValue(store.selection.contains(card.id) ? "已选" : "未选")
                            .accessibilityAction(named: "预览") { focus = card }
                            .accessibilityIdentifier("landlord-hand-\(card.id)")
                            .zIndex(Double(index))
                    }
                }.padding(.horizontal, 14).padding(.vertical, 12)
            }.frame(height: 122).accessibilityIdentifier("landlord-hand")
        }
    }
    private func face(_ card: LandlordCard, role: CardPreviewRole, z: Int, viewport: CGRect, width: CGFloat, height: CGFloat) -> some View {
        let id = store.preferences.style == .media ? mapping.assignments[card.id] : nil
        return LandlordCardFace(card: card, feed: id.map { media.feed($0) })
            .frame(width: width, height: height)
            .background { GeometryReader { geometry in
                Color.clear.preference(key: CardLayoutKey.self, value: [CardLayout(card: card.id, rect: geometry.frame(in: .global), viewport: viewport, role: role, z: z)])
            } }
    }
    private var controls: some View {
        VStack(spacing: 4) {
            HStack {
                if store.game.phase == .bidding {
                    ForEach(0...3, id: \.self) { bid in
                        Button(bid == 0 ? "不叫" : "\(bid) 分") { store.bid(bid) }
                            .disabled(store.game.turn != 0 || (bid > 0 && bid <= store.game.highestBid))
                            .accessibilityIdentifier("landlord-bid-\(bid)")
                    }
                } else if store.game.phase == .playing {
                    Button("提示") { store.hint() }.accessibilityIdentifier("landlord-hint")
                    Button("不出") { store.pass() }.disabled(store.game.target == nil).accessibilityIdentifier("landlord-pass")
                    Button("出牌") { store.play() }.disabled(store.selection.isEmpty).accessibilityIdentifier("landlord-play")
                }
            }.disabled(store.game.turn != 0 || store.automatic).frame(minHeight: 44)
            HStack { Text("托管我的手牌").font(.caption); Spacer(); Toggle("托管我的手牌", isOn: $store.automatic).labelsHidden().frame(width: 51, height: 44).accessibilityIdentifier("landlord-auto") }.padding(.horizontal, 12)
        }.buttonStyle(MoonGlassButtonStyle()).padding(.horizontal, 12).padding(.bottom, 6)
    }
    private var mediaSettings: some View {
        NavigationStack {
            Form {
                Picker("牌面样式", selection: $store.preferences.style) {
                    Text("经典牌面").tag(CardFaceStyle.classic); Text("媒体牌面").tag(CardFaceStyle.media)
                }.pickerStyle(.segmented).accessibilityIdentifier("landlord-style")
                Toggle("素材不足时循环复用", isOn: $store.preferences.cycle)
                Stepper("动态预览：\(store.preferences.budget) 路", value: $store.preferences.budget, in: 0...2)
                    .accessibilityIdentifier("landlord-budget")
                Text("默认静音循环播放。动态预算最多 2 路，同一素材共用解码；被完全遮挡的牌保留快照。3–4 路需真实 iPhone 压测后再开放。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重新启用动态预览") { media.retry() }
                Section("选择图片或视频（\(store.preferences.mediaIDs.count)/54）") {
                    if assets.isEmpty { Text("请先在库中导入图片或视频；缺失素材自动显示经典牌面。") }
                    ForEach(assets) { entry in
                        Button {
                            if store.preferences.mediaIDs.contains(entry.id) { store.preferences.mediaIDs.removeAll { $0 == entry.id } }
                            else if store.preferences.mediaIDs.count < 54 { store.preferences.mediaIDs.append(entry.id) }
                        } label: {
                            HStack {
                                Image(systemName: entry.kind == .video ? "video" : "photo")
                                Text(entry.title).lineLimit(2)
                                Spacer()
                                if store.preferences.mediaIDs.contains(entry.id) { Image(systemName: "checkmark") }
                            }.frame(minHeight: 44)
                        }.accessibilityIdentifier("landlord-media-\(entry.id)")
                    }
                }
            }.navigationTitle("斗地主牌面").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false }.accessibilityIdentifier("landlord-settings-done") } }
        }
    }
    private var historySheet: some View {
        NavigationStack {
            List {
                Section("本局 \(store.game.history.count) 手 · 静态记录") {
                    ForEach(store.game.history, id: \.id) { (group: LandlordPlay) in
                        historyRow(group)
                    }
                }
                Section("最近三局虚拟积分") {
                    ForEach(Array(store.summaries.enumerated()), id: \.offset) { _, score in Text("我 \(score[0]) · 右家 \(score[1]) · 左家 \(score[2])") }
                }
            }.navigationTitle("对局记录").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { history = false } } }
        }
    }
    private func historyRow(_ group: LandlordPlay) -> some View {
        VStack(alignment: .leading) {
            Text(groupTitle(group)).font(.caption)
            Text(group.cards.map { $0.label }.joined(separator: " "))
        }
    }
    private func updatePause() { store.paused = focus != nil || settings || history; store.refresh() }
    private func configureMedia() {
        media.configure(entries: assets, requested: store.preferences.budget,
                        active: present && scenePhase == .active && store.preferences.style == .media && !settings && !history)
    }
    private func updateVisibility() {
        guard store.preferences.style == .media else { media.update([], focus: nil); return }
        let valid = Set(assets.map(\.id))
        let source = layouts.filter { focus == nil ? $0.role != .focus : $0.role == .focus }
        var best: [Int: CardMediaCandidate] = [:]
        for layout in source {
            guard let id = mapping.assignments[layout.card], valid.contains(id) else { continue }
            let clipped = layout.rect.intersection(layout.viewport)
            let covers = source.filter { $0.z > layout.z && $0.role != .focus }.map { $0.rect.intersection($0.viewport) }.filter { !$0.isNull }
            let area = clipped.isNull ? 0 : CardMediaPolicy.visibleArea(clipped, coveredBy: covers)
            let visibility: CardVisibility = area <= 1 ? .hidden : area < layout.rect.width * layout.rect.height - 1 ? .partial : .visible
            let candidate = CardMediaCandidate(cardID: layout.card, mediaID: id, role: layout.role, z: layout.z, visibility: visibility)
            if best[layout.card].map({ $0.role.rawValue < candidate.role.rawValue || $0.z < candidate.z }) ?? true { best[layout.card] = candidate }
        }
        media.update(Array(best.values), focus: focus?.id)
    }
}
private struct LandlordCardFace: View {
    let card: LandlordCard
    let feed: CardMediaFrameFeed?
    var body: some View {
        ZStack(alignment: .topLeading) {
            MoonGlassBackdrop(radius: 10)
            if let feed { LandlordCardFrame(feed: feed).clipShape(RoundedRectangle(cornerRadius: 10)) }
            VStack(alignment: .leading, spacing: 0) { Text(card.rankText).font(.system(size: card.rank >= 16 ? 13 : 19, weight: .bold)); Text(card.suitText).font(.headline) }
                .foregroundStyle(card.isRed ? Color.red : Color.primary)
                .padding(4).background(Color(uiColor: .systemBackground).opacity(0.95), in: RoundedRectangle(cornerRadius: 6)).padding(3)
        }.accessibilityElement(children: .ignore).accessibilityLabel(card.label)
    }
}
private struct LandlordCardFrame: View {
    @ObservedObject var feed: CardMediaFrameFeed
    var body: some View {
        GeometryReader { geometry in
            if let image = feed.image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
