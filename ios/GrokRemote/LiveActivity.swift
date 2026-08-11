import ActivityKit
import Foundation

/// Starts / updates / ends the Live Activity for a session's turn. Best-effort:
/// no-ops if Live Activities are disabled. Activities are requested with a push
/// token so the BRIDGE can keep updating them after the app closes; the token is
/// handed to `onPushToken` for registration.
@MainActor
final class LiveActivityManager {
    private var activity: Activity<TethrXActivityAttributes>?
    private var sessionId: String?

    /// Called with the activity's APNs update token (hex) once iOS issues it.
    var onPushToken: ((String) -> Void)?

    func start(sessionName: String, sessionId: String, phase: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        self.sessionId = sessionId
        if activity != nil { update(phase: phase, detail: detail); return }
        // This manager is per-ChatViewModel, so a previous one for the same session (a
        // swipe back mid-turn, a restored scene) left its activity running and unowned:
        // the lock screen kept saying WORKING until the system's own limit expired,
        // hours later. Adopt it instead of stacking a second card on top.
        if let existing = Activity<TethrXActivityAttributes>.activities
            .first(where: { $0.attributes.sessionId == sessionId }) {
            activity = existing
            observePushToken(existing)
            update(phase: phase, detail: detail)
            return
        }
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        activity = try? Activity.request(
            attributes: TethrXActivityAttributes(sessionName: sessionName, sessionId: sessionId),
            content: .init(state: state, staleDate: nil),
            pushType: .token
        )
        if let activity { observePushToken(activity) }
    }

    private func observePushToken(_ activity: Activity<TethrXActivityAttributes>) {
        Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self?.onPushToken?(hex) }
            }
        }
    }

    /// Stop owning the activity without ending it: the turn is still running on the
    /// computer, and the bridge drives the card from here via its update token.
    func detach() { activity = nil }

    /// End any activity for this session, including one this manager never started.
    static func endOrphan(sessionId: String, phase: String, detail: String) {
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        for a in Activity<TethrXActivityAttributes>.activities where a.attributes.sessionId == sessionId {
            Task { await a.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4)) }
        }
    }

    func update(phase: String, detail: String) {
        guard let activity else { return }
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func end(phase: String, detail: String) {
        guard let activity else {
            // Nothing owned here, but an earlier manager for this session may have left
            // a card running. Sweep it rather than leaving it stuck on WORKING.
            if let sessionId { Self.endOrphan(sessionId: sessionId, phase: phase, detail: detail) }
            return
        }
        self.activity = nil
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4)) }
    }
}
