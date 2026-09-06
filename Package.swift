// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "mytight",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mytight", targets: ["mytight"]),
        .executable(name: "mytight-selftest", targets: ["mytight-selftest"]),
        .library(name: "MyTightCore", targets: ["MyTightCore"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "MyTightCore",
            dependencies: ["CZlib"],
            path: "Sources/MyTightCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mytight-selftest",
            dependencies: ["MyTightCore", "CZlib"],
            path: "Sources/mytight-selftest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mytight",
            dependencies: ["MyTightCore"],
            path: "Sources/mytight",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
