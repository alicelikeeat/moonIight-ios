import Foundation

/// One gate for game content that does not come from the editors: an AI
/// reply or a shared JSON content pack. Content is decoded, checked against
/// the same rules the editors enforce, cross-checked (a boss may only cast
/// skills that exist), and every rejected piece is named with the reason.
/// Valid pieces still go in when others are rejected; nothing is half-applied.
enum ContentCompiler {
    /// Larger packs are refused before decoding.
    static let maxBytes = 1_000_000
    /// Ids the game ships with; a pack may use them but never replace them.
    static let reservedPrefixes = ["tpl.", "builtin."]

    /// A content pack: any of its lists may be missing.
    struct Pack: Codable, Equatable, Sendable {
        var skills: [SkillDefinition]?
        var bosses: [BossScript]?
        var stories: [RPGStoryGraph]?
    }

    struct Issue: Equatable, Sendable {
        var item: String
        var reason: String
    }

    struct Compiled: Equatable, Sendable {
        var skills: [SkillDefinition] = []
        var bosses: [BossScript] = []
        var stories: [RPGStoryGraph] = []
        var issues: [Issue] = []
        var isEmpty: Bool { skills.isEmpty && bosses.isEmpty && stories.isEmpty }
        /// "2 skills, 1 boss, 0 stories; 1 rejected".
        var summary: String {
            L10n.t("技能 \(skills.count) 个，Boss \(bosses.count) 个，剧情 \(stories.count) 段", "\(skills.count) skills, \(bosses.count) bosses, \(stories.count) stories")
                + (issues.isEmpty ? "" : L10n.t("；未导入 \(issues.count) 项", "; \(issues.count) not imported"))
        }
    }

    /// Decodes and checks a pack. `existingSkills`: skill ids already in the
    /// world (templates are always known).
    static func compile(_ data: Data, existingSkills: Set<String> = []) -> Compiled {
        var out = Compiled()
        guard data.count <= maxBytes else { out.issues.append(Issue(item: "pack", reason: L10n.t("内容包超过 1 MB", "The pack is over 1 MB"))); return out }
        let pack: Pack
        do { pack = try JSONDecoder().decode(Pack.self, from: data) }
        catch { out.issues.append(Issue(item: "pack", reason: L10n.t("不是有效的内容包 JSON", "Not a valid content pack JSON"))); return out }

        var seen = Set<String>()
        func reserved(_ id: String) -> Bool { reservedPrefixes.contains { id.hasPrefix($0) } }
        for skill in pack.skills ?? [] {
            if reserved(skill.id) { out.issues.append(Issue(item: skill.id, reason: L10n.t("内置技能不能被替换", "Built-in skills cannot be replaced"))); continue }
            if !seen.insert("skill:" + skill.id).inserted { out.issues.append(Issue(item: skill.id, reason: L10n.t("技能 id 重复", "Duplicate skill id"))); continue }
            guard skill.valid else { out.issues.append(Issue(item: skill.id, reason: L10n.t("技能超出范围（名称、冷却、耐力或事件数）", "Skill out of range (name, cooldown, stamina or events)"))); continue }
            out.skills.append(skill)
        }
        let known = existingSkills.union(out.skills.map(\.id)).union(SkillLibrary.templates().map(\.id))
        for boss in pack.bosses ?? [] {
            if reserved(boss.id) { out.issues.append(Issue(item: boss.id, reason: L10n.t("内置 Boss 不能被替换", "Built-in bosses cannot be replaced"))); continue }
            if !seen.insert("boss:" + boss.id).inserted { out.issues.append(Issue(item: boss.id, reason: L10n.t("Boss id 重复", "Duplicate boss id"))); continue }
            guard boss.valid else { out.issues.append(Issue(item: boss.id, reason: L10n.t("Boss 阶段不合规（1–6 段、首段 100%、间隔 0.5–60 秒）", "Boss phases invalid (1–6 phases, first at 100%, 0.5–60 s between casts)"))); continue }
            let missing = Set(boss.phases.flatMap { $0.skills.map(\.skillID) }).subtracting(known).sorted()
            guard missing.isEmpty else { out.issues.append(Issue(item: boss.id, reason: L10n.t("引用了不存在的技能：", "Uses skills that do not exist: ") + missing.joined(separator: ", "))); continue }
            out.bosses.append(boss)
        }
        for story in pack.stories ?? [] {
            if story.id == RPGOfficialStory.graph.id { out.issues.append(Issue(item: story.id, reason: L10n.t("官方主线不能被替换", "The official story cannot be replaced"))); continue }
            if !seen.insert("story:" + story.id).inserted { out.issues.append(Issue(item: story.id, reason: L10n.t("剧情 id 重复", "Duplicate story id"))); continue }
            do { try story.validate() } catch { out.issues.append(Issue(item: story.id, reason: error.localizedDescription)); continue }
            if story.nodes.contains(where: { $0.mediaBindingID != nil }) {
                out.issues.append(Issue(item: story.id, reason: L10n.t("内容包里的剧情不能引用本机素材", "Stories in a pack cannot use media from this phone"))); continue
            }
            out.stories.append(story)
        }
        return out
    }

    /// Puts compiled skills and bosses into the 3D world; ones with the
    /// same id are replaced (a newer version of the pack). Stories go in
    /// through `RPGStoryAuthoring.install`, which keeps its own limits.
    static func merge(_ compiled: Compiled, into spatial: inout SpatialWorld) {
        if !compiled.skills.isEmpty {
            var skills = spatial.skills ?? []
            for skill in compiled.skills { skills.removeAll { $0.id == skill.id }; skills.append(skill) }
            spatial.skills = skills
        }
        if !compiled.bosses.isEmpty {
            var bosses = spatial.bossScripts ?? []
            for boss in compiled.bosses { bosses.removeAll { $0.id == boss.id }; bosses.append(boss) }
            spatial.bossScripts = bosses
        }
    }

    /// The World Director's AI plan, through the same gate.
    static func worldIntent(_ data: Data, theme: WorldTheme) -> (intent: WorldIntent?, issues: [Issue]) {
        guard data.count <= maxBytes else { return (nil, [Issue(item: "intent", reason: L10n.t("回复超过 1 MB", "The reply is over 1 MB"))]) }
        guard let intent = WorldIntentResolver.decode(data, theme: theme) else { return (nil, [Issue(item: "intent", reason: L10n.t("世界规划不符合格式", "The world plan does not match the schema"))]) }
        return (intent, [])
    }
}
