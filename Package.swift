// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Macaroon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Macaroon",
            targets: ["Macaroon"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Macaroon",
            path: "Sources/Macaroon",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "MacaroonTests",
            dependencies: ["Macaroon"],
            path: "Tests/MacaroonTests"
        )
    ]
)
