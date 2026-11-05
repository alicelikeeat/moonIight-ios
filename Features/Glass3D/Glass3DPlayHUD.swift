import SwiftUI

/// v1.79: the play HUD as its own view. The layout redraws only when the
/// controller's slow state changes (dead / lock target); health, stamina,
/// cooldown rings, hotbar cooldowns and the boss bar each watch `live`,
/// so a cooldown tick redraws one ring, not the screen and its glass.
@available(iOS 18.0, *)
struct Glass3DPlayHUD: View {
    @ObservedObject var controller: Glass3DController
    let portrait: Bool

    var body: some View {
        if portrait { portraitLayout } else { landscapeLayout }
    }

    /// Landscape: move stick left; hotbar, actions and look stick right.
    private var landscapeLayout: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Glass3DVitals(live: controller.live)
                Glass3DStick { x, y in controller.setStick(x, y) }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 10) {
                if controller.dead { reviveButton } else {
                    RPGGlassGroup(spacing: 10) {
                        HStack(alignment: .bottom, spacing: 10) {
                            VStack(spacing: 8) { lockButton; Glass3DHotbar(live: controller.live, controller: controller, vertical: true) }
                            actionCluster
                        }
                    }
                }
                lookStick(size: 112)
            }
        }
    }

    /// Portrait: vitals and hotbar row above; move stick, actions and look
    /// stick along the bottom within thumb reach.
    private var portraitLayout: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                Glass3DVitals(live: controller.live)
                Spacer(minLength: 4)
                if !controller.dead {
                    RPGGlassGroup(spacing: 6) { HStack(spacing: 6) { lockButton; Glass3DHotbar(live: controller.live, controller: controller, vertical: false) } }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Glass3DStick(onVector: { x, y in controller.setStick(x, y) }, size: 112)
                Spacer(minLength: 0)
                if controller.dead { reviveButton } else { RPGGlassGroup(spacing: 8) { actionCluster } }
                lookStick(size: 92)
            }
        }
    }

    private var actionCluster: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(spacing: 8) {
                Glass3DRoundButton(symbol: "sparkles", title: L10n.t("技能", "Skill"), size: 50, ring: .action(1), live: controller.live, id: "glass3d-skill") { controller.attack(.skill) }
                Glass3DRoundButton(symbol: "arrow.triangle.2.circlepath", title: L10n.t("闪避", "Dodge"), size: 46, ring: .action(2), live: controller.live, id: "glass3d-roll") { controller.roll() }
            }
            VStack(spacing: 8) {
                Glass3DRoundButton(symbol: "arrow.up.circle", title: L10n.t("跳跃", "Jump"), size: 50, ring: .none, live: controller.live, id: "glass3d-jump") { controller.jump() }
                Glass3DRoundButton(symbol: "bolt.fill", title: L10n.t("攻击", "Attack"), size: 68, ring: .action(0), live: controller.live, id: "glass3d-attack") { controller.attack(.strike) }
            }
        }
    }
    private var lockButton: some View {
        Glass3DRoundButton(symbol: controller.lockedTarget == nil ? "scope" : "xmark.circle",
                           title: controller.lockedTarget == nil ? L10n.t("锁定", "Lock") : L10n.t("解除锁定", "Unlock"),
                           size: 42, ring: .none, live: controller.live, id: "glass3d-lock") { controller.toggleLock() }
    }
    private func lookStick(size: CGFloat) -> some View {
        Glass3DStick(onVector: { x, y in controller.setLook(x, y) }, size: size, symbol: "eye", label: L10n.t("视角摇杆", "Look Stick"), identifier: "glass3d-look-stick")
    }
    private var reviveButton: some View {
        Button { controller.revive() } label: {
            Label(L10n.t("复苏", "Revive"), systemImage: "heart.fill").font(.headline).foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 14).background(Color.pink.gradient, in: Capsule())
        }
        .buttonStyle(RPGPressStyle()).accessibilityIdentifier("glass3d-revive")
    }
}

/// Which cooldown ring a round button shows.
enum Glass3DRing: Equatable { case none, action(Int), hotbar(Int) }

/// A round glass action button; its cooldown ring watches `live` on its own.
@available(iOS 18.0, *)
struct Glass3DRoundButton: View {
    let symbol: String
    let title: String
    let size: CGFloat
    let ring: Glass3DRing
    let live: Glass3DLive
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: size * 0.32, weight: .bold))
                if size >= 60 { Text(title).font(.system(size: 10, weight: .semibold)) }
            }.frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(RPGPressStyle()).hudGlass(.interactive, in: Circle())
        .overlay { if ring != .none { Glass3DCooldownRing(live: live, ring: ring) } }
        .accessibilityLabel(title).accessibilityIdentifier(id)
    }
}

