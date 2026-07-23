// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "BrowserPackages",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserPersistence", targets: ["BrowserPersistence"]),
        .library(name: "BrowserEngine", targets: ["BrowserEngine"]),
        .library(name: "BrowserStore", targets: ["BrowserStore"]),
        .library(name: "BrowserUI", targets: ["BrowserUI"]),
        .library(name: "BrowserTestSupport", targets: ["BrowserTestSupport"]),
    ],
    dependencies: [
        // Sequential, named, individually testable migrations (BROWSER_SPEC 7.2).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.7.1"),
    ],
    targets: [
        .target(name: "BrowserCore", swiftSettings: strict),

        .target(
            name: "BrowserPersistence",
            dependencies: ["BrowserCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),

        .target(name: "BrowserEngine", dependencies: ["BrowserCore"], swiftSettings: strict),

        .target(
            name: "BrowserStore",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserPersistence"],
            swiftSettings: strict
        ),

        .target(
            name: "BrowserUI",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserStore"],
            swiftSettings: strict
        ),

        .target(
            name: "BrowserTestSupport",
            dependencies: ["BrowserCore", "BrowserEngine"],
            swiftSettings: strict
        ),

        // End-to-end: real engine, real database, real HTTP. No fakes.
        .testTarget(
            name: "BrowserE2ETests",
            dependencies: [
                "BrowserCore", "BrowserEngine", "BrowserPersistence", "BrowserStore",
                "BrowserTestSupport",
            ],
            swiftSettings: strict
        ),

        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore", "BrowserTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "BrowserPersistenceTests",
            dependencies: ["BrowserPersistence", "BrowserTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "BrowserEngineTests",
            dependencies: ["BrowserEngine", "BrowserTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "BrowserStoreTests",
            dependencies: ["BrowserStore", "BrowserTestSupport"],
            swiftSettings: strict
        ),
    ]
)
