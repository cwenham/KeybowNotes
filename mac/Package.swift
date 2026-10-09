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
        .library(name: "KeybowLocation", targets: ["KeybowLocation"]),
        .library(name: "KeybowQuotes", targets: ["KeybowQuotes"]),
        .library(name: "KeybowDisplay", targets: ["KeybowDisplay"]),
        .library(name: "KeybowWindows", targets: ["KeybowWindows"]),
        .library(name: "KeybowHome", targets: ["KeybowHome"]),
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
        .target(
            name: "KeybowLocation",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KeybowQuotes",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KeybowDisplay",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KeybowWindows",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "KeybowHome",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The list of modules built in, for the app and the command line.
        .target(
            name: "KeybowModules",
            dependencies: ["KeybowKit", "KeybowStopwatch", "KeybowAI", "KeybowData", "KeybowLocation", "KeybowQuotes",
                           "KeybowDisplay", "KeybowWindows", "KeybowHome"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "keybow",
            dependencies: ["KeybowKit", "KeybowModules"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "KeybowNotesApp",
            dependencies: ["KeybowKit", "KeybowAI", "KeybowLocation", "KeybowModules"],
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
            name: "KeybowWindowsTests",
            dependencies: ["KeybowWindows", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowDisplayTests",
            dependencies: ["KeybowDisplay", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowQuotesTests",
            dependencies: ["KeybowQuotes", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowLocationTests",
            dependencies: ["KeybowLocation", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowAITests",
            dependencies: ["KeybowAI", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowHomeTests",
            dependencies: ["KeybowHome", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowStopwatchTests",
            dependencies: ["KeybowStopwatch", "KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
