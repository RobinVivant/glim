// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HueKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HueKit", targets: ["HueKit"]),
        .executable(name: "huectl", targets: ["huectl"]),
    ],
    targets: [
        .target(name: "HueKit"),
        .executableTarget(name: "huectl", dependencies: ["HueKit"]),
        .testTarget(name: "HueKitTests", dependencies: ["HueKit"]),
    ]
)
