import Foundation
import WidgetKit

/// Snapshot the app publishes to its home-screen widget through the shared app group.
/// The widget target keeps its own copy of this shape — only the JSON keys must agree.
struct TethrXSnapshot: Codable {
    var computer = ""
    var sessionCount = 0
    var runningCount = 0
    var activeName = ""
    var totalTokens = 0
    var costUSD: Double = 0
    var updatedAt = Date()
    // Blocked on you is the one state that needs an action, and the widget used to
    // report it as plain "working" — the same face it wears while it's fine.
    var waitingCount = 0
    var waitingName = ""
    /// So a tap lands on the session that is asking, not on the app's last screen.
    var waitingSessionId = ""
}

enum WidgetBridge {
    static let suiteName = "group.com.tethrx.app"
    static let key = "tethrx.snapshot"

    static func publish(_ snapshot: TethrXSnapshot) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        // Every poll used to reload the widget, though `updatedAt` alone had changed.
        // Background wakes (the watch asking for the list) count against the widget's
        // daily budget, and a spent budget is how later, real changes got dropped.
        // A change reloads at once; the same state reloads at most every ten minutes,
        // which keeps the widget's "may be out of date" clock honest.
        var unchanged = snapshot
        unchanged.updatedAt = .distantPast
        let fingerprint = try? JSONEncoder().encode(unchanged)
        let now = Date()
        if fingerprint == lastFingerprint, let last = lastReload, now.timeIntervalSince(last) < 600 { return }
        lastFingerprint = fingerprint
        lastReload = now
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// No computer to report on (it was forgotten, or disconnected on purpose). Left
    /// in place, the last computer's "needs you", and its tap target, stayed up.
    static func clear() {
        UserDefaults(suiteName: suiteName)?.removeObject(forKey: key)
        lastFingerprint = nil
        lastReload = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static var lastFingerprint: Data?
    private static var lastReload: Date?
}
