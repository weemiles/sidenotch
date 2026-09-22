// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SideNotch",
            path: "Sources/SideNotch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
