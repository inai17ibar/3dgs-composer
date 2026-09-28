// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(
        name: "GSComposerCore",
        path: "Sources/GSComposerCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "gscomposer-cli",
        dependencies: ["GSComposerCore"],
        path: "Sources/gscomposer-cli",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "GSComposerCoreTests",
        dependencies: ["GSComposerCore"],
        path: "Tests/GSComposerCoreTests",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "GSComposer",
        dependencies: ["GSComposerCore"],
        path: "Sources/GSComposer",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "GSComposer",
    platforms: [
        .macOS(.v15)
    ],
    targets: targets
)
