import AppIntents
import HueKit
import SwiftUI

@main
struct GlimApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.vero)
        }
    }
}

/// Owns the pairing and the live store for the paired bridge.
@MainActor
@Observable
final class AppModel {
    private(set) var store: HomeStore?

    init() {
        #if DEBUG
        // Development: start unpaired, for exercising setup against the mock bridge.
        if ProcessInfo.processInfo.environment["GLIM_RESET"] != nil { Glim.storage.deleteAll() }
        #endif
        if let credentials = Glim.storage.loadCredentials() {
            store = HomeStore(credentials: credentials, storage: Glim.storage)
        }
    }

    func paired(_ credentials: BridgeCredentials) {
        try? Glim.storage.saveCredentials(credentials)
        store = HomeStore(credentials: credentials, storage: Glim.storage)
        store?.start()
    }

    func forgetBridge() {
        store?.stop()
        store = nil
        Glim.storage.deleteAll()
        Glim.reloadWidgets()
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let store = model.store, !store.needsPairing {
                HomeView(store: store)
            } else {
                SetupView()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                model.store?.start()
            case .background:
                model.store?.stop()
                Glim.reloadWidgets()
            default:
                break
            }
        }
    }
}

struct GlimShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AllLightsOffIntent(),
            phrases: ["Turn off all lights with \(.applicationName)", "\(.applicationName) all off"],
            shortTitle: "All Lights Off",
            systemImageName: "lightbulb.slash"
        )
        AppShortcut(
            intent: ToggleRoomIntent(),
            phrases: ["Toggle \(\.$room) with \(.applicationName)"],
            shortTitle: "Toggle Room",
            systemImageName: "lightbulb"
        )
        AppShortcut(
            intent: ActivateSceneIntent(),
            phrases: ["Set \(\.$scene) with \(.applicationName)"],
            shortTitle: "Activate Scene",
            systemImageName: "sparkles"
        )
    }
}
