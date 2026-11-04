import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// v1.73 M05: client side of the cloud rigging job API. The service is
// chosen and run by the user (e.g. a server wrapping UniRig); the app
// ships no server address and no key. Requests carry the user's own
// token. Results come back in Moonlight's format and are checked here
// (version, vertex count, skeleton, weights) and then by the same motion
// tests as local rigs before anything is saved.
//
//   POST   /v1/rig/jobs              create (body: GLB)
//   GET    /v1/rig/jobs/{id}         status and progress
//   POST   /v1/rig/jobs/{id}/cancel  cancel
//   GET    /v1/rig/jobs/{id}/result  download the rig
//   DELETE /v1/rig/jobs/{id}         delete the job and uploaded files

struct CloudRigConfig: Equatable, Sendable {
    var baseURL: URL
    var token: String

    /// Only https (http allowed for localhost testing).
    static func parse(_ text: String, token: String) -> CloudRigConfig? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty,
              scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1")) else { return nil }
        return CloudRigConfig(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct CloudRigJob: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, deleted }
    var id: String
    var status: State
    var progress: Double?
    var message: String?
    var finished: Bool { [.succeeded, .failed, .cancelled, .deleted].contains(status) }
}

/// Result body: Moonlight rig format, vertex order of the uploaded GLB.
struct CloudRigResult: Codable, Equatable, Sendable {
    static let formatVersion = 1
    var formatVersion: Int
    var vertexCount: Int
    var skeleton: SkeletonDefinition
    /// 4 per vertex (255 = unused).
    var joints: [UInt8]
    var weights: [Float]
    var engine: String?
    var notes: [String]?
}

enum CloudRigError: Error, Equatable, LocalizedError {
    case notConfigured, unauthorized, notFound, tooLarge, rejected(String), rateLimited, server(Int), badResponse(String), timedOut, incompatible(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: L10n.t("请先在高级设置里填写云端服务地址", "Set the cloud service address in Advanced first")
        case .unauthorized: L10n.t("云端服务拒绝了访问令牌", "The cloud service rejected the access token")
        case .notFound: L10n.t("云端任务不存在或已过期", "The cloud job does not exist or has expired")
        case .tooLarge: L10n.t("模型超过云端服务的大小限制", "The model is over the service's size limit")
        case .rejected(let why): L10n.t("云端服务拒绝了模型：", "The service rejected the model: ") + why
        case .rateLimited: L10n.t("请求太频繁，请稍后再试", "Too many requests; try again later")
        case .server(let code): L10n.t("云端服务出错（\(code)）", "Cloud service error (\(code))")
        case .badResponse(let why): L10n.t("云端返回的数据无法读取：", "Could not read the service's reply: ") + why
        case .timedOut: L10n.t("云端任务超时，本地工程未受影响", "The cloud job timed out; the local project is unchanged")
        case .incompatible(let why): L10n.t("云端结果与模型不匹配：", "The cloud result does not fit the model: ") + why
        }
    }
}

enum CloudRiggingProtocol {
    static let maxUploadBytes = 64 * 1024 * 1024
    static let timeout: TimeInterval = 600

