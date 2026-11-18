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
            // Glim is dark whatever the system appearance is, like the app (UIUserInterfaceStyle).
            RoomWidgetView(entry: entry)
                .containerBackground(for: .widget) { RoomWidgetBackground(entry: entry) }
                .environment(\.colorScheme, .dark)
        }
        .configurationDisplayName("Room")
        .description("Turn a room on or off and recall its scenes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Black, with a soft patch of the room's light when it is on, like the app's background.
struct RoomWidgetBackground: View {
    let entry: RoomEntry

    var body: some View {
        ZStack {
            Color.black
            if entry.isOn {
                RadialGradient(
                    colors: [entry.tint.opacity(0.22 + entry.level / 100 * 0.3), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 240)
            }
        }
    }
}

extension RoomEntry {
    /// What the slider shows: 0...100, full for on/off devices that are on.
    var level: Double { isOn ? (isDimmable ? max(brightness, 1) : 100) : 0 }

    var levelText: String { isOn ? (isDimmable ? "\(Int(max(brightness, 1).rounded()))%" : "On") : "Off" }

    var status: String {
        guard isOn else { return "Off" }
        return scenes.first(where: \.isActive)?.name ?? "On"
    }
}

struct RoomWidgetView: View {
    let entry: RoomEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let room = entry.room, entry.isPaired {
            if family == .systemMedium {
                medium(room)
            } else {
                small(room)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "lightbulb.slash").font(.title2)
                Text(entry.isPaired ? "No rooms" : "Open Glim to pair").font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// The whole widget switches the room; the bar at the bottom shows its brightness.
    private func small(_ room: RoomEntity) -> some View {
        Button(intent: SetRoomPowerIntent(room: room, on: !entry.isOn)) {
            VStack(alignment: .leading, spacing: 2) {
                powerDot(size: 44)
                Spacer(minLength: 0)
                Text(room.name).font(.system(size: 17, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                Text(entry.status).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                LevelBar(entry: entry) {
                    Text(entry.levelText).font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 10)
                }
                .frame(height: 28)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(room.name), \(entry.levelText)")
    }

    /// The app's room row, with the room's scenes under it.
    private func medium(_ room: RoomEntity) -> some View {
        VStack(spacing: 10) {
            Button(intent: SetRoomPowerIntent(room: room, on: !entry.isOn)) {
                LevelBar(entry: entry) {
                    HStack(spacing: 10) {
                        powerDot(size: 40)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(room.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                            Text(entry.status).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(entry.levelText).font(.system(size: 16, weight: .bold)).monospacedDigit()
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 16)
                }
                .frame(height: 52)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(room.name), \(entry.levelText)")

            if entry.scenes.isEmpty {
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(entry.scenes.prefix(4)) { scene in
                        Button(intent: ActivateSceneIntent(scene: scene.entity)) {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(scene.color)
                                    .frame(width: 34, height: 34)
                                    .padding(3)
                                    .overlay {
                                        if scene.isActive { Circle().strokeBorder(Color.vero, lineWidth: 2) }
                                    }
                                Text(scene.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(scene.isActive ? Color.vero : .white.opacity(0.8))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func powerDot(size: CGFloat) -> some View {
        Image(systemName: "power")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(entry.isOn ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(entry.isOn ? entry.tint : Color.white.opacity(0.10), in: .circle)
            .shadow(color: entry.isOn ? entry.tint.opacity(0.7) : .clear, radius: 8)
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
                Rectangle().fill(entry.tint.opacity(0.42)).frame(width: fill).widgetAccentable()
                if entry.level > 0, entry.level < 100 {
                    Rectangle().fill(entry.tint.opacity(0.95)).frame(width: 2).offset(x: max(0, fill - 2))
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
