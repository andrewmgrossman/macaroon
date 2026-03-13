// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RoonController",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Macaroon",
            targets: ["RoonControllerApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "RoonControllerApp",
            path: "Sources/RoonControllerApp",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "RoonControllerTests",
            dependencies: ["RoonControllerApp"],
            path: "Tests/RoonControllerTests"
        )
    ]
)
