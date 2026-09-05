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
    /// Stable identity of the bridge install. Tailscale/DHCP addresses drift; this
    /// is what lets the app recognize "same computer, new IP" and update its saved
    /// entry instead of keeping one dead entry per old address.
    var serverId: String? = nil
    let grok: String?
    let grokAvailable: Bool
    var grokLatest: String? = nil   // newest grok build (from `grok update --check`)
    var grokUpdateAvailable: Bool? = nil
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
    /// The bridge's own stable identity (from /api/health). Entries saved by older
    /// app versions don't have one until their computer is reached again.
    var serverId: String? = nil
    /// This computer's plain-HTTP address from before its pinned-HTTPS upgrade —
    /// the per-computer fallback when its pinned port stops answering.
    var plainBase: String? = nil
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
        // PARSING a fixed machine format must not use the user's locale or calendar.
        // Left on Locale.current, a Japanese or Buddhist-calendar device read the
        // bridge's plain "2026-08-11" against its own era and produced nothing, so the
        // whole axis came back blank. Only the OUTPUT is localized.
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy-MM-dd"
        parser.timeZone = .current
        guard let d = parser.date(from: date) else { return "" }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate("EEE")
        return out.string(from: d)
    }
}

/// A Grok conversation tracked by the bridge.
/// What grok is blocked on, when it is blocked on you.
struct WaitingState: Codable, Hashable {
    var kind: String        // "permission" | "plan"
    var label: String?      // the command or title, for the chip
    var since: String?
    /// What it takes to answer this without fetching anything else: the request and
    /// the option ids for yes and no. Absent on bridges that predate it.
    var requestId: String?
    var allow: String?
    var deny: String?
}

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
    /// "ask" | "reads" | "all". Absent on bridges that only had the boolean.
    var approvalPolicy: String?
    var status: String
    /// Set while grok is blocked on you. A session waiting for an approval used to be
    /// indistinguishable from one busy working, so finding the stuck one among several
    /// meant opening each and scrolling to the bottom.
    var waiting: WaitingState?
    var turnCount: Int
    /// When the turn in flight began, so the list can say how long it has been going.
    /// Absent on bridges that predate it — the row then just says RUNNING, as before.
    var runningSince: String?
    var createdAt: String
    /// When anything last happened here. The bridge orders the list by it, and an
    /// idle row shows it, so "which of these did I touch this morning" is readable.
    var updatedAt: String?
    var lastEventId: Int?
    var usage: SessionUsage?
    /// Follow-ups the bridge will run when the current turn ends.
    var queue: [QueuedMessage]?
    /// The summary a compact/branch carried over. Present only until the first
    /// turn consumes it — the chat shows it so the fresh session doesn't look
    /// like it forgot everything.
    var seedContext: String?

    var isRunning: Bool { status == "running" }
    var isWaitingOnYou: Bool { waiting != nil }

    /// Effective policy, tolerating a bridge that only reports the old boolean.
    var effectiveApprovalPolicy: String {
        if let approvalPolicy, !approvalPolicy.isEmpty { return approvalPolicy }
        return (autoApprove ?? false) ? "all" : "ask"
    }

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
        let x = parts(a), y = parts(b)
        for i in 0..<3 where x[i] != y[i] { return x[i] < y[i] }
        return false
    }

    /// Always three components.
    ///
    /// This used to `compactMap { Int($0) }` and then bail out unless exactly three
    /// survived, returning false, which means "not older", which means no banner. So
    /// "1.0" and "0.1.19.1" silently disabled the app's ONLY channel for telling a user
    /// their bridge is too old, permanently, on a build that cannot be patched. And
    /// "0.2.0-beta.1" dropped its unparseable component and compared [0, 2, 1], lining
    /// the wrong numbers up against each other.
    private static func parts(_ v: String) -> [Int] {
        var out = v.split(separator: ".", omittingEmptySubsequences: false).map { field -> Int in
            // Take the leading digits, so a prerelease suffix degrades to its number.
            Int(field.prefix(while: \.isNumber)) ?? 0
        }
        while out.count < 3 { out.append(0) }
        return Array(out.prefix(3))
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

    /// How long ago something happened, for a row that is not doing anything now:
    /// just now, 12m ago, 3h ago, 2d ago.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 90 { return String(loc: "just now") }
        let minutes = seconds / 60
        if minutes < 60 { return String(loc: "\(minutes)m ago") }
        let hours = minutes / 60
        if hours < 24 { return String(loc: "\(hours)h ago") }
        return String(loc: "\(hours / 24)d ago")
    }

    /// A stopwatch reading for something still going: 12s, 4m, 1h20m. Short enough to
    /// sit inside a session row without pushing anything off the end.
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }

    /// The bridge speaks `Date.toISOString()`, which always carries milliseconds —
    /// a formatter without `.withFractionalSeconds` silently returns nil for every
    /// one of them.
    static func date(fromISO text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return isoWithFraction.date(from: text) ?? isoPlain.date(from: text)
    }
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
}

