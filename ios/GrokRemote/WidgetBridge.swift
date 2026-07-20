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
}

enum WidgetBridge {
    static let suiteName = "group.com.tethrx.app"
    static let key = "tethrx.snapshot"

    static func publish(_ snapshot: TethrXSnapshot) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
