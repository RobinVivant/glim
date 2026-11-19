import XCTest

/// Drives the real app against scripts/mock-bridge.py and checks both sides:
/// what the screen shows and what the bridge received.
///
/// Start a fresh mock first (the tests assume its initial state): scripts/mock-bridge.py 8443
/// Screenshots go to $GLIM_SHOTS when set (pass TEST_RUNNER_GLIM_SHOTS=<dir> to xcodebuild).
final class GlimUITests: XCTestCase {
    private let bridge = MockBridge(host: ProcessInfo.processInfo.environment["GLIM_BRIDGE_HOST"] ?? "127.0.0.1:8443")

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPairControlAndFollowTheBridge() async throws {
        let bridge = bridge
        let app = XCUIApplication()
        app.launchEnvironment["GLIM_RESET"] = "1"
        app.launchEnvironment["GLIM_BRIDGE_HOST"] = bridge.host
        app.launch()

        // Setup pairs by itself once the bridge stops refusing, then the rooms appear.
        XCTAssertTrue(app.buttons["power-Kitchen"].waitForExistence(timeout: 20), "home screen did not appear")
        try await bridge.put("grouped_light", named: "Kitchen", ["on": ["on": false]])
        try await bridge.put("grouped_light", named: "Office", ["on": ["on": false]])
        XCTAssertTrue(app.buttons["power-Kitchen"].wait(for: \.label, toEqual: "Turn on", timeout: 5))
        shot("01-home")

        // Power: the screen flips at once and the bridge gets the command.
        app.buttons["power-Kitchen"].tap()
        XCTAssertEqual(app.buttons["power-Kitchen"].label, "Turn off")
        try await expectBridge("Kitchen on") { try await bridge.groupedLight("Kitchen").on }

        // Brightness: drag the room's row sideways by half its width, starting left of the chevron.
        let bar = app.descendants(matching: .any)["brightness-Kitchen"]
        XCTAssertEqual(bar.value as? String, "100 percent")
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        let shown = Int((bar.value as? String ?? "").split(separator: " ").first ?? "") ?? -1
        XCTAssertTrue((35...65).contains(shown), "bar shows \(shown)")
        try await expectBridge("Kitchen brightness follows the bar") {
            abs(try await bridge.groupedLight("Kitchen").brightness - Double(shown)) <= 1
        }
        shot("02-kitchen-dimmed")

        // Scene: open the living room's row, then recall Movie in it.
        app.buttons["expand-Living room"].tap()
        XCTAssertTrue(app.buttons["scene-Living room-Movie"].waitForExistence(timeout: 3), "row did not open")
        app.buttons["scene-Living room-Movie"].tap()
        try await expectBridge("Movie scene active") { try await bridge.sceneIsActive("Movie") }
        XCTAssertTrue(app.buttons["scene-Living room-Movie"].isSelected)

        // A change made elsewhere reaches the screen through the event stream.
        XCTAssertEqual(app.buttons["power-Office"].label, "Turn on")
        try await bridge.put("grouped_light", named: "Office", ["on": ["on": true]])
        XCTAssertTrue(app.buttons["power-Office"].wait(for: \.label, toEqual: "Turn off", timeout: 5))
        shot("03-scene-and-remote-change")

        // Room detail: single lights.
        app.buttons["open-Living room"].tap()
        let sofa = app.switches["light-Sofa lamp"]
        XCTAssertTrue(sofa.waitForExistence(timeout: 5))
        shot("04-room-detail")
        let wasOn = (sofa.value as? String) == "1"
        sofa.switches.firstMatch.exists ? sofa.switches.firstMatch.tap() : sofa.tap()
        try await expectBridge("Sofa lamp toggled") { try await bridge.light("Sofa lamp").on != wasOn }
        app.navigationBars.buttons.firstMatch.tap()

        // All off.
        app.buttons["All off"].tap()
        try await expectBridge("everything off") { try await !bridge.anyLightOn() }
        XCTAssertTrue(app.buttons["power-Kitchen"].wait(for: \.label, toEqual: "Turn on", timeout: 5))
        shot("05-all-off")

        // Relaunch paired: the rooms are there from the cache without setup.
        app.terminate()
        app.launchEnvironment["GLIM_RESET"] = nil
        let started = Date()
        app.launch()
        XCTAssertTrue(app.buttons["power-Kitchen"].waitForExistence(timeout: 5))
        print("GLIM relaunch to rooms: \(Int(Date().timeIntervalSince(started) * 1000)) ms (includes XCUITest launch overhead)")
    }

