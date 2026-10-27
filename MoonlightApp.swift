import SwiftUI
import UIKit

@main
struct MoonlightApp: App {
    @UIApplicationDelegateAdaptor(MoonlightOrientationDelegate.self) private var orientationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}

@MainActor
final class MoonlightOrientationDelegate: NSObject, UIApplicationDelegate {
    static var playerAllowsLandscape = false

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if Self.playerAllowsLandscape {
            return [.portrait, .landscapeLeft, .landscapeRight]
        }
        return .portrait
    }
}

enum LongPressSelectionMode: String, CaseIterable, Identifiable {
    case tap
    case drag

    var id: Self { self }
    var title: String { self == .tap ? "松手后点按" : "跟随拖动选择" }
}

enum QuickActionID: String, CaseIterable, Identifiable {
    case play
    case favorite
    case library
    case share

    var id: Self { self }
    var title: String {
        switch self {
        case .play: "打开播放"
        case .favorite: "收藏 / 取消收藏"
        case .library: "加入库"
        case .share: "分享"
        }
    }
    var symbol: String {
        switch self {
        case .play: "play.fill"
        case .favorite: "heart"
        case .library: "plus"
        case .share: "square.and.arrow.up"
        }
    }
}

struct ActiveLongPressMenu: Identifiable, Equatable {
    var id: String { entry.id }
    var entry: MediaEntry
    var location: CGPoint
    var fingerLocation: CGPoint
    var fingerDown = true
    var dropletScale: CGFloat = 1
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var mediaStore = MediaStore()
    @Published var longPressStyle: LongPressStyle = .popover {
        didSet { UserDefaults.standard.set(longPressStyle.rawValue, forKey: "moonlight.longPressStyle") }
    }
    @Published var longPressSelectionMode: LongPressSelectionMode = .tap {
        didSet { UserDefaults.standard.set(longPressSelectionMode.rawValue, forKey: "moonlight.longPressSelectionMode") }
    }
    @Published var longPressQuickActions: [QuickActionID] = [.play, .favorite, .library, .share] {
        didSet { UserDefaults.standard.set(longPressQuickActions.map(\.rawValue), forKey: "moonlight.longPressQuickActions") }
    }
    @Published var activeLongPressMenu: ActiveLongPressMenu?
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
        if let rawValue = UserDefaults.standard.string(forKey: "moonlight.longPressSelectionMode"),
           let savedMode = LongPressSelectionMode(rawValue: rawValue) {
            longPressSelectionMode = savedMode
        }
        if let rawValues = UserDefaults.standard.stringArray(forKey: "moonlight.longPressQuickActions") {
            longPressQuickActions = Array(rawValues.compactMap(QuickActionID.init(rawValue:)).prefix(4))
        }
        if UserDefaults.standard.object(forKey: "moonlight.portraitPlaybackOnly") != nil {
            portraitPlaybackOnly = UserDefaults.standard.bool(forKey: "moonlight.portraitPlaybackOnly")
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--scroll-ui-tests") {
            selectedTab = ProcessInfo.processInfo.arguments.contains("--test-discover") ? .discover : .home
            let columns = ProcessInfo.processInfo.arguments.contains("--single-column") ? 1 : 2
            UserDefaults.standard.set(columns, forKey: "discover_columns")
            UserDefaults.standard.set(1.0, forKey: "discover_banner_scale")
            virtualActivityEnabled = false
            longPressStyle = .popover
            longPressSelectionMode = .tap
        }
        #endif
    }

    func setQuickAction(_ action: QuickActionID, enabled: Bool) {
        if enabled {
            guard !longPressQuickActions.contains(action), longPressQuickActions.count < 4 else { return }
            longPressQuickActions.append(action)
        } else {
            longPressQuickActions.removeAll { $0 == action }
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
        var updated = moments
        let author = UserDefaults.standard.string(forKey: "moonlight.profile.displayName") ?? "我的朋友"
        updated.insert(MomentPost(text: text, attachment: attachment, authorName: author), at: 0)
        withAnimation(.easeOut(duration: 0.22)) { moments = Array(updated.prefix(500)) }
    }

    func toggleMomentLike(_ id: String) {
        guard let index = moments.firstIndex(where: { $0.id == id }) else { return }
        var updated = moments
        updated[index].likedByMe.toggle()
        updated[index].likes = max(0, updated[index].likes + (updated[index].likedByMe ? 1 : -1))
        moments = updated
    }

    func addMomentComment(_ id: String, text: String) {
        let comment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !comment.isEmpty, let index = moments.firstIndex(where: { $0.id == id }) else { return }
        var updated = moments
        updated[index].comments.append(comment)
        moments = updated
    }

    func repostMoment(_ id: String) {
        guard let index = moments.firstIndex(where: { $0.id == id }) else { return }
        var updated = moments
        let original = updated[index]
        updated[index].reposts += 1
        updated.insert(MomentPost(text: "转发了 \(original.authorName) 的动态：\(original.text)", attachment: original.attachment), at: 0)
        withAnimation(.easeOut(duration: 0.22)) { moments = Array(updated.prefix(500)) }
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
        var updated = moments
        updated.insert(MomentPost(
            text: generated?.caption ?? captions.randomElement() ?? "分享一条新内容。",
            attachment: entry,
            authorName: name,
            likes: Int.random(in: 0...18),
            comments: [generated?.comment ?? comments.randomElement() ?? "不错。"],
            isVirtual: true
        ), at: 0)
        moments = Array(updated.prefix(500))
    }

    private func simulateVirtualInteractions() {
        var updated = moments
        for index in updated.indices where updated[index].isVirtual {
            if Int.random(in: 0..<100) < 55 { updated[index].likes += 1 }
            if Int.random(in: 0..<100) < 24 {
                updated[index].comments.append(["这个我也喜欢。", "刚刚看完了。", "转给朋友看看。"].randomElement() ?? "好看。")
                if updated[index].comments.count > 20 { updated[index].comments.removeFirst() }
            }
            if Int.random(in: 0..<100) < 10 { updated[index].reposts += 1 }
        }
        moments = updated
    }
}

enum VirtualAIProvider: String, CaseIterable, Identifiable, Sendable {
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

    init(id: String = UUID().uuidString, text: String, date: Date = .now, attachment: MediaEntry? = nil, likedByMe: Bool = false, authorName: String = "我", likes: Int = 0, comments: [String] = [], reposts: Int = 0, isVirtual: Bool = false) {
        self.id = id; self.text = text; self.date = date; self.attachment = attachment
        self.likedByMe = likedByMe; self.authorName = authorName; self.likes = likes
        self.comments = comments; self.reposts = reposts; self.isVirtual = isVirtual
    }

    private enum CodingKeys: String, CodingKey { case id, text, date, attachment, likedByMe, authorName, likes, comments, reposts, isVirtual }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? .now
        attachment = try values.decodeIfPresent(MediaEntry.self, forKey: .attachment)
        likedByMe = try values.decodeIfPresent(Bool.self, forKey: .likedByMe) ?? false
        authorName = try values.decodeIfPresent(String.self, forKey: .authorName) ?? "我"
        likes = try values.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        comments = try values.decodeIfPresent([String].self, forKey: .comments) ?? []
        reposts = try values.decodeIfPresent(Int.self, forKey: .reposts) ?? 0
        isVirtual = try values.decodeIfPresent(Bool.self, forKey: .isVirtual) ?? false
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



