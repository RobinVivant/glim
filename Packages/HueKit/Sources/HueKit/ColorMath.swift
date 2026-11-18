import Foundation

/// CIE xy chromaticity, the color format the bridge speaks.
public struct XY: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Display color in sRGB, each channel 0...1.
public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

public enum ColorMath {
    /// The full-brightness sRGB color for a chromaticity (Philips wide-gamut D65 conversion).
    public static func rgb(_ xy: XY) -> RGB {
        guard xy.y > 0 else { return RGB(r: 1, g: 1, b: 1) }
        let bigY = 1.0
        let bigX = bigY / xy.y * xy.x
        let bigZ = bigY / xy.y * (1 - xy.x - xy.y)
        var r = bigX * 1.656492 - bigY * 0.354851 - bigZ * 0.255038
        var g = -bigX * 0.707196 + bigY * 1.655397 + bigZ * 0.036152
        var b = bigX * 0.051713 - bigY * 0.121364 + bigZ * 1.011530
        r = max(r, 0)
        g = max(g, 0)
        b = max(b, 0)
        let peak = max(r, g, b)
        if peak > 0 {
            r /= peak
            g /= peak
            b /= peak
        }
        return RGB(r: gamma(r), g: gamma(g), b: gamma(b))
    }

    public static func xy(_ rgb: RGB) -> XY {
        let r = linear(rgb.r)
        let g = linear(rgb.g)
        let b = linear(rgb.b)
        let bigX = r * 0.664511 + g * 0.154324 + b * 0.162028
        let bigY = r * 0.283881 + g * 0.668433 + b * 0.047685
        let bigZ = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = bigX + bigY + bigZ
        guard sum > 0 else { return XY(x: 0.3127, y: 0.3290) }
        return XY(x: bigX / sum, y: bigY / sum)
    }

    /// Approximate sRGB color of a white point given in mirek (1,000,000 / kelvin).
    public static func rgb(mirek: Int) -> RGB {
        let kelvin = 1_000_000.0 / Double(max(mirek, 1))
        let t = min(max(kelvin, 1000), 40000) / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        // Blended toward white: a lamp at 2200 K reads as soft amber on screen, not saturated orange.
        func unit(_ value: Double) -> Double { 0.42 + 0.58 * min(max(value, 0), 255) / 255 }
        return RGB(r: unit(r), g: unit(g), b: unit(b))
    }

    public static func average(_ colors: [RGB]) -> RGB? {
        guard !colors.isEmpty else { return nil }
        let count = Double(colors.count)
        return RGB(
            r: colors.reduce(0) { $0 + $1.r } / count,
            g: colors.reduce(0) { $0 + $1.g } / count,
            b: colors.reduce(0) { $0 + $1.b } / count
        )
    }

    private static func gamma(_ value: Double) -> Double {
        value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func linear(_ value: Double) -> Double {
        value > 0.04045 ? pow((value + 0.055) / 1.055, 2.4) : value / 12.92
    }
}
