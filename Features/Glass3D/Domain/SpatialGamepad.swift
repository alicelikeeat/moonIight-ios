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
enum SpatialPadButton: String, CaseIterable, Sendable {
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
    static func move(_ pad: SpatialPadState) -> (x: Double, y: Double) {
        let v = shaped(pad.leftX, pad.leftY); return (v.x, -v.y)
    }
    static func look(_ pad: SpatialPadState) -> (x: Double, y: Double) {
        let v = shaped(pad.rightX, pad.rightY); return (v.x, -v.y)
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
    static func actions(_ pad: SpatialPadState, previous: SpatialPadState, playing: Bool) -> [SpatialPadAction] {
        let down = pressed(pad, previous: previous)
        return SpatialPadButton.allCases.filter(down.contains).compactMap { action(for: $0, playing: playing) }
    }

    /// Design mode zoom from the triggers: >1 zooms in, <1 out, 1 none.
    static func zoomFactor(_ pad: SpatialPadState, dt: Double) -> Double {
        let amount = pad.rightTrigger - pad.leftTrigger
        guard abs(amount) > 0.05, dt > 0, dt.isFinite else { return 1 }
        return exp(amount * 1.5 * dt)
    }
}
