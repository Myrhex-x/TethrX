import ActivityKit
import Foundation

/// Starts / updates / ends the Live Activity for a session's turn. Best-effort:
/// no-ops if Live Activities are disabled. Updates apply while the app is running;
/// full background updates would need ActivityKit push (a later addition).
@MainActor
final class LiveActivityManager {
    private var activity: Activity<TethrXActivityAttributes>?

    func start(sessionName: String, phase: String, detail: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil { update(phase: phase, detail: detail); return }
        let state = TethrXActivityAttributes.ContentState(phase: phase, detail: detail)
        activity = try? Activity.request(
            attributes: TethrXActivityAttributes(sessionName: sessionName),
            content: .init(state: state, staleDate: nil)
        )
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
