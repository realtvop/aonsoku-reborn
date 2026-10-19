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
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "AonsokuKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
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
