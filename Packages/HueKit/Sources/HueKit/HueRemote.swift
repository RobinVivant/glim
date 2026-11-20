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
    /// When `preferCacheWithin` is positive and an extension command ran within that
    /// window, returns the cached optimistic snapshot to avoid reading stale pre-Zigbee state.
    public func currentSnapshot(timeout: TimeInterval = 2.5, preferCacheWithin: TimeInterval = 0) async -> HomeSnapshot {
        if preferCacheWithin > 0, let age = storage.secondsSinceRemoteWrite, age >= 0, age < preferCacheWithin {
            let cached = cachedSnapshot()
            if !cached.isEmpty { return cached }
        }
        guard let resources = try? await performWithRelocation(timeout: timeout, { try await $0.fetchResources() }) else {
            return cachedSnapshot()
        }
        let snapshot = HomeSnapshot(resources: resources)
        storage.saveSnapshot(snapshot)
        return snapshot
    }

    public func isGroupOn(_ groupID: String) async -> Bool {
        let cached = cachedSnapshot()
        guard let group = cached.group(groupID) else { return false }
        if let live = try? await performWithRelocation(timeout: 2, { try await $0.fetchGroupedLight(group.groupedLightID) }) {
            return live.isOn
        }
        return cached.state(of: group).isOn
    }

    public func setGroup(_ groupID: String, on: Bool) async throws {
        var snapshot = cachedSnapshot()
        guard let group = snapshot.group(groupID) else { throw HueError.invalidResponse }
        try await performWithRelocation { client in
            try await client.setGroupedLight(group.groupedLightID, ["on": ["on": .bool(on)]])
        }
        snapshot.setGroupLocally(group, on: on)
        storage.saveSnapshot(snapshot)
        storage.markRemoteWrite()
    }

    /// Flips the group and returns its new state.
    @discardableResult
    public func toggleGroup(_ groupID: String) async throws -> Bool {
        var snapshot = cachedSnapshot()
        guard let group = snapshot.group(groupID) else { throw HueError.invalidResponse }
        let fallbackIsOn = snapshot.state(of: group).isOn
        let target: Bool = try await performWithRelocation { client in
            let current: Bool
            if let live = try? await client.fetchGroupedLight(group.groupedLightID) {
                current = live.isOn
            } else {
                current = fallbackIsOn
            }
            let next = !current
            try await client.setGroupedLight(group.groupedLightID, ["on": ["on": .bool(next)]])
            return next
        }
        snapshot.setGroupLocally(group, on: target)
        storage.saveSnapshot(snapshot)
        storage.markRemoteWrite()
        return target
    }

    public func setGroup(_ groupID: String, brightness: Double) async throws {
        var snapshot = cachedSnapshot()
        guard let group = snapshot.group(groupID) else { throw HueError.invalidResponse }
        let value = min(max(brightness, 1), 100)
        try await performWithRelocation { client in
            try await client.setGroupedLight(
                group.groupedLightID,
                ["on": ["on": true], "dimming": ["brightness": .number(value)], "dynamics": ["duration": 200]])
        }
        snapshot.setGroupLocally(group, brightness: value)
        storage.saveSnapshot(snapshot)
        storage.markRemoteWrite()
    }

    public func setLight(_ lightID: String, on: Bool) async throws {
        var snapshot = cachedSnapshot()
        guard snapshot.lights[lightID] != nil else { throw HueError.invalidResponse }
        try await performWithRelocation { client in
            try await client.put(HueClient.path(.light, lightID), ["on": ["on": .bool(on)]])
        }
        snapshot.setLightLocally(id: lightID, patch: ["on": ["on": .bool(on)]])
        storage.saveSnapshot(snapshot)
        storage.markRemoteWrite()
    }

    public func recallScene(_ sceneID: String) async throws {
        try await performWithRelocation { client in
            try await client.recallScene(sceneID)
        }
        var snapshot = cachedSnapshot()
        snapshot.recallLocally(sceneID: sceneID)
        storage.saveSnapshot(snapshot)
        storage.markRemoteWrite()
    }

    public func setAll(on: Bool) async throws {
        var snapshot = cachedSnapshot()
        guard let home = snapshot.homeGroupedLightID else { throw HueError.invalidResponse }
        try await performWithRelocation { client in
            try await client.setGroupedLight(home, ["on": ["on": .bool(on)]])
        }
        snapshot.setAllLocally(on: on)
        storage.saveSnapshot(snapshot)
        storage.markRemoteWrite()
    }

    private func performWithRelocation<T: Sendable>(
        timeout: TimeInterval = 4, _ work: @Sendable (HueClient) async throws -> T
    ) async throws -> T {
        let current = try client(timeout: timeout)
        do {
            return try await work(current)
        } catch let error as URLError where HueRemote.shouldRelocate(after: error, host: current.credentials.host) {
            guard let newHost = await Discovery.locateLocal(bridgeID: current.credentials.bridgeID),
                newHost != current.credentials.host
            else { throw error }
            var updated = current.credentials
            updated.host = newHost
            try? storage.saveCredentials(updated)
            return try await work(HueClient(credentials: updated, requestTimeout: timeout))
        }
    }

    private static func shouldRelocate(after error: URLError, host: String) -> Bool {
        guard !HueClient.isLoopback(host) else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func client(timeout: TimeInterval = 4) throws -> HueClient {
        guard let credentials = storage.loadCredentials() else { throw HueError.notPaired }
        return HueClient(credentials: credentials, requestTimeout: timeout)
    }
}
