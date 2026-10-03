// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AonsokuCapacitorNative",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "AonsokuCapacitorNative",
            targets: ["AonsokuNativePlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "AonsokuNativePlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "ios/Sources/AonsokuNativePlugin"),
        .testTarget(
            name: "AonsokuNativePluginTests",
            dependencies: ["AonsokuNativePlugin"],
            path: "ios/Tests/AonsokuNativePluginTests")
    ]
)
