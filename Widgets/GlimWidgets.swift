import AppIntents
import HueKit
import SwiftUI
import WidgetKit

@main
struct GlimWidgetBundle: WidgetBundle {
    var body: some Widget {
        RoomWidget()
        RoomToggleControl()
        SceneControl()
        AllOffControl()
    }
}

// MARK: Home Screen widget

struct RoomWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Room"
    static let description = IntentDescription("Choose the room this widget controls and the scenes it shows.")

    @Parameter(title: "Room") var room: RoomEntity?

    /// Scene ids. Plain strings, not scene entities: WidgetKit hands an entity array back empty.
    @Parameter(
        title: "Scenes",
        description: "Leave empty to show the room's first scenes. The medium widget shows 4, the large one 8.",
        optionsProvider: RoomSceneOptions())
    var scenes: [String]?

    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .equalTo, .systemSmall) {
            Summary { \.$room }
        } otherwise: {
            Summary {
                \.$room
                \.$scenes
            }
        }
    }
}

/// The scenes of the room the widget is set to, for its scene picker.
struct RoomSceneOptions: DynamicOptionsProvider {
    @IntentParameterDependency<RoomWidgetConfiguration>(\.$room) var configuration

    func results() async throws -> ItemCollection<String> {
        let snapshot = Glim.remote.cachedSnapshot()
        let chosen = (configuration?.room.id).flatMap(snapshot.group)
        guard let group = chosen ?? snapshot.groups.first else { return ItemCollection(sections: []) }
        let items = snapshot.scenes(in: group).map { IntentItem($0.id, title: "\($0.name)") }
        return ItemCollection(sections: [IntentItemSection(items: items)])
    }
}

struct RoomEntry: TimelineEntry {
    struct SceneItem: Identifiable {
        let id: String
        let name: String
        let colors: [Color]
        let isActive: Bool
        let entity: SceneEntity

        var swatch: AnyShapeStyle {
            switch colors.count {
            case 0: return AnyShapeStyle(Color.glow)
            case 1: return AnyShapeStyle(colors[0])
            default: return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center))
            }
        }
    }

    struct LightItem: Identifiable {
        let id: String
        let name: String
        let isOn: Bool
        let color: Color
        let isReachable: Bool
        let entity: LightEntity
    }

    var date = Date.now
    var room: RoomEntity?
    var isOn = false
    var brightness = 0.0
    var isDimmable = true
    var isReachable = true
    var tint = Color.glow
    var activeSceneName: String?
    var scenes: [SceneItem] = []
    var lights: [LightItem] = []
    var isPaired = true

    static let preview = RoomEntry(
        room: RoomEntity(id: "preview", name: "Living room"),
        isOn: true,
        brightness: 60,
        activeSceneName: "Relax",
        scenes: ["Relax", "Read", "Movie", "Bright"].map {
            SceneItem(
                id: $0, name: $0, colors: [.glow], isActive: $0 == "Relax",
                entity: SceneEntity(id: $0, name: $0, roomName: "Living room"))
        },
        lights: ["Sofa lamp", "Floor lamp"].map {
            LightItem(
                id: $0, name: $0, isOn: true, color: .glow, isReachable: true,
                entity: LightEntity(id: $0, name: $0, roomName: "Living room"))
        }
    )

    init(
        date: Date = .now,
        room: RoomEntity? = nil,
        isOn: Bool = false,
        brightness: Double = 0,
        isDimmable: Bool = true,
        isReachable: Bool = true,
        tint: Color = .glow,
        activeSceneName: String? = nil,
        scenes: [SceneItem] = [],
        lights: [LightItem] = [],
        isPaired: Bool = true
    ) {
        self.date = date
        self.room = room
        self.isOn = isOn
        self.brightness = brightness
        self.isDimmable = isDimmable
        self.isReachable = isReachable
        self.tint = tint
        self.activeSceneName = activeSceneName
        self.scenes = scenes
        self.lights = lights
        self.isPaired = isPaired
    }

    /// `sceneIDs` are the scenes picked for the widget, in order; with none picked, or none of them
    /// in this room, it shows the room's scenes.
    init(snapshot: HomeSnapshot, roomID: String?, sceneIDs: [String] = []) {
        guard let group = roomID.flatMap(snapshot.group) ?? snapshot.groups.first else { return }
        let state = snapshot.state(of: group)
        room = RoomEntity(id: group.id, name: group.name)
        isOn = state.isOn
        brightness = state.brightness
        isDimmable = state.isDimmable
        isReachable = state.isReachable
        tint = state.tint?.color ?? .glow

        let roomScenes = snapshot.scenes(in: group)
        activeSceneName = roomScenes.first(where: \.isActive)?.name
        let picked = sceneIDs.compactMap { id in roomScenes.first { $0.id == id } }
        scenes = (picked.isEmpty ? roomScenes : picked).map {
            SceneItem(
                id: $0.id,
                name: $0.name,
                colors: $0.swatches.map(\.color),
                isActive: $0.isActive,
                entity: SceneEntity(id: $0.id, name: $0.name, roomName: group.name)
            )
        }
        lights = snapshot.lights(in: group).map {
            LightItem(
                id: $0.id,
                name: $0.name,
                isOn: $0.isOn,
                color: $0.displayColor.color,
                isReachable: snapshot.isReachable($0),
                entity: LightEntity(id: $0.id, name: $0.name, roomName: group.name)
            )
        }
    }
}

