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
    static let description = IntentDescription("Choose the room this widget controls.")

    @Parameter(title: "Room") var room: RoomEntity?
}

struct RoomEntry: TimelineEntry {
    struct SceneItem: Identifiable {
        let id: String
        let name: String
        let color: Color
        let isActive: Bool
        let entity: SceneEntity
    }

    var date = Date.now
    var room: RoomEntity?
    var isOn = false
    var brightness = 0.0
    var isDimmable = true
    var tint = Color.glow
    var scenes: [SceneItem] = []
    var isPaired = true

    static let preview = RoomEntry(
        room: RoomEntity(id: "preview", name: "Living room"), isOn: true, brightness: 60,
        scenes: ["Relax", "Read", "Movie", "Bright"].map {
            SceneItem(
                id: $0, name: $0, color: .glow, isActive: $0 == "Relax",
                entity: SceneEntity(id: $0, name: $0, roomName: "Living room"))
        })

    init(
        date: Date = .now, room: RoomEntity? = nil, isOn: Bool = false, brightness: Double = 0, tint: Color = .glow,
        scenes: [SceneItem] = [], isPaired: Bool = true
    ) {
        self.date = date
        self.room = room
        self.isOn = isOn
        self.brightness = brightness
        self.tint = tint
        self.scenes = scenes
        self.isPaired = isPaired
    }

    init(snapshot: HomeSnapshot, roomID: String?) {
        guard let group = roomID.flatMap(snapshot.group) ?? snapshot.groups.first else { return }
        let state = snapshot.state(of: group)
        room = RoomEntity(id: group.id, name: group.name)
        isOn = state.isOn
        brightness = state.brightness
        isDimmable = state.isDimmable
        tint = state.tint?.color ?? .glow
        scenes = snapshot.scenes(in: group).map {
            SceneItem(
                id: $0.id, name: $0.name, color: $0.swatches.first?.color ?? .glow, isActive: $0.isActive,
                entity: SceneEntity(id: $0.id, name: $0.name, roomName: group.name))
        }
    }
}

struct RoomTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> RoomEntry { .preview }

    func snapshot(for configuration: RoomWidgetConfiguration, in context: Context) async -> RoomEntry {
        guard Glim.remote.isPaired else { return .preview }
        return RoomEntry(snapshot: Glim.remote.cachedSnapshot(), roomID: configuration.room?.id)
    }

    func timeline(for configuration: RoomWidgetConfiguration, in context: Context) async -> Timeline<RoomEntry> {
        guard Glim.remote.isPaired else {
            return Timeline(entries: [RoomEntry(isPaired: false)], policy: .after(.now.addingTimeInterval(3600)))
        }
        let entry = RoomEntry(snapshot: await Glim.remote.currentSnapshot(), roomID: configuration.room?.id)
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60)))
    }
}

struct RoomWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: "com.robinvivant.glim.room", intent: RoomWidgetConfiguration.self, provider: RoomTimelineProvider()
        ) { entry in
            RoomWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Room")
        .description("Turn a room on or off and recall its scenes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RoomWidgetView: View {
    let entry: RoomEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let room = entry.room, entry.isPaired {
            HStack(alignment: .top, spacing: 14) {
                power(room)
                if family == .systemMedium, !entry.scenes.isEmpty {
                    scenes
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "lightbulb.slash").font(.title2)
                Text(entry.isPaired ? "No rooms" : "Open Glim to pair").font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func power(_ room: RoomEntity) -> some View {
        Button(intent: SetRoomPowerIntent(room: room, on: !entry.isOn)) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: entry.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(entry.isOn ? Color.black.opacity(0.75) : Color.secondary)
                    .frame(width: 46, height: 46)
                    .background(entry.isOn ? AnyShapeStyle(entry.tint.gradient) : AnyShapeStyle(.quaternary), in: .circle)
                Spacer(minLength: 0)
                Text(room.name).font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                Text(entry.isOn ? (entry.isDimmable ? "\(Int(max(entry.brightness, 1).rounded()))%" : "On") : "Off")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var scenes: some View {
        VStack(spacing: 6) {
            ForEach(entry.scenes.prefix(4)) { scene in
                Button(intent: ActivateSceneIntent(scene: scene.entity)) {
                    HStack(spacing: 6) {
                        Circle().fill(scene.color).frame(width: 10, height: 10)
                        Text(scene.name).font(.footnote.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxHeight: .infinity)
                    .background(scene.isActive ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
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
            .tint(.yellow)
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
            guard let scene = configuration.scene else { throw HueError.notPaired }
            return scene
        }
    }

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "com.robinvivant.glim.control.scene", provider: Provider()) { scene in
            ControlWidgetButton(action: ActivateSceneIntent(scene: scene)) {
                Label(scene.name, systemImage: "sparkles")
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
