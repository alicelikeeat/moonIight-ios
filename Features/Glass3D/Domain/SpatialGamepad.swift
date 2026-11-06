import Foundation

/// Game controller (Xbox, PlayStation, MFi) input for the 3D world, kept
/// free of the GameController framework so it can be tested anywhere.
/// The app reads the pad once per frame into a `SpatialPadState`; this file
/// turns that into stick vectors and one-shot button presses.
struct SpatialPadState: Equatable, Sendable {
    /// Sticks as the controller reports them: x right, y up, −1…1.
    var leftX = 0.0, leftY = 0.0
    var rightX = 0.0, rightY = 0.0
    /// Triggers 0…1.
    var leftTrigger = 0.0, rightTrigger = 0.0
    var buttons: Set<SpatialPadButton> = []
}

/// Xbox names (A bottom, B right, X left, Y top).
enum SpatialPadButton: String, CaseIterable, Codable, Sendable {
    case a, b, x, y
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftStick, rightStick
    case menu, options
    case up, down, left, right
}

/// What a press does. Play and design use the same buttons differently.
enum SpatialPadAction: Equatable, Sendable {
    case jump, attack, skill, dodge
    case lock, cameraBehind
    case hotbar(Int)
    case switchMode
    case flyUp, flyDown, backToCharacter, straightDown
}

enum SpatialGamepad {
    static let deadZone = 0.18
    /// Triggers count as pressed past this.
    static let triggerPress = 0.5

    /// Removes stick drift, then rescales so the edge of the dead zone is 0.
    static func shaped(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return (0, 0) }
        let length = (x * x + y * y).squareRoot()
        guard length > deadZone else { return (0, 0) }
        let clamped = min(1, length)
        let scale = (clamped - deadZone) / (1 - deadZone) / length
        return (x * scale, y * scale)
    }

    /// Stick vectors in on-screen joystick convention (y down), which is
    /// what `setStick` / `setLook` expect.
    /// v1.84: the mapping can swap the sticks and invert looking up/down.
    static func move(_ pad: SpatialPadState, mapping: SpatialPadMapping = .standard) -> (x: Double, y: Double) {
        let v = mapping.swapSticks ? shaped(pad.rightX, pad.rightY) : shaped(pad.leftX, pad.leftY); return (v.x, -v.y)
    }
    static func look(_ pad: SpatialPadState, mapping: SpatialPadMapping = .standard) -> (x: Double, y: Double) {
        let v = mapping.swapSticks ? shaped(pad.leftX, pad.leftY) : shaped(pad.rightX, pad.rightY)
        return (v.x, mapping.invertLookY ? v.y : -v.y)
    }

    /// Buttons that went down since the previous frame (triggers included).
    static func pressed(_ pad: SpatialPadState, previous: SpatialPadState) -> Set<SpatialPadButton> {
        held(pad).subtracting(held(previous))
    }
    static func held(_ pad: SpatialPadState) -> Set<SpatialPadButton> {
        var set = pad.buttons
        if pad.leftTrigger >= triggerPress { set.insert(.leftTrigger) }
        if pad.rightTrigger >= triggerPress { set.insert(.rightTrigger) }
        return set
    }

    /// Xbox layout. Play: A jump, X attack, Y skill, B dodge, LB/RB/LT/RT
    /// skill slots 1–4, right stick click lock-on, left stick click camera
    /// behind. Design: A back to character, Y straight down, LB/RB fly
    /// down/up. Menu switches play/design in both.
    static func action(for button: SpatialPadButton, playing: Bool, mapping: SpatialPadMapping) -> SpatialPadAction? {
        mapping.action(for: button, playing: playing)
    }

    /// The standard layout (also what `SpatialPadMapping.standard` holds).
    static func action(for button: SpatialPadButton, playing: Bool) -> SpatialPadAction? {
        if button == .menu { return .switchMode }
        if playing {
            switch button {
            case .a: return .jump
            case .x: return .attack
            case .y: return .skill
            case .b: return .dodge
            case .rightStick: return .lock
            case .leftStick: return .cameraBehind
            case .leftShoulder: return .hotbar(0)
            case .rightShoulder: return .hotbar(1)
            case .leftTrigger: return .hotbar(2)
            case .rightTrigger: return .hotbar(3)
            default: return nil
            }
        }
        switch button {
        case .a: return .backToCharacter
        case .y: return .straightDown
        case .leftShoulder: return .flyDown
        case .rightShoulder: return .flyUp
        default: return nil
        }
    }

    /// Actions for this frame, in a stable order.
    static func actions(_ pad: SpatialPadState, previous: SpatialPadState, playing: Bool, mapping: SpatialPadMapping = .standard) -> [SpatialPadAction] {
        let down = pressed(pad, previous: previous)
        return SpatialPadButton.allCases.filter(down.contains).compactMap { mapping.action(for: $0, playing: playing) }
    }

    /// Design mode zoom from the triggers: >1 zooms in, <1 out, 1 none.
    static func zoomFactor(_ pad: SpatialPadState, dt: Double) -> Double {
        let amount = pad.rightTrigger - pad.leftTrigger
        guard abs(amount) > 0.05, dt > 0, dt.isFinite else { return 1 }
        return exp(amount * 1.5 * dt)
    }
}

// MARK: v1.84 button mapping

