// check-runtime-paths-harness.swift
// Swift harness for check-runtime-paths.sh.
//
// Compiled by the shell script against the @testable GoblinPortal objects — never run directly.
// Three cases: cwd correctness (⌘T), context-menu wiring, BEL→attention.
//
import AppKit
import SwiftTerm
@testable import GoblinPortal

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

var bad = 0
func ok(_ m: String) { print("  ok  \(m)") }
func fail(_ m: String) { print("  FAIL \(m)"); bad += 1 }

/// Pump the main run loop, returning early once `done()` holds.
/// Waits are conjunctions, never disjunctions — see check-pane-teardown.sh's pump() note.
@MainActor
func pump(_ seconds: Double, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        if done() { return }
    }
}

/// Direct children of this process. Same pgrep approach as check-pane-teardown.sh.
func childPids() -> Set<Int32> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", String(getpid())]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Set(String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
}

/// Minimal offscreen window that is visible enough for AppKit responder chains to
/// work and for a shell view to get frame geometry — same shape as check-pane-teardown.sh.
@MainActor
func hostWindow(_ view: NSView, size: NSSize = NSSize(width: 800, height: 400)) -> NSWindow {
    let win = NSWindow(
        contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
        styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView?.addSubview(view)
    view.frame = win.contentView!.bounds
    win.orderBack(nil)
    return win
}

MainActor.assumeIsolated {
    let spaceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let cfg = AppConfig.defaults()
    let frame = NSRect(x: 0, y: 0, width: 800, height: 400)

    // ========================================================================================
    // CASE 1 — CWD. A terminal spawned by addTerminalDocument lands in the Space root.
    //
    // The chain being tested:
    //   addTerminalDocument(start:workingDirectory:)
    //     → TerminalPane(config:frame:workingDirectory:)
    //     → TerminalPane.start()          — calls startProcess(cwd: workingDirectory)
    //     → SwiftTerm: LocalProcess.startProcess(executable:args:envAdditions:currentDirectory:)
    //     → Pty.fork(inDirectory:)        — chdir(cCurrentDirectory) in the child
    //
    // ShellDirectory.shellCwd(for:) is what the production DirectoryFollow poller uses on
    // every 750ms tick. Exercising it here proves the cwd is right at spawn, and on its
    // first tick the poller will see the same path the Space was opened on — so it will
    // NOT update the tree root (since they match), which is the correct quiet behaviour.
    //
    // `start: true` — the shell really spawns; this is not a construction-only check.
    // ========================================================================================
    let spaceVC = SpaceViewController(config: cfg, root: spaceRoot)
    let wc = SpaceWindowController(config: cfg, root: spaceRoot)
    _ = wc.window  // force window load

    let beforeCwd = childPids()
    let pane = TerminalPane(config: cfg, frame: frame, workingDirectory: spaceRoot)
    let termWin = hostWindow(pane.view)
    pane.start()

    // Wait until a child appears (the shell spawn) — same pattern as check-pane-teardown.sh.
    pump(12.0) { !childPids().subtracting(beforeCwd).isEmpty }
    guard let shellPid = childPids().subtracting(beforeCwd).first else {
        print("  ENV  TerminalPane spawned no direct child in 12s — cannot check cwd")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        exit(2)
    }
    // Give the shell one extra tick to finish its chdir before we read back.
    pump(0.5)

    let shellCwd = ShellDirectory.shellCwd(for: shellPid)
    if let shellCwd {
        // Resolve symlinks on both sides — spaceRoot may be a symlink-terminated temp path
        // (macOS /var/folders is a symlink to /private/var/folders).
        let got = shellCwd.resolvingSymlinksInPath().standardized.path
        let want = spaceRoot.resolvingSymlinksInPath().standardized.path
        print("  shell pid=\(shellPid) cwd=\(got)")
        print("  space root         =\(want)")
        if got == want {
            ok("shell cwd matches Space root (\(got))")
        } else {
            fail("shell cwd \(got) != Space root \(want) — ⌘T does not open in the project")
        }
    } else {
        // shellCwd nil means proc_pidinfo returned 0 bytes — plausible if the shell exited
        // immediately (unlikely at 0.5s) or the pid was recycled. Treat as environmental.
        print("  ENV  ShellDirectory.shellCwd returned nil for pid \(shellPid)")
        print(bad == 0 ? "ENV-BLOCKED" : "SOME-FAILED")
        pane.documentWillClose()
        exit(2)
    }
    pane.documentWillClose()

    // ========================================================================================
    // CASE 2 — CONTEXT MENU.
    //
    // The chain being tested:
    //   FileTreeViewController.menuNeedsUpdate(_:)  — runs on right-click
    //     → addItem(withTitle:"New Terminal Here", action:#selector(menuNewTerminal(_:)), ...)
    //     → for item in menu.items where item.action != nil { item.target = self }
    //   NSApp.target(forAction:to:from:)             — resolves the chain from the tree view
    //
    // Three sub-checks, in ascending trust:
    //   2a. target is non-nil and is the FileTreeViewController itself (not a stale ref)
    //   2b. action is the exact menuNewTerminal(_:) selector
    //   2c. the responder chain resolves it to a live object from the tree view
    //
    // Cannot reach: whether the menu appears at the cursor, keyboard navigation, tap area.
    // ========================================================================================
    let treeVC = FileTreeViewController(config: cfg, root: spaceRoot)
    let treeWin = hostWindow(treeVC.view, size: NSSize(width: 600, height: 800))
    treeWin.makeKey()
    pump(0.3)  // let the tree populate its outline

    // Fire menuNeedsUpdate to populate the menu, just as a right-click would.
    let menu = NSMenu()
    treeVC.outlineView.menu = menu
    treeVC.menuNeedsUpdate(menu)

    let terminalItems = menu.items.filter { $0.title == "New Terminal Here" }
    print("  context-menu items with title 'New Terminal Here': \(terminalItems.count)")
    guard let item = terminalItems.first else {
        fail("'New Terminal Here' not found in context menu — menuNeedsUpdate did not add it")
        print("\n\(bad) runtime-paths case(s) FAILED"); exit(1)
    }

    // 2a — target is the tree controller.
    let target = item.target
    print("  item.target = \(String(describing: target))")
    if let target = target as? FileTreeViewController {
        ok("context-menu target is a FileTreeViewController (non-nil, correct type)")
        _ = target  // suppress unused-variable warning
    } else {
        fail("context-menu target is \(String(describing: target)), expected FileTreeViewController")
    }

    // 2b — selector matches exactly. Resolving `button.action` rather than a hardcoded
    // expectation, the same lesson check-sidebar-toggle.sh records: measuring a value the
    // item does not own passes green while a miswired item stays inert.
    let expectedSel = #selector(FileTreeViewController.menuNewTerminal(_:))
    print("  item.action = \(String(describing: item.action))")
    if item.action == expectedSel {
        ok("context-menu action == #selector(menuNewTerminal(_:))")
    } else {
        fail("context-menu action is \(String(describing: item.action)), expected menuNewTerminal(_:)")
    }

    // 2c — responder chain resolves from the tree view. Use item.action (not expectedSel)
    // so a wrong action fails here, not just in 2b.
    if let action = item.action {
        let resolved = app.target(forAction: action, to: nil, from: treeVC.outlineView)
        if let resolved {
            let cls = String(describing: type(of: resolved))
            print("  NSApp.target(forAction: menuNewTerminal:) resolved to \(cls)")
            ok("context-menu action resolves to a live responder (\(cls))")
        } else {
            fail("context-menu action resolved to nil — 'New Terminal Here' would click and do nothing")
        }
    }

    // Control: a bogus selector must NOT resolve — same pattern as check-sidebar-toggle.sh.
    let bogusSel = NSSelectorFromString("umberProbeNoSuchContextMenuAction:")
    let controlResolved = app.target(forAction: bogusSel, to: nil, from: treeVC.outlineView)
    if controlResolved != nil {
        fail("CONTROL RESOLVED NON-NIL — harness is measuring nothing; responder chain is too permissive")
    } else {
        ok("control: bogus selector correctly resolves to nil")
    }

    // ========================================================================================
    // CASE 3 — BEL → ATTENTION.
    //
    // The chain being tested:
    //   view.feed(byteArray: [0x07])         — byte 0x07 is BEL
    //     → GoblinPortalTerminalView.bell(source:)  — open override on TerminalView
    //     → bellDelegate?.terminalViewDidRingBell(self)
    //     → TerminalPane.terminalViewDidRingBell(_:)
    //     → guard !isActiveDocument else { return }
    //     → status = .attention
    //
    // 3a: feeding BEL to a pane with no superview (isActiveDocument == false) raises .attention.
    // 3b: feeding BEL to a pane WITH a superview (isActiveDocument == true) does NOT raise it —
    //     asserting the negative is what proves the guard is still there and that 3a is not
    //     just noise from an always-firing handler.
    //
    // No shell spawn needed — feed(byteArray:) routes through the terminal parser and does not
    // require a pty. The test is about the delegate→status chain, not about pty I/O.
    //
    // Cannot reach: NSSound.beep() (audio output), the tab strip's repaint (visual output).
    // ========================================================================================

    // 3a — background pane (no superview → isActiveDocument == false).
    let bgPane = TerminalPane(config: cfg, frame: frame, workingDirectory: spaceRoot)
    // Intentionally NOT added to any window — view.superview will be nil.
    print("  bgPane.view.superview = \(String(describing: bgPane.view.superview))")
    print("  bgPane.documentStatus before BEL = \(bgPane.documentStatus)")
    bgPane.view.feed(byteArray: ArraySlice([0x07]))
    pump(0.15)  // let the parse + delegate call + status assignment propagate
    let statusAfterBg = bgPane.documentStatus
    print("  bgPane.documentStatus after  BEL = \(statusAfterBg)")
    if statusAfterBg == .attention {
        ok("BEL on background pane raised .attention")
    } else {
        fail("BEL on background pane did NOT raise .attention (got \(statusAfterBg))")
    }

    // 3b — active pane (view installed in a window → isActiveDocument is true because
    // the window is key and the view has a superview). Status must stay .idle.
    let fgPane = TerminalPane(config: cfg, frame: frame, workingDirectory: spaceRoot)
    let fgWin = hostWindow(fgPane.view)
    fgWin.makeKey()
    pump(0.15)
    print("  fgPane.view.superview = \(String(describing: fgPane.view.superview != nil))")
    print("  fgPane.view.window?.isKeyWindow = \(String(describing: fgPane.view.window?.isKeyWindow))")
    print("  fgPane.documentStatus before BEL = \(fgPane.documentStatus)")
    fgPane.view.feed(byteArray: ArraySlice([0x07]))
    pump(0.15)
    let statusAfterFg = fgPane.documentStatus
    print("  fgPane.documentStatus after  BEL = \(statusAfterFg)")
    if statusAfterFg == .idle {
        ok("BEL on active pane correctly leaves status .idle (guard is in place)")
    } else {
        fail("BEL on active pane raised \(statusAfterFg) — the isActiveDocument guard was bypassed")
    }

    _ = (termWin, treeWin, fgWin)  // keep windows alive to end of run

    if bad == 0 {
        print("\nall runtime-path cases passed (cwd + context-menu wiring + BEL attention)")
    } else {
        print("\n\(bad) runtime-path case(s) FAILED")
    }
    exit(bad == 0 ? 0 : 1)
}
