// AppDelegate+CloseConfirmation.swift
// Owns quit's single aggregate decision. Separate because AppDelegate.swift is at
// its size ceiling and per-Space prompting cannot consolidate across windows.

import AppKit

extension AppDelegate {
    func confirmApplicationClose() -> Bool {
        CloseConfirmation.confirm(
            SpaceWindowController.open.flatMap { $0.space.allClosingDocuments }, quitting: true)
    }
}
