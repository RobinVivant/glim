import AppIntents
import HueKit
import SwiftUI
import UIKit

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
    var pendingGroupID: String?

    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    init() {
        #if DEBUG
        // Development: start unpaired, for exercising setup against the mock bridge.
        if ProcessInfo.processInfo.environment["GLIM_RESET"] != nil { Glim.storage.deleteAll() }
        if let groupID = ProcessInfo.processInfo.environment["GLIM_OPEN_GROUP"], !groupID.isEmpty {
            pendingGroupID = groupID
        }
        #endif
        if let credentials = Glim.storage.loadCredentials() {
            store = makeStore(credentials: credentials)
        }
    }

    private func makeStore(credentials: BridgeCredentials) -> HomeStore {
        HomeStore(
            credentials: credentials,
            storage: Glim.storage,
            onQueueActivity: { [weak self] active in
                Task { @MainActor in self?.updateBackgroundTask(active: active) }
            }
        )
    }

    private func updateBackgroundTask(active: Bool) {
        if active {
            guard backgroundTaskID == .invalid else { return }
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HueCommands") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        } else {
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    func paired(_ credentials: BridgeCredentials) {
        let previousBridgeID = store?.credentials.bridgeID ?? Glim.storage.loadCredentials()?.bridgeID
        store?.stop()
        if let previousBridgeID, previousBridgeID != credentials.bridgeID {
            Glim.storage.deleteSnapshot()
        }
        try? Glim.storage.saveCredentials(credentials)
        let newStore = makeStore(credentials: credentials)
        store = newStore
        newStore.start()
        Glim.reloadWidgets()
    }

    func forgetBridge() {
        store?.stop()
        store = nil
        endBackgroundTask()
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
                SetupView(reason: pairingReason)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                if let store = model.store, !store.needsPairing {
                    store.start()
                }
            case .background:
                model.store?.stop()
                Glim.reloadWidgets()
            default:
                break
            }
        }
        .onOpenURL { url in
            model.pendingGroupID = Glim.groupID(from: url)
        }
    }

    private var pairingReason: String? {
        guard let store = model.store, store.needsPairing else { return nil }
        if case .offline(let message) = store.connection { return message }
        return HueError.unauthorized.localizedDescription
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
