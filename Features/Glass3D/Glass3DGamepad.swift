import GameController
import Combine

/// Reads the connected game controller (Xbox, PlayStation, MFi) once per
/// frame. Mapping lives in `SpatialGamepad`; this only samples the pad.
@MainActor
final class Glass3DGamepad: ObservableObject {
    /// Name shown in the HUD, nil when no controller is connected.
    @Published private(set) var connectedName: String?
    private(set) var previous = SpatialPadState()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect, .GCControllerDidBecomeCurrent, .GCControllerDidStopBeingCurrent] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshName() }
            })
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        refreshName()
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    private var pad: GCExtendedGamepad? {
        GCController.current?.extendedGamepad ?? GCController.controllers().lazy.compactMap(\.extendedGamepad).first
    }
    private func refreshName() {
        let controller = GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil }
        let name = controller.map { $0.vendorName ?? "Gamepad" }
        if name != connectedName { connectedName = name }
        if controller == nil { previous = SpatialPadState() }
    }

    /// The current state, or nil without a controller.
    func sample() -> SpatialPadState? {
        guard let pad else { return nil }
        var state = SpatialPadState()
        state.leftX = Double(pad.leftThumbstick.xAxis.value); state.leftY = Double(pad.leftThumbstick.yAxis.value)
        state.rightX = Double(pad.rightThumbstick.xAxis.value); state.rightY = Double(pad.rightThumbstick.yAxis.value)
        state.leftTrigger = Double(pad.leftTrigger.value); state.rightTrigger = Double(pad.rightTrigger.value)
        let buttons: [(GCControllerButtonInput?, SpatialPadButton)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftThumbstickButton, .leftStick), (pad.rightThumbstickButton, .rightStick),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options),
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right),
        ]
        for (input, button) in buttons where input?.isPressed == true { state.buttons.insert(button) }
        return state
    }
    func remember(_ state: SpatialPadState) { previous = state }
}
