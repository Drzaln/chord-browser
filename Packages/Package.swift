// swift-tools-version: 6.0
import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "ChordPackages",
    // 15.4 is the hard floor (BROWSER_SPEC 2), set by WKWebExtension
    // availability. Matching it here — rather than .v15 (15.0) — lets M7 use the
    // extension API without scattering `if #available`, per §7.3.
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "ChordCore", targets: ["ChordCore"]),
        .library(name: "ChordLogging", targets: ["ChordLogging"]),
        .library(name: "ChordCrypto", targets: ["ChordCrypto"]),
        .library(name: "ChordPersistence", targets: ["ChordPersistence"]),
        .library(name: "ChordEngine", targets: ["ChordEngine"]),
        .library(name: "ChordExtensions", targets: ["ChordExtensions"]),
        .library(name: "ChordStore", targets: ["ChordStore"]),
        .library(name: "ChordUI", targets: ["ChordUI"]),
        .library(name: "ChordSecrets", targets: ["ChordSecrets"]),
        .library(name: "ChordTestSupport", targets: ["ChordTestSupport"]),
    ],
    dependencies: [
        // Sequential, named, individually testable migrations (BROWSER_SPEC 7.2).
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.7.1"),
    ],
    targets: [
        .target(name: "ChordCore", swiftSettings: strict),

        // The one logging sink (BROWSER_SPEC 3.7): mirrors every line to
        // os.Logger and, once installed, to a rotating file. Sits beside Core
        // at the bottom of the dependency tree — no app package imports it,
        // every package that logs does. Foundation + os only, like Core.
        .target(name: "ChordLogging", swiftSettings: strict),

        .target(
            name: "ChordPersistence",
            dependencies: ["ChordCore", "ChordLogging", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),

        .target(
            name: "ChordEngine",
            dependencies: ["ChordCore", "ChordLogging"],
            resources: [.process("Resources/seed-blocklist.txt")],
            swiftSettings: strict
        ),

        // WebKit-extension host (M7). The second WebKit importer after Engine;
        // §7.1 was amended to "the engine layer is the WebKit boundary." No
        // WK* type reaches Store/UI — it talks to them through ExtensionHost
        // and the engine's opaque ExtensionControllerHandle. See ADR 011.
        .target(
            name: "ChordExtensions",
            dependencies: ["ChordCore", "ChordCrypto", "ChordEngine", "ChordLogging"],
            swiftSettings: strict
        ),

        // Extension-bundle signature verification (M7.5f). The ONLY Security/
        // CryptoKit importer besides ChordSecrets — same one-OS-framework-per-
        // target rule (ADR 011). ChordExtensions depends on it so the
        // installer can stamp a verdict on every bundle it accepts.
        .target(
            name: "ChordCrypto",
            dependencies: ["ChordCore"],
            swiftSettings: strict
        ),

        // The password vault's secret half (V1). The ONLY importer of Security /
        // LocalAuthentication — the same "one target per OS-framework boundary"
        // rule that gave ChordExtensions its own target (ADR 011). No secret
        // reaches SQLite, and no Keychain type leaves this package.
        .target(
            name: "ChordSecrets",
            dependencies: ["ChordCore"],
            swiftSettings: strict
        ),

        .target(
            name: "ChordStore",
            dependencies: [
                "ChordCore", "ChordEngine", "ChordExtensions", "ChordPersistence",
                "ChordSecrets", "ChordLogging",
            ],
            swiftSettings: strict
        ),

        .target(
            name: "ChordUI",
            dependencies: ["ChordCore", "ChordEngine", "ChordExtensions", "ChordStore", "ChordLogging"],
            swiftSettings: strict
        ),

        .target(
            name: "ChordTestSupport",
            // Store, for the single-window conveniences in
            // `TabStore+SingleWindow`. Nothing in Sources depends on this target
            // — only the test targets do — so this adds no cycle.
            dependencies: ["ChordCore", "ChordEngine", "ChordStore"],
            swiftSettings: strict
        ),

        // End-to-end: real engine, real database, real HTTP. No fakes.
        .testTarget(
            name: "ChordE2ETests",
            dependencies: [
                "ChordCore", "ChordEngine", "ChordPersistence", "ChordStore",
                "ChordTestSupport",
            ],
            swiftSettings: strict
        ),

        .testTarget(
            name: "ChordCoreTests",
            dependencies: ["ChordCore", "ChordTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ChordPersistenceTests",
            dependencies: ["ChordPersistence", "ChordTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ChordEngineTests",
            dependencies: ["ChordEngine", "ChordTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ChordExtensionsTests",
            dependencies: ["ChordExtensions", "ChordTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ChordUITests",
            dependencies: ["ChordUI", "ChordTestSupport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ChordSecretsTests",
            dependencies: ["ChordSecrets", "ChordCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ChordLoggingTests",
            dependencies: ["ChordLogging"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "ChordStoreTests",
            dependencies: ["ChordStore", "ChordSecrets", "ChordTestSupport"],
            swiftSettings: strict
        ),
    ]
)
