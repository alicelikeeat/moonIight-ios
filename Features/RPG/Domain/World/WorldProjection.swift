import Foundation

protocol WorldProjection: Sendable {
    var perspective: RPGPerspective { get }
    func visibleEntities(in state: WorldState) -> [WorldEntity]
}
struct TopDownProjection: WorldProjection {
    let perspective = RPGPerspective.topDown
    func visibleEntities(in state: WorldState) -> [WorldEntity] { state.entities.filter { $0.scope != .sideOnly && $0.surface != nil } }
}
struct SideViewProjection: WorldProjection {
    let perspective = RPGPerspective.side
    let regionID: String
    func visibleEntities(in state: WorldState) -> [WorldEntity] { state.entities.filter { $0.scope != .topDownOnly && $0.side?.regionID == regionID } }
}
