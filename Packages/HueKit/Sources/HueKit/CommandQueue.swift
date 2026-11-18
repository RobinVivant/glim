import Foundation

/// Sends writes to the bridge without flooding it. Per resource, one request is
/// in flight at a time and newer values replace queued ones, so a slider drag
/// costs a handful of requests and always ends on the last value.
public actor CommandQueue {
    public typealias Send = @Sendable (_ path: String, _ body: JSONValue) async throws -> Void

    private let send: Send
    private let onFailure: @Sendable (Error) -> Void
    private var pending: [String: JSONValue] = [:]
    private var draining: Set<String> = []
    private let input: AsyncStream<(String, JSONValue)>.Continuation

    public init(send: @escaping Send, onFailure: @escaping @Sendable (Error) -> Void) {
        self.send = send
        self.onFailure = onFailure
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

    private func enqueue(path: String, body: JSONValue) {
        pending[path] = pending[path]?.merging(body) ?? body
        guard !draining.contains(path) else { return }
        draining.insert(path)
        Task { await drain(path) }
    }

    private func drain(_ path: String) async {
        var retries = 0
        while let body = pending.removeValue(forKey: path) {
            do {
                try await send(path, body)
                retries = 0
            } catch HueError.rateLimited where retries < 3 {
                retries += 1
                pending[path] = body.merging(pending[path] ?? .object([:]))
                try? await Task.sleep(for: .milliseconds(300 * retries))
                continue
            } catch {
                onFailure(error)
            }
            try? await Task.sleep(for: CommandQueue.spacing(for: path))
        }
        draining.remove(path)
    }

    /// The bridge handles about ten light commands a second and far fewer group commands.
    static func spacing(for path: String) -> Duration {
        path.contains("/grouped_light/") ? .milliseconds(220) : .milliseconds(90)
    }
}
