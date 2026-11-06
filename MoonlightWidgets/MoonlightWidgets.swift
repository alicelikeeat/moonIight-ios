import SwiftUI
import WidgetKit

// Home and lock screen widgets. Every tap is a moonlight:// link, so the
// shortcuts work on any install; the world status needs the App Group the
// app writes its snapshot into, and says so when it is missing.

@main
struct MoonlightWidgetBundle: WidgetBundle {
    var body: some Widget {
        MoonlightWorldStatusWidget()
        MoonlightShortcutsWidget()
    }
}

// MARK: Timeline

struct MoonlightWorldEntry: TimelineEntry {
    let date: Date
    /// nil: no snapshot yet, or no App Group after re-signing.
    let snapshot: MoonlightWidgetSnapshot?
    /// False when the shared container itself is missing (signing dropped it).
    let shared: Bool
}

struct MoonlightWorldProvider: TimelineProvider {
    func placeholder(in context: Context) -> MoonlightWorldEntry {
        MoonlightWorldEntry(date: Date(), snapshot: Self.sample, shared: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (MoonlightWorldEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : Self.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MoonlightWorldEntry>) -> Void) {
        // The app reloads this after saves; the hourly refresh only keeps
        // the "saved … ago" line honest if the app is not opened for a while.
        completion(Timeline(entries: [Self.current()], policy: .after(Date().addingTimeInterval(3600))))
    }

    static func current() -> MoonlightWorldEntry {
        MoonlightWorldEntry(date: Date(), snapshot: MoonlightWidgetStore.read(), shared: MoonlightWidgetStore.containerURL != nil)
    }

    /// Widget gallery preview: a small plaza with a fountain and two houses.
    static let sample: MoonlightWidgetSnapshot = {
        var cells: [MoonlightMinimapCell] = []
        for x in 120..<136 { for y in 120..<136 where (x + y) % 2 == 0 { cells.append(.init(x: x, y: y, top: 0.1, rgb: 0xEEEEEE)) } }
        for x in 126...128 { for y in 126...128 { cells.append(.init(x: x, y: y, top: 1, rgb: 0x77BBDD)) } }
        for x in 114...118 { for y in 130...134 { cells.append(.init(x: x, y: y, top: 4, rgb: 0x8FB8E0)) } }
        for x in 136...140 { for y in 114...118 { cells.append(.init(x: x, y: y, top: 4, rgb: 0xB5523B)) } }
        return MoonlightWidgetSnapshot(worldTitle: "月光水晶城", health: 82, stamina: 100, shards: 12, blocks: 10125, revision: 42,
                                       savedAt: Date(), mapSide: MoonlightMinimap.side,
                                       map: MoonlightMinimap.build(cells, centerX: 128, centerY: 128))
    }()
}

// MARK: World status

struct MoonlightWorldStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MoonlightWidgetStore.statusKind, provider: MoonlightWorldProvider()) { entry in
            MoonlightWorldStatusView(entry: entry)
        }
        .configurationDisplayName("世界状态")
        .description("沙盒世界的小地图、生命和月晶，轻点回到世界。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
    }
}

struct MoonlightWorldStatusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MoonlightWorldEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            case .systemLarge: large
            default: small
            }
        }
        .containerBackground(for: .widget) { MoonlightWidgetBackground() }
        .widgetURL(MoonlightLink.sandbox.url)
    }

    // Home screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let snapshot = entry.snapshot {
                MoonlightMinimapView(snapshot: snapshot).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(snapshot.worldTitle).font(.caption.weight(.semibold)).lineLimit(1)
                MoonlightVitalsRow(snapshot: snapshot, compact: true)
            } else {
                emptyState
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            if let snapshot = entry.snapshot {
                MoonlightMinimapView(snapshot: snapshot).aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.worldTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    MoonlightVitalsRow(snapshot: snapshot, compact: false)
                    savedLine(snapshot)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        MoonlightLinkChip(link: .world3D)
                        MoonlightLinkChip(link: .camera)
                    }
                }
            } else {
                emptyState
                Spacer(minLength: 0)
                VStack(spacing: 6) { MoonlightLinkChip(link: .world3D); MoonlightLinkChip(link: .camera) }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = entry.snapshot {
                HStack {
                    Text(snapshot.worldTitle).font(.headline).lineLimit(1)
                    Spacer()
                    savedLine(snapshot)
                }
                MoonlightMinimapView(snapshot: snapshot).aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                MoonlightVitalsRow(snapshot: snapshot, compact: false)
            } else {
                emptyState
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) { ForEach(MoonlightLink.allCases, id: \.self) { MoonlightLinkChip(link: $0) } }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("月淡沙盒", systemImage: "cube.transparent").font(.subheadline.weight(.semibold))
            Text(entry.shared ? "进入一次沙盒世界，这里就会显示世界状态。" : "当前安装方式没有共享数据，世界状态无法显示；快捷入口仍可使用。")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func savedLine(_ snapshot: MoonlightWidgetSnapshot) -> some View {
        Text("保存于 \(snapshot.savedAt, style: .relative)前")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }

    // Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let snapshot = entry.snapshot {
                Text(snapshot.worldTitle).font(.headline).lineLimit(1).widgetAccentable()
                Text("生命 \(snapshot.health) · 月晶 \(snapshot.shards)").font(.caption)
                Text("方块 \(snapshot.blocks)").font(.caption2).foregroundStyle(.secondary)
            } else {
                Label("月淡沙盒", systemImage: "cube.transparent").font(.headline).widgetAccentable()
                Text("轻点进入世界").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var circular: some View {
        Group {
            if let snapshot = entry.snapshot {
                Gauge(value: Double(snapshot.health), in: 0...100) {
                    Image(systemName: "heart.fill")
                } currentValueLabel: {
                    Text("\(snapshot.health)")
                }
                .gaugeStyle(.accessoryCircular)
            } else {
                ZStack { AccessoryWidgetBackground(); Image(systemName: "cube.transparent").font(.title3) }
            }
        }
    }
}

