// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyUsage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MyUsage",
            path: "MyUsage",
            exclude: ["Resources/Info.plist"]
        ),
        .testTarget(
            name: "MyUsageTests",
            dependencies: ["MyUsage"],
            path: "MyUsageTests"
        ),
    ]
)
