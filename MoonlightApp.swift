import SwiftUI
import UIKit
import Combine

@main
struct MoonlightApp: App {
    @UIApplicationDelegateAdaptor(MoonlightOrientationDelegate.self) private var orientationDelegate
    @StateObject private var model = AppModel()
    /// Changing the language rebuilds the interface so every string updates.
    @AppStorage(L10n.key) private var language = AppLanguage.zh.rawValue

    var body: some Scene {
        WindowGroup {
            RootView().id(language).environmentObject(model).environmentObject(BackgroundStore.shared)
        }
    }
}

@MainActor
final class MoonlightOrientationDelegate: NSObject, UIApplicationDelegate {
    static var playerAllowsLandscape = false
    /// Set while the sandbox / 3D world is on screen: it then turns freely
    /// between portrait and landscape (v1.63; it used to lock landscape).
    static var sandboxLandscape = false

    static var supported: UIInterfaceOrientationMask {
        if sandboxLandscape || playerAllowsLandscape { return [.portrait, .landscapeLeft, .landscapeRight] }
        return .portrait
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.supported
    }

    /// Entering the sandbox allows both orientations (the screen follows the
    /// device); leaving it returns other pages to portrait. Both layouts
    /// adapt to the window shape, so a declined request is harmless.
    static func setSandboxLandscape(_ landscape: Bool) {
        #if DEBUG
        // Existing RPG UI tests drive the world in portrait; only tests that
        // opt in exercise the rotation itself.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--rpg-ui-tests") && !arguments.contains("--sandbox-landscape-ui-tests") { return }
        #endif
        guard sandboxLandscape != landscape else { return }
        sandboxLandscape = landscape
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows { window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: supported)) { error in
            print("Orientation request declined: \(error.localizedDescription)")
        }
    }
}

enum LongPressSelectionMode: String, CaseIterable, Identifiable {
    case tap
    case drag

    var id: Self { self }
    var title: String { self == .tap ? "松手后点按" : "跟随拖动选择" }
}

enum QuickActionID: String, CaseIterable, Identifiable, Hashable {
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
    var id: String { entry?.id ?? "global-hold" }
    var entry: MediaEntry?
    var location: CGPoint
    var fingerLocation: CGPoint
    var fingerDown = true
    var dropletScale: CGFloat = 1
}

