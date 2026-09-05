import Foundation
import WatchConnectivity

// MARK: - The wire between the phone and the watch
//
// The watch never talks to the bridge itself. It asks the phone, and the phone —
// which already holds the pairing token, the pinned certificate and whichever
// computer is selected — makes the call. That keeps one copy of the credentials on
// one device, and it means the watch works over Tailscale, a hotspot or a pinned
// LAN certificate without knowing any of that exists.
//
// The watch target keeps its own copy of these shapes (it is a separate module and
// a separate platform); only the coding keys have to agree.

/// One row in the watch's list.
struct WatchSession: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var folder: String = ""
    /// "idle" | "running"
    var status: String = "idle"
    /// "permission" | "plan" while grok is blocked on you, else nil.
    var waitingKind: String?
    var waitingLabel: String?
    /// When the running turn began, or when the block started.
    var since: Date?
    var turns: Int = 0
    var contextFraction: Double = 0
    /// Everything needed to answer the block, pushed with the snapshot rather than
    /// fetched. A watch out of range of its phone can still show the command and
    /// hold an answer for it.
    var approval: WatchApproval?

    var isRunning: Bool { status == "running" }
    var isWaitingOnYou: Bool { waitingKind != nil }
}

/// What the watch shows without asking for anything: the computer and its sessions.
struct WatchSnapshot: Codable, Hashable {
    var computer: String = ""
    var connected: Bool = false
    var sessions: [WatchSession] = []
    var updatedAt: Date = Date()

    var waitingCount: Int { sessions.filter(\.isWaitingOnYou).count }
    var runningCount: Int { sessions.filter(\.isRunning).count }
}

/// One folded line of a conversation, small enough for a watch screen.
struct WatchLine: Codable, Hashable, Identifiable {
    /// "user" | "grok" | "tool" | "status" | "error"
    var kind: String
    var text: String
    var id: Int
}

/// The approval the watch is being asked to answer.
struct WatchApproval: Codable, Hashable {
    var requestId: String
    var command: String
    /// The one-line reason from CommandRisk, already resolved on the phone so the
    /// watch does not carry a second copy of the pattern list.
    var risk: String?
    /// "destructive" | "sensitive" | nil
    var riskLevel: String?
    var allowOptionId: String?
    var denyOptionId: String?
}

/// The tail of one conversation.
struct WatchDetail: Codable, Hashable {
    var sessionId: String
    var name: String = ""
    var busy: Bool = false
    var lines: [WatchLine] = []
    var approval: WatchApproval?
    var error: String?
}

// MARK: - Phone side

/// Serves the watch: keeps it supplied with a snapshot, and performs the calls it
/// asks for. A no-op on devices with no paired watch.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    /// True once a watch is paired AND has the app installed — the phone skips all
    /// of this otherwise.
    @Published private(set) var active = false
    /// Whether a watch is paired at all. "Not installed" and "no watch" are different
    /// problems with different fixes, and telling someone to install an app on a
    /// watch they do not own is the kind of advice that reads as broken.
    @Published private(set) var paired = false

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var lastPushed: WatchSnapshot?

    func start() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// Push the current sessions to the watch. Cheap and idempotent: identical
    /// snapshots are dropped, since application context is latest-wins anyway and a
    /// redundant write still wakes the watch.
    func publish(_ snapshot: WatchSnapshot) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        var next = snapshot
        next.updatedAt = Date()
        // Compare everything except the timestamp, which changes every call.
        if var previous = lastPushed {
            previous.updatedAt = next.updatedAt
            if previous == next { return }
        }
        lastPushed = next
        guard let data = try? JSONEncoder.watch.encode(next) else { return }
        try? session.updateApplicationContext(["snapshot": data])
    }

    /// Build a snapshot from whatever the app currently knows.
    static func snapshot(from app: AppState) -> WatchSnapshot {
        WatchSnapshot(
            computer: app.health?.host ?? (URL(string: app.normalizedBase)?.host ?? ""),
            connected: app.connected,
            sessions: app.sessions.map { session in
                WatchSession(
                    id: session.id,
                    name: session.displayName,
                    folder: session.folder ?? "",
                    status: session.status,
                    waitingKind: session.waiting?.kind,
                    waitingLabel: session.waiting?.label,
                    since: Fmt.date(fromISO: session.isWaitingOnYou ? session.waiting?.since : session.runningSince),
                    turns: session.turnCount,
                    contextFraction: session.usage?.contextFraction ?? 0,
                    approval: approval(for: session)
                )
            }
        )
    }

    /// The pending approval, built from the session metadata alone — no transcript
    /// fetch, so it survives in a snapshot the phone pushed hours ago.
    private static func approval(for session: SessionInfo) -> WatchApproval? {
        guard let waiting = session.waiting, waiting.kind == "permission",
              let requestId = waiting.requestId else { return nil }
        let command = waiting.label ?? ""
        let risk = CommandRisk.assess(command)
        return WatchApproval(
            requestId: requestId,
            command: command,
            risk: risk.map { String(localized: $0.reason) },
            riskLevel: risk.map { $0.level == .destructive ? "destructive" : "sensitive" },
            allowOptionId: waiting.allow,
            denyOptionId: waiting.deny
        )
    }
}

