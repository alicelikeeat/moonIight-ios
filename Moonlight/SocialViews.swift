import PhotosUI
import SwiftUI
import UIKit

struct MomentsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var theme
    @Environment(\.colorScheme) private var scheme

    private var colors: MoonColors { app.settings.showsBackdrop(.moments) ? .media : theme }
    @State private var showFriends = false
    @State private var showChats = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if app.social.moments.isEmpty {
                        VStack(spacing: 10) {
                            Text("朋友圈还是空的").font(.system(size: 18, weight: .semibold))
                            Text("写一条，或者载入几个示例好友。").font(.system(size: 13)).foregroundColor(colors.textDim)
                            Button("载入示例") { app.loadDemo() }
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .moonGlass(colors, radius: 16)
                                .accessibilityIdentifier("moments.demo")
                        }
                        .padding(.top, 48)
                    }
                    ForEach(app.social.timeline) { moment in
                        MomentCard(moment: moment)
                    }
                }
                .padding(16)
                .padding(.bottom, 100)
            }
            .background {
                ZStack {
                    SystemGlassFill(dark: colors.dark)
                    PageBackdrop(page: .moments)
                }
            }
            .navigationTitle("朋友圈")
            .environment(\.colorScheme, app.settings.showsBackdrop(.moments) ? .dark : scheme)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showFriends = true } label: { Image(systemName: "person.2") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button { showChats = true } label: {
                            Image(systemName: "bubble.left")
                                .overlay(alignment: .topTrailing) {
                                    if app.social.totalUnread > 0 {
                                        Text("\(app.social.totalUnread)").font(.system(size: 9, weight: .bold))
                                            .padding(3).background(colors.heart, in: Circle()).offset(x: 8, y: -6)
                                    }
                                }
                        }
                        Button {
                            app.composer = ComposerDraft(authorId: app.social.selfId)
                        } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
            .navigationDestination(isPresented: $showFriends) { FriendsView() }
            .navigationDestination(isPresented: $showChats) { ChatListView() }
        }
    }
}

