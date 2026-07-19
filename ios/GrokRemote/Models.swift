import Foundation

/// Response of `GET /api/health`.
struct HealthInfo: Codable {
    let ok: Bool
    let name: String?
    let grok: String?
    let grokAvailable: Bool
}

/// A Grok conversation tracked by the bridge.
struct SessionInfo: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var cwd: String?
    var model: String?
    var transport: String?
    var planMode: Bool?
    var effort: String?
    var autoApprove: Bool?
    var status: String
    var turnCount: Int
    var createdAt: String
    var lastEventId: Int?

    var isRunning: Bool { status == "running" }
}

/// How a rendered conversation line should look.
enum ChatRole: Equatable {
    case user, assistant, thought, tool, status, error, permission, plan
}

/// One option grok offers for a permission request (e.g. "Yes, proceed" / "No…").
struct PermissionOption: Identifiable, Equatable, Codable {
    var optionId: String
    var name: String
    var kind: String
    var id: String { optionId }
    var isAllow: Bool { kind.lowercased().contains("allow") }
}

/// One rendered line in the conversation. Streaming text is appended into the
/// `text` of the current assistant/thought item, so bubbles grow token-by-token.
struct ChatItem: Identifiable, Equatable {
    let id = UUID()
    var role: ChatRole
    var text: String

    // Tool activity (ACP transport)
    var toolCallId: String? = nil
    var toolStatus: String? = nil        // "running" | "completed" | "failed"

    // Permission request (ACP transport)
    var requestId: String? = nil
    var options: [PermissionOption] = []
    var decided: String? = nil           // chosen optionId, or "cancelled"
}
