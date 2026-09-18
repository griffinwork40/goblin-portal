// swift-tools-version: 6.0
import PackageDescription

// The real app. Step 2 of ../.afk/plans/native-swift-terminal-afk-host.md.
//
// Renamed from Umber to Goblin Portal on 2026-09-15. The theme preset "umber"
// (a warm earth pigment) survives as an easter egg.
let package = Package(
    name: "GoblinPortal",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Upstream SwiftTerm v1.15.0, vendored at ../vendor/SwiftTerm with SIX
        // local patches — 0001 ships the Metal shader as a `.copy` resource so the
        // GPU renderer is reachable, 0002/0003 are required correctness fixes
        // (SwiftTerm #494 scrollback reflow, and the alt-buffer resize that bled
        // stale cells across tmux panes), 0004 gates an upstream debug `abort()`
        // behind `#if DEBUG`, 0005 adds DCS Ptmux passthrough, and 0006 gates
        // linefeed selection-clear on mouseMode. See ../patches/swiftterm/SwiftTerm.pin
        // for the hashes and README.md ("Dependency note") for how to recreate the tree.
        //
        // A tree missing 0002/0003 compiles, runs, and silently corrupts the
        // buffer, which is why Scripts/verify-vendor.sh is a hard gate in
        // Scripts/make-app-bundle.sh rather than advisory.
        .package(path: "../vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "GoblinPortal",
            dependencies: ["SwiftTerm"],
            path: "Sources/GoblinPortal",
            // `shell-integration.zsh` must be declared here so SwiftPM copies it into
            // the product bundle and `Bundle.main.path(forResource:ofType:)` returns a
            // non-nil path. Without this, `swift run GoblinPortal` and the release bundle
            // both silently skip GOBLIN_PORTAL_INTEGRATION, and the zsh integration is
            // never sourced. The path is relative to the target's `path`
            // ("Sources/GoblinPortal"), so two levels up to the package root, then into
            // Resources/.
            resources: [
                .copy("../../Resources/shell-integration.zsh"),
                .copy("../../Resources/install-update.sh"),
            ]
        ),
        // Standalone CLI binary that enables `EDITOR='goblin-portal --wait'` workflows.
        // No dependency on the GoblinPortal target or SwiftTerm — it communicates with
        // the running app via NSDistributedNotificationCenter and a Unix domain socket.
        // See Sources/GoblinPortalCLI/main.swift for the full IPC design rationale.
        .executableTarget(
            name: "GoblinPortalCLI",
            dependencies: [],
            path: "Sources/GoblinPortalCLI"
        ),
    ]
)
