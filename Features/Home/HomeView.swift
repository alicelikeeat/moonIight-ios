import AVKit
import PhotosUI
import WebKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let onSelect: (MediaEntry) -> Void
    @State private var batchSize = 10
    private let sizes = [10, 15, 20]

    var body: some View {
            LazyVStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "月淡", subtitle: "为你留一段安静的时间", symbol: "moon.stars.fill")
            HStack {
                Text("最近内容").font(.title3.bold())
                Spacer()
                Menu {
                    ForEach(sizes, id: \.self) { count in
                        Button {
                            batchSize = count
                            Task { await model.mediaStore.addRandom(count: count) }
                        } label: { Label("随机添加 \(count) 条", systemImage: "shuffle") }
                    }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44).moonGlassCircle()
                }
                .buttonStyle(.moonJelly).accessibilityLabel("随便看看")
                .accessibilityIdentifier("home-random-menu")
            }
            if model.mediaStore.items.isEmpty {
                EmptyPanel(title: "内容会出现在这里", detail: "下拉刷新，或从内容源随机添加内容。", symbol: "play.rectangle")
            } else {
                ForEach(model.mediaStore.items) { entry in MediaEntryCard(entry: entry, height: 210, onSelect: { onSelect(entry) }) }
            }
            if let notice = model.mediaStore.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
    }
}
