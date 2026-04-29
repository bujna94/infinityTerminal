// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InfinityTerminal",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "InfinityTerminal",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/InfinityTerminal",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/appLogo.png"),
            ]
        ),
    ]
)
