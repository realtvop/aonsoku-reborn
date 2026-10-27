// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AonsokuKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(
            name: "AonsokuKit",
            targets: ["AonsokuKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-perception", exact: "2.0.12"),
    ],
    targets: [
        .target(
            name: "AonsokuKit",
            dependencies: [
                "CTailscale",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Perception", package: "swift-perception"),
            ],
            path: "Sources/AonsokuKit",
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedLibrary("resolv")]
        ),
        .binaryTarget(name: "CTailscale", path: "Vendor/CTailscale.xcframework"),
        .testTarget(
            name: "AonsokuKitTests",
            dependencies: [
                "AonsokuKit",
                .product(name: "Perception", package: "swift-perception"),
            ],
            path: "Tests/AonsokuKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
