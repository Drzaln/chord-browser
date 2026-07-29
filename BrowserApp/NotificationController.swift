import BrowserCore
import Foundation
import UserNotifications
import os

/// Posts web notifications to macOS Notification Center and routes clicks back
/// (non-spec: user-requested).
///
/// Public WKWebView has no Web Notifications support, so the engine shims
/// `window.Notification` and forwards calls here (see `NotificationBridge`). This
/// owns the one thing that must live in the app: the `UNUserNotificationCenter`
/// and its authorization. Notifications appear while Chord is running and the
/// posting page is open; this is not background Web Push.
@MainActor
final class NotificationController: NSObject {
    // nonisolated so the OS completion closures (which are Sendable/non-isolated)
    // can log; `Logger` is Sendable.
    nonisolated private static let log = Logger(subsystem: "com.rizal.browser", category: "notifications")

    /// Called when a delivered notification is clicked, with the page-side
    /// notification id and the pane that posted it, so the store can focus the tab
    /// and fire the page's `onclick`.
    var onClick: (@MainActor (_ jsID: String, _ paneID: UUID) -> Void)?

    /// Whether the user has been asked yet this launch — the OS only prompts once,
    /// but we avoid re-requesting on every `requestPermission()` call.
    private var didRequestAuthorization = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks the OS for permission (prompting the first time) and reports whether
    /// notifications are now allowed.
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            didRequestAuthorization = true
            return granted
        } catch {
            Self.log.error("notification authorization failed: \(String(describing: error))")
            return false
        }
    }

    /// The current OS authorization, read without prompting — used at launch to
    /// seed the web-facing `Notification.permission` so returning pages read the
    /// decision the user already made instead of re-prompting.
    func authorizationStatus() async -> WebNotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// Posts a web notification. `tag` collapses onto an earlier one with the same
    /// tag, matching the web spec; otherwise the page-side id keeps each distinct.
    func present(_ request: WebNotificationRequest, fromPane paneID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = ["jsID": request.jsID, "paneID": paneID.uuidString]

        let identifier = (request.tag?.isEmpty == false) ? "tag:\(request.tag!)" : request.jsID
        let notification = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(notification) { error in
            if let error {
                Self.log.error("notification post failed: \(String(describing: error))")
            }
        }
    }
}

extension NotificationController: UNUserNotificationCenterDelegate {

    /// Show the banner even when Chord is frontmost — a chat notification the user
    /// is not looking at the tab for is still worth surfacing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A click routes back to the pane that posted it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let jsID = info["jsID"] as? String
        let paneID = (info["paneID"] as? String).flatMap(UUID.init(uuidString:))
        // Hop only the Sendable values to the main actor; the completion handler
        // is not Sendable, so call it here rather than capturing it in the Task.
        if let jsID, let paneID {
            Task { @MainActor in self.onClick?(jsID, paneID) }
        }
        completionHandler()
    }
}
