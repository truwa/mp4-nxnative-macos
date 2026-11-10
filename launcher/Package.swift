// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MP4Launcher",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MP4Launcher",
            path: "Sources/MP4Launcher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