extension SpatialPadAction {
    /// Stable name for saving.
    var key: String {
        switch self {
        case .jump: return "jump"
        case .attack: return "attack"
        case .skill: return "skill"
        case .dodge: return "dodge"
        case .lock: return "lock"
        case .cameraBehind: return "cameraBehind"
        case .hotbar(let i): return "hotbar\(i)"
        case .switchMode: return "switchMode"
        case .flyUp: return "flyUp"
        case .flyDown: return "flyDown"
        case .backToCharacter: return "backToCharacter"
        case .straightDown: return "straightDown"
        }
    }
    init?(key: String) {
        guard let action = (Self.playActions + Self.designActions).first(where: { $0.key == key }) else { return nil }
        self = action
    }
    /// Actions that can be put on a button while playing / designing.
    static let playActions: [SpatialPadAction] = [.jump, .attack, .skill, .dodge, .lock, .cameraBehind, .hotbar(0), .hotbar(1), .hotbar(2), .hotbar(3), .switchMode]
    static let designActions: [SpatialPadAction] = [.backToCharacter, .straightDown, .flyUp, .flyDown, .switchMode]
}

/// Which button does what, per mode, plus stick options. One button does
/// one thing per mode; assigning a taken button swaps the two actions.
/// Saved as JSON; anything unknown or duplicated is dropped on load.
struct SpatialPadMapping: Codable, Equatable, Sendable {
    /// Action key → button.
    var play: [String: SpatialPadButton]
    var design: [String: SpatialPadButton]
    /// Left stick looks, right stick moves.
    var swapSticks = false
    /// Pushing the look stick up looks down.
    var invertLookY = false

    static let standard: SpatialPadMapping = {
        func table(_ actions: [SpatialPadAction], playing: Bool) -> [String: SpatialPadButton] {
            var result: [String: SpatialPadButton] = [:]
            for button in SpatialPadButton.allCases {
                if let action = SpatialGamepad.action(for: button, playing: playing), actions.contains(action) { result[action.key] = button }
            }
            return result
        }
        return SpatialPadMapping(play: table(SpatialPadAction.playActions, playing: true), design: table(SpatialPadAction.designActions, playing: false))
    }()

    /// Buttons kept for design-mode zoom (the triggers) — not assignable there.
    static let designReserved: Set<SpatialPadButton> = [.leftTrigger, .rightTrigger]

    func button(for action: SpatialPadAction, playing: Bool) -> SpatialPadButton? {
        (playing ? play : design)[action.key]
    }
    func action(for button: SpatialPadButton, playing: Bool) -> SpatialPadAction? {
        guard let key = (playing ? play : design).first(where: { $0.value == button })?.key else { return nil }
        return SpatialPadAction(key: key)
    }

    /// Puts `action` on `button`; whatever had that button moves to the
    /// action's old button (or is left unassigned when it had none).
    /// Returns false for a button reserved in that mode.
    @discardableResult
    mutating func assign(_ button: SpatialPadButton, to action: SpatialPadAction, playing: Bool) -> Bool {
        if !playing && Self.designReserved.contains(button) { return false }
        var table = playing ? play : design
        let old = table[action.key]
        if let other = table.first(where: { $0.value == button && $0.key != action.key })?.key { table[other] = old }
        table[action.key] = button
        if playing { play = table } else { design = table }
        return true
    }
    mutating func clear(_ action: SpatialPadAction, playing: Bool) {
        if playing { play[action.key] = nil } else { design[action.key] = nil }
    }

    /// Drops unknown actions, reserved buttons and duplicate buttons.
    func normalized() -> SpatialPadMapping {
        func clean(_ table: [String: SpatialPadButton], allowed: [SpatialPadAction], reserved: Set<SpatialPadButton>) -> [String: SpatialPadButton] {
            var used = Set<SpatialPadButton>(), result: [String: SpatialPadButton] = [:]
            for action in allowed {
                guard let button = table[action.key], !reserved.contains(button), !used.contains(button) else { continue }
                used.insert(button); result[action.key] = button
            }
            return result
        }
        var copy = self
        copy.play = clean(play, allowed: SpatialPadAction.playActions, reserved: [])
        copy.design = clean(design, allowed: SpatialPadAction.designActions, reserved: Self.designReserved)
        return copy
    }

    static let storageKey = "moonlight.gamepad.mapping"
    static func decode(_ data: Data?) -> SpatialPadMapping {
        guard let data, let value = try? JSONDecoder().decode(SpatialPadMapping.self, from: data) else { return .standard }
        return value.normalized()
    }
    func encoded() -> Data? { try? JSONEncoder().encode(normalized()) }
}

/// The touch HUD drawn as an Xbox controller: each spot is a physical
/// button, showing whatever action the saved mapping puts on it, so the
/// screen and the controller never disagree after a remap.
enum SpatialPadHUDLayout {
    /// Face buttons by position: top, left, right, bottom.
    static let face: [SpatialPadButton] = [.y, .x, .b, .a]
    /// Shoulder row, left to right as held: LT LB | RB RT.
    static let shoulders: [SpatialPadButton] = [.leftTrigger, .leftShoulder, .rightShoulder, .rightTrigger]
    /// Pressing the right stick (lock-on) sits by the look stick.
    static let stickClick: SpatialPadButton = .rightStick

    /// Centre of a face button in a diamond of `size`-wide buttons, origin top-left.
    static func faceCenter(_ button: SpatialPadButton, size: Double) -> (x: Double, y: Double)? {
        let pitch = size * 0.92
        let mid = pitch + size / 2
        switch button {
        case .y: return (mid, size / 2)
        case .x: return (size / 2, mid)
        case .b: return (mid + pitch, mid)
        case .a: return (mid, mid + pitch)
        default: return nil
        }
    }
    /// Width and height of the diamond.
    static func diamondSide(size: Double) -> Double { size * 0.92 * 2 + size }

    static func actions(_ buttons: [SpatialPadButton], mapping: SpatialPadMapping) -> [(button: SpatialPadButton, action: SpatialPadAction?)] {
        buttons.map { ($0, mapping.action(for: $0, playing: true)) }
    }
}
