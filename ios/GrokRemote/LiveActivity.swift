import ActivityKit
import Foundation

/// Starts / updates / ends the Live Activity for a session's turn. Best-effort:
/// no-ops if Live Activities are disabled. Activities are requested with a push
/// token so the BRIDGE can keep updating them after the app closes; the token is
/// handed to `onPushToken` for registration.
@MainActor
final class LiveActivityManager {
    private var activity: Activity<TethrXActivityAttributes>?

    /// Called with the activity's APNs update token (hex) once iOS issues it.
    var onPushToken: ((String) -> Void)?

    func start(sessionName: String, sessionId: String, phase: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil { update(phase: phase, detail: detail); return }
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        activity = try? Activity.request(
            attributes: TethrXActivityAttributes(sessionName: sessionName, sessionId: sessionId),
            content: .init(state: state, staleDate: nil),
            pushType: .token
        )
        if let activity {
            Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await MainActor.run { self?.onPushToken?(hex) }
                }
            }
        }
    }

    func update(phase: String, detail: String) {
        guard let activity else { return }
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end(phase: String, detail: String) {
        guard let activity else { return }
        self.activity = nil
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4)) }
    }
}
