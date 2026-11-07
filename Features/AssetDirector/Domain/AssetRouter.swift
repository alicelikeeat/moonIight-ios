import Foundation

// v1.87 AI Asset Director — routing an analysed asset to the processing
// that can actually use it. A "module" is a capability, not a separate
// paid model: most are Moonlight's own local pipelines. Anything not
// connected says so; nothing here pretends to have run.

enum AssetModule: String, Codable, CaseIterable, Sendable {
    case characterAI, riggingAI, animationAI, architectureAI, worldDirector, terrainAI, materialAI, effectAI, styleMatcher
    var title: String {
        switch self {
        case .characterAI: L10n.t("角色 AI", "Character AI")
        case .riggingAI: L10n.t("骨骼 AI", "Rigging AI")
        case .animationAI: L10n.t("动作 AI", "Animation AI")
        case .architectureAI: L10n.t("建筑 AI", "Architecture AI")
        case .worldDirector: L10n.t("世界导演", "World Director")
        case .terrainAI: L10n.t("地形 AI", "Terrain AI")
        case .materialAI: L10n.t("材质 AI", "Material AI")
        case .effectAI: L10n.t("特效 AI", "Effect AI")
        case .styleMatcher: L10n.t("风格匹配", "Style Matcher")
        }
    }
}

/// Concrete operations; each maps to one real code path in the app.
enum AssetOperation: String, Codable, CaseIterable, Sendable {
    /// Image → 3D model with the on-device depth pipeline (Generate3D).
    case generateModelFromImage
    /// Put a cut-out picture in the world as a standee (media binding).
    case placeSprite
    /// Auto-rig a model without a skeleton (Generate3DRigging).
    case autoRig
    /// Make motion clips for a rigged model (Claude motion, needs a key).
    case generateMotion
    /// Use as style / palette input for the World Director.
    case useAsStyleReference
    /// Place a model in the current world through the World Director.
    case placeModel
    /// Glass tint and texture binding from the picture's colours.
    case configureMaterial
    /// Show a looping GIF / video as a moving effect or screen.
    case adaptEffect
    /// Slice a sprite-sheet GIF into actions (not built yet).
    case sliceSpriteSheet
    /// Height map from a terrain photo (not built: no terrain model).
    case terrainFromPhoto
    /// Gather style-alike assets into a custom style group.
    case buildStyleGroup

    var title: String {
        switch self {
        case .generateModelFromImage: L10n.t("用图片生成 3D 模型", "Make a 3D model from the picture")
        case .placeSprite: L10n.t("作为立牌放进世界", "Place as a standee")
        case .autoRig: L10n.t("自动骨骼与蒙皮", "Auto-rig and skin")
        case .generateMotion: L10n.t("生成待机 / 行走 / 攻击动作", "Make idle / walk / attack motion")
        case .useAsStyleReference: L10n.t("作为世界风格参考", "Use as world style reference")
        case .placeModel: L10n.t("放进当前世界", "Place in the current world")
        case .configureMaterial: L10n.t("配置为玻璃材质", "Set up as a glass material")
        case .adaptEffect: L10n.t("作为动态特效 / 屏幕", "Use as a moving effect / screen")
        case .sliceSpriteSheet: L10n.t("切帧并映射动作", "Slice frames into actions")
        case .terrainFromPhoto: L10n.t("由照片生成地形高度", "Terrain heights from the photo")
        case .buildStyleGroup: L10n.t("建立风格组", "Build a style group")
        }
    }
}

enum AssetCapabilityState: Equatable, Sendable {
    case available
    /// Built, but needs something first (a key, consent, a setting).
    case needsSetup(String)
    /// Not built or no model on this device.
    case unavailable(String)
    var usable: Bool { self == .available }
}

/// What this install can actually do, decided by the app at runtime.
struct AssetCapabilities: Equatable, Sendable {
    var depthModelBundled: Bool
    var cloudKeyPresent: Bool
    var cloudConsent: Bool
    var rigging: Bool = true