    /// Adds the Room widget to the Home Screen and switches a room from it. Runs after
    /// the test above, which leaves the app paired with the mock bridge.
    @MainActor
    func testWidgetOnTheHomeScreen() async throws {
        let bridge = bridge
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
        let roomButton = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bedroom, '")).firstMatch

        if !roomButton.waitForExistence(timeout: 3) {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).press(forDuration: 1.6)
            let edit = springboard.buttons["Edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 4), "Home Screen did not enter edit mode")
            edit.tap()
            let add = springboard.buttons["Add Widget"]
            XCTAssertTrue(add.waitForExistence(timeout: 4))
            add.tap()
            let search = springboard.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("Glim")
            let result = springboard.collectionViews.cells
                .matching(NSPredicate(format: "label CONTAINS[c] 'Glim'")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 5), "Glim is not in the widget gallery")
            result.tap()
            let confirm = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Add Widget'")).firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            let done = springboard.buttons["Done"]
            if done.waitForExistence(timeout: 3) { done.tap() }
        }

        // The widget extension reads the shared pairing and shows the bridge's state.
        try await bridge.put("grouped_light", named: "Bedroom", ["on": ["on": false]])
        let off = springboard.buttons["Bedroom, Off"].firstMatch
        if !off.waitForExistence(timeout: 3) {
            // The widget only redraws when asked; opening the app and leaving it does that.
            XCUIApplication().activate()
            XCUIDevice.shared.press(.home)
        }
        XCTAssertTrue(off.waitForExistence(timeout: 10), "widget does not show the bedroom as off")
        shot("06-widget-off")

        // Tapping it runs the intent inside the extension: the bridge gets the command and the widget redraws.
        off.tap()
        try await expectBridge("Bedroom on from the widget") { try await bridge.groupedLight("Bedroom").on }
        let on = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bedroom, ' AND label ENDSWITH '%'"))
            .firstMatch
        XCTAssertTrue(on.waitForExistence(timeout: 10), "widget did not redraw as on")
        shot("07-widget-on")

        // Tapping a part of the bar sets that brightness.
        let half = springboard.buttons["Bedroom at 50%"].firstMatch
        XCTAssertTrue(half.waitForExistence(timeout: 5), "widget has no brightness levels")
        half.tap()
        try await expectBridge("Bedroom at 50% from the widget") {
            abs(try await bridge.groupedLight("Bedroom").brightness - 50) <= 1
        }
        XCTAssertTrue(springboard.buttons["Bedroom, 50%"].firstMatch.waitForExistence(timeout: 10), "widget did not redraw at 50%")
        shot("08-widget-half")
    }

    /// Long-presses the widget placed by the test above and picks another room for it.
    @MainActor
    func testWidgetRoomCanBeChosen() async throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        let widget = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Bedroom, '")).firstMatch
        XCTAssertTrue(widget.waitForExistence(timeout: 5), "no Glim widget on the Home Screen")
        widget.press(forDuration: 1.5)
        shot("11-widget-long-press")
        let editWidget = springboard.buttons["Edit Widget"]
        XCTAssertTrue(editWidget.waitForExistence(timeout: 4), "long press shows no Edit Widget")
        editWidget.tap()
        // The sheet shows a spinner for a few seconds while it asks the extension for the room list.
        let roomPicker = springboard.cells.containing(.staticText, identifier: "Room").buttons["Bedroom"]
        XCTAssertTrue(roomPicker.waitForExistence(timeout: 15), "the edit sheet has no room picker")
        shot("12-widget-edit")
        // The scene picker offers the chosen room's scenes only.
        let choose = springboard.cells.containing(.staticText, identifier: "Scenes").buttons.firstMatch
        XCTAssertTrue(choose.exists, "the edit sheet has no scene picker")
        choose.tap()
        XCTAssertTrue(springboard.cells.containing(.staticText, identifier: "Aurora").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(springboard.cells.containing(.staticText, identifier: "Relax").firstMatch.exists)
        XCTAssertFalse(springboard.cells.containing(.staticText, identifier: "Bright").firstMatch.exists)
        XCTAssertFalse(springboard.cells.containing(.staticText, identifier: "Movie").firstMatch.exists)
        shot("13-widget-scenes")
        XCUIDevice.shared.press(.home)
    }

    @MainActor
    private func expectBridge(_ what: String, _ check: @Sendable () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("bridge state: \(what)")
    }

    @MainActor
    private func shot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["GLIM_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
    }
}

