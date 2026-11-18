import Foundation
import Testing

@testable import HueKit

/// End-to-end checks over real HTTPS against scripts/mock-bridge.py.
/// Run: scripts/mock-bridge.py 8443 &  then  HUE_MOCK_HOST=127.0.0.1:8443 swift test
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HUE_MOCK_HOST"] != nil), .serialized)
struct MockBridgeTests {
    let host = ProcessInfo.processInfo.environment["HUE_MOCK_HOST"] ?? ""

    /// Pairs like the app does: probe, then ask until the bridge stops refusing.
    func pairedStorage() async throws -> HueStorage {
        let bridge = try await Pairing.probe(host: host)
        var credentials: BridgeCredentials?
        for _ in 0..<5 where credentials == nil {
            do {
                credentials = try await Pairing.pair(with: bridge, deviceName: "Test Mac")
            } catch HueError.linkButtonNotPressed {
                continue
            }
        }
        let storage = HueStorage(
            directory: FileManager.default.temporaryDirectory.appending(path: "glim-mock-\(UUID().uuidString)"))
        try storage.saveCredentials(try #require(credentials))
        return storage
    }

    @Test func remoteControlsRoomsScenesAndEverything() async throws {
        let storage = try await pairedStorage()
        defer { storage.deleteAll() }
        let remote = HueRemote(storage: storage)
        #expect(remote.isPaired)

        let snapshot = await remote.currentSnapshot()
        let kitchen = try #require(snapshot.groups.first { $0.name == "Kitchen" })
        let living = try #require(snapshot.groups.first { $0.name == "Living room" })
        #expect(remote.cachedSnapshot().groups.count == snapshot.groups.count)

        try await remote.setGroup(kitchen.id, on: true)
        #expect(await remote.isGroupOn(kitchen.id))
        #expect(try await remote.toggleGroup(kitchen.id) == false)
        #expect(await remote.isGroupOn(kitchen.id) == false)

        try await remote.setGroup(kitchen.id, brightness: 40)
        #expect(remote.cachedSnapshot().state(of: kitchen).brightness == 40)
        #expect(await remote.currentSnapshot().state(of: kitchen).brightness == 40)

        let movie = try #require(snapshot.scenes(in: living).first { $0.name == "Movie" })
        try await remote.recallScene(movie.id)
        let afterScene = await remote.currentSnapshot()
        #expect(afterScene.scenes[movie.id]?.isActive == true)
        #expect(afterScene.state(of: living).brightness == 25)

        try await remote.setAll(on: false)
        #expect(await remote.currentSnapshot().anyLightOn == false)
    }

    @Test @MainActor func storeFollowsTheBridgeAndSendsItsCommands() async throws {
        let storage = try await pairedStorage()
        defer { storage.deleteAll() }
        let credentials = try #require(storage.loadCredentials())
        let client = HueClient(credentials: credentials)
        let store = HomeStore(credentials: credentials, storage: storage)
        store.start()
        defer { store.stop() }
        try await waitUntil("store goes live") { store.connection == .live }
        let office = try #require(store.snapshot.groups.first { $0.name == "Office" })

        // A change made by someone else arrives through the event stream.
        try await client.setGroupedLight(office.groupedLightID, ["on": ["on": false]])
        try await waitUntil("store sees the room go off") { !store.snapshot.state(of: office).isOn }
        try await client.setGroupedLight(office.groupedLightID, ["on": ["on": true]])
        try await waitUntil("store sees the room come on") { store.snapshot.state(of: office).isOn }

        // The store's own command shows at once and reaches the bridge.
        store.setGroup(office, brightness: 30)
        #expect(store.snapshot.state(of: office).brightness == 30)
        try await waitUntil("bridge has the brightness") {
            (try? await client.fetchGroupedLight(office.groupedLightID))?.brightness == 30
        }

        // Later bridge events do not undo it once the hold on the room lifts.
        try await Task.sleep(for: .milliseconds(1500))
        #expect(store.snapshot.state(of: office).brightness == 30)
        #expect(store.connection == .live)
    }

    @Test func refusesABridgeWhoseCertificateChanged() async throws {
        let storage = try await pairedStorage()
        defer { storage.deleteAll() }
        var credentials = try #require(storage.loadCredentials())
        #expect(try await HueClient(credentials: credentials).fetchResources().isEmpty == false)

        credentials.certificatePin = "c29tZW9uZSBlbHNl"
        await #expect(throws: (any Error).self) {
            try await HueClient(credentials: credentials).fetchResources()
        }
    }

    @Test func refusesAWrongApplicationKey() async throws {
        let storage = try await pairedStorage()
        defer { storage.deleteAll() }
        var credentials = try #require(storage.loadCredentials())
        credentials.applicationKey = "not-the-key"
        await #expect(throws: HueError.unauthorized) {
            try await HueClient(credentials: credentials).fetchResources()
        }
    }
}

@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("timed out waiting: \(what)")
}
