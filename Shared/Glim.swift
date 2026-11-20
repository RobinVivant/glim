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

    static func groupURL(_ id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "glim"
        components.host = "group"
        components.path = "/\(id)"
        return components.url
    }

    static func groupID(from url: URL) -> String? {
        guard url.scheme == "glim", url.host == "group" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

extension LightScene {
    var swatch: AnyShapeStyle {
        let colors = swatches.map(\.color)
        switch colors.count {
        case 0: return AnyShapeStyle(Color.glow)
        case 1: return AnyShapeStyle(colors[0])
        default: return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center))
        }
    }
}

extension Color {
    /// The warm white used when a group has no color of its own to show.
    static let glow = Color(red: 1.0, green: 0.78, blue: 0.42)
    /// Vero's brand teal, #00CCCC. Filled controls in it take black text.
    static let vero = Color(red: 0, green: 0.8, blue: 0.8)
}
