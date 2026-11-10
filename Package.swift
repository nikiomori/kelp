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
        .executable(name: "kelp-vm", targets: ["KelpVM"]),
        .executable(name: "KelpGuest", targets: ["KelpGuest"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", from: "0.1.20"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.25.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.9.0"),
        // Postgres and MySQL spoken by kelpd itself: no psql or mysql needed on the Mac
        .package(url: "https://github.com/vapor/postgres-nio", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio", from: "1.7.0"),
    ],
    targets: [
        .target(name: "Core", resources: [.copy("Resources/extensions.md"), .copy("Resources/rpc.json"),   // docs link to both
                                          // iOS machines' runner, an Xcode project of its own (IOSRunner)
                                          .copy("Resources/runner-pbxproj.txt"), .copy("Resources/runner-scheme.txt"),
                                          .copy("Resources/runner-app.txt"), .copy("Resources/runner-runner.txt")]),
        .target(name: "GitKit", dependencies: ["Core"]),
        .target(name: "Agents", dependencies: ["Core"]),
        .target(name: "AgentData", dependencies: ["Core"]),
        .target(name: "Daemon", dependencies: ["Core", "GitKit", "Agents", "Integrations", "AgentData", "LSPKit", .product(name: "GRDB", package: "GRDB.swift"),
                                               .product(name: "PostgresNIO", package: "postgres-nio"), .product(name: "MySQLNIO", package: "mysql-nio")]),
        .target(name: "TerminalKit", dependencies: ["Core", "GhosttyKit"], linkerSettings: ghosttyLinks),
        .executableTarget(name: "kelpd", dependencies: ["Daemon"]),
        .executableTarget(name: "kelp", dependencies: ["Core"]),
        // A virtual machine for agents (Core/VMs.swift): the only program signed with the virtualization entitlement.
        .executableTarget(name: "KelpVM", dependencies: ["Core"], linkerSettings: [.linkedFramework("Virtualization")]),
        // Inside a macOS machine: its apps' controls for agents, over SSH (Sources/KelpGuest). Copied in as an app.
        .executableTarget(name: "KelpGuest"),
        .target(name: "LSPKit", dependencies: ["Core"]),
        .target(name: "WorkbenchKit", dependencies: ["Core"]),
        .target(name: "Integrations", dependencies: ["Core", "GitKit"]),
        .target(name: "Markdown", dependencies: [.product(name: "Markdown", package: "swift-markdown", moduleAliases: ["Markdown": "SwiftMarkdown"])],   // cmark-gfm, as SwiftMarkdown
                resources: [.copy("Resources/mermaid.min.js"), .copy("Resources/mermaid-LICENSE.txt"),   // mermaid 11.17.2, MIT
                            // KaTeX 0.19.1, MIT: its woff2 fonts inlined into the CSS as data URLs
                            .copy("Resources/katex.min.js"), .copy("Resources/katex.min.css"), .copy("Resources/katex-LICENSE.txt")]),
        // The design system's sizes, colours and building blocks (panel bar, icon button, empty state): AppKit only.
        .target(name: "DesignKit"),
        .target(name: "EditorKit", dependencies: ["DesignKit", .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                                                 .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter")]),
        // The shell, and what an extension is given (`package` declarations): the window, the editor area, tabs, panels.
        .target(name: "KelpKit", dependencies: ["Core", "DesignKit", "Agents", "TerminalKit", "EditorKit", "WorkbenchKit",
                                                .product(name: "Sparkle", package: "Sparkle")],
                resources: [.process("Resources/AgentLogos")]),   // Lobe Icons 1.102.0, MIT (its LICENSE inside)
        // The built-in extensions: each sees only what KelpKit declares `package`, never the shell's own parts, nor another.
        .target(name: "BuiltinAgents", dependencies: ["KelpKit", "DesignKit", "Core", "Agents", "TerminalKit", "WorkbenchKit"], path: "Sources/Builtins/Agents"),
        .target(name: "BuiltinFiles", dependencies: ["KelpKit", "DesignKit", "Core", "Agents", "EditorKit", "Markdown", "WorkbenchKit"], path: "Sources/Builtins/Files"),
        .target(name: "BuiltinGit", dependencies: ["KelpKit", "DesignKit", "Core", "Agents", "EditorKit", "WorkbenchKit"], path: "Sources/Builtins/Git"),
        .target(name: "BuiltinBrowser", dependencies: ["KelpKit", "DesignKit", "Core", "WorkbenchKit"], path: "Sources/Builtins/Browser"),
        .target(name: "BuiltinIssues", dependencies: ["KelpKit", "DesignKit", "Core", "Agents", "EditorKit", "WorkbenchKit"], path: "Sources/Builtins/Issues"),
        .target(name: "BuiltinActivity", dependencies: ["KelpKit", "DesignKit", "Core"], path: "Sources/Builtins/Activity"),
        .target(name: "BuiltinRoutines", dependencies: ["KelpKit", "DesignKit", "Core", "WorkbenchKit"], path: "Sources/Builtins/Routines"),
        .target(name: "BuiltinServers", dependencies: ["KelpKit", "DesignKit", "Core", "WorkbenchKit"], path: "Sources/Builtins/Servers"),
        .target(name: "BuiltinMachines", dependencies: ["KelpKit", "DesignKit", "Core", "WorkbenchKit"], path: "Sources/Builtins/Machines"),
        .target(name: "BuiltinDatabases", dependencies: ["KelpKit", "DesignKit", "Core", "WorkbenchKit", "EditorKit"], path: "Sources/Builtins/Databases"),
        .target(name: "BuiltinRun", dependencies: ["KelpKit", "DesignKit", "Core", "WorkbenchKit"], path: "Sources/Builtins/Run"),
        .executableTarget(
            name: "KelpApp",
            dependencies: ["KelpKit", "BuiltinAgents", "BuiltinFiles", "BuiltinGit", "BuiltinBrowser", "BuiltinIssues", "BuiltinActivity",
                           "BuiltinRoutines", "BuiltinServers", "BuiltinMachines", "BuiltinRun", "BuiltinDatabases", "GhosttyKit"],
            // SwiftPM records the deployment target (14.0) as the SDK the app was built with, and AppKit then draws the
            // macOS 14 look (compatibility mode). Naming a current SDK gets the system's own design on macOS 26+.
            // Limit: fixed at 26.0; raise it when a later SDK's look is wanted.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"])]
        ),
        .target(name: "TestSupportC", path: "Tests/TestSupportC"),
        .target(name: "TestSupport", dependencies: ["TestSupportC"], path: "Tests/TestSupport"),
        .testTarget(name: "CoreTests", dependencies: ["Core", "TestSupport"]),
        .testTarget(name: "GitKitTests", dependencies: ["GitKit", "TestSupport"]),
        .testTarget(name: "KelpVMTests", dependencies: ["KelpVM", "TestSupport"]),   // kelp-vm's decisions, apart from Virtualization
        .testTarget(name: "KelpGuestTests", dependencies: ["KelpGuest"]),   // its socket's requests and answers
        .testTarget(name: "AgentsTests", dependencies: ["Agents", "TestSupport"]),
        .testTarget(name: "AgentDataTests", dependencies: ["AgentData", "TestSupport"]),
        .testTarget(name: "DaemonTests", dependencies: ["Daemon", "Agents", "TestSupport"]),
        .testTarget(name: "LSPKitTests", dependencies: ["LSPKit", "TestSupport"]),
        .testTarget(name: "IntegrationsTests", dependencies: ["Integrations", "TestSupport"]),
        .testTarget(name: "MarkdownTests", dependencies: ["Markdown"]),
        .testTarget(name: "WorkbenchKitTests", dependencies: ["WorkbenchKit", "Core", "TestSupport"]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit", "TestSupport"]),
        .testTarget(name: "KelpCLITests", dependencies: ["kelp", "Core"]),   // the CLI's parsing and what it prints
        .testTarget(name: "ArchitectureTests"),   // reads the sources: the rules in docs/architecture.md
        .testTarget(name: "KelpAppTests", dependencies: ["KelpApp", "KelpKit", "BuiltinAgents", "BuiltinFiles", "BuiltinGit", "BuiltinBrowser", "BuiltinIssues",
                                                  "BuiltinActivity", "BuiltinRoutines", "BuiltinRun", "BuiltinMachines", "BuiltinServers", "BuiltinDatabases", "Core", "Daemon", "GitKit", "WorkbenchKit", "TestSupport"]),
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
    ]
)
