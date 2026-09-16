//
//  main.swift
//  Entry point.
//
//  Top-level code in main.swift is @MainActor in Swift 6, which is what we want:
//  every AppKit object below is main-actor-isolated.
//

import AppKit

let app = NSApplication.shared
// .regular (not .accessory) so the app gets a Dock icon, a menu bar, and normal
// activation — it is a real app, not a background agent.
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