struct MomentCard: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @EnvironmentObject private var hold: HoldController
    @Environment(\.moon) private var theme
    private var colors: MoonColors { app.settings.showsBackdrop(.moments) ? .media : theme }
    var moment: Moment
    @State private var showComment = false

    var body: some View {
        let author = app.social.contact(moment.authorId)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                avatar(author, 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(author?.name ?? "某人").font(.system(size: 15, weight: .semibold))
                    Text(RelTime.string(moment.createdAt)).font(.system(size: 11)).foregroundColor(colors.textDim)
                }
                Spacer()
            }
            if !moment.text.isEmpty {
                Text(moment.text).font(.system(size: 16))
            }
            media
            HStack(spacing: 18) {
                react("hand.thumbsup", moment.likes.count, moment.likes.contains(app.social.selfId)) { app.toggleLike(moment: moment.id, who: app.social.selfId) }
                react("hand.thumbsdown", moment.dislikes.count, moment.dislikes.contains(app.social.selfId)) { app.toggleDislike(moment: moment.id, who: app.social.selfId) }
                Button { showComment = true } label: {
                    Label("\(moment.comments.count)", systemImage: "text.bubble")
                        .font(.system(size: 13, weight: .medium))
                }
                .accessibilityIdentifier("moment.comment")
                Spacer()
            }
            .foregroundColor(colors.text)
            ForEach(CommentTree.flat(moment.comments)) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text(app.social.contact(line.comment.authorId)?.name ?? "").font(.system(size: 13, weight: .semibold))
                    Text(line.comment.text).font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(line.depth) * 16)
            }
        }
        .padding(14)
        .moonGlass(colors, radius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .holdTrack(onBegan: { point in
            TabChrome.setSuspended(true)
            openRing(at: point)
        }, onChanged: { point in
            ring.finger = point
            ring.fingerDown = true
            hold.move(point)
        }, onEnded: { point in
            let outcome = hold.lift()
            ring.fingerDown = false
            ring.finger = point
            if outcome != .timed && outcome != .center {
                if ring.session?.drop == true { ring.releaseFinger(at: point) }
                else if ring.session?.select == .drag || ring.session?.select == .slider { ring.selectDrag(at: point) }
            }
            TabChrome.setSuspended(false)
        }, ownsLarge: true)
        .onTapGesture(count: 2) { app.likeOnly(moment: moment.id, who: app.social.selfId); Haptics.soft() }
        .sheet(isPresented: $showComment) {
            CommentThread(momentID: moment.id)
        }
    }

    @ViewBuilder private var media: some View {
        if let first = moment.attachments.first {
            if first.kind == .video {
                MomentVideo(momentID: moment.id, attachment: first)
            } else if moment.attachments.count == 1 {
                RemoteOrLocalImage(url: first.displayURL, art: first.coverURL, mode: .fill)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(moment.attachments.prefix(4)) { att in
                        RemoteOrLocalImage(url: att.displayURL, art: att.coverURL, mode: .fill)
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    private func react(_ symbol: String, _ count: Int, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("\(count)", systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(on ? colors.accent : colors.text)
        }
    }

    private func openRing(at origin: CGPoint) {
        let friends = app.social.friends
        let mine = moment.authorId == app.social.selfId
        ring.finger = origin
        ring.fingerDown = true
        var bubbles = [
            RingItem(title: "赞", systemImage: "heart") { app.toggleLike(moment: moment.id, who: app.social.selfId) },
            RingItem(title: "踩", systemImage: "hand.thumbsdown") { app.toggleDislike(moment: moment.id, who: app.social.selfId) },
            RingItem(title: "评论", systemImage: "bubble.left") { showComment = true },
            RingItem(title: "转发到聊天", systemImage: "paperplane", children: friends.prefix(6).map { friend in
                RingItem(title: friend.name, systemImage: "person") {
                    let conv = app.openChat(with: [app.social.selfId, friend.id])
                    app.send(convId: conv.id, senderId: app.social.selfId, text: moment.text)
                }
            }) {},
        ]
        if mine {
            bubbles.append(RingItem(title: "删除", systemImage: "trash", key: "delete", destructive: true) { app.deleteMoment(moment.id) })
        }
        ring.present(origin: origin, items: bubbles, groups: [
            MenuGroup(title: "编辑", items: [
                RingItem(title: "复制文字", systemImage: "doc.on.doc") { UIPasteboard.general.string = moment.text; app.showToast("已复制") },
                RingItem(title: "改发布者", systemImage: "person.crop.circle", children: ([app.social.me] + app.social.friends).map { c in
                    RingItem(title: c.name, systemImage: "person") {
                        app.editSocial { s in
                            s.moments = s.moments.map { m in
                                guard m.id == moment.id else { return m }
                                var m = m
                                m.authorId = c.id
                                return m
                            }
                        }
                    }
                }) {},
            ]),
            MenuGroup(title: "危险", danger: true, items: [
                RingItem(title: "删除", systemImage: "trash", key: "delete", destructive: true) { app.deleteMoment(moment.id) },
            ]),
        ], settings: app.settings)
    }

    @ViewBuilder private func avatar(_ c: Contact?, _ size: CGFloat) -> some View {
        if let path = c?.avatarPath, FileManager.default.fileExists(atPath: path) {
            RemoteOrLocalImage(url: URL(fileURLWithPath: path), mode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle().fill(Monogram.color(c?.avatarColor ?? 0))
                .frame(width: size, height: size)
                .overlay(Text(Monogram.letter(c?.name ?? "?")).font(.system(size: size * 0.4, weight: .semibold)).foregroundColor(.black.opacity(0.75)))
        }
    }
}

struct MomentVideo: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @EnvironmentObject private var hold: HoldController
    var momentID: String
    var attachment: Attachment
    @StateObject private var session = PlayerSession()
    @State private var claimed = false

    var body: some View {
        ZStack {
            if attachment.kind == .embed, let raw = attachment.remoteURL, let url = URL(string: raw) {
                WebEmbedView(url: url)
            } else if let url = playURL {
                PlayerLayerView(player: session.player, gravity: .resizeAspectFill)
                if !session.showsPlaying {
                    Image(systemName: "play.fill").foregroundColor(.white).padding(12).background(.black.opacity(0.3), in: Circle())
                }
            } else {
                RemoteOrLocalImage(url: attachment.displayURL, art: attachment.coverURL, mode: .fill)
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .modifier(MomentPlayTap(enabled: attachment.kind != .embed) {
            session.toggle()
        })
        .holdTrack(onBegan: { point in beganHold(point) }, onChanged: { hold.move($0) }, onEnded: { _ in hold.lift() })
        .onAppear {
            let allow = app.claimMomentSlot(momentID)
            claimed = allow
            if allow, let url = playURL {
                session.loop = true
                session.load(url: url, autoplay: true, muted: true)
            }
        }
        .onDisappear {
            if claimed { app.releaseMomentSlot(momentID) }
            session.pause()
        }
    }

    private func beganHold(_ point: CGPoint) {
        let entry = playerEntry
        let items = videoRing(entry)
        let bounds = UIScreen.main.bounds
        let deferOpen = app.settings.timedOn || HoldMachine.inCenter(
            x: Float(point.x), y: Float(point.y), width: Float(bounds.width), height: Float(bounds.height)
        ) && app.settings.centerPanel
        let present = {
            ring.present(origin: point, items: items, groups: [], settings: app.settings, overMedia: false)
        }
        if deferOpen {
            hold.arm(
                origin: point,
                settings: app.settings,
                catalog: RingCatalog(items: items, groups: [], context: .momentVideo, title: entry.title, overMedia: false),
                onRelease: { app.fullPlayer = entry },
                onDeferredOpen: present
            )
        } else {
            app.fullPlayer = entry
        }
    }

    private var playerEntry: MediaEntry {
        let embed = attachment.kind == .embed
        return MediaEntry(
            id: attachment.libraryEntryId ?? attachment.id,
            kind: embed ? .embed : .video,
            title: attachment.title.isEmpty ? "视频" : attachment.title,
            localPath: attachment.localPath,
            remoteURL: embed ? nil : attachment.remoteURL,
            coverURL: attachment.coverURL,
            platform: attachment.localPath == nil ? (embed ? PlatformID.web : PlatformID.url) : PlatformID.local,
            embedURL: embed ? attachment.remoteURL : nil,
            source: "moment"
        )
    }

    private func videoRing(_ entry: MediaEntry) -> [RingItem] {
        [
            RingItem(title: session.showsPlaying ? "暂停" : "播放", systemImage: session.showsPlaying ? "pause" : "play", key: "mv_play") {
                session.toggle()
            },
            RingItem(title: "进入播放页面", systemImage: "arrow.up.left.and.arrow.down.right", key: "mv_open") {
                app.fullPlayer = entry
            },
            RingItem(title: session.isMuted ? "打开声音" : "静音", systemImage: "speaker", key: "mv_mute") {
                session.isMuted.toggle()
            },
            RingItem(title: "保存", systemImage: "square.and.arrow.down", children: [
                RingItem(title: "保存到相册", systemImage: "square.and.arrow.down", key: "mv_save") {
                    if let id = attachment.libraryEntryId, let item = app.entry(id) { app.saveToPhotos(item) }
                    else { app.showToast("这支视频还没在库里") }
                },
                RingItem(title: "下载", systemImage: "arrow.down.circle", enabled: entry.localPath == nil && DownloadPolicy.canDownload(entry).ok) {
                    app.download(entry)
                },
            ]) {},
        ]
    }

    private var playURL: URL? {
        if attachment.kind == .embed { return nil }
        if let path = attachment.localPath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        if let remote = attachment.remoteURL { return URL(string: remote) }
        return nil
    }
}

private struct MomentPlayTap: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onTapGesture {
                guard !PressGate.suppressTap else { return }
                action()
            }
        } else {
            content
        }
    }
}

struct FriendsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.moon) private var colors
    @State private var editing: Contact?
    @State private var creating = false
    @State private var chatID: String?

    var body: some View {
        List {
            ForEach(app.social.friends) { friend in
                Button {
                    chatID = app.openChat(with: [app.social.selfId, friend.id]).id
                } label: {
                    HStack {
                        Circle().fill(Monogram.color(friend.avatarColor)).frame(width: 40, height: 40)
                            .overlay(Text(Monogram.letter(friend.name)).foregroundColor(.black.opacity(0.7)))
                        VStack(alignment: .leading) {
                            Text(friend.name)
                            Text(friend.bio).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    ring.present(origin: CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY), items: [
                        RingItem(title: "聊天", systemImage: "bubble.left") {
                            chatID = app.openChat(with: [app.social.selfId, friend.id]).id
                        },
                        RingItem(title: "以 TA 发动态", systemImage: "square.and.pencil") {
                            app.composer = ComposerDraft(authorId: friend.id)
                        },
                        RingItem(title: "编辑", systemImage: "pencil") { editing = friend },
                        RingItem(title: "替 TA 聊天", systemImage: "person.2") {
                            if let other = app.social.friends.first(where: { $0.id != friend.id }) {
                                chatID = app.openChat(with: [friend.id, other.id]).id
                            } else { app.showToast("再添加一位好友") }
                        },
                    ], groups: [
                        MenuGroup(title: "自动回复", items: [
                            RingItem(title: friend.autoReplyOn ? "关闭自动回复" : "打开自动回复", systemImage: "text.bubble") {
                                var copy = friend
                                copy.autoReplyOn.toggle()
                                if copy.autoReplies.isEmpty { copy.autoReplies = ["在的", "等我一下", "哈哈"] }
                                app.upsertFriend(copy)
                            },
                        ]),
                        MenuGroup(title: "危险", danger: true, items: [
                            RingItem(title: "删除", systemImage: "trash") { app.deleteFriend(friend.id) },
                        ]),
                    ], settings: app.settings)
                })
            }
        }
        .navigationTitle("好友")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $creating) { FriendEditor(contact: nil) }
        .sheet(item: $editing) { friend in FriendEditor(contact: friend) }
        .navigationDestination(isPresented: Binding(get: { chatID != nil }, set: { if !$0 { chatID = nil } })) {
            if let chatID { ChatThreadView(conversationID: chatID) }
        }
    }
}

