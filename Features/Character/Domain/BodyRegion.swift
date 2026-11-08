import Foundation

// The base body's joints grouped by body region (the base-body view lists
// and highlights them this way).

/// Where a base-body joint sits, for listing and highlighting.
enum BodyRegion: String, CaseIterable, Identifiable {
    case torso, head, leftArm, rightArm, leftFingers, rightFingers, leftLeg, rightLeg
    var id: String { rawValue }
    var title: String {
        switch self {
        case .torso: L10n.t("躯干", "Torso"); case .head: L10n.t("头部", "Head")
        case .leftArm: L10n.t("左臂", "Left arm"); case .rightArm: L10n.t("右臂", "Right arm")
        case .leftFingers: L10n.t("左手手指", "Left fingers"); case .rightFingers: L10n.t("右手手指", "Right fingers")
        case .leftLeg: L10n.t("左腿", "Left leg"); case .rightLeg: L10n.t("右腿", "Right leg")
        }
    }

    static func of(_ id: String) -> BodyRegion {
        if id.hasPrefix("ext.leftFinger") { return .leftFingers }
        if id.hasPrefix("ext.rightFinger") { return .rightFingers }
        if ["head", "headEnd", "ext.jaw", "ext.leftEye", "ext.rightEye"].contains(id) { return .head }
        let left = id.hasPrefix("left")
        guard left || id.hasPrefix("right") else { return .torso }
        let isLeg = ["Thigh", "Shin", "Foot", "Toe"].contains { id.contains($0) }
        if isLeg { return left ? .leftLeg : .rightLeg }
        return left ? .leftArm : .rightArm
    }

    /// A readable joint name: standard joints by their tag, extensions spelled out.
    static func title(_ joint: RigJoint) -> String {
        if joint.semanticTag != .other { return joint.semanticTag.title }
        let id = joint.jointID
        switch id {
        case "ext.jaw": return L10n.t("下颌", "Jaw")
        case "ext.leftEye": return L10n.t("左眼", "Left eye")
        case "ext.rightEye": return L10n.t("右眼", "Right eye")
        default: break
        }
        // ext.leftFinger2.3 → 左手 食指 第 3 节
        let left = id.hasPrefix("ext.left")
        let digits = id.filter(\.isNumber)
        guard digits.count == 2, let finger = Int(String(digits.first!)), let segment = Int(String(digits.last!)) else { return id }
        let names = [L10n.t("拇指", "thumb"), L10n.t("食指", "index"), L10n.t("中指", "middle"), L10n.t("无名指", "ring"), L10n.t("小指", "little")]
        let name = names.indices.contains(finger - 1) ? names[finger - 1] : "\(finger)"
        return left ? L10n.t("左手\(name) 第 \(segment) 节", "Left \(name) \(segment)") : L10n.t("右手\(name) 第 \(segment) 节", "Right \(name) \(segment)")
    }
}
