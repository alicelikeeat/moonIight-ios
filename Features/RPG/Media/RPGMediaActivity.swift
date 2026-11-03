import SwiftUI

private struct MoonlightMediaSuspensionKey: EnvironmentKey { static let defaultValue=false }
extension EnvironmentValues {
    var moonlightMediaSuspended:Bool {
        get{self[MoonlightMediaSuspensionKey.self]}
        set{self[MoonlightMediaSuspensionKey.self]=newValue}
    }
}