    func state(_ op: AssetOperation) -> AssetCapabilityState {
        switch op {
        case .generateModelFromImage:
            depthModelBundled ? .available : .unavailable(L10n.t("这个安装包没有本地深度模型", "This build has no on-device depth model"))
        case .placeSprite, .useAsStyleReference, .placeModel, .configureMaterial, .adaptEffect, .buildStyleGroup: .available
        case .autoRig: rigging ? .available : .unavailable(L10n.t("自动骨骼不可用", "Auto-rig unavailable"))
        case .generateMotion:
            !cloudKeyPresent ? .needsSetup(L10n.t("需要在设置里填写 Anthropic API 密钥", "Needs an Anthropic API key in Settings"))
                : !cloudConsent ? .needsSetup(L10n.t("需要先在智能素材库开启云端处理", "Turn on cloud processing in the Asset Director first")) : .available
        case .sliceSpriteSheet: .unavailable(L10n.t("切帧与动作映射尚未接入；原 GIF 可以直接作为动画使用", "Frame slicing is not built yet; the GIF itself can be used as an animation"))
        case .terrainFromPhoto: .unavailable(L10n.t("没有接入地形模型：不会凭照片伪造高度，只能作风格参考", "No terrain model: heights are not invented from a photo; style reference only"))
        }
    }
}

enum AssetCost: String, Codable, Sendable {
    case instant, seconds, minutes, cloud
    var title: String {
        switch self {
        case .instant: L10n.t("即时", "Instant")
        case .seconds: L10n.t("几秒", "Seconds")
        case .minutes: L10n.t("一到几分钟", "A few minutes")
        case .cloud: L10n.t("云端请求（按 API 计费）", "Cloud request (billed by the API)")
        }
    }
}

/// One suggested job, structured so the UI can show it and the app can run it.
struct AssetTaskSuggestion: Equatable, Sendable, Identifiable {
    var inputIDs: [String]
    var module: AssetModule
    var operation: AssetOperation
    var output: String
    var prerequisites: [String]
    var external: Bool
    var cost: AssetCost
    /// Everything that creates files, uploads or changes a world asks first.
    var needsConfirmation: Bool
    var fallback: String
    var state: AssetCapabilityState
    var reason: String
    var id: String { module.rawValue + ":" + operation.rawValue + ":" + inputIDs.joined(separator: ",") }
}

