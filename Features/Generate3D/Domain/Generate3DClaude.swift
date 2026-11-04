import Foundation

// v1.72: optional online motion design with Claude. The user's own API key,
// an explicit consent before every send, and only text leaves the phone:
// the motion description and the skeleton (bone names and joint
// positions). No pictures, no mesh. Claude answers with a clip in a fixed
// JSON shape (structured outputs); the clip is clamped to safe ranges here
// and must still pass the on-device RigValidation before it is saved.

enum ClaudeMotionError: Error, Equatable, LocalizedError {
    case noKey
    case http(Int, String)
    case refused(String?)
    case truncated
    case badReply(String)
    case emptyClip

    var errorDescription: String? {
        switch self {
        case .noKey: L10n.t("请先填写你自己的 Anthropic API Key。", "Enter your own Anthropic API key first.")
        case .http(let code, let message): L10n.t("Claude 服务返回错误 \(code)：", "Claude returned error \(code): ") + message
        case .refused(let category): L10n.t("Claude 拒绝了这个请求", "Claude declined this request") + (category.map { "（\($0)）" } ?? "") + L10n.t("，请换一种描述。", "; try describing it differently.")
        case .truncated: L10n.t("回答被截断，请把动作描述得简单一些再试。", "The answer was cut off; try a simpler description.")
        case .badReply(let detail): L10n.t("没能读懂 Claude 的回答：", "Could not read Claude's answer: ") + detail
        case .emptyClip: L10n.t("回答里没有可用的骨骼通道。", "The answer has no usable bone channels.")
        }
    }
}

enum ClaudeMotion {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    /// Server-side fallback when the main model declines (scalar "default" form).
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let keyAccount = "anthropic-api-key"

