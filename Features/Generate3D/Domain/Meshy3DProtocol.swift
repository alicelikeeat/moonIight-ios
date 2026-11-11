import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// v1.93: cloud 3D generation with Meshy (docs.meshy.ai), the user's own API
// key. One to four pictures of the same subject (the first is the front) go
// to POST /openapi/v1/multi-image-to-3d as data URIs; the task is polled with
// GET /openapi/v1/multi-image-to-3d/{id} until it ends; the GLB is downloaded
// from the returned URL. Pictures leave the phone, so the app asks before
// every send; nothing is built in (no key, no account). Requests and replies
// follow the published API as read on 2026-11-11. Pure Foundation.

struct MeshyOptions: Equatable, Sendable {
    /// A humanoid: ask for a T-pose, so rigging and garment fitting start from the bind pose.
    var character = true
    /// Metallic, roughness and normal maps besides the base colour.
    var pbr = true
    /// Faces to aim for after the remesh (the phone's budget; the API takes 100…300000).
    var polycount = 30_000
    /// The Ultra geometry pass (2048³): slower and costs more credits.
    var fineGeometry = false

    var clamped: MeshyOptions { var o = self; o.polycount = min(300_000, max(100, polycount)); return o }
}

struct MeshyTask: Equatable, Sendable {
    enum Status: String, Sendable { case pending = "PENDING", inProgress = "IN_PROGRESS", succeeded = "SUCCEEDED", failed = "FAILED", canceled = "CANCELED" }
    var id: String
    var status: Status
    /// 0…100.
    var progress: Int
    var glb: URL?
    var thumbnail: URL?
    var error: String?
    var credits: Int?
    /// Tasks ahead in the queue.
    var preceding: Int?
    var finished: Bool { status == .succeeded || status == .failed || status == .canceled }
}

enum MeshyError: Error, Equatable, LocalizedError {
    case noKey, noPictures, tooManyPictures, pictureTooLarge
    case badRequest(String), unauthorized, payment(String), moderated, notFound, rateLimited, server(Int)
    case badReply(String), failed(String), canceled, timedOut, noModel

    var errorDescription: String? {
        switch self {
        case .noKey: L10n.t("请先填写你自己的 Meshy API Key。", "Enter your own Meshy API key first.")
        case .noPictures: L10n.t("至少需要一张图片（第一张是正面）。", "At least one picture is needed (the first is the front).")
        case .tooManyPictures: L10n.t("最多四张图片。", "At most four pictures.")
        case .pictureTooLarge: L10n.t("图片太大，无法发送。", "A picture is too large to send.")
        case .badRequest(let why): L10n.t("Meshy 不接受这个请求：", "Meshy did not accept the request: ") + why
        case .unauthorized: L10n.t("API Key 无效或缺失，请检查。", "The API key is missing or invalid.")
        case .payment(let why): L10n.t("Meshy 账户额度不足或需要付费套餐：", "Not enough Meshy credits, or a paid plan is needed: ") + why
        case .moderated: L10n.t("内容审核拦截了图片，请换一张。", "Content moderation blocked a picture; use another.")
        case .notFound: L10n.t("任务不存在或已过期。", "The task does not exist or has expired.")
        case .rateLimited: L10n.t("请求太频繁，请稍后再试。", "Too many requests; try again later.")
        case .server(let code): L10n.t("Meshy 服务出错（\(code)）。", "Meshy service error (\(code)).")
        case .badReply(let what): L10n.t("没能读懂 Meshy 的回答：", "Could not read Meshy's reply: ") + what
        case .failed(let why): L10n.t("生成失败：", "The generation failed: ") + why
        case .canceled: L10n.t("任务被取消。", "The task was cancelled.")
        case .timedOut: L10n.t("等待超时。任务可能仍在 Meshy 上运行，可在 Meshy 网站查看。", "Timed out waiting. The task may still be running; check the Meshy site.")
        case .noModel: L10n.t("任务完成了，但没有返回 GLB 模型。", "The task finished without a GLB model.")
        }
    }
}

