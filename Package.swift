// swift-tools-version:6.0
import PackageDescription

/// libghostty: Vendor/GhosttyKit.xcframework, built by scripts/build-ghostty.sh (too big for git).
let ghosttyLinks: [LinkerSetting] = [.linkedFramework("Metal"), .linkedFramework("MetalKit"), .linkedFramework("QuartzCore"), .linkedFramework("CoreText"),
                                      .linkedFramework("CoreGraphics"), .linkedFramework("IOSurface"), .linkedFramework("Carbon"),
                                      .linkedFramework("UniformTypeIdentifiers"), .linkedLibrary("c++")]

let package = Package(
    name: "Kelp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kelp", targets: ["kelp"]),
        .executable(name: "kelpd", targets: ["kelpd"]),
        .executable(name: "KelpApp", targets: ["KelpApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", from: "0.1.20"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
    ],
    targets: [
        .target(name: "Core", resources: [.copy("Resources/extensions.md")]),   // docs/extensions.md links here
        .target(name: "GitKit", dependencies: ["Core"]),
        .target(name: "Agents", dependencies: ["Core"]),
        .target(name: "AgentData", dependencies: ["Core"]),
        .target(name: "Daemon", dependencies: ["Core", "GitKit", "Agents", "Integrations", "AgentData", "LSPKit", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "TerminalKit", dependencies: ["Core", "GhosttyKit"], linkerSettings: ghosttyLinks),
        .executableTarget(name: "kelpd", dependencies: ["Daemon"]),
        .executableTarget(name: "kelp", dependencies: ["Core"]),
        .target(name: "LSPKit", dependencies: ["Core"]),
        .target(name: "WorkbenchKit", dependencies: ["Core"]),
        .target(name: "Integrations", dependencies: ["Core", "GitKit"]),
        .target(name: "Markdown", resources: [.copy("Resources/mermaid.min.js"), .copy("Resources/mermaid-LICENSE.txt")]),   // mermaid 11.17.2, MIT
        .target(name: "EditorKit", dependencies: [.product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                                                 .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")]),
        // The shell, and what an extension is given (`package` declarations): the window, the editor area, tabs, panels.
        .target(name: "KelpKit", dependencies: ["Core", "Agents", "TerminalKit", "EditorKit", "Markdown", "WorkbenchKit",
                                                .product(name: "Sparkle", package: "Sparkle")]),
        // The built-in extensions: each sees only what KelpKit declares `package`, never the shell's own parts, nor another.
        .target(name: "BuiltinAgents", dependencies: ["KelpKit", "Core", "Agents", "TerminalKit", "WorkbenchKit"], path: "Sources/Builtins/Agents"),
        .target(name: "BuiltinFiles", dependencies: ["KelpKit", "Core", "Agents", "EditorKit", "Markdown", "WorkbenchKit"], path: "Sources/Builtins/Files"),
        .target(name: "BuiltinGit", dependencies: ["KelpKit", "Core", "Agents", "EditorKit", "WorkbenchKit"], path: "Sources/Builtins/Git"),
        .target(name: "BuiltinBrowser", dependencies: ["KelpKit", "Core", "Agents", "WorkbenchKit"], path: "Sources/Builtins/Browser"),
        .target(name: "BuiltinIssues", dependencies: ["KelpKit", "Core", "Agents", "WorkbenchKit"], path: "Sources/Builtins/Issues"),
        .target(name: "BuiltinActivity", dependencies: ["KelpKit", "Core", "Agents", "WorkbenchKit"], path: "Sources/Builtins/Activity"),
        .executableTarget(
            name: "KelpApp",
            dependencies: ["KelpKit", "BuiltinAgents", "BuiltinFiles", "BuiltinGit", "BuiltinBrowser", "BuiltinIssues", "BuiltinActivity",
                           "GhosttyKit"],
            // SwiftPM records the deployment target (14.0) as the SDK the app was built with, and AppKit then draws the
            // macOS 14 look (compatibility mode). Naming a current SDK gets the system's own design on macOS 26+.
            // Limit: fixed at 26.0; raise it when a later SDK's look is wanted.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"])]
        ),
        .target(name: "TestSupportC", path: "Tests/TestSupportC"),
        .target(name: "TestSupport", dependencies: ["TestSupportC"], path: "Tests/TestSupport"),
        .testTarget(name: "CoreTests", dependencies: ["Core", "TestSupport"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit", "WorkbenchKit", "TestSupport"]),   // diffs as parsed, then as rows
        .testTarget(name: "AgentsTests", dependencies: ["Agents", "TestSupport"]),
        .testTarget(name: "AgentDataTests", dependencies: ["AgentData", "TestSupport"]),
        // The pinned method and event names: read by the tests from their own folder, not resources.
        .testTarget(name: "DaemonTests", dependencies: ["Daemon", "Agents", "TestSupport"], exclude: ["methods.txt", "events.txt"]),
        .testTarget(name: "LSPKitTests", dependencies: ["LSPKit"]),
        .testTarget(name: "IntegrationsTests", dependencies: ["Integrations", "TestSupport"]),
        .testTarget(name: "MarkdownTests", dependencies: ["Markdown"]),
        .testTarget(name: "WorkbenchKitTests", dependencies: ["WorkbenchKit", "Core", "TestSupport"]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
        .testTarget(name: "ArchitectureTests"),   // reads the sources: the rules in docs/architecture.md
        .testTarget(name: "KelpAppTests", dependencies: ["KelpApp", "KelpKit", "BuiltinAgents", "BuiltinFiles", "BuiltinGit", "BuiltinBrowser", "BuiltinIssues",
                                                  "BuiltinActivity", "Core", "Daemon", "GitKit", "WorkbenchKit", "TestSupport"]),
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
    ]
)
