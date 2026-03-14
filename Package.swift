// swift-tools-version: 6.2
import PackageDescription
import Foundation

var macaroonSwiftSettings: [SwiftSetting] = []
if let rawValue = ProcessInfo.processInfo.environment["MACAROON_DEBUG_LOGGING"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased(),
   rawValue == "1" || rawValue == "true" || rawValue == "yes" {
    macaroonSwiftSettings.append(.define("MACAROON_DEBUG_LOGGING"))
}

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
            ],
            swiftSettings: macaroonSwiftSettings
        ),
        .testTarget(
            name: "MacaroonTests",
            dependencies: ["Macaroon"],
            path: "Tests/MacaroonTests",
            swiftSettings: macaroonSwiftSettings
        )
    ]
)
