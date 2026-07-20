import SwiftUI
import UserNotifications
import UIKit

/// Owns APNs registration and notification handling. When the user opts in we
/// request authorization and register; the device token is handed to `onToken`,
/// which the app forwards to the bridge. Approval pushes carry Approve/Reject
/// buttons so a tool can be resolved straight from the notification.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    @Published var enabled = UserDefaults.standard.bool(forKey: "push.enabled")
    private(set) var lastToken: String?

    /// Set by the app; called whenever a fresh device token arrives.
    var onToken: ((String) -> Void)?
    /// Tapping a notification should open that session.
    var onOpenSession: ((String) -> Void)? { didSet { flushPending() } }
    /// Approve/Reject tapped on the notification — resolve it against the bridge.
    var onPermissionDecision: ((_ sessionId: String, _ requestId: String, _ optionId: String) async -> Void)? {
        didSet { flushPending() }
    }

    // On a cold launch the notification response arrives before the app has wired these
    // handlers up. iOS never redelivers it, so hold onto it and replay once we can act.
    private var pendingOpen: String?
    private var pendingDecision: (sessionId: String, requestId: String, optionId: String)?

    private func flushPending() {
        if let id = pendingOpen, let handler = onOpenSession {
            pendingOpen = nil
            handler(id)
        }
        if let decision = pendingDecision, let handler = onPermissionDecision {
            pendingDecision = nil
            Task { await handler(decision.sessionId, decision.requestId, decision.optionId) }
        }
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    /// The "PERMISSION" category gives approval pushes their action buttons.
    private func registerCategories() {
        // Approving lets a command run on the user's computer, so require the device
        // to be unlocked (Face ID makes that a glance). Rejecting is always safe.
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve",
                                           options: [.authenticationRequired])
        let reject = UNNotificationAction(identifier: "REJECT", title: "Reject",
                                          options: [.destructive])
        let permission = UNNotificationCategory(identifier: "PERMISSION",
                                                actions: [approve, reject],
                                                intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([permission])
    }

    /// Ask permission and register for remote notifications (user opted in).
    func enable() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                self.enabled = granted
                UserDefaults.standard.set(granted, forKey: "push.enabled")
                if granted { UIApplication.shared.registerForRemoteNotifications() }
            }
        }
    }

    /// Turn push off locally (the bridge prunes the token on its next failed send).
    func disable() {
        enabled = false
        UserDefaults.standard.set(false, forKey: "push.enabled")
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    /// On launch, re-register if the user previously enabled push (tokens rotate).
    func refreshIfEnabled() {
        guard enabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func didRegister(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        lastToken = hex
        onToken?(hex)
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    // Show the banner even if the app happens to be foregrounded on another session.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tapped the notification, or one of its Approve/Reject buttons.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String ?? ""
        let requestId = info["requestId"] as? String ?? ""
        let allowId = info["allowOptionId"] as? String
        let rejectId = info["rejectOptionId"] as? String
        let action = response.actionIdentifier

        Task { @MainActor in
            switch action {
            case "APPROVE", "REJECT":
                let optionId = (action == "APPROVE") ? allowId : rejectId
                if !sessionId.isEmpty, !requestId.isEmpty, let optionId {
                    if let handler = self.onPermissionDecision {
                        // Await the round trip so iOS doesn't suspend us mid-request.
                        await handler(sessionId, requestId, optionId)
                    } else {
                        self.pendingDecision = (sessionId, requestId, optionId)
                    }
                }
            default:
                if !sessionId.isEmpty {
                    if let handler = self.onOpenSession { handler(sessionId) }
                    else { self.pendingOpen = sessionId }
                }
            }
            completionHandler()
        }
    }
}

/// Minimal app delegate purely to receive the APNs device token.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The delegate must be in place before launch finishes, otherwise a notification
    /// that launched the app is never delivered to it at all.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            UNUserNotificationCenter.current().delegate = PushManager.shared
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken) }
    }
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push this run — non-fatal.
    }
}
