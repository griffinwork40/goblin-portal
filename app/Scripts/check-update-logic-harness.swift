//
//  check-update-logic-harness.swift
//  Part A assertion harness for check-update-logic.sh.
//
//  Not part of the app: Package.swift globs Sources/GoblinPortal only.
//  check-update-logic.sh copies this file to main.swift in its temp dir and
//  compiles it against the two logic functions extracted verbatim from
//  UpdateChecker.swift. The split mirrors check-git-status.sh: the shell half
//  builds fixtures and runs Part B; this file makes assertions about Part A.
//
//  WHY A SEPARATE FILE. The shell half (trampoline smoke test + env checks +
//  Part B logic) plus this Swift would exceed the 350-LOC ceiling enforced by
//  check-file-size.sh. The seam is clean: shell = process orchestration,
//  Swift = type-level assertions. Both count independently against the ceiling.
//
//  This must be COPIED to main.swift before compilation: Swift allows top-level
//  statements only in a file literally named main.swift.
//
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ✓ " : "  ✗ ") + name + (detail.isEmpty ? "" : "   [\(detail)]"))
    if !ok { failures += 1 }
}

// ── isNewer -- extracted verbatim from UpdateChecker.swift ────────────────────
// nonisolated private static func isNewer(_ remote: String, than local: String)
// Promoted to top-level for standalone compilation. The logic is unchanged.

func isNewer(_ remote: String, than local: String) -> Bool {
    let r = remote.split(separator: ".").map { Int($0) }
    let l = local.split(separator: ".").map { Int($0) }
    let count = max(r.count, l.count)
    for i in 0..<count {
        let rv = i < r.count ? (r[i] ?? 0) : 0
        let lv = i < l.count ? (l[i] ?? 0) : 0
        if rv != lv { return rv > lv }
    }
    return false
}

// ── findZipAsset -- extracted verbatim from UpdateChecker.swift ───────────────
// nonisolated private static func findZipAsset(in json: [String: Any]) -> URL?
// Promoted to top-level. The host allowlist and name prefix guard (Item 4) are
// the primary things under test here.

let allowedHosts: Set<String> = [
    "objects.githubusercontent.com",
    "github.com",
]

func findZipAsset(in json: [String: Any]) -> URL? {
    guard let assets = json["assets"] as? [[String: Any]] else { return nil }
    for asset in assets {
        guard let assetName = asset["name"] as? String,
              assetName.hasSuffix(".zip"),
              !assetName.hasSuffix(".sha256"),
              assetName.hasPrefix("GoblinPortal-"),
              let downloadURL = asset["browser_download_url"] as? String,
              let url = URL(string: downloadURL),
              url.scheme == "https",
              let host = url.host,
              allowedHosts.contains(host)
        else { continue }
        return url
    }
    return nil
}

// ── findHashAsset -- extracted verbatim from UpdateChecker.swift ──────────────
// nonisolated private static func findHashAsset(in json: [String: Any]) -> URL?
// Promoted to top-level. Tests verify: correct .zip.sha256 suffix match,
// prefix guard, host allowlist, and that the .zip itself is NOT returned.

func findHashAsset(in json: [String: Any]) -> URL? {
    let allowedHosts: Set<String> = [
        "objects.githubusercontent.com",
        "github.com",
    ]
    guard let assets = json["assets"] as? [[String: Any]] else { return nil }
    for asset in assets {
        guard let assetName = asset["name"] as? String,
              assetName.hasSuffix(".zip.sha256"),
              assetName.hasPrefix("GoblinPortal-"),
              let downloadURL = asset["browser_download_url"] as? String,
              let url = URL(string: downloadURL),
              url.scheme == "https",
              let host = url.host,
              allowedHosts.contains(host)
        else { continue }
        return url
    }
    return nil
}

// ────────────────────────────────────────────────────────────────────────────
// isNewer cases
// ────────────────────────────────────────────────────────────────────────────
print("isNewer — semver comparison")

