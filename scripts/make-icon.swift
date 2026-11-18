// Draws the app icon: a warm glow on a dark field. Run: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let background = CGGradient(
    colorsSpace: space, colors: [color(0.13, 0.10, 0.20), color(0.04, 0.03, 0.07)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    background, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

let center = CGPoint(x: size / 2, y: size / 2)
let glow = CGGradient(
    colorsSpace: space,
    colors: [color(1.0, 0.86, 0.55, 0.95), color(1.0, 0.62, 0.20, 0.55), color(1.0, 0.45, 0.15, 0.0)] as CFArray,
    locations: [0, 0.38, 1])!
context.drawRadialGradient(
    glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 470, options: [])

let core = CGGradient(
    colorsSpace: space, colors: [color(1.0, 0.98, 0.90), color(1.0, 0.80, 0.42)] as CFArray, locations: [0, 1])!
context.saveGState()
context.addEllipse(in: CGRect(x: center.x - 170, y: center.y - 170, width: 340, height: 340))
context.clip()
context.drawRadialGradient(
    core, startCenter: CGPoint(x: center.x - 40, y: center.y + 50), startRadius: 0, endCenter: center,
    endRadius: 200, options: [.drawsAfterEndLocation])
context.restoreGState()

let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
