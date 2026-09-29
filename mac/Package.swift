// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeybowNotes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KeybowKit", targets: ["KeybowKit"]),
        .library(name: "KeybowStopwatch", targets: ["KeybowStopwatch"]),
        .library(name: "KeybowAI", targets: ["KeybowAI"]),
        .library(name: "KeybowData", targets: ["KeybowData"]),
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
        .target(
            name: "KeybowAI",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Uses Claude, through its module, to write extraction rules.
        .target(
            name: "KeybowData",
            dependencies: ["KeybowKit", "KeybowAI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The list of modules built in, for the app and the command line.
        .target(
            name: "KeybowModules",
            dependencies: ["KeybowKit", "KeybowStopwatch", "KeybowAI", "KeybowData"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "keybow",
            dependencies: ["KeybowKit", "KeybowModules"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KeybowNotesApp",
            dependencies: ["KeybowKit", "KeybowAI", "KeybowModules"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowKitTests",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowDataTests",
            dependencies: ["KeybowData", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowAITests",
            dependencies: ["KeybowAI", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowStopwatchTests",
            dependencies: ["KeybowStopwatch", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
