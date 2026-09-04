import Foundation

// The payload the phone sends. The watch is a separate module on a separate
// platform, so it carries its own copy of these shapes, exactly as the widget does
// for its snapshot: only the coding keys have to agree with WatchLink.swift.

struct WatchSession: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var folder: String = ""
    var status: String = "idle"
    var waitingKind: String?
    var waitingLabel: String?
    var since: Date?
    var turns: Int = 0
    var contextFraction: Double = 0
    /// Pushed with the snapshot, so the command and its risk are readable — and
    /// answerable — without a live link to the phone.
    var approval: WatchApproval?

    var isRunning: Bool { status == "running" }
    var isWaitingOnYou: Bool { waitingKind != nil }
}

struct WatchSnapshot: Codable, Hashable {
    var computer: String = ""
    var connected: Bool = false
    var sessions: [WatchSession] = []
    var updatedAt: Date = Date()

    var waitingCount: Int { sessions.filter(\.isWaitingOnYou).count }
    var runningCount: Int { sessions.filter(\.isRunning).count }

    /// Blocked first, then working, then the rest: on a screen this small the order
    /// is the whole navigation.
    var ordered: [WatchSession] {
        sessions.sorted { a, b in
            func rank(_ s: WatchSession) -> Int { s.isWaitingOnYou ? 0 : (s.isRunning ? 1 : 2) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

struct WatchLine: Codable, Hashable, Identifiable {
    var kind: String
    var text: String
    var id: Int
}

struct WatchApproval: Codable, Hashable {
    var requestId: String
    var command: String
    var risk: String?
    var riskLevel: String?
    var allowOptionId: String?
    var denyOptionId: String?

    var isDestructive: Bool { riskLevel == "destructive" }
}

struct WatchDetail: Codable, Hashable {
    var sessionId: String
    var name: String = ""
    var busy: Bool = false
    var lines: [WatchLine] = []
    var approval: WatchApproval?
    var error: String?
}

enum Fmt {
    /// A stopwatch reading short enough for a watch row: 12s, 4m, 1h20m.
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }
}

extension JSONDecoder {
    static let watch: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
