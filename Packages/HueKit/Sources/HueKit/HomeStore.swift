import Foundation
import Network
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
    /// True once the bridge rejected the stored key or certificate; the app should pair again.
    public private(set) var needsPairing = false

    @ObservationIgnored private let storage: HueStorage
    @ObservationIgnored private let onQueueActivity: (@Sendable (Bool) -> Void)?
    @ObservationIgnored private var client: HueClient
    @ObservationIgnored private var queue: CommandQueue!
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    /// Resources the user is changing right now, and until when bridge events for them wait.
    @ObservationIgnored private var holds: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var deferred: [String: JSONValue] = [:]

    private static let holdTime: Duration = .milliseconds(1200)

    public init(
        credentials: BridgeCredentials,
        storage: HueStorage,
        onQueueActivity: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.credentials = credentials
        self.storage = storage
        self.onQueueActivity = onQueueActivity
        snapshot = storage.loadSnapshot() ?? HomeSnapshot()
        client = HueClient(credentials: credentials)
        queue = makeQueue()
    }

    private func makeQueue() -> CommandQueue {
        CommandQueue(
            send: { [client] path, body in try await client.put(path, body) },
            onFailure: { [weak self] error in
                Task { @MainActor in self?.commandFailed(error) }
            },
            onActivityChanged: onQueueActivity
        )
    }

    // MARK: Lifecycle

    public func start() {
        guard !needsPairing else { return }
        if holds.isEmpty, let cached = storage.loadSnapshot(), !cached.isEmpty {
            snapshot = cached
        }
        startPathMonitor()
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        flushTask?.cancel()
        flushTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        saveTask?.cancel()
        saveTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
        holds.removeAll()
        deferred.removeAll()
        if !snapshot.isEmpty { storage.saveSnapshot(snapshot) }
    }

    public func reconnect() {
        guard !needsPairing else { return }
        runTask?.cancel()
        runTask = Task { await run() }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.map { "\($0.type):\($0.name)" }.joined(separator: ",")
            let signature = "\(path.status)-\(interfaces)"
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.handlePathChange(signature: signature, satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
    }

    private func handlePathChange(signature: String, satisfied: Bool) {
        let changed = lastPathSignature != nil && lastPathSignature != signature
        lastPathSignature = signature
        guard changed, satisfied else { return }
        reconnect()
    }

    private func run() async {
        var delay = 1.0
        var failures = 0
        while !Task.isCancelled {
            let attempt = ContinuousClock.now
            do {
                let resources = try await client.fetchResources()
                if Task.isCancelled { return }
                applyFullSnapshot(resources, preserveHolds: true)
                connection = .live
                failures = 0
                for try await events in client.events() {
                    if Task.isCancelled { return }
                    receive(events)
                }
            } catch let error as HueError where error == .unauthorized || error == .certificateChanged {
                if Task.isCancelled { return }
                needsPairing = true
                connection = .offline(error.localizedDescription)
                runTask = nil
                return
            } catch {
                if Task.isCancelled { return }
                connection = .offline(error.localizedDescription)
                failures += 1
                if failures % 3 == 2 { await relocateBridge() }
            }
            if Task.isCancelled { return }
            // A connection that held for a while earns a quick retry; one that keeps
            // dropping at once backs off, so a broken stream cannot hammer the bridge.
            if ContinuousClock.now - attempt > .seconds(20) { delay = 1 }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 8)
        }
    }

    private func applyFullSnapshot(_ resources: [JSONValue], preserveHolds: Bool) {
        let now = ContinuousClock.now
        holds = holds.filter { $0.value > now }
        deferred.removeAll()
        let held = preserveHolds ? Set(holds.keys) : []
        snapshot = HomeSnapshot(resources: resources, preserving: held, from: snapshot)
        scheduleSave()
    }

    /// The bridge may have a new address; find it by id and reconnect there.
    private func relocateBridge() async {
        guard !HueClient.isLoopback(credentials.host),
            let host = await Discovery.locate(bridgeID: credentials.bridgeID),
            host != credentials.host
        else { return }
        credentials.host = host
        try? storage.saveCredentials(credentials)
        let oldQueue = queue
        client = HueClient(credentials: credentials)
        queue = makeQueue()
        if let oldQueue { Task { await oldQueue.cancelAll() } }
    }

    private func refresh(reconnectOnFailure: Bool = false, failureError: Error? = nil) {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                let resources = try await client.fetchResources()
                guard !Task.isCancelled else { return }
                applyFullSnapshot(resources, preserveHolds: false)
            } catch let error as HueError where error == .unauthorized || error == .certificateChanged {
                guard !Task.isCancelled else { return }
                needsPairing = true
                connection = .offline(error.localizedDescription)
                runTask?.cancel()
                runTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                if reconnectOnFailure {
                    connection = .offline((failureError ?? error).localizedDescription)
                    reconnect()
                }
            }
        }
    }

    private func commandFailed(_ error: Error) {
        if let hueError = error as? HueError, hueError == .unauthorized || hueError == .certificateChanged {
            needsPairing = true
            connection = .offline(hueError.localizedDescription)
            runTask?.cancel()
            runTask = nil
            return
        }
        // The optimistic state may be wrong now; take the bridge's, or reconnect if unreachable.
        refresh(reconnectOnFailure: true, failureError: error)
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
        hold(snapshot.relatedHoldIDs(for: group))
        snapshot.setGroupLocally(group, on: on)
        queue.submit(path: HueClient.path(.groupedLight, group.groupedLightID), body: ["on": ["on": .bool(on)]])
    }

    /// Brightness 0...100. Below 1 turns the group off; anything else turns it on.
    public func setGroup(_ group: LightGroup, brightness: Double) {
        guard brightness >= 1 else { return setGroup(group, on: false) }
        let value = min(brightness, 100)
        hold(snapshot.relatedHoldIDs(for: group))
        snapshot.setGroupLocally(group, brightness: value)
        queue.submit(
            path: HueClient.path(.groupedLight, group.groupedLightID),
            body: ["on": ["on": true], "dimming": ["brightness": .number(value)], "dynamics": ["duration": 200]]
        )
    }

    public func setGroup(_ group: LightGroup, mirek: Int) {
        let clamped = snapshot.clampedMirek(mirek, for: group)
        hold(snapshot.relatedHoldIDs(for: group))
        snapshot.setGroupLocally(group, mirek: clamped)
        let body: JSONValue = ["on": ["on": true], "color_temperature": ["mirek": .number(Double(clamped))]]
        queue.submit(path: HueClient.path(.groupedLight, group.groupedLightID), body: body)
    }

    public func setGroup(_ group: LightGroup, color: XY) {
        hold(snapshot.relatedHoldIDs(for: group))
        snapshot.setGroupLocally(group, color: color)
        let body = HomeStore.colorPatch(color).merging(["on": ["on": true]])
        queue.submit(path: HueClient.path(.groupedLight, group.groupedLightID), body: body)
    }

    public func recall(_ scene: LightScene) {
        if let group = snapshot.group(scene.groupID) {
            hold(snapshot.relatedHoldIDs(for: group))
        } else {
            hold([scene.id])
        }
        snapshot.recallLocally(sceneID: scene.id)
        queue.submit(path: HueClient.path(.scene, scene.id), body: HueClient.recallBody)
    }

    public func setAll(on: Bool) {
        guard let home = snapshot.homeGroupedLightID else { return }
        hold(Array(snapshot.lights.keys) + Array(snapshot.groupedLights.keys) + Array(snapshot.scenes.keys))
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
        let clamped = snapshot.clampedMirek(mirek, for: light)
        change(light, patch: ["on": ["on": true], "color_temperature": ["mirek": .number(Double(clamped))]])
    }

    public func setLight(_ light: Light, color: XY) {
        change(light, patch: HomeStore.colorPatch(color).merging(["on": ["on": true]]))
    }

    private func change(_ light: Light, patch: JSONValue, extra: JSONValue = .object([:])) {
        hold(snapshot.relatedHoldIDs(forLight: light.id))
        snapshot.setLightLocally(id: light.id, patch: patch)
        queue.submit(path: HueClient.path(.light, light.id), body: patch.merging(extra))
    }

    private static func colorPatch(_ color: XY) -> JSONValue {
        ["color": ["xy": ["x": .number(color.x), "y": .number(color.y)]]]
    }
}
