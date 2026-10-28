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

    /// The session this manager speaks for, known from the start. A chat opened while
    /// a turn was already running never called `start()`, so its `end()` had no session
    /// to sweep and the card stayed on WORKING.
    func bind(sessionId: String) {
        if self.sessionId == nil { self.sessionId = sessionId }
    }

    func start(sessionName: String, sessionId: String, phase: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        self.sessionId = sessionId
        if activity != nil { update(phase: phase, detail: detail); return }
        // This manager is per-ChatViewModel, so a previous one for the same session (a
        // swipe back mid-turn, a restored scene) left its activity running and unowned:
        // the lock screen kept saying WORKING until the system's own limit expired,
        // hours later. Adopt it instead of stacking a second card on top.
        // Only one that is still showing: a card just ended for the turn before this one
        // (a queued follow-up starts at once) is on its way off the screen, and adopting
        // it meant this turn had no card at all.
        if let existing = Activity<TethrXActivityAttributes>.activities
            .first(where: { $0.attributes.sessionId == sessionId
                            && ($0.activityState == .active || $0.activityState == .stale) }) {
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

/// Hands ActivityKit's tokens to the bridges for the life of the process.
///
/// Started from the app delegate, not from a scene: iOS delivers a push-started card's
/// update token by waking the app in the background with no scene at all, and a scene's
/// `.task` never runs then. Without that token the bridge could neither move the card
/// to "waiting" nor end it.
@MainActor
enum LiveActivityTokens {
    private static var started = false

    static func startObserving(_ app: AppState) {
        guard !started else { return }
        started = true
        if #available(iOS 17.2, *) {
            Task {
                for await tokenData in Activity<TethrXActivityAttributes>.pushToStartTokenUpdates {
                    await app.registerLiveActivityStart(hex(tokenData))
                }
            }
        }
        // Cards that already exist (started while the app was not running) and every
        // card from here on.
        for activity in Activity<TethrXActivityAttributes>.activities { observe(activity, app) }
        Task {
            for await activity in Activity<TethrXActivityAttributes>.activityUpdates { observe(activity, app) }
        }
    }

    private static func observe(_ activity: Activity<TethrXActivityAttributes>, _ app: AppState) {
        let sessionId = activity.attributes.sessionId
        Task {
            for await tokenData in activity.pushTokenUpdates {
                await app.registerLiveActivityUpdate(sessionId: sessionId, token: hex(tokenData))
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
