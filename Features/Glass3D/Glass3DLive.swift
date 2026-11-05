import Foundation
import SwiftUI

/// v1.79: values that change many times a second (frame rate, health,
/// stamina, cooldown rings, hotbar cooldowns, boss bar). They live apart
/// from the controller so a cooldown tick redraws its ring only — before,
/// every tick redrew the whole 3D screen and all of its glass.
@MainActor final class Glass3DLive: ObservableObject {
    @Published var health = 100
    @Published var stamina = 100
    @Published var cooldowns: [Double] = [0, 0, 0]
    @Published var bossBar: (name: String, health: Int, maxHealth: Int, phase: Int)?
    @Published var stats = (visibleCells: 0, blocks: 0, creatures: 0, activeAI: 0, videos: 0, fps: 0.0)
    @Published var hotbarSlots: [Glass3DHotbarSlot] = []
    /// Status text for native glass (refreshed with the stats).
    @Published var glassStatus = ""
}
