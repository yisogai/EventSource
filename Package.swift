// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EventSource",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "EventSource",
            targets: [
                "EventSource",
            ]),
    ],
    targets: [
        .target(
            name: "EventSource",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]),
        .testTarget(
            name: "EventSourceTests",
            dependencies: ["EventSource"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]),
    ]
)
