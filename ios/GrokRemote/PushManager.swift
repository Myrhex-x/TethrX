import SwiftUI
import UserNotifications
import UIKit

/// Owns APNs registration. When the user opts in we request authorization and
/// register; the resulting device token is handed to `onToken`, which the app
/// forwards to the bridge so it can push "turn finished / approval needed" alerts.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    @Published var enabled = UserDefaults.standard.bool(forKey: "push.enabled")
    private(set) var lastToken: String?
    /// Set by the app; called whenever a fresh device token arrives.
    var onToken: ((String) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
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
}

/// Minimal app delegate purely to receive the APNs device token.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken) }
    }
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push this run — non-fatal.
    }
}
