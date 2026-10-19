// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AonsokuKit",
    platforms: [.iOS(.v26)],
    products: [
        .library(
            name: "AonsokuKit",
            targets: ["AonsokuKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "AonsokuKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/AonsokuKit"
        ),
        .testTarget(
            name: "AonsokuKitTests",
            dependencies: ["AonsokuKit"],
            path: "Tests/AonsokuKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
