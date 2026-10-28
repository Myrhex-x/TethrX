import Foundation
import WidgetKit

/// What the face complication reads. The watch app owns it; the widget extension
/// keeps its own copy of this shape (separate module), so only the coding keys have
/// to agree, the same arrangement the iOS widget uses.
///
/// The widget decodes with synthesized Codable, which throws on a missing key even
/// for a property with a default. A field added here must be optional in both
/// copies, or a widget reading state an older build wrote would show nothing at all.
struct ComplicationState: Codable, Equatable {
    var waitingCount = 0
    var runningCount = 0
    var sessionCount = 0
    var waitingName = ""
    var waitingSessionId = ""
    var updatedAt = Date()

    static let suiteName = "group.com.tethrx.app"
    static let key = "tethrx.watch.state"
}

extension ComplicationState {
    init(_ snapshot: WatchSnapshot) {
        let waiting = snapshot.sessions.first(where: \.isWaitingOnYou)
        self.init(
            waitingCount: snapshot.waitingCount,
            runningCount: snapshot.runningCount,
            sessionCount: snapshot.sessions.count,
            waitingName: waiting?.name ?? "",
            waitingSessionId: waiting?.id ?? "",
            updatedAt: Date()
        )
    }

    /// Whether two states draw the same face, whenever each was written.
    func drawsLike(_ other: ComplicationState) -> Bool {
        var other = other
        other.updatedAt = updatedAt
        return self == other
    }

    /// Hand the face what it needs and ask it to redraw. Called from the store on
    /// every snapshot, including one that lands while the app is not running, so the
    /// face is never left describing an hour ago. A snapshot that changes nothing on
    /// the face is not written: each reload spends from the widget's daily budget.
    static func publish(_ snapshot: WatchSnapshot) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let next = ComplicationState(snapshot)
        if let data = defaults.data(forKey: key),
           let current = try? JSONDecoder().decode(ComplicationState.self, from: data),
           current.drawsLike(next) { return }
        guard let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
