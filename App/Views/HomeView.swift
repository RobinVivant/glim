import HueKit
import SwiftUI

struct HomeView: View {
    let store: HomeStore

    @State private var openGroup: LightGroup?
    @State private var expandedGroup: String?
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    header
                    ForEach(store.snapshot.groups) { group in
                        GroupRow(
                            group: group,
                            state: store.snapshot.state(of: group),
                            scenes: store.snapshot.scenes(in: group),
                            lights: store.snapshot.lights(in: group).map {
                                LightEntry(light: $0, isReachable: store.snapshot.isReachable($0))
                            },
                            isExpanded: expandedGroup == group.id,
                            onPower: { store.setGroup(group, on: $0) },
                            onBrightness: { store.setGroup(group, brightness: $0) },
                            onScene: { store.recall($0) },
                            onLight: { store.setLight($0, on: $1) },
                            onExpand: {
                                Haptics.tap()
                                withAnimation(.snappy(duration: 0.28)) {
                                    expandedGroup = expandedGroup == group.id ? nil : group.id
                                }
                            },
                            onOpen: { openGroup = group }
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            .background { AmbientGlow(spots: glowSpots) }
            .background(Color.black)
            .overlay {
                if store.snapshot.groups.isEmpty {
                    if store.connection == .live {
                        ContentUnavailableView(
                            "No rooms", systemImage: "lightbulb.slash",
                            description: Text("This bridge has no rooms or zones yet."))
                    } else {
                        ProgressView()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openGroup) { group in
                GroupDetailView(store: store, groupID: group.id)
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView(store: store)
            }
        }
    }

    private var rooms: [LightGroup] { store.snapshot.groups.filter { $0.kind != .zone } }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).sectionLabel(.vero)
                Text(store.credentials.name)
                    .font(.system(size: 34, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 12)
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), interactive: true)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var summary: String {
        let lit = rooms.filter { store.snapshot.state(of: $0).isOn && store.snapshot.state(of: $0).isReachable }.count
        switch lit {
        case 0: return "Everything off"
        case 1: return "1 room on"
        default: return "\(lit) rooms on"
        }
    }

    private var glowSpots: [AmbientGlow.Spot] {
        rooms.prefix(5).map { group in
            let state = store.snapshot.state(of: group)
            let lit = state.isOn && state.isReachable && state.lightsOn > 0
            let level = state.isDimmable ? state.brightness : 70
            return AmbientGlow.Spot(color: state.tint?.color ?? .glow, opacity: lit ? 0.18 + level / 100 * 0.32 : 0)
        }
    }