    struct ModelChoice: Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        /// Whether `fallbacks: "default"` is sent for this model.
        var fallbacks: Bool
    }
    static let models: [ModelChoice] = [
        ModelChoice(id: "claude-opus-5-5", name: "Claude Opus 5.5", fallbacks: true),
        ModelChoice(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", fallbacks: false),
    ]

    static let boneNames: [RigBone: String] = [
        .torso: "torso", .head: "head", .rightUpperArm: "right_upper_arm", .rightForearm: "right_forearm",
        .leftUpperArm: "left_upper_arm", .leftForearm: "left_forearm", .rightThigh: "right_thigh", .rightShin: "right_shin",
        .leftThigh: "left_thigh", .leftShin: "left_shin",
    ]
    static func bone(named name: String) -> RigBone? { boneNames.first { $0.value == name }?.key }

    // MARK: Request

    /// JSON schema the answer must follow (structured outputs).
    static var schema: [String: Any] {
        let channel: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["bone", "axis", "amplitude_degrees", "bias_degrees", "phase_turns", "cycles_per_period"],
            "properties": [
                "bone": ["type": "string", "enum": RigBone.allCases.compactMap { boneNames[$0] }],
                "axis": ["type": "string", "enum": ["x", "y", "z"]],
                "amplitude_degrees": ["type": "number"],
                "bias_degrees": ["type": "number"],
                "phase_turns": ["type": "number"],
                "cycles_per_period": ["type": "integer"],
            ] as [String: Any],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["name", "period_seconds", "channels"],
            "properties": [
                "name": ["type": "string"],
                "period_seconds": ["type": "number"],
                "channels": ["type": "array", "items": channel],
            ] as [String: Any],
        ]
    }

    static let system = """
    You design looping animation clips for a small 3D character made from one picture. \
    The skeleton has ten bones: torso (root, at the hips), head, right/left upper arm, right/left forearm, \
    right/left thigh, right/left shin. "Right" is the character's right, which is on the viewer's left. \
    Model space: x points to the viewer's right, y up, z towards the viewer; the character faces the viewer. \
    Each channel rotates one bone about its joint, relative to its parent: \
    angle(t) = bias + amplitude * sin(2π * cycles_per_period * t / period + 2π * phase_turns). \
    Axis x swings a limb forward or back (positive bends it backwards, so a forward leg swing starts with a negative angle); \
    axis z raises it sideways (raising the right arm out to the side is a negative z angle, the left arm is positive); \
    axis y twists. Forearms and shins bend at the elbow and knee. \
    The picture is flat, so keep twists (y) small and prefer x and z. \
    Keep amplitudes and biases within ±90 degrees and below 45 degrees for the torso and head; period between 0.4 and 4 seconds; \
    cycles_per_period a whole number from 1 to 4 so the clip loops seamlessly. \
    Use as few channels as the motion needs (at most 16). Give the clip a short name in the user's language.
    """

    /// Body of the Messages API request.
    static func requestBody(description: String, skeleton: RigSkeleton, model: ModelChoice) throws -> Data {
        let joints = skeleton.bones.compactMap { b -> String? in
            guard let name = boneNames[b.bone] else { return nil }
            let head = b.head.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            let tail = b.tail.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            return "- \(name): joint (\(head)) to (\(tail))"
        }.joined(separator: "\n")
        let user = """
        Skeleton of this character (model units, the model is about 1 tall):
        \(joints)

        Motion to design:
        \(description)
        """
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": user]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": schema]] as [String: Any],
        ]
        if model.fallbacks { body["fallbacks"] = "default" }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func headers(apiKey: String, model: ModelChoice) -> [String: String] {
        var h = ["content-type": "application/json", "x-api-key": apiKey, "anthropic-version": apiVersion]
        if model.fallbacks { h["anthropic-beta"] = fallbackBeta }
        return h
    }

    // MARK: Response

    /// The clip from a Messages API reply. Checks the stop reason first.
    static func clip(fromResponse data: Data, status: Int) throws -> RigClip {
        try clip(fromJSON: Data(try answerText(data, status: status).utf8))
    }

    /// The structured answer text of a Messages API reply (stop reason,
    /// refusal and HTTP errors checked first).
    static func answerText(_ data: Data, status: Int) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = ((object?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ClaudeMotionError.http(status, message)
        }
        guard let object else { throw ClaudeMotionError.badReply("not JSON") }
        switch object["stop_reason"] as? String {
        case "refusal": throw ClaudeMotionError.refused((object["stop_details"] as? [String: Any])?["category"] as? String)
        case "max_tokens": throw ClaudeMotionError.truncated
        default: break
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw ClaudeMotionError.badReply("no text") }
        return text
    }

    /// The clip from the structured JSON answer, clamped to safe ranges.
    static func clip(fromJSON data: Data) throws -> RigClip {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeMotionError.badReply("not JSON") }
        let deg: Float = .pi / 180
        func number(_ any: Any?) -> Float? { (any as? NSNumber).map { $0.floatValue }.flatMap { $0.isFinite ? $0 : nil } }
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, v)) }
        var channels: [RigClip.Channel] = []
        for item in (object["channels"] as? [[String: Any]] ?? []).prefix(16) {
            guard let bone = (item["bone"] as? String).flatMap(bone(named:)) else { continue }
            let axis: [Float]
            switch item["axis"] as? String {
            case "x": axis = [1, 0, 0]
            case "y": axis = [0, 1, 0]
            case "z": axis = [0, 0, 1]
            default: continue
            }
            let limit: Float = (bone == .torso || bone == .head) ? 45 : 90
            let amplitude = clamp(number(item["amplitude_degrees"]) ?? 0, -limit, limit)
            let bias = clamp(number(item["bias_degrees"]) ?? 0, -limit, limit)
            let phase = (number(item["phase_turns"]) ?? 0).truncatingRemainder(dividingBy: 1)
            let cycles = clamp((number(item["cycles_per_period"]) ?? 1).rounded(), 1, 4)
            channels.append(.init(bone: bone, axis: axis, amplitude: amplitude * deg, phase: phase * 2 * .pi, bias: bias * deg, frequency: cycles))
        }
        guard !channels.isEmpty else { throw ClaudeMotionError.emptyClip }
        let rawName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? "AI" : String(rawName.prefix(24))
        let period = clamp(number(object["period_seconds"]) ?? 1.2, 0.4, 4)
        return RigClip(id: "ai-" + UUID().uuidString.prefix(8).lowercased(), name: name, period: period, channels: channels)
    }

    /// Adds a designed clip to a rig package (replacing one with the same
    /// name, keeping at most `limit` AI clips; standard clips are untouched).
    static func adding(_ clip: RigClip, to package: RigPackage, limit: Int = 8) -> RigPackage {
        var out = package
        out.clips.removeAll { $0.id.hasPrefix("ai-") && $0.name == clip.name }
        out.clips.append(clip)
        let ai = out.clips.filter { $0.id.hasPrefix("ai-") }
        if ai.count > limit { let drop = Set(ai.prefix(ai.count - limit).map(\.id)); out.clips.removeAll { drop.contains($0.id) } }
        return out
    }
}

