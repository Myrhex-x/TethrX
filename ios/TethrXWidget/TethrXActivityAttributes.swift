import ActivityKit

/// Shared between the app (which starts/updates the activity) and the widget
/// extension (which renders it). Member of BOTH targets.
struct TethrXActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String     // "working" | "waiting" | "done" | "error"
        var detail: String    // e.g. the tool name, or "Waiting for your approval"
    }
    var sessionName: String
}
