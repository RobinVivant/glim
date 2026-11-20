import AppIntents
import HueKit

// MARK: Entities

struct RoomEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    static let defaultQuery = RoomQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct RoomQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RoomEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [RoomEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [RoomEntity] { all() }

    func defaultResult() async -> RoomEntity? { all().first }

    private func all() -> [RoomEntity] {
        Glim.remote.cachedSnapshot().groups.map { RoomEntity(id: $0.id, name: $0.name) }
    }
}

struct SceneEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scene"
    static let defaultQuery = SceneQuery()

    let id: String
    let name: String
    let roomName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(roomName)")
    }
}

struct SceneQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [SceneEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SceneEntity] {
        all().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.roomName.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [SceneEntity] { all() }

    func defaultResult() async -> SceneEntity? { all().first }

    private func all() -> [SceneEntity] {
        let snapshot = Glim.remote.cachedSnapshot()
        return snapshot.groups.flatMap { group in
            snapshot.scenes(in: group).map { SceneEntity(id: $0.id, name: $0.name, roomName: group.name) }
        }
    }
}

struct LightEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Light"
    static let defaultQuery = LightQuery()

    let id: String
    let name: String
    let roomName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(roomName)")
    }
}

struct LightQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [LightEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [LightEntity] {
        all().filter {
            $0.name.localizedCaseInsensitiveContains(string) || $0.roomName.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [LightEntity] { all() }

    func defaultResult() async -> LightEntity? { all().first }

    private func all() -> [LightEntity] {
        let snapshot = Glim.remote.cachedSnapshot()
        var seen = Set<String>()
        return snapshot.groups.filter { $0.kind == .room }.flatMap { group in
            snapshot.lights(in: group).compactMap { light in
                guard seen.insert(light.id).inserted else { return nil }
                return LightEntity(id: light.id, name: light.name, roomName: group.name)
            }
        }
    }
}

// MARK: Intents

/// Turns a room on or off. Also the action behind toggles in widgets and Control Center.
struct SetRoomPowerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Room On or Off"
    static let description = IntentDescription("Turns the lights of a room or zone on or off.")

    @Parameter(title: "Room") var room: RoomEntity
    @Parameter(title: "On") var value: Bool

    init() {}

    init(room: RoomEntity, on: Bool = true) {
        self.room = room
        self.value = on
    }

    func perform() async throws -> some IntentResult {
        try await Glim.remote.setGroup(room.id, on: value)
        Glim.reloadWidgets()
        return .result()
    }
}

struct ToggleRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Room"
    static let description = IntentDescription("Turns a room off if it is on, and on if it is off.")

    @Parameter(title: "Room") var room: RoomEntity

    init() {}

    init(room: RoomEntity) {
        self.room = room
    }

    func perform() async throws -> some IntentResult {
        try await Glim.remote.toggleGroup(room.id)
        Glim.reloadWidgets()
        return .result()
    }
}

struct SetRoomBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Room Brightness"
    static let description = IntentDescription("Turns a room on at a given brightness.")

    @Parameter(title: "Room") var room: RoomEntity
    @Parameter(title: "Brightness", inclusiveRange: (1, 100)) var brightness: Int

    init() {}

    init(room: RoomEntity, brightness: Int) {
        self.room = room
        self.brightness = brightness
    }

    func perform() async throws -> some IntentResult {
        try await Glim.remote.setGroup(room.id, brightness: Double(brightness))
        Glim.reloadWidgets()
        return .result()
    }
}

struct SetLightPowerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Light On or Off"
    static let description = IntentDescription("Turns a single light on or off.")

    @Parameter(title: "Light") var light: LightEntity
    @Parameter(title: "On") var value: Bool

    init() {}

    init(light: LightEntity, on: Bool = true) {
        self.light = light
        self.value = on
    }

    func perform() async throws -> some IntentResult {
        try await Glim.remote.setLight(light.id, on: value)
        Glim.reloadWidgets()
        return .result()
    }
}

struct ActivateSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "Activate Scene"
    static let description = IntentDescription("Recalls a Hue scene.")

    @Parameter(title: "Scene") var scene: SceneEntity

    init() {}

    init(scene: SceneEntity) {
        self.scene = scene
    }

    func perform() async throws -> some IntentResult {
        try await Glim.remote.recallScene(scene.id)
        Glim.reloadWidgets()
        return .result()
    }
}

struct AllLightsOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn All Lights Off"
    static let description = IntentDescription("Turns off every light on the bridge.")

    func perform() async throws -> some IntentResult {
        try await Glim.remote.setAll(on: false)
        Glim.reloadWidgets()
        return .result()
    }
}