enum Meshy3DProtocol {
    static let base = "https://api.meshy.ai/openapi/v1/multi-image-to-3d"
    static let keyAccount = "meshy-api-key"
    static let maxPictures = 4
    /// The API takes 20 MB a picture; the app sends far smaller JPEGs.
    static let maxPictureBytes = 20_000_000

    static func dataURI(jpeg: Data) -> String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }

    /// The create request's JSON body.
    static func body(pictures: [Data], options: MeshyOptions) throws -> [String: Any] {
        guard !pictures.isEmpty else { throw MeshyError.noPictures }
        guard pictures.count <= maxPictures else { throw MeshyError.tooManyPictures }
        guard pictures.allSatisfy({ !$0.isEmpty && $0.count <= maxPictureBytes }) else { throw MeshyError.pictureTooLarge }
        let o = options.clamped
        var body: [String: Any] = [
            "image_urls": pictures.map(dataURI),
            "ai_model": "latest",
            "should_texture": true,
            "enable_pbr": o.pbr,
            "should_remesh": true,
            "topology": "triangle",
            "target_polycount": o.polycount,
            "target_formats": ["glb"],
        ]
        if o.fineGeometry { body["geometry_resolution"] = "2k" }
        if o.character { body["pose_mode"] = "t-pose" }
        return body
    }

    private static func request(_ url: String, _ method: String, key: String, body: Data? = nil, timeout: TimeInterval = 60) throws -> URLRequest {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { throw MeshyError.noKey }
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
        r.httpMethod = method
        r.setValue("Bearer " + k, forHTTPHeaderField: "Authorization")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    static func create(key: String, pictures: [Data], options: MeshyOptions) throws -> URLRequest {
        let json = try JSONSerialization.data(withJSONObject: try body(pictures: pictures, options: options))
        return try request(base, "POST", key: key, body: json, timeout: 180)
    }
    static func status(key: String, id: String) throws -> URLRequest { try request(base + "/" + escape(id), "GET", key: key) }
    static func delete(key: String, id: String) throws -> URLRequest { try request(base + "/" + escape(id), "DELETE", key: key) }

    static func escape(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? "" }

    /// Throws for every status but 2xx, with the API's own message where it gives one.
    static func check(status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { $0["message"] as? String } ?? ""
        switch status {
        case 400, 422: throw MeshyError.badRequest(message.isEmpty ? "\(status)" : String(message.prefix(300)))
        case 401: throw MeshyError.unauthorized
        case 402: throw MeshyError.payment(String(message.prefix(300)))
        case 403: throw MeshyError.moderated
        case 404: throw MeshyError.notFound
        case 429: throw MeshyError.rateLimited
        default: throw MeshyError.server(status)
        }
    }

    /// The new task's id from the create reply ({"result": "<id>"}).
    static func createdID(_ body: Data) throws -> String {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let id = o["result"] as? String, !id.isEmpty else { throw MeshyError.badReply("result") }
        return id
    }

    static func task(_ body: Data) throws -> MeshyTask {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let id = o["id"] as? String,
              let raw = o["status"] as? String, let status = MeshyTask.Status(rawValue: raw) else { throw MeshyError.badReply("task") }
        func url(_ value: Any?) -> URL? {
            guard let s = value as? String, let u = URL(string: s), u.scheme?.lowercased() == "https" else { return nil }
            return u
        }
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue ?? (v as? Double).map { Int($0) } }
        let error = ((o["task_error"] as? [String: Any])?["message"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        return MeshyTask(id: id, status: status, progress: min(100, max(0, int(o["progress"]) ?? 0)),
                         glb: url((o["model_urls"] as? [String: Any])?["glb"]), thumbnail: url(o["thumbnail_url"]), error: error,
                         credits: int(o["consumed_credits"]), preceding: int(o["preceding_tasks"]))
    }

    /// Seconds before the next status poll.
    static func pollDelay(attempt: Int) -> Double { min(8, 2 + Double(min(attempt, 12)) * 0.5) }
}