// MARK: v1.74 character design (text → CharacterSpec)

/// Claude turns a description into a character spec (body, outfit, hair,
/// accessories, colours) that the phone builds into a 3D model. Only the
/// description is sent.
enum ClaudeCharacter {
    static var schema: [String: Any] {
        func e(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        let hex: [String: Any] = ["type": "string", "description": "RRGGBB"]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["name", "height_m", "build", "head_scale", "hair", "outfit", "accessories", "skin", "hair_color", "top", "bottom", "shoes", "accent", "metal"],
            "properties": [
                "name": ["type": "string"], "height_m": ["type": "number"], "head_scale": ["type": "number"],
                "build": e(CharacterSpec.Build.allCases.map(\.rawValue)), "hair": e(CharacterSpec.Hair.allCases.map(\.rawValue)),
                "outfit": e(CharacterSpec.Outfit.allCases.map(\.rawValue)),
                "accessories": ["type": "array", "items": e(CharacterSpec.Accessory.allCases.map(\.rawValue))],
                "skin": hex, "hair_color": hex, "top": hex, "bottom": hex, "shoes": hex, "accent": hex, "metal": hex,
            ] as [String: Any],
        ]
    }

    static let system = """
    You design stylised 3D game characters for a phone app that builds them from rounded primitives. \
    Read the user's description and choose: a short name in the user's language; height in metres (0.8-2.4; children and chibi \
    characters are shorter with head_scale up to 1.6, adults use 1.0); build; hair; outfit (armor for warriors and knights, robe for \
    mages, dress for princesses, ninja for ninjas and assassins, robot for robots and mechs, casual otherwise); accessories that fit \
    (at most 6; one weapon per hand: sword or staff in the right hand, shield or bow in the left); and colours as RRGGBB hex that \
    match the description and look good together. Skin is the face and hands (use metal-like greys for robots).
    """

    static func requestBody(prompt: String, model: ClaudeMotion.ModelChoice) throws -> Data {
        var body: [String: Any] = [
            "model": model.id, "max_tokens": 16000, "system": system,
            "messages": [["role": "user", "content": "Character description:\n" + String(prompt.prefix(500))]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]] as [String: Any],
        ]
        if model.fallbacks { body["fallbacks"] = "default" }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func spec(fromResponse data: Data, status: Int) throws -> CharacterSpec {
        try spec(fromJSON: Data(try ClaudeMotion.answerText(data, status: status).utf8))
    }

    static func spec(fromJSON data: Data) throws -> CharacterSpec {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeMotionError.badReply("not JSON") }
        var s = CharacterSpec(name: o["name"] as? String ?? "")
        if let h = (o["height_m"] as? NSNumber)?.floatValue { s.height = h }
        if let h = (o["head_scale"] as? NSNumber)?.floatValue { s.headScale = h }
        s.build = (o["build"] as? String).flatMap(CharacterSpec.Build.init) ?? s.build
        s.hair = (o["hair"] as? String).flatMap(CharacterSpec.Hair.init) ?? s.hair
        s.outfit = (o["outfit"] as? String).flatMap(CharacterSpec.Outfit.init) ?? s.outfit
        s.accessories = Array(((o["accessories"] as? [String]) ?? []).compactMap(CharacterSpec.Accessory.init).prefix(6))
        for (key, path) in [("skin", \CharacterSpec.skin), ("hair_color", \.hairColor), ("top", \.top), ("bottom", \.bottom), ("shoes", \.shoes), ("accent", \.accent), ("metal", \.metal)] {
            if let v = o[key] as? String { s[keyPath: path] = v }
        }
        return s.clamped
    }
}
