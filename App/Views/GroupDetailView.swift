import HueKit
import SwiftUI

/// A room or zone in full: every scene, color for the whole group, and each light.
struct GroupDetailView: View {
    let store: HomeStore
    let groupID: String

    @State private var colorLight: Light?

    var body: some View {
        if let group = store.snapshot.group(groupID) {
            content(group)
        } else {
            ContentUnavailableView("Room removed", systemImage: "questionmark.circle")
        }
    }

    private func content(_ group: LightGroup) -> some View {
        let state = store.snapshot.state(of: group)
        let scenes = store.snapshot.scenes(in: group)
        let lights = store.snapshot.lights(in: group)
        let tint = state.tint?.color ?? .glow

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    if state.isDimmable {
                        BrightnessBar(value: state.brightness, isOn: state.isOn, tint: tint, height: 56) {
                            store.setGroup(group, brightness: $0)
                        }
                    } else {
                        Text(state.isOn ? "On" : "Off").font(.title3.weight(.semibold))
                        Spacer()
                    }
                    PowerButton(isOn: state.isOn, tint: tint) { store.setGroup(group, on: !state.isOn) }
                }

                if lights.contains(where: { $0.mirekRange != nil || $0.xy != nil }) {
                    section("Color") {
                        PaletteStrip(
                            showsWhites: lights.contains { $0.mirekRange != nil },
                            showsColors: lights.contains { $0.xy != nil },
                            onMirek: { store.setGroup(group, mirek: $0) },
                            onColor: { store.setGroup(group, color: $0) }
                        )
                    }
                }

                if !scenes.isEmpty {
                    section("Scenes") {
                        FlowLayout(spacing: 8) {
                            ForEach(scenes) { scene in
                                SceneChip(scene: scene) { store.recall(scene) }
                            }
                        }
                    }
                }

                section("Lights") {
                    VStack(spacing: 10) {
                        ForEach(lights) { light in
                            LightRow(
                                light: light,
                                isReachable: store.snapshot.isReachable(light),
                                onPower: { store.setLight(light, on: $0) },
                                onBrightness: { store.setLight(light, brightness: $0) },
                                onColor: { colorLight = light }
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $colorLight) { opened in
            LightColorSheet(store: store, light: store.snapshot.lights[opened.id] ?? opened)
                .presentationDetents([.height(260)])
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }
}

struct LightRow: View {
    let light: Light
    let isReachable: Bool
    let onPower: (Bool) -> Void
    let onBrightness: (Double) -> Void
    let onColor: () -> Void

    private var tint: Color { light.displayColor.color }
    private var hasColorControls: Bool { light.mirekRange != nil || light.xy != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onColor) {
                    Circle()
                        .fill(light.isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!hasColorControls)
                .accessibilityLabel("Color of \(light.name)")

                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name).font(.body.weight(.medium)).lineLimit(1)
                    if !isReachable {
                        Text("Unreachable").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                Toggle("Power", isOn: Binding(get: { light.isOn }, set: { onPower($0) }))
                    .labelsHidden()
                    .tint(tint)
                    .accessibilityIdentifier("light-\(light.name)")
            }
            if light.brightness != nil {
                BrightnessBar(
                    value: light.brightness ?? 0, isOn: light.isOn, tint: tint, height: 36, onChange: onBrightness)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        .opacity(isReachable ? 1 : 0.55)
    }
}

struct LightColorSheet: View {
    let store: HomeStore
    let light: Light

    @State private var mirek: Double = 366

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(light.name).font(.headline)
            if let range = light.mirekRange {
                // Warm is a high mirek value; the slider runs warm to cool, left to right.
                Slider(
                    value: Binding(
                        get: { Double(range.upperBound) - mirek + Double(range.lowerBound) },
                        set: {
                            mirek = Double(range.upperBound) - $0 + Double(range.lowerBound)
                            store.setLight(light, mirek: Int(mirek.rounded()))
                        }),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                ) {
                    Text("White temperature")
                } minimumValueLabel: {
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                } maximumValueLabel: {
                    Image(systemName: "snowflake").foregroundStyle(.cyan)
                }
            }
            PaletteStrip(
                showsWhites: light.mirekRange != nil,
                showsColors: light.xy != nil,
                onMirek: {
                    mirek = Double($0)
                    store.setLight(light, mirek: $0)
                },
                onColor: { store.setLight(light, color: $0) }
            )
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear {
            if let current = light.mirek { mirek = Double(current) }
        }
    }
}

/// Wraps its children onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}
