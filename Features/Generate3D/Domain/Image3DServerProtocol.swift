import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// v1.75: picture → 3D model on the user's own computer (tools/local3d:
// TripoSR or Hunyuan3D-2 on their GPU / Mac). The phone uploads one
// picture and downloads a GLB. Plain http is allowed only to addresses in
// the local network (the computer on the same Wi-Fi); anything else must
// be https. No address or key is built into the app.
//
//   GET    /v1/health
//   POST   /v1/image3d/jobs              (body: JPEG / PNG)
//   GET    /v1/image3d/jobs/{id}
//   POST   /v1/image3d/jobs/{id}/cancel
//   GET    /v1/image3d/jobs/{id}/result  (GLB)
//   DELETE /v1/image3d/jobs/{id}

struct LocalServerConfig: Equatable, Sendable {
    var baseURL: URL
    var token: String

    /// "192.168.1.20:8765" or a full URL. http only for local addresses.
    static func parse(_ text: String, token: String) -> LocalServerConfig? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "http://" + t }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if scheme == "http" && !isLocal(host) { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        return LocalServerConfig(baseURL: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Private IPv4 ranges, link-local, loopback, and .local names.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, let b): return (16...31).contains(b)
        default: return false
        }
    }
}

struct LocalServerHealth: Codable, Equatable, Sendable {
    var name: String
    var backend: String
    var version: String?
    /// v1.93: the backend uses every view of a multi-view job (others use the front only).
    var multiview: Bool?
}

enum Image3DServerProtocol {
    static func request(_ config: LocalServerConfig, _ method: String, _ path: String, body: Data? = nil, contentType: String? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var base = config.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var r = URLRequest(url: URL(string: base + path)!, timeoutInterval: timeout)
        r.httpMethod = method
        if !config.token.isEmpty { r.setValue("Bearer " + config.token, forHTTPHeaderField: "Authorization") }
        if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        return r
    }
    static func health(_ c: LocalServerConfig) -> URLRequest { request(c, "GET", "/v1/health", timeout: 8) }
    static func create(_ c: LocalServerConfig, image: Data, mime: String, texture: Bool) -> URLRequest {
        var r = request(c, "POST", "/v1/image3d/jobs", body: image, contentType: mime, timeout: 120)
        r.setValue(texture ? #"{"texture":true}"# : #"{"texture":false}"#, forHTTPHeaderField: "X-Options")
        return r
    }
    /// v1.93: several views of one subject (front required; back, left, right) as JSON.
    /// Servers before 1.93 do not read it: check `LocalServerHealth.version` first.
    static func create(_ c: LocalServerConfig, views: [PhotoView: Data], texture: Bool) -> URLRequest? {
        guard let front = views[.front], !front.isEmpty else { return nil }
        var sent: [String: String] = ["front": front.base64EncodedString()]
        for view in [PhotoView.back, .left, .right] { if let data = views[view], !data.isEmpty { sent[view.rawValue] = data.base64EncodedString() } }
        guard let body = try? JSONSerialization.data(withJSONObject: ["views": sent]) else { return nil }
        var r = request(c, "POST", "/v1/image3d/jobs", body: body, contentType: "application/json", timeout: 180)
        r.setValue(texture ? #"{"texture":true}"# : #"{"texture":false}"#, forHTTPHeaderField: "X-Options")
        return r
    }
    /// Whether a server version reads multi-view jobs (1.93 and later).
    static func acceptsViews(_ version: String?) -> Bool {
        let parts = (version ?? "").split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return parts[0] > 1 || (parts[0] == 1 && parts[1] >= 93)
    }
    static func status(_ c: LocalServerConfig, id: String) -> URLRequest { request(c, "GET", "/v1/image3d/jobs/" + CloudRiggingProtocol.escape(id)) }
    static func cancel(_ c: LocalServerConfig, id: String) -> URLRequest { request(c, "POST", "/v1/image3d/jobs/" + CloudRiggingProtocol.escape(id) + "/cancel") }
    static func result(_ c: LocalServerConfig, id: String) -> URLRequest { request(c, "GET", "/v1/image3d/jobs/" + CloudRiggingProtocol.escape(id) + "/result", timeout: 300) }
    static func delete(_ c: LocalServerConfig, id: String) -> URLRequest { request(c, "DELETE", "/v1/image3d/jobs/" + CloudRiggingProtocol.escape(id)) }

    static func healthInfo(_ body: Data) throws -> LocalServerHealth {
        guard let h = try? JSONDecoder().decode(LocalServerHealth.self, from: body) else { throw CloudRigError.badResponse("health") }
        return h
    }

    /// The GLB result as a model ready to save (vertex colours baked).
    static func model(fromGLB data: Data) throws -> (mesh: GeneratedMesh, texture: RasterImage?, encodedTexture: Data?) {
        var model = try GLBCodec.read(data)
        model.mesh.normalize(size: 1)
        if model.texture == nil, let colors = model.colors {
            let baked = VertexColorBaker.bake(model.mesh, colors: colors)
            return (baked.mesh, baked.texture, nil)
        }
        return (model.mesh, nil, model.texture)
    }
}