enum AssetRouter {
    /// Suggestions for one record, best first; only operations that fit
    /// what the asset really is right now.
    static func route(_ r: AssetIntelligenceRecord, capabilities caps: AssetCapabilities) -> [AssetTaskSuggestion] {
        guard r.status == .ready || r.status == .needsReview, let category = r.primaryCategory ?? r.candidates.first?.category else { return [] }
        let t = r.signals?.technical
        var out: [AssetTaskSuggestion] = []
        func add(_ module: AssetModule, _ op: AssetOperation, output: String, needs: [String] = [], external: Bool = false, cost: AssetCost, confirm: Bool = true, fallback: String, reason: String) {
            out.append(AssetTaskSuggestion(inputIDs: [r.assetID], module: module, operation: op, output: output, prerequisites: needs, external: external,
                                           cost: cost, needsConfirmation: confirm, fallback: fallback, state: caps.state(op), reason: reason))
        }
        let keepOriginal = L10n.t("保留原素材，不做改动", "Keep the original unchanged")
        switch (r.mediaType, category) {
        case (.image, .character):
            if r.recommendedUses.contains(.sprite) {
                add(.characterAI, .placeSprite, output: L10n.t("世界里的角色立牌", "Character standee in the world"), cost: .instant, fallback: keepOriginal,
                    reason: L10n.t("透明背景的人物立绘可以直接当精灵", "A cut-out character picture works as a sprite as is"))
            }
            add(.characterAI, .generateModelFromImage, output: L10n.t("深度立体 3D 模型（非完整 360°）", "Depth-relief 3D model (not full 360°)"),
                needs: [L10n.t("正面清晰、背景干净", "A clear front view on a clean background")], cost: .minutes,
                fallback: L10n.t("失败时保留图片作为立牌", "If it fails, keep the picture as a standee"),
                reason: L10n.t("人物立绘可以作为 3D 建模的输入", "A character picture can seed a 3D model"))
        case (.model, .character):
            if t?.hasSkeleton != true {
                add(.riggingAI, .autoRig, output: L10n.t("带骨骼和蒙皮的模型（新版本，原模型保留）", "Rigged, skinned model (new version; original kept)"), cost: .seconds,
                    fallback: keepOriginal, reason: L10n.t("角色模型还没有骨骼", "The character model has no skeleton yet"))
            } else if (t?.animationNames ?? []).isEmpty {
                add(.animationAI, .generateMotion, output: L10n.t("待机、行走、攻击动作片段", "Idle, walk and attack clips"), needs: [L10n.t("模型已有骨骼", "Model is rigged")],
                    external: true, cost: .cloud, fallback: L10n.t("使用游戏内置的通用动作", "Use the game's built-in motions"),
                    reason: L10n.t("有骨骼但没有动作片段", "Rigged but has no animation clips"))
            }
            add(.worldDirector, .placeModel, output: L10n.t("站在世界里的角色", "A character standing in the world"), cost: .seconds, fallback: keepOriginal,
                reason: L10n.t("模型可以直接放进 RealityKit 场景", "The model can go straight into the RealityKit scene"))
        case (.model, _):
            add(.worldDirector, .placeModel, output: L10n.t("场景里的建筑 / 道具模型", "A building / prop model in the scene"), cost: .seconds, fallback: keepOriginal,
                reason: category == .building ? L10n.t("可用的建筑模型交给世界导演摆放", "A usable building model goes to the World Director") : L10n.t("静态模型可作场景道具", "A static model works as a scene prop"))
        case (.image, .building):
            add(.architectureAI, .useAsStyleReference, output: L10n.t("建筑风格与配色", "Building style and palette"), cost: .instant, confirm: false, fallback: keepOriginal,
                reason: L10n.t("建筑照片只作为风格参考，不会被当成模型", "A building photo is a style reference, never treated as a model"))
        case (.image, .nature):
            add(.terrainAI, .terrainFromPhoto, output: L10n.t("地形高度", "Terrain heights"), cost: .minutes, fallback: L10n.t("作为风格参考使用", "Use as a style reference"),
                reason: L10n.t("地形照片", "Terrain photo"))
            add(.architectureAI, .useAsStyleReference, output: L10n.t("环境配色", "Environment palette"), cost: .instant, confirm: false, fallback: keepOriginal,
                reason: L10n.t("可作为生物群系与配色参考", "Can guide biome and palette"))
        case (.image, .material):
            add(.materialAI, .configureMaterial, output: L10n.t("玻璃色调与贴图配置", "Glass tint and texture setup"), cost: .instant, fallback: keepOriginal,
                reason: L10n.t("可拼接的纹理适合做材质", "A tiling texture fits a material"))
        case (.gif, .character):
            add(.characterAI, .placeSprite, output: L10n.t("会动的角色精灵", "An animated character sprite"), cost: .instant, fallback: keepOriginal,
                reason: L10n.t("角色动画 GIF 可以直接使用", "A character animation GIF can be used as is"))
            add(.effectAI, .sliceSpriteSheet, output: L10n.t("按动作切好的帧", "Frames sliced per action"), cost: .seconds, fallback: L10n.t("整段 GIF 作为一个动画", "Use the whole GIF as one animation"),
                reason: L10n.t("精灵动画可以拆成动作", "A sprite animation can be split into actions"))
        case (.gif, _), (.video, .effect):
            add(.effectAI, .adaptEffect, output: L10n.t("循环的动态特效", "A looping effect"), cost: .instant, fallback: keepOriginal,
                reason: L10n.t("循环动画可以作为特效或动态装饰", "A looping animation works as an effect or decoration"))
        case (.video, _):
            add(.effectAI, .adaptEffect, output: L10n.t("影像屏或动态贴图", "A media screen or moving texture"), cost: .instant, fallback: keepOriginal,
                reason: r.sceneContext.contains(.water) ? L10n.t("有水的画面适合放在喷泉或水面", "Water footage fits a fountain or water surface") : L10n.t("视频可以放上影像屏", "Video can go on a media screen"))
        case (.image, _):
            add(.architectureAI, .useAsStyleReference, output: L10n.t("风格与配色参考", "Style and palette reference"), cost: .instant, confirm: false, fallback: keepOriginal,
                reason: L10n.t("参考图参与世界风格规划", "A reference shapes the world's style"))
        case (.audio, _):
            break
        }
        return out
    }

    /// Group suggestion: assets with the same style make a style group.
    static func styleGroups(_ records: [AssetIntelligenceRecord], capabilities caps: AssetCapabilities) -> [AssetTaskSuggestion] {
        ArtStyleMatcher.groups(records).map { ids in
            AssetTaskSuggestion(inputIDs: ids, module: .styleMatcher, operation: .buildStyleGroup, output: L10n.t("自定义风格组", "Custom style group"), prerequisites: [],
                                external: false, cost: .instant, needsConfirmation: true, fallback: L10n.t("保持分开", "Keep them separate"),
                                state: caps.state(.buildStyleGroup), reason: L10n.t("\(ids.count) 个素材的色彩和笔触相近", "\(ids.count) assets share colour and stroke"))
        }
    }
}