// MARK: - Requests from the watch

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let usable = state == .activated && session.isPaired && session.isWatchAppInstalled
        let isPaired = session.isPaired
        Task { @MainActor in
            self.active = usable
            self.paired = isPaired
            if usable { self.publish(Self.snapshot(from: AppState.shared)) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another watch: reactivate, or the phone goes silent for the
        // rest of the launch.
        session.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let usable = session.isPaired && session.isWatchAppInstalled
        let isPaired = session.isPaired
        Task { @MainActor in
            self.active = usable
            self.paired = isPaired
            if usable { self.publish(Self.snapshot(from: AppState.shared)) }
        }
    }

    /// An action the watch queued while this phone was out of reach. It arrives
    /// whenever the system can deliver it, including a launch in the background, and
    /// the watch is told so it can stop showing the tap as pending.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            let reply = await self.handle(userInfo)
            guard reply["ok"] as? Bool == true, let requestId = userInfo["requestId"] as? String else { return }
            session.transferUserInfo(["answered": requestId])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // The watch waits on this, so every path must reply exactly once, including
        // the failures. A dropped reply is a watch spinner that never stops.
        Task { @MainActor in
            let reply = await self.handle(message)
            replyHandler(reply)
        }
    }

    @MainActor
    private func handle(_ message: [String: Any]) async -> [String: Any] {
        let command = message["cmd"] as? String ?? ""
        let app = AppState.shared
        switch command {
        case "snapshot":
            await app.reloadSessions(quiet: true)
            let snapshot = Self.snapshot(from: app)
            publish(snapshot)
            return encoded(snapshot, as: "snapshot")

        case "detail":
            guard let id = message["sessionId"] as? String else { return ["error": "no session"] }
            return encoded(await detail(sessionId: id), as: "detail")

        case "decide":
            guard let client = app.client,
                  let id = message["sessionId"] as? String,
                  let requestId = message["requestId"] as? String else { return ["error": "not connected"] }
            let optionId = message["optionId"] as? String
            let reason = (message["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try await client.resolvePermission(sessionId: id, requestId: requestId,
                                                   optionId: optionId, always: false,
                                                   reason: (reason?.isEmpty == false) ? reason : nil)
                await app.reloadSessions(quiet: true)
                publish(Self.snapshot(from: app))
                return ["ok": true]
            } catch {
                return ["error": Self.readable(error)]
            }

        case "reply":
            guard let client = app.client,
                  let id = message["sessionId"] as? String,
                  let text = message["text"] as? String, !text.isEmpty else { return ["error": "not connected"] }
            do {
                _ = try await client.enqueue(sessionId: id, text: text)
                return ["ok": true]
            } catch {
                return ["error": Self.readable(error)]
            }

        case "stop":
            guard let client = app.client, let id = message["sessionId"] as? String else { return ["error": "not connected"] }
            do {
                try await client.cancelOrThrow(sessionId: id)
                await app.reloadSessions(quiet: true)
                publish(Self.snapshot(from: app))
                return ["ok": true]
            } catch {
                return ["error": Self.readable(error)]
            }

        default:
            return ["error": "unknown request"]
        }
    }

    /// Fold the bridge's event tail into the handful of lines a watch can show, and
    /// find the approval it is waiting on.
    @MainActor
    private func detail(sessionId: String) async -> WatchDetail {
        var detail = WatchDetail(sessionId: sessionId)
        let app = AppState.shared
        guard let client = app.client else {
            detail.error = String(localized: "Not connected to a computer.")
            return detail
        }
        detail.name = app.sessions.first(where: { $0.id == sessionId })?.displayName ?? ""
        do {
            let tail = try await client.tail(sessionId: sessionId, count: 120)
            detail.busy = tail.status == "running"
            var lines: [WatchLine] = []
            var pending: WatchApproval?
            var resolved: Set<String> = []

            for record in tail.events {
                let event = record.event
                switch event["kind"] as? String {
                case "turn_start":
                    append(&lines, kind: "user", text: event["text"] as? String ?? "")
                case "text":
                    // Streamed prose arrives ~4 characters at a time; merge it back.
                    append(&lines, kind: "grok", text: event["text"] as? String ?? "", merge: true)
                case "tool_call":
                    let label = (event["command"] as? String) ?? (event["title"] as? String) ?? (event["tool"] as? String) ?? ""
                    append(&lines, kind: "tool", text: label)
                case "error":
                    append(&lines, kind: "error", text: event["message"] as? String ?? "")
                case "permission_request":
                    guard let requestId = event["requestId"] as? String else { break }
                    let command = (event["command"] as? String) ?? (event["title"] as? String)
                        ?? (event["tool"] as? String) ?? ""
                    let options = (event["options"] as? [[String: Any]]) ?? []
                    let allow = options.first { ($0["kind"] as? String ?? "").lowercased().contains("allow") }
                    let deny = options.first { !(($0["kind"] as? String ?? "").lowercased().contains("allow")) }
                    let risk = CommandRisk.assess(command)
                    pending = WatchApproval(
                        requestId: requestId,
                        command: command,
                        risk: risk.map { String(localized: $0.reason) },
                        riskLevel: risk.map { $0.level == .destructive ? "destructive" : "sensitive" },
                        allowOptionId: allow?["optionId"] as? String,
                        denyOptionId: deny?["optionId"] as? String
                    )
                case "permission_resolved":
                    if let requestId = event["requestId"] as? String { resolved.insert(requestId) }
                default:
                    break
                }
            }
            if let found = pending, resolved.contains(found.requestId) { pending = nil }
            detail.approval = pending
            detail.lines = Array(lines.suffix(12))
        } catch {
            detail.error = Self.readable(error)
        }
        return detail
    }

    /// Append a line, merging into the previous one when it is the same kind and the
    /// text is a continuation (streamed prose).
    private func append(_ lines: inout [WatchLine], kind: String, text: String, merge: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if merge, let last = lines.last, last.kind == kind {
            lines[lines.count - 1].text += text
            return
        }
        guard !trimmed.isEmpty || merge else { return }
        lines.append(WatchLine(kind: kind, text: text, id: lines.count))
    }

    private func encoded<T: Encodable>(_ value: T, as key: String) -> [String: Any] {
        guard let data = try? JSONEncoder.watch.encode(value) else { return ["error": "could not encode"] }
        return [key: data]
    }

    private static func readable(_ error: Error) -> String {
        (error as? BridgeError)?.errorDescription ?? error.localizedDescription
    }
}

extension JSONEncoder {
    /// One encoder for both directions, so dates survive the trip.
    static let watch: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let watch: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
