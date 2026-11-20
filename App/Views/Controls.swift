import HueKit
import SwiftUI
import UIKit

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
    var isEnabled = true
    var accessibilityName = "Brightness"
    let onChange: (Double) -> Void
    var onTap: (() -> Void)?
    @ViewBuilder let content: (Double) -> Content

    @State private var dragStart: Double?
    @State private var dragValue: Double?
    @State private var dragBaseX: CGFloat?
    @State private var lastSentStep: Int?

    var body: some View {
        // A light can be on at 0, its lowest level; that still reads as on.
        let shown = isDimmable ? dragValue ?? (isOn ? max(value, 1) : 0) : (isOn ? 100 : 0)
        let isDragging = dragValue != nil
        GeometryReader { proxy in
            let fill = max(0, proxy.size.width * shown / 100)
            ZStack(alignment: .leading) {
                Group {
                    LinearGradient(
                        colors: [tint.opacity(0.24), tint.opacity(0.46)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: fill)
                    if shown > 0, shown < 100 {
                        Rectangle()
                            .fill(tint.opacity(isDragging ? 0.95 : 0.52))
                            .frame(width: 1.5)
                            .offset(x: max(0, fill - 1.5))
                    }
                }
                .animation(isDragging ? nil : .snappy(duration: 0.22), value: shown)

                content(shown).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .contentShape(.rect)
            .overlay {
                HorizontalDragOverlay(
                    allowsDrag: isDimmable && isEnabled,
                    onTap: onTap,
                    onDragChanged: { translationX in
                        guard proxy.size.width > 0 else { return }
                        if dragBaseX == nil {
                            dragBaseX = translationX
                            dragStart = isOn ? max(value, 1) : 0
                            lastSentStep = nil
                        }
                        let start = dragStart ?? 0
                        let delta = translationX - (dragBaseX ?? 0)
                        let next = min(max(start + delta / proxy.size.width * 100, 0), 100)
                        let step = next < 0.5 ? 0 : min(max(Int(next.rounded()), 1), 100)
                        if step != lastSentStep {
                            if step == 0 || step == 100 { Haptics.click() }
                            lastSentStep = step
                            onChange(Double(step))
                        }
                        dragValue = next
                    },
                    onDragEnded: {
                        dragStart = nil
                        dragValue = nil
                        dragBaseX = nil
                        lastSentStep = nil
                    }
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isDimmable ? (shown >= 1 ? "\(Int(shown.rounded())) percent" : "Off") : (isOn ? "On" : "Off"))
        .modifier(ConditionalTapAction(onTap: onTap))
        .accessibilityAdjustableAction { direction in
            guard isDimmable, isEnabled else { return }
            let current = isOn ? value : 0
            onChange(min(max(current + (direction == .increment ? 10 : -10), 0), 100))
        }
    }
}

private struct ConditionalTapAction: ViewModifier {
    let onTap: (() -> Void)?

    func body(content: Content) -> some View {
        if let onTap {
            content.accessibilityAction { onTap() }
        } else {
            content
        }
    }
}

/// UIKit-backed horizontal pan + tap overlay so sideways dimming locks cleanly against a vertical ScrollView
/// and cancels/resets reliably if interrupted.
private struct HorizontalDragOverlay: UIViewRepresentable {
    let allowsDrag: Bool
    let onTap: (() -> Void)?
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onDragChanged: onDragChanged, onDragEnded: onDragEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.require(toFail: pan)

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        context.coordinator.pan = pan
        context.coordinator.tap = tap
        updateRecognizerState(coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onDragChanged = onDragChanged
        context.coordinator.onDragEnded = onDragEnded
        updateRecognizerState(coordinator: context.coordinator)
    }

    private func updateRecognizerState(coordinator: Coordinator) {
        coordinator.pan?.isEnabled = allowsDrag
        coordinator.tap?.isEnabled = onTap != nil
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (() -> Void)?
        var onDragChanged: (CGFloat) -> Void
        var onDragEnded: () -> Void
        weak var pan: UIPanGestureRecognizer?
        weak var tap: UITapGestureRecognizer?

        init(
            onTap: (() -> Void)?,
            onDragChanged: @escaping (CGFloat) -> Void,
            onDragEnded: @escaping () -> Void
        ) {
            self.onTap = onTap
            self.onDragChanged = onDragChanged
            self.onDragEnded = onDragEnded
        }

        @objc func handleTap() {
            onTap?()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onDragChanged(recognizer.translation(in: recognizer.view).x)
            case .ended, .cancelled, .failed:
                onDragEnded()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === pan, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let translation = pan.translation(in: pan.view)
            let velocity = pan.velocity(in: pan.view)
            let dx = abs(translation.x) > 0 || abs(translation.y) > 0 ? abs(translation.x) : abs(velocity.x)
            let dy = abs(translation.x) > 0 || abs(translation.y) > 0 ? abs(translation.y) : abs(velocity.y)
            return dx > dy * 1.15
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === pan && otherGestureRecognizer.view is UIScrollView
        }
    }
}

/// A capsule brightness bar, for a room's detail screen and for single lights.
struct BrightnessBar: View {
    let value: Double
    let isOn: Bool
    let tint: Color
    var height: CGFloat = 46
    var isEnabled = true
    var accessibilityName = "Brightness"
    let onChange: (Double) -> Void

    var body: some View {
        BrightnessSurface(
            value: value,
            isOn: isOn,
            tint: tint,
            isEnabled: isEnabled,
            accessibilityName: accessibilityName,
            onChange: onChange
        ) { shown in
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

/// A scene as a round swatch with its name under it; the active one has a teal ring.
struct SceneDot: View {
    let scene: LightScene
    var isActive: Bool?
    let action: () -> Void

    private var active: Bool { isActive ?? scene.isActive }

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
                        if active { Circle().strokeBorder(Color.vero, lineWidth: 2) }
                    }
                Text(scene.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color.vero : .white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(scene.name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A scene as a glass pill with a swatch, for the detail screen.
struct SceneChip: View {
    let scene: LightScene
    var isActive: Bool?
    let action: () -> Void

    private var active: Bool { isActive ?? scene.isActive }

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
            .overlay(Capsule().strokeBorder(active ? Color.vero : .white.opacity(0.12), lineWidth: active ? 2 : 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// One light as a pill that switches it; tinted with the light's color while it is on.
struct LightChip: View {
    let light: Light
    let isReachable: Bool
    let action: () -> Void

    var body: some View {
        let on = light.isOn && isReachable
        let dotColor = light.displayColor.color
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(on ? dotColor : .white.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .shadow(color: on ? dotColor.opacity(0.6) : .clear, radius: 4)
                Text(light.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(on ? dotColor.opacity(0.14) : .white.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(on ? dotColor.opacity(0.55) : .white.opacity(0.10), lineWidth: 1))
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
    var mirekRange: ClosedRange<Int>? = nil
    var selectedMirek: Int? = nil
    var selectedColor: XY? = nil
    var horizontalPadding: CGFloat = 0
    let onMirek: (Int) -> Void
    let onColor: (XY) -> Void

    static let whites = [500, 400, 333, 250, 182]
    static let colors: [(name: String, rgb: RGB)] = [
        ("Red", RGB(r: 1, g: 0.18, b: 0.15)),
        ("Orange", RGB(r: 1, g: 0.5, b: 0.1)),
        ("Amber", RGB(r: 1, g: 0.85, b: 0.2)),
        ("Green", RGB(r: 0.3, g: 0.9, b: 0.35)),
        ("Cyan", RGB(r: 0.2, g: 0.85, b: 0.9)),
        ("Blue", RGB(r: 0.2, g: 0.4, b: 1)),
        ("Violet", RGB(r: 0.6, g: 0.3, b: 1)),
        ("Pink", RGB(r: 1, g: 0.35, b: 0.7)),
    ]

    private var availableWhites: [Int] {
        guard let range = mirekRange else { return Self.whites }
        var seen = Set<Int>()
        return Self.whites.compactMap { mirek in
            let clamped = min(max(mirek, range.lowerBound), range.upperBound)
            return seen.insert(clamped).inserted ? clamped : nil
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if showsWhites {
                    ForEach(availableWhites, id: \.self) { mirek in
                        let isSelected = selectedMirek.map { abs($0 - mirek) <= 12 } ?? false
                        dot(ColorMath.rgb(mirek: mirek).color, label: "\(1_000_000 / mirek) kelvin", isSelected: isSelected) {
                            onMirek(mirek)
                        }
                    }
                }
                if showsWhites && showsColors && !availableWhites.isEmpty {
                    Capsule().fill(.white.opacity(0.15)).frame(width: 1, height: 26)
                }
                if showsColors {
                    ForEach(PaletteStrip.colors, id: \.name) { entry in
                        let xy = ColorMath.xy(entry.rgb)
                        let isSelected = selectedMirek == nil
                            && (selectedColor.map { hypot($0.x - xy.x, $0.y - xy.y) < 0.04 } ?? false)
                        dot(entry.rgb.color, label: entry.name, isSelected: isSelected) {
                            onColor(xy)
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 3)
        }
    }

    private func dot(_ color: Color, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 38, height: 38)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .padding(3)
                .overlay {
                    if isSelected { Circle().strokeBorder(Color.vero, lineWidth: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
