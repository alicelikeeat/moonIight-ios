import Foundation

enum AttachmentKind: String, Codable, Sendable { case image = "IMAGE", video = "VIDEO", embed = "EMBED" }

enum MessageStatus: String, Codable, Sendable {
    case local = "LOCAL"
    case sending = "SENDING"
    case sent = "SENT"
    case delivered = "DELIVERED"
    case read = "READ"
    case failed = "FAILED"

    /// Subtle mark under the user's own bubbles.
    var mark: String {
        switch self {
        case .local, .sending: return "⏱"
        case .sent: return "✓"
        case .delivered: return "✓✓"
        case .read: return "✓✓"
        case .failed: return "!"
        }
    }
    var accent: Bool { self == .read }
}

struct MediaFocus: Codable, Equatable, Sendable {
    var x: Float = 0.5
    var y: Float = MediaFocus.defaultY
    var scale: Float = 1
    static let defaultY: Float = 0.3
    static let maxScale: Float = 4

    func clamped() -> MediaFocus {
        MediaFocus(x: min(1, max(0, x)), y: min(1, max(0, y)), scale: min(Self.maxScale, max(1, scale)))
    }
    func encode() -> String { String(format: "%.4f,%.4f,%.4f", x, y, scale) }
    static func decode(_ s: String?) -> MediaFocus? {
        guard let parts = s?.split(separator: ",").compactMap({ Float($0.trimmingCharacters(in: .whitespaces)) }), parts.count == 3 else { return nil }
        return MediaFocus(x: parts[0], y: parts[1], scale: parts[2]).clamped()
    }
}

struct SavedMedia: Codable, Equatable, Sendable {
    var path: String
    var video: Bool
    var focus: MediaFocus?
}

struct Contact: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var name: String
    var bio: String = ""
    var avatarPath: String?
    var avatarColor: Int = 0
    var avatarVideo: Bool = false
    var coverPath: String?
    var coverVideo: Bool = false
    var avatarFocus: MediaFocus?
    var coverFocus: MediaFocus?
    var prevAvatar: SavedMedia?
    var prevCover: SavedMedia?
    var isVirtual: Bool = true
    var isSelf: Bool = false
    var remoteUserId: String?
    var autoReplyOn: Bool = false
    var autoReplies: [String] = []
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}

struct Attachment: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var kind: AttachmentKind
    var libraryEntryId: String?
    var localPath: String?
    var coverURL: String?
    var remoteURL: String?
    var remoteId: String?
    var mime: String?
    var sizeBytes: Int64 = 0
    var title: String = ""

    var displayURL: URL? {
        if let localPath, FileManager.default.fileExists(atPath: localPath) { return URL(fileURLWithPath: localPath) }
        if let coverURL, let u = URL(string: coverURL) { return u }
        if let remoteURL, let u = URL(string: remoteURL) { return u }
        return nil
    }
}

struct Comment: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var authorId: String
    var text: String
    var replyToId: String?
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}

struct Moment: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var authorId: String
    var text: String = ""
    var attachments: [Attachment] = []
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var editedAt: Int64?
    var likes: [String] = []
    var dislikes: [String] = []
    var comments: [Comment] = []
}

struct Conversation: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var memberIds: [String]
    var title: String?
    var isGroup: Bool = false
    var remote: Bool = false
    var remoteId: String?
    var pinned: Bool = false
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var updatedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var readAt: Int64 = 0
}

struct Message: Codable, Identifiable, Equatable, Sendable {
    var id: String = IDs.new()
    var conversationId: String
    var senderId: String
    var text: String = ""
    var attachments: [Attachment] = []
    var createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var serverAt: Int64?
    var status: MessageStatus = .local
    var auto: Bool = false
    var error: String?
    var orderKey: Int64 { serverAt ?? createdAt }
}

struct SocialState: Codable, Equatable, Sendable {
    var selfId: String
    var contacts: [Contact]
    var moments: [Moment] = []
    var conversations: [Conversation] = []
    var messages: [Message] = []
    var schema: Int = SocialState.schemaVersion
    static let schemaVersion = 2

