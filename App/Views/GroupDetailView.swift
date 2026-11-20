import HueKit
import SwiftUI
import UIKit

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
        let isLit = state.isOn && state.isReachable && state.lightsOn > 0
        let scenes = store.snapshot.scenes(in: group)
        let lights = store.snapshot.lights(in: group)
        let tint = state.tint?.color ?? .glow
        let litWithMirek = lights.filter { $0.isOn && $0.mirek != nil }
        let selectedMirek = litWithMirek.count == 1 ? litWithMirek.first?.mirek : nil

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        PowerButton(isOn: isLit, tint: tint, size: 52) { store.setGroup(group, on: !isLit) }
                            .disabled(!state.isReachable)
                        if state.isDimmable {
                            BrightnessBar(
                                value: state.brightness,
                                isOn: isLit,
                                tint: tint,
                                height: 52,
                                isEnabled: state.isReachable,
                                accessibilityName: group.name
                            ) {
                                store.setGroup(group, brightness: $0)
                            }
                        } else {
                            Text(isLit ? "On" : "Off").font(.system(size: 22, weight: .heavy))
                            Spacer()
                        }
                    }
                    if !state.isReachable {
                        Text("Unreachable, check its power")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 16)

                if lights.contains(where: { $0.mirekRange != nil || $0.xy != nil }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Color").sectionLabel().padding(.horizontal, 16)
                        PaletteStrip(
                            showsWhites: lights.contains { $0.mirekRange != nil },
                            showsColors: lights.contains { $0.xy != nil },
                            mirekRange: store.snapshot.mirekRange(for: group),
                            selectedMirek: selectedMirek,
                            horizontalPadding: 16,
                            onMirek: { store.setGroup(group, mirek: $0) },
                            onColor: { store.setGroup(group, color: $0) }
                        )
                    }
                }

                if !scenes.isEmpty {
                    section("Scenes") {
                        FlowLayout(spacing: 8) {
                            ForEach(scenes) { scene in
                                SceneChip(scene: scene, isActive: isLit && scene.isActive) { store.recall(scene) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                if !lights.isEmpty {
                    section("Lights") {
                        VStack(spacing: 8) {
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
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 16)
        }
        .background {
            AmbientGlow(spots: [
                AmbientGlow.Spot(color: tint, opacity: isLit ? 0.25 + state.brightness / 100 * 0.3 : 0)
            ])
        }
        .background(Color.black)
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $colorLight) { opened in
            let current = store.snapshot.lights[opened.id] ?? opened
            LightColorSheet(store: store, light: current)
                .presentationDetents([.height(current.xy != nil ? 320 : 250)])
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).sectionLabel()
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
            HStack(spacing: 8) {
                Button(action: onColor) {
                    Circle()
                        .fill(light.isOn && isReachable ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.12)))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .padding(3)
                        .overlay {
                            if hasColorControls {
                                Circle().strokeBorder(tint.opacity(light.isOn ? 0.45 : 0.6), lineWidth: 1.5)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(!hasColorControls || !isReachable)
                .accessibilityLabel("Color of \(light.name)")

                VStack(alignment: .leading, spacing: 1) {
                    Text(light.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    if !isReachable {
                        Text("Unreachable").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
                Toggle("Power", isOn: Binding(get: { light.isOn }, set: { onPower($0) }))
                    .labelsHidden()
                    .tint(.vero)
                    .disabled(!isReachable)
                    .accessibilityIdentifier("light-\(light.name)")
            }
            if light.brightness != nil {
                BrightnessBar(
                    value: light.brightness ?? 0,
                    isOn: light.isOn && isReachable,
                    tint: tint,
                    height: 36,
                    isEnabled: isReachable,
                    accessibilityName: light.name,
                    onChange: onBrightness
                )
            }
        }
        .padding(14)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .opacity(isReachable ? 1 : 0.55)
    }
}

struct LightColorSheet: View {
    let store: HomeStore
    let light: Light

    @State private var mirek: Double = 366

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(light.name).font(.system(size: 17, weight: .bold))
            if let range = light.mirekRange {
                // Warm is a high mirek value; the slider runs warm to cool, left to right.
                Slider(
                    value: Binding(
                        get: {
                            let clamped = min(max(mirek, Double(range.lowerBound)), Double(range.upperBound))
                            return Double(range.upperBound) - clamped + Double(range.lowerBound)
                        },
                        set: {
                            let next = Double(range.upperBound) - $0 + Double(range.lowerBound)
                            mirek = next
                            store.setLight(light, mirek: Int(next.rounded()))
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
                mirekRange: light.mirekRange,
                selectedMirek: light.mirek,
                selectedColor: light.xy,
                onMirek: {
                    mirek = Double(clamped($0))
                    store.setLight(light, mirek: $0)
                },
                onColor: { store.setLight(light, color: $0) }
            )
            if light.xy != nil {
                ColorPicker(
                    "Custom color",
                    selection: Binding(
                        get: { light.displayColor.color },
                        set: { picked in
                            var r: CGFloat = 1
                            var g: CGFloat = 1
                            var b: CGFloat = 1
                            var a: CGFloat = 1
                            UIColor(picked).getRed(&r, green: &g, blue: &b, alpha: &a)
                            store.setLight(light, color: ColorMath.xy(RGB(r: Double(r), g: Double(g), b: Double(b))))
                        }
                    ),
                    supportsOpacity: false
                )
                .font(.system(size: 15, weight: .semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .onAppear { syncMirek() }
        .onChange(of: light.mirek) { _, _ in syncMirek() }
    }

    private func clamped(_ value: Int) -> Int {
        guard let range = light.mirekRange else { return value }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func syncMirek() {
        let initial = light.mirek ?? 366
        mirek = Double(clamped(initial))
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
