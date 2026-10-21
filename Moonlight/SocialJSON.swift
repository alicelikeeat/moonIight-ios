import Foundation

enum SocialJSONError: Error, Equatable {
    case invalid
}

/// social.json codec matching the Android backup shape (schema 2, schema 1 imports).
enum SocialJSON {
    static func encode(_ s: SocialState) -> Data {
        let obj: [String: Any] = [
            "schema": s.schema,
            "app": "moonlight",
            "selfId": s.selfId,
            "contacts": s.contacts.map(contact),
            "moments": s.moments.map(moment),
            "conversations": s.conversations.map(conversation),
            "messages": s.messages.map(message),
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    static func encodeString(_ s: SocialState) -> String {
        String(data: encode(s), encoding: .utf8) ?? ""
    }

    static func decode(_ data: Data) throws -> SocialState {
        guard let text = String(data: data, encoding: .utf8) else { throw SocialJSONError.invalid }
        return try decode(text)
    }

    static func decode(_ text: String) throws -> SocialState {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let o = raw as? [String: Any] else { throw SocialJSONError.invalid }
        guard let selfId = o["selfId"] as? String, !selfId.isEmpty else { throw SocialJSONError.invalid }
        var contacts = arr(o["contacts"]).map(contact)
        if !contacts.contains(where: { $0.id == selfId }) {
            contacts.insert(Contact(id: selfId, name: "我", isSelf: true, isVirtual: false), at: 0)
        }
        return SocialState(
            selfId: selfId,
            contacts: contacts,
            moments: arr(o["moments"]).map(moment),
            conversations: arr(o["conversations"]).map(conversation),
            messages: arr(o["messages"]).map(message),
            schema: (o["schema"] as? NSNumber)?.intValue ?? SocialState.schemaVersion
        )
    }

    private static func arr(_ any: Any?) -> [[String: Any]] {
        (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }
    private static func strings(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }
    private static func str(_ o: [String: Any], _ k: String) -> String? {
        guard let s = o[k] as? String, !s.isEmpty else { return nil }
        return s
    }
    private static func lng(_ o: [String: Any], _ k: String) -> Int64? {
        guard let n = o[k] as? NSNumber else { return nil }
        return n.int64Value
    }
    private static func bl(_ o: [String: Any], _ k: String, _ def: Bool) -> Bool {
        (o[k] as? NSNumber)?.boolValue ?? def
    }
    private static func null(_ v: Any?) -> Any { v ?? NSNull() }

    private static func contact(_ c: Contact) -> [String: Any] {
        [
            "id": c.id, "name": c.name, "bio": c.bio,
            "avatarPath": null(c.avatarPath), "avatarColor": c.avatarColor, "avatarVideo": c.avatarVideo,
            "coverPath": null(c.coverPath), "coverVideo": c.coverVideo,
            "avatarFocus": null(c.avatarFocus?.encode()), "coverFocus": null(c.coverFocus?.encode()),
            "prevAvatar": c.prevAvatar.map(saved) ?? NSNull(),
            "prevCover": c.prevCover.map(saved) ?? NSNull(),
            "isVirtual": c.isVirtual, "isSelf": c.isSelf,
            "remoteUserId": null(c.remoteUserId), "autoReplyOn": c.autoReplyOn,
            "autoReplies": c.autoReplies, "createdAt": c.createdAt, "updatedAt": c.updatedAt,
        ]
    }

    private static func contact(_ o: [String: Any]) -> Contact {
        Contact(
            id: (o["id"] as? String) ?? IDs.new(),
            name: (o["name"] as? String) ?? "",
            bio: (o["bio"] as? String) ?? "",
            avatarPath: str(o, "avatarPath"),
            avatarColor: (o["avatarColor"] as? NSNumber)?.intValue ?? 0,
            avatarVideo: bl(o, "avatarVideo", false),
            coverPath: str(o, "coverPath"),
            coverVideo: bl(o, "coverVideo", false),
            avatarFocus: MediaFocus.decode(str(o, "avatarFocus")),
            coverFocus: MediaFocus.decode(str(o, "coverFocus")),
            prevAvatar: saved(o["prevAvatar"] as? [String: Any]),
            prevCover: saved(o["prevCover"] as? [String: Any]),
            isVirtual: bl(o, "isVirtual", true),
            isSelf: bl(o, "isSelf", false),
            remoteUserId: str(o, "remoteUserId"),
            autoReplyOn: bl(o, "autoReplyOn", false),
            autoReplies: strings(o["autoReplies"]),
            createdAt: lng(o, "createdAt") ?? 0,
            updatedAt: lng(o, "updatedAt") ?? lng(o, "createdAt") ?? 0
        )
    }

    private static func saved(_ m: SavedMedia) -> [String: Any] {
        ["path": m.path, "video": m.video, "focus": null(m.focus?.encode())]
    }
    private static func saved(_ o: [String: Any]?) -> SavedMedia? {
        guard let o, let path = str(o, "path") else { return nil }
        return SavedMedia(path: path, video: bl(o, "video", false), focus: MediaFocus.decode(str(o, "focus")))
    }

    private static func attachment(_ a: Attachment) -> [String: Any] {
        [
            "id": a.id, "kind": a.kind.rawValue,
            "libraryEntryId": null(a.libraryEntryId), "localPath": null(a.localPath),
            "coverUrl": null(a.coverURL), "remoteUrl": null(a.remoteURL), "remoteId": null(a.remoteId),
            "mime": null(a.mime), "sizeBytes": a.sizeBytes, "title": a.title,
        ]
    }
    private static func attachment(_ o: [String: Any]) -> Attachment {
        let kind = AttachmentKind(rawValue: (o["kind"] as? String) ?? "") ?? .image
        return Attachment(
            id: (o["id"] as? String) ?? IDs.new(),
            kind: kind,
            libraryEntryId: str(o, "libraryEntryId"),
            localPath: str(o, "localPath"),
            coverURL: str(o, "coverUrl"),
            remoteURL: str(o, "remoteUrl"),
            remoteId: str(o, "remoteId"),
            mime: str(o, "mime"),
            sizeBytes: lng(o, "sizeBytes") ?? 0,
            title: (o["title"] as? String) ?? ""
        )
    }

    private static func comment(_ c: Comment) -> [String: Any] {
        ["id": c.id, "authorId": c.authorId, "text": c.text, "replyToId": null(c.replyToId), "createdAt": c.createdAt]
    }
    private static func comment(_ o: [String: Any]) -> Comment {
        Comment(
            id: (o["id"] as? String) ?? IDs.new(),
            authorId: (o["authorId"] as? String) ?? "",
            text: (o["text"] as? String) ?? "",
            replyToId: str(o, "replyToId"),
            createdAt: lng(o, "createdAt") ?? 0
        )
    }

    private static func moment(_ m: Moment) -> [String: Any] {
        var o: [String: Any] = [
            "id": m.id, "authorId": m.authorId, "text": m.text,
            "attachments": m.attachments.map(attachment),
            "createdAt": m.createdAt,
            "likes": m.likes, "dislikes": m.dislikes,
            "comments": m.comments.map(comment),
        ]
        o["editedAt"] = m.editedAt.map { $0 as Any } ?? NSNull()
        return o
    }
    private static func moment(_ o: [String: Any]) -> Moment {
        Moment(
            id: (o["id"] as? String) ?? IDs.new(),
            authorId: (o["authorId"] as? String) ?? "",
            text: (o["text"] as? String) ?? "",
            attachments: arr(o["attachments"]).map(attachment),
            createdAt: lng(o, "createdAt") ?? 0,
            editedAt: lng(o, "editedAt"),
            likes: strings(o["likes"]),
            dislikes: strings(o["dislikes"]),
            comments: arr(o["comments"]).map(comment)
        )
    }

    private static func conversation(_ c: Conversation) -> [String: Any] {
        [
            "id": c.id, "memberIds": c.memberIds, "title": null(c.title), "isGroup": c.isGroup,
            "remote": c.remote, "remoteId": null(c.remoteId), "pinned": c.pinned,
            "createdAt": c.createdAt, "updatedAt": c.updatedAt, "readAt": c.readAt,
        ]
    }
    private static func conversation(_ o: [String: Any]) -> Conversation {
        let readAt: Int64
        if o.keys.contains("readAt"), let n = lng(o, "readAt") { readAt = n } else { readAt = Int64.max / 2 }
        return Conversation(
            id: (o["id"] as? String) ?? IDs.new(),
            memberIds: strings(o["memberIds"]),
            title: str(o, "title"),
            isGroup: bl(o, "isGroup", false),
            remote: bl(o, "remote", false),
            remoteId: str(o, "remoteId"),
            pinned: bl(o, "pinned", false),
            createdAt: lng(o, "createdAt") ?? 0,
            updatedAt: lng(o, "updatedAt") ?? lng(o, "createdAt") ?? 0,
            readAt: readAt
        )
    }

    private static func message(_ m: Message) -> [String: Any] {
        [
            "id": m.id, "conversationId": m.conversationId, "senderId": m.senderId, "text": m.text,
            "attachments": m.attachments.map(attachment),
            "createdAt": m.createdAt, "serverAt": m.serverAt.map { $0 as Any } ?? NSNull(),
            "status": m.status.rawValue, "auto": m.auto, "error": null(m.error),
        ]
    }
    private static func message(_ o: [String: Any]) -> Message {
        let status = MessageStatus(rawValue: (o["status"] as? String) ?? "") ?? .local
        return Message(
            id: (o["id"] as? String) ?? IDs.new(),
            conversationId: (o["conversationId"] as? String) ?? "",
            senderId: (o["senderId"] as? String) ?? "",
            text: (o["text"] as? String) ?? "",
            attachments: arr(o["attachments"]).map(attachment),
            createdAt: lng(o, "createdAt") ?? 0,
            serverAt: lng(o, "serverAt"),
            status: status,
            auto: bl(o, "auto", false),
            error: str(o, "error")
        )
    }
}

enum DemoSocial {
    private static let minute: Int64 = 60_000
    private static let hour: Int64 = 60 * minute

    static func seed(_ s: SocialState, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> SocialState {
        let me = s.me
        func f(_ name: String, _ bio: String, _ color: Int, _ auto: [String] = []) -> Contact {
            Contact(name: name, bio: "\(bio) · 示例好友", avatarColor: color, autoReplies: auto, createdAt: now - 30 * 24 * hour)
        }
        let yue = f("阿月", "只在夜里出门拍月亮", 1, ["好呀～", "刚看到，等我一下", "哈哈哈哈", "今晚月亮好圆"])
        let lin = f("小林", "跑步 / 胶片 / 猫", 2)
        let nova = f("Nova", "Stargazer. Night owl.", 3)
        let ye = f("山野", "徒步中，信号时有时无", 4)
        let he = f("星河", "做一点点音乐", 5)
        func img(_ n: Int) -> Attachment { Attachment(kind: .image, coverURL: "art:\(n)") }
        func vid(_ n: Int, _ t: String) -> Attachment { Attachment(kind: .video, coverURL: "art:\(n)", title: t) }
        let moments = [
            Moment(authorId: yue.id, text: "湖面上的月光，一次长曝光 30 秒。风停的那一下刚刚好。", attachments: [img(0), img(4), img(2)], createdAt: now - 12 * minute, likes: [me.id, nova.id, lin.id], comments: [
                Comment(authorId: nova.id, text: "这个倒影绝了", createdAt: now - 9 * minute),
                Comment(authorId: me.id, text: "下次带上我", createdAt: now - 6 * minute),
                Comment(authorId: yue.id, text: "好，周六见", replyToId: me.id, createdAt: now - 4 * minute),
            ]),
            Moment(authorId: lin.id, text: "夜跑 8 公里，路过山脊线的时候停下来录了一段。", attachments: [vid(3, "山脊夜跑")], createdAt: now - 2 * hour, likes: [ye.id, he.id], dislikes: [nova.id]),
            Moment(authorId: me.id, text: "今天的月亮像一颗糖。", attachments: [img(5)], createdAt: now - 5 * hour, likes: [yue.id]),
            Moment(authorId: nova.id, text: "Milky Way season is back ✨ 一共拍了九张，挑几张。", attachments: [img(1), img(4), img(0), img(2), img(3), img(5)], createdAt: now - 26 * hour, likes: [me.id, yue.id, ye.id, he.id], comments: [
                Comment(authorId: he.id, text: "可以做我新专辑封面吗", createdAt: now - 20 * hour),
            ]),
            Moment(authorId: ye.id, text: "营地没有信号，只有星星。", createdAt: now - 3 * 24 * hour),
        ]
        let c1 = Conversation(memberIds: [me.id, yue.id], createdAt: now - 3 * hour, updatedAt: now - 2 * minute, readAt: now - minute)
        let c2 = Conversation(memberIds: [lin.id, nova.id], createdAt: now - 5 * hour, updatedAt: now - 4 * hour, readAt: now)
        let c3 = Conversation(memberIds: [me.id, lin.id, ye.id, he.id], title: "夜跑小队", isGroup: true, createdAt: now - 48 * hour, updatedAt: now - 28 * hour, readAt: now - 31 * hour)
        func m(_ c: Conversation, _ who: Contact, _ text: String, _ ago: Int64, _ st: MessageStatus = .sent, _ att: [Attachment] = []) -> Message {
            Message(conversationId: c.id, senderId: who.id, text: text, attachments: att, createdAt: now - ago, status: st)
        }
        let messages = [
            m(c1, yue, "今晚去湖边吗？月亮 21:40 升起", 58 * minute),
            m(c1, me, "去！我带三脚架", 55 * minute, .read),
            m(c1, yue, "", 40 * minute, .sent, [img(0)]),
            m(c1, yue, "上次拍的，这次争取更清楚", 39 * minute),
            m(c1, me, "好看！那 21:15 湖边见", 12 * minute, .read),
            m(c1, me, "记得带外套，晚上冷", 2 * minute, .sent),
            m(c2, lin, "你那边看得到银河吗", 5 * hour),
            m(c2, nova, "看得到！刚拍完", 4 * hour),
            m(c3, ye, "周六老地方？", 30 * hour),
            m(c3, he, "+1", 29 * hour),
            m(c3, me, "我可能晚 10 分钟", 28 * hour, .read),
        ]
        var out = s
        out.contacts += [yue, lin, nova, ye, he]
        out.moments += moments
        out.conversations += [c1, c2, c3]
        out.messages += messages
        return out
    }
}
