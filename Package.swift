// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppDowngrader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AppDowngrader",
            path: "Sources",
            resources: [
                .copy("AppIcon.png")
            ]
        )
    ]
)
