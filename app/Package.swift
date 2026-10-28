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
        // Upstream SwiftTerm main @ c3436be (post-IO-rewrite), vendored at
        // ../vendor/SwiftTerm with thirteen local patches (0001-0013, re-vendor 2026-10-27,
        // issue #281). Key patches: 0001 ships the Metal shader as .copy, 0002 fixes
        // the alt-buffer narrowing trim (required — missing it bleeds stale cells across
        // tmux panes), 0004 adds DCS Ptmux passthrough, 0012 bounds OSC 1337 image payloads.
        // See ../patches/swiftterm/SwiftTerm.pin for hashes and README.md ("Dependency note")
        // for how to recreate the vendor tree via bootstrap-vendor.sh.
        .package(path: "../vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "GoblinPortal",
            dependencies: ["SwiftTerm"],
            path: "Sources/GoblinPortal",
            // The `shell-integration.*` scripts must be declared here so SwiftPM copies them into
            // the product bundle and `Bundle.main.path(forResource:ofType:)` returns a
            // non-nil path. Without this, `swift run GoblinPortal` and the release bundle
            // both silently skip GOBLIN_PORTAL_INTEGRATION{,_BASH,_FISH}, and no shell's
            // integration is ever sourced. The path is relative to the target's `path`
            // ("Sources/GoblinPortal"), so two levels up to the package root, then into
            // Resources/.
            resources: [
                .copy("../../Resources/shell-integration.zsh"),
                .copy("../../Resources/shell-integration.bash"),
                .copy("../../Resources/shell-integration.fish"),
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
