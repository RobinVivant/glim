import Foundation
import Synchronization
import Testing

@testable import HueKit

/// A small home in the bridge's own format: one room with a color light and a
/// white light, one zone containing the color light, and two scenes.
let fixture = """
    [
      {"id": "dev-1", "type": "device", "metadata": {"name": "Sofa lamp"},
       "services": [{"rid": "light-1", "rtype": "light"}, {"rid": "zb-1", "rtype": "zigbee_connectivity"}]},
      {"id": "dev-2", "type": "device", "metadata": {"name": "Ceiling"},
       "services": [{"rid": "light-2", "rtype": "light"}, {"rid": "zb-2", "rtype": "zigbee_connectivity"}]},
      {"id": "zb-1", "type": "zigbee_connectivity", "owner": {"rid": "dev-1", "rtype": "device"}, "status": "connected"},
      {"id": "zb-2", "type": "zigbee_connectivity", "owner": {"rid": "dev-2", "rtype": "device"},
       "status": "connectivity_issue"},
      {"id": "light-1", "type": "light", "owner": {"rid": "dev-1", "rtype": "device"},
       "metadata": {"name": "Sofa lamp"}, "on": {"on": true}, "dimming": {"brightness": 60.0},
       "color_temperature": {"mirek": null, "mirek_valid": false,
                             "mirek_schema": {"mirek_minimum": 153, "mirek_maximum": 500}},
       "color": {"xy": {"x": 0.5, "y": 0.4}}},
      {"id": "light-2", "type": "light", "owner": {"rid": "dev-2", "rtype": "device"},
       "metadata": {"name": "Ceiling"}, "on": {"on": false}, "dimming": {"brightness": 100.0},
       "color_temperature": {"mirek": 366, "mirek_valid": true,
                             "mirek_schema": {"mirek_minimum": 153, "mirek_maximum": 454}}},
      {"id": "room-1", "type": "room", "metadata": {"name": "Living room"},
       "children": [{"rid": "dev-1", "rtype": "device"}, {"rid": "dev-2", "rtype": "device"}],
       "services": [{"rid": "gl-room", "rtype": "grouped_light"}]},
      {"id": "zone-1", "type": "zone", "metadata": {"name": "Downstairs"},
       "children": [{"rid": "light-1", "rtype": "light"}],
       "services": [{"rid": "gl-zone", "rtype": "grouped_light"}]},
      {"id": "gl-room", "type": "grouped_light", "owner": {"rid": "room-1", "rtype": "room"},
       "on": {"on": true}, "dimming": {"brightness": 60.0}},
      {"id": "gl-zone", "type": "grouped_light", "owner": {"rid": "zone-1", "rtype": "zone"},
       "on": {"on": true}, "dimming": {"brightness": 60.0}},
      {"id": "gl-home", "type": "grouped_light", "owner": {"rid": "home", "rtype": "bridge_home"},
       "on": {"on": true}, "dimming": {"brightness": 60.0}},
      {"id": "scene-relax", "type": "scene", "metadata": {"name": "Relax"},
       "group": {"rid": "room-1", "rtype": "room"}, "status": {"active": "inactive"},
       "actions": [
         {"target": {"rid": "light-1", "rtype": "light"},
          "action": {"on": {"on": true}, "dimming": {"brightness": 30.0}, "color_temperature": {"mirek": 447}}},
         {"target": {"rid": "light-2", "rtype": "light"},
          "action": {"on": {"on": true}, "dimming": {"brightness": 20.0}, "color_temperature": {"mirek": 447}}}
       ]},
      {"id": "scene-bright", "type": "scene", "metadata": {"name": "Bright"},
       "group": {"rid": "room-1", "rtype": "room"}, "status": {"active": "static"}, "actions": []},
      {"id": "button-1", "type": "button", "metadata": {"control_id": 1}}
    ]
    """

func makeSnapshot() throws -> HomeSnapshot {
    HomeSnapshot(resources: try JSONValue(data: Data(fixture.utf8)).array ?? [])
}

@Suite struct JSONValueTests {
    @Test func mergeReplacesLeavesAndKeepsSiblings() {
        let base: JSONValue = ["on": ["on": true], "dimming": ["brightness": 50, "min_dim_level": 2]]
        let merged = base.merging(["dimming": ["brightness": 80]])
        #expect(merged["dimming"]?["brightness"]?.double == 80)
        #expect(merged["dimming"]?["min_dim_level"]?.double == 2)
        #expect(merged["on"]?["on"]?.bool == true)
    }

    @Test func booleansAndNumbersStayDistinctThroughData() throws {
        let value: JSONValue = ["flag": true, "count": 1, "none": .null]
        let decoded = try JSONValue(data: value.data())
        #expect(decoded == value)
        #expect(decoded["flag"]?.bool == true)
        #expect(decoded["count"]?.bool == nil)
    }
}

