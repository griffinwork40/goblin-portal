//
//  AppDelegate+Notifications.swift
//  UNUserNotificationCenterDelegate conformance for AppDelegate, plus the
//  launch-time read of the system's existing notification authorization.
//
//  Kept in its own file because AppDelegate.swift is close to the 350-LOC
//  ceiling and the conformance belongs to the notifications feature, not to
//  app lifecycle.
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

// MARK: - Launch-time authorization state read

extension AppDelegate {
    /// Read the system's current notification authorization without prompting,
    /// and seed `CommandNotification`'s policy so the first background-command
    /// notification on a returning session does not redundantly trigger
    /// `requestAuthorization`.
    ///
    /// WHY `getNotificationSettings` and not `requestAuthorization`: T2.5's
    /// rule is "no permission prompt at launch". `getNotificationSettings`
    /// reads the existing decision without ever showing a dialog — it is the
    /// only UNUserNotificationCenter API that is safe here.
    ///
    /// WHY also on `didBecomeActiveNotification`: a user who denied permission,
    /// then re-enabled it in System Settings, gets the correction applied the
    /// next time they bring the app to the foreground — without a relaunch.
    /// The re-read is cheap (no dialog, no callback overhead on the hot path).
    func readNotificationAuthState() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Map UNAuthorizationStatus → NotificationPermissionPolicy.AuthState.
            // Cases not represented in AuthState (.notDetermined, .ephemeral)
            // are intentionally left unmapped: notDetermined means we have no
            // information to seed, and ephemeral is not requested by this app.
            let state: NotificationPermissionPolicy.AuthState?
            switch settings.authorizationStatus {
            case .authorized:   state = .authorized
            case .provisional:  state = .provisional
            case .denied:       state = .denied
            default:            state = nil   // .notDetermined / .ephemeral — leave policy as-is
            }
            guard let state else { return }
            DispatchQueue.main.async {
                CommandNotification.applyKnownAuthState(state)
            }
        }
    }
}
