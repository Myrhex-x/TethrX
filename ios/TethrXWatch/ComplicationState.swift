import Foundation

/// What the face complication reads. The watch app owns it; the widget extension
/// keeps its own copy of this shape (separate module), so only the coding keys have
/// to agree — the same arrangement the iOS widget uses.
struct ComplicationState: Codable {
    var waitingCount = 0
    var runningCount = 0
    var sessionCount = 0
    var waitingName = ""
    var waitingSessionId = ""
    var updatedAt = Date()

    static let suiteName = "group.com.tethrx.app"
    static let key = "tethrx.watch.state"
}
