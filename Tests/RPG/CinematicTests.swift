import Foundation

/// Cinematic timelines: shots, captions and cues on one clock, and the
/// Boss entrance built from them.
func cinematicTests() {
    let boss = SpatialVector(140.5, 130.5, 0), player = SpatialVector(130.5, 130.5, 0)
    let intro = CinematicPlayer.bossIntro(id: "b1", name: "玻璃巨像", phases: 3, boss: boss, player: player)
    check(intro.valid && abs(intro.length - 2.6) < 1e-9, "cinema: the Boss entrance is a valid 2.6 s timeline")
    check(abs(CinematicPlayer.yaw(from: player, to: boss) - 270) < 1e-9 && abs(CinematicPlayer.yaw(from: boss, to: player) - 90) < 1e-9,
          "cinema: the camera faces from the player toward the Boss (it looks along yaw + 90°)")
    let wide = CinematicPlayer.frame(intro, from: -1, to: 0.5)
    check(wide.camera?.distance == 13 && wide.captions == ["玻璃巨像 · 3 个阶段"] && wide.cues.isEmpty && !wide.finished, "cinema: first the wide shot and the name")
    let close = CinematicPlayer.frame(intro, from: 0.5, to: 1.3)
    check(close.camera?.distance == 7 && close.camera?.target == boss + SpatialVector(0, 0, 1.4) && close.cues.map(\.preset) == [.charge], "cinema: then close on the Boss, its charge fires")
    check(CinematicPlayer.frame(intro, from: 1.3, to: 1.4).cues.isEmpty, "cinema: a cue fires exactly once")
    let end = CinematicPlayer.frame(intro, from: 1.4, to: 2.7)
    check(end.finished && end.camera == nil && end.captions.isEmpty, "cinema: it ends and hands the camera back")
    let atZero = CinematicTimeline(id: "z", cues: [CinematicCue(time: 0, preset: .spark, at: .zero)])
    check(CinematicPlayer.frame(atZero, from: -1, to: 0).cues.count == 1, "cinema: a cue at 0 fires on the first frame")
    var long = intro; long.captions.append(CinematicCaption(start: 40, duration: 1, text: "late"))
    var empty = intro; empty.captions[0].text = ""
    var backwards = intro; backwards.shots[0].start = -1
    check(!long.valid && !empty.valid && !backwards.valid, "cinema: over 30 s, an empty caption or a negative time is refused")
    let restored = try? JSONDecoder().decode(CinematicTimeline.self, from: JSONEncoder().encode(intro))
    check(restored == intro, "cinema: timelines are data and round-trip as JSON")
    print("RPG cinema: Boss entrance timeline")
}