/// How a rendered conversation line should look.
enum ChatRole: Equatable {
    case user, assistant, thought, tool, status, error, permission, plan, tasks
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
    var scope: String = "builtin"    // legacy routing hint: "builtin" | "user" | "bundled" | "command"
    /// grok's own classification, unmodified by the bridge's routing policy.
    var kind: String?
    /// The bridge's explicit routing decision: "send" | "details" | "auto-approve" | "hidden".
    var routing: String?
    /// Expensive enough to confirm first. A bare /loop measured about 52k tokens.
    var costly: Bool = false

    var id: String { name }
    var display: String { "/" + name }
    var takesArgs: Bool { !hint.isEmpty }

    /// Badge text in the palette: grok's real classification, not the routing hint.
    var isBuiltin: Bool { (kind ?? scope) == "builtin" }

    /// What actually happens when this command is run.
    ///
    /// grok 0.2.x really did implement its built-ins only inside its own terminal UI.
    /// grok 1.0.0 executes them over ACP: /workflow, /goal and /feedback return real
    /// text, and /compact compacts in place. Only /context is still genuinely inert.
    ///
    /// The bridge knows which grok it is talking to, so it decides and sends `routing`.
    /// The derivation below is the fallback for a bridge too old to say.
    enum Action: Equatable {
        case send            // grok runs it
        case openDetails     // /context — inert over ACP, but the app already shows this
        case autoApprove     // /always-approve — the app owns the approval loop
        case unsupported     // hidden rather than offered as something that quietly fails
    }

