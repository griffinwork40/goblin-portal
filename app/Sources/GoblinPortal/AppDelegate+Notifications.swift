//
//  AppDelegate+Notifications.swift
//  UNUserNotificationCenterDelegate conformance for AppDelegate.
//
//  Kept in its own file because AppDelegate.swift is close to the 350-LOC ceiling
//  and the conformance belongs to the notifications feature, not to app lifecycle.
//

import UserNotifications

// MARK: - Notification presentation

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// Allow notifications to display even when the app is frontmost.
    ///
    /// Without this, macOS silences notifications from the active app entirely.
    /// The primary use case — a long build finishing in a background TAB of the
    /// same window — means the app is frontmost, so the notification would be
    /// swallowed. Returning .banner + .sound matches the behaviour users expect:
    /// the notification appears and the system sound plays.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
