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

    @ObservedObject private var pads = SpatialPadMappingStore.shared

    /// Landscape: vitals and move stick left; shoulder row, face diamond and
    /// look stick right, placed like an Xbox controller's right half.
    private var landscapeLayout: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Glass3DVitals(live: controller.live)
                Glass3DStick { x, y in controller.setStick(x, y) }
            }
            Spacer()
            if controller.dead { reviveButton } else {
                VStack(alignment: .trailing, spacing: 10) {
                    shoulderRow(size: 44)
                    rightHalf(face: 56, stick: 104)
                }
            }
        }
    }

    /// Portrait: vitals left and the shoulder row right above; the move
    /// stick, look stick and face diamond along the bottom.
    private var portraitLayout: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                Glass3DVitals(live: controller.live)
                Spacer(minLength: 4)
                if !controller.dead { shoulderRow(size: 42) }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Glass3DStick(onVector: { x, y in controller.setStick(x, y) }, size: 108)
                Spacer(minLength: 0)
                if controller.dead { reviveButton } else { rightHalf(face: 52, stick: 88) }
            }
        }
    }

    /// LT LB | RB RT: the four skill slots in the order the shoulders are held.
    private func shoulderRow(size: CGFloat) -> some View {
        let slots = SpatialPadHUDLayout.actions(SpatialPadHUDLayout.shoulders, mapping: pads.mapping)
        return RPGGlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                    if index == 2 { Spacer().frame(width: 6) }
                    padButton(slot.button, slot.action, size: size)
                }
            }
        }
    }

    /// Face diamond (Y top, X left, B right, A bottom) with the look stick
    /// below and to its left, and lock-on (RS) above the stick — where the
    /// right stick and its click are on the controller.
    private func rightHalf(face size: CGFloat, stick: CGFloat) -> some View {
        let side = CGFloat(SpatialPadHUDLayout.diamondSide(size: Double(size)))
        let face = SpatialPadHUDLayout.actions(SpatialPadHUDLayout.face, mapping: pads.mapping)
        let click = SpatialPadHUDLayout.stickClick
        return HStack(alignment: .bottom, spacing: 6) {
            VStack(spacing: 8) {
                padButton(click, pads.mapping.action(for: click, playing: true), size: 42)
                lookStick(size: stick)
            }
            RPGGlassGroup(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(face.enumerated()), id: \.offset) { _, slot in
                        if let c = SpatialPadHUDLayout.faceCenter(slot.button, size: Double(size)) {
                            padButton(slot.button, slot.action, size: size)
                                .position(x: CGFloat(c.x), y: CGFloat(c.y))
                        }
                    }
                }
                .frame(width: side, height: side)
            }
            .padding(.bottom, stick * 0.45)
        }
    }

    private func padButton(_ button: SpatialPadButton, _ action: SpatialPadAction?, size: CGFloat) -> some View {
        Glass3DPadButton(controller: controller, live: controller.live, button: button, action: action, size: size)
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

/// One controller button on the HUD: the action the mapping puts on it,
/// with its Xbox cap. Watches `live` itself, so skill-slot changes redraw
/// only these buttons.
@available(iOS 18.0, *)
struct Glass3DPadButton: View {
    @ObservedObject var controller: Glass3DController
    @ObservedObject var live: Glass3DLive
    let button: SpatialPadButton
    let action: SpatialPadAction?
    let size: CGFloat

    var body: some View {
        let look = action.map(visual) ?? PadVisual(symbol: "circle.dotted", title: L10n.t("未设置", "Not set"), id: "glass3d-pad-\(button.cap)", ring: .none, enabled: false)
        Glass3DRoundButton(symbol: look.symbol, title: look.title, size: size, ring: look.ring, live: live, id: look.id, cap: button) {
            if let action { controller.perform(action) }
        }
        .disabled(!look.enabled)
        .opacity(look.enabled ? 1 : 0.45)
    }

    private struct PadVisual { var symbol: String, title: String, id: String, ring: Glass3DRing, enabled = true }

    private func visual(_ action: SpatialPadAction) -> PadVisual {
        switch action {
        case .jump: PadVisual(symbol: "arrow.up.circle", title: L10n.t("跳跃", "Jump"), id: "glass3d-jump", ring: .none)
        case .attack: PadVisual(symbol: "bolt.fill", title: L10n.t("攻击", "Attack"), id: "glass3d-attack", ring: .action(0))
        case .skill: PadVisual(symbol: "sparkles", title: L10n.t("技能", "Skill"), id: "glass3d-skill", ring: .action(1))
        case .dodge: PadVisual(symbol: "arrow.triangle.2.circlepath", title: L10n.t("闪避", "Dodge"), id: "glass3d-roll", ring: .action(2))
        case .lock:
            PadVisual(symbol: controller.lockedTarget == nil ? "scope" : "xmark.circle",
                      title: controller.lockedTarget == nil ? L10n.t("锁定", "Lock") : L10n.t("解除锁定", "Unlock"), id: "glass3d-lock", ring: .none)
        case .cameraBehind: PadVisual(symbol: "camera.rotate", title: L10n.t("镜头回到身后", "Camera Behind"), id: "glass3d-camera-behind", ring: .none)
        case .hotbar(let i):
            if let slot = live.hotbarSlots.first(where: { $0.index == i }) {
                PadVisual(symbol: slot.symbol, title: slot.name, id: "glass3d-hotbar-\(i)", ring: .hotbar(i))
            } else {
                PadVisual(symbol: "circle.dotted", title: L10n.t("空技能栏", "Empty Slot"), id: "glass3d-hotbar-\(i)", ring: .none, enabled: false)
            }
        case .switchMode: PadVisual(symbol: "hammer", title: L10n.t("切换游玩 / 设计", "Play / Design"), id: "glass3d-pad-switch", ring: .none)
        case .switchPerspective: PadVisual(symbol: "square.grid.3x3.fill", title: L10n.t("切换像素 / 3D", "Pixel / 3D"), id: "glass3d-pad-perspective", ring: .none)
        case .flyUp, .flyDown, .backToCharacter, .straightDown:
            PadVisual(symbol: "circle.dotted", title: action.title, id: "glass3d-pad-\(action.key)", ring: .none, enabled: false)
        }
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
    /// The controller button this stands for, drawn as a small Xbox cap.
    var cap: SpatialPadButton? = nil
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
        .overlay(alignment: .bottomTrailing) { if let cap { Glass3DCapBadge(button: cap) } }
        .accessibilityLabel(cap.map { title + " · " + $0.xboxTitle } ?? title).accessibilityIdentifier(id)
    }
}

/// The Xbox letter on a HUD button: coloured A/B/X/Y, grey LB/RB/LT/RT/RS.
struct Glass3DCapBadge: View {
    let button: SpatialPadButton
    var body: some View {
        let face = button.capColor != .gray
        Text(button.cap)
            .font(.system(size: face ? 9 : 7.5, weight: .heavy, design: .rounded))
            .foregroundStyle(face ? Color.white : Color.primary)
            .padding(.horizontal, face ? 0 : 3)
            .frame(minWidth: 15, minHeight: 15)
            .background(Capsule().fill(face ? button.capColor.opacity(0.9) : Color.primary.opacity(0.12)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.6))
            .offset(x: 2, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        // FPS in steps of 5 for VoiceOver: the label does not churn every refresh.
        .accessibilityLabel(L10n.t("方块 \(live.stats.blocks) · \(live.glassStatus) · AI \(live.stats.activeAI) · 约 \(fps / 5 * 5) FPS",
                                   "\(live.stats.blocks) blocks · \(live.glassStatus) · AI \(live.stats.activeAI) · about \(fps / 5 * 5) FPS"))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("glass3d-stats")
    }
}
