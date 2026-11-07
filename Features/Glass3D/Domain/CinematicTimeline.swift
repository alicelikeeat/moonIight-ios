import Foundation

/// v1.88 step 7: a short cinematic as data — camera shots, captions and
/// effect cues on one clock — played over the live 3D world. Pure: the
/// same timeline and times always give the same frame.
struct CinematicShot: Codable, Equatable, Sendable {
    var start: Double
    var duration: Double
    var camera: SpatialCameraState
}

struct CinematicCaption: Codable, Equatable, Sendable {
    var start: Double
    var duration: Double
    var text: String
}

struct CinematicCue: Codable, Equatable, Sendable {
    var time: Double
    var preset: ParticlePreset
    var at: SpatialVector
    var seconds = 0.6
}

struct CinematicTimeline: Codable, Equatable, Sendable {
    var id: String
    var shots: [CinematicShot] = []
    var captions: [CinematicCaption] = []
    var cues: [CinematicCue] = []

    var length: Double {
        (shots.map { $0.start + $0.duration } + captions.map { $0.start + $0.duration } + cues.map(\.time)).max() ?? 0
    }
    /// Short and finite: at most 30 s and 64 pieces, nothing before 0.
    var valid: Bool {
        let times = shots.flatMap { [$0.start, $0.duration] } + captions.flatMap { [$0.start, $0.duration] } + cues.map(\.time)
        return !id.isEmpty && shots.count + captions.count + cues.count <= 64 && times.allSatisfy { $0.isFinite && $0 >= 0 } && length <= 30 &&
            captions.allSatisfy { (1...120).contains($0.text.count) }
    }
}

/// One step of a playing cinematic.
struct CinematicFrame: Equatable, Sendable {
    /// Where the camera wants to be (the shot that covers this moment).
    var camera: SpatialCameraState?
    var captions: [String] = []
    /// Cues whose time fell inside this step (each fires exactly once).
    var cues: [CinematicCue] = []
    var finished = false
}

enum CinematicPlayer {
    /// The frame for the step from `from` (exclusive) to `to` (inclusive).
    static func frame(_ timeline: CinematicTimeline, from: Double, to: Double) -> CinematicFrame {
        var frame = CinematicFrame()
        frame.camera = timeline.shots.last { $0.start <= to && to < $0.start + $0.duration }?.camera
        frame.captions = timeline.captions.filter { $0.start <= to && to < $0.start + $0.duration }.map(\.text)
        // Start a timeline with `from` below 0 so cues at 0 fire too.
        frame.cues = timeline.cues.filter { $0.time > from && $0.time <= to }
        frame.finished = to >= timeline.length
        return frame
    }

    /// Facing yaw for a camera that looks from `from` toward `to` (the
    /// camera looks along yaw + 90°).
    static func yaw(from: SpatialVector, to: SpatialVector) -> Double {
        let angle = atan2(to.y - from.y, to.x - from.x) * 180 / .pi
        var yaw = (angle - 90).truncatingRemainder(dividingBy: 360); if yaw < 0 { yaw += 360 }
        return yaw
    }

    /// A Boss's entrance: a wide shot of both, then close on the Boss with
    /// its name and phase count, and a charge of light where it stands.
    static func bossIntro(id: String, name: String, phases: Int, boss: SpatialVector, player: SpatialVector) -> CinematicTimeline {
        let yaw = yaw(from: player, to: boss)
        let middle = SpatialVector.lerp(player, boss, 0.5)
        return CinematicTimeline(id: "boss-intro:" + id, shots: [
            CinematicShot(start: 0, duration: 1.2, camera: SpatialCameraState(target: middle + SpatialVector(0, 0, 1), tilt: 32, yaw: yaw, distance: 13)),
            CinematicShot(start: 1.2, duration: 1.4, camera: SpatialCameraState(target: boss + SpatialVector(0, 0, 1.4), tilt: 18, yaw: yaw, distance: 7)),
        ], captions: [
            CinematicCaption(start: 0.3, duration: 2.3, text: String((name + L10n.t(" · \(max(1, phases)) 个阶段", " · \(max(1, phases)) phases")).prefix(120))),
        ], cues: [
            CinematicCue(time: 1.2, preset: .charge, at: boss + SpatialVector(0, 0, 0.8), seconds: 0.8),
        ])
    }
}
