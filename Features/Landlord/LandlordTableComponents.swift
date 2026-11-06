import SwiftUI

struct LandlordMediaPlacement: Equatable {
    let card: Int
    let media: String
    let rect: CGRect
    let role: CardPreviewRole
    let z: Int
    var viewport: CGRect? = nil
}
struct LandlordMediaPlacementKey: PreferenceKey {
    static let defaultValue: [LandlordMediaPlacement] = []
    static func reduce(value: inout [LandlordMediaPlacement], nextValue: () -> [LandlordMediaPlacement]) { value += nextValue() }
}
struct LandlordLiveImage: View {
    @ObservedObject var feed: CardMediaFrameFeed
    var body: some View {
        GeometryReader { g in
            if let image = feed.image { Image(uiImage: image).resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped() }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
struct LandlordTableCard: View {
    let card: LandlordCard
    var concealed = false
    var wild: Int?
    var effective: Int?
    var feed: CardMediaFrameFeed?
    var selected = false
    var body: some View {
        GeometryReader { g in
            let small = g.size.width < 50
            ZStack {
                if concealed {
                    RoundedRectangle(cornerRadius: 8).fill(Color.indigo)
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.65), lineWidth: 1).padding(4)
                    Image(systemName: "sparkle").font(.system(size: max(12, g.size.width * 0.35))).foregroundStyle(.white.opacity(0.8))
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemGroupedBackground))
                    if let feed { LandlordLiveImage(feed: feed).clipShape(RoundedRectangle(cornerRadius: 8)) }
                    if !small {
                        Text(card.suitText).font(.system(size: g.size.width * 0.40)).foregroundStyle(card.isRed ? Color.red.opacity(0.35) : Color.primary.opacity(0.20))
                    }
                    VStack {
                        HStack(alignment: .top) {
                            VStack(spacing: 0) {
                                Text(card.rankText).font(.system(size: card.rank >= 16 ? (small ? 9 : 12) : (small ? 13 : 19), weight: .bold))
                                Text(card.suitText).font(.system(size: small ? 10 : 13))
                            }
                            .foregroundStyle(card.isRed ? Color.red : Color.primary)
                            .padding(3).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 4))
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                        if card.rank == wild {
                            Text(effective.map { "癞→" + LandlordCard.rankLabel($0) } ?? "癞")
                                .font(.system(size: small ? 8 : 11, weight: .bold)).foregroundStyle(.black)
                                .padding(.horizontal, 3).background(.yellow, in: Capsule())
                        }
                    }.padding(2)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 3 : 0.7))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(concealed ? "已遮挡的牌" : card.label + (card.rank == wild ? "，癞子" : "") + (effective.map { "，替代为" + LandlordCard.rankLabel($0) } ?? ""))
        .accessibilityValue(concealed ? "牌背" : selected ? "已选" : "未选")
    }
}

