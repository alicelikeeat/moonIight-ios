import SwiftUI

@main
struct MoonlightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var mediaStore = MediaStore()
    @Published var longPressStyle: LongPressStyle = .popover
    @Published var portraitPlaybackOnly = true
    @Published var bannerColumns = 2
    @Published var bannerScale = 1.0
    @Published var refreshCount = 0

    @MainActor
    func refresh(_ tab: AppTab) async {
        guard tab == .home || tab == .discover else { return }
        if tab == .home { await mediaStore.refreshHome() }
        if tab == .discover { await mediaStore.refreshDiscover() }
        try? await Task.sleep(nanoseconds: 250_000_000)
        refreshCount += 1
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home, discover, camera, moments, me
    var id: Self { self }
    var title: String {
        switch self {
        case .home: "首页"
        case .discover: "发现"
        case .camera: "拍摄"
        case .moments: "朋友圈"
        case .me: "我"
        }
    }
    var symbol: String {
        switch self {
        case .home: "moon.stars.fill"
        case .discover: "safari"
        case .camera: "camera.fill"
        case .moments: "person.2"
        case .me: "person.crop.circle"
        }
    }
}

enum LongPressStyle: String, CaseIterable, Identifiable {
    case popover, trackingGlass, droplet
    var id: Self { self }
    var title: String {
        switch self {
        case .popover: "弹出菜单"
        case .trackingGlass: "跟手圆形玻璃"
        case .droplet: "水滴融合"
        }
    }
}



