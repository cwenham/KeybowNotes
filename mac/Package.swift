// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeybowNotes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KeybowKit", targets: ["KeybowKit"]),
        .library(name: "KeybowStopwatch", targets: ["KeybowStopwatch"]),
        .executable(name: "keybow", targets: ["keybow"]),
        .executable(name: "keybownotes", targets: ["KeybowNotesApp"]),
    ],
    targets: [
        .target(name: "KeybowKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Modules: features built on KeybowKit's module interface alone.
        .target(
            name: "KeybowStopwatch",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The list of modules built in, for the app and the command line.
        .target(
            name: "KeybowModules",
            dependencies: ["KeybowKit", "KeybowStopwatch"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "keybow",
            dependencies: ["KeybowKit", "KeybowModules"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KeybowNotesApp",
            dependencies: ["KeybowKit", "KeybowModules"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowKitTests",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowStopwatchTests",
            dependencies: ["KeybowStopwatch", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