struct FriendEditor: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var contact: Contact?
    @State private var name = ""
    @State private var bio = ""
    @State private var replies = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("名字", text: $name)
                TextField("简介", text: $bio)
                TextField("自动回复，用逗号分开", text: $replies)
            }
            .navigationTitle(contact == nil ? "新好友" : "编辑好友")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var c = contact ?? Contact(name: name)
                        c.name = name.isEmpty ? "未命名" : name
                        c.bio = bio
                        c.autoReplies = replies.split { $0 == "," || $0 == "，" }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        c.isVirtual = true
                        app.upsertFriend(c)
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = contact?.name ?? ""
                bio = contact?.bio ?? ""
                replies = contact?.autoReplies.joined(separator: "，") ?? ""
            }
        }
    }
}

struct ChatListView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var open: Conversation?

    private var onBackdrop: Bool { app.settings.showsBackdrop(.chat) }

    var body: some View {
        List {
            if app.social.conversations.isEmpty {
                Text("还没有对话。在好友页点一下就开始。").foregroundColor(.secondary)
            }
            ForEach(app.social.conversations.sorted { $0.updatedAt > $1.updatedAt }) { conv in
                Button { open = conv } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(title(conv)).font(.system(size: 16, weight: .semibold))
                            Spacer()
                            if app.social.unread(conv.id) > 0 {
                                Text("\(app.social.unread(conv.id))")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.3)))
                            }
                        }
                        Text(app.social.lastMessage(conv.id)?.text ?? " ").lineLimit(1).font(.system(size: 13)).foregroundColor(.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background {
            ZStack {
                if !onBackdrop { SystemGlassFill(dark: scheme == .dark) }
                PageBackdrop(page: .chat)
            }
        }
        .environment(\.colorScheme, onBackdrop ? .dark : scheme)
        .navigationTitle("消息")
        .navigationDestination(isPresented: Binding(get: { open != nil }, set: { if !$0 { open = nil } })) {
            if let open { ChatThreadView(conversationID: open.id) }
        }
    }

    private func title(_ conv: Conversation) -> String {
        if let title = conv.title, !title.isEmpty { return title }
        let names = conv.memberIds.compactMap { app.social.contact($0)?.name }
        return names.joined(separator: "、")
    }
}

