// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "porthole",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "porthole", targets: ["porthole"]),
        .executable(name: "porthole-selftest", targets: ["porthole-selftest"]),
        .library(name: "PortholeCore", targets: ["PortholeCore"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "PortholeCore",
            dependencies: ["CZlib"],
            path: "Sources/PortholeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "porthole-selftest",
            dependencies: ["PortholeCore", "CZlib"],
            path: "Sources/porthole-selftest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "porthole",
            dependencies: ["PortholeCore"],
            path: "Sources/porthole",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
