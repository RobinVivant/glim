import Foundation

/// Sends writes to the bridge without flooding it. Per resource, one request is
/// in flight at a time and newer values replace queued ones, so a slider drag
/// costs a handful of requests and always ends on the last value.
public actor CommandQueue {
    public typealias Send = @Sendable (_ path: String, _ body: JSONValue) async throws -> Void

    private let send: Send
    private let onFailure: @Sendable (Error) -> Void
    private let onActivityChanged: (@Sendable (Bool) -> Void)?
    private var pending: [String: JSONValue] = [:]
    private var drainTasks: [String: Task<Void, Never>] = [:]
    private var nextGroupSlot: ContinuousClock.Instant = .now
    private var nextLightSlot: ContinuousClock.Instant = .now
    private let input: AsyncStream<(String, JSONValue)>.Continuation

    public init(
        send: @escaping Send,
        onFailure: @escaping @Sendable (Error) -> Void,
        onActivityChanged: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.send = send
        self.onFailure = onFailure
        self.onActivityChanged = onActivityChanged
        let (stream, continuation) = AsyncStream<(String, JSONValue)>.makeStream()
        input = continuation
        Task { [weak self] in
            for await (path, body) in stream { await self?.enqueue(path: path, body: body) }
        }
    }

    deinit {
        input.finish()
    }

    /// Queues a write. Callable from any context; submissions keep their order.
    public nonisolated func submit(path: String, body: JSONValue) {
        input.yield((path, body))
    }

    public func cancelAll() {
        pending.removeAll()
        let tasks = drainTasks.values
        drainTasks.removeAll()
        for task in tasks { task.cancel() }
        onActivityChanged?(false)
    }

    private func enqueue(path: String, body: JSONValue) {
        if let existing = pending[path] {
            pending[path] = CommandQueue.mergeCommand(existing, with: body)
        } else {
            pending[path] = body
        }
        guard drainTasks[path] == nil else { return }
        let wasIdle = drainTasks.isEmpty
        drainTasks[path] = Task { await drain(path) }
        if wasIdle { onActivityChanged?(true) }
    }

    private func drain(_ path: String) async {
        var retries = 0
        while !Task.isCancelled, let body = pending.removeValue(forKey: path) {
            await reserveGlobalSlot(for: path)
            if Task.isCancelled { break }
            do {
                try await send(path, body)
                retries = 0
            } catch HueError.rateLimited where retries < 3 {
                retries += 1
                pending[path] = CommandQueue.mergeCommand(body, with: pending[path] ?? .object([:]))
                try? await Task.sleep(for: .milliseconds(300 * retries))
                continue
            } catch {
                if !Task.isCancelled { onFailure(error) }
            }
            if !Task.isCancelled {
                try? await Task.sleep(for: CommandQueue.spacing(for: path))
            }
        }
        if drainTasks.removeValue(forKey: path) != nil, drainTasks.isEmpty {
            onActivityChanged?(false)
        }
    }

    /// Spaces commands globally so multi-room bursts (such as "Night") do not flood the bridge.
    private func reserveGlobalSlot(for path: String) async {
        let now = ContinuousClock.now
        let isGroupOrScene = path.contains("/grouped_light/") || path.contains("/scene/")
        let slot: ContinuousClock.Instant
        if isGroupOrScene {
            slot = max(now, nextGroupSlot)
            nextGroupSlot = slot + .milliseconds(120)
        } else {
            slot = max(now, nextLightSlot)
            nextLightSlot = slot + .milliseconds(50)
        }
        if slot > now {
            try? await Task.sleep(until: slot, clock: .continuous)
        }
    }

    /// Merges two commands for the same resource without leaking mutually exclusive fields.
    static func mergeCommand(_ existing: JSONValue, with newer: JSONValue) -> JSONValue {
        guard case .object(var base) = existing else { return newer }
        if newer["on"]?["on"]?.bool == false {
            base.removeValue(forKey: "dimming")
            base.removeValue(forKey: "dynamics")
            base.removeValue(forKey: "color")
            base.removeValue(forKey: "color_temperature")
        } else {
            if newer["color"] != nil, newer["color_temperature"] == nil {
                base.removeValue(forKey: "color_temperature")
            }
            if newer["color_temperature"] != nil, newer["color"] == nil {
                base.removeValue(forKey: "color")
            }
        }
        return JSONValue.object(base).merging(newer)
    }

    /// The bridge handles about ten light commands a second and far fewer group commands.
    static func spacing(for path: String) -> Duration {
        path.contains("/grouped_light/") ? .milliseconds(220) : .milliseconds(90)
    }
}
