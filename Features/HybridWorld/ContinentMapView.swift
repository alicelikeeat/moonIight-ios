import SwiftUI

/// v1.86: the 16×16 continent. Every region can be visited: a saved one
/// opens as it was left, a new one is built from its theme on arrival.
@available(iOS 18.0, *)
struct ContinentMapView: View {
    @ObservedObject var controller: Glass3DController
    var onTravel: () -> Void = {}
    @State private var chosen: RegionAddress?
    @State private var visited: Set<RegionAddress> = []
    private let graph = WorldGraph.continentIndex()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                grid.padding(10).moonGlassCard(radius: 20)
                details
                legend
            }
            .padding(16)
        }
        .moonLiquidPage()
        .navigationTitle(L10n.t("大陆地图", "Continent Map"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { visited = RegionArchive.saved().union([controller.regionAddress]); chosen = chosen ?? controller.regionAddress }
        .accessibilityIdentifier("continent-map")
    }

    private var grid: some View {
        let edge = HybridWorldScale.regionsAlongEdge
        return VStack(spacing: 2) {
            // Row 15 at the top, so north (map +y) is up.
            ForEach((0..<edge).reversed(), id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<edge, id: \.self) { column in cell(RegionAddress(column: column, row: row)) }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func cell(_ address: RegionAddress) -> some View {
        let record = graph.regions.first { $0.address == address }
        let here = address == controller.regionAddress, picked = address == chosen
        let named = record.map { $0.name != "待接入区域" } ?? false
        return Button { withAnimation(MoonLiquidMotion.morph) { chosen = address } } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color(record).opacity(visited.contains(address) ? 0.95 : 0.35))
                .overlay { if named { Circle().fill(.white.opacity(0.9)).padding(5) } }
                .overlay { if here { Image(systemName: "figure.walk").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(picked ? Color.white : .clear, lineWidth: 2))
                .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.moonJelly)
        .accessibilityLabel(record.map(RegionTravel.title) ?? "")
        .accessibilityAddTraits(picked ? .isSelected : [])
        .accessibilityIdentifier(String(format: "continent-cell-%02d-%02d", address.column, address.row))
    }

    @ViewBuilder private var details: some View {
        if let chosen, let record = graph.regions.first(where: { $0.address == chosen }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    MoonLiquidIcon(symbol: chosen == GoldenCity.address ? "building.columns.fill" : "map.fill", color: color(record), size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RegionTravel.title(record)).font(.headline)
                        Text(chosen == GoldenCity.address ? L10n.t("月光水晶城", "Crystal Moon City") : RegionTravel.theme(record).title)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(chosen == controller.regionAddress ? L10n.t("你在这里。走到地图边缘也能去相邻区域。", "You are here. Walk to an edge of the map to cross into the next region.")
                     : visited.contains(chosen) ? L10n.t("去过：回到你离开时的样子。", "Visited: opens as you left it.")
                     : L10n.t("还没去过：到达时按这个区域的主题生成，之后会保存。", "Not visited: built from its theme on arrival, then saved."))
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    controller.travel(to: chosen)
                    onTravel()
                } label: { Label(L10n.t("前往这里", "Travel Here"), systemImage: "location.north.circle.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.moonLiquidProminent)
                .disabled(chosen == controller.regionAddress || controller.travelling != nil)
                .accessibilityIdentifier("continent-travel")
            }
            .padding(14).moonGlassCard(radius: 20)
        }
    }

    private var legend: some View {
        Text(L10n.t("颜色是区域主题，深色是去过的区域，白点是有名字的区域。北在上方。",
                    "Colour is the region's theme; solid means visited; a white dot marks a named region. North is up."))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func color(_ record: WorldRegionRecord?) -> Color {
        guard let record else { return .gray }
        if record.address == GoldenCity.address { return .orange }
        switch RegionTravel.theme(record) {
        case .nature: return .green
        case .skyCity: return .cyan
        case .memory: return .pink
        case .futureCity: return .purple
        case .bossAdventure: return .red
        }
    }
}

extension TravelDirection {
    var symbol: String {
        switch self {
        case .west: "arrow.left.circle.fill"
        case .east: "arrow.right.circle.fill"
        case .south: "arrow.down.circle.fill"
        case .north: "arrow.up.circle.fill"
        }
    }
}
