import HueKit
import SwiftUI

@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)

    static func tap() { light.impactOccurred() }
    static func click() { rigid.impactOccurred() }
}

extension View {
    /// Liquid Glass on iOS 26 and later, a thin material with a light edge before that.
    @ViewBuilder
    func glass(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// The small uppercase, tracked label Vero uses over sections.
    func sectionLabel(_ color: Color = .white.opacity(0.6)) -> some View {
        font(.system(size: 13, weight: .bold)).tracking(1).textCase(.uppercase).foregroundStyle(color)
    }
}

/// A surface that fills with the light's color up to its brightness. Dragging sideways
/// anywhere on it changes the value relative to where it was, so a touch never makes the
/// lights jump. A tap calls `onTap`.
struct BrightnessSurface<Content: View>: View {
    /// 0...100 as the store reports it.
    let value: Double
    let isOn: Bool
    let tint: Color
    /// False for on/off devices: the surface is full when on and does not drag.
    var isDimmable = true
    var accessibilityName = "Brightness"
    let onChange: (Double) -> Void
    var onTap: (() -> Void)?
    @ViewBuilder let content: (Double) -> Content

    @State private var dragStart: Double?
    @State private var dragValue: Double?
    @State private var isSideways: Bool?

    var body: some View {
        // A light can be on at 0, its lowest level; that still reads as on.
        let shown = isDimmable ? dragValue ?? (isOn ? max(value, 1) : 0) : (isOn ? 100 : 0)
        GeometryReader { proxy in
            let fill = max(0, proxy.size.width * shown / 100)
            ZStack(alignment: .leading) {
                Rectangle().fill(tint.opacity(0.42)).frame(width: fill)
                if shown > 0, shown < 100 {
                    Rectangle().fill(tint.opacity(0.95)).frame(width: 2).offset(x: max(0, fill - 2))
                }
                content(shown).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(.rect)
            .onTapGesture { onTap?() }
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
                    },
                including: isDimmable ? .all : .subviews
            )
        }
        .animation(dragValue == nil ? .snappy(duration: 0.22) : nil, value: shown)
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isDimmable ? (shown >= 1 ? "\(Int(shown.rounded())) percent" : "Off") : (isOn ? "On" : "Off"))
        .accessibilityAction { onTap?() }
        .accessibilityAdjustableAction { direction in
            guard isDimmable else { return }
            let current = isOn ? value : 0
            onChange(min(max(current + (direction == .increment ? 10 : -10), 0), 100))
        }
    }
}

/// A capsule brightness bar, for a room's detail screen and for single lights.
struct BrightnessBar: View {
    let value: Double
    let isOn: Bool
    let tint: Color
    var height: CGFloat = 46
    let onChange: (Double) -> Void

    var body: some View {
        BrightnessSurface(value: value, isOn: isOn, tint: tint, onChange: onChange) { shown in
            HStack {
                Image(systemName: shown >= 1 ? "sun.max.fill" : "sun.min")
                Spacer()
                Text(shown >= 1 ? "\(Int(shown.rounded()))%" : "Off").monospacedDigit()
                    .contentTransition(.identity)
            }
            .font(.system(size: 15, weight: .bold))
            .padding(.horizontal, 16)
        }
        .frame(height: height)
        .background(.white.opacity(0.08))
        .clipShape(.capsule)
    }
}

struct PowerButton: View {
    let isOn: Bool
    let tint: Color
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: "power")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isOn ? Color.black : Color.white)
                .frame(width: size, height: size)
                .background(isOn ? tint : Color.white.opacity(0.10), in: .circle)
                .shadow(color: isOn ? tint.opacity(0.7) : .clear, radius: 10)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Turn off" : "Turn on")
    }
}

extension LightScene {
    var swatch: AnyShapeStyle {
        let colors = swatches.map(\.color)
        switch colors.count {
        case 0: return AnyShapeStyle(Color.glow)
        case 1: return AnyShapeStyle(colors[0])
        default: return AnyShapeStyle(AngularGradient(colors: colors + [colors[0]], center: .center))
        }
    }
}

/// A scene as a round swatch with its name under it; the active one has a teal ring.
struct SceneDot: View {
    let scene: LightScene
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(scene.swatch)
                    .frame(width: 48, height: 48)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                    .padding(4)
                    .overlay {
                        if scene.isActive { Circle().strokeBorder(Color.vero, lineWidth: 2) }
                    }
                Text(scene.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(scene.isActive ? Color.vero : .white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scene.name)
        .accessibilityAddTraits(scene.isActive ? .isSelected : [])
    }
}

/// A scene as a glass pill with a swatch, for the detail screen.
struct SceneChip: View {
    let scene: LightScene
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(scene.swatch).frame(width: 30, height: 30)
                Text(scene.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 42)
            .background(.white.opacity(0.07), in: .capsule)
            .overlay(Capsule().strokeBorder(scene.isActive ? Color.vero : .white.opacity(0.12), lineWidth: scene.isActive ? 2 : 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scene.isActive ? .isSelected : [])
    }
}

/// One light as a pill that switches it; teal while it is on.
struct LightChip: View {
    let light: Light
    let isReachable: Bool
    let action: () -> Void

    var body: some View {
        let on = light.isOn && isReachable
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 7) {
                Circle().fill(on ? Color.vero : .white.opacity(0.35)).frame(width: 8, height: 8)
                Text(light.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(on ? Color.vero.opacity(0.14) : .white.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(on ? Color.vero.opacity(0.6) : .white.opacity(0.10), lineWidth: 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
        .opacity(isReachable ? 1 : 0.5)
        .accessibilityLabel(isReachable ? light.name : "\(light.name), unreachable")
        .accessibilityValue(light.isOn ? "On" : "Off")
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
                    Capsule().fill(.white.opacity(0.15)).frame(width: 1, height: 26)
                }
                if showsColors {
                    ForEach(PaletteStrip.colors, id: \.self) { color in
                        dot(color.color, label: "Color") { onColor(ColorMath.xy(color)) }
                    }
                }
            }
            .padding(2)
        }
    }

    private func dot(_ color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 40, height: 40)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Soft patches of each lit room's color behind the glass; they dim with the room.
struct AmbientGlow: View {
    struct Spot: Equatable {
        var color: Color
        var opacity: Double
    }

    let spots: [Spot]

    /// Where each spot sits, as fractions of the screen, and how wide it is.
    private static let places: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (0.15, 0.08, 300), (0.85, 0.30, 320), (0.10, 0.55, 260), (0.90, 0.75, 240), (0.40, 0.95, 260),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(spots.indices, id: \.self) { index in
                    let place = Self.places[index % Self.places.count]
                    Circle()
                        .fill(spots[index].color)
                        .frame(width: place.size, height: place.size)
                        .position(x: proxy.size.width * place.x, y: proxy.size.height * place.y)
                        .opacity(spots[index].opacity)
                }
            }
            .blur(radius: 70)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.4), value: spots)
    }
}