struct LandlordSeatFrame: View {
    let player: Int
    let profile: LandlordSeatProfile
    let game: LandlordGame
    var revealed: Bool
    var compact = false
    var avatar: CardMediaFrameFeed?
    let inspect: () -> Void
    var body: some View {
        Button(action: inspect) {
            HStack(spacing: compact ? 5 : 9) {
                ZStack {
                    Circle().fill(seatColor.opacity(0.15))
                    Image(systemName: player == game.landlord ? "crown.fill" : "person.fill").foregroundStyle(seatColor)
                    if let avatar { LandlordLiveImage(feed: avatar).clipShape(Circle()) }
                }.frame(width: compact ? 30 : 44, height: compact ? 30 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("\(game.landlord == nil ? "待叫分" : game.landlord == player ? "地主" : "农民") · \(game.hands[player].count) 张")
                        .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                    if !compact { Text("积分 \(game.scores[player]) · \(revealed ? "明牌" : "遮挡")").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if game.turn == player && game.phase != .finished { Circle().fill(seatColor).frame(width: 7, height: 7).accessibilityLabel("正在行动") }
            }.padding(compact ? 6 : 9).frame(maxWidth: .infinity, alignment: .leading)
                .moonSingleGlass(radius: 15)
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(game.turn == player && game.phase != .finished ? seatColor : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain).accessibilityIdentifier("landlord-seat-\(player)")
    }
    private var seatColor: Color { player == 0 ? .teal : player == 1 ? .orange : .indigo }
}

/// Every historical play stays in this viewport. Stacking affects presentation only.
struct LandlordHistoryTable: View {
    let game: LandlordGame
    var collect = false
    @Binding var expanded: Bool
    @Binding var offsets: [Int: LandlordTableOffset]
    private var piles: [LandlordTablePile] { LandlordTablePile.piles(game, collect: collect) }
    let card: (LandlordCard, LandlordTablePile) -> AnyView
    let inspect: (Int) -> Void
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var drag: [Int: CGSize] = [:]
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    if expanded {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(piles) { play in
                                VStack(alignment: .leading, spacing: 5) {
                                    groupHeader(play)
                                    HStack(spacing: 4) { ForEach(play.cards) { c in card(c, play).frame(width: 46, height: 65) } }
                                }.id(play.id)
                            }
                        }.padding(16).frame(minWidth: max(0, geometry.size.width), alignment: .leading)
                    } else {
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(piles.enumerated()), id: \.element.id) { index, play in
                                stacked(play, index: index, width: geometry.size.width)
                                    .id(play.id)
                            }
                        }
                        .frame(width: max(300, geometry.size.width * 2), height: max(geometry.size.height, CGFloat(piles.count * 34 + 160)))
                        .scaleEffect(min(1.8, max(0.7, scale * pinch)), anchor: .topLeading)
                        .frame(width: max(300, geometry.size.width * 2) * min(1.8, max(0.7, scale * pinch)),
                               height: max(geometry.size.height, CGFloat(piles.count * 34 + 160)) * min(1.8, max(0.7, scale * pinch)), alignment: .topLeading)
                    }
                }
                .simultaneousGesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }.onEnded { scale = min(1.8, max(0.7, scale * $0)) })
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 8) {
                        Button { offsets = [:]; scale = 1 } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("自动整理牌桌").accessibilityIdentifier("landlord-arrange")
                        Button { if let id = piles.last?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } } } label: { Image(systemName: "scope") }.accessibilityLabel("回到当前出牌")
                    }.font(.caption).buttonStyle(.moonLiquid).padding(6)
                }
                .onChange(of: piles.count) { _ in
                    if let id = piles.last?.id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .overlay {
                if piles.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "suit.spade").font(.title2)
                        Text("出牌将按顺序叠放在这里").font(.caption)
                        Text("全局记录保留 · 长按检查 · 拖动整理").font(.caption2)
                    }.foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
        }
        .background(Color.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.teal.opacity(0.18), lineWidth: 1))
        .accessibilityIdentifier("landlord-table")
        .accessibilityValue("\(piles.reduce(0) { $0 + $1.cards.count })张桌面牌，\(game.history.count)手已出牌记录")
    }
    private func groupHeader(_ play: LandlordTablePile) -> some View {
        Button { inspect(play.id) } label: {
            Text("\(["我", "右家", "左家"][play.player]) · \(play.title) · \(play.cards.count)张")
                .font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("landlord-pile-\(play.id)")
    }
    private func stacked(_ play: LandlordTablePile, index: Int, width: CGFloat) -> some View {
        let pileWidth = max(150, min(260, width * 0.7))
        let step = min(23, (pileWidth - 35) / CGFloat(max(1, play.cards.count - 1)))
        let saved = offsets[play.id, default: .init()].bounded
        let delta = drag[play.id, default: .zero]
        let seatShift: CGFloat = play.player == 1 ? 0.15 : play.player == 2 ? -0.15 : 0
        return VStack(alignment: .leading, spacing: 2) {
            groupHeader(play)
            ZStack(alignment: .leading) {
                ForEach(Array(play.cards.enumerated()), id: \.element.id) { i, c in
                    card(c, play).frame(width: 35, height: 50).offset(x: CGFloat(i) * step).zIndex(Double(i))
                }
            }.frame(width: 35 + CGFloat(max(0, play.cards.count - 1)) * step, height: 50, alignment: .leading)
        }
        .frame(width: pileWidth, alignment: .leading)
        .position(x: width + width * seatShift + CGFloat(saved.x) * width * 0.3 + delta.width,
                  y: 65 + CGFloat(index * 34) + CGFloat(saved.y) * 75 + delta.height)
        .zIndex(Double(index))
        .onTapGesture { inspect(play.id) }
        .onLongPressGesture { inspect(play.id) }
        .gesture(DragGesture(minimumDistance: 12).onChanged { drag[play.id] = $0.translation }.onEnded { value in
            offsets[play.id] = LandlordTableOffset(x: saved.x + Double(value.translation.width / max(1, width * 0.3)),
                                                   y: saved.y + Double(value.translation.height / 75)).bounded
            drag[play.id] = nil
        })
    }
}

