import Foundation

/// The one gate for outside content: what passes, what is refused and why,
/// and that valid pieces still go in next to refused ones.
func contentCompilerTests() throws {
    let bolt = SkillDefinition(id: "pack.bolt", name: "Bolt", cooldown: 2, staminaCost: 10, symbol: "bolt", events: [SkillEvent(time: 0, kind: .action(.skill))])
    let boss = BossScript(id: "pack.boss", name: "Pack Boss", phases: [
        BossPhase(threshold: 1, skills: [WeightedSkill(skillID: "pack.bolt"), WeightedSkill(skillID: "tpl.fireball")], castInterval: 3)])
    let story = RPGStoryGraph(id: "pack.story", title: "Pack", start: "hello", nodes: [.init(id: "hello", text: "你好", next: "end"), .init(id: "end", kind: .end)])
    let good = try JSONEncoder().encode(ContentCompiler.Pack(skills: [bolt], bosses: [boss], stories: [story]))
    let compiled = ContentCompiler.compile(good)
    check(compiled.skills == [bolt] && compiled.bosses == [boss] && compiled.stories == [story] && compiled.issues.isEmpty,
          "content: a valid pack passes whole (\(compiled.issues))")

    // Every refusal names the piece and the reason; the valid pieces stay.
    var unnamed = bolt; unnamed.id = "pack.unnamed"; unnamed.name = ""
    var template = bolt; template.id = "tpl.fireball"
    var lostBoss = boss; lostBoss.id = "pack.lost"; lostBoss.phases[0].skills = [WeightedSkill(skillID: "nowhere")]
    var badPhases = boss; badPhases.id = "pack.half"; badPhases.phases[0].threshold = 0.5
    var official = story; official.id = RPGOfficialStory.graph.id
    var broken = story; broken.id = "pack.broken"; broken.nodes[0].next = "missing"
    var withMedia = story; withMedia.id = "pack.media"; withMedia.nodes[0].mediaBindingID = "binding-on-this-phone"
    let mixed = try JSONEncoder().encode(ContentCompiler.Pack(skills: [bolt, unnamed, template, bolt], bosses: [boss, lostBoss, badPhases],
                                                              stories: [story, official, broken, withMedia]))
    let checked = ContentCompiler.compile(mixed)
    let refused = Set(checked.issues.map(\.item))
    check(checked.skills.map(\.id) == ["pack.bolt"] && checked.bosses.map(\.id) == ["pack.boss"] && checked.stories.map(\.id) == ["pack.story"],
          "content: valid pieces go in next to refused ones")
    check(refused == ["pack.unnamed", "tpl.fireball", "pack.bolt", "pack.lost", "pack.half", RPGOfficialStory.graph.id, "pack.broken", "pack.media"] && checked.issues.count == 8,
          "content: each refused piece is named once (\(checked.issues.map { $0.item + ": " + $0.reason }))")
    check(checked.issues.first { $0.item == "pack.lost" }?.reason.contains("nowhere") == true, "content: a boss names the skills it is missing")
    check(checked.summary.contains("8"), "content: the summary counts what was not imported")
    let known = ContentCompiler.compile(try JSONEncoder().encode(ContentCompiler.Pack(bosses: [lostBoss])), existingSkills: ["nowhere"])
    check(known.bosses.map(\.id) == ["pack.lost"] && known.issues.isEmpty, "content: a boss may use skills already in the world")

    // Whole-pack refusals.
    check(ContentCompiler.compile(Data(repeating: 32, count: ContentCompiler.maxBytes + 1)).issues.map(\.item) == ["pack"], "content: over 1 MB is refused before decoding")
    let junk = ContentCompiler.compile(Data("not json".utf8))
    check(junk.isEmpty && junk.issues.map(\.item) == ["pack"], "content: a broken file is refused with a reason")
    check(ContentCompiler.compile(Data("{}".utf8)) == ContentCompiler.Compiled(), "content: an empty pack is empty, not an error")

    // Into the world: same ids replaced, others kept; stories keep their own limits.
    var spatial = SpatialWorld.blank()
    var older = bolt; older.cooldown = 9
    spatial.skills = [older, SkillDefinition(id: "mine.keep", name: "Keep")]
    ContentCompiler.merge(compiled, into: &spatial)
    check(spatial.skills?.map(\.id).sorted() == ["mine.keep", "pack.bolt"] && spatial.skills?.first { $0.id == "pack.bolt" }?.cooldown == 2 && spatial.bossScripts == [boss],
          "content: a newer pack replaces its own pieces and keeps the player's")
    var world = WorldState(seed: 3)
    try RPGStoryAuthoring.install(compiled.stories[0], bindings: [], world: &world)
    check(world.story.customGraphs.map(\.id) == ["pack.story"], "content: the pack's story installs through the story rules")
    check((try? RPGStoryAuthoring.install(compiled.stories[0], bindings: [], world: &world)) == nil, "content: the same story is not installed twice")

    // The World Director's AI plan goes through the same gate.
    let plan = ContentCompiler.worldIntent(Data(#"{"colors":["FFFFFF"],"water":true,"buildingScale":9}"#.utf8), theme: .crystalKingdom)
    check(plan.intent?.water == true && plan.issues.isEmpty && (plan.intent?.buildingScale ?? 9) < 9, "content: a valid AI plan passes, clamped")
    let badPlan = ContentCompiler.worldIntent(Data("[1,2]".utf8), theme: .crystalKingdom)
    check(badPlan.intent == nil && badPlan.issues.count == 1, "content: an AI plan that does not match is refused with a reason")
    print("RPG content compiler: packs and AI plans through one gate")
}
