import Foundation

// The payload the phone sends. The watch is a separate module on a separate
// platform, so it carries its own copy of these shapes, exactly as the widget does
// for its snapshot: only the coding keys have to agree with WatchLink.swift.
//
// Fields added after the first release (`kind`, `lastActivity`, `lastReply`,
// `lastUser`) are optional on both sides, so a phone and a watch on different
// builds still decode each other's payloads.

struct WatchSession: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var folder: String = ""
    var status: String = "idle"
    /// "permission" | "plan" while Grok is blocked on you, else nil.
    var waitingKind: String?
    var waitingLabel: String?
    /// When the running turn began, or when the block started.
    var since: Date?
    var turns: Int = 0
    var contextFraction: Double = 0
    /// Pushed with the snapshot, so the request and its risk are readable, and
    /// answerable, without a live link to the phone.
    var approval: WatchApproval?
    /// When anything last happened here. Sent for idle sessions only.
    var lastActivity: Date?

    var isRunning: Bool { status == "running" }
    var isWaitingOnYou: Bool { waitingKind != nil }
}

struct WatchSnapshot: Codable, Hashable {
    var computer: String = ""
    /// Whether the phone has a computer to talk to (one is paired and not
    /// disconnected), not whether that computer is awake this second.
    var connected: Bool = false
    var sessions: [WatchSession] = []
    /// When the phone read this list from the computer, by the phone's clock. Two
    /// copies that crossed on the way are ordered by it.
    var updatedAt: Date = Date()

    var waitingCount: Int { sessions.filter(\.isWaitingOnYou).count }
    var runningCount: Int { sessions.filter(\.isRunning).count }

    /// The three sections of the list. A blocked session is "Needs you" even while
    /// its status is still "running", so nothing appears twice.
    var needsYou: [WatchSession] { sessions.filter(\.isWaitingOnYou) }
    var running: [WatchSession] { sessions.filter { $0.isRunning && !$0.isWaitingOnYou } }
    var recent: [WatchSession] { sessions.filter { !$0.isRunning && !$0.isWaitingOnYou } }
}

struct WatchLine: Codable, Hashable, Identifiable {
    /// "user" | "grok" | "tool" | "status" | "error"
    var kind: String
    var text: String
    var id: Int
}

struct WatchApproval: Codable, Hashable {
    var requestId: String
    /// The command for a permission; the start of the plan for a plan review.
    var command: String
    var risk: String?
    /// "destructive" | "sensitive" | nil
    var riskLevel: String?
    var allowOptionId: String?
    var denyOptionId: String?
    /// "permission" | "plan". Absent on phones that predate plan reviews, which only
    /// ever sent permissions.
    var kind: String?

    var isPlan: Bool { kind == "plan" }
    var isDestructive: Bool { riskLevel == "destructive" }
    /// A plan is answered with a yes or no; a permission needs the option id Grok
    /// offered for "allow", and a bridge too old to send it can only be denied.
    var canAllow: Bool { isPlan || allowOptionId != nil }
}

struct WatchDetail: Codable, Hashable {
    var sessionId: String
    var name: String = ""
    var busy: Bool = false
    var lines: [WatchLine] = []
    var approval: WatchApproval?
    var error: String?
    /// Grok's last stretch of prose in the current turn, whole rather than folded
    /// into a line.
    var lastReply: String?
    /// The message that started the current turn.
    var lastUser: String?
    /// When the phone read this from the computer, by the phone's clock: comparable
    /// with a snapshot's `updatedAt`, unlike anything measured on this watch.
    var fetchedAt: Date?
}

extension JSONDecoder {
    static let watch: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