struct LandlordCardInspector: View {
    let cards: [LandlordCard]
    let concealed: Bool
    let wild: Int?
    var substitutions: [Int: Int] = [:]
    var initialID: Int?
    let feed: (Int) -> CardMediaFrameFeed?
    let focus: (Int?) -> Void
    @State private var index = 0
    private var current: LandlordCard? { cards.isEmpty ? nil : cards[min(index, cards.count - 1)] }
    var body: some View {
        GeometryReader { g in
            if g.size.width > g.size.height {
                HStack(spacing: 14) {
                    largeCard(width: min(170, g.size.height * 0.65))
                    VStack(alignment: .leading, spacing: 8) {
                        heading
                        Text("在大牌上滑动逐张检查").font(.caption).foregroundStyle(.secondary)
                        ScrollView { LazyVGrid(columns: [.init(.adaptive(minimum: 50))], spacing: 8) { thumbnails } }
                    }
                }.padding(10)
            } else {
                VStack(spacing: 12) {
                    heading
                    largeCard(width: min(185, g.size.height * 0.42))
                    Text("在大牌上滑动逐张检查，也可点下方列表").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) { HStack(spacing: 6) { thumbnails }.padding(8) }
                }.padding()
            }
        }
        .onAppear { index = initialID.flatMap { id in cards.firstIndex { $0.id == id } } ?? 0; updateFocus() }
        .onChange(of: index) { _ in updateFocus() }
        .onChange(of: concealed) { _ in updateFocus() }
        .onDisappear { focus(nil) }
    }
    private var heading: some View {
        Text(concealed ? "手牌已遮挡" : current.map { "\($0.label) · 第 \(min(index, cards.count - 1) + 1)/\(cards.count) 张" } ?? "这家的牌已出完").font(.headline)
    }
    @ViewBuilder private func largeCard(width: CGFloat) -> some View {
        if let current {
            LandlordTableCard(card: current, concealed: concealed, wild: wild, effective: substitutions[current.id], feed: concealed ? nil : feed(current.id))
                .frame(width: width, height: width * 1.37)
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if let next = LandlordTableLayout.cardIndex(x: Double(value.location.x), width: Double(width), count: cards.count, cardWidth: 0) { index = next }
                }).accessibilityIdentifier("landlord-inspected-card")
        }
    }
    private var thumbnails: some View {
        ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
            Button { index = i } label: {
                LandlordTableCard(card: c, concealed: concealed, wild: wild, effective: substitutions[c.id], selected: index == i)
                    .frame(width: 48, height: 70)
            }.buttonStyle(.plain)
        }
    }
    private func updateFocus() { focus(concealed ? nil : current?.id) }
}