@MainActor
final class AppModel: ObservableObject {
    var pendingMediaSearch: MediaSearchIntent?
    @Published var command: AppCommandRequest?
    func send(_ action: AppCommand, context: String = "") { command = AppCommandRequest(action: action, context: context) }
    /// The app opens into the most recent sandbox world.
    @Published var selectedTab: AppTab = .sandbox
    @Published var mediaStore = MediaStore() {
        didSet { observeMediaChanges() }
    }
    private var mediaUpdates: AnyCancellable?
    @Published var longPressStyle: LongPressStyle = .popover {
        didSet { UserDefaults.standard.set(longPressStyle.rawValue, forKey: "moonlight.longPressStyle") }
    }
    @Published var longPressSelectionMode: LongPressSelectionMode = .tap {
        didSet { UserDefaults.standard.set(longPressSelectionMode.rawValue, forKey: "moonlight.longPressSelectionMode") }
    }
    @Published var longPressQuickActions: [QuickActionID] = [.play, .favorite, .library, .share] {
        didSet { UserDefaults.standard.set(longPressQuickActions.map(\.rawValue), forKey: "moonlight.longPressQuickActions") }
    }
    @Published var cardLongPressEnabled: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "moonlight.cardLongPressEnabled") == nil
            ? true
            : defaults.bool(forKey: "moonlight.cardLongPressEnabled")
    }() {
        didSet { UserDefaults.standard.set(cardLongPressEnabled, forKey: "moonlight.cardLongPressEnabled") }
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
    private let momentPersistence = MomentPersistence()
    @Published private(set) var moments: [MomentPost] = [] {
        didSet { momentPersistence.save(moments) }
    }

    init() {
        observeMediaChanges()
        let savedInterval = UserDefaults.standard.integer(forKey: "moonlight.virtualFriends.interval")
        if savedInterval > 0 { virtualIntervalMinutes = max(15, savedInterval) }
        virtualAIKeyDraft = SecureSettings.read(virtualAIProvider.keychainAccount) ?? ""
        moments = momentPersistence.load()
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
            let blindUITest = ProcessInfo.processInfo.arguments.contains("--blind-ui-tests")
            UserDefaults.standard.set(blindUITest, forKey: "moonlight.blindMode")
            if blindUITest {
                UserDefaults.standard.set(true, forKey: "moonlight.globalSearch.enabled")
            }
            if !ProcessInfo.processInfo.arguments.contains("--keep-menu-settings") {
                InteractionPreferences.shared.resetForUITests()
            }
            InteractionPreferences.shared.navigationMode = ProcessInfo.processInfo.arguments.contains("--slider-ui-tests") ? .slider : .circles
            if ProcessInfo.processInfo.arguments.contains("--assistant-dock-ui-tests") {
                InteractionPreferences.shared.navigationMode = .assistant
                UserDefaults.standard.set("openAI", forKey: "moonlight.assistant.provider")
                UserDefaults.standard.set(0.0, forKey: "moonlight.navigation.hideDelay")
            }
            if ProcessInfo.processInfo.arguments.contains("--hidden-dock-ui-tests") {
                UserDefaults.standard.set(0.4, forKey: "moonlight.navigation.hideDelay")
            }
            cardLongPressEnabled = !ProcessInfo.processInfo.arguments.contains("--disable-card-hold-ui-tests")
            if ProcessInfo.processInfo.arguments.contains("--reels-ui-tests") { UserDefaults.standard.set(false, forKey: "moonlight.reels.autoAdvance") }
            selectedTab = ProcessInfo.processInfo.arguments.contains("--test-discover") ? .discover : .home
            if ProcessInfo.processInfo.arguments.contains("--sandbox-launch-ui-tests") { selectedTab = .sandbox }
            let columns = ProcessInfo.processInfo.arguments.contains("--single-column") ? 1 : 2
            UserDefaults.standard.set(columns, forKey: "discover_columns")
            UserDefaults.standard.set(1.0, forKey: "discover_banner_scale")
            virtualActivityEnabled = false
            longPressStyle = ProcessInfo.processInfo.arguments.contains("--bubble-ui-tests") ? .bubble : .popover
            longPressSelectionMode = .tap
        }
        #endif
    }

    private func observeMediaChanges() {
        mediaUpdates = mediaStore.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.objectWillChange.send() }
        }
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

    func deleteMoment(_ id: String) {
        withAnimation(.easeOut(duration: 0.22)) { moments.removeAll { $0.id == id } }
    }
    #if DEBUG
    func prepareWideMomentUITest(_ entry: MediaEntry) {
        moments = []
        publishMoment(text: "宽幅图片布局测试", attachment: entry)
    }
    #endif

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

struct AppCommandRequest: Identifiable, Equatable {
    let id = UUID()
    let action: AppCommand
    let context: String
}