struct CommentThread: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var momentID: String
    @State private var text = ""
    @State private var replyTo: String?

    var body: some View {
        let comments = app.social.moments.first { $0.id == momentID }?.comments ?? []
        NavigationStack {
            List {
                if comments.isEmpty {
                    Text("还没有评论。写第一条，也可以回复某一条。").foregroundColor(.secondary)
                }
                ForEach(CommentTree.flat(comments)) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.social.contact(line.comment.authorId)?.name ?? "某人")
                            .font(.system(size: 13, weight: .semibold))
                        Text(line.comment.text).font(.system(size: 15))
                        HStack {
                            Button("回复") { replyTo = line.comment.id }
                            Button("删除") { app.deleteComment(moment: momentID, id: line.comment.id) }
                                .foregroundColor(.red)
                        }
                        .font(.system(size: 13))
                    }
                    .padding(.leading, CGFloat(line.depth) * 16)
                }
            }
            .accessibilityIdentifier("comment.thread")
            .navigationTitle("评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("完成") { dismiss() }.accessibilityIdentifier("comment.done")
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField(replyTo == nil ? "说点什么" : "回复这条", text: $text)
                        .textFieldStyle(.roundedBorder)
                    Button("发送") {
                        app.addComment(moment: momentID, author: app.social.selfId, text: text, replyTo: replyTo)
                        text = ""
                        replyTo = nil
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
                .padding(12)
                .background(.ultraThinMaterial)
            }
        }
    }
}