@Suite struct SnapshotTests {
    @Test func buildsRoomsBeforeZonesWithTheirLights() throws {
        let snapshot = try makeSnapshot()
        #expect(snapshot.groups.map(\.name) == ["Living room", "Downstairs"])
        #expect(snapshot.groups[0].lightIDs == ["light-2", "light-1"])  // Ceiling, Sofa lamp
        #expect(snapshot.groups[1].lightIDs == ["light-1"])
        #expect(snapshot.homeGroupedLightID == "gl-home")
        #expect(snapshot.resources.count == 13)  // the button is not kept
    }

    @Test func reportsGroupState() throws {
        let snapshot = try makeSnapshot()
        let state = snapshot.state(of: snapshot.groups[0])
        #expect(state.isOn)
        #expect(state.brightness == 60)
        #expect(state.lightsOn == 1)
        #expect(state.lightCount == 2)
        #expect(state.tint != nil)
        #expect(state.isDimmable)
        #expect(state.isReachable)  // one of its two lights still answers
    }

    @Test func parsesLightCapabilitiesAndReachability() throws {
        let snapshot = try makeSnapshot()
        let sofa = try #require(snapshot.lights["light-1"])
        let ceiling = try #require(snapshot.lights["light-2"])
        #expect(sofa.xy == XY(x: 0.5, y: 0.4))
        #expect(sofa.mirek == nil)
        #expect(ceiling.xy == nil)
        #expect(ceiling.mirekRange == 153...454)
        #expect(snapshot.isReachable(sofa))
        #expect(!snapshot.isReachable(ceiling))
    }

    @Test func sortsScenesAndReadsActiveFlag() throws {
        let snapshot = try makeSnapshot()
        let scenes = snapshot.scenes(in: snapshot.groups[0])
        #expect(scenes.map(\.name) == ["Bright", "Relax"])
        #expect(scenes.map(\.isActive) == [true, false])
        #expect(scenes[1].swatches.count == 1)
    }

    @Test func appliesPartialUpdateEvents() throws {
        var snapshot = try makeSnapshot()
        let payload = """
            [{"creationtime": "2026-11-18T17:00:00Z", "id": "e1", "type": "update",
              "data": [{"id": "light-1", "type": "light", "dimming": {"brightness": 12.5}},
                       {"id": "gl-room", "type": "grouped_light", "on": {"on": false}}]}]
            """
        snapshot.apply(HueEvent.parse(Data(payload.utf8)))
        #expect(snapshot.lights["light-1"]?.brightness == 12.5)
        #expect(snapshot.lights["light-1"]?.isOn == true)
        #expect(snapshot.lights["light-1"]?.xy == XY(x: 0.5, y: 0.4))
        #expect(snapshot.groupedLights["gl-room"]?.isOn == false)
        #expect(snapshot.state(of: snapshot.groups[0]).brightness == 0)
    }

    @Test func appliesAddAndDeleteEvents() throws {
        var snapshot = try makeSnapshot()
        let added = """
            [{"type": "add", "data": [{"id": "scene-new", "type": "scene", "metadata": {"name": "Aurora"},
              "group": {"rid": "room-1", "rtype": "room"}, "status": {"active": "inactive"}, "actions": []}]},
             {"type": "delete", "data": [{"id": "scene-bright", "type": "scene"}]}]
            """
        snapshot.apply(HueEvent.parse(Data(added.utf8)))
        #expect(snapshot.scenes(in: snapshot.groups[0]).map(\.name) == ["Aurora", "Relax"])
    }

    @Test func ignoresUpdatesForUnknownResources() throws {
        var snapshot = try makeSnapshot()
        let before = snapshot
        snapshot.merge(id: "nope", patch: ["on": ["on": true]])
        #expect(snapshot == before)
    }

    @Test func recallingASceneLocallyShowsItsLightValues() throws {
        var snapshot = try makeSnapshot()
        snapshot.recallLocally(sceneID: "scene-relax")
        #expect(snapshot.lights["light-1"]?.brightness == 30)
        #expect(snapshot.lights["light-1"]?.mirek == 447)
        #expect(snapshot.lights["light-2"]?.isOn == true)
        #expect(snapshot.scenes["scene-relax"]?.isActive == true)
        #expect(snapshot.scenes["scene-bright"]?.isActive == false)
        let state = snapshot.state(of: snapshot.groups[0])
        #expect(state.isOn)
        #expect(state.brightness == 25)
    }

    @Test func groupChangesReachTheLights() throws {
        var snapshot = try makeSnapshot()
        let room = snapshot.groups[0]
        snapshot.setGroupLocally(room, on: false)
        #expect(snapshot.lights(in: room).allSatisfy { !$0.isOn })
        snapshot.setGroupLocally(room, brightness: 42)
        #expect(snapshot.lights(in: room).allSatisfy { $0.isOn && $0.brightness == 42 })
        #expect(snapshot.state(of: room).brightness == 42)
        snapshot.setAllLocally(on: false)
        #expect(!snapshot.anyLightOn)
    }

