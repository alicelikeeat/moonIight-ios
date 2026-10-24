import Foundation

struct SendResult: Equatable, Sendable {
    var status: MessageStatus
    var serverAt: Int64?
    var remoteId: String?
    var error: String?
}

enum TransportEvent: Sendable {
    case incoming(Message)
    case receipt(messageId: String, status: MessageStatus, at: Int64)
    case connectionChanged(Bool, String?)
}

struct SyncResult: Equatable, Sendable {
    var messages: [Message]
    var conversations: [Conversation]
    var cursor: String?
    var error: String?
}

protocol ChatTransport: Sendable {
    var id: String { get }
    var active: Bool { get }
    func send(message: Message, conversation: Conversation) async -> SendResult
    func sync(cursor: String?) async -> SyncResult
    func markRead(conversationId: String, upToMessageId: String) async
}

/// Everything stays on device. Virtual friends never leave the phone.
struct LocalTransport: ChatTransport {
    let id = "local"
    let active = true
    func send(message: Message, conversation: Conversation) async -> SendResult {
        SendResult(status: .sent)
    }
    func sync(cursor: String?) async -> SyncResult {
        SyncResult(messages: [], conversations: [], cursor: cursor)
    }
    func markRead(conversationId: String, upToMessageId: String) async {}
}

struct ChatServerConfig: Equatable, Sendable {
    var baseURL: String = ""
    var token: String?
    var userId: String?
    var configured: Bool { !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func wsURL() -> String {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasPrefix("https://") { base = "wss://" + base.dropFirst("https://".count) }
        else if base.hasPrefix("http://") { base = "ws://" + base.dropFirst("http://".count) }
        return base + RemoteTransport.wsPath
    }
}

/// HTTP status, body, and a transport error string. Nil status means the request never completed.
typealias ChatExchange = @Sendable (URLRequest) async -> (Int?, Data?, String?)

/// A small public JSON API. No account, no key. The phone only talks to the URL the user typed.
enum ChatWire {
    static let maxImageBytes = 900_000

    static func root(_ base: String) -> String {
        var text = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func postURL(_ base: String, convId: String) -> URL? {
        let id = convId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? convId
        return URL(string: root(base) + "/v1/conversations/\(id)/messages")
    }

    static func syncURL(_ base: String, cursor: String?) -> URL? {
        var raw = root(base) + "/v1/sync"
        if let cursor, !cursor.isEmpty, let escaped = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            raw += "?cursor=\(escaped)"
        }
        return URL(string: raw)
    }

    static func encode(_ message: Message) -> Data {
        var object: [String: Any] = [
            "id": message.id,
            "conversationId": message.conversationId,
            "senderId": message.senderId,
            "text": message.text,
            "createdAt": message.createdAt,
        ]
        let files: [[String: Any]] = message.attachments.compactMap { attachment in
            var item: [String: Any] = ["kind": attachment.kind.rawValue]
            if let remote = attachment.remoteURL { item["remoteURL"] = remote }
            if let path = attachment.localPath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               data.count <= maxImageBytes,
               attachment.kind == .image {
                item["dataBase64"] = data.base64EncodedString()
                item["mime"] = attachment.mime ?? "image/jpeg"
            }
            return item
        }
        if !files.isEmpty { object["attachments"] = files }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func interpretSend(status: Int?, data: Data?) -> SendResult {
        guard let status, (200..<300).contains(status) else {
            let note = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (note?.isEmpty == false) ? note! : "服务器没有收下这条消息"
            return SendResult(status: .failed, error: text)
        }
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let serverAt = (object?["serverAt"] as? NSNumber)?.int64Value
        let remoteId = object?["id"] as? String
        return SendResult(status: .sent, serverAt: serverAt, remoteId: remoteId)
    }

    static func interpretSync(status: Int?, data: Data?, cursor: String?) -> SyncResult {
        guard let status, (200..<300).contains(status), let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SyncResult(messages: [], conversations: [], cursor: cursor, error: "连不上聊天服务器")
        }
        let rows = object["messages"] as? [[String: Any]] ?? []
        let next = object["cursor"] as? String ?? cursor
        return SyncResult(messages: rows.compactMap(decode), conversations: [], cursor: next)
    }

    static func decodeMessage(_ data: Data) -> Message? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decode(object)
    }

    static func decode(_ object: [String: Any]) -> Message? {
        guard let id = object["id"] as? String,
              let conversationId = object["conversationId"] as? String,
              let senderId = object["senderId"] as? String else { return nil }
        let text = object["text"] as? String ?? ""
        let created = (object["createdAt"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
        let serverAt = (object["serverAt"] as? NSNumber)?.int64Value
        let attachments = (object["attachments"] as? [[String: Any]] ?? []).compactMap(decodeAttachment)
        return Message(
            id: id, conversationId: conversationId, senderId: senderId, text: text,
            attachments: attachments, createdAt: created, serverAt: serverAt, status: .sent
        )
    }

    private static func decodeAttachment(_ object: [String: Any]) -> Attachment? {
        let kind = AttachmentKind(rawValue: (object["kind"] as? String) ?? "") ?? .image
        var attachment = Attachment(kind: kind, remoteURL: object["remoteURL"] as? String, mime: object["mime"] as? String, title: "图片")
        if let b64 = object["dataBase64"] as? String, let data = Data(base64Encoded: b64), data.count <= maxImageBytes {
            Paths.ensureDirs()
            let url = Paths.media.appendingPathComponent("chat_\(IDs.new()).jpg")
            if (try? data.write(to: url)) != nil {
                attachment.localPath = url.path
                attachment.sizeBytes = Int64(data.count)
            }
        }
        return attachment
    }
}

/// Talks to whatever server the user typed. An empty address never leaves the phone.
struct RemoteTransport: ChatTransport {
    var config: ChatServerConfig
    var exchange: ChatExchange
    let id = "remote"
    var active: Bool { config.configured }

    static let api = "/v1"
    static let auth = "/v1/auth/token"
    static let me = "/v1/me"
    static let conversations = "/v1/conversations"
    static let syncPath = "/v1/sync"
    static let uploads = "/v1/uploads"
    static let wsPath = "/v1/ws"
    static func messages(_ convId: String) -> String { "/v1/conversations/\(convId)/messages" }
    static func receipts(_ convId: String) -> String { "/v1/conversations/\(convId)/receipts" }

    init(config: ChatServerConfig, exchange: @escaping ChatExchange = RemoteTransport.live) {
        self.config = config
        self.exchange = exchange
    }

    static func live(_ request: URLRequest) async -> (Int?, Data?, String?) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode, data, nil)
        } catch {
            return (nil, nil, error.localizedDescription)
        }
    }

    func send(message: Message, conversation: Conversation) async -> SendResult {
        guard active, let url = ChatWire.postURL(config.baseURL, convId: conversation.id) else {
            return SendResult(status: .failed, error: "还没有填写聊天服务器")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = ChatWire.encode(message)
        let (status, data, error) = await exchange(request)
        if let error, status == nil { return SendResult(status: .failed, error: error) }
        return ChatWire.interpretSend(status: status, data: data)
    }

    func sync(cursor: String?) async -> SyncResult {
        guard active, let url = ChatWire.syncURL(config.baseURL, cursor: cursor) else {
            return SyncResult(messages: [], conversations: [], cursor: cursor)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (status, data, error) = await exchange(request)
        if let error, status == nil {
            return SyncResult(messages: [], conversations: [], cursor: cursor, error: error)
        }
        return ChatWire.interpretSync(status: status, data: data, cursor: cursor)
    }

    func markRead(conversationId: String, upToMessageId: String) async {}
}