struct ChatThreadView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var ring: RingController
    @Environment(\.colorScheme) private var scheme
    var conversationID: String
    @State private var text = ""
    @State private var senderId: String = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var pending: Attachment?

    var body: some View {
        let conv = app.social.conversations.first { $0.id == conversationID }
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(app.social.messagesOf(conversationID)) { message in
                            bubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .moonOnChange(of: app.social.messages.count) { _ in
                    if let last = app.social.messagesOf(conversationID).last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if let pending {
                HStack {
                    RemoteOrLocalImage(url: pending.displayURL, mode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("待发送的图片")
                        .font(.system(size: 13))
                    Spacer()
                    Button("取消") { self.pending = nil }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityIdentifier("chat.photo")
                Menu {
                    ForEach(speakers) { person in
                        Button(person.name) { senderId = person.id }
                    }
                } label: {
                    Text(app.social.contact(senderId)?.name ?? "我")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                TextField("写一句。虚拟好友的每一句都由你来写。", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("发送") {
                    let files = pending.map { [$0] } ?? []
                    app.send(convId: conversationID, senderId: senderId.isEmpty ? app.social.selfId : senderId, text: text, attachments: files)
                    text = ""
                    pending = nil
                }
                .font(.system(size: 15, weight: .semibold))
            }
            .padding(10)
            if let conv {
                Button(conv.remote ? "这条对话会发给服务器" : "这条对话只在本机") {
                    guard !app.settings.chatServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        app.showToast("到设置里填写聊天服务器")
                        return
                    }
                    app.editSocial { state in
                        state.conversations = state.conversations.map { item in
                            guard item.id == conv.id else { return item }
                            var item = item
                            item.remote.toggle()
                            return item
                        }
                    }
                }
                .font(.system(size: 13))
                .padding(.bottom, 8)
                .accessibilityIdentifier("chat.remote")
            }
        }
        .moonOnChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let saved = app.storeChatImage(data) {
                    pending = saved
                } else {
                    app.showToast("这张图没有放进聊天")
                }
                photoItem = nil
            }
        }
        .background {
            ZStack {
                if !app.settings.showsBackdrop(.chat) { SystemGlassFill(dark: scheme == .dark) }
                PageBackdrop(page: .chat)
            }
        }
        .environment(\.colorScheme, app.settings.showsBackdrop(.chat) ? .dark : scheme)
        .navigationTitle(conv?.title ?? "聊天")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if senderId.isEmpty { senderId = app.social.selfId }
            app.markRead(conversationID)
        }
    }

    private var speakers: [Contact] {
        let conv = app.social.conversations.first { $0.id == conversationID }
        let ids = conv?.memberIds ?? [app.social.selfId]
        let people = ids.compactMap { app.social.contact($0) }
        return people.isEmpty ? [app.social.me] : people
    }

    private func bubble(_ message: Message) -> some View {
        let mine = message.senderId == app.social.selfId
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                Text(app.social.contact(message.senderId)?.name ?? "")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                ForEach(message.attachments.filter { $0.kind == .image }) { file in
                    RemoteOrLocalImage(url: file.displayURL, mode: .fill)
                        .frame(width: 160, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("chat.image")
                }
                Text(message.text.isEmpty ? " " : message.text)
                    .font(.system(size: 16))
                    .padding(10)
                    .background(mine ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                if mine {
                    Text(message.status.mark)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(message.status.accent ? Color.accentColor : .secondary)
                }
                if let error = message.error {
                    Text(error).font(.system(size: 11)).foregroundColor(.red)
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            ring.present(origin: CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY), items: [
                RingItem(title: "复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text },
                RingItem(title: "改发言人", systemImage: "person", children: speakers.map { person in
                    RingItem(title: person.name, systemImage: "person") {
                        app.editSocial { s in
                            s.messages = s.messages.map { m in
                                guard m.id == message.id else { return m }
                                var m = m
                                m.senderId = person.id
                                return m
                            }
                        }
                    }
                }) {},
                RingItem(title: "撤回", systemImage: "arrow.uturn.backward") { app.deleteMessage(message.id) },
            ], groups: [
                MenuGroup(title: "危险", danger: true, items: [
                    RingItem(title: "删除", systemImage: "trash") { app.deleteMessage(message.id) },
                ]),
            ], settings: app.settings)
        }
    }
}

