import SwiftUI
import AudioToolbox

/// Keeps the established entrance and legacy table, while the new table owns
/// its full-screen orientation scope and lifecycle.
struct LandlordGameView: View {
    @State private var presented = false
    @State private var opened = false
    @State private var legacy = false
    var body: some View {
        if legacy || ProcessInfo.processInfo.arguments.contains("--landlord-ui-tests") {
            LegacyLandlordGameView()
        } else {
            VStack(spacing: 16) {
                Image(systemName: "suit.spade.fill").font(.largeTitle).foregroundStyle(.teal)
                Text("Liquid Glass 斗地主").font(.title2.bold())
                Text("三人单机 · 横竖屏 · 明牌练习 · 单癞子").font(.callout).foregroundStyle(.secondary)
                Button("进入全屏牌桌") { presented = true }.buttonStyle(.moonLiquidProminent).accessibilityIdentifier("landlord-enter")
                Button("使用旧版牌桌") { legacy = true }.buttonStyle(.moonLiquid)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { if !opened { opened = true; presented = true } }
                .fullScreenCover(isPresented: $presented) { LandlordLiquidTable { presented = false } }
        }
    }
}

private enum LandlordPanel: Hashable, Identifiable {
    case settings, history, hand(Int), pile(Int), profile(Int), rules, allCards
    var id: String { String(describing: self) }
}

struct LandlordLiquidTable: View {
    let close: () -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store = LandlordGameStore()
    @StateObject private var media = CardMediaCoordinator()
    @State private var panel: LandlordPanel?
    @State private var newGameConfirmation = false
    @State private var newGameAfterPanel = false
    @State private var inspectionFocus: Int?
    @State private var initialInspection: Int?
    @State private var placements: [LandlordMediaPlacement] = []
    @State private var viewport = CGRect.zero
    @State private var visible = false
    @State private var dealt = false
    @State private var effect: String?
    @State private var orientationID = UUID()
    @State private var selectionOrigin: [Int]?
    @State private var visited: Set<Int> = []
    @State private var handWidth: CGFloat = 320
    @State private var diagnostic = ""
    @State private var mediaFixtureReady = false
    @State private var tableViewport = CGRect.zero
    @State private var suppressTapUntil: TimeInterval = 0
    @GestureState private var handDragging = false
    @Namespace private var movement
    private var assets: [MediaEntry] { app.mediaStore.items.filter { $0.kind != .embed && $0.remoteURL?.isFileURL == true } }
    private var animate: Bool { store.table.animations && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                LinearGradient(colors: [.teal.opacity(0.12), .clear, .indigo.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                if !landscape && geometry.size.height < 650 {
                    ScrollView { portrait.frame(height: 640) }
                } else if landscape { horizontal }
                else { portrait }
                if let effect, animate {
                    Text(effect).font(.title2.bold()).padding(20).moonSingleGlass(radius: 24)
                        .shadow(radius: 10).allowsHitTesting(false).transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .onAppear { viewport = geometry.frame(in: .global) }
            .onChange(of: geometry.frame(in: .global)) { viewport = $0; refreshMedia() }
            .accessibilityValue(landscape ? "横屏" : "竖屏")
            .accessibilityIdentifier("landlord-liquid-layout")
        }
        .onPreferenceChange(LandlordMediaPlacementKey.self) { placements = $0; refreshMedia() }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--landlord-media-ui-tests") {
                var imported: [String] = []
                for name in ["kn_adventurer_walk", "kn_female_walk", "kn_player_walk"] {
                    if let url = Bundle.main.url(forResource: name, withExtension: "gif", subdirectory: "Glass3DStarter"),
                       let entry = await app.mediaStore.importLocalFile(url, title: name, kind: .image) { imported.append(entry.id) }
                }
                if imported.count == 3 {
                    store.preferences.mediaIDs = imported; store.preferences.style = .media
                    for i in 0..<3 { store.table.profiles[i].avatarMediaID = imported[i] }
                    mediaFixtureReady = true; configureMedia(); refreshMedia()
                }
            }
            guard ProcessInfo.processInfo.arguments.contains("--landlord-liquid-ui-tests") else { return }
            while !Task.isCancelled {
                diagnostic = "phase=\(store.game.phase.rawValue);valid=\(store.game.validated ? 1 : 0);history=\(store.game.history.count);cards=\(store.game.hands.flatMap { $0 }.count);wild=\(store.game.wildcardRank ?? 0);players=\(media.decoderCount);frames=\(media.renderedFrames);fixture=\(mediaFixtureReady ? 1 : 0)"
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            #endif
        }
        .onAppear {
            visible = true
            MoonlightOrientationDelegate.beginLandlord(orientationID)
            store.activate(phase == .active); configureMedia(); deal()
        }
        .onDisappear {
            visible = false; store.activate(false); media.dispose()
            MoonlightOrientationDelegate.endLandlord(orientationID)
        }
        .onChange(of: phase) { value in
            selectionOrigin = nil; visited = []
            store.activate(value == .active && visible)
            if value != .active { media.stop(); effect = nil } else { configureMedia(); refreshMedia() }
        }
        .onChange(of: panel) { _ in store.dismissChoices(); pause(); configureMedia(); refreshMedia() }
        .onChange(of: newGameConfirmation) { _ in pause() }
        .onChange(of: store.automatic) { _ in store.refresh() }
        .onChange(of: store.table) { _ in
            if case .hand(let seat) = panel, !store.table.canInspectHand(seat) { inspectionFocus = nil }
            store.persist(); configureMedia(); refreshMedia()
        }
        .onChange(of: store.preferences) { _ in store.preferences.normalize(available: Set(assets.map(\.id))); store.persist(); configureMedia(); refreshMedia() }
        .onChange(of: assets) { _ in configureMedia(); refreshMedia() }
        .onChange(of: inspectionFocus) { _ in media.mute(); refreshMedia() }
        .onChange(of: handDragging) { active in if !active { selectionOrigin = nil; visited = [] } }
        .onChange(of: store.game.id) { _ in
            panel = nil; inspectionFocus = nil; effect = nil; media.stop(clear: true); deal(); configureMedia()
        }
        .onChange(of: store.game.history.count) { _ in
            if store.table.sound { AudioServicesPlaySystemSound(1104) }
            if store.table.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        .task(id: store.game.history.count) {
            guard let play = store.game.history.last, play.pattern.tier > 0 || store.game.phase == .finished else { return }
            withAnimation(animate ? .spring(response: 0.35, dampingFraction: 0.7) : nil) {
                effect = store.game.phase == .finished ? (store.game.spring ? "春天 · 对局结束" : "对局结束") : play.interpretation?.title ?? play.pattern.kind.title
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            withAnimation(animate ? .easeOut : nil) { effect = nil }
        }
        .sheet(item: $panel, onDismiss: {
            inspectionFocus = nil
            if newGameAfterPanel { newGameAfterPanel = false; requestNewGame() }
        }) { panel in
            NavigationStack {
                panelView(panel)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { self.panel = nil; inspectionFocus = nil } } }
            }
        }
        .confirmationDialog("对局尚未结束，开始新一局？", isPresented: $newGameConfirmation, titleVisibility: .visible) {
            Button("开始新一局", role: .destructive) { store.newGame() }
        }
        .sheet(isPresented: Binding(get: { !store.interpretations.isEmpty }, set: { if !$0 { store.dismissChoices(); pause() } })) {
            NavigationStack {
                List(store.interpretations) { choice in
                    Button { store.commit(choice); pause() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(choice.title)
                            if !choice.substitutions.isEmpty {
                                Text(choice.substitutions.sorted(by: { $0.key < $1.key }).map { "\(LandlordCard(id: $0.key).label) → \(LandlordCard.rankLabel($0.value))" }.joined(separator: "，"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.accessibilityIdentifier("landlord-interpretation-\(choice.id)")
                }.navigationTitle("选择本次出牌解释")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { store.dismissChoices(); pause() } } }
            }.presentationDetents([.medium, .large])
        }
        .overlay(alignment: .topLeading) {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--landlord-liquid-ui-tests") {
                Text("对局状态").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                    .accessibilityIdentifier("landlord-liquid-probe")
                    .accessibilityValue(diagnostic)
            }
            #endif
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { store.persist(); close() } label: { Image(systemName: "chevron.backward") }.accessibilityLabel("保存并退出斗地主").accessibilityIdentifier("landlord-exit")
            Text(store.game.wildcardRank == nil ? "斗地主" : "单癞子 · \(LandlordCard.rankLabel(store.game.wildcardRank!))").font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Button { store.table.expanded.toggle() } label: { Image(systemName: store.table.expanded ? "square.stack.fill" : "rectangle.grid.1x2") }.accessibilityLabel("切换叠放与展开").accessibilityIdentifier("landlord-expand")
            Button { panel = .allCards } label: { Image(systemName: "rectangle.on.rectangle") }.accessibilityLabel("检查全部54张牌").accessibilityIdentifier("landlord-all-cards")
            Menu {
                Button("牌面、明牌与角色") { panel = .settings }
                Button("本局完整记录") { panel = .history }
                Button("玩法说明") { panel = .rules }
                Button("新一局") { requestNewGame() }
            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("斗地主设置").accessibilityIdentifier("landlord-table-menu")
        }.font(.callout).frame(height: 36).buttonStyle(.moonLiquid)
    }
    private var portrait: some View {
        VStack(spacing: 6) {
            header
            HStack(alignment: .top, spacing: 8) { opponent(2, compact: true); opponent(1, compact: true) }
            status
            bottomCards
            currentTarget
            historyTable.frame(minHeight: 110, maxHeight: .infinity)
            handArea(compact: false)
            controls
        }
    }
    private var horizontal: some View {
        VStack(spacing: 4) {
            header
            HStack(alignment: .top, spacing: 8) {
                opponent(2, compact: false).frame(width: 125)
                VStack(spacing: 3) { status; bottomCards; currentTarget; historyTable }
                opponent(1, compact: false).frame(width: 125)
            }.frame(maxHeight: .infinity)
            handArea(compact: true)
            controls
        }
    }
    private func opponent(_ player: Int, compact: Bool) -> some View {
        VStack(spacing: 3) {
            seat(player, compact: compact)
            if store.table.canInspectHand(player) {
                Text(store.game.hands[player].map { $0.rankText }.joined(separator: " "))
                    .font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(compact ? 1 : 4).minimumScaleFactor(0.7)
                    .accessibilityIdentifier("landlord-visible-hand-\(player)")
            } else {
                Text("▧ ▧ ▧ · \(store.game.hands[player].count)张").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("手牌已遮挡，\(store.game.hands[player].count)张")
                    .accessibilityIdentifier("landlord-hidden-hand-\(player)")
            }
        }
    }
    private func seat(_ player: Int, compact: Bool) -> some View {
        let profile = store.table.profiles[player]
        return LandlordSeatFrame(player: player, profile: profile, game: store.game, revealed: store.table.canInspectHand(player), compact: compact,
            avatar: profile.avatarMediaID.flatMap { media.feed($0) }) { initialInspection = nil; panel = .hand(player) }
            .background { if let mediaID = profile.avatarMediaID { GeometryReader { g in
                Color.clear.preference(key: LandlordMediaPlacementKey.self, value: [.init(card: 100 + player, media: mediaID,
                    rect: g.frame(in: .global), role: .other, z: 1000)])
            } } }
    }
    private var status: some View {
        HStack(spacing: 5) {
            let game = store.game
            Text(game.phase == .bidding ? "\(store.table.profiles[game.turn].name)叫分 · 当前\(game.highestBid)分" :
                 game.phase == .finished ? "\(game.winner == game.landlord ? "地主" : "农民")获胜\(game.spring ? " · 春天" : "") · 我 \(game.scores[0])分" :
                 game.phase == .redeal ? "三家不叫，请重新发牌" : "\(store.table.profiles[game.turn].name)出牌 · \(game.highestBid)分 × \(game.multiplier)")
                .font(.caption.weight(.semibold)).lineLimit(2).accessibilityIdentifier("landlord-status")
            if store.thinking { ProgressView().scaleEffect(0.65) }
            if game.phase == .finished || game.phase == .redeal { Button("新一局") { requestNewGame() }.font(.caption).buttonStyle(.moonLiquid).accessibilityIdentifier("landlord-new-game") }
        }
        .frame(maxWidth: .infinity, minHeight: 22)
        .overlay(alignment: .bottom) { if !store.message.isEmpty { Text(store.message).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).offset(y: 8) } }
    }
    private var currentTarget: some View {
        Group {
            if let play = store.game.lastPlay {
                Button { panel = .pile(play.id) } label: {
                    Text("当前要压：\(store.table.profiles[play.player].name) · \(play.interpretation?.title ?? play.pattern.kind.title) · \(play.cards.count)张")
                        .font(.caption2).lineLimit(1)
                }.buttonStyle(.plain).accessibilityIdentifier("landlord-current-target")
            } else { Text("自由出牌 · 已出 \(store.game.history.reduce(0) { $0 + $1.cards.count })/54 张").font(.caption2).foregroundStyle(.secondary) }
        }.frame(height: 20)
    }
    private var bottomCards: some View {
        HStack(spacing: 6) {
            Text("底牌").foregroundStyle(.secondary)
            if store.game.landlord == nil { Text("▧  ▧  ▧").accessibilityLabel("三张底牌，叫分后公开") }
            else {
                ForEach(store.game.bottom) { card in
                    Text(card.label).foregroundStyle(card.isRed ? Color.red : Color.primary)
                }
            }
        }.font(.caption2.weight(.semibold)).frame(height: 17)
    }
    private var historyTable: some View {
        LandlordHistoryTable(game: store.game, expanded: $store.table.expanded, offsets: $store.table.offsets,
            card: { card, play in AnyView(cardView(card, concealed: false, role: .central, z: play.id * 100 + 100 + card.id, effective: play.interpretation?.substitutions[card.id], clip: tableViewport)
                .matchedGeometryEffect(id: card.id, in: movement, isSource: false)) }, inspect: { panel = .pile($0) })
            .animation(animate ? .spring(response: 0.35, dampingFraction: 0.85) : nil, value: store.game.history.count)
            .background { GeometryReader { g in
                Color.clear.onAppear { tableViewport = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { tableViewport = $0; refreshMedia() }
            } }
    }
    private func handArea(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 6) {
            if compact { seat(0, compact: true).frame(width: 115) }
            VStack(spacing: 3) {
                if !compact { seat(0, compact: true) }
                GeometryReader { geometry in
                    let cards = store.game.hands[0]
                    let rows = LandlordTableLayout.handRows(cardCount: cards.count, width: Double(geometry.size.width), compact: compact)
                    VStack(spacing: 7) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, indices in
                            handRow(indices.map { cards[$0] }, width: geometry.size.width, compact: compact)
                        }
                    }
                    .onAppear { handWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { handWidth = $0 }
                }.frame(height: CGFloat(max(1, LandlordTableLayout.handRows(cardCount: store.game.hands[0].count, width: Double(handWidth), compact: compact).count)) * 64)
            }
        }.accessibilityIdentifier("landlord-hand")
    }
    private func handRow(_ cards: [LandlordCard], width: CGFloat, compact: Bool) -> some View {
        let cardWidth: CGFloat = compact ? 44 : 46
        let step = cards.count > 1 ? min(38, max(1, (width - cardWidth) / CGFloat(cards.count - 1))) : 0
        return ZStack(alignment: .leading) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                cardView(card, concealed: !store.table.canInspectHand(0), role: .hand, z: i + 10000)
                    .frame(width: cardWidth, height: 57)
                    .matchedGeometryEffect(id: card.id, in: movement, isSource: true)
                    .offset(x: CGFloat(i) * step, y: store.selection.contains(card.id) ? -5 : 0)
                    .zIndex(Double(i))
                    .onTapGesture { if Date.timeIntervalSinceReferenceDate > suppressTapUntil { store.choose(card.id) } }
                    .onLongPressGesture { suppressTapUntil = Date.timeIntervalSinceReferenceDate + 0.7; initialInspection = card.id; panel = .hand(0) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { store.choose(card.id) }
                    .accessibilityIdentifier(store.table.canInspectHand(0) ? "landlord-hand-\(card.id)" : "landlord-concealed-hand")
                    .scaleEffect(dealt || !animate ? 1 : 0.8).opacity(dealt || !animate ? 1 : 0)
                    .animation(animate ? .spring(response: 0.3, dampingFraction: 0.85).delay(Double(i) * 0.018) : nil, value: dealt)
            }
        }.frame(width: width, height: 57, alignment: .leading).contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                guard store.game.turn == 0, !store.automatic else { return }
                if selectionOrigin == nil {
                    selectionOrigin = store.selection; visited = []
                    if let start = LandlordTableLayout.cardIndex(x: Double(value.startLocation.x), width: Double(max(cardWidth, cardWidth + CGFloat(max(0, cards.count - 1)) * step)), count: cards.count, cardWidth: Double(cardWidth)) {
                        visited.insert(cards[start].id)
                    }
                }
                guard let index = LandlordTableLayout.cardIndex(x: Double(value.location.x), width: Double(max(cardWidth, cardWidth + CGFloat(max(0, cards.count - 1)) * step)), count: cards.count, cardWidth: Double(cardWidth)) else { return }
                if visited.insert(cards[index].id).inserted {
                    var ids = selectionOrigin ?? []
                    for id in visited { if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) } }
                    store.setSelection(ids)
                }
            }.updating($handDragging) { _, active, _ in active = true }.onEnded { _ in selectionOrigin = nil; visited = [] })
    }
    private var controls: some View {
        HStack(spacing: 8) {
            Group {
            if store.game.phase == .bidding {
                ForEach(0...3, id: \.self) { bid in
                    Button(bid == 0 ? "不叫" : "\(bid)分") { store.bid(bid) }
                        .disabled(store.game.turn != 0 || store.automatic || (bid > 0 && bid <= store.game.highestBid))
                        .accessibilityIdentifier("landlord-bid-\(bid)")
                }
            } else if store.game.phase == .playing {
                Button("提示") { store.hint() }.accessibilityIdentifier("landlord-hint")
                Button("不出") { store.pass() }.disabled(store.game.target == nil).accessibilityIdentifier("landlord-pass")
                Button("出牌") { store.play() }.disabled(store.selection.isEmpty).accessibilityIdentifier("landlord-play")
            }
            }.disabled(store.game.turn != 0 || store.automatic || store.thinking)
            Spacer(minLength: 0)
            Toggle("托管", isOn: $store.automatic).font(.caption).fixedSize().accessibilityIdentifier("landlord-auto")
        }.font(.callout.weight(.semibold)).buttonStyle(.moonLiquid).frame(minHeight: 38)

    }

    private func cardView(_ card: LandlordCard, concealed: Bool, role: CardPreviewRole, z: Int, effective: Int? = nil, clip: CGRect? = nil) -> some View {
        let mediaID = !concealed && store.preferences.style == .media ? store.mapping.assignments[card.id] : nil
        return LandlordTableCard(card: card, concealed: concealed, wild: store.game.wildcardRank, effective: effective,
            feed: mediaID.flatMap { media.feed($0) }, selected: role == .hand && store.selection.contains(card.id))
            .background { if let mediaID { GeometryReader { geometry in
                Color.clear.preference(key: LandlordMediaPlacementKey.self, value: [.init(card: card.id, media: mediaID, rect: geometry.frame(in: .global), role: role, z: z, viewport: clip)])
            } } }
    }
    private func requestNewGame() {
        if store.game.phase == .finished || store.game.phase == .redeal { store.newGame() }
        else { newGameConfirmation = true }
    }
    private func pause() { store.paused = panel != nil || newGameConfirmation || newGameAfterPanel || !store.interpretations.isEmpty; store.refresh() }
    private func deal() {
        dealt = false
        Task { @MainActor in await Task.yield(); dealt = true }
    }
    private func configureMedia() {
        let ids = Set(store.preferences.mediaIDs + store.table.profiles.compactMap(\.avatarMediaID))
        media.configure(entries: assets.filter { ids.contains($0.id) }, requested: store.preferences.budget,
            active: visible && phase == .active && panel != .settings && panel != .rules && panel != .history)
    }
    private func refreshMedia() {
        guard visible, phase == .active else { return }
        if panel != nil {
            if let id = inspectionFocus, let mediaID = store.preferences.style == .media ? store.mapping.assignments[id] : nil {
                media.update([.init(cardID: id, mediaID: mediaID, role: .focus, z: 100000, visibility: .visible)], focus: id)
            } else { media.update([], focus: nil) }
            return
        }
        let source = placements.compactMap { item -> LandlordMediaPlacement? in
            let clipped = item.rect.intersection(viewport).intersection(item.viewport ?? viewport)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return .init(card: item.card, media: item.media, rect: clipped, role: item.role, z: item.z)
        }
        let candidates = source.map { value -> CardMediaCandidate in
            let covers = source.filter { $0.z > value.z }.map(\.rect)
            let area = CardMediaPolicy.visibleArea(value.rect.intersection(viewport), coveredBy: covers)
            return .init(cardID: value.card, mediaID: value.media, role: value.role, z: value.z, visibility: area > 1 ? .partial : .hidden)
        }
        media.update(candidates, focus: nil)
    }

    @ViewBuilder private func panelView(_ panel: LandlordPanel) -> some View {
        switch panel {
        case .settings: settings
        case .rules:
            ScrollView {
                Text("单机离线，一人对两名机器人。\n\n普通玩法保留原规则。单癞子每局在叫分前从 3、4…A、2 中随机指定，四张同点数牌为癞子。单出按原点数；组合可替代普通点数，不可替代大小王；顺子、连对、飞机主体不含 2 和大小王。\n\n炸弹：王炸 > 纯癞子炸弹 > 硬炸弹 > 软炸弹；同级按点数比较。炸弹、王炸每次 ×2，春天另 ×2。这是本应用的单癞子规则，不包含所有地方变体。\n\n明牌只改变显示，不改变发牌或机器人的信息。遮挡的手牌不能通过检查或无障碍标签看到点数。底牌在叫分完成后公开。\n\n点选或划选手牌，长按检查，点出牌确认；松手不出牌。长按历史牌堆可检查每一张，拖动可整理，双指缩放，滚动可查看全部历史。查看旧牌时，顶部仍显示当前要压的牌。\n\n打开检查、记录或设置暂停机器人；退出、后台保存，回到前台继续。游戏只使用虚拟积分。")
                    .font(.body).padding().textSelection(.enabled)
            }.navigationTitle("斗地主规则")
        case .hand(let player):
            VStack {
                Toggle("显示这家的牌点", isOn: $store.table.revealed[player]).padding(.horizontal)
                    .accessibilityIdentifier("landlord-inspection-reveal")
                LandlordCardInspector(cards: store.game.hands[player], concealed: !store.table.canInspectHand(player), wild: store.game.wildcardRank,
                    initialID: initialInspection, feed: { id in store.preferences.style == .media ? store.mapping.assignments[id].map { media.feed($0) } : nil }, focus: { inspectionFocus = $0 })
            }.navigationTitle(store.table.profiles[player].name + "的手牌")
        case .pile(let id):
            if let play = store.game.history.first(where: { $0.id == id }) {
                LandlordCardInspector(cards: play.cards, concealed: false, wild: store.game.wildcardRank,
                    substitutions: play.interpretation?.substitutions ?? [:],
                    feed: { id in store.preferences.style == .media ? store.mapping.assignments[id].map { media.feed($0) } : nil }, focus: { inspectionFocus = $0 })
                    .navigationTitle("第\(play.trick)轮 · \(store.table.profiles[play.player].name)")
            }
        case .profile(let player): profileEditor(player)
        case .history:
            List {
                Section("本局完整记录 · \(store.game.history.count)手") {
                    ForEach(store.game.history) { play in
                        Button { self.panel = .pile(play.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(store.table.profiles[play.player].name) · 第\(play.trick)轮 · \(play.interpretation?.title ?? play.pattern.kind.title)")
                                Text(play.cards.map { $0.label }.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("最近三局虚拟积分") { ForEach(Array(store.summaries.enumerated()), id: \.offset) { _, score in Text("我 \(score[0]) · 右家 \(score[1]) · 左家 \(score[2])") } }
            }.navigationTitle("对局记录")
        case .allCards: fullDeck
        }
    }
    private var settings: some View {
        Form {
            Section("本局显示 · 单机练习") {
                HStack {
                    Button("常规遮挡") { store.table.revealed = [true, false, false] }.accessibilityIdentifier("landlord-normal-visibility")
                    Spacer()
                    Button("全员明牌") { store.table.revealed = [true, true, true] }.accessibilityIdentifier("landlord-reveal-all")
                }
                ForEach(0..<3, id: \.self) { player in
                    Toggle("\(store.table.profiles[player].name) · 显示牌点", isOn: $store.table.revealed[player])
                        .accessibilityIdentifier("landlord-reveal-\(player)")
                    Button("编辑\(store.table.profiles[player].name)的角色框") { panel = .profile(player) }
                }
            }
            Section("新一局规则") {
                Toggle("下一局使用单癞子", isOn: $store.table.nextGameWild).accessibilityIdentifier("landlord-next-wild")
                Text("只在开始新一局时生效。当前：" + (store.game.wildcardRank.map { "癞子 " + LandlordCard.rankLabel($0) } ?? "普通斗地主"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("开始新一局") { newGameAfterPanel = true; panel = nil }.accessibilityIdentifier("landlord-settings-new-game")
                Button("查看完整规则") { panel = .rules }
            }
            Section("动态与牌面") {
                Toggle("牌桌动画", isOn: $store.table.animations)
                Toggle("出牌音效", isOn: $store.table.sound)
                Toggle("触觉反馈", isOn: $store.table.haptics)
                Picker("牌面样式", selection: $store.preferences.style) {
                    Text("经典牌面").tag(CardFaceStyle.classic); Text("媒体牌面").tag(CardFaceStyle.media)
                }.pickerStyle(.segmented).accessibilityIdentifier("landlord-style")
                Stepper("动态媒体：\(store.preferences.budget)路", value: $store.preferences.budget, in: 0...2)
                Text("角色框与牌面共用预算；离屏和完全遮挡时暂停，压力过高时显示静态快照。iOS 26 使用系统 Liquid Glass，旧系统使用 Material 回退。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重新启用动态预览") { media.retry() }
                if !media.notice.isEmpty { Text(media.notice).font(.caption) }
            }
            Section("媒体牌面素材 · \(store.preferences.mediaIDs.count)/54") {
                if assets.isEmpty { Text("可先到 Moonlight 素材库导入图片、GIF 或视频。") }
                ForEach(assets) { entry in
                    Button {
                        if store.preferences.mediaIDs.contains(entry.id) { store.preferences.mediaIDs.removeAll { $0 == entry.id } }
                        else if store.preferences.mediaIDs.count < 54 { store.preferences.mediaIDs.append(entry.id) }
                    } label: {
                        HStack { Text(entry.title).lineLimit(1); Spacer(); if store.preferences.mediaIDs.contains(entry.id) { Image(systemName: "checkmark") } }
                    }
                }
            }
        }.moonLiquidList().navigationTitle("牌桌设置")
    }
    private func profileEditor(_ player: Int) -> some View {
        Form {
            Section("角色信息") {
                TextField("昵称", text: $store.table.profiles[player].name)
                Text("头像素材缺失时显示默认角色；不影响对局。")
            }
            Section("头像 · 本地素材") {
                Button("默认角色") { store.table.profiles[player].avatarMediaID = nil }
                ForEach(assets) { entry in
                    Button { store.table.profiles[player].avatarMediaID = entry.id } label: {
                        HStack { Text(entry.title).lineLimit(1); Spacer(); if store.table.profiles[player].avatarMediaID == entry.id { Image(systemName: "checkmark") } }
                    }
                }
            }
        }.navigationTitle("角色框")
    }
    private var fullDeck: some View {
        ScrollView {
            Text("全副54张 · 已出牌公开，未出手牌遵循明暗牌设置").font(.caption).foregroundStyle(.secondary).padding()
            LazyVGrid(columns: [.init(.adaptive(minimum: 60))], spacing: 12) {
                ForEach(LandlordCard.deck) { card in
                    let play = store.game.history.first { $0.cards.contains(card) }
                    let owner = (0..<3).first { store.game.hands[$0].contains(card) }
                    let isBottom = store.game.bottom.contains(card)
                    let known = play != nil || (owner.map { store.table.canInspectHand($0) } ?? false) || (isBottom && store.game.landlord != nil)
                    VStack(spacing: 5) {
                        LandlordTableCard(card: card, concealed: !known, wild: store.game.wildcardRank, effective: play?.interpretation?.substitutions[card.id])
                            .frame(width: 56, height: 78)
                        Text(play.map { "第\($0.trick)轮" } ?? owner.map { store.table.profiles[$0].name } ?? "底牌")
                            .font(.caption2).lineLimit(1)
                    }.onTapGesture {
                        initialInspection = card.id
                        if let play { panel = .pile(play.id) } else if let owner { panel = .hand(owner) }
                    }
                }
            }.padding()
        }.navigationTitle("完整54张牌")
            .accessibilityIdentifier("landlord-full-deck").accessibilityValue("54张，唯一身份")
    }
}
