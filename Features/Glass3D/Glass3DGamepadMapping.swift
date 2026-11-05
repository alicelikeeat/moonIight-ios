import SwiftUI

// v1.84: Xbox (and other) controller button mapping. Tap an action, press
// a button on the controller; a taken button swaps with the old one.

/// The saved mapping, shared by the 3D world and the mapping page.
@MainActor
final class SpatialPadMappingStore: ObservableObject {
    static let shared = SpatialPadMappingStore()
    @Published var mapping: SpatialPadMapping {
        didSet { if mapping != oldValue { UserDefaults.standard.set(mapping.encoded(), forKey: SpatialPadMapping.storageKey) } }
    }
    /// True while the mapping page is open: the world ignores the pad then,
    /// so pressing buttons to map them does not jump or attack.
    @Published var editing = false
    private init() { mapping = SpatialPadMapping.decode(UserDefaults.standard.data(forKey: SpatialPadMapping.storageKey)) }
}

extension SpatialPadButton {
    /// Xbox names.
    var xboxTitle: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftShoulder: "LB"
        case .rightShoulder: "RB"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .leftStick: L10n.t("左摇杆按下 (LS)", "Left Stick (LS)")
        case .rightStick: L10n.t("右摇杆按下 (RS)", "Right Stick (RS)")
        case .menu: L10n.t("菜单键 ≡", "Menu ≡")
        case .options: L10n.t("视图键 ⧉", "View ⧉")
        case .up: L10n.t("十字键 上", "D-pad Up")
        case .down: L10n.t("十字键 下", "D-pad Down")
        case .left: L10n.t("十字键 左", "D-pad Left")
        case .right: L10n.t("十字键 右", "D-pad Right")
        }
    }
    /// Short label for the round key cap.
    var cap: String {
        switch self {
        case .leftStick: "LS"
        case .rightStick: "RS"
        case .menu: "≡"
        case .options: "⧉"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        default: xboxTitle
        }
    }
    /// Xbox face button colours.
    var capColor: Color {
        switch self {
        case .a: .green
        case .b: .red
        case .x: .blue
        case .y: .yellow
        default: .gray
        }
    }
}

extension SpatialPadAction {
    var title: String {
        switch self {
        case .jump: L10n.t("跳跃 / 复苏", "Jump / Revive")
        case .attack: L10n.t("普通攻击", "Attack")
        case .skill: L10n.t("技能", "Skill")
        case .dodge: L10n.t("翻滚闪避", "Dodge Roll")
        case .lock: L10n.t("锁定目标", "Lock On")
        case .cameraBehind: L10n.t("镜头回到身后", "Camera Behind")
        case .hotbar(let i): L10n.t("技能栏 \(i + 1)", "Skill Slot \(i + 1)")
        case .switchMode: L10n.t("切换游玩 / 设计", "Switch Play / Design")
        case .flyUp: L10n.t("镜头上升", "Camera Up")
        case .flyDown: L10n.t("镜头下降", "Camera Down")
        case .backToCharacter: L10n.t("回到角色", "Back to Character")
        case .straightDown: L10n.t("俯视", "Look Straight Down")
        }
    }
}

/// Round key cap like the printed Xbox buttons.
struct GamepadKeyCap: View {
    let button: SpatialPadButton?
    var lit = false
    var body: some View {
        Text(button?.cap ?? "—")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(button.map { $0.capColor == .gray ? Color.primary : $0.capColor } ?? .secondary)
            .padding(.horizontal, 8)
            .frame(minWidth: 34, minHeight: 34)
            .background(Capsule().fill(lit ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8))
            .scaleEffect(lit ? 1.12 : 1)
            .animation(MoonLiquidMotion.release, value: lit)
            .accessibilityLabel(button?.xboxTitle ?? L10n.t("未设置", "Not set"))
    }
}

/// Settings → Game Controller, and the 3D ⋯ menu.
struct GamepadMappingView: View {
    @ObservedObject private var store = SpatialPadMappingStore.shared
    @StateObject private var pad = Glass3DGamepad()
    @State private var playing = true
    @State private var listening: SpatialPadAction?
    @State private var held: Set<SpatialPadButton> = []
    @State private var message: String?

    private var actions: [SpatialPadAction] { playing ? SpatialPadAction.playActions : SpatialPadAction.designActions }

