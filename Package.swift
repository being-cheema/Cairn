// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Search", targets: ["Search"]),
        // A developer tools package: downloaded on request, never in the
        // app (build.sh devtools, DevToolsPackages.swift).
        .library(name: "DevToolsLite", type: .dynamic, targets: ["DevToolsLite"]),
        .library(name: "DevToolsFull", type: .dynamic, targets: ["DevToolsFull"]),
    ],
    targets: [
        // What Search and a developer tools package say to each other.
        .target(
            name: "SearchPluginAPI",
            path: "Sources/SearchPluginAPI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DevToolsLite",
            dependencies: ["SearchPluginAPI"],
            path: "Sources/DevToolsLite",
            // What build.sh puts in the feed for it, not code.
            exclude: ["package.json"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Developer Tools Full: the Chrome-style panels. Its Lighthouse,
        // Recorder and device toolbar are Lite's, the same sources compiled
        // into each (Sources/DevToolsShared, linked in as Shared/).
        .target(
            name: "DevToolsFull",
            dependencies: ["SearchPluginAPI"],
            path: "Sources/DevToolsFull",
            exclude: ["package.json"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // What the browser and the agent's MCP server say to each other, and
        // that server.
        .target(
            name: "CairnProtocol",
            path: "Sources/CairnProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "cairn-mcp",
            dependencies: ["CairnProtocol"],
            path: "Sources/cairn-mcp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The command line: the same socket, the same checks (CairnCLI).
        .executableTarget(
            name: "cairn",
            dependencies: ["CairnProtocol"],
            path: "Sources/cairn",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Search",
            dependencies: ["SearchPluginAPI", "CairnProtocol"],
            path: "Sources/Search",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Test-only: keeps every window the unit tests make off the screen.
        .target(
            name: "NoWindows",
            path: "Tests/NoWindows",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "SearchTests",
            // cairn-mcp so that its tests have it built, to run as an agent would.
            dependencies: ["Search", "NoWindows", "CairnProtocol", "cairn-mcp"],
            path: "Tests/SearchTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
