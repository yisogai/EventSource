// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EventSource",
    platforms: [
        .iOS(.v15),
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
            path: "EventSource"),
    ]
)
