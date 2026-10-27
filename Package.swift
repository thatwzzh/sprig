// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sprig",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sprig", targets: ["Sprig"]),
        .library(name: "SprigCore", targets: ["SprigCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
    ],
    targets: [
        .target(name: "SprigCore"),
        .executableTarget(
            name: "Sprig",
            dependencies: ["SprigCore", "KeyboardShortcuts"]
        ),
        .testTarget(name: "SprigCoreTests", dependencies: ["SprigCore"]),
    ],
    swiftLanguageModes: [.v5]
)
