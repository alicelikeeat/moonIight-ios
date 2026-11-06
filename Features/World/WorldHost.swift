import Foundation

/// Owns the one sandbox session for the whole app run. The world is loaded
/// the first time the sandbox appears and then kept: leaving the sandbox
/// pauses and saves it (RPGSession.pause), coming back resumes it
/// (RPGSession.activate) without reading the save again.
@MainActor final class WorldHost {
    static let shared = WorldHost()
    private init() {}

    private(set) lazy var session = RPGSession()

    /// A page to open inside the sandbox on its next appearance, set when a
    /// search command such as 剧情编辑器 routes into the world.
    var pendingPage: RPGEntryPage?
    /// Set by the widget's 3D-world link: open the 3D world once the sandbox is ready.
    var pendingGlassWorld = false
    static let openGlassWorldNotification = Notification.Name("moonlight.openGlassWorld")
    /// The portrait page to return to from 完成 / 继续 elsewhere.
    var returnTab: AppTab = .home

    /// Worlds whose prologue already played during this app run, so coming
    /// back from another page does not replay it. Switching to a different
    /// world (new ID) plays it again.
    private var prologued: Set<String> = []
    func needsPrologue(_ worldID: String) -> Bool { !prologued.contains(worldID) }
    func markPrologue(_ worldID: String) { prologued.insert(worldID) }
}
