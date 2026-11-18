import Foundation
import Observation

/// The live home state behind the app's UI. Opens from the cached snapshot,
/// follows the bridge's event stream, and applies the user's changes locally
/// before the bridge confirms them.
@MainActor
@Observable
public final class HomeStore {
    public enum Connection: Equatable, Sendable {
        case connecting
        case live
        case offline(String)
    }

    public private(set) var snapshot: HomeSnapshot
    public private(set) var connection: Connection = .connecting
    public private(set) var credentials: BridgeCredentials
    /// True once the bridge rejected the stored key; the app should pair again.
    public private(set) var needsPairing = false

    @ObservationIgnored private let storage: HueStorage
    @ObservationIgnored private var client: HueClient
    @ObservationIgnored private var queue: CommandQueue!
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Resources the user is changing right now, and until when bridge events for them wait.
    @ObservationIgnored private var holds: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var deferred: [String: JSONValue] = [:]

    private static let holdTime: Duration = .milliseconds(1200)

    public init(credentials: BridgeCredentials, storage: HueStorage) {
        self.credentials = credentials
        self.storage = storage
        snapshot = storage.loadSnapshot() ?? HomeSnapshot()
        client = HueClient(credentials: credentials)
        queue = makeQueue()
    }

    private func makeQueue() -> CommandQueue {
        CommandQueue(
            send: { [client] path, body in try await client.put(path, body) },
            onFailure: { [weak self] error in
                Task { @MainActor in self?.commandFailed(error) }
            }
        )
    }

