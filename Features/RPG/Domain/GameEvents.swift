import Foundation

/// What the 3D world reports to the save. One typed way in: the session
/// applies every event through `GameEventRules` (pure, tested), so the
/// story's view of the world changes in one place only.
enum GameEvent: Equatable, Sendable {
    /// The player stands here. `inStoryRegion`: the current region is the
    /// one whose grid the story's places are on.
    case playerMoved(SpatialVector, inStoryRegion: Bool)
    /// A 3D creature died (story enemies carry `RPGStorySpatial.creaturePrefix`).
    case creatureDefeated(id: String)
    /// Blocks the player removed from the 3D world.
    case blocksRemoved([String])
}

/// What applying an event did.
struct GameEventOutcome: Equatable, Sendable {
    /// The save changed in a way worth writing now (a position is not).
    var persist = false
    /// The current quest's condition holds after the event.
    var conditionMet = false
}

enum GameEventRules {
    static func apply(_ event: GameEvent, to world: inout WorldState, generator: RPGWorldGenerator) -> GameEventOutcome {
        var outcome = GameEventOutcome()
        switch event {
        case .playerMoved(let position, let inStoryRegion):
            if inStoryRegion { _ = RPGStorySpatial.syncPlayer(position, world: &world) }
        case .creatureDefeated(let id):
            outcome.persist = RPGStorySpatial.defeated(id, world: &world)
        case .blocksRemoved(let ids):
            guard !ids.isEmpty else { break }
            RPGStorySpatial.blocksDestroyed(ids, world: &world)
            outcome.persist = true
        }
        if outcome.persist { RPGStoryRuntime.recordEvents(world: &world) }
        outcome.conditionMet = RPGStorySpatial.conditionMet(world: world, generator: generator)
        return outcome
    }
}
