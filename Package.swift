// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TDS",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "TalosDeployCore",
            targets: ["TalosDeployCore"]
        ),
        .executable(
            name: "tds",
            targets: ["TalosDeployCLI"]
        ),
        .executable(
            name: "tds-app",
            targets: ["TalosDeployApp"]
        ),
    ],
    targets: [
        .target(
            name: "TalosDeployCore",
            resources: [
                .copy("Resources/core_bridge.py"),
            ]
        ),
        .executableTarget(
            name: "TalosDeployCLI",
            dependencies: ["TalosDeployCore"]
        ),
        .executableTarget(
            name: "TalosDeployApp",
            dependencies: ["TalosDeployCore"]
        ),
        .testTarget(
            name: "TalosDeployCoreTests",
            dependencies: ["TalosDeployCore"]
        ),
    ]
)
