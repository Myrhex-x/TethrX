import Foundation
import UIKit

/// Response of `GET /api/health`.
struct HealthInfo: Codable {
    /// The bridge's pinned-HTTPS listener, when it has one.
    struct TlsInfo: Codable {
        let port: Int
        let fingerprint: String   // SHA-256 hex of its self-signed cert
    }
    let ok: Bool
    let name: String?
    let host: String?          // the computer's hostname — used to name a paired bridge
    let grok: String?
    let grokAvailable: Bool
    var version: String?       // the bridge's own version
    var latestVersion: String? // newest on npm (checked at most daily; nil offline)
    var tls: TlsInfo?
}

/// A paired computer. Its pairing token lives in the Keychain, keyed by `id`,
/// so several machines (laptop + desktop) can stay paired at once.
struct SavedBridge: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var address: String
    /// Cert fingerprint when this computer is reached over pinned HTTPS.
    var pin: String? = nil
    var tokenAccount: String { "bridge.token." + id }
}

/// One session matched by full-text search, with a few snippets.
struct SearchResult: Codable, Identifiable {
    struct Hit: Codable, Hashable {
        var eventId: Int
        var kind: String
        var snippet: String
    }
    var sessionId: String
    var title: String
    var count: Int
    var hits: [Hit]
    var id: String { sessionId }
}

/// A follow-up waiting for the running turn to finish. Held by the BRIDGE, so it
/// survives the app being closed — and so a lock-screen reply can add one.
struct QueuedMessage: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var source: String?    // "phone" | "reply" | "share" | "reason"
    var at: String?
}

/// One day's token/cost totals from `GET /api/usage/history`.
struct UsageDay: Codable, Identifiable, Hashable {
    var date: String       // YYYY-MM-DD, the computer's local day
    var turns = 0
    var inputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0
    var cachedReadTokens = 0
    var totalTokens = 0
    var costUsdTicks: Double = 0
    var apiDurationMs: Double = 0

    var id: String { date }
    var costUSD: Double { costUsdTicks / 1e10 }

    /// "Mon", for the chart's axis.
    var weekdayLabel: String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        guard let d = parser.date(from: date) else { return "" }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate("EEE")
        return out.string(from: d)
    }
}

/// A Grok conversation tracked by the bridge.
struct SessionInfo: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var folder: String?
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
    var usage: SessionUsage?
    /// Follow-ups the bridge will run when the current turn ends.
    var queue: [QueuedMessage]?

    var isRunning: Bool { status == "running" }

    /// What the UI shows. Renaming writes `title`, so it has to win here — the views
    /// used to render the working directory's folder name unconditionally, which made
    /// renaming look completely broken even though it saved correctly.
    var displayName: String {
        let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !named.isEmpty, named != "New session" { return named }
        if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return "session"
    }
}

/// Token / cost usage grok reports, accumulated per session by the bridge.
/// `contextTokens` vs `contextWindow` is the live context-window meter; the rest
/// are lifetime totals for the session.
struct SessionUsage: Codable, Hashable {
    var turns = 0
    var inputTokens = 0
    var outputTokens = 0
    var reasoningTokens = 0        // grok's "thinking" tokens
    var cachedReadTokens = 0
    var totalTokens = 0
    var costUsdTicks: Double = 0   // grok-reported cost; USD = ticks / 1e10
    var apiDurationMs: Double = 0
    var contextTokens = 0          // ~current conversation footprint
    var contextWindow = 0          // model's max context (e.g. 500k)
    var lastModelId = ""

    var costUSD: Double { costUsdTicks / 1e10 }
    var contextFraction: Double { contextWindow > 0 ? min(1, Double(contextTokens) / Double(contextWindow)) : 0 }
    var contextRemaining: Int { max(0, contextWindow - contextTokens) }

    enum CodingKeys: String, CodingKey {
        case turns, inputTokens, outputTokens, reasoningTokens, cachedReadTokens, totalTokens
        case costUsdTicks, apiDurationMs, contextTokens, contextWindow, lastModelId
    }