    var me: Contact { contacts.first { $0.id == selfId } ?? Contact(id: selfId, name: "我", isVirtual: false, isSelf: true) }
    func contact(_ id: String) -> Contact? { contacts.first { $0.id == id } }
    var friends: [Contact] { contacts.filter { !$0.isSelf } }
    func messagesOf(_ convId: String) -> [Message] {
        messages.filter { $0.conversationId == convId }.sorted { $0.orderKey < $1.orderKey }
    }
    func lastMessage(_ convId: String) -> Message? {
        messages.filter { $0.conversationId == convId }.max { $0.orderKey < $1.orderKey }
    }
    var timeline: [Moment] { moments.sorted { $0.createdAt > $1.createdAt } }
    func unread(_ convId: String) -> Int {
        guard let c = conversations.first(where: { $0.id == convId }) else { return 0 }
        if !c.memberIds.contains(selfId) { return 0 }
        return messages.filter { $0.conversationId == convId && $0.senderId != selfId && $0.createdAt > c.readAt }.count
    }
    var totalUnread: Int { conversations.reduce(0) { $0 + unread($1.id) } }

    static func fresh() -> SocialState {
        let me = Contact(name: "我的朋友圈", bio: "测试中", avatarColor: 0, isVirtual: false, isSelf: true)
        return SocialState(selfId: me.id, contacts: [me])
    }
}

/// Roots sit at depth 0. A reply is indented under its parent. Deleting a comment takes its replies with it.
enum CommentTree {
    struct Line: Identifiable, Equatable {
        var comment: Comment
        var depth: Int
        var id: String { comment.id }
    }

    static func flat(_ comments: [Comment]) -> [Line] {
        let ids = Set(comments.map(\.id))
        let roots = comments.filter { c in
            guard let parent = c.replyToId else { return true }
            return !ids.contains(parent)
        }.sorted { $0.createdAt < $1.createdAt }
        var out: [Line] = []
        func walk(_ comment: Comment, _ depth: Int, _ seen: Set<String>) {
            if seen.contains(comment.id) || depth > 12 { return }
            out.append(Line(comment: comment, depth: depth))
            var next = seen
            next.insert(comment.id)
            let kids = comments.filter { $0.replyToId == comment.id }.sorted { $0.createdAt < $1.createdAt }
            for kid in kids { walk(kid, depth + 1, next) }
        }
        for root in roots { walk(root, 0, []) }
        return out
    }

    static func removing(_ comments: [Comment], id: String) -> [Comment] {
        var drop: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for comment in comments {
                if let parent = comment.replyToId, drop.contains(parent), drop.insert(comment.id).inserted {
                    grew = true
                }
            }
        }
        return comments.filter { !drop.contains($0.id) }
    }
}

enum SocialOps {
    static func upsertContact(_ s: SocialState, _ c: Contact) -> SocialState {
        var s = s
        if s.contacts.contains(where: { $0.id == c.id }) {
            s.contacts = s.contacts.map { $0.id == c.id ? c : $0 }
        } else {
            s.contacts.append(c)
        }
        return s
    }

    static func deleteContact(_ s: SocialState, _ id: String) -> SocialState {
        if id == s.selfId { return s }
        let convs: [Conversation] = s.conversations.compactMap { c in
            if !c.memberIds.contains(id) { return c }
            let left = c.memberIds.filter { $0 != id }
            if !c.isGroup || left.count < 2 { return nil }
            var copy = c
            copy.memberIds = left
            return copy
        }
        let convIds = Set(convs.map(\.id))
        var s = s
        s.contacts.removeAll { $0.id == id }
        s.moments = s.moments.filter { $0.authorId != id }.map { m in
            var m = m
            m.likes.removeAll { $0 == id }
            m.dislikes.removeAll { $0 == id }
            m.comments.removeAll { $0.authorId == id }
            return m
        }
        s.conversations = convs
        s.messages = s.messages.filter { convIds.contains($0.conversationId) && $0.senderId != id }
        return s
    }

    static func upsertMoment(_ s: SocialState, _ m: Moment) -> SocialState {
        var s = s
        if let i = s.moments.firstIndex(where: { $0.id == m.id }) { s.moments[i] = m } else { s.moments.append(m) }
        return s
    }

    static func deleteMoment(_ s: SocialState, _ id: String) -> SocialState {
        var s = s
        s.moments.removeAll { $0.id == id }
        return s
    }