/// Reads and writes the mock bridge's state directly, as another Hue app would.
struct MockBridge: Sendable {
    let host: String
    private let session = URLSession(configuration: .ephemeral, delegate: TrustLocalMock(), delegateQueue: nil)

    struct State: Sendable {
        var on: Bool
        var brightness: Double
    }

    private func resources() async throws -> [[String: Any]] {
        var request = URLRequest(url: URL(string: "https://\(host)/clip/v2/resource")!)
        request.setValue("mock-application-key", forHTTPHeaderField: "hue-application-key")
        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["data"] as? [[String: Any]] ?? []
    }

    private func name(_ resource: [String: Any]) -> String? {
        (resource["metadata"] as? [String: Any])?["name"] as? String
    }

    private func state(_ resource: [String: Any]) -> State {
        State(
            on: (resource["on"] as? [String: Any])?["on"] as? Bool ?? false,
            brightness: (resource["dimming"] as? [String: Any])?["brightness"] as? Double ?? 0)
    }

    private func groupedLightResource(_ groupName: String, in all: [[String: Any]]) throws -> [String: Any] {
        guard let group = all.first(where: { ["room", "zone"].contains($0["type"] as? String) && name($0) == groupName }),
            let rid = (group["services"] as? [[String: Any]])?.first?["rid"] as? String,
            let grouped = all.first(where: { $0["id"] as? String == rid })
        else { throw URLError(.resourceUnavailable) }
        return grouped
    }

    func groupedLight(_ groupName: String) async throws -> State {
        state(try groupedLightResource(groupName, in: try await resources()))
    }

    func light(_ lightName: String) async throws -> State {
        guard let light = try await resources().first(where: { $0["type"] as? String == "light" && name($0) == lightName })
        else { throw URLError(.resourceUnavailable) }
        return state(light)
    }

    func sceneIsActive(_ sceneName: String) async throws -> Bool {
        let scene = try await resources().first { $0["type"] as? String == "scene" && name($0) == sceneName }
        return ((scene?["status"] as? [String: Any])?["active"] as? String ?? "inactive") != "inactive"
    }

    func anyLightOn() async throws -> Bool {
        try await resources().contains { $0["type"] as? String == "light" && state($0).on }
    }

    func put(_ type: String, named groupName: String, _ body: [String: Any]) async throws {
        let id = try groupedLightResource(groupName, in: try await resources())["id"] as? String ?? ""
        var request = URLRequest(url: URL(string: "https://\(host)/clip/v2/resource/\(type)/\(id)")!)
        request.httpMethod = "PUT"
        request.setValue("mock-application-key", forHTTPHeaderField: "hue-application-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: request)
    }
}

/// The mock bridge is a local process with a throwaway self-signed certificate.
final class TrustLocalMock: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

extension XCUIElement {
    @MainActor
    func wait(for keyPath: KeyPath<XCUIElement, String>, toEqual expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self[keyPath: keyPath] == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return self[keyPath: keyPath] == expected
    }
}
