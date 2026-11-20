import CryptoKit
import Foundation
import Synchronization

public struct BridgeCredentials: Codable, Hashable, Sendable {
    /// IP address or hostname of the bridge on the local network.
    public var host: String
    public var bridgeID: String
    public var name: String
    public var applicationKey: String
    /// Base64 SHA-256 of the bridge's TLS certificate, recorded when pairing.
    public var certificatePin: String

    public init(host: String, bridgeID: String, name: String, applicationKey: String, certificatePin: String) {
        self.host = host
        self.bridgeID = bridgeID
        self.name = name
        self.applicationKey = applicationKey
        self.certificatePin = certificatePin
    }
}

public enum HueError: Error, LocalizedError, Equatable {
    case notPaired
    case linkButtonNotPressed
    case unauthorized
    case certificateChanged
    case rateLimited
    case untrustedBridge
    case http(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notPaired: "No Hue bridge is paired yet."
        case .linkButtonNotPressed: "Press the link button on the bridge."
        case .unauthorized: "The bridge no longer accepts this app. Pair again."
        case .certificateChanged: "The bridge's certificate changed. Forget this bridge in Settings and pair again."
        case .rateLimited: "The bridge is busy."
        case .untrustedBridge: "The device at this address did not identify as the expected Hue bridge."
        case .http(let code, let message): message.isEmpty ? "Bridge error \(code)." : message
        case .invalidResponse: "Unexpected answer from the bridge."
        }
    }
}

/// Talks to one bridge over its local HTTPS API (CLIP v2).
public final class HueClient: Sendable {
    public let credentials: BridgeCredentials
    private let session: URLSession
    private let pinDelegate: PinningDelegate
    private let streamPinDelegate: PinningDelegate
    private let streamSessionBox = Mutex<URLSession?>(nil)

    public init(credentials: BridgeCredentials, requestTimeout: TimeInterval = 4) {
        self.credentials = credentials
        pinDelegate = PinningDelegate(mode: .pinned(credentials.certificatePin))
        streamPinDelegate = PinningDelegate(mode: .pinned(credentials.certificatePin))
        session = HueClient.makeSession(delegate: pinDelegate, timeout: requestTimeout)
    }

    deinit {
        session.invalidateAndCancel()
        streamSessionBox.withLock { $0?.invalidateAndCancel() }
    }

    static func makeSession(pin: PinningDelegate.Mode, timeout: TimeInterval) -> URLSession {
        makeSession(delegate: PinningDelegate(mode: pin), timeout: timeout)
    }

    static func makeSession(delegate: PinningDelegate, timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func getStreamSession() -> URLSession {
        streamSessionBox.withLock { existing in
            if let existing { return existing }
            let created = HueClient.makeSession(delegate: streamPinDelegate, timeout: 3600)
            existing = created
            return created
        }
    }

    public static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where host.lowercased().hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
            break
        }
        if let slash = host.firstIndex(of: "/") {
            host = String(host[..<slash])
        }
        if !host.hasPrefix("["), host.filter({ $0 == ":" }).count > 1 {
            host = "[\(host)]"
        }
        return host
    }

    static func isLoopback(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost).lowercased()
        return host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") || host.hasPrefix("[::1]")
    }

    // MARK: Reading

    /// Every resource on the bridge in one request.
    public func fetchResources() async throws -> [JSONValue] {
        try await get("/clip/v2/resource")
    }

    public func fetchGroupedLight(_ id: String) async throws -> GroupedLight {
        guard let light = try await get("/clip/v2/resource/grouped_light/\(id)").first.flatMap(GroupedLight.init(json:))
        else { throw HueError.invalidResponse }
        return light
    }

    private func get(_ path: String) async throws -> [JSONValue] {
        do {
            let (data, response) = try await session.data(for: try request("GET", path))
            try HueClient.check(response, data)
            return try JSONValue(data: data)["data"]?.array ?? []
        } catch {
            if pinDelegate.didRejectPin { throw HueError.certificateChanged }
            throw error
        }
    }

    // MARK: Writing

    public func put(_ path: String, _ body: JSONValue) async throws {
        var request = try request("PUT", path)
        request.httpBody = try body.data()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: request)
            try HueClient.check(response, data)
        } catch {
            if pinDelegate.didRejectPin { throw HueError.certificateChanged }
            throw error
        }
    }

    public func setGroupedLight(_ id: String, _ body: JSONValue) async throws {
        try await put(HueClient.path(.groupedLight, id), body)
    }

    public func recallScene(_ id: String) async throws {
        try await put(HueClient.path(.scene, id), HueClient.recallBody)
    }

    public enum Resource: String, Sendable {
        case light, scene
        case groupedLight = "grouped_light"
    }

    public static func path(_ resource: Resource, _ id: String) -> String {
        "/clip/v2/resource/\(resource.rawValue)/\(id)"
    }

    public static let recallBody: JSONValue = ["recall": ["action": "active"]]

    // MARK: Events

    /// Live changes from the bridge. The stream ends or throws when the connection drops.
    public func events() -> AsyncThrowingStream<[HueEvent], Error> {
        let streamSession = getStreamSession()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try self.request("GET", "/eventstream/clip/v2")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await streamSession.bytes(for: request)
                    try HueClient.check(response, Data())
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let events = HueEvent.parse(Data(line.dropFirst(5).utf8))
                        if !events.isEmpty { continuation.yield(events) }
                    }
                    continuation.finish()
                } catch {
                    if self.streamPinDelegate.didRejectPin {
                        continuation.finish(throwing: HueError.certificateChanged)
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        let host = HueClient.normalizedHost(credentials.host)
        guard !host.isEmpty, let url = URL(string: "https://\(host)\(path)") else { throw HueError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(credentials.applicationKey, forHTTPHeaderField: "hue-application-key")
        return request
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw HueError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw HueError.unauthorized
        case 429, 503: throw HueError.rateLimited
        default:
            let message = (try? JSONValue(data: data))?["errors"]?.array?.first?["description"]?.string ?? ""
            throw HueError.http(http.statusCode, message)
        }
    }
}

/// The bridge presents a certificate from Signify's private CA, which the system
/// does not trust. The app trusts the exact certificate it saw while pairing.
final class PinningDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    enum Mode: Sendable {
        case pinned(String)
        /// Accept and record whatever certificate is presented (first contact only).
        case capture
    }

    struct Observation: Sendable {
        var pin: String
        var subject: String
    }

    let mode: Mode
    private let observation = Mutex<Observation?>(nil)
    private let rejected = Mutex(false)

    init(mode: Mode) {
        self.mode = mode
    }

    var observed: Observation? { observation.withLock { $0 } }
    var didRejectPin: Bool { rejected.withLock { $0 } }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    /// Streaming requests (`bytes(for:)`) deliver the server-trust challenge here instead.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let pin = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)).base64EncodedString()
        switch mode {
        case .pinned(let expected):
            guard pin == expected else {
                rejected.withLock { $0 = true }
                return (.cancelAuthenticationChallenge, nil)
            }
        case .capture:
            let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
            observation.withLock { $0 = Observation(pin: pin, subject: subject) }
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