struct RoomTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RoomEntry { .preview }

    func snapshot(for configuration: RoomWidgetConfiguration, in context: Context) async -> RoomEntry {
        guard Glim.remote.isPaired else { return .preview }
        let cached = Glim.remote.cachedSnapshot()
        if context.isPreview, cached.isEmpty { return .preview }
        return RoomEntry(
            snapshot: cached,
            roomID: configuration.room?.id,
            sceneIDs: configuration.scenes ?? []
        )
    }

    func timeline(for configuration: RoomWidgetConfiguration, in context: Context) async -> Timeline<RoomEntry> {
        guard Glim.remote.isPaired else {
            return Timeline(entries: [RoomEntry(isPaired: false)], policy: .after(.now.addingTimeInterval(3600)))
        }
        let entry = RoomEntry(
            snapshot: await Glim.remote.currentSnapshot(preferCacheWithin: 2.0),
            roomID: configuration.room?.id,
            sceneIDs: configuration.scenes ?? []
        )
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
    }
}

struct RoomWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "com.robinvivant.glim.room", intent: RoomWidgetConfiguration.self, provider: RoomTimelineProvider()
        ) { entry in
            // Glim is dark whatever the system appearance is, like the app (UIUserInterfaceStyle).
            RoomWidgetView(entry: entry)
                .containerBackground(for: .widget) { RoomWidgetBackground(entry: entry) }
                .environment(\.colorScheme, .dark)
        }
        .configurationDisplayName("Room")
        .description("Turn a room on or off, set its brightness and recall its scenes.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// Black, with a soft patch of the room's light when it is on, like the app's background.
struct RoomWidgetBackground: View {
    let entry: RoomEntry

    var body: some View {
        ZStack {
            Color.black
            if entry.isLit {
                RadialGradient(
                    colors: [entry.tint.opacity(0.22 + entry.level / 100 * 0.3), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 240)
            }
        }
    }
}

extension RoomEntry {
    var isLit: Bool { isOn && isReachable }

    /// What the slider shows: 0...100, full for on/off devices that are on.
    var level: Double { isLit ? (isDimmable ? max(brightness, 1) : 100) : 0 }

    var levelText: String {
        if !isReachable { return "Unreachable" }
        return isOn ? (isDimmable ? "\(Int(max(brightness, 1).rounded()))%" : "On") : "Off"
    }

    var status: String {
        if !isReachable { return "Unreachable" }
        guard isOn else { return "Off" }
        return activeSceneName ?? "On"
    }
}

struct RoomWidgetView: View {
    let entry: RoomEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let room = entry.room, entry.isPaired {
            Group {
                switch family {
                case .systemMedium: medium(room)
                case .systemLarge: large(room)
                default: small(room)
                }
            }
            .widgetURL(Glim.groupURL(room.id))
            .opacity(entry.isReachable ? 1 : 0.65)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "lightbulb.slash").font(.title2)
                Text(entry.isPaired ? "No rooms" : "Open Glim to pair").font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// The top button switches the room; tapping the text opens Glim to that room;
    /// tapping the bar at the bottom sets its brightness.
    private func small(_ room: RoomEntity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(intent: SetRoomPowerIntent(room: room, on: !entry.isLit)) {
                powerDot(size: 42)
            }
            .buttonStyle(.plain)
            .disabled(!entry.isReachable)
            .accessibilityLabel("\(room.name), \(entry.levelText)")

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(room.name).font(.system(size: 16, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                Text(entry.status).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }

            LevelBar(entry: entry) {
                if entry.isReachable {
                    Text(entry.levelText).font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 10)
                }
            }
            .overlay { levelTaps(room) }
            .disabled(!entry.isReachable)
            .frame(height: 32)
        }
    }

    private func medium(_ room: RoomEntity) -> some View {
        VStack(spacing: 12) {
            row(room, height: 50, dot: 42)
            if entry.scenes.isEmpty {
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(entry.scenes.prefix(4)) { sceneButton($0, size: 34) }
                }
            }
        }
    }

    private func large(_ room: RoomEntity) -> some View {
        let maxScenes = 8
        let visibleScenes = Array(entry.scenes.prefix(maxScenes))
        let maxLights = visibleScenes.count > 4 ? 4 : 6
        let visibleLights = Array(entry.lights.prefix(maxLights))

        return VStack(alignment: .leading, spacing: 12) {
            row(room, height: 54, dot: 46)
            if visibleScenes.isEmpty {
                Text("This room has no scenes.").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text("Scenes")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.55))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 10) {
                    ForEach(visibleScenes) { sceneButton($0, size: 42) }
                }
            }
            if !visibleLights.isEmpty {
                Text("Lights")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.55))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(visibleLights) { lightButton($0) }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Power button on the left beside a 1:1 aligned capsule bar that sets brightness where tapped.
    private func row(_ room: RoomEntity, height: CGFloat, dot: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button(intent: SetRoomPowerIntent(room: room, on: !entry.isLit)) {
                powerDot(size: dot)
            }
            .buttonStyle(.plain)
            .disabled(!entry.isReachable)
            .accessibilityLabel("\(room.name), \(entry.levelText)")

            LevelBar(entry: entry) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(room.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                        Text(entry.status).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if entry.isReachable {
                        Text(entry.levelText).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    }
                }
                .padding(.horizontal, 14)
            }
            .overlay { levelTaps(room) }
            .disabled(!entry.isReachable)
            .frame(height: height)
        }
    }

    /// Brightness levels a tap on the bar sets, one per equal part of it, left to right.
    static let levels = [5, 25, 50, 75, 100]

    /// Invisible buttons across the bar with subtle bottom tick marks; an on/off device gets a single switch.
    @ViewBuilder
    private func levelTaps(_ room: RoomEntity) -> some View {
        if entry.isDimmable {
            HStack(spacing: 0) {
                ForEach(Array(Self.levels.enumerated()), id: \.offset) { index, level in
                    Button(intent: SetRoomBrightnessIntent(room: room, brightness: level)) {
                        Rectangle().fill(.white.opacity(0.001))
                            .overlay(alignment: .bottomTrailing) {
                                if index < Self.levels.count - 1 {
                                    Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(room.name) at \(level)%")
                }
            }
        } else {
            Button(intent: SetRoomPowerIntent(room: room, on: !entry.isLit)) {
                Rectangle().fill(.white.opacity(0.001))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isLit ? "Turn \(room.name) off" : "Turn \(room.name) on")
        }
    }

    private func sceneButton(_ scene: RoomEntry.SceneItem, size: CGFloat) -> some View {
        let active = entry.isLit && scene.isActive
        return Button(intent: ActivateSceneIntent(scene: scene.entity)) {
            VStack(spacing: 4) {
                Circle()
                    .fill(scene.swatch)
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .padding(3)
                    .overlay {
                        if active { Circle().strokeBorder(Color.vero, lineWidth: 2) }
                    }
                Text(scene.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? Color.vero : .white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func lightButton(_ light: RoomEntry.LightItem) -> some View {
        let on = light.isOn && light.isReachable
        return Button(intent: SetLightPowerIntent(light: light.entity, on: !light.isOn)) {
            HStack(spacing: 6) {
                Circle()
                    .fill(on ? light.color : .white.opacity(0.3))
                    .frame(width: 7, height: 7)
                    .shadow(color: on ? light.color.opacity(0.6) : .clear, radius: 3)
                Text(light.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(on ? light.color.opacity(0.14) : .white.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(on ? light.color.opacity(0.55) : .white.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!light.isReachable)
        .opacity(light.isReachable ? 1 : 0.5)
    }

    private func powerDot(size: CGFloat) -> some View {
        Image(systemName: "power")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(entry.isLit ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(entry.isLit ? entry.tint : Color.white.opacity(0.10), in: .circle)
            .shadow(color: entry.isLit ? entry.tint.opacity(0.7) : .clear, radius: 8)
            .widgetAccentable()
    }
}

/// A capsule filled with the room's color up to its brightness, like a row in the app.
struct LevelBar<Content: View>: View {
    let entry: RoomEntry
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let fill = proxy.size.width * entry.level / 100
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [entry.tint.opacity(0.24), entry.tint.opacity(0.46)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: fill)
                .widgetAccentable()
                if entry.level > 0, entry.level < 100 {
                    Rectangle().fill(entry.tint.opacity(0.55)).frame(width: 1.5).offset(x: max(0, fill - 1.5))
                }
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.white.opacity(0.07))
        .clipShape(.capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: Controls (Control Center, Lock Screen, Action button)

struct RoomControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Room"

    @Parameter(title: "Room") var room: RoomEntity?
}

struct RoomToggleControl: ControlWidget {
    struct Value {
        var room: RoomEntity
        var isOn: Bool
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: RoomControlConfiguration) -> Value {
            Value(room: configuration.room ?? RoomEntity(id: "preview", name: "Room"), isOn: true)
        }

        func currentValue(configuration: RoomControlConfiguration) async throws -> Value {
            let fallback = Glim.remote.cachedSnapshot().groups.first.map { RoomEntity(id: $0.id, name: $0.name) }
            guard let room = configuration.room ?? fallback else { throw HueError.notPaired }
            return Value(room: room, isOn: await Glim.remote.isGroupOn(room.id))
        }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.robinvivant.glim.control.room", provider: Provider()) { value in
            ControlWidgetToggle(value.room.name, isOn: value.isOn, action: SetRoomPowerIntent(room: value.room)) { isOn in
                Label(isOn ? "On" : "Off", systemImage: isOn ? "lightbulb.fill" : "lightbulb")
            }
            .tint(.vero)
        }
        .displayName("Room")
        .description("Turn a room on or off.")
    }
}

struct SceneControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Scene"

    @Parameter(title: "Scene") var scene: SceneEntity?
}

struct SceneControl: ControlWidget {
    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: SceneControlConfiguration) -> SceneEntity {
            configuration.scene ?? SceneEntity(id: "preview", name: "Scene", roomName: "")
        }

        func currentValue(configuration: SceneControlConfiguration) async throws -> SceneEntity {
            if let scene = configuration.scene { return scene }
            let snapshot = Glim.remote.cachedSnapshot()
            for group in snapshot.groups {
                if let first = snapshot.scenes(in: group).first {
                    return SceneEntity(id: first.id, name: first.name, roomName: group.name)
                }
            }
            throw HueError.notPaired
        }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.robinvivant.glim.control.scene", provider: Provider()) { scene in
            ControlWidgetButton(action: ActivateSceneIntent(scene: scene)) {
                let title = scene.roomName.isEmpty ? scene.name : "\(scene.name) · \(scene.roomName)"
                Label(title, systemImage: "sparkles")
            }
        }
        .displayName("Scene")
        .description("Recall a Hue scene.")
    }
}

struct AllOffControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.robinvivant.glim.control.all-off") {
            ControlWidgetButton(action: AllLightsOffIntent()) {
                Label("All off", systemImage: "lightbulb.slash")
            }
        }
        .displayName("All Lights Off")
        .description("Turn off every light.")
    }
}