enum AppCommand: String, CaseIterable, Codable, Identifiable, Hashable {
    case home, discover, moments, me, library, settings, friends, messages, profile
    case refresh, sources, layout, random10, random15, random20, importMedia
    case photo, video, compose, avatar, cover, deleteCover, reelsLibrary, reelsSources
    case background, backgrounds, backgroundLibrary, gestures, menuSettings
    case playMedia, favoriteMedia, saveMedia, shareMedia
    case portrait, virtualFriends, navigationMode, selectAll, favorites, downloads
    case searchMedia, treasureMap, treasurePlayback, landlord, rpg, rpgStory, rpgEditor, rpgDiagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .searchMedia: "搜索媒体"; case .treasureMap: "月藏图"; case .treasurePlayback: "视频墙"; case .landlord: "斗地主"; case .rpg: "自由媒体沙盒"; case .rpgStory: "剧情与任务"; case .rpgEditor: "剧情编辑器"; case .rpgDiagnostics: "沙盒运行诊断"
        case .home: "首页"; case .discover: "发现"; case .moments: "朋友圈"; case .me: "我"
        case .library: "打开库"; case .settings: "设置"; case .friends: "朋友"; case .messages: "消息"; case .profile: "编辑资料"
        case .refresh: "刷新"; case .sources: "内容源"; case .layout: "切换单双列"
        case .random10: "随机加入 10 条"; case .random15: "随机加入 15 条"; case .random20: "随机加入 20 条"
        case .importMedia: "导入图片或视频"; case .photo: "拍照"; case .video: "录制视频"
        case .compose: "发布动态"; case .avatar: "更换头像"; case .cover: "更换横幅"; case .deleteCover: "删除横幅"
        case .reelsLibrary: "抖音模式 · 库"; case .reelsSources: "抖音模式 · 内容源"
        case .background: "当前背景"; case .backgrounds: "全部背景"; case .backgroundLibrary: "背景与按键"
        case .gestures: "手势说明"; case .menuSettings: "配置长按菜单"
        case .playMedia: "打开播放"; case .favoriteMedia: "收藏 / 取消收藏"; case .saveMedia: "加入库"; case .shareMedia: "分享"
        case .portrait: "切换竖屏锁定"; case .virtualFriends: "切换虚拟好友活动"; case .navigationMode: "切换底栏模式"
        case .selectAll: "库 · 全选"; case .favorites: "库 · 收藏"; case .downloads: "库 · 下载"
        }
    }
    var symbol: String {
        switch self {
        case .searchMedia: "magnifyingglass"; case .treasureMap: "sparkles.rectangle.stack"; case .treasurePlayback: "play.square.stack"; case .landlord: "suit.spade"; case .rpg: "square.grid.3x3"; case .rpgStory: "book"; case .rpgEditor: "point.3.connected.trianglepath.dotted"; case .rpgDiagnostics: "waveform.path.ecg"
        case .home: "moon.stars"; case .discover: "safari"; case .moments, .friends: "person.2"
        case .me, .profile, .avatar: "person.crop.circle"; case .library, .saveMedia: "square.grid.2x2"
        case .settings, .menuSettings: "gearshape"; case .messages: "bubble.left.and.bubble.right"
        case .refresh: "arrow.clockwise"; case .sources: "line.3.horizontal.decrease"; case .layout: "rectangle.grid.2x2"
        case .random10, .random15, .random20: "shuffle"; case .importMedia: "square.and.arrow.down"
        case .photo: "camera"; case .video: "video"; case .compose: "square.and.pencil"; case .cover, .background: "photo"; case .deleteCover: "trash"
        case .reelsLibrary, .reelsSources: "play.rectangle.fill"; case .backgrounds, .backgroundLibrary: "photo.stack"
        case .gestures: "hand.draw"; case .playMedia: "play.fill"; case .favoriteMedia, .favorites: "heart"
        case .shareMedia: "square.and.arrow.up"; case .portrait: "lock.rotation"; case .virtualFriends: "person.2.wave.2"
        case .navigationMode: "slider.horizontal.3"; case .selectAll: "checkmark.circle"; case .downloads: "arrow.down.circle"
        }
    }
    var mediaAction: QuickActionID? {
        switch self { case .playMedia: .play; case .favoriteMedia: .favorite; case .saveMedia: .library; case .shareMedia: .share; default: nil }
    }
}

enum BottomNavigationMode: String, CaseIterable, Identifiable {
    case circles, slider, assistant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circles: "独立圆形"
        case .slider: "原生滑块"
        case .assistant: "智能输入栏"
        }
    }
}

@MainActor final class InteractionPreferences: ObservableObject {
    static let shared = InteractionPreferences()
    @Published var navigationMode: BottomNavigationMode {
        didSet { UserDefaults.standard.set(navigationMode.rawValue, forKey: "moonlight.navigationMode") }
    }
    @Published private(set) var menus: [String: [AppCommand]] {
        didSet { if let data = try? JSONEncoder().encode(menus) { UserDefaults.standard.set(data, forKey: "moonlight.contextMenus") } }
    }
    init() {
        navigationMode = BottomNavigationMode(rawValue: UserDefaults.standard.string(forKey: "moonlight.navigationMode") ?? "circles") ?? .circles
        menus = UserDefaults.standard.data(forKey: "moonlight.contextMenus").flatMap { try? JSONDecoder().decode([String: [AppCommand]].self, from: $0) } ?? [:]
    }
    func actions(_ context: String) -> [AppCommand] {
        if let saved = menus[context] { return saved }
        if context != "page.all", context.hasPrefix("page."), let common = menus["page.all"] { return common }
        if context != "button.all", context.hasPrefix("button."), let common = menus["button.all"] { return common }
        return defaults(context)
    }
    func set(_ actions: [AppCommand], for context: String) { menus[context] = Array(NSOrderedSet(array: actions.map(\.rawValue)).array.compactMap { ($0 as? String).flatMap(AppCommand.init(rawValue:)) }) }
    func reset(_ context: String) { menus.removeValue(forKey: context) }
    #if DEBUG
    func resetForUITests() { menus = [:] }
    #endif
    func defaults(_ context: String) -> [AppCommand] {
        switch context {
        case "media": [.playMedia, .favoriteMedia, .saveMedia, .shareMedia]
        case "button.home": [.reelsLibrary, .reelsSources, .refresh, .background]
        case "button.camera", "page.camera": [.photo, .video, .importMedia, .background]
        case "page.home": [.random10, .reelsLibrary, .reelsSources, .importMedia]
        case "page.discover", "button.discover": [.sources, .layout, .refresh, .background]
        case "button.sources": [.sources, .refresh, .background, .menuSettings]
        case "button.layout": [.layout, .sources, .background, .menuSettings]
        case "page.moments", "button.moments": [.compose, .avatar, .cover, .background]
        case "page.me", "button.me": [.library, .profile, .settings, .background]
        case "page.library": [.selectAll, .favorites, .downloads, .importMedia]
        case "page.settings": [.menuSettings, .backgroundLibrary, .navigationMode, .background]
        case "profile.cover": [.cover, .background, .backgrounds, .gestures, .deleteCover]
        default: [.background, .backgrounds, .gestures, .menuSettings]
        }
    }
}