    static func url(_ config: CloudRigConfig, _ path: String) -> URL {
        var base = config.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)!
    }
    static func request(_ config: CloudRigConfig, _ method: String, _ path: String, body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var r = URLRequest(url: url(config, path), timeoutInterval: 60)
        r.httpMethod = method
        if !config.token.isEmpty { r.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        return r
    }
    static func create(_ config: CloudRigConfig, glb: Data) -> URLRequest {
        var r = request(config, "POST", "/v1/rig/jobs", body: glb, contentType: "model/gltf-binary")
        r.setValue(#"{"skeleton":"humanoid","maxInfluences":4,"format":"moonlight-rig-1","client":"Moonlight/1.73"}"#, forHTTPHeaderField: "X-Rig-Options")
        r.timeoutInterval = 300
        return r
    }
    static func status(_ config: CloudRigConfig, id: String) -> URLRequest { request(config, "GET", "/v1/rig/jobs/" + escape(id)) }
    static func cancel(_ config: CloudRigConfig, id: String) -> URLRequest { request(config, "POST", "/v1/rig/jobs/" + escape(id) + "/cancel") }
    static func result(_ config: CloudRigConfig, id: String) -> URLRequest { request(config, "GET", "/v1/rig/jobs/" + escape(id) + "/result") }
    static func delete(_ config: CloudRigConfig, id: String) -> URLRequest { request(config, "DELETE", "/v1/rig/jobs/" + escape(id)) }
    static func escape(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? "" }

    /// Maps HTTP status to errors (2xx passes).
    static func check(status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let message = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { ($0["message"] ?? $0["error"]) as? String } ?? ""
        switch status {
        case 401, 403: throw CloudRigError.unauthorized
        case 404, 410: throw CloudRigError.notFound
        case 413: throw CloudRigError.tooLarge
        case 400, 422: throw CloudRigError.rejected(message.isEmpty ? "\(status)" : message)
        case 429: throw CloudRigError.rateLimited
        default: throw CloudRigError.server(status)
        }
    }
    static func job(_ body: Data) throws -> CloudRigJob {
        guard let job = try? JSONDecoder().decode(CloudRigJob.self, from: body), !job.id.isEmpty else { throw CloudRigError.badResponse("job") }
        return job
    }

    /// Seconds before the next status poll.
    static func pollDelay(attempt: Int) -> Double { min(10, 1.5 * pow(1.4, Double(min(attempt, 10)))) }

    /// Decodes and checks a result for a model with `vertexCount` vertices.
    static func decodeResult(_ body: Data, vertexCount: Int) throws -> (skeleton: SkeletonDefinition, skin: SkinInfluences, notes: [String]) {
        guard let r = try? JSONDecoder().decode(CloudRigResult.self, from: body) else { throw CloudRigError.badResponse("result") }
        guard r.formatVersion == CloudRigResult.formatVersion else { throw CloudRigError.incompatible(L10n.t("格式版本 \(r.formatVersion)", "format version \(r.formatVersion)")) }
        guard r.vertexCount == vertexCount, r.joints.count == vertexCount * 4, r.weights.count == vertexCount * 4 else {
            throw CloudRigError.incompatible(L10n.t("顶点数不一致", "vertex count differs"))
        }
        guard r.skeleton.joints.count <= 254 else { throw CloudRigError.incompatible(L10n.t("关节过多", "too many joints")) }
        do { try r.skeleton.validate(humanoid: false) } catch { throw CloudRigError.incompatible(L10n.t("骨骼结构：", "skeleton: ") + "\(error)") }
        // Clean tiny numerical drift; reject anything clearly wrong.
        var skin = SkinInfluences(joints: r.joints, weights: r.weights)
        for v in 0..<vertexCount {
            var sum: Float = 0
            for k in 0..<4 {
                let j = skin.joints[v * 4 + k], w = skin.weights[v * 4 + k]
                guard w.isFinite, w >= -1e-4 else { throw CloudRigError.incompatible(L10n.t("权重为负或无效", "negative or invalid weight")) }
                if j == 255 { skin.weights[v * 4 + k] = 0; continue }
                guard Int(j) < r.skeleton.joints.count else { throw CloudRigError.incompatible(L10n.t("关节索引越界", "joint index out of range")) }
                skin.weights[v * 4 + k] = max(0, w); sum += max(0, w)
            }
            guard sum > 0.5, sum < 1.5 else { throw CloudRigError.incompatible(L10n.t("权重总和不为 1", "weights do not sum to 1")) }
            for k in 0..<4 { skin.weights[v * 4 + k] /= sum }
        }
        guard skin.valid(jointCount: r.skeleton.joints.count, vertexCount: vertexCount) else { throw CloudRigError.incompatible(L10n.t("权重不合法", "invalid weights")) }
        return (r.skeleton, skin, r.notes ?? [])
    }
}
