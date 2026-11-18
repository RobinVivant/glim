import Foundation
import HueKit

// Development tool: exercises HueKit against a real bridge from the Mac.
//
//   huectl discover          bridges found on this network
//   huectl rooms             rooms, zones, their state and scenes
//   huectl watch [seconds]   print live events
//   huectl noop              re-send a group's current on/off state (no visible change)
//
// Reads the application key from $HUE_KEY_FILE (default ~/.secrets/hue-glim-dev.json,
// the bridge's raw pairing answer) and the address from $HUE_HOST or discovery.

func loadCredentials() async throws -> BridgeCredentials {
    let environment = ProcessInfo.processInfo.environment
    let keyFile = environment["HUE_KEY_FILE"] ?? NSHomeDirectory() + "/.secrets/hue-glim-dev.json"
    let answer = try JSONValue(data: Data(contentsOf: URL(fileURLWithPath: keyFile)))
    guard let key = answer.array?.first?["success"]?["username"]?.string else { throw HueError.notPaired }
    var host = environment["HUE_HOST"]
    if host == nil { host = await Discovery.candidateHosts().first }
    guard let host else { throw HueError.invalidResponse }
    let bridge = try await Pairing.probe(host: host)
    return BridgeCredentials(
        host: host, bridgeID: bridge.bridgeID, name: bridge.name, applicationKey: key,
        certificatePin: bridge.certificatePin)
}

func milliseconds(_ duration: Duration) -> String {
    String(format: "%.0f ms", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let clock = ContinuousClock()

do {
    switch arguments.first {
    case "discover":
        let started = clock.now
        let bridges = await Discovery.bridges()
        for bridge in bridges { print("\(bridge.name)  \(bridge.host)  \(bridge.bridgeID)") }
        print("\(bridges.count) bridge(s) in \(milliseconds(clock.now - started))")

    case "rooms":
        let client = HueClient(credentials: try await loadCredentials())
        let started = clock.now
        let resources = try await client.fetchResources()
        let fetched = clock.now
        let snapshot = HomeSnapshot(resources: resources)
        print("\(resources.count) resources, fetch \(milliseconds(fetched - started)), index \(milliseconds(clock.now - fetched))")
        for group in snapshot.groups {
            let state = snapshot.state(of: group)
            let scenes = snapshot.scenes(in: group)
            let power = state.isOn ? "on \(String(format: "%.2f", state.brightness))%" : "off"
            print("[\(group.kind.rawValue)] \(group.name): \(power), \(state.lightsOn)/\(state.lightCount) lights on, \(scenes.count) scenes")
            for light in snapshot.lights(in: group) {
                let kind = light.xy != nil ? "color" : light.mirekRange != nil ? "white ambiance" : light.brightness != nil ? "dimmable" : "on/off"
                let reach = snapshot.isReachable(light) ? "" : " (unreachable)"
                print("    \(light.name): \(light.isOn ? "on" : "off") \(light.brightness.map { String(format: "%.2f%%", $0) } ?? "no dimming") \(kind)\(reach)")
            }
            if !scenes.isEmpty {
                print("    scenes: " + scenes.map { $0.isActive ? "*\($0.name)" : $0.name }.joined(separator: ", "))
            }
        }

    case "watch":
        let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 15
        let client = HueClient(credentials: try await loadCredentials())
        print("watching for \(Int(seconds)) s")
        let watcher = Task {
            do {
            for try await events in client.events() {
                for event in events {
                    for resource in event.resources {
                        let keys = (resource.objectKeys).filter { !["id", "id_v1", "owner", "type", "service_id"].contains($0) }
                        print("\(event.kind.rawValue) \(resource["type"]?.string ?? "?") \(keys.sorted().joined(separator: ","))")
                    }
                }
            }
            } catch { print("stream ended: \(error)") }
        }
        try await Task.sleep(for: .seconds(seconds))
        watcher.cancel()

    case "noop":
        let client = HueClient(credentials: try await loadCredentials())
        let snapshot = HomeSnapshot(resources: try await client.fetchResources())
        guard let group = snapshot.groups.first else { throw HueError.invalidResponse }
        let isOn = snapshot.state(of: group).isOn
        for attempt in 1...3 {
            let started = clock.now
            try await client.setGroupedLight(group.groupedLightID, ["on": ["on": .bool(isOn)]])
            print("put \(attempt) to \(group.name) (on=\(isOn), unchanged): \(milliseconds(clock.now - started))")
        }

    default:
        print("usage: huectl discover | rooms | watch [seconds] | noop")
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}

extension JSONValue {
    var objectKeys: [String] {
        if case .object(let values) = self { Array(values.keys) } else { [] }
    }
}
