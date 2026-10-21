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

    let feedPlayer = PlayerSession()
    let localTransport = LocalTransport()
    let remoteTransport = RemoteTransport(config: ChatServerConfig())
    private let writer = StoreWriter()
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var downloadSessions: [String: URLSession] = [:]

    init() {
        Paths.ensureDirs()
        if let data = AtomicFile.read(Paths.settingsFile), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        settings.ringAnim = RingAnimPick.normalize(settings.ringAnim)
        if let data = AtomicFile.read(Paths.libraryFile), let lib = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) {
            library = lib
        } else {
            library = LibrarySnapshot()
        }
        if let data = AtomicFile.read(Paths.socialFile), let s = try? SocialJSON.decode(data) {
            social = s
        } else {
            social = .fresh()
        }
        feedOrder = library.entries.sorted { $0.createdAt > $1.createdAt }.map(\.id)
        clampFeed()
    }

    var feedItems: [MediaEntry] {
        let map = Dictionary(uniqueKeysWithValues: library.entries.map { ($0.id, $0) })
        return feedOrder.compactMap { map[$0] }.filter { entry in
            if entry.hidden { return false }
            switch feedScope {
            case .all: return true
            case .local: return entry.localPath != nil
            case .online: return entry.localPath == nil
            }
        }
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
        clampFeed()
        scheduleSave()
        showToast("已删除", undo: { [weak self] in
            guard let self else { return }
            self.library.entries.insert(old, at: 0)
            self.feedOrder.insert(old.id, at: 0)
            self.scheduleSave()
            self.showToast("已撤销")
        })
    }

    func addRemote(_ entry: MediaEntry) {
        var copy = entry
        if library.entries.contains(where: { $0.remoteURL == copy.remoteURL && copy.remoteURL != nil && $0.platform == copy.platform }) {
            if let existing = library.entries.first(where: { $0.remoteURL == copy.remoteURL }) { focus(id: existing.id) }
            showToast("已经在库里")
            return
        }
        copy.id = IDs.new()
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

    func download(_ entry: MediaEntry) {
        let policy = DownloadPolicy.canDownload(entry)
        guard policy.ok, let remote = entry.remoteURL, let url = URL(string: remote), !DownloadPolicy.isStreamURL(remote) else {
            showToast(policy.reason ?? "不能下载")
            return
        }
        if entry.localPath != nil { showToast("已经在本地"); return }
        var task = DownloadTask(url: remote, title: entry.title)
        library.downloads.insert(task, at: 0)
        scheduleSave()
        let box = DownloadBox(taskId: task.id)
        box.onProgress = { [weak self] p in
            self?.patchDownload(task.id) { $0.progress = p }
        }
        box.onFinish = { [weak self] file, error in
            guard let self else { return }
            self.downloadSessions[task.id] = nil
            if let file {
                self.patchDownload(task.id) { $0.done = true; $0.progress = 1; $0.localPath = file.path; $0.error = nil }
                let saved = MediaEntry(kind: entry.kind == .image ? .image : .video, title: entry.title, localPath: file.path, coverURL: entry.coverURL, platform: PlatformID.local, author: entry.author, source: "download", byteSize: taskByteSize(file.path))
                self.library.entries.insert(saved, at: 0)
                self.feedOrder.insert(saved.id, at: 0)
                self.scheduleSave()
                self.showToast("下载完成")
            } else {
                self.patchDownload(task.id) { $0.error = error ?? "下载失败" }
                self.showToast(error ?? "下载失败")
            }
        }
        let session = URLSession(configuration: .default, delegate: box, delegateQueue: nil)
        box.session = session
        downloadSessions[task.id] = session
        session.downloadTask(with: url).resume()
        showToast("开始下载")
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
        showToast("已删除", undo: { [weak self] in self?.editSocial { $0 = SocialOps.upsertMoment($0, old) } })
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
            let remap: (String) -> String = { $0 == incoming.selfId ? current.selfId : $0 }
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
            remoteURL: entry.remoteURL,
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
        let writer = self.writer
        saveTask = Task {
            if Task.isCancelled { return }
            let g = await writer.bump()
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await writer.writeIfCurrent(generation: g, social: socialData, library: libraryData, settings: settingsData)
        }
    }

    func saveSettings() { scheduleSave() }

    func flush() async {
        saveTask?.cancel()
        let socialData = SocialJSON.encode(social)
        let libraryData = (try? JSONEncoder().encode(library)) ?? Data()
        let settingsData = (try? JSONEncoder().encode(settings)) ?? Data()
        let g = await writer.bump()
        await writer.writeIfCurrent(generation: g, social: socialData, library: libraryData, settings: settingsData)
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
