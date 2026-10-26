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
    @Published var longPressStyle: LongPressStyle = .popover {
        didSet { UserDefaults.standard.set(longPressStyle.rawValue, forKey: "moonlight.longPressStyle") }
    }
    @Published var portraitPlaybackOnly = true {
        didSet { UserDefaults.standard.set(portraitPlaybackOnly, forKey: "moonlight.portraitPlaybackOnly") }
    }
    @Published var bannerColumns = 2
    @Published var bannerScale = 1.0
    @Published var refreshCount = 0
    @Published var virtualActivityEnabled = UserDefaults.standard.bool(forKey: "moonlight.virtualFriends.enabled") {
        didSet { UserDefaults.standard.set(virtualActivityEnabled, forKey: "moonlight.virtualFriends.enabled") }
    }
    @Published var virtualAIProvider: VirtualAIProvider = VirtualAIProvider(rawValue: UserDefaults.standard.string(forKey: "moonlight.virtualFriends.aiProvider") ?? "openAI") ?? .openAI {
        didSet {
            UserDefaults.standard.set(virtualAIProvider.rawValue, forKey: "moonlight.virtualFriends.aiProvider")
            virtualAIKeyDraft = SecureSettings.read(virtualAIProvider.keychainAccount) ?? ""
        }
    }
    @Published var virtualAIKeyDraft = SecureSettings.read("virtual_ai_openai") ?? ""
    @Published var virtualIntervalMinutes = 30 {
        didSet { UserDefaults.standard.set(virtualIntervalMinutes, forKey: "moonlight.virtualFriends.interval") }
    }
    @Published private(set) var moments: [MomentPost] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(moments) {
                UserDefaults.standard.set(data, forKey: "moonlight.moments.v2")
            }
        }
    }

    init() {
        let savedInterval = UserDefaults.standard.integer(forKey: "moonlight.virtualFriends.interval")
        if savedInterval > 0 { virtualIntervalMinutes = max(15, savedInterval) }
        virtualAIKeyDraft = SecureSettings.read(virtualAIProvider.keychainAccount) ?? ""
        if let data = UserDefaults.standard.data(forKey: "moonlight.moments.v2"),
           let saved = try? JSONDecoder().decode([MomentPost].self, from: data) {
            moments = saved
        }
        if let rawValue = UserDefaults.standard.string(forKey: "moonlight.longPressStyle"),
           let savedStyle = LongPressStyle(rawValue: rawValue) {
            longPressStyle = savedStyle
        }
        if UserDefaults.standard.object(forKey: "moonlight.portraitPlaybackOnly") != nil {
            portraitPlaybackOnly = UserDefaults.standard.bool(forKey: "moonlight.portraitPlaybackOnly")
        }
    }

    @MainActor
    func refresh(_ tab: AppTab) async {
        guard tab == .home || tab == .discover else { return }
        if tab == .home { await mediaStore.refreshHome() }
        if tab == .discover { await mediaStore.refreshDiscover() }
        try? await Task.sleep(nanoseconds: 250_000_000)
        refreshCount += 1
    }

    func publishMoment(text: String, attachment: MediaEntry?) {
        moments.insert(MomentPost(text: text, attachment: attachment), at: 0)
    }

    func toggleMomentLike(_ id: String) {
        guard let index = moments.firstIndex(where: { $0.id == id }) else { return }
        var updated = moments
        updated[index].likedByMe.toggle()
        updated[index].likes = max(0, updated[index].likes + (updated[index].likedByMe ? 1 : -1))
        moments = updated
    }

    func runVirtualActivityLoop() async {
        while !Task.isCancelled {
            guard virtualActivityEnabled else {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            let delay = UInt64(max(15, virtualIntervalMinutes) * 60) * 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, virtualActivityEnabled else { continue }
            await mediaStore.refreshDiscover()
            guard !Task.isCancelled, let entry = mediaStore.discoverItems.randomElement() else { continue }
            await createVirtualMoment(with: entry)
            simulateVirtualInteractions()
        }
    }

    func saveVirtualAIKey() {
        let account = virtualAIProvider.keychainAccount
        let value = virtualAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { SecureSettings.delete(account) }
        else { SecureSettings.write(value, account: account) }
        virtualAIKeyDraft = value
    }

    private func createVirtualMoment(with entry: MediaEntry) async {
        let captions = ["刚好刷到这条，分享给大家。", "今天看到的有趣内容，先收藏再转发。", "这个片段让我停下来多看了一会儿。", "晚上的放松时间，推荐给你们。"]
        let comments = ["这个封面好有氛围。", "看完了，确实不错。", "先点赞收藏啦。", "这个来源还有类似内容吗？"]
        let name = VirtualFriendRoster.names.randomElement() ?? "小林"
        let generated = await MediaAPI.generateVirtualFriendText(
            title: entry.title,
            author: entry.author,
            provider: virtualAIProvider,
            apiKey: SecureSettings.read(virtualAIProvider.keychainAccount) ?? ""
        )
        moments.insert(MomentPost(
            text: generated?.caption ?? captions.randomElement() ?? "分享一条新内容。",
            attachment: entry,
            authorName: name,
            likes: Int.random(in: 0...18),
            comments: [generated?.comment ?? comments.randomElement() ?? "不错。"],
            isVirtual: true
        ), at: 0)
    }

    private func simulateVirtualInteractions() {
        var updated = moments
        for index in updated.indices where updated[index].isVirtual {
            if Int.random(in: 0..<100) < 55 { updated[index].likes += 1 }
            if Int.random(in: 0..<100) < 24 {
                updated[index].comments.append(["这个我也喜欢。", "刚刚看完了。", "转给朋友看看。"].randomElement() ?? "好看。")
            }
            if Int.random(in: 0..<100) < 10 { updated[index].reposts += 1 }
        }
        moments = updated
    }
}

enum VirtualAIProvider: String, CaseIterable, Identifiable {
    case openAI, grok
    var id: Self { self }
    var title: String { self == .openAI ? "OpenAI" : "Grok" }
    var keychainAccount: String { self == .openAI ? "virtual_ai_openai" : "virtual_ai_grok" }
}

enum VirtualFriendRoster {
    static let names = ["小林", "阿月", "晚风", "橘子汽水", "星河", "山雀"]
}

struct MomentPost: Codable, Identifiable {
    var id = UUID().uuidString
    var text: String
    var date = Date.now
    var attachment: MediaEntry?
    var likedByMe = false
    var authorName = "我"
    var likes = 0
    var comments: [String] = []
    var reposts = 0
    var isVirtual = false
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




