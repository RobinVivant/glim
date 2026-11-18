import HueKit
import SwiftUI

@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    static func tap() { light.impactOccurred() }
    static func click() { rigid.impactOccurred() }
}

/// A wide brightness bar. Dragging sideways anywhere on it changes the value
/// relative to where it was, so a touch never makes the lights jump.
struct BrightnessBar: View {
    /// 0...100 as the store reports it.
    let value: Double
    let isOn: Bool
    let tint: Color
    var height: CGFloat = 46
    let onChange: (Double) -> Void

    @State private var dragStart: Double?
    @State private var dragValue: Double?
    @State private var isSideways: Bool?

    var body: some View {
        let shown = dragValue ?? (isOn ? value : 0)
        GeometryReader { proxy in
            let fill = max(0, proxy.size.width * shown / 100)
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(tint.gradient).frame(width: fill)
                label(shown).foregroundStyle(.secondary)
                label(shown)
                    .foregroundStyle(.black.opacity(0.72))
                    .mask(alignment: .leading) { Rectangle().frame(width: fill) }
            }
            .clipShape(.rect(cornerRadius: height * 0.36))
            .contentShape(.rect)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { gesture in
                        if isSideways == nil {
                            isSideways = abs(gesture.translation.width) > abs(gesture.translation.height)
                        }
                        guard isSideways == true, proxy.size.width > 0 else { return }
                        let start = dragStart ?? (isOn ? value : 0)
                        dragStart = start
                        let next = min(max(start + gesture.translation.width / proxy.size.width * 100, 0), 100)
                        if next.rounded() != dragValue?.rounded() {
                            if next < 1 || next >= 100 { Haptics.click() }
                            onChange(next)
                        }
                        dragValue = next
                    }
                    .onEnded { _ in
                        isSideways = nil
                        dragStart = nil
                        dragValue = nil
                    }
            )
        }
        .frame(height: height)
        .animation(dragValue == nil ? .snappy(duration: 0.22) : nil, value: shown)
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue(shown >= 1 ? "\(Int(shown.rounded())) percent" : "Off")
        .accessibilityAdjustableAction { direction in
            let current = isOn ? value : 0
            onChange(min(max(current + (direction == .increment ? 10 : -10), 0), 100))
        }
    }

    private func label(_ shown: Double) -> some View {
        HStack {
            Image(systemName: shown >= 1 ? "sun.max.fill" : "sun.min")
            Spacer()
            Text(shown >= 1 ? "\(Int(shown.rounded()))%" : "Off").monospacedDigit()
                .contentTransition(.identity)
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 14)
    }
}

struct PowerButton: View {
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "power")
                .font(.body.weight(.bold))
                .foregroundStyle(isOn ? Color.black.opacity(0.75) : Color.secondary)
                .frame(width: 46, height: 46)
                .background(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.quaternary), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Turn off" : "Turn on")
    }
}

struct SceneChip: View {
    let scene: LightScene
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(swatch)
                    .frame(width: 16, height: 16)
                Text(scene.name).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(.leading, 9)
            .padding(.trailing, 13)
            .padding(.vertical, 8)
            .background(scene.isActive ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary), in: .capsule)
            .overlay {
                if scene.isActive { Capsule().strokeBorder(.primary.opacity(0.35), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scene.isActive ? .isSelected : [])
    }

    private var swatch: AnyShapeStyle {
        let colors = scene.swatches.map(\.color)
        switch colors.count {
        case 0: return AnyShapeStyle(Color.glow)
        case 1: return AnyShapeStyle(colors[0])
        default: return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center))
        }
    }
}

/// Preset whites and colors, for a room or a single light.
struct PaletteStrip: View {
    var showsWhites = true
    var showsColors = true
    let onMirek: (Int) -> Void
    let onColor: (XY) -> Void

    static let whites = [500, 400, 333, 250, 182]
    static let colors: [RGB] = [
        RGB(r: 1, g: 0.18, b: 0.15), RGB(r: 1, g: 0.5, b: 0.1), RGB(r: 1, g: 0.85, b: 0.2),
        RGB(r: 0.3, g: 0.9, b: 0.35), RGB(r: 0.2, g: 0.85, b: 0.9), RGB(r: 0.2, g: 0.4, b: 1),
        RGB(r: 0.6, g: 0.3, b: 1), RGB(r: 1, g: 0.35, b: 0.7),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if showsWhites {
                    ForEach(PaletteStrip.whites, id: \.self) { mirek in
                        dot(ColorMath.rgb(mirek: mirek).color, label: "\(1_000_000 / mirek) kelvin") { onMirek(mirek) }
                    }
                }
                if showsWhites && showsColors {
                    Divider().frame(height: 26)
                }
                if showsColors {
                    ForEach(PaletteStrip.colors, id: \.self) { color in
                        dot(color.color, label: "Color") { onColor(ColorMath.xy(color)) }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func dot(_ color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 38, height: 38)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
