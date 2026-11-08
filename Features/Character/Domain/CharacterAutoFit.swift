import Foundation

// v1.91: CharacterAutoFitPipeline's first step — look at the input, then
// choose a route. Routes:
//   A keepRig            a model with a usable skeleton and weights: keep
//                        them, map the joints, retarget the motion library
//   B autoRig            a complete mesh without a rig: RiggingPipeline
//                        (with the base body's borrowed weights)
//   C baseBodyFromImage  a whole person in a picture or relief: shape and
//                        paint the base body (marked as inferred)
//   D reconstructThenRig several views: build the geometry, then B
//   E notHumanoid        refused with the reason (never forced onto a
//                        human skeleton); a static model stays possible
// Low-confidence results need the user's confirmation before they replace
// anything. Pure Swift (tested on Linux).

struct AutoFitFacts: Equatable, Sendable {
    enum Input: String, Sendable { case usdz, glb, generatedMesh, photo, multiView, video }
    var input: Input
    /// 0…1 humanoid confidence, nil when not measured.
    var humanoid: Float?
    var hasSkeleton = false
    var hasWeights = false
    var hasAnimation = false
    var complete3D = false
    /// A depth relief: front surface only.
    var reliefOnly = false
    /// A whole person (face, shoulders, hips, feet) seen in the picture.
    var personVisible = false
}

enum AutoFitRoute: String, Equatable, Sendable {
    case keepRig, autoRig, baseBodyFromImage, reconstructThenRig, notHumanoid
    var letter: String { switch self { case .keepRig: "A"; case .autoRig: "B"; case .baseBodyFromImage: "C"; case .reconstructThenRig: "D"; case .notHumanoid: "E" } }
}

struct AutoFitPlan: Equatable, Sendable {
    var route: AutoFitRoute
    var steps: [String]
    /// The result is a guess from limited information (one picture, a relief).
    var inferred: Bool
    var needsConfirmation: Bool
    var reasons: [String]
}

enum CharacterAutoFit {
    static func plan(_ f: AutoFitFacts) -> AutoFitPlan {
        let confident = (f.humanoid ?? 0) >= 0.7
        let human = f.humanoid.map { $0 >= 0.4 } ?? (f.personVisible || f.hasSkeleton)
        func make(_ route: AutoFitRoute, _ steps: [String], inferred: Bool = false, _ reasons: [String]) -> AutoFitPlan {
            AutoFitPlan(route: route, steps: steps, inferred: inferred, needsConfirmation: inferred || !confident, reasons: reasons)
        }
        let check = L10n.t("质量检查", "quality check"), place = L10n.t("用户确认后放入世界", "place in the world after confirmation")
        switch f.input {
        case .photo, .video:
            if f.personVisible {
                return make(.baseBodyFromImage, [L10n.t("识别关键点和轮廓", "find keypoints and outline"), L10n.t("按比例调整底模", "shape the base body"),
                                                 L10n.t("投影贴图", "project the texture"), L10n.t("套用通用动作", "apply the shared motions"), check, place],
                            inferred: true, [L10n.t("画面里有完整人物；背面和遮挡处是推断的", "A whole person is visible; the back and hidden parts are inferred")])
            }
            return make(.notHumanoid, [], [L10n.t("没有看到完整人物，不能套用人形底模（仍可生成静态立体模型）", "No whole person is visible; a human body cannot be fitted (a static relief is still possible)")])
        case .multiView:
            if f.personVisible {
                return make(.baseBodyFromImage, [L10n.t("用正面和背面照片调整并绘制底模", "shape and paint the base body from the front and back photos"), check, place],
                            inferred: true, [L10n.t("正面照片里有完整人物", "The front photo shows a whole person")])
            }
            return make(.reconstructThenRig, [L10n.t("多视角重建几何", "reconstruct the geometry"), L10n.t("自动绑骨", "automatic rig"), check, place],
                        [L10n.t("多张照片先重建成完整网格", "Several photos are first rebuilt into a complete mesh")])
        case .usdz, .glb, .generatedMesh:
            guard human else {
                return make(.notHumanoid, [], [L10n.t("不是人形（人形可信度 \(Int((f.humanoid ?? 0) * 100))%），不强行套用人形骨骼", "Not humanoid (\(Int((f.humanoid ?? 0) * 100))% humanoid); no human skeleton is forced on it")])
            }
            if f.hasSkeleton && f.hasWeights {
                return make(.keepRig, [L10n.t("保留原骨骼和权重", "keep its skeleton and weights"), L10n.t("映射关节语义", "map joint meanings"),
                                       L10n.t("重定向动作库", "retarget the motion library"), check, place],
                            [L10n.t("模型自带可用的骨骼和蒙皮", "The model has a usable skeleton and skin") + (f.hasAnimation ? L10n.t("，也保留它自己的动画", ", and keeps its own animations") : "")])
            }
            if f.reliefOnly {
                return make(.baseBodyFromImage, [L10n.t("用原图套用底模（完整 360°）", "fit the base body from the source picture (full 360°)"), check, place],
                            inferred: true, [L10n.t("深度立体模型只有正面，改用底模得到完整身体", "A depth relief has only a front; the base body gives a whole one")])
            }
            if f.complete3D {
                return make(.autoRig, [L10n.t("估计关节", "estimate joints"), L10n.t("生成骨骼", "build the skeleton"), L10n.t("计算蒙皮（含底模权重对比）", "solve weights (compared with the base body's)"),
                                       L10n.t("动作测试", "motion tests"), check, place],
                            [f.hasSkeleton ? L10n.t("有骨骼但没有权重，重新计算", "A skeleton without weights; weights are solved") : L10n.t("完整网格，没有骨骼", "A complete mesh without a rig")])
            }
            return make(.notHumanoid, [], [L10n.t("形体信息不足（不是完整网格）", "Not enough shape (not a complete mesh)")])
        }
    }
}
