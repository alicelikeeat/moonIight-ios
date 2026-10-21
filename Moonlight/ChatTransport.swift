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

/// Inactive stub. See docs/CHAT_PROTOCOL.md. No network calls are made.
struct RemoteTransport: ChatTransport {
    var config: ChatServerConfig
    let id = "remote"
    let active = false

    static let api = "/v1"
    static let auth = "/v1/auth/token"
    static let me = "/v1/me"
    static let conversations = "/v1/conversations"
    static let syncPath = "/v1/sync"
    static let uploads = "/v1/uploads"
    static let wsPath = "/v1/ws"
    static func messages(_ convId: String) -> String { "/v1/conversations/\(convId)/messages" }
    static func receipts(_ convId: String) -> String { "/v1/conversations/\(convId)/receipts" }

    func send(message: Message, conversation: Conversation) async -> SendResult {
        SendResult(status: .failed, error: "聊天服务器即将推出，消息仅保存在本机")
    }
    func sync(cursor: String?) async -> SyncResult {
        SyncResult(messages: [], conversations: [], cursor: cursor)
    }
    func markRead(conversationId: String, upToMessageId: String) async {}
}