check("0.3.0 newer than 0.2.0 (true)",
      isNewer("0.3.0", than: "0.2.0"))

check("same version is NOT newer (false)",
      !isNewer("0.2.0", than: "0.2.0"))

check("older remote is NOT newer (false)",
      !isNewer("0.1.0", than: "0.2.0"))

// The lexicographic trap: "1.10.0" > "1.9.0" numerically but "1.10.0" < "1.9.0"
// lexicographically (because "1" < "9"). A string-comparison isNewer would report
// false here, which means the app would never auto-update across a minor-10 boundary.
check("1.10.0 newer than 1.9.0 (true — lexicographic trap)",
      isNewer("1.10.0", than: "1.9.0"))

// Extra component: four-part version vs three-part.
check("1.0.0.1 newer than 1.0.0 (extra component, true)",
      isNewer("1.0.0.1", than: "1.0.0"))

// Non-numeric segment: Int($0) returns nil → treated as 0. Must not crash.
let nonNumericResult = isNewer("1.0.alpha", than: "1.0.0")
check("non-numeric segment does not crash (runs to completion)",
      true, "isNewer(\"1.0.alpha\", than: \"1.0.0\") = \(nonNumericResult)")

// Empty strings: both nil → equal → false.
check("empty vs empty is false (not newer)",
      !isNewer("", than: ""))

// Leading zero: "01.0.0" vs "1.0.0" — Int("01") = 1, so they are equal.
check("leading-zero segment parses as integer (equal → false)",
      !isNewer("01.0.0", than: "1.0.0"))

// ────────────────────────────────────────────────────────────────────────────
// findZipAsset cases
// ────────────────────────────────────────────────────────────────────────────
print("findZipAsset — asset selection, name prefix, host allowlist")

// No assets key → nil.
check("no assets key returns nil",
      findZipAsset(in: [:]) == nil)

check("empty assets array returns nil",
      findZipAsset(in: ["assets": [[String: Any]]()]) == nil)

// Valid zip on allowed CDN host.
let goodCDN = "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1234/GoblinPortal-v0.3.0.zip"
let validAsset: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip", "browser_download_url": goodCDN]
    ]
]
let foundURL = findZipAsset(in: validAsset)
check("valid GoblinPortal- zip on CDN returns non-nil",
      foundURL != nil, foundURL?.absoluteString ?? "nil")

// sha256 companion file is excluded (belt-and-suspenders).
let sha256Asset: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip.sha256", "browser_download_url": goodCDN]
    ]
]
check(".sha256 asset is excluded",
      findZipAsset(in: sha256Asset) == nil)

// Non-zip only → nil.
let dmgAsset: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.dmg",
         "browser_download_url": "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1234/GoblinPortal-v0.3.0.dmg"]
    ]
]
check("non-zip only returns nil",
      findZipAsset(in: dmgAsset) == nil)

// First zip wins (two zips: first is accepted).
let twoZips: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip", "browser_download_url": goodCDN],
        ["name": "GoblinPortal-v0.2.0.zip", "browser_download_url": goodCDN],
    ]
]
let firstURL = findZipAsset(in: twoZips)
check("first zip wins when multiple are present",
      firstURL?.absoluteString == goodCDN)

// Item 4: host validation — non-GitHub host rejected.
let foreignURL = "https://evil.example.com/GoblinPortal-v0.3.0.zip"
let foreignAsset: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip", "browser_download_url": foreignURL]
    ]
]
check("non-GitHub host is rejected (Item 4)",
      findZipAsset(in: foreignAsset) == nil)

// Item 4: github.com is in the allowlist (direct download fallback).
let githubDirectURL = "https://github.com/griffinwork40/goblin-portal/releases/download/v0.3.0/GoblinPortal-v0.3.0.zip"
let githubDirectAsset: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip", "browser_download_url": githubDirectURL]
    ]
]
check("github.com host is allowed (Item 4)",
      findZipAsset(in: githubDirectAsset) != nil)

