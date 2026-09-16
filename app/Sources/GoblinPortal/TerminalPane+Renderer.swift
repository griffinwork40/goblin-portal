//
//  TerminalPane+Renderer.swift
//  Asking SwiftTerm for a drawing back end, and refusing to lie about which one it gave.
//
//  Its own file because `TerminalPane.swift` is 336 lines — 14 from `check-file-size.sh`'s
//  ceiling — and because this is one whole concern with a rule of its own: the *requested*
//  renderer and the *live* renderer are different facts, and every function here exists to
//  keep them from being confused. `Renderer.swift` owns the decision; this owns acting on
//  it.
//
//  WHY THIS IS MORE THAN ONE LINE. `setUseMetal(true)` can fail for reasons that are all
//  invisible from the call site: no Metal device, a shader source that is not in the bundle
//  (the state this project shipped in until 2026-07-31 — see patch 0001), a pipeline that
//  will not build. SwiftTerm handles this correctly, which is the good news:
//  `Mac/MacTerminalView.swift:379` is `throws` and the failure path leaves the view on Core
//  Text rather than trapping. But a `try?` on its own converts a real, diagnosable failure
//  into a terminal that is quietly slower than the config says it is — the exact silent
//  asymmetry `verify-vendor.sh` was written to kill, one layer up. So the request is made,
//  the result is read back from `isUsingMetalRenderer`, and any divergence is reported.
//

import AppKit
import SwiftTerm

extension TerminalPane {
    /// Ask the view for `renderer`, and report what it actually ended up using.
    ///
    /// Returns the **live** renderer, not the requested one. Callers that want to know
    /// whether they got what they asked for should compare.
    ///
    /// CALL ORDER: `apply(config:)` calls this BEFORE setting the font, because enabling or
    /// disabling Metal rebuilds the drawing surface (`updateMetalRenderer`,
    /// `Mac/MacTerminalView.swift:391` — it inserts or removes an `MTKView` and, on the way
    /// out, restores the caret view), so a font applied first would be applied to a surface
    /// that is about to be replaced. Safe to reach on every ⌘R: `setUseMetal` returns early
    /// when the requested state already matches (`:380-382`), so an unchanged config costs a
    /// comparison.
    @discardableResult
    func applyRenderer(_ renderer: Renderer) -> Renderer {
        let live = requestRenderer(renderer)

        // Report only the interesting cases: a downgrade always, and the happy path only
        // under GOBLIN_PORTAL_DIAG. A terminal that silently fell back to Core Text is exactly the
        // thing this file exists to make visible, so that one line goes to stderr
        // unconditionally — it is a real failure with a real cost, and this app has no
        // other channel to mention it in. Matching `AppConfig.load()`'s posture: degrade,
        // keep working, say why.
        if live != renderer {
            FileHandle.standardError.write("""
            [goblin-portal] renderer '\(renderer.configName)' unavailable — using \
            '\(live.configName)'. \(Self.fallbackHint)

            """.data(using: .utf8)!)
        } else if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
            FileHandle.standardError.write(
                "[diag] renderer=\(live.configName) (requested \(renderer.configName))\n"
                    .data(using: .utf8)!)
        }
        return live
    }

    /// The renderer this view is drawing with right now.
    ///
    /// Read from SwiftTerm rather than remembered locally, so it cannot drift from reality:
    /// the view rebuilds its `MTKView` when it moves between windows
    /// (`Mac/MacTerminalView.swift:225` — a `CAMetalLayer`'s binding does not survive being
    /// reparented, and a stale one silently freezes on its last frame), and a cached copy of
    /// "we asked for Metal once" would keep claiming Metal through any later failure.
    var liveRenderer: Renderer {
        #if canImport(MetalKit)
        return view.isUsingMetalRenderer ? .metal : .coreText
        #else
        return .coreText
        #endif
    }

    /// Perform the switch. Separated from the reporting above so the reporting has exactly
    /// one place to read the outcome from, and so the `#if canImport` lives in one function
    /// instead of being smeared through the diagnostics.
    private func requestRenderer(_ renderer: Renderer) -> Renderer {
        #if canImport(MetalKit)
        do {
            // Idempotent by contract — `setUseMetal` returns early when the requested state
            // already matches (`Mac/MacTerminalView.swift:380-382`), which matters because
            // this is reached from `apply(config:)` and therefore from every ⌘R.
            try view.setUseMetal(renderer == .metal)
        } catch {
            // Deliberately not rethrown and deliberately not fatal. A terminal that will not
            // open because the GPU renderer would not initialise is a strictly worse product
            // than a terminal that opens on Core Text and says so, and `setUseMetal`'s own
            // failure path has already left the view in the working state.
            if ProcessInfo.processInfo.environment["GOBLIN_PORTAL_DIAG"] != nil {
                FileHandle.standardError.write(
                    "[diag] setUseMetal(\(renderer == .metal)) threw: \(error)\n"
                        .data(using: .utf8)!)
            }
        }
        return liveRenderer
        #else
        // No MetalKit in the SDK at all: there is nothing to request and nothing to report
        // beyond the fallback line the caller prints.
        return .coreText
        #endif
    }

    /// Why a Metal request most plausibly failed, phrased as the thing to check.
    ///
    /// Named rather than inlined because the honest answer is nearly always the same one:
    /// the shader did not make it into the bundle. `MetalTerminalRenderer.makeLibrary`
    /// (`Apple/Metal/MetalTerminalRenderer.swift:2746`) needs `Shaders.metal` present as a
    /// resource so it can compile it at runtime (`:2765`), patch 0001 is what puts it there,
    /// and `make-app-bundle.sh` is what carries the resource bundle into
    /// `Contents/Resources/`. `check-metal-renderer.sh` checks both.
    static let fallbackHint =
        "Run app/Scripts/check-metal-renderer.sh — the usual cause is Shaders.metal missing "
        + "from the resource bundle (vendor patch 0001)."
}