    var body: some View {
        List {
            Group {
                Section {
                    HStack(spacing: 12) {
                        MoonLiquidIcon(symbol: "gamecontroller.fill", color: pad.connectedName == nil ? .gray : .green, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pad.connectedName ?? L10n.t("未连接手柄", "No controller connected")).font(.headline)
                            Text(pad.connectedName == nil
                                 ? L10n.t("在 iPhone 设置 → 蓝牙 里配对 Xbox 手柄；没有手柄也可以用每行右侧的菜单选键。", "Pair an Xbox controller in Settings → Bluetooth; without one, pick keys from the menu on each row.")
                                 : L10n.t("点一个动作，再按手柄上的键即可绑定。", "Tap an action, then press a button on the controller."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if pad.connectedName != nil { pressTest }
                }
                Section {
                    Picker(L10n.t("模式", "Mode"), selection: $playing) {
                        Text(L10n.t("游玩", "Play")).tag(true)
                        Text(L10n.t("设计", "Design")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("gamepad-mapping-mode")
                    ForEach(actions, id: \.key) { action in row(action) }
                } header: {
                    Text(L10n.t("按键", "Buttons"))
                } footer: {
                    Text(playing ? L10n.t("左摇杆移动，右摇杆转视角。一个键只做一件事：选了已被占用的键，两个动作会互换。", "Left stick moves, right stick looks. One button does one thing: picking a taken button swaps the two actions.")
                                 : L10n.t("设计模式：左摇杆平移，右摇杆转动，LT / RT 缩放（扳机固定用于缩放）。", "Design: left stick pans, right stick turns, LT / RT zoom (the triggers stay on zoom)."))
                }
                if let message {
                    Section { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                }
                Section(L10n.t("摇杆", "Sticks")) {
                    Toggle(L10n.t("左右摇杆互换", "Swap Sticks"), isOn: $store.mapping.swapSticks).accessibilityIdentifier("gamepad-swap-sticks")
                    Toggle(L10n.t("视角上下反转", "Invert Look Up/Down"), isOn: $store.mapping.invertLookY).accessibilityIdentifier("gamepad-invert-look")
                }
                Section {
                    Button(role: .destructive) {
                        withAnimation(MoonLiquidMotion.morph) { store.mapping = .standard; listening = nil; message = L10n.t("已恢复 Xbox 默认布局", "Back to the Xbox default layout") }
                    } label: { Label(L10n.t("恢复默认", "Reset to Default"), systemImage: "arrow.counterclockwise") }
                    .disabled(store.mapping == .standard)
                    .accessibilityIdentifier("gamepad-mapping-reset")
                }
            }
            .listRowBackground(MoonLiquidRowBackground())
        }
        .moonLiquidList()
        .navigationTitle(L10n.t("手柄按键映射", "Controller Mapping"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.editing = true }
        .onDisappear { store.editing = false; listening = nil }
        .onChange(of: playing) { _ in listening = nil; message = nil }
        .task { await poll() }
        .accessibilityIdentifier("gamepad-mapping-screen")
    }

    private func row(_ action: SpatialPadAction) -> some View {
        let button = store.mapping.button(for: action, playing: playing)
        let waiting = listening == action
        return HStack(spacing: 12) {
            Button {
                withAnimation(MoonLiquidMotion.morph) { listening = waiting ? nil : action; message = nil }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.title).foregroundStyle(.primary)
                        if waiting {
                            Text(L10n.t("请按手柄上的键…（再点一次取消）", "Press a button… (tap again to cancel)")).font(.caption).foregroundStyle(Color.accentColor)
                        } else if let button {
                            Text(button.xboxTitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    GamepadKeyCap(button: button, lit: waiting || button.map(held.contains) == true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.moonJelly)
            .accessibilityIdentifier("gamepad-map-\(action.key)")
            Menu {
                ForEach(SpatialPadButton.allCases, id: \.self) { candidate in
                    if playing || !SpatialPadMapping.designReserved.contains(candidate) {
                        Button { assign(candidate, to: action) } label: {
                            if candidate == button { Label(candidate.xboxTitle, systemImage: "checkmark") } else { Text(candidate.xboxTitle) }
                        }
                    }
                }
                Divider()
                Button(role: .destructive) { store.mapping.clear(action, playing: playing) } label: { Label(L10n.t("不使用按键", "No Button"), systemImage: "xmark") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
            }
            .accessibilityLabel(L10n.t("选择按键", "Choose Button"))
            .accessibilityIdentifier("gamepad-map-menu-\(action.key)")
        }
        .listRowBackground(waiting ? AnyView(Color.accentColor.opacity(0.16)) : AnyView(MoonLiquidRowBackground()))
    }

    /// Lights up whatever is held, so the controller can be checked.
    private var pressTest: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("按键测试：按下的键会亮起", "Button test: held buttons light up")).font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SpatialPadButton.allCases, id: \.self) { button in GamepadKeyCap(button: button, lit: held.contains(button)) }
                }
                .padding(.vertical, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gamepad-press-test")
    }

    private func assign(_ button: SpatialPadButton, to action: SpatialPadAction) {
        var mapping = store.mapping
        let displaced = mapping.action(for: button, playing: playing)
        guard mapping.assign(button, to: action, playing: playing) else {
            message = L10n.t("设计模式里 LT / RT 固定用于缩放", "In design mode LT / RT stay on zoom")
            return
        }
        withAnimation(MoonLiquidMotion.morph) {
            store.mapping = mapping
            listening = nil
            if let displaced, displaced != action {
                let moved = mapping.button(for: displaced, playing: playing)
                message = moved.map { L10n.t("「\(displaced.title)」换到了 \($0.xboxTitle)", "\(displaced.title) moved to \($0.xboxTitle)") }
                    ?? L10n.t("「\(displaced.title)」现在没有按键", "\(displaced.title) now has no button")
            } else {
                message = nil
            }
        }
    }

    /// About 30 times a second while the page is open.
    private func poll() async {
        var previous = SpatialPadState()
        while !Task.isCancelled {
            if let state = pad.sample() {
                let now = SpatialGamepad.held(state)
                if now != held { held = now }
                if let action = listening, let first = SpatialPadButton.allCases.first(where: SpatialGamepad.pressed(state, previous: previous).contains) {
                    assign(first, to: action)
                }
                previous = state
            } else if !held.isEmpty {
                held = []
            }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }
}