// Item 4: name prefix — reject zip without GoblinPortal- prefix.
let badNameURL = "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1234/Malware-v1.0.zip"
let badNameAsset: [String: Any] = [
    "assets": [
        ["name": "Malware-v1.0.zip", "browser_download_url": badNameURL]
    ]
]
check("zip without GoblinPortal- prefix is rejected (Item 4)",
      findZipAsset(in: badNameAsset) == nil)

// Item 4: http:// scheme rejected even on an allowed host.
let httpURL = "http://objects.githubusercontent.com/github-production-release-asset-2e65be/1234/GoblinPortal-v0.3.0.zip"
let httpAsset: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip", "browser_download_url": httpURL]
    ]
]
check("http:// scheme is rejected even on allowed host (Item 4)",
      findZipAsset(in: httpAsset) == nil)

// Belt-and-suspenders: sha256 with GoblinPortal- prefix is still excluded.
let sha256GoodPrefix: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip.sha256", "browser_download_url": goodCDN]
    ]
]
check("GoblinPortal- prefix + .sha256 suffix is still excluded",
      findZipAsset(in: sha256GoodPrefix) == nil)

// ────────────────────────────────────────────────────────────────────────────
// findHashAsset cases (S2)
// ────────────────────────────────────────────────────────────────────────────
print("findHashAsset — .sha256 sidecar selection (S2)")

let goodHashURL = "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1234/GoblinPortal-v0.3.0.zip.sha256"

// No assets key → nil.
check("no assets key returns nil (hash)",
      findHashAsset(in: [:]) == nil)

// Valid .zip.sha256 sidecar on CDN.
let hashAssetValid: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip.sha256", "browser_download_url": goodHashURL]
    ]
]
let foundHashURL = findHashAsset(in: hashAssetValid)
check("valid .zip.sha256 sidecar returns non-nil",
      foundHashURL != nil, foundHashURL?.absoluteString ?? "nil")

// Plain .zip is NOT returned by findHashAsset (different concern from findZipAsset).
let zipOnlyForHash: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip", "browser_download_url": goodCDN]
    ]
]
check(".zip asset is NOT returned by findHashAsset",
      findHashAsset(in: zipOnlyForHash) == nil)

// Both zip and sidecar present: findHashAsset returns the sidecar URL.
let bothAssets: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip",        "browser_download_url": goodCDN],
        ["name": "GoblinPortal-v0.3.0.zip.sha256",  "browser_download_url": goodHashURL],
    ]
]
let hashFromBoth = findHashAsset(in: bothAssets)
check("sidecar returned when both zip and sha256 present",
      hashFromBoth?.absoluteString == goodHashURL, hashFromBoth?.absoluteString ?? "nil")

// Host allowlist: foreign host rejected for hash sidecar too.
let foreignHash: [String: Any] = [
    "assets": [
        ["name": "GoblinPortal-v0.3.0.zip.sha256",
         "browser_download_url": "https://evil.example.com/GoblinPortal-v0.3.0.zip.sha256"]
    ]
]
check("foreign host rejected for hash sidecar",
      findHashAsset(in: foreignHash) == nil)

// Name prefix guard: sidecar without GoblinPortal- prefix rejected.
let badPrefixHash: [String: Any] = [
    "assets": [
        ["name": "Other-v1.0.zip.sha256", "browser_download_url": goodHashURL]
    ]
]
check("sidecar without GoblinPortal- prefix rejected",
      findHashAsset(in: badPrefixHash) == nil)

// ────────────────────────────────────────────────────────────────────────────
// Summary
// ────────────────────────────────────────────────────────────────────────────
print("")
if failures == 0 {
    print("Part A: all checks passed")
    exit(0)
}
print("Part A: \(failures) check(s) failed")
exit(1)
