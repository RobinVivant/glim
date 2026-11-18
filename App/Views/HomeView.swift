import HueKit
import SwiftUI

struct HomeView: View {
    let store: HomeStore

    @State private var openGroup: LightGroup?
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(store.snapshot.groups) { group in
                        GroupRow(
                            group: group,
                            state: store.snapshot.state(of: group),
                            scenes: store.snapshot.scenes(in: group),
                            onPower: { store.setGroup(group, on: $0) },
                            onBrightness: { store.setGroup(group, brightness: $0) },
                            onScene: { store.recall($0) },
                            onOpen: { openGroup = group }
                        )
                        .equatable()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
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
            .safeAreaInset(edge: .bottom) {
                if case .offline = store.connection {
                    Label("Bridge unreachable, retrying", systemImage: "wifi.exclamationmark")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: .capsule)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle(store.credentials.name)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showsSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("All off", systemImage: "power") {
                        Haptics.click()
                        store.setAll(on: false)
                    }
                    .disabled(!store.snapshot.anyLightOn)
                }
            }
            .navigationDestination(item: $openGroup) { group in
                GroupDetailView(store: store, groupID: group.id)
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView(store: store)
            }
        }
    }
}

/// One room or zone on the main screen: power, brightness and its scenes.
struct GroupRow: View, Equatable {
    let group: LightGroup
    let state: GroupState
    let scenes: [LightScene]
    let onPower: (Bool) -> Void
    let onBrightness: (Double) -> Void
    let onScene: (LightScene) -> Void
    let onOpen: () -> Void

    nonisolated static func == (lhs: GroupRow, rhs: GroupRow) -> Bool {
        lhs.group == rhs.group && lhs.state == rhs.state && lhs.scenes == rhs.scenes
    }

    private var tint: Color { state.tint?.color ?? .glow }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.title3.weight(.semibold)).lineLimit(1)
                            Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("open-\(group.name)")
                PowerButton(isOn: state.isOn, tint: tint) { onPower(!state.isOn) }
                    .accessibilityIdentifier("power-\(group.name)")
            }
            BrightnessBar(value: state.brightness, isOn: state.isOn, tint: tint, onChange: onBrightness)
                .accessibilityIdentifier("brightness-\(group.name)")
            if !scenes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(scenes) { scene in
                            SceneChip(scene: scene) { onScene(scene) }
                                .accessibilityIdentifier("scene-\(group.name)-\(scene.name)")
                        }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .clipShape(.rect(cornerRadius: 24))
    }

    private var subtitle: String {
        let kind = group.kind == .zone ? "Zone · " : ""
        if !state.isOn || state.lightsOn == 0 { return kind + "Off" }
        if state.lightsOn == state.lightCount { return kind + (state.lightCount == 1 ? "On" : "All \(state.lightCount) on") }
        return kind + "\(state.lightsOn) of \(state.lightCount) on"
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