// MARK: Shortcuts

struct MoonlightShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MoonlightWidgetStore.shortcutsKind, provider: MoonlightWorldProvider()) { entry in
            MoonlightShortcutsView()
        }
        .configurationDisplayName("快捷入口")
        .description("一键进入沙盒、3D 世界、拍摄或搜索。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular])
    }
}

struct MoonlightShortcutsView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack { AccessoryWidgetBackground(); Image(systemName: MoonlightLink.world3D.symbol).font(.title3) }
                    .widgetURL(MoonlightLink.world3D.url)
            case .systemMedium:
                HStack(spacing: 8) { ForEach(MoonlightLink.allCases, id: \.self) { MoonlightLinkTile(link: $0) } }
            default:
                VStack(spacing: 8) {
                    HStack(spacing: 8) { MoonlightLinkTile(link: .sandbox); MoonlightLinkTile(link: .world3D) }
                    HStack(spacing: 8) { MoonlightLinkTile(link: .camera); MoonlightLinkTile(link: .search) }
                }
            }
        }
        .containerBackground(for: .widget) { MoonlightWidgetBackground() }
    }
}

// MARK: Pieces

/// The minimap as pixel art: one square per cell, open ground in a soft tone.
struct MoonlightMinimapView: View {
    let snapshot: MoonlightWidgetSnapshot

    var body: some View {
        Canvas { context, size in
            let side = max(1, snapshot.mapSide)
            let cell = min(size.width, size.height) / CGFloat(side)
            let origin = CGPoint(x: (size.width - cell * CGFloat(side)) / 2, y: (size.height - cell * CGFloat(side)) / 2)
            context.fill(Path(CGRect(origin: origin, size: CGSize(width: cell * CGFloat(side), height: cell * CGFloat(side)))),
                         with: .color(Color(red: 0.80, green: 0.86, blue: 0.78)))
            for row in 0..<side {
                for column in 0..<side {
                    let value = snapshot.map[row * side + column]
                    guard value > 0 else { continue }
                    let rgb = value - 1
                    let color = Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
                    let rect = CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(row) * cell, width: cell + 0.5, height: cell + 0.5)
                    context.fill(Path(rect), with: .color(color))
                }
            }
            // The player, at the centre of the map.
            let half = CGFloat(side / 2)
            let dot = CGRect(x: origin.x + half * cell - cell * 0.1, y: origin.y + (half - 1) * cell - cell * 0.1, width: cell * 1.2, height: cell * 1.2)
            context.fill(Path(ellipseIn: dot.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white))
            context.fill(Path(ellipseIn: dot), with: .color(Color(red: 0.30, green: 0.75, blue: 0.82)))
        }
        .accessibilityLabel("世界小地图")
    }
}

struct MoonlightVitalsRow: View {
    let snapshot: MoonlightWidgetSnapshot
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            Label("\(snapshot.health)", systemImage: "heart.fill").foregroundStyle(.red)
            Label("\(snapshot.shards)", systemImage: "moon.stars.fill").foregroundStyle(.indigo)
            if !compact { Label("\(snapshot.blocks)", systemImage: "cube").foregroundStyle(.secondary) }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .labelStyle(MoonlightTightLabel())
        .lineLimit(1)
    }
}

struct MoonlightTightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) { configuration.icon; configuration.title.foregroundStyle(.primary) }
    }
}

/// A small capsule link inside a bigger widget.
struct MoonlightLinkChip: View {
    let link: MoonlightLink
    var body: some View {
        Link(destination: link.url) {
            Label(link.title, systemImage: link.symbol)
                .font(.caption2.weight(.semibold)).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
    }
}

/// A square shortcut tile.
struct MoonlightLinkTile: View {
    let link: MoonlightLink
    var body: some View {
        Link(destination: link.url) {
            VStack(spacing: 4) {
                Image(systemName: link.symbol).font(.system(size: 18, weight: .semibold))
                Text(link.title).font(.caption2.weight(.semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// The app's moonlit glass tone.
struct MoonlightWidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let colors = scheme == .dark
            ? [Color(red: 0.12, green: 0.13, blue: 0.22), Color(red: 0.18, green: 0.14, blue: 0.24)]
            : [Color(red: 0.86, green: 0.88, blue: 0.97), Color(red: 0.93, green: 0.90, blue: 0.97)]
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
