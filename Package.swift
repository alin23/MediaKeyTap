// swift-tools-version:5.1

import PackageDescription

let package = Package(
    name: "MediaKeyTap",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "MediaKeyTap", targets: ["MediaKeyTap"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics", from: "1.0.2"),
    ],
    targets: [
        .target(name: "MediaKeyTap", dependencies: [
            .product(name: "Atomics", package: "swift-atomics"),
        ], path: "MediaKeyTap"),
    ]
)