    init() {}

    // Tolerant decode: any missing/mistyped key falls back to its default (older
    // sessions, future fields); an SSE `usage` dictionary decodes the same way.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys) -> Int { (try? c.decode(Int.self, forKey: k)) ?? 0 }
        func d(_ k: CodingKeys) -> Double { (try? c.decode(Double.self, forKey: k)) ?? 0 }
        turns = i(.turns); inputTokens = i(.inputTokens); outputTokens = i(.outputTokens)
        reasoningTokens = i(.reasoningTokens); cachedReadTokens = i(.cachedReadTokens); totalTokens = i(.totalTokens)
        costUsdTicks = d(.costUsdTicks); apiDurationMs = d(.apiDurationMs)
        contextTokens = i(.contextTokens); contextWindow = i(.contextWindow)
        lastModelId = (try? c.decode(String.self, forKey: .lastModelId)) ?? ""
    }
}

/// Response of `GET /api/usage` — token/cost totals across all sessions.
struct UsageReport: Codable {
    struct Totals: Codable {
        var turns = 0, inputTokens = 0, outputTokens = 0, reasoningTokens = 0
        var cachedReadTokens = 0, totalTokens = 0
        var costUsdTicks: Double = 0, apiDurationMs: Double = 0
    }
    var totals = Totals()
    var sessionCount = 0
    var contextWindow = 0
    var costUSD: Double { totals.costUsdTicks / 1e10 }
}

/// Tiny numeric semver comparison. nil counts as older — bridges before 0.1.12
/// didn't report a version at all.
enum Semver {
    static func isOlder(_ a: String?, than b: String) -> Bool {
        guard let a, !a.isEmpty else { return true }
        let x = a.split(separator: ".").compactMap { Int($0) }
        let y = b.split(separator: ".").compactMap { Int($0) }
        guard x.count == 3, y.count == 3 else { return false }
        for i in 0..<3 where x[i] != y[i] { return x[i] < y[i] }
        return false
    }
}

/// Human-friendly formatting for tokens, cost, and durations.
enum Fmt {
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
    static func cost(_ usd: Double) -> String {
        if usd <= 0 { return "$0.00" }
        if usd < 0.01 { return String(format: "$%.4f", usd) }
        return String(format: "$%.2f", usd)
    }
    static func duration(_ ms: Double) -> String {
        let s = ms / 1000
        if s >= 60 { return String(format: "%.1f min", s / 60) }
        return String(format: "%.1fs", s)
    }
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

/// A grok slash command advertised over ACP (built-ins like /compact plus skills).
struct SlashCommand: Codable, Identifiable, Hashable {
    var name: String                 // without the leading slash, e.g. "compact"
    var description: String = ""
    var hint: String = ""            // arg hint from the command's input, if any
    var scope: String = "builtin"    // "builtin" | "user" | "bundled"
    var id: String { name }
    var display: String { "/" + name }
    var takesArgs: Bool { !hint.isEmpty }

    /// What actually happens when this command is run.
    ///
    /// grok implements its built-in commands only inside its own terminal UI. Sent over
    /// ACP they arrive, produce zero tokens and no events, and do nothing — verified
    /// against /compact. Skills, by contrast, execute as a normal turn. So skills are
    /// passed through, the built-ins the app can perform itself are handled locally,
    /// and the remainder are hidden rather than offered as commands that quietly fail.
    enum Action: Equatable {
        case send            // a skill — grok runs it
        case openDetails     // /context, /session-info — the app already shows this
        case autoApprove     // /always-approve — the app has a real toggle
        case unsupported     // /compact, /goal, /loop, /feedback — inert over ACP
    }

    var action: Action {
        guard scope == "builtin" else { return .send }
        switch name {
        case "context", "session-info": return .openDetails
        case "always-approve":          return .autoApprove
        default:                        return .unsupported
        }
    }

