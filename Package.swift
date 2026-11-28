// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyUsage",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MyUsage",
            path: "MyUsage",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icns"
            ],
            resources: [
                .copy("Resources/Icons"),
                .copy("Resources/AppIcon.appiconset")
            ]
        ),
        .testTarget(
            name: "MyUsageTests",
            dependencies: ["MyUsage"],
            path: "MyUsageTests"
        ),
    ]
)
