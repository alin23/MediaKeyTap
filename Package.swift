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
    targets: [
        .target(name: "MediaKeyTap", path: "MediaKeyTap"),
    ]
)
