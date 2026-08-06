// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "BrowserPackages",
    // 15.4 is the hard floor (BROWSER_SPEC 2), set by WKWebExtension
    // availability. Matching it here — rather than .v15 (15.0) — lets M7 use the
    // extension API without scattering `if #available`, per §7.3.
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserLogging", targets: ["BrowserLogging"]),
        .library(name: "BrowserPersistence", targets: ["BrowserPersistence"]),
        .library(name: "BrowserEngine", targets: ["BrowserEngine"]),
        .library(name: "BrowserExtensions", targets: ["BrowserExtensions"]),
        .library(name: "BrowserStore", targets: ["BrowserStore"]),
        .library(name: "BrowserUI", targets: ["BrowserUI"]),
        .library(name: "BrowserSecrets", targets: ["BrowserSecrets"]),
        .library(name: "BrowserTestSupport", targets: ["BrowserTestSupport"]),
    ],
    dependencies: [
        // Sequential, named, individually testable migrations (BROWSER_SPEC 7.2).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.7.1"),
    ],
    targets: [
        .target(name: "BrowserCore", swiftSettings: strict),

        // The one logging sink (BROWSER_SPEC 3.7): mirrors every line to
        // os.Logger and, once installed, to a rotating file. Sits beside Core
        // at the bottom of the dependency tree — no app package imports it,
        // every package that logs does. Foundation + os only, like Core.
        .target(name: "BrowserLogging", swiftSettings: strict),

        .target(
            name: "BrowserPersistence",
            dependencies: ["BrowserCore", "BrowserLogging", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),

        .target(
            name: "BrowserEngine",
            dependencies: ["BrowserCore", "BrowserLogging"],
            resources: [.process("Resources/seed-blocklist.txt")],
            swiftSettings: strict
        ),

        // WebKit-extension host (M7). The second WebKit importer after Engine;
        // §7.1 was amended to "the engine layer is the WebKit boundary." No
        // WK* type reaches Store/UI — it talks to them through ExtensionHost
        // and the engine's opaque ExtensionControllerHandle. See ADR 011.
        .target(
            name: "BrowserExtensions",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserLogging"],
            swiftSettings: strict
        ),

        // The password vault's secret half (V1). The ONLY importer of Security /
        // LocalAuthentication — the same "one target per OS-framework boundary"
        // rule that gave BrowserExtensions its own target (ADR 011). No secret
        // reaches SQLite, and no Keychain type leaves this package.
        .target(
            name: "BrowserSecrets",
            dependencies: ["BrowserCore"],
            swiftSettings: strict
        ),

        .target(
            name: "BrowserStore",
            dependencies: [
                "BrowserCore", "BrowserEngine", "BrowserExtensions", "BrowserPersistence",
                "BrowserSecrets", "BrowserLogging",
            ],
            swiftSettings: strict
        ),

        .target(
            name: "BrowserUI",
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserExtensions", "BrowserStore", "BrowserLogging"],
            swiftSettings: strict
        ),

        .target(
            name: "BrowserTestSupport",
            // Store, for the single-window conveniences in
            // `TabStore+SingleWindow`. Nothing in Sources depends on this target
            // — only the test targets do — so this adds no cycle.
            dependencies: ["BrowserCore", "BrowserEngine", "BrowserStore"],
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
            name: "BrowserExtensionsTests",
            dependencies: ["BrowserExtensions", "BrowserTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "BrowserUITests",
            dependencies: ["BrowserUI", "BrowserTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "BrowserSecretsTests",
            dependencies: ["BrowserSecrets", "BrowserCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "BrowserLoggingTests",
            dependencies: ["BrowserLogging"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "BrowserStoreTests",
            dependencies: ["BrowserStore", "BrowserSecrets", "BrowserTestSupport"],
            swiftSettings: strict
        ),
    ]
)