enum RingAction: Identifiable, Hashable {
    case media(QuickActionID), command(AppCommand)
    var id: String { switch self { case .media(let a): "media-" + a.rawValue; case .command(let a): a.rawValue } }
    var title: String { switch self { case .media(let a): a.title; case .command(let a): a.title } }
    var symbol: String { switch self { case .media(let a): a.symbol; case .command(let a): a.symbol } }
    var mediaAction: QuickActionID? { switch self { case .media(let a): a; case .command(let a): a.mediaAction } }
    var background: BackgroundTarget { mediaAction.map(BackgroundTarget.ring(for:)) ?? .allRingButtons }
}

extension AppCommand {
    var searchTerms: [String] {
        let aliases: [String]
        switch self {
        case .searchMedia: aliases = ["搜索", "搜视频", "搜图片", "查找媒体", "search"]
        case .rpg: aliases = ["沙盒", "沙盘", "RPG", "双视角", "世界", "冒险", "创造", "建造", "放置", "挖掘", "八向移动", "范围技能", "翻滚", "冲刺", "方块行为", "世界保存", "撤销", "重做"]
        case .rpgStory: aliases = ["沙盒剧情", "序章", "村庄", "月核", "守灯人", "任务导航"]
        case .rpgEditor: aliases = ["剧情节点", "剧情JSON", "剧情导入", "剧情导出", "自制任务", "媒体演出"]
        case .rpgDiagnostics: aliases = ["沙盒帧率", "沙盒性能", "解码器", "沙盒内存"]
        case .landlord: aliases = ["斗地主", "叫分", "媒体牌面", "经典牌面", "出牌", "不出", "提示", "新一局", "托管", "牌桌记录", "牌面声音", "清理失效素材", "动态预览"]
        case .treasureMap: aliases = ["月藏图", "宝藏", "卡片"]
        case .treasurePlayback: aliases = ["视频墙", "顺序播放", "随机播放", "同时播放", "选择视频"]
        case .importMedia: aliases = ["相册", "导入", "照片库"]
        case .favorites: aliases = ["收藏", "我的收藏"]
        case .library: aliases = ["库", "媒体库", "视频库"]
        default: aliases = []
        }
        return [title, rawValue] + aliases
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

struct MomentPost: Codable, Identifiable, Sendable {
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
    case sandbox, home, discover, camera, moments, me
    var id: Self { self }
    /// Bottom bar order. 发现 is no longer its own tab: it is the second
    /// segment of 首页 (推荐 / 发现), so `.discover` maps to the 首页 button.
    static let bar: [AppTab] = [.sandbox, .home, .camera, .moments, .me]
    var barTab: AppTab { self == .discover ? .home : self }
    var title: String {
        switch self {
        case .sandbox: L10n.t("沙盒", "Sandbox")
        case .home: L10n.t("首页", "Home")
        case .discover: L10n.t("发现", "Discover")
        case .camera: L10n.t("拍摄", "Camera")
        case .moments: L10n.t("朋友圈", "Moments")
        case .me: L10n.t("我", "Me")
        }
    }
    var symbol: String {
        switch self {
        case .sandbox: "cube.transparent"
        case .home: "moon.stars.fill"
        case .discover: "safari"
        case .camera: "camera.fill"
        case .moments: "person.2"
        case .me: "person.crop.circle"
        }
    }
}

enum LongPressStyle: String, CaseIterable, Identifiable {
    case popover, trackingGlass, droplet, bubble
    var id: Self { self }
    var title: String {
        switch self {
        case .popover: "弹出菜单"
        case .trackingGlass: "跟手圆形玻璃"
        case .droplet: "水滴融合"
        case .bubble: "玻璃气泡分离"
        }
    }
}