    // MARK: Lifecycle

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        saveTask?.cancel()
        storage.saveSnapshot(snapshot)
    }

    private func run() async {
        var delay = 1.0
        var failures = 0
        while !Task.isCancelled {
            if connection != .live { connection = .connecting }
            let attempt = ContinuousClock.now
            do {
                let resources = try await client.fetchResources()
                if Task.isCancelled { break }
                snapshot = HomeSnapshot(resources: resources)
                scheduleSave()
                connection = .live
                failures = 0
                for try await events in client.events() { receive(events) }
            } catch HueError.unauthorized {
                needsPairing = true
                connection = .offline(HueError.unauthorized.localizedDescription)
                return
            } catch {
                if Task.isCancelled { break }
                connection = .offline(error.localizedDescription)
                failures += 1
                if failures % 3 == 2 { await relocateBridge() }
            }
            // A connection that held for a while earns a quick retry; one that keeps
            // dropping at once backs off, so a broken stream cannot hammer the bridge.
            if ContinuousClock.now - attempt > .seconds(20) { delay = 1 }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 8)
        }
    }

    /// The bridge may have a new address; find it by id and reconnect there.
    private func relocateBridge() async {
        guard let host = await Discovery.locate(bridgeID: credentials.bridgeID), host != credentials.host else { return }
        credentials.host = host
        try? storage.saveCredentials(credentials)
        client = HueClient(credentials: credentials)
        queue = makeQueue()
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            guard let resources = try? await client.fetchResources(), !Task.isCancelled else { return }
            snapshot = HomeSnapshot(resources: resources)
        }
    }

    private func commandFailed(_ error: Error) {
        if case HueError.unauthorized = error { needsPairing = true }
        // The optimistic state may be wrong now; take the bridge's.
        refresh()
    }

    // MARK: Events

    private func receive(_ events: [HueEvent]) {
        let now = ContinuousClock.now
        var immediate: [HueEvent] = []
        for event in events {
            guard event.kind == .update else {
                immediate.append(event)
                continue
            }
            var passing: [JSONValue] = []
            for resource in event.resources {
                if let id = resource["id"]?.string, let until = holds[id], until > now {
                    deferred[id] = deferred[id]?.merging(resource) ?? resource
                } else {
                    passing.append(resource)
                }
            }
            if !passing.isEmpty { immediate.append(HueEvent(kind: .update, resources: passing)) }
        }
        if !immediate.isEmpty {
            snapshot.apply(immediate)
            scheduleSave()
        }
    }

    private func hold(_ ids: [String]) {
        let until = ContinuousClock.now + HomeStore.holdTime
        for id in ids { holds[id] = until }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: HomeStore.holdTime + .milliseconds(50))
            if !Task.isCancelled { flushDeferred() }
        }
    }

    private func flushDeferred() {
        let now = ContinuousClock.now
        holds = holds.filter { $0.value > now }
        for (id, patch) in deferred where holds[id] == nil {
            snapshot.merge(id: id, patch: patch)
            deferred[id] = nil
        }
        if !holds.isEmpty { scheduleFlush() }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { storage.saveSnapshot(snapshot) }
        }
    }

    // MARK: Commands

    public func setGroup(_ group: LightGroup, on: Bool) {
        hold([group.groupedLightID] + group.lightIDs)
        snapshot.setGroupLocally(group, on: on)
        queue.submit(path: HueClient.path(.groupedLight, group.groupedLightID), body: ["on": ["on": .bool(on)]])
    }

    /// Brightness 0...100. Below 1 turns the group off; anything else turns it on.
    public func setGroup(_ group: LightGroup, brightness: Double) {
        guard brightness >= 1 else { return setGroup(group, on: false) }
        let value = min(brightness, 100)
        hold([group.groupedLightID] + group.lightIDs)
        snapshot.setGroupLocally(group, brightness: value)
        queue.submit(
            path: HueClient.path(.groupedLight, group.groupedLightID),
            body: ["on": ["on": true], "dimming": ["brightness": .number(value)], "dynamics": ["duration": 200]]
        )
    }

    public func setGroup(_ group: LightGroup, mirek: Int) {
        hold([group.groupedLightID] + group.lightIDs)
        let patch: JSONValue = ["color_temperature": ["mirek": .number(Double(mirek))]]
        for id in group.lightIDs where snapshot.lights[id]?.mirekRange != nil { snapshot.setLightLocally(id: id, patch: patch) }
        queue.submit(path: HueClient.path(.groupedLight, group.groupedLightID), body: patch)
    }

    public func setGroup(_ group: LightGroup, color: XY) {
        hold([group.groupedLightID] + group.lightIDs)
        for id in group.lightIDs where snapshot.lights[id]?.xy != nil {
            snapshot.setLightLocally(id: id, patch: HomeStore.colorPatch(color))
        }
        queue.submit(path: HueClient.path(.groupedLight, group.groupedLightID), body: HomeStore.colorPatch(color))
    }

    public func recall(_ scene: LightScene) {
        if let group = snapshot.group(scene.groupID) { hold([group.groupedLightID] + group.lightIDs) }
        snapshot.recallLocally(sceneID: scene.id)
        queue.submit(path: HueClient.path(.scene, scene.id), body: HueClient.recallBody)
    }

    public func setAll(on: Bool) {
        guard let home = snapshot.homeGroupedLightID else { return }
        hold(Array(snapshot.lights.keys) + Array(snapshot.groupedLights.keys))
        snapshot.setAllLocally(on: on)
        queue.submit(path: HueClient.path(.groupedLight, home), body: ["on": ["on": .bool(on)]])
    }

    public func setLight(_ light: Light, on: Bool) {
        change(light, patch: ["on": ["on": .bool(on)]])
    }

    public func setLight(_ light: Light, brightness: Double) {
        guard brightness >= 1 else { return setLight(light, on: false) }
        change(
            light,
            patch: ["on": ["on": true], "dimming": ["brightness": .number(min(brightness, 100))]],
            extra: ["dynamics": ["duration": 200]]
        )
    }

    public func setLight(_ light: Light, mirek: Int) {
        change(light, patch: ["color_temperature": ["mirek": .number(Double(mirek))]])
    }

    public func setLight(_ light: Light, color: XY) {
        hold([light.id])
        snapshot.setLightLocally(id: light.id, patch: HomeStore.colorPatch(color))
        queue.submit(path: HueClient.path(.light, light.id), body: HomeStore.colorPatch(color))
    }

    private func change(_ light: Light, patch: JSONValue, extra: JSONValue = .object([:])) {
        hold([light.id])
        snapshot.setLightLocally(id: light.id, patch: patch)
        queue.submit(path: HueClient.path(.light, light.id), body: patch.merging(extra))
    }

    private static func colorPatch(_ color: XY) -> JSONValue {
        ["color": ["xy": ["x": .number(color.x), "y": .number(color.y)]]]
    }
}