@available(iOS 18.0, *)
struct Glass3DCooldownRing: View {
    @ObservedObject var live: Glass3DLive
    let ring: Glass3DRing
    var body: some View {
        let value: Double = switch ring {
        case .none: 0
        case .action(let i): i < live.cooldowns.count ? live.cooldowns[i] : 0
        case .hotbar(let i): live.hotbarSlots.first { $0.index == i }?.cooldown ?? 0
        }
        Circle().trim(from: 0, to: value).stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90)).padding(2).allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Hotbar skills: the list redraws when slots change, rings on their own.
@available(iOS 18.0, *)
struct Glass3DHotbar: View {
    @ObservedObject var live: Glass3DLive
    let controller: Glass3DController
    let vertical: Bool
    var body: some View {
        ForEach(live.hotbarSlots, id: \.index) { slot in
            Glass3DRoundButton(symbol: slot.symbol, title: slot.name, size: 42, ring: .hotbar(slot.index), live: live, id: "glass3d-hotbar-\(slot.index)") { controller.castHotbar(slot.index) }
        }
    }
}

/// Health and stamina on light glass.
@available(iOS 18.0, *)
struct Glass3DVitals: View {
    @ObservedObject var live: Glass3DLive
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bar(live.health, .red, "heart.fill")
            bar(live.stamina, .green, "bolt.fill")
        }
        .padding(.horizontal, 10).padding(.vertical, 8).hudGlass(.light, radius: 14)
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.t("生命 \(live.health)，耐力 \(live.stamina)", "Health \(live.health), stamina \(live.stamina)"))
        .accessibilityIdentifier("glass3d-vitals")
    }
    private func bar(_ value: Int, _ tint: Color, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            ZStack(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.15)); Capsule().fill(tint.gradient).frame(width: CGFloat(max(0, min(100, value))) * 0.96) }.frame(width: 96, height: 6)
        }
    }
}

/// Boss name, phase and health.
@available(iOS 18.0, *)
struct Glass3DBossBar: View {
    @ObservedObject var live: Glass3DLive
    var body: some View {
        if let boss = live.bossBar {
            VStack(spacing: 3) {
                Text(boss.name + (boss.phase > 1 ? L10n.t(" · 第 \(boss.phase) 阶段", " · Phase \(boss.phase)") : "")).font(.caption.weight(.semibold))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(Color.red.gradient).frame(width: 240 * CGFloat(boss.health) / CGFloat(max(1, boss.maxHealth)))
                }.frame(width: 240, height: 8)
            }
            .padding(.horizontal, 14).padding(.vertical, 6).hudGlass(.light, radius: 12)
            .accessibilityElement(children: .ignore).accessibilityLabel(boss.name + " \(boss.health)/\(boss.maxHealth)").accessibilityIdentifier("glass3d-boss-bar")
        }
    }
}

/// Blocks, native glass state, active AI and frame rate — plain text with
/// a shadow, no glass (one glass surface less over the moving 3D view).
@available(iOS 18.0, *)
struct Glass3DStatsLine: View {
    @ObservedObject var live: Glass3DLive
    var body: some View {
        let fps = Int(live.stats.fps)
        HStack(spacing: 10) {
            Label("\(live.stats.blocks)", systemImage: "cube")
            Label(live.glassStatus, systemImage: "sparkles")
            Label("\(live.stats.activeAI)", systemImage: "brain")
            HStack(spacing: 3) {
                Circle().fill(fps >= 50 ? Color.green : fps >= 30 ? Color.orange : Color.red).frame(width: 6, height: 6)
                Text("\(fps) FPS")
            }
        }
        .labelStyle(Glass3DCompactLabel())
        .font(.caption2.monospacedDigit()).foregroundStyle(.white).lineLimit(1)
        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.black.opacity(0.18), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("方块 \(live.stats.blocks) · \(live.glassStatus) · AI \(live.stats.activeAI) · \(fps) FPS",
                                   "\(live.stats.blocks) blocks · \(live.glassStatus) · AI \(live.stats.activeAI) · \(fps) FPS"))
        .accessibilityIdentifier("glass3d-stats")
    }
}
