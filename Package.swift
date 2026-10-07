// swift-tools-version: 6.2
import PackageDescription

// NOTE: Only Command Line Tools are installed. SwiftUI's @State / #Preview macros,
// XCTest and swift-testing are NOT available. Use ObservableObject + @ObservedObject /
// @Binding / @AppStorage in SwiftUI, and the *Checks executables for tests.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "NoteBar",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "NoteBar", targets: ["NoteBar"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Shared models + contracts. Every other module depends only on this (plus system frameworks).
        .target(name: "NoteBarCore", swiftSettings: v5),
        .target(name: "NoteBarStore", dependencies: ["NoteBarCore", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: v5),
        .target(name: "NoteBarPanel", dependencies: ["NoteBarCore"], swiftSettings: v5),
        .target(name: "NoteBarEditor", dependencies: ["NoteBarCore"], swiftSettings: v5),
        .target(name: "NoteBarUI", dependencies: ["NoteBarCore"], swiftSettings: v5),
        .target(name: "NoteBarIntegrations", dependencies: ["NoteBarCore"], swiftSettings: v5),
        .target(name: "NoteBarSettings", dependencies: ["NoteBarCore"], swiftSettings: v5),
        .executableTarget(
            name: "NoteBar",
            dependencies: ["NoteBarCore", "NoteBarStore", "NoteBarPanel", "NoteBarEditor",
                           "NoteBarUI", "NoteBarIntegrations", "NoteBarSettings"],
            swiftSettings: v5
        ),
        // Test runners (no XCTest available): `swift run CoreChecks` etc. Exit code != 0 on failure.
        .executableTarget(name: "CoreChecks", dependencies: ["NoteBarCore"], swiftSettings: v5),
        .executableTarget(name: "StoreChecks", dependencies: ["NoteBarCore", "NoteBarStore"], swiftSettings: v5),
        .executableTarget(name: "EditorChecks", dependencies: ["NoteBarCore", "NoteBarEditor"], swiftSettings: v5),
        // Renders NoteBarUI offscreen to PNG files for visual checks: `swift run UISnapshot /tmp/out`
        .executableTarget(name: "UISnapshot", dependencies: ["NoteBarCore", "NoteBarUI"], swiftSettings: v5),
        // Renders the Settings window offscreen to PNG: `swift run SettingsSnapshot /tmp/out`
        .executableTarget(name: "SettingsSnapshot", dependencies: ["NoteBarCore", "NoteBarSettings"], swiftSettings: v5),
    ]
)
