import Foundation
import Network
import Synchronization

/// A bridge that answered at an address, before pairing.
public struct BridgeInfo: Identifiable, Hashable, Sendable {
    public var id: String { bridgeID }
    public let bridgeID: String
    public let name: String
    public let host: String
    public let certificatePin: String
}

public enum Pairing {
    /// Asks the device at `host` who it is and records its certificate.
    public static func probe(host: String) async throws -> BridgeInfo {
        let delegate = PinningDelegate(mode: .capture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(host)/api/0/config") else { throw HueError.invalidResponse }
        let (data, response) = try await session.data(from: url)
        try HueClient.check(response, data)
        let config = try JSONValue(data: data)
        guard let bridgeID = config["bridgeid"]?.string, let observed = delegate.observed else {
            throw HueError.invalidResponse
        }
        // The bridge's certificate names its own id; anything else is not the bridge it claims to be.
        guard observed.subject.caseInsensitiveCompare(bridgeID) == .orderedSame else {
            throw HueError.untrustedBridge
        }
        return BridgeInfo(
            bridgeID: bridgeID.lowercased(),
            name: config["name"]?.string ?? "Hue Bridge",
            host: host,
            certificatePin: observed.pin
        )
    }

    /// Requests an application key. Throws `linkButtonNotPressed` until the button was pressed.
    public static func pair(with bridge: BridgeInfo, deviceName: String) async throws -> BridgeCredentials {
        let session = HueClient.makeSession(pin: .pinned(bridge.certificatePin), timeout: 4)
        defer { session.invalidateAndCancel() }

        guard let url = URL(string: "https://\(bridge.host)/api") else { throw HueError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let instance = String(deviceName.filter { $0.isLetter || $0.isNumber || $0 == " " }.prefix(19))
        request.httpBody = try JSONValue.object([
            "devicetype": .string("glim#\(instance.isEmpty ? "iphone" : instance)"),
            "generateclientkey": true,
        ]).data()
        let (data, response) = try await session.data(for: request)
        try HueClient.check(response, data)
        let answer = try JSONValue(data: data).array?.first
        if let key = answer?["success"]?["username"]?.string {
            return BridgeCredentials(
                host: bridge.host,
                bridgeID: bridge.bridgeID,
                name: bridge.name,
                applicationKey: key,
                certificatePin: bridge.certificatePin
            )
        }
        if answer?["error"]?["type"]?.int == 101 { throw HueError.linkButtonNotPressed }
        throw HueError.http(200, answer?["error"]?["description"]?.string ?? "")
    }
}

public enum Discovery {
    /// Addresses of bridges on this network: local mDNS and Philips' discovery
    /// endpoint together, since mDNS does not cross subnets.
    public static func candidateHosts(timeout: Duration = .seconds(2)) async -> [String] {
        async let local = mdns(timeout: timeout)
        async let cloud = cloud()
        var hosts: [String] = []
        for host in await local + cloud where !hosts.contains(host) { hosts.append(host) }
        return hosts
    }

    /// Bridges that answer and identify themselves, ready to pair with.
    public static func bridges(timeout: Duration = .seconds(2)) async -> [BridgeInfo] {
        let hosts = await candidateHosts(timeout: timeout)
        return await withTaskGroup(of: BridgeInfo?.self) { group in
            for host in hosts { group.addTask { try? await Pairing.probe(host: host) } }
            var found: [BridgeInfo] = []
            for await bridge in group {
                if let bridge, !found.contains(where: { $0.bridgeID == bridge.bridgeID }) { found.append(bridge) }
            }
            return found
        }
    }

    /// The current address of a known bridge, for when its IP changed.
    public static func locate(bridgeID: String) async -> String? {
        await bridges().first { $0.bridgeID == bridgeID.lowercased() }?.host
    }

    static func cloud() async -> [String] {
        guard let url = URL(string: "https://discovery.meethue.com/") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let entries = try? JSONValue(data: data).array
        else { return [] }
        return entries.compactMap { $0["internalipaddress"]?.string }
    }

    static func mdns(timeout: Duration) async -> [String] {
        let found = EndpointBox()
        let browser = NWBrowser(for: .bonjour(type: "_hue._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            found.set(results.map(\.endpoint))
        }
        browser.start(queue: .global())
        try? await Task.sleep(for: timeout)
        browser.cancel()

        return await withTaskGroup(of: String?.self) { group in
            for endpoint in found.endpoints { group.addTask { await resolve(endpoint) } }
            var hosts: [String] = []
            for await host in group {
                if let host { hosts.append(host) }
            }
            return hosts
        }
    }

    /// Resolves a Bonjour service to an IPv4 address by connecting to it.
    private static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let once = Mutex(false)
        let host: String? = await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: String?) {
                let first = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        finish("\(host)".split(separator: "%").first.map(String.init))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled, .waiting:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish(nil) }
        }
        connection.cancel()
        return host
    }
}

private final class EndpointBox: Sendable {
    private let storage = Mutex<[NWEndpoint]>([])
    var endpoints: [NWEndpoint] { storage.withLock { $0 } }
    func set(_ endpoints: [NWEndpoint]) { storage.withLock { $0 = endpoints } }
}