    var isUsable: Bool { action != .unsupported }
}

/// One entry of `GET /api/fs/dirs` — the working-directory picker.
struct DirListing: Codable {
    struct Dir: Codable, Identifiable, Hashable {
        var name: String
        var path: String
        var id: String { path }
    }
    var path: String
    var parent: String?
    var dirs: [Dir]
}

/// One entry of a session's project tree (`GET /api/sessions/:id/files`).
struct FileEntry: Codable, Identifiable, Hashable {
    var name: String
    var dir: Bool
    var size: Int
    var id: String { name }
}

/// `GET /api/sessions/:id/file` — a text file's content (or a binary marker).
struct FileContent: Codable {
    var path: String
    var size: Int
    var binary: Bool
    var truncated: Bool?
    var content: String?
}

/// A bridge-side scheduled task, tied to a session; fires on the computer's clock.
struct BridgeSchedule: Codable, Identifiable, Hashable {
    var id: String
    var sessionId: String
    var prompt: String
    var hour: Int
    var minute: Int
    var weekdays: [Int]      // 0=Sunday … 6=Saturday; empty = every day
    var enabled: Bool

    var timeLabel: String { String(format: "%02d:%02d", hour, minute) }
    /// "Every day", "Weekdays", or short day names.
    var daysLabel: String {
        if weekdays.isEmpty { return String(localized: "Every day") }
        if weekdays.sorted() == [1, 2, 3, 4, 5] { return String(localized: "Weekdays") }
        if weekdays.sorted() == [0, 6] { return String(localized: "Weekends") }
        let symbols = Calendar.current.shortWeekdaySymbols   // Sun-first, matching 0=Sunday
        return weekdays.sorted().compactMap { symbols.indices.contains($0) ? symbols[$0] : nil }.joined(separator: " ")
    }
}

/// One changed file in the session's working directory.
struct GitFile: Codable, Identifiable, Hashable {
    var path: String
    var code: String
    var staged: Bool
    var id: String { path }
    var filename: String { (path as NSString).lastPathComponent }
    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }
    /// Human label for git's porcelain status code.
    var label: String {
        if code == "??" { return "new" }
        if code.contains("D") { return "deleted" }
        if code.contains("R") { return "renamed" }
        if code.contains("A") { return "added" }
        if code.contains("M") { return "modified" }
        return code
    }
}

/// `GET /api/sessions/:id/git` — what changed in the session's folder.
struct GitStatus: Codable {
    var repo: Bool
    var branch: String?
    var files: [GitFile]?
    var changedCount: Int { files?.count ?? 0 }
}

/// A before/after edit Grok made to a file (from an edit tool's diff).
struct FileDiff: Equatable {
    var path: String
    var oldText: String
    var newText: String
    var filename: String { (path as NSString).lastPathComponent }
    var oldLines: [String] { oldText.isEmpty ? [] : oldText.components(separatedBy: "\n") }
    var newLines: [String] { newText.isEmpty ? [] : newText.components(separatedBy: "\n") }
}

/// One rendered line in the conversation. Streaming text is appended into the
/// `text` of the current assistant/thought item, so bubbles grow token-by-token.
struct ChatItem: Identifiable, Equatable {
    let id = UUID()
    var role: ChatRole
    var text: String

    // Attached images on a user message. `images` holds the actual thumbnails for
    // a message sent from THIS device; history replay only knows the count.
    var images: [UIImage] = []
    var imageCount: Int = 0

    // Tool activity (ACP transport)
    var toolCallId: String? = nil
    var toolStatus: String? = nil        // "running" | "completed" | "failed"
    var toolOutput: String? = nil        // stdout/stderr the tool produced
    var diff: FileDiff? = nil            // for edit tools

    // Permission request (ACP transport)
    var requestId: String? = nil
    var options: [PermissionOption] = []
    var decided: String? = nil           // chosen optionId, or "cancelled"
}
