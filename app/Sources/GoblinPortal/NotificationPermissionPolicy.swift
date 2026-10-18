// NotificationPermissionPolicy.swift
// Foundation-only state machine for deferred notification permission.
// Compiled standalone by check-notification-permission.sh.
//
// WHY this file exists: T2.5 moves the UNUserNotificationCenter permission
// prompt from launch (where it fires before the app has anything to say) to
// the first notification that WOULD be posted. The state machine here
// encapsulates every observable state and the action each (state × event)
// pair should take, so the gate can exercise the policy without AppKit or a
// window server. The caller in CommandNotification.swift maps each action to
// its UNUserNotificationCenter call.
//
// STATE MACHINE
//   .notDetermined  — initial; authorization has never been asked or answered.
//   .pending        — a request is in flight; a subsequent notification that
//                     arrives before the user dismisses the dialog is stored
//                     in a queue (capped at maxQueued). When authorization is
//                     granted the queued items are delivered in order; when
//                     denied they are dropped. Only the first event causes a
//                     system permission dialog — burst arrivals do not re-ask.
//   .authorized     — permission granted; post immediately.
//   .provisional    — provisional grant; post immediately (same as authorized).
//   .denied         — user refused; drop silently, do not re-ask.
//
// ACTION TABLE (what the caller must do in response to each returned Action)
//   .requestThenPost(title:body:) — call requestAuthorization; on grant, post
//                                    the notification from the completion handler
//                                    (a notification added before authorization
//                                    is silently dropped by macOS, so this is
//                                    mandatory — not an optimisation).
//   .post(title:body:)            — authorization is already in hand; post now.
//   .enqueue(title:body:)         — request already in flight; store for later.
//   .drop                         — permission denied; do nothing, do not re-ask.
//
// BURST BEHAVIOR (documented per-requirement)
//   While a request is in flight (.pending) every additional notification is
//   enqueued (up to maxQueued; extras are dropped). On authorization grant the
//   caller delivers them in order from the completion handler. This choice
//   deliberately delivers at most maxQueued items from a burst: it is better
//   to silently cap a storm than to flood the Notification Center with a
//   backlog the user must dismiss one by one. The cap value is exposed as a
//   constant so the gate and the caller share one source of truth.

import Foundation

// MARK: - Action

/// What the caller must do in response to a notification delivery request.
enum NotificationAction: Equatable {
    /// First notification ever: ask for permission, then post from the completion handler.
    case requestThenPost(title: String, body: String)
    /// Permission already granted (or provisional): post immediately.
    case post(title: String, body: String)
    /// A request is in flight: store for later delivery if granted.
    case enqueue(title: String, body: String)
    /// Permission denied: drop silently, do not re-ask.
    case drop
}

// MARK: - Policy

/// State machine for deferred notification permission.
///
/// Not thread-safe: all calls must come from the main actor (same as
/// `CommandNotification`, which is `@MainActor`). Not declared `@MainActor`
/// itself so `check-notification-permission.sh` can compile it with Foundation
/// only — no AppKit, no `@MainActor`, and therefore no run loop required.
struct NotificationPermissionPolicy {

    // MARK: - State

    enum AuthState: Equatable {
        case notDetermined
        case pending
        case authorized
        case provisional
        case denied
    }

    /// Maximum number of notifications stored while a permission request is in flight.
    /// Extras beyond this cap are dropped. See the file-level doc comment for rationale.
    static let maxQueued = 5

    private(set) var authState: AuthState = .notDetermined

    /// Notifications received while a request is in flight, awaiting delivery or drop.
    private(set) var pendingQueue: [(title: String, body: String)] = []

    // MARK: - Event handling

    /// Called when a notification WOULD be posted.
    ///
    /// Returns the action the caller must take. Mutates internal state (queuing
    /// or moving to .pending) as a side effect.
    mutating func notificationRequested(title: String, body: String) -> NotificationAction {
        switch authState {
        case .notDetermined:
            authState = .pending
            return .requestThenPost(title: title, body: body)

        case .pending:
            if pendingQueue.count < Self.maxQueued {
                pendingQueue.append((title: title, body: body))
                return .enqueue(title: title, body: body)
            }
            return .drop

        case .authorized, .provisional:
            return .post(title: title, body: body)

        case .denied:
            return .drop
        }
    }

    /// Called from the `requestAuthorization` completion handler.
    ///
    /// Returns the queue of notifications to deliver if `granted == true`; returns
    /// an empty array if `granted == false` (queue is discarded). Resets `pendingQueue`.
    mutating func authorizationCompleted(granted: Bool) -> [(title: String, body: String)] {
        if granted {
            authState = .authorized
        } else {
            authState = .denied
        }
        let queued = pendingQueue
        pendingQueue = []
        return granted ? queued : []
    }

    /// Called when `getNotificationSettings` resolves an existing authorization
    /// (e.g. on a fresh launch after the user has already granted/denied).
    mutating func applyKnownState(_ state: AuthState) {
        guard authState == .notDetermined else { return }
        authState = state
    }
}