    /// Rooms that have a scene called Nightlight, each with that scene.
    private var nightScenes: [LightScene] {
        rooms.compactMap { group in
            store.snapshot.scenes(in: group).first { $0.name.localizedCaseInsensitiveCompare("Nightlight") == .orderedSame }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if case .offline = store.connection {
                Label("Bridge unreachable, retrying", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glass(in: Capsule())
            }
            HStack(spacing: 6) {
                let anyOn = store.snapshot.anyLightOn
                Button {
                    Haptics.click()
                    store.setAll(on: false)
                } label: {
                    Label("All off", systemImage: "power")
                        .font(.system(size: 16, weight: .bold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(anyOn ? Color.black : .white.opacity(0.4))
                        .background(anyOn ? Color.vero : .white.opacity(0.08), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(!anyOn)
                let night = nightScenes
                if !night.isEmpty {
                    Button {
                        Haptics.click()
                        night.forEach(store.recall)
                    } label: {
                        Label("Night", systemImage: "moon.fill")
                            .font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.white.opacity(0.08), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sets every room that has it to its Nightlight scene")
                }
            }
            .padding(6)
            .frame(height: 64)
            .glass(in: Capsule())
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 4)
    }
}

struct LightEntry: Hashable {
    let light: Light
    let isReachable: Bool
}

/// One room or zone on the main screen: a full-width brightness slider with a power
/// button, which opens onto its scenes and lights.
struct GroupRow: View, Equatable {
    let group: LightGroup
    let state: GroupState
    let scenes: [LightScene]
    let lights: [LightEntry]
    let isExpanded: Bool
    let onPower: (Bool) -> Void
    let onBrightness: (Double) -> Void
    let onScene: (LightScene) -> Void
    let onLight: (Light, Bool) -> Void
    let onExpand: () -> Void
    let onOpen: () -> Void

    nonisolated static func == (lhs: GroupRow, rhs: GroupRow) -> Bool {
        lhs.group == rhs.group && lhs.state == rhs.state && lhs.scenes == rhs.scenes
            && lhs.lights == rhs.lights && lhs.isExpanded == rhs.isExpanded
    }

    private var tint: Color { state.tint?.color ?? .glow }
    private var isLit: Bool { state.isOn && state.isReachable && state.lightsOn > 0 }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 34, style: .continuous) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                BrightnessSurface(
                    value: state.brightness, isOn: state.isOn, tint: tint, isDimmable: state.isDimmable,
                    accessibilityName: group.name, onChange: onBrightness, onTap: onExpand
                ) { shown in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                            Text(subtitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(level(shown)).font(.system(size: 17, weight: .bold)).monospacedDigit()
                            .contentTransition(.identity)
                    }
                    .padding(.leading, 68)
                    .padding(.trailing, 54)
                }
                .accessibilityIdentifier(state.isDimmable ? "brightness-\(group.name)" : "row-\(group.name)")
                .accessibilityHint(state.isDimmable ? "Slide to dim. Opens scenes and lights." : "Opens scenes and lights.")

                HStack {
                    PowerButton(isOn: state.isOn, tint: tint) { onPower(!state.isOn) }
                        .accessibilityIdentifier("power-\(group.name)")
                    Spacer()
                    Button(action: onExpand) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .frame(width: 44, height: 44)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Hide scenes and lights" : "Show scenes and lights")
                    .accessibilityIdentifier("expand-\(group.name)")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
            }
            .frame(height: 68)

            if isExpanded {
                details.transition(.opacity)
            }
        }
        .clipShape(shape)
        .glass(in: shape)
        .opacity(state.isReachable ? 1 : 0.55)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !scenes.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 12) {
                    ForEach(scenes) { scene in
                        SceneDot(scene: scene) { onScene(scene) }
                            .accessibilityIdentifier("scene-\(group.name)-\(scene.name)")
                    }
                }
            }
            FlowLayout(spacing: 8) {
                ForEach(lights, id: \.light.id) { entry in
                    LightChip(light: entry.light, isReachable: entry.isReachable) {
                        onLight(entry.light, !entry.light.isOn)
                    }
                    .accessibilityIdentifier("chip-\(entry.light.name)")
                }
            }
            Button(action: onOpen) {
                Label("Color and each light", systemImage: "paintpalette")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(.white.opacity(0.08), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("open-\(group.name)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private func level(_ shown: Double) -> String {
        if !state.isReachable { return "" }
        if !state.isDimmable { return state.isOn ? "On" : "Off" }
        return shown >= 1 ? "\(Int(shown.rounded()))%" : "Off"
    }

    private var subtitle: String {
        let kind = group.kind == .zone ? "Zone · " : ""
        if !state.isReachable { return kind + "Unreachable, check its power" }
        if !isLit { return kind + "Off" }
        let active = scenes.first(where: \.isActive).map { $0.name + " · " } ?? ""
        let count: String
        if state.lightsOn == state.lightCount {
            count = state.lightCount == 1 ? "On" : "All \(state.lightCount) on"
        } else {
            count = "\(state.lightsOn) of \(state.lightCount) on"
        }
        return kind + active + count
    }
}

struct SettingsView: View {
    let store: HomeStore

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge") {
                    LabeledContent("Name", value: store.credentials.name)
                    LabeledContent("Address", value: store.credentials.host)
                    LabeledContent("Status", value: status)
                    LabeledContent("Lights", value: "\(store.snapshot.lights.count)")
                }
                Section {
                    Button("Forget this bridge", role: .destructive) { confirmsForget = true }
                } footer: {
                    Text("Widgets and Control Center controls stop working until you pair again.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Forget this bridge?", isPresented: $confirmsForget, titleVisibility: .visible) {
                Button("Forget", role: .destructive) {
                    dismiss()
                    model.forgetBridge()
                }
            }
        }
    }

    private var status: String {
        switch store.connection {
        case .connecting: "Connecting"
        case .live: "Connected"
        case .offline(let reason): reason
        }
    }
}
