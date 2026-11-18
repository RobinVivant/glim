import Foundation

/// One-shot control of the home for widgets, controls and shortcuts, which run
/// without the app's live store. Each call talks to the bridge directly and
/// keeps the shared cached snapshot in step.
public struct HueRemote: Sendable {
    public let storage: HueStorage

    public init(storage: HueStorage) {
        self.storage = storage
    }

    public var isPaired: Bool { storage.loadCredentials() != nil }

    /// The last known state, without touching the network.
    public func cachedSnapshot() -> HomeSnapshot {
        storage.loadSnapshot() ?? HomeSnapshot()
    }

    /// The bridge's current state, or the cached one when it does not answer in time.
    public func currentSnapshot(timeout: TimeInterval = 2.5) async -> HomeSnapshot {
        guard let client = try? client(timeout: timeout), let resources = try? await client.fetchResources() else {
            return cachedSnapshot()
        }
        let snapshot = HomeSnapshot(resources: resources)
        storage.saveSnapshot(snapshot)
        return snapshot
    }

    public func isGroupOn(_ groupID: String) async -> Bool {
        let cached = cachedSnapshot()
        guard let group = cached.group(groupID) else { return false }
        if let live = try? await client(timeout: 2).fetchGroupedLight(group.groupedLightID) { return live.isOn }
        return cached.state(of: group).isOn
    }

    public func setGroup(_ groupID: String, on: Bool) async throws {
        var snapshot = cachedSnapshot()
        guard let group = snapshot.group(groupID) else { throw HueError.invalidResponse }
        try await client().setGroupedLight(group.groupedLightID, ["on": ["on": .bool(on)]])
        snapshot.setGroupLocally(group, on: on)
        storage.saveSnapshot(snapshot)
    }

    /// Flips the group and returns its new state.
    @discardableResult
    public func toggleGroup(_ groupID: String) async throws -> Bool {
        let target = !(await isGroupOn(groupID))
        try await setGroup(groupID, on: target)
        return target
    }

    public func setGroup(_ groupID: String, brightness: Double) async throws {
        var snapshot = cachedSnapshot()
        guard let group = snapshot.group(groupID) else { throw HueError.invalidResponse }
        let value = min(max(brightness, 1), 100)
        try await client().setGroupedLight(
            group.groupedLightID, ["on": ["on": true], "dimming": ["brightness": .number(value)]])
        snapshot.setGroupLocally(group, brightness: value)
        storage.saveSnapshot(snapshot)
    }

    public func recallScene(_ sceneID: String) async throws {
        try await client().recallScene(sceneID)
        var snapshot = cachedSnapshot()
        snapshot.recallLocally(sceneID: sceneID)
        storage.saveSnapshot(snapshot)
    }

    public func setAll(on: Bool) async throws {
        var snapshot = cachedSnapshot()
        guard let home = snapshot.homeGroupedLightID else { throw HueError.invalidResponse }
        try await client().setGroupedLight(home, ["on": ["on": .bool(on)]])
        snapshot.setAllLocally(on: on)
        storage.saveSnapshot(snapshot)
    }

    private func client(timeout: TimeInterval = 4) throws -> HueClient {
        guard let credentials = storage.loadCredentials() else { throw HueError.notPaired }
        return HueClient(credentials: credentials, requestTimeout: timeout)
    }
}
