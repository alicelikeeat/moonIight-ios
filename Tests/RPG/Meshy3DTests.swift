import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// v1.93: the Meshy multi-image-to-3D requests and replies (as published in its API reference).
func meshy3DTests() {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    // Create request.
    if let r = try? Meshy3DProtocol.create(key: " msy_test ", pictures: [jpeg, jpeg], options: MeshyOptions()),
       let o = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] {
        let urls = o["image_urls"] as? [String] ?? []
        check(r.url?.absoluteString == "https://api.meshy.ai/openapi/v1/multi-image-to-3d" && r.httpMethod == "POST"
              && r.value(forHTTPHeaderField: "Authorization") == "Bearer msy_test" && r.value(forHTTPHeaderField: "Content-Type") == "application/json",
              "meshy: the create request goes to the multi-image endpoint with the bearer key")
        check(urls.count == 2 && urls.allSatisfy { $0 == "data:image/jpeg;base64," + jpeg.base64EncodedString() }, "meshy: pictures are sent as JPEG data URIs, front first")
        check(o["pose_mode"] as? String == "t-pose" && o["enable_pbr"] as? Bool == true && o["should_texture"] as? Bool == true && (o["target_formats"] as? [String]) == ["glb"]
              && o["target_polycount"] as? Int == 30_000 && o["should_remesh"] as? Bool == true && o["topology"] as? String == "triangle" && o["geometry_resolution"] == nil,
              "meshy: a character asks for a T-pose, PBR maps, a GLB and the phone's face budget")
    } else { check(false, "meshy: the create request builds") }
    if let o = try? Meshy3DProtocol.body(pictures: [jpeg], options: MeshyOptions(character: false, pbr: false, polycount: 9_000_000, fineGeometry: true)) {
        check(o["pose_mode"] == nil && o["enable_pbr"] as? Bool == false && o["target_polycount"] as? Int == 300_000 && o["geometry_resolution"] as? String == "2k",
              "meshy: an object keeps its pose; the face count is clamped to the API's range; fine geometry asks for 2k")
    }
    func thrown(_ f: () throws -> Void) -> MeshyError? { do { try f(); return nil } catch { return error as? MeshyError } }
    check(thrown { _ = try Meshy3DProtocol.create(key: "  ", pictures: [jpeg], options: MeshyOptions()) } == .noKey
          && thrown { _ = try Meshy3DProtocol.body(pictures: [], options: MeshyOptions()) } == .noPictures
          && thrown { _ = try Meshy3DProtocol.body(pictures: [jpeg, jpeg, jpeg, jpeg, jpeg], options: MeshyOptions()) } == .tooManyPictures
          && thrown { _ = try Meshy3DProtocol.body(pictures: [Data()], options: MeshyOptions()) } == .pictureTooLarge,
          "meshy: no key, no pictures, five pictures and an empty picture are refused before anything is sent")
    if let s = try? Meshy3DProtocol.status(key: "k", id: "018a/../x") {
        check(s.url?.absoluteString == "https://api.meshy.ai/openapi/v1/multi-image-to-3d/018a%2F%2E%2E%2Fx" && s.httpMethod == "GET", "meshy: task ids are escaped in the status URL (\(s.url?.absoluteString ?? ""))")
    }

    // Replies.
    check((try? Meshy3DProtocol.createdID(Data(#"{"result":"018a210d-8ba4-705c-b111-1f1776f7f578"}"#.utf8))) == "018a210d-8ba4-705c-b111-1f1776f7f578"
          && thrown { _ = try Meshy3DProtocol.createdID(Data("{}".utf8)) } == .badReply("result"), "meshy: the create reply gives the task id")
    let done = #"{"id":"t1","type":"multi-image-to-3d","model_urls":{"glb":"https://assets.meshy.ai/x/model.glb?Expires=1","fbx":"https://assets.meshy.ai/x/model.fbx"},"thumbnail_url":"https://assets.meshy.ai/x/preview.png","progress":100,"status":"SUCCEEDED","texture_urls":[{"base_color":"https://assets.meshy.ai/x/t.png"}],"preceding_tasks":0,"task_error":null,"consumed_credits":30}"#
    if let t = try? Meshy3DProtocol.task(Data(done.utf8)) {
        check(t.id == "t1" && t.status == .succeeded && t.finished && t.progress == 100 && t.glb?.host == "assets.meshy.ai" && t.credits == 30 && t.error == nil && t.preceding == 0,
              "meshy: a finished task gives its GLB link and the credits used")
    } else { check(false, "meshy: the task reply parses") }
    let running = try? Meshy3DProtocol.task(Data(#"{"id":"t2","status":"IN_PROGRESS","progress":42,"model_urls":{},"preceding_tasks":3}"#.utf8))
    let failed = try? Meshy3DProtocol.task(Data(#"{"id":"t3","status":"FAILED","progress":0,"task_error":{"message":"The model has too many triangles"}}"#.utf8))
    let unsafe = try? Meshy3DProtocol.task(Data(#"{"id":"t4","status":"SUCCEEDED","progress":100,"model_urls":{"glb":"http://example.com/m.glb"}}"#.utf8))
    check(running?.status == .inProgress && running?.finished == false && running?.progress == 42 && running?.glb == nil && running?.preceding == 3
          && failed?.status == .failed && failed?.error == "The model has too many triangles" && unsafe?.glb == nil,
          "meshy: running and failed tasks are read; a model link that is not https is ignored")
    check(thrown { _ = try Meshy3DProtocol.task(Data(#"{"id":"t5","status":"WAITING"}"#.utf8)) } == .badReply("task"), "meshy: an unknown status is not guessed at")
    func status(_ code: Int, _ body: String = "{}") -> MeshyError? { thrown { try Meshy3DProtocol.check(status: code, body: Data(body.utf8)) } }
    check(status(200) == nil && status(401) == .unauthorized && status(402, #"{"message":"Insufficient credits"}"#) == .payment("Insufficient credits") && status(403) == .moderated
          && status(404) == .notFound && status(429) == .rateLimited && status(400, #"{"message":"Invalid image count"}"#) == .badRequest("Invalid image count") && status(503) == .server(503),
          "meshy: each HTTP error becomes its own message")
    print("RPG meshy: requests and replies")
}
