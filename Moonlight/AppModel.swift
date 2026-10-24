import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum AppTab: String, CaseIterable, Identifiable {
    case home, discover, capture, moments, me
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"
        case .discover: return "发现"
        case .capture: return "拍摄"
        case .moments: return "朋友圈"
        case .me: return "我"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "moon.stars"
        case .discover: return "magnifyingglass"
        case .capture: return "circle.fill"
        case .moments: return "person.2"
        case .me: return "person"
        }
    }
}

struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(IDs.new()).\(ext)")
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var library: LibrarySnapshot
    @Published var social: SocialState
    @Published var tab: AppTab = .home
    @Published var feedIndex: Int = 0
    @Published var feedScope: FeedScope = .all
    @Published var feedOrder: [String] = []
    @Published var toast: String?
    @Published var undo: (() -> Void)?
    @Published var jumpVisible = false
    @Published var infoEntry: MediaEntry?
    @Published var composer: ComposerDraft?
    @Published var fullPlayer: MediaEntry?
    @Published var discoverResults: [MediaEntry] = []
    @Published var discoverBusy = false
    @Published var discoverError: String?
    @Published var requestSettings = false
    @Published var trash: [TrashItem] = []
    @Published var showTrash = false
    @Published var shredTitle: String?
    @Published var refreshCache: [MediaEntry] = []
    @Published var momentSlots: [String] = []
    /// Home-feed buttons and the tab bar. Hidden while an autoplaying video is clean full-screen.
    @Published var feedChrome = true
    /// Bumped when a button is used so the hide timer starts over.
    @Published var chromeGeneration = 0
    /// In-memory clip for the immersive UI test. Never written into the library.
    @Published var demoEntry: MediaEntry?

    static let immersiveDemoID = "immersive-demo"

    let feedPlayer = PlayerSession()
    let recorder = RecorderModel()
    let localTransport = LocalTransport()
    let remoteTransport = RemoteTransport(config: ChatServerConfig())
    private let writer = StoreWriter()
    private let transfers = TransferCenter()
    private var transferJobs: [TransferJob] = []
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var shredTask: Task<Void, Never>?

    init() {
        Paths.ensureDirs()
        var loadedSettings = AppSettings()
        if let data = AtomicFile.read(Paths.settingsFile), let s = AppSettings.load(data) {
            loadedSettings = s
        }
        loadedSettings.ringAnim = RingAnimPick.normalize(loadedSettings.ringAnim)
        let loadedLibrary: LibrarySnapshot
        if let data = AtomicFile.read(Paths.libraryFile), let lib = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) {
            loadedLibrary = lib
        } else {
            loadedLibrary = LibrarySnapshot()
        }
        let loadedSocial: SocialState
        if let data = AtomicFile.read(Paths.socialFile), let s = try? SocialJSON.decode(data) {
            loadedSocial = s
        } else {
            loadedSocial = .fresh()
        }
        settings = loadedSettings
        library = loadedLibrary
        social = loadedSocial
        if let data = AtomicFile.read(Paths.trashFile), let items = try? JSONDecoder().decode([TrashItem].self, from: data) {
            trash = items
        }
        if let data = AtomicFile.read(Paths.transfersFile), let jobs = try? JSONDecoder().decode([TransferJob].self, from: data) {
            transferJobs = jobs
        }
        if let data = AtomicFile.read(Paths.refreshFile), let items = try? JSONDecoder().decode([MediaEntry].self, from: data) {
            refreshCache = items
        }
        feedOrder = loadedLibrary.entries.sorted { $0.createdAt > $1.createdAt }.map(\.id)
        clampFeed()
        AppHooks.model = self
        BGRefresh.install()
        BGRefresh.schedule(enabled: settings.bgRefreshOn)
        transfers.onProgress = { [weak self] id, fraction, received in
            self?.noteTransfer(id, fraction: fraction, received: received)
        }
        transfers.onResume = { [weak self] id, path in
            self?.noteResume(id, path: path)
        }
        transfers.onFinish = { [weak self] id, file, error in
            self?.finishTransfer(id, file: file, error: error)
        }
        transfers.attach(jobs: transferJobs)
        _ = LinkMonitor.shared
        if ProcessInfo.processInfo.arguments.contains("-MoonlightDrop") {
            settings.dropSelect = true
        }
        if ProcessInfo.processInfo.arguments.contains("-MoonlightImmersive") {
            settings.chromeAutoHide = true
            settings.chromeHideSeconds = 1
            settings.feedMuted = true
            settings.pauseOnLowPower = false
            settings.autoplayWifiOnly = false
            installImmersiveDemo()
        }
    }

    func nudgeChrome() { chromeGeneration += 1 }

    private func installImmersiveDemo() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moon-immersive.mov")
        Task.detached { [weak self] in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size < 1500 {
                try? FileManager.default.removeItem(at: url)
                try? TinyClip.write(to: url)
            }
            let ready = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0) > 500
            await self?.useImmersiveDemo(url, exists: ready)
        }
    }

    private func useImmersiveDemo(_ url: URL, exists: Bool) {
        guard exists else { return }
        demoEntry = MediaEntry(
            id: Self.immersiveDemoID,
            kind: .video,
            title: "沉浸",
            localPath: url.path,
            platform: PlatformID.local,
            author: "测试",
            source: "local"
        )
        feedIndex = 0
    }

    var feedItems: [MediaEntry] {
        let map = Dictionary(uniqueKeysWithValues: library.entries.map { ($0.id, $0) })
        var items = feedOrder.compactMap { map[$0] }.filter { entry in
            if entry.hidden { return false }
            switch feedScope {
            case .all: return true
            case .local: return entry.localPath != nil
            case .online: return entry.localPath == nil
            }
        }
        if let demoEntry, !items.contains(where: { $0.id == demoEntry.id }) {
            items.insert(demoEntry, at: 0)
        }
        return items
    }

    func entry(_ id: String) -> MediaEntry? { library.entries.first { $0.id == id } }

    func clampFeed() {
        let n = feedItems.count
        if n == 0 { feedIndex = 0 }
        else if feedIndex >= n { feedIndex = n - 1 }
        else if feedIndex < 0 { feedIndex = 0 }
    }

    func focus(id: String) {
        feedScope = .all
        if let i = feedItems.firstIndex(where: { $0.id == id }) { feedIndex = i }
        tab = .home
    }

    func shuffleFeed() {
        feedOrder.shuffle()
        feedIndex = 0
        showToast("已重新洗牌")
    }

    func randomItem() {
        let n = feedItems.count
        guard n > 0 else { return }
        feedIndex = Int.random(in: 0..<n)
    }

    func setScope(_ scope: FeedScope) {
        feedScope = scope
        feedIndex = 0
        clampFeed()
    }

    func updateEntry(_ id: String, _ body: (inout MediaEntry) -> Void) {
        guard let i = library.entries.firstIndex(where: { $0.id == id }) else { return }
        body(&library.entries[i])
        scheduleSave()
    }

    func toggleFavorite(_ id: String) {
        updateEntry(id) { $0.favorite.toggle() }
        if entry(id)?.favorite == true { Haptics.soft() }
    }

    func favoriteOnly(_ id: String) {
        guard entry(id)?.favorite != true else {
            Haptics.soft()
            return
        }
        updateEntry(id) { $0.favorite = true }
        Haptics.soft()
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        updateEntry(id) { $0.hidden = hidden }
        clampFeed()
        showToast(hidden ? "已隐藏" : "已取消隐藏")
    }

    func deleteEntry(_ id: String) {
        guard let old = entry(id) else { return }
        library.entries.removeAll { $0.id == id }
        feedOrder.removeAll { $0 == id }
        if old.source == "follow", !settings.hiddenFollowIDs.contains(old.id) {
            settings.hiddenFollowIDs.append(old.id)
        }
        TrashBin.shredEntry(old, into: &trash, now: nowMs())
        clampFeed()
        scheduleSave()
        playShred(old.title)
        showToast("已删除", undo: { [weak self] in
            self?.restoreEntry(old.id)
        })
    }

    func addRemote(_ entry: MediaEntry) {
        var copy = entry
        if library.entries.contains(where: { $0.remoteURL == copy.remoteURL && copy.remoteURL != nil && $0.platform == copy.platform }) {
            if let existing = library.entries.first(where: { $0.remoteURL == copy.remoteURL }) { focus(id: existing.id) }
            showToast("已经在库里")
            return
        }
        if !copy.id.hasPrefix("yt-") && !copy.id.hasPrefix("bv-") && !copy.id.hasPrefix("av-") && !copy.id.hasPrefix("pt-") {
            copy.id = IDs.new()
        }
        library.entries.insert(copy, at: 0)
        feedOrder.insert(copy.id, at: 0)
        scheduleSave()
        focus(id: copy.id)
        showToast("已加入首页")
    }

    func importFile(at url: URL, kind: MediaKind, title: String, source: String, focusAfter: Bool = true) {
        Paths.ensureDirs()
        let ext = url.pathExtension.isEmpty ? (kind == .video ? "mov" : "jpg") : url.pathExtension
        let dest = Paths.media.appendingPathComponent("\(IDs.new()).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            showToast("导入失败")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        let entry = MediaEntry(
            kind: kind, title: title.isEmpty ? "未命名" : title, localPath: dest.path,
            platform: PlatformID.local, author: "我", source: source, byteSize: size
        )
        library.entries.insert(entry, at: 0)
        feedOrder.insert(entry.id, at: 0)
        scheduleSave()
        if focusAfter { focus(id: entry.id) }
        showToast("已导入")
    }

    func importImageData(_ data: Data, title: String, source: String, focusAfter: Bool = true) {
        Paths.ensureDirs()
        let dest = Paths.media.appendingPathComponent("\(IDs.new()).jpg")
        do { try data.write(to: dest) } catch { showToast("导入失败"); return }
        importExisting(path: dest.path, kind: .image, title: title, source: source, size: Int64(data.count), focusAfter: focusAfter)
    }

    private func importExisting(path: String, kind: MediaKind, title: String, source: String, size: Int64, focusAfter: Bool) {
        let entry = MediaEntry(kind: kind, title: title, localPath: path, platform: PlatformID.local, author: "我", source: source, byteSize: size)
        library.entries.insert(entry, at: 0)
        feedOrder.insert(entry.id, at: 0)
        scheduleSave()
        if focusAfter { focus(id: entry.id) }
        showToast("已导入")
    }

    func importPicker(_ item: PhotosPickerItem, focusAfter: Bool = true) async {
        let types = item.supportedContentTypes
        let video = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        if video {
            if let movie = try? await item.loadTransferable(type: MovieFile.self) {
                importFile(at: movie.url, kind: .video, title: "视频", source: "import", focusAfter: focusAfter)
            } else { showToast("无法读取这段视频") }
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            importImageData(data, title: "图片", source: "import", focusAfter: focusAfter)
        } else {
            showToast("无法读取这个文件")
        }
    }

    func saveToPhotos(_ entry: MediaEntry) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { showToast("没有相册权限"); return }
            if let path = entry.localPath {
                writeAsset(path: path, video: entry.kind == .video)
                return
            }
            guard let remote = entry.remoteURL, let url = URL(string: remote), DownloadPolicy.canDownload(entry).ok else {
                showToast("这个来源不能直接保存")
                return
            }
            do {
                let (tmp, _) = try await URLSession.shared.download(from: url)
                let ext = entry.kind == .video ? "mp4" : "jpg"
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(IDs.new()).\(ext)")
                if FileManager.default.fileExists(atPath: dest.path) { try? FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: tmp, to: dest)
                writeAsset(path: dest.path, video: entry.kind == .video)
            } catch {
                showToast("保存失败")
            }
        }
    }

    private func writeAsset(path: String, video: Bool) {
        let url = URL(fileURLWithPath: path)
        PHPhotoLibrary.shared().performChanges {
            if video { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            else { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
        } completionHandler: { ok, _ in
            DispatchQueue.main.async { self.showToast(ok ? "已保存到相册" : "保存失败") }
        }
    }

    func download(_ entry: MediaEntry, lane: DownloadLane = .active) {
        let policy = DownloadPolicy.canDownload(entry)
        let remote = entry.downloadURL.flatMap { $0.isEmpty ? nil : $0 } ?? entry.remoteURL
        guard policy.ok, let remote, URL(string: remote) != nil, !DownloadPolicy.isStreamURL(remote) else {
            showToast(policy.reason ?? "不能下载")
            return
        }
        if lane == .active && entry.localPath != nil { showToast("已经在本地"); return }
        let id = IDs.new()
        let job = TransferJob(id: id, url: remote, title: entry.title, lane: lane, entry: entry)
        transferJobs.insert(job, at: 0)
        if lane.listsInLibrary {
            library.downloads.insert(DownloadTask(id: id, url: remote, title: entry.title), at: 0)
            showToast("开始下载")
        } else {
            showToast("已开始自动缓存，不会出现在我的下载")
        }
        scheduleSave()
        transfers.start(job)
    }

    private func taskByteSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func patchDownload(_ id: String, _ body: (inout DownloadTask) -> Void) {
        guard let i = library.downloads.firstIndex(where: { $0.id == id }) else { return }
        body(&library.downloads[i])
        scheduleSave()
    }

    func discover(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let term = q.isEmpty ? ["moonlight", "aurora", "ocean", "galaxy", "night city", "forest"].randomElement()! : q
        discoverBusy = true
        discoverError = nil
        var all: [MediaEntry] = []
        let commons = await CommonsAPI.search(keyword: term, limit: 12)
        all += commons
        discoverResults = all
        let nasa = await NASAAPI.search(query: term, limit: 4)
        all += nasa
        discoverResults = all
        let archive = await ArchiveAPI.search(query: term, limit: 3)
        all += archive
        if !settings.pexelsKey.isEmpty {
            all += await PexelsAPI.search(key: settings.pexelsKey, query: term)
        }
        if !settings.pixabayKey.isEmpty {
            all += await PixabayAPI.search(key: settings.pixabayKey, query: term)
        }
        if !settings.youtubeKey.isEmpty {
            all += await YouTubeAPI.search(key: settings.youtubeKey, query: term)
        }
        if PublicLink.normalizedHost(settings.peertubeInstance) != nil {
            all += await PeerTubeAPI.search(instance: settings.peertubeInstance, query: term)
        }
        if let one = PublicLink.media(term) { all.insert(one, at: 0) }
        if case .youtubeFeed(let url) = PublicLink.parse(term), let feed = URL(string: url), let xml = await HTTP.text(feed) {
            all += FeedXML.youtube(xml)
        }
        var seen = Set<String>()
        discoverResults = all.filter { e in
            let key = e.remoteURL ?? e.embedURL ?? e.id
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
        discoverBusy = false
        if discoverResults.isEmpty { discoverError = "没有找到内容。换个词，或稍后再试。" }
    }

    func subscribe(_ raw: String) {
        let parsed = PublicLink.follow(from: raw, instance: settings.peertubeInstance)
        guard let follow = parsed.0 else {
            showToast(parsed.1 ?? "不能订阅这个")
            return
        }
        if settings.follows.contains(where: { $0.platform == follow.platform && $0.kind == follow.kind && $0.ref == follow.ref && $0.instance == follow.instance }) {
            showToast("已经订阅了")
            return
        }
        settings.follows.append(follow)
        saveSettings()
        showToast("已订阅 \(follow.title)")
        Task { await refreshFollows() }
    }

    func removeFollow(_ id: String) {
        settings.follows.removeAll { $0.id == id }
        saveSettings()
    }

    func refreshFollows() async {
        var gathered: [MediaEntry] = []
        for source in settings.follows {
            gathered += await PeerTubeAPI.load(source)
        }
        let hidden = Set(settings.hiddenFollowIDs)
        for var item in gathered where !hidden.contains(item.id) {
            item.source = "follow"
            if let i = library.entries.firstIndex(where: { $0.id == item.id }) {
                var old = library.entries[i]
                old.title = item.title
                old.remoteURL = item.remoteURL
                old.embedURL = item.embedURL
                old.coverURL = item.coverURL
                old.downloadURL = item.downloadURL
                old.author = item.author
                library.entries[i] = old
            } else {
                library.entries.insert(item, at: 0)
                feedOrder.insert(item.id, at: 0)
            }
        }
        scheduleSave()
        if !gathered.isEmpty { showToast("订阅更新了 \(gathered.count) 条") }
    }

    // MARK: social

    func editSocial(_ body: (inout SocialState) -> Void) {
        body(&social)
        scheduleSave()
    }

    func loadDemo() {
        editSocial { $0 = DemoSocial.seed($0) }
        showToast("已载入示例好友")
    }

    func toggleLike(moment: String, who: String) { editSocial { $0 = SocialOps.toggleLike($0, moment, who) } }
    func likeOnly(moment: String, who: String) { editSocial { $0 = SocialOps.likeOnly($0, moment, who) } }
    func toggleDislike(moment: String, who: String) { editSocial { $0 = SocialOps.toggleDislike($0, moment, who) } }

    func addComment(moment: String, author: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editSocial { $0 = SocialOps.addComment($0, moment, Comment(authorId: author, text: trimmed)) }
    }

    func deleteMoment(_ id: String) {
        guard let old = social.moments.first(where: { $0.id == id }) else { return }
        editSocial { $0 = SocialOps.deleteMoment($0, id) }
        TrashBin.shredMoment(old, into: &trash, now: nowMs())
        scheduleSave()
        playShred(old.text.isEmpty ? "一条动态" : old.text)
        showToast("已删除", undo: { [weak self] in self?.restoreMoment(old.id) })
    }

    func postMoment(authorId: String, text: String, attachments: [Attachment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { showToast("写点什么，或加一张图"); return }
        let moment = Moment(authorId: authorId, text: trimmed, attachments: attachments)
        editSocial { $0 = SocialOps.upsertMoment($0, moment) }
        composer = nil
        tab = .moments
        showToast("已发布")
    }

    func upsertFriend(_ c: Contact) { editSocial { $0 = SocialOps.upsertContact($0, c) } }

    func deleteFriend(_ id: String) {
        editSocial { $0 = SocialOps.deleteContact($0, id) }
        showToast("已删除好友")
    }

    func openChat(with members: [String], title: String? = nil) -> Conversation {
        var conv: Conversation!
        editSocial { s in
            let pair = SocialOps.conversationFor(s, members: members, title: title)
            s = pair.0
            conv = pair.1
        }
        return conv
    }

    func send(convId: String, senderId: String, text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let conv = social.conversations.first(where: { $0.id == convId }) else { return }
        var msg = Message(conversationId: convId, senderId: senderId, text: trimmed, attachments: attachments, status: .sending)
        editSocial { $0 = SocialOps.putMessage($0, msg) }
        let transport: any ChatTransport = conv.remote ? remoteTransport : localTransport
        Task {
            let result = await transport.send(message: msg, conversation: conv)
            msg.status = result.status
            msg.serverAt = result.serverAt
            msg.error = result.error
            editSocial { $0 = SocialOps.putMessage($0, msg) }
            guard result.status != .failed else { return }
            let replies = AutoReply.replies(msg: msg, conv: conv, contacts: social.contacts)
            for reply in replies {
                try? await Task.sleep(nanoseconds: 700_000_000)
                editSocial { $0 = SocialOps.putMessage($0, reply) }
            }
        }
    }

    func markRead(_ convId: String) {
        editSocial { $0 = SocialOps.markRead($0, convId, Int64(Date().timeIntervalSince1970 * 1000)) }
    }

    func deleteMessage(_ id: String) { editSocial { $0 = SocialOps.deleteMessage($0, id) } }

    func copyProfile(contactId: String, file: URL, video: Bool, cover: Bool) {
        Paths.ensureDirs()
        let ext = file.pathExtension.isEmpty ? (video ? "mov" : "jpg") : file.pathExtension
        let dest = Paths.avatars.appendingPathComponent("\(IDs.new()).\(ext)")
        do { try FileManager.default.copyItem(at: file, to: dest) } catch { showToast("没能保存这张图"); return }
        editSocial { s in
            guard let i = s.contacts.firstIndex(where: { $0.id == contactId }) else { return }
            if cover {
                if let path = s.contacts[i].coverPath {
                    s.contacts[i].prevCover = SavedMedia(path: path, video: s.contacts[i].coverVideo, focus: s.contacts[i].coverFocus)
                }
                s.contacts[i].coverPath = dest.path
                s.contacts[i].coverVideo = video
            } else {
                if let path = s.contacts[i].avatarPath {
                    s.contacts[i].prevAvatar = SavedMedia(path: path, video: s.contacts[i].avatarVideo, focus: s.contacts[i].avatarFocus)
                }
                s.contacts[i].avatarPath = dest.path
                s.contacts[i].avatarVideo = video
            }
        }
    }

    func copyProfileData(contactId: String, data: Data, cover: Bool) {
        Paths.ensureDirs()
        let dest = Paths.avatars.appendingPathComponent("\(IDs.new()).jpg")
        do { try data.write(to: dest) } catch { return }
        copyProfile(contactId: contactId, file: dest, video: false, cover: cover)
    }

    func restoreProfile(contactId: String, cover: Bool) {
        editSocial { s in
            guard let i = s.contacts.firstIndex(where: { $0.id == contactId }) else { return }
            if cover, let prev = s.contacts[i].prevCover {
                s.contacts[i].coverPath = prev.path
                s.contacts[i].coverVideo = prev.video
                s.contacts[i].coverFocus = prev.focus
            } else if !cover, let prev = s.contacts[i].prevAvatar {
                s.contacts[i].avatarPath = prev.path
                s.contacts[i].avatarVideo = prev.video
                s.contacts[i].avatarFocus = prev.focus
            } else if cover {
                s.contacts[i].coverPath = nil
                s.contacts[i].coverVideo = false
            } else {
                s.contacts[i].avatarPath = nil
                s.contacts[i].avatarVideo = false
            }
        }
    }

    func exportSocial() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("social.json")
        try? AtomicFile.write(SocialJSON.encode(social), to: url)
        return url
    }

    func importSocial(url: URL) {
        guard let data = try? Data(contentsOf: url), let incoming = try? SocialJSON.decode(data) else {
            showToast("这不是月光的备份")
            return
        }
        editSocial { current in
            let ownerId = current.selfId
            let remap: (String) -> String = { $0 == incoming.selfId ? ownerId : $0 }
            var merged = current
            for c in incoming.contacts where c.id != incoming.selfId && !merged.contacts.contains(where: { $0.id == c.id }) {
                merged.contacts.append(c)
            }
            for m in incoming.moments where !merged.moments.contains(where: { $0.id == m.id }) {
                var copy = m
                copy.authorId = remap(copy.authorId)
                copy.likes = copy.likes.map(remap)
                copy.dislikes = copy.dislikes.map(remap)
                copy.comments = copy.comments.map { var c = $0; c.authorId = remap(c.authorId); return c }
                merged.moments.append(copy)
            }
            for c in incoming.conversations where !merged.conversations.contains(where: { $0.id == c.id }) {
                var copy = c
                copy.memberIds = copy.memberIds.map(remap)
                merged.conversations.append(copy)
            }
            for m in incoming.messages where !merged.messages.contains(where: { $0.id == m.id }) {
                var copy = m
                copy.senderId = remap(copy.senderId)
                merged.messages.append(copy)
            }
            current = merged
        }
        showToast("已导入备份")
    }

    func attachment(from entry: MediaEntry) -> Attachment {
        Attachment(
            kind: entry.kind == .image ? .image : (entry.kind == .video ? .video : .embed),
            libraryEntryId: entry.id,
            localPath: entry.localPath,
            coverURL: entry.coverURL ?? (entry.kind == .image ? entry.remoteURL : nil),
            remoteURL: entry.kind == .embed ? (entry.embedURL ?? entry.remoteURL) : entry.remoteURL,
            title: entry.title
        )
    }

    func showToast(_ text: String, undo: (() -> Void)? = nil) {
        toast = text
        self.undo = undo
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if Task.isCancelled { return }
            self?.toast = nil
            self?.undo = nil
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        let socialData = SocialJSON.encode(social)
        let libraryData = (try? JSONEncoder().encode(library)) ?? Data()
        let settingsData = (try? JSONEncoder().encode(settings)) ?? Data()
        let trashData = (try? JSONEncoder().encode(trash)) ?? Data()
        let transferData = (try? JSONEncoder().encode(transferJobs)) ?? Data()
        let writer = self.writer
        saveTask = Task {
            if Task.isCancelled { return }
            let g = await writer.bump()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await writer.writeIfCurrent(generation: g, social: socialData, library: libraryData, settings: settingsData, trash: trashData, transfers: transferData)
        }
    }

    func saveSettings() { scheduleSave() }

    func flush() async {
        saveTask?.cancel()
        let socialData = SocialJSON.encode(social)
        let libraryData = (try? JSONEncoder().encode(library)) ?? Data()
        let settingsData = (try? JSONEncoder().encode(settings)) ?? Data()
        let trashData = (try? JSONEncoder().encode(trash)) ?? Data()
        let transferData = (try? JSONEncoder().encode(transferJobs)) ?? Data()
        let g = await writer.bump()
        await writer.writeIfCurrent(generation: g, social: socialData, library: libraryData, settings: settingsData, trash: trashData, transfers: transferData)
    }

    func toggleRecording() {
        recorder.toggle(onSaved: { [weak self] url in
            guard let self else { return }
            let saved = MediaEntry(kind: .video, title: "录屏", localPath: url.path, platform: PlatformID.local, source: "local", byteSize: self.taskByteSize(url.path))
            self.library.entries.insert(saved, at: 0)
            self.feedOrder.insert(saved.id, at: 0)
            self.scheduleSave()
            self.showToast("录屏已放进库")
        }, onUnavailable: { [weak self] in
            self?.showToast("这台设备现在不能录屏")
        }, onEmpty: { [weak self] in
            self?.showToast("没有录下画面")
        })
    }

    func applyIcon(_ preset: IconPreset) {
        settings.iconPreset = preset.rawValue
        saveSettings()
        UIApplication.shared.setAlternateIconName(preset.alternateName) { error in
            DispatchQueue.main.async {
                if error != nil { self.showToast("没能换上这个图标") }
                else { self.showToast("图标已换成\(preset.title)") }
            }
        }
    }

    func absorbRefresh(_ incoming: [MediaEntry]) {
        refreshCache = PublicRefresh.merge(existing: refreshCache, incoming: incoming)
        settings.lastRefreshAt = nowMs()
        if let data = try? JSONEncoder().encode(refreshCache) {
            try? AtomicFile.write(data, to: Paths.refreshFile)
        }
        saveSettings()
    }

    func claimMomentSlot(_ id: String) -> Bool {
        if momentSlots.contains(id) { return true }
        let allowed = MomentPlay.allows(
            mode: settings.momentAutoplay,
            momentID: id,
            picked: Set(settings.momentAutoplayIds),
            already: momentSlots.count
        )
        guard allowed else { return false }
        momentSlots.append(id)
        return true
    }

    func releaseMomentSlot(_ id: String) { momentSlots.removeAll { $0 == id } }

    func restoreTrash(_ id: String) {
        guard let item = TrashBin.take(id, from: &trash) else { return }
        if let entry = item.entry {
            if !library.entries.contains(where: { $0.id == entry.id }) {
                library.entries.insert(entry, at: 0)
                feedOrder.insert(entry.id, at: 0)
            }
        }
        if let moment = item.moment {
            editSocial { $0 = SocialOps.upsertMoment($0, moment) }
        }
        scheduleSave()
        showToast("已还原")
    }

    func forgetTrash(_ id: String) {
        _ = TrashBin.take(id, from: &trash)
        scheduleSave()
    }

    func emptyTrash() {
        trash = []
        scheduleSave()
        showToast("已清空最近删除")
    }

    func importProfile(item: PhotosPickerItem, contactId: String, cover: Bool) async {
        let video = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if video, let movie = try? await item.loadTransferable(type: MovieFile.self) {
            copyProfile(contactId: contactId, file: movie.url, video: true, cover: cover)
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            copyProfileData(contactId: contactId, data: data, cover: cover)
        }
    }

    private func restoreEntry(_ id: String) {
        if let item = trash.first(where: { $0.entry?.id == id }) {
            restoreTrash(item.id)
        }
    }

    private func restoreMoment(_ id: String) {
        if let item = trash.first(where: { $0.moment?.id == id }) {
            restoreTrash(item.id)
        }
    }

    private func playShred(_ title: String) {
        shredTitle = title
        shredTask?.cancel()
        shredTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }
            if self?.shredTitle == title { self?.shredTitle = nil }
        }
    }

    private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func noteTransfer(_ id: String, fraction: Double, received: Int64) {
        if let i = transferJobs.firstIndex(where: { $0.id == id }) {
            transferJobs[i].received = received
        }
        patchDownload(id) { task in
            task.progress = fraction
        }
    }

    private func noteResume(_ id: String, path: String) {
        if let i = transferJobs.firstIndex(where: { $0.id == id }) {
            transferJobs[i].resumeFile = path
            transferJobs[i].retried = true
            scheduleSave()
        }
    }

    private func finishTransfer(_ id: String, file: URL?, error: String?) {
        guard let index = transferJobs.firstIndex(where: { $0.id == id }) else { return }
        let job = transferJobs[index]
        if let file {
            transferJobs[index].done = true
            transferJobs[index].error = nil
            if job.lane.listsInLibrary {
                patchDownload(id) { $0.done = true; $0.progress = 1; $0.localPath = file.path; $0.error = nil }
                let source = job.entry
                let saved = MediaEntry(
                    kind: source?.kind == .image ? .image : .video,
                    title: job.title,
                    localPath: file.path,
                    coverURL: source?.coverURL,
                    platform: PlatformID.local,
                    author: source?.author ?? "",
                    source: "download",
                    byteSize: taskByteSize(file.path)
                )
                library.entries.insert(saved, at: 0)
                feedOrder.insert(saved.id, at: 0)
                showToast("下载完成")
            }
        } else {
            transferJobs[index].error = error ?? "下载失败"
            if job.lane.listsInLibrary {
                patchDownload(id) { $0.error = error ?? "下载失败" }
                showToast(error ?? "下载失败")
            }
        }
        scheduleSave()
    }

    func armDwell(for entry: MediaEntry?) {
        dwellTask?.cancel()
        guard let entry, entry.kind == .image, entry.dwellSeconds > 0 else { return }
        let seconds = entry.dwellSeconds
        let id = entry.id
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.feedItems.indices.contains(self.feedIndex), self.feedItems[self.feedIndex].id == id else { return }
            if self.feedIndex + 1 < self.feedItems.count { self.feedIndex += 1 }
        }
    }
}

struct ComposerDraft: Identifiable {
    let id = UUID()
    var authorId: String
    var text: String = ""
    var attachments: [Attachment] = []
}

final class DownloadBox: NSObject, URLSessionDownloadDelegate {
    let taskId: String
    var onProgress: ((Double) -> Void)?
    var onFinish: ((URL?, String?) -> Void)?
    weak var session: URLSession?
    private var moved: URL?

    init(taskId: String) { self.taskId = taskId }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let p = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        DispatchQueue.main.async { self.onProgress?(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Paths.ensureDirs()
        let ext = downloadTask.response?.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
        let dest = Paths.media.appendingPathComponent("dl_\(IDs.new()).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: location, to: dest)
            moved = dest
        } catch {
            moved = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let file = moved
        let message = error?.localizedDescription
        DispatchQueue.main.async {
            if let file, error == nil { self.onFinish?(file, nil) }
            else { self.onFinish?(nil, message ?? (file == nil ? "文件不完整" : "下载失败")) }
        }
    }
}