    var action: Action {
        switch routing {
        case "send":         return .send
        case "details":      return .openDetails
        case "auto-approve": return .autoApprove
        case "hidden":       return .unsupported
        default: break
        }
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
        if weekdays.isEmpty { return String(loc: "Every day") }
        if weekdays.sorted() == [1, 2, 3, 4, 5] { return String(loc: "Weekdays") }
        if weekdays.sorted() == [0, 6] { return String(loc: "Weekends") }
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
    ///
    /// Localized here rather than at the badge: `label` reaches `Text` as a plain
    /// `String`, which selects the verbatim initializer, so a bare literal would
    /// never be looked up in any language. The trailing `code` stays verbatim
    /// because it is a porcelain code, not prose.
    var label: String {
        if code == "??" { return String(loc: "new") }
        if code.contains("D") { return String(loc: "deleted") }
        if code.contains("R") { return String(loc: "renamed") }
        if code.contains("A") { return String(loc: "added") }
        if code.contains("M") { return String(loc: "modified") }
        return code
    }
}

/// A repository this session actually edited files in — sessions usually start in
/// ~ (not a repo) while grok works somewhere deeper, so the review offers these.
struct GitRepoCandidate: Codable, Identifiable, Hashable {
    var root: String
    var name: String
    var id: String { root }
}

/// `GET /api/sessions/:id/git` — what changed in the reviewed repository.
struct GitStatus: Codable {
    var repo: Bool
    var branch: String?
    var files: [GitFile]?
    /// The repo the listed files belong to (nil from pre-0.1.17 bridges).
    var dir: String?
    /// Every repo this session touched, for the folder switcher.
    var candidates: [GitRepoCandidate]?
    var changedCount: Int { files?.count ?? 0 }
}

/// A saved grok workflow (a multi-agent Rhai script under .grok/workflows/).
struct WorkflowInfo: Codable, Identifiable, Hashable {
    var name: String
    var scope: String?          // "project" | "user"
    var description: String?
    var whenToUse: String?
    var id: String { name }
}

/// `GET /api/grok/update` — grok binary version state on the computer.
struct GrokUpdateStatus: Codable {
    var current: String?
    var latest: String?
    var updateAvailable: Bool
    var updating: Bool?
    var autoUpdate: Bool?
}

/// One installed grok plugin (`GET /api/grok/plugins`). Its skills show up in
/// the "/" palette on their own; this exists for management.
struct GrokPlugin: Codable, Identifiable, Hashable {
    var name: String
    var version: String?
    var source: String?
    var marketplace: String?
    var disabled: Bool?
    var description: String?
    var id: String { name }
    var isDisabled: Bool { disabled ?? false }
    /// "github.com/foo/bar" reads better than a full clone URL on one line.
    var sourceLabel: String {
        guard let source, !source.isEmpty else { return "" }
        if let host = URL(string: source)?.host { return host + (URL(string: source)?.path ?? "") }
        return (source as NSString).lastPathComponent
    }
}

/// A before/after edit Grok made to a file (from an edit tool's diff).
struct FileDiff: Equatable {
    var path: String
    var oldText: String
    var newText: String
    var filename: String { (path as NSString).lastPathComponent }
    /// Split ONCE, at construction.
    ///
    /// These were computed properties, so every access re-split the whole file, and the
    /// views read them repeatedly while building one row per line. A large rewrite
    /// therefore re-split thousands of lines many times over during a single layout.
    let oldLines: [String]
    let newLines: [String]

    init(path: String, oldText: String, newText: String) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
        self.oldLines = oldText.isEmpty ? [] : oldText.components(separatedBy: "\n")
        self.newLines = newText.isEmpty ? [] : newText.components(separatedBy: "\n")
    }
}

/// The tail of a session's event log. Events stay as raw dictionaries: the folding
/// rules differ per client (the phone builds a full transcript, the watch a dozen
/// lines), and decoding a union of every event shape would help neither.
struct TranscriptTail {
    struct Record { var id: Int; var event: [String: Any] }
    var events: [Record] = []
    var status: String = "idle"
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

    // Grok's own checklist for the turn (ACP `plan` updates). Held on ONE item that
    // is revised in place — every revision used to append another bullet dump.
    var planEntries: [PlanEntry] = []

    // Reasoning: when this block of thinking started, and when it gave way to an
    // answer. The pair is what lets the trace collapse to "Thought for 12s" instead
    // of leaving a wall of reasoning above every reply.
    var startedAt: Date? = nil
    var endedAt: Date? = nil
    /// Nil while Grok is still thinking.
    var thoughtDuration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }

    // Permission request (ACP transport)
    var requestId: String? = nil
    var options: [PermissionOption] = []
    var decided: String? = nil           // chosen optionId, or "cancelled"
}

/// A text file picked from Files, waiting in the composer.
///
/// Grok reads files on the computer itself; anything that exists only on the phone
/// has to travel inside the prompt, so this is deliberately small and text-only.
struct TextAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var text: String
    var bytes: Int

    /// Past this, a "file" is really a paste that would eat the context window.
    static let limit = 64 * 1024

    var sizeLabel: String {
        bytes >= 1024 ? "\(bytes / 1024)k" : "\(bytes)b"
    }

    /// Named and fenced, so grok can see what it is looking at.
    var fenced: String {
        let ext = (name as NSString).pathExtension
        return "`\(name)`:\n\n```\(ext)\n\(text)\n```"
    }
}
