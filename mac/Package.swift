// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeybowNotes",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KeybowKit", targets: ["KeybowKit"]),
        .executable(name: "keybow", targets: ["keybow"]),
    ],
    targets: [
        .target(name: "KeybowKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "keybow",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeybowKitTests",
            dependencies: ["KeybowKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