    /// 赞 and 踩 are mutually exclusive. Tapping the one you already have removes it.
    static func toggleLike(_ s: SocialState, _ momentId: String, _ who: String) -> SocialState {
        var s = s
        s.moments = s.moments.map { m in
            guard m.id == momentId else { return m }
            var m = m
            if m.likes.contains(who) {
                m.likes.removeAll { $0 == who }
            } else {
                m.likes.append(who)
                m.dislikes.removeAll { $0 == who }
            }
            return m
        }
        return s
    }

    static func toggleDislike(_ s: SocialState, _ momentId: String, _ who: String) -> SocialState {
        var s = s
        s.moments = s.moments.map { m in
            guard m.id == momentId else { return m }
            var m = m
            if m.dislikes.contains(who) {
                m.dislikes.removeAll { $0 == who }
            } else {
                m.dislikes.append(who)
                m.likes.removeAll { $0 == who }
            }
            return m
        }
        return s
    }

    /// Double-tap never removes a like.
    static func likeOnly(_ s: SocialState, _ momentId: String, _ who: String) -> SocialState {
        guard let m = s.moments.first(where: { $0.id == momentId }), !m.likes.contains(who) else { return s }
        return toggleLike(s, momentId, who)
    }

    static func addComment(_ s: SocialState, _ momentId: String, _ c: Comment) -> SocialState {
        var s = s
        s.moments = s.moments.map { m in
            guard m.id == momentId else { return m }
            var m = m
            m.comments.append(c)
            return m
        }
        return s
    }

    static func deleteComment(_ s: SocialState, _ momentId: String, _ commentId: String) -> SocialState {
        var s = s
        s.moments = s.moments.map { m in
            guard m.id == momentId else { return m }
            var m = m
            m.comments = CommentTree.removing(m.comments, id: commentId)
            return m
        }
        return s
    }

    static func markRead(_ s: SocialState, _ convId: String, _ at: Int64) -> SocialState {
        var s = s
        s.conversations = s.conversations.map { c in
            guard c.id == convId, c.readAt < at else { return c }
            var c = c
            c.readAt = at
            return c
        }
        return s
    }

    static func conversationFor(_ s: SocialState, members: [String], title: String? = nil, group: Bool? = nil) -> (SocialState, Conversation) {
        var seen = [String]()
        for m in members where !seen.contains(m) { seen.append(m) }
        let isGroup = group ?? (seen.count > 2)
        if !isGroup, let existing = s.conversations.first(where: { !$0.isGroup && Set($0.memberIds) == Set(seen) }) {
            return (s, existing)
        }
        let c = Conversation(memberIds: seen, title: (title?.isEmpty == false) ? title : nil, isGroup: isGroup)
        var s = s
        s.conversations.append(c)
        return (s, c)
    }

    static func putMessage(_ s: SocialState, _ m: Message) -> SocialState {
        var s = s
        if let i = s.messages.firstIndex(where: { $0.id == m.id }) { s.messages[i] = m } else { s.messages.append(m) }
        s.conversations = s.conversations.map { c in
            guard c.id == m.conversationId else { return c }
            var c = c
            c.updatedAt = max(c.updatedAt, m.createdAt)
            return c
        }
        return s
    }

    static func deleteMessage(_ s: SocialState, _ id: String) -> SocialState {
        var s = s
        s.messages.removeAll { $0.id == id }
        return s
    }
}

enum AutoReply {
    static func replies(msg: Message, conv: Conversation, contacts: [Contact], now: Int64 = Int64(Date().timeIntervalSince1970 * 1000), pick: (Int) -> Int = { _ in Int.random(in: 0...0x7fffffff) }) -> [Message] {
        if msg.auto || conv.remote { return [] }
        let byId = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        let responders = conv.memberIds.filter { $0 != msg.senderId }.compactMap { byId[$0] }
            .filter { $0.isVirtual && !$0.isSelf && $0.autoReplyOn && $0.autoReplies.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        return responders.enumerated().map { i, c in
            let pool = c.autoReplies.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let text = pool[abs(pick(pool.count)) % pool.count]
            return Message(conversationId: conv.id, senderId: c.id, text: text, createdAt: now + 1 + Int64(i), status: .sent, auto: true)
        }
    }
}
