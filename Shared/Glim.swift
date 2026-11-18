import HueKit
import SwiftUI
import WidgetKit

/// What the app and its widget extension share.
enum Glim {
    static let appGroup = "group.com.robinvivant.glim"
    static let storage = HueStorage.appGroup(appGroup)
    static let remote = HueRemote(storage: storage)

    /// Asks every widget and control to redraw from the latest state.
    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

extension Color {
    /// The warm white used when a group has no color of its own to show.
    static let glow = Color(red: 1.0, green: 0.78, blue: 0.42)
}