    @Test func switchingARoomOnShowsItsRememberedLevelAndMovesItsZone() throws {
        var snapshot = try makeSnapshot()
        let room = snapshot.groups[0]
        let zone = snapshot.groups[1]
        snapshot.setGroupLocally(room, on: false)
        // The bridge reports 0 for a group that is off.
        snapshot.merge(id: "gl-room", patch: ["dimming": ["brightness": 0]])
        #expect(!snapshot.state(of: zone).isOn)

        snapshot.setGroupLocally(room, on: true)
        #expect(snapshot.state(of: room).brightness == 80)  // lights remembered 60 and 100
        #expect(snapshot.state(of: zone).isOn)
        #expect(snapshot.state(of: zone).brightness == 60)
        #expect(snapshot.anyLightOn)

        snapshot.setLightLocally(id: "light-1", patch: ["on": ["on": false]])
        #expect(!snapshot.state(of: zone).isOn)
        #expect(snapshot.state(of: room).brightness == 100)
    }

    @Test func aLightGivenAColorDrawsInThatColorAtOnce() throws {
        var snapshot = try makeSnapshot()
        let before = try #require(snapshot.lights["light-2"]).displayColor
        // The ceiling light is white-only; pretend it has color to exercise the switch from white to color.
        snapshot.merge(id: "light-2", patch: ["color": ["xy": ["x": 0.3, "y": 0.3]]])
        #expect(snapshot.lights["light-2"]?.displayColor == before)  // still showing its white point

        snapshot.setLightLocally(id: "light-2", patch: ["color": ["xy": ["x": 0.17, "y": 0.12]]])
        let after = try #require(snapshot.lights["light-2"])
        #expect(after.mirek == nil)
        #expect(after.displayColor.b > after.displayColor.r)
    }

    @Test func survivesTheCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "glim-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = HueStorage(directory: directory)
        #expect(storage.loadSnapshot() == nil)
        #expect(storage.loadCredentials() == nil)

        let snapshot = try makeSnapshot()
        storage.saveSnapshot(snapshot)
        #expect(storage.loadSnapshot() == snapshot)

        let credentials = BridgeCredentials(
            host: "10.0.0.2", bridgeID: "abc", name: "Home", applicationKey: "key", certificatePin: "pin")
        try storage.saveCredentials(credentials)
        #expect(storage.loadCredentials() == credentials)
        storage.deleteAll()
        #expect(storage.loadCredentials() == nil)
    }
}

@Suite struct ColorTests {
    @Test func rgbSurvivesTheTripThroughXY() {
        for color in [RGB(r: 1, g: 0, b: 0), RGB(r: 0, g: 1, b: 0), RGB(r: 0.2, g: 0.4, b: 1), RGB(r: 1, g: 0.6, b: 0.2)] {
            let back = ColorMath.rgb(ColorMath.xy(color))
            #expect(abs(back.r - color.r) < 0.02 && abs(back.g - color.g) < 0.02 && abs(back.b - color.b) < 0.02)
        }
    }

    @Test func warmWhiteIsRedderThanCoolWhite() {
        let warm = ColorMath.rgb(mirek: 500)
        let cool = ColorMath.rgb(mirek: 153)
        #expect(warm.b < cool.b)
        #expect(warm.r >= cool.r)
    }
}

@Suite struct CommandQueueTests {
    final class Recorder: Sendable {
        let sent = Mutex<[(String, JSONValue)]>([])
        func record(_ path: String, _ body: JSONValue) { sent.withLock { $0.append((path, body)) } }
        var all: [(String, JSONValue)] { sent.withLock { $0 } }
    }

    @Test func coalescesARapidDragOntoTheLastValue() async throws {
        let recorder = Recorder()
        let queue = CommandQueue(
            send: { path, body in
                recorder.record(path, body)
                try await Task.sleep(for: .milliseconds(30))
            },
            onFailure: { _ in })

        let path = HueClient.path(.light, "light-1")
        queue.submit(path: path, body: ["on": ["on": true]])
        for value in 1...50 {
            queue.submit(path: path, body: ["dimming": ["brightness": .number(Double(value))]])
        }
        try await Task.sleep(for: .milliseconds(600))

        let sent = recorder.all
        #expect(sent.count < 10)
        #expect(sent.last?.1["dimming"]?["brightness"]?.double == 50)
        // The on command queued before the drag is not lost by the merge.
        #expect(sent.contains { $0.1["on"]?["on"]?.bool == true })
    }

    @Test func retriesWhenTheBridgeIsBusyAndReportsOtherFailures() async throws {
        let attempts = Mutex(0)
        let failures = Mutex<[String]>([])
        let queue = CommandQueue(
            send: { path, _ in
                if path.hasSuffix("busy") {
                    let attempt = attempts.withLock { count in
                        count += 1
                        return count
                    }
                    if attempt == 1 { throw HueError.rateLimited }
                } else {
                    throw HueError.http(500, "boom")
                }
            },
            onFailure: { error in failures.withLock { $0.append(error.localizedDescription) } })

        queue.submit(path: "/light/busy", body: ["on": ["on": true]])
        queue.submit(path: "/light/broken", body: ["on": ["on": true]])
        try await Task.sleep(for: .milliseconds(900))

        #expect(attempts.withLock { $0 } == 2)
        #expect(failures.withLock { $0 } == ["boom"])
    }
}
