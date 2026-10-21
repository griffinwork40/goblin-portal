//
//  SpaceViewController+FirstResponderObserver.swift
//  KVO-based click-to-focus: update split dimming whenever NSWindow.firstResponder
//  changes, so clicking an unfocused pane always moves the accent border and dimming.
//
//  WHY THIS EXISTS
//
//  `SplitContainerView.mouseDown` (SplitContainerView.swift:264) fires
//  `didReceiveClickInChild` so the owner can call `updateSplitDimming`.  That
//  worked in theory but NEVER fires in practice: AppKit delivers `mouseDown` to the
//  *deepest* hit-test winner, which is `GoblinPortalTerminalView` (a subclass of
//  SwiftTerm's `MacTerminalView`).  `GoblinPortalTerminalView+SmoothScroll.swift:42`
//  overrides `mouseDown` and calls `super`, which reaches `MacTerminalView.mouseDown`
//  (vendor/SwiftTerm/Sources/SwiftTerm/Mac/MacTerminalView.swift:2496) — an `open
//  override` that handles selection and mouse reporting and then returns WITHOUT
//  calling `super`.  The responder-chain walk stops there; `SplitContainerView.mouseDown`
//  is never reached on a terminal click.
//
//  AppKit still calls `makeFirstResponder` on the clicked view independently (because
//  `acceptsFirstResponder` returns `true` on `GoblinPortalTerminalView`), so the
//  window's `firstResponder` DOES change to the clicked terminal — the visual state
//  (dimming, accent border) just never follows because `updateSplitDimming` is never
//  triggered.
//
//  WHY NOT PATCH SwiftTerm
//
//  `MacTerminalView.becomeFirstResponder` is `public` (not `open`), so it cannot be
//  overridden from outside the module.  Adding a `super` call to `mouseDown` would
//  require a new vendor patch — another entry in the sixteen-patch list — for a fix
//  that is cleaner as a reactive observer anyway.
//
//  THE FIX
//
//  KVO on `NSWindow.firstResponder`.  When the new first responder is a descendant of
//  a split leaf, call `updateSplitDimming` deferred one run-loop turn (so the
//  `firstResponder` write is already visible before we query it).  Keyboard navigation
//  (⌘⇧H/J/K/L) calls `updateSplitDimming` directly in `SpaceViewController+SplitFocus.swift`;
//  the observer fires harmlessly on that path because the KVO notification arrives
//  *after* the explicit call, and `updateSplitDimming` is idempotent.
//
//  LIFECYCLE
//
//  `subscribeToFirstResponderChanges(in:)` is called from `viewDidAppear` (the first
//  moment `view.window` is non-nil for the Space's window), and from the window-change
//  notification so a Space moved to a new native window stays wired.
//  `unsubscribeFromFirstResponderChanges()` is called from `tearDownAllDocuments()` and
//  from `viewWillDisappear`.  The KVO token is stored in `firstResponderObserver`
//  (declared in `SpaceViewController.swift` alongside `systemColorObserver`).
//
//  WHY DEFER ONE RUN-LOOP TURN
//
//  KVO on `firstResponder` fires synchronously inside `makeFirstResponder`, before the
//  write commits to `NSWindow.firstResponder`.  Reading `window?.firstResponder` inside
//  the notification body would still return the *old* value.  A single
//  `RunLoop.main.perform` defers the check to the next cycle, where the new value is
//  settled — the same pattern AppKit uses for `becomeFirstResponder` / `resignFirstResponder`
//  notifications.
//
//  WHY KEEP didReceiveClickInChild
//
//  The `SplitContainerView.didReceiveClickInChild` callback is kept with a
//  `// WHY KEPT` comment in `+SplitPresentation.swift:installClickCallback`.  It still
//  correctly identifies *which* child was clicked (important for nested 3-4 pane layouts
//  where the KVO path must also fire `updateSplitDimming`), and it costs nothing when
//  the responder chain does reach `SplitContainerView` (e.g. on a click that lands on
//  the divider strip itself).  The visual update is now driven exclusively by this file.
//

import AppKit

extension SpaceViewController {

    // MARK: - Subscribe / unsubscribe

    /// Begin observing `firstResponder` changes on `window`.
    ///
    /// Safe to call multiple times: a stale observation is torn down before the new
    /// one is installed, so re-wiring after a native-tab window move leaves exactly
    /// one active observer.
    func subscribeToFirstResponderChanges(in window: NSWindow) {
        // Tear down any previous observation first — window may have changed.
        unsubscribeFromFirstResponderChanges()

        firstResponderObserver = window.observe(
            \.firstResponder,
            options: [.new]
        ) { [weak self] observedWindow, _ in
            // KVO fires on whatever queue triggered the change.  `firstResponder` is
            // always set from the main thread (AppKit guarantee), so this closure is
            // main-thread, but we still route through MainActor.assumeIsolated to
            // satisfy Swift 6 isolation checks without adding a runtime dispatch.
            MainActor.assumeIsolated {
                guard let self else { return }
                // Defer one run-loop turn: KVO fires synchronously *inside*
                // makeFirstResponder, before the write to firstResponder commits.
                // Reading window.firstResponder here would return the old value.
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        self.handleFirstResponderChange(in: observedWindow)
                    }
                }
            }
        }
    }

    /// Stop observing `firstResponder` changes.  Safe to call when not subscribed.
    func unsubscribeFromFirstResponderChanges() {
        firstResponderObserver?.invalidate()
        firstResponderObserver = nil
    }

    // MARK: - Handler

    /// Called one run-loop turn after `NSWindow.firstResponder` changes.
    ///
    /// If the new first responder is a descendant of a split pane in the active tab,
    /// `updateSplitDimming` is re-run so dimming and the accent border follow the click.
    /// If there is no active split, this is a fast no-op (splitPeers lookup returns nil).
    private func handleFirstResponderChange(in window: NSWindow) {
        guard let primary = activeDocument,
              splitPeers[ObjectIdentifier(primary)] != nil else { return }
        // Guard: the new first responder must live inside our view hierarchy.
        // (Other responders — menus, panels, the command palette — should not
        // trigger a pane-focus change.)
        guard let fr = window.firstResponder as? NSView,
              fr.isDescendant(of: view) else { return }
        updateSplitDimming(for: primary)
    }
}
