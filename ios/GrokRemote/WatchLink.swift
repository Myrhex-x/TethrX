import Combine
import Foundation
import UIKit
import WatchConnectivity

// MARK: - The wire between the phone and the watch
//
// The watch never talks to the bridge itself. It asks the phone, and the phone,
// which already holds the pairing token, the pinned certificate and whichever
// computer is selected, makes the call. That keeps one copy of the credentials on
// one device, and it means the watch works over Tailscale, a hotspot or a pinned
// LAN certificate without knowing any of that exists.
//
// The watch target keeps its own copy of these shapes (it is a separate module and
// a separate platform); only the coding keys have to agree. Every field added after
// the first release is optional on both sides, so a phone and a watch on different
// builds still decode each other's payloads.

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
    /// When anything last happened here, for an idle row.
    var lastActivity: Date?

    var isRunning: Bool { status == "running" }
    var isWaitingOnYou: Bool { waitingKind != nil }
}

/// What the watch shows without asking for anything: the computer and its sessions.
struct WatchSnapshot: Codable, Hashable {
    var computer: String = ""
    /// Whether this phone has a computer to talk to. False means none is paired, or
    /// the user disconnected; a computer that is merely asleep still counts, so the
    /// watch never tells someone with a perfectly good pairing to pair again.
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

/// What the watch is being asked to answer: a permission, or a plan review.
struct WatchApproval: Codable, Hashable {
    var requestId: String
    /// The command for a permission; the start of the plan for a plan review.
    var command: String
    /// The one-line reason from CommandRisk, already resolved on the phone so the
    /// watch does not carry a second copy of the pattern list.
    var risk: String?
    /// "destructive" | "sensitive" | nil
    var riskLevel: String?
    var allowOptionId: String?
    var denyOptionId: String?
    /// "permission" | "plan". Watches that predate plan reviews ignore it.
    var kind: String?
}

/// The tail of one conversation.
struct WatchDetail: Codable, Hashable {
    var sessionId: String
    var name: String = ""
    var busy: Bool = false
    var lines: [WatchLine] = []
    var approval: WatchApproval?
    var error: String?
    /// Grok's last stretch of prose in the current turn, whole rather than folded
    /// into a line. Nil while a fresh turn has said nothing yet, so an answer to the
    /// previous question is never shown under the new one.
    var lastReply: String?
    /// The message that started the current turn.
    var lastUser: String?
    /// When the phone read this from the computer, by the phone's clock, so the watch
    /// can tell it apart from a snapshot taken before or after it.
    var fetchedAt: Date?
}

// MARK: - Phone side

/// Serves the watch: keeps it supplied with a snapshot, and performs the calls it
/// asks for. A no-op on devices with no paired watch.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    static let shared = WatchLink()

    /// True once a watch is paired AND has the app installed. The phone skips all
    /// of this otherwise.
    @Published private(set) var active = false
    /// Whether a watch is paired at all. "Not installed" and "no watch" are different
    /// problems with different fixes, and telling someone to install an app on a
    /// watch they do not own is the kind of advice that reads as broken.
    @Published private(set) var paired = false
    /// Whether the watch is in range and awake right now. "Installed" answered a
    /// different question from the one someone staring at a blank watch is asking,
    /// and left them with nothing to check.
    @Published private(set) var reachable = false
    /// When the phone last got a snapshot through, so the settings page can say
    /// whether the link is working or merely configured.
    @Published private(set) var lastDelivered: Date?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var lastPushed: WatchSnapshot?
    private var started = false
    private var subscriptions: Set<AnyCancellable> = []
    /// The last of the queued requests from the watch, which the next one waits on.
    private var queuedWork: Task<Void, Never>?

    /// Limits on what crosses to the watch. Application context has an undocumented
    /// ceiling well below what people assume, and a payload over it is refused
    /// outright (WCErrorCodePayloadTooLarge), which leaves the watch on its last
    /// snapshot with no sign anything went wrong. These keep it far from that line.
    enum Budget {
        static let snapshotBytes = 50_000
        static let text = 300
        static let commandBytes = 2_048
        static let line = 400
        static let reply = 600
    }

    /// Idempotent. Called from the app delegate at launch, because a message from the
    /// watch can launch this app in the background with no scene, and again from the
    /// scene, which is harmless.
    func start() {
        guard !started else { return }
        started = true
        guard let session else { return }
        session.delegate = self
        session.activate()

        // Every change to the list reaches the watch, not only the moments something
        // connects. A burst of changes (a reload that touches several sessions, a turn
        // ending) settles first, and `publish` drops anything the watch already has.
        let app = AppState.shared
        app.$sessions.map { _ in () }
            .merge(with: app.$connected.map { _ in () }, app.$demoMode.map { _ in () })
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.publish(Self.snapshot(from: AppState.shared))
            }
            .store(in: &subscriptions)
    }

    /// Push regardless of whether anything changed.
    ///
    /// The dedupe in `publish` is right for the steady state and wrong for every
    /// moment the watch's own copy is gone: reinstall the watch app and the phone
    /// would compare the new snapshot against one the watch never received, decide
    /// nothing had changed, and leave it blank until something else moved.
    func republish() {
        lastPushed = nil
        publish(Self.snapshot(from: AppState.shared))
    }

    /// Push the current sessions to the watch. Cheap and idempotent: identical
    /// snapshots are dropped, since application context is latest-wins anyway and a
    /// redundant write still wakes the watch.
    func publish(_ snapshot: WatchSnapshot) {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        reachable = session.isReachable
        guard Self.hasSettled(AppState.shared) else { return }
        let next = Self.fitted(snapshot)
        // Compare everything except the timestamp: the same list read again is not
        // worth waking the watch for.
        if var previous = lastPushed {
            previous.updatedAt = next.updatedAt
            if previous == next { return }
        }
        lastPushed = next
        guard let data = try? JSONEncoder.watch.encode(next) else {
            lastPushed = nil
            return
        }
        do {
            try session.updateApplicationContext(["snapshot": data])
            lastDelivered = next.updatedAt
        } catch {
            // Handed back so the next attempt is not deduped against a push that
            // never left the phone.
            lastPushed = nil
        }
    }

    /// Whether what the app holds is worth putting on a wrist. Just after launch, and
    /// while a computer is being reached, the list is empty because nothing has
    /// loaded yet, not because nothing is running. Pushing that blanked a watch that
    /// held a perfectly good list a moment before, and a background launch can be
    /// suspended before its first load, leaving the watch blank for good. Better the
    /// last real list, which says how old it is.
    static func hasSettled(_ app: AppState) -> Bool {
        if app.connected || app.demoMode || !app.sessions.isEmpty { return true }
        // No computer to wait for is itself the answer.
        return app.client == nil || app.userDisconnected
    }

    /// Build a snapshot from whatever the app currently knows, already inside the
    /// watch's budget.
    static func snapshot(from app: AppState) -> WatchSnapshot {
        let host = app.health?.host ?? (URL(string: app.normalizedBase)?.host ?? "")
        let snapshot = WatchSnapshot(
            computer: clip(host, Budget.text),
            // Not `app.connected` alone: a watch request can launch this app in the
            // background, where the scene's launch reconnect never runs, and the watch
            // would then say "No computer paired" to someone who has one.
            connected: app.connected || (app.client != nil && !app.userDisconnected),
            sessions: app.sessions.map { session in
                WatchSession(
                    id: session.id,
                    name: clip(session.displayName, Budget.text),
                    folder: clip(session.folder ?? "", Budget.text),
                    status: session.status,
                    waitingKind: session.waiting?.kind,
                    waitingLabel: session.waiting?.label.map { clip($0, Budget.text) },
                    since: Fmt.date(fromISO: session.isWaitingOnYou ? session.waiting?.since : session.runningSince),
                    turns: session.turnCount,
                    contextFraction: session.usage?.contextFraction ?? 0,
                    approval: approval(for: session),
                    // Idle rows only. The bridge moves `updatedAt` on every streamed
                    // event, so sending it for a running session would defeat the
                    // dedupe and wake the watch on every poll for as long as Grok types.
                    lastActivity: (session.isRunning || session.isWaitingOnYou)
                        ? nil : Fmt.date(fromISO: session.updatedAt ?? session.createdAt)
                )
            },
            // How old the list is, not when it was pushed: the watch compares these
            // to keep the newer of two copies, and says "Updated … ago" from it.
            updatedAt: app.sessionsAt
        )
        return fitted(snapshot)
    }

    /// The snapshot, with the oldest idle sessions left off until it fits. What is
    /// waiting or running always goes: those are the reasons to look at a wrist.
    static func fitted(_ snapshot: WatchSnapshot) -> WatchSnapshot {
        var fitted = snapshot
        while let size = try? JSONEncoder.watch.encode(fitted).count, size > Budget.snapshotBytes {
            let idle = fitted.sessions.indices.filter {
                !fitted.sessions[$0].isRunning && !fitted.sessions[$0].isWaitingOnYou
            }
            guard !idle.isEmpty else { break }
            // The bridge lists the most recently active first, so the tail of the idle
            // rows is the oldest. Drop roughly as many as the overflow needs at once
            // rather than re-encoding for every single row.
            let perSession = max(1, size / max(1, fitted.sessions.count))
            let excess = max(1, (size - Budget.snapshotBytes) / perSession + 1)
            for index in idle.suffix(excess).reversed() { fitted.sessions.remove(at: index) }
        }
        return fitted
    }

    /// The pending request, built from the session metadata alone (no transcript
    /// fetch), so it survives in a snapshot the phone pushed hours ago.
    private static func approval(for session: SessionInfo) -> WatchApproval? {
        guard let waiting = session.waiting, let requestId = waiting.requestId else { return nil }
        switch waiting.kind {
        case "permission":
            var approval = permission(requestId: requestId, command: waiting.commandText,
                                      allow: waiting.allow, deny: waiting.deny)
            if waiting.commandMayBeCut {
                // An older bridge cut this at 120 characters, and the end of a
                // command is where `&& git push --force` lives. Shown as cut, and
                // never one tap to allow: the watch confirms anything destructive.
                approval.command += "\u{2026}"
                approval.riskLevel = "destructive"
                if approval.risk == nil { approval.risk = String(loc: "Only the start of this command is shown.") }
            }
            return approval
        case "plan":
            // The plan's text is not in the metadata; the detail fetch brings it.
            return WatchApproval(requestId: requestId, command: "", kind: "plan")
        default:
            return nil
        }
    }

    private static func permission(requestId: String, command: String,
                                   allow: String?, deny: String?) -> WatchApproval {
        let risk = CommandRisk.assess(command)
        return WatchApproval(
            requestId: requestId,
            command: clip(command, bytes: Budget.commandBytes),
            risk: risk.map { clip(String(resolving: $0.reason), Budget.text) },
            riskLevel: risk.map { $0.level == .destructive ? "destructive" : "sensitive" },
            allowOptionId: allow,
            denyOptionId: deny,
            kind: "permission"
        )
    }
}

// MARK: - Requests from the watch

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let usable = state == .activated && session.isPaired && session.isWatchAppInstalled
        let isPaired = session.isPaired
        let canReach = session.isReachable
        Task { @MainActor in
            self.active = usable
            self.paired = isPaired
            self.reachable = canReach
            // A fresh activation is exactly the case the dedupe must not apply to:
            // whatever the watch holds, this phone has no idea what it is.
            if usable { self.republish() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let canReach = session.isReachable
        Task { @MainActor in
            self.reachable = canReach
            // Coming back into range is the moment to catch the watch up.
            if canReach, self.active { self.republish() }
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
            // Installing or reinstalling the watch app leaves it with nothing, so
            // this push must not be compared against what the last watch held.
            if usable { self.republish() }
        }
    }

    /// Something the watch queued while this phone was out of reach. It arrives
    /// whenever the system can deliver it, including a launch in the background.
    /// The watch is told how an answer went either way: on success so it stops
    /// showing the tap as pending, and on failure so it stops saying "sent" about a
    /// decision that never reached the computer.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let command = userInfo["cmd"] as? String
        let requestId = userInfo["requestId"] as? String
        let text = userInfo["text"] as? String
        Task { @MainActor in
            // One at a time, in the order they arrive. Each handler waits on the
            // network, so two follow-ups dictated out of range could otherwise reach
            // the computer the other way round.
            let previous = self.queuedWork
            let work = Task { @MainActor in
                await previous?.value
                await self.handleQueued(userInfo, command: command, requestId: requestId, text: text)
            }
            self.queuedWork = work
        }
    }

    private func handleQueued(_ userInfo: [String: Any], command: String?, requestId: String?, text: String?) async {
        let reply = await Self.keepingAlive { await self.handle(userInfo) }
        let failure = reply["error"] as? String
        if let requestId, command == "decide" || command == "plan" {
            var report: [String: Any] = ["answered": requestId, "ok": failure == nil]
            if let failure { report["error"] = failure }
            if WCSession.default.activationState == .activated {
                WCSession.default.transferUserInfo(report)
            }
        } else if command == "reply", failure != nil, let text {
            // The words existed only on the wrist. Hand them back rather than
            // letting them vanish.
            PushManager.notifyUndelivered(text)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // The watch waits on this, so every path must reply exactly once, including
        // the failures. A dropped reply is a watch spinner that never stops.
        Task { @MainActor in
            let reply = await Self.keepingAlive { await self.handle(message) }
            replyHandler(reply)
        }
    }

    private func handle(_ message: [String: Any]) async -> [String: Any] {
        let command = message["cmd"] as? String ?? ""
        let app = AppState.shared
        switch command {
        case "snapshot":
            await app.reloadSessions(quiet: true)
            // An empty list that only means "not loaded" would replace a good one;
            // the watch keeps what it has when this comes back as an error.
            guard Self.hasSettled(app) else { return ["error": Self.notConnected] }
            let snapshot = Self.snapshot(from: app)
            publish(snapshot)
            return encoded(snapshot, as: "snapshot")

        case "detail":
            guard let id = message["sessionId"] as? String else { return ["error": "no session"] }
            return encoded(await detail(sessionId: id), as: "detail")

        case "decide":
            guard let client = app.client else { return ["error": Self.notConnected] }
            guard let id = message["sessionId"] as? String,
                  let requestId = message["requestId"] as? String else { return ["error": "bad request"] }
            let optionId = message["optionId"] as? String
            let reason = (message["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try await client.resolvePermission(sessionId: id, requestId: requestId,
                                                   optionId: optionId, always: false,
                                                   reason: (reason?.isEmpty == false) ? reason : nil)
            } catch BridgeError.badStatus(let code) where code == 409 {
                // Answered elsewhere already. The list that offered it is stale, so
                // replace it, or the wrist keeps offering buttons that can only fail.
                await app.reloadSessions(quiet: true)
                publish(Self.snapshot(from: app))
                return ["error": String(loc: "That approval was no longer pending. Grok isn't waiting on it.")]
            } catch {
                return ["error": Self.readable(error)]
            }
            await app.reloadSessions(quiet: true)
            publish(Self.snapshot(from: app))
            return ["ok": true]

        case "plan":
            guard let client = app.client else { return ["error": Self.notConnected] }
            guard let id = message["sessionId"] as? String,
                  let requestId = message["requestId"] as? String,
                  let approved = message["approved"] as? Bool else { return ["error": "bad request"] }
            do {
                try await client.resolvePlan(sessionId: id, requestId: requestId, approved: approved)
            } catch BridgeError.badStatus(let code) where code == 409 {
                await app.reloadSessions(quiet: true)
                publish(Self.snapshot(from: app))
                return ["error": String(loc: "That plan review was no longer pending.")]
            } catch {
                return ["error": Self.readable(error)]
            }
            // A reason rides along as the next message, as it does for a refused
            // permission: rejecting a plan with no word on why gets the same plan back.
            // The answer itself has already landed, so a failure here is not reported
            // as the answer failing.
            let reason = (message["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !approved, !reason.isEmpty {
                _ = try? await client.enqueue(sessionId: id, text: reason, source: "reason")
            }
            await app.reloadSessions(quiet: true)
            publish(Self.snapshot(from: app))
            return ["ok": true]

        case "reply":
            guard let client = app.client else { return ["error": Self.notConnected] }
            guard let id = message["sessionId"] as? String,
                  let text = message["text"] as? String, !text.isEmpty else { return ["error": "bad request"] }
            do {
                _ = try await client.enqueue(sessionId: id, text: text)
                return ["ok": true]
            } catch {
                return ["error": Self.readable(error)]
            }

        case "stop":
            guard let client = app.client else { return ["error": Self.notConnected] }
            guard let id = message["sessionId"] as? String else { return ["error": "bad request"] }
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

    /// Fold the bridge's event tail into what a watch screen shows: the request it
    /// is blocked on, Grok's last prose, the message that started the turn, and a
    /// handful of short lines for watches that still list them.
    private func detail(sessionId: String) async -> WatchDetail {
        var detail = WatchDetail(sessionId: sessionId)
        let app = AppState.shared
        guard let client = app.client else {
            detail.error = Self.notConnected
            return detail
        }
        let listed = app.sessions.first(where: { $0.id == sessionId })
        detail.name = Self.clip(listed?.displayName ?? "", Budget.text)
        detail.fetchedAt = Date()
        do {
            // Streamed prose arrives a few characters per event, so a long reply is
            // hundreds of records. 600 asks for as much as the bridge will give.
            let tail = try await client.tail(sessionId: sessionId, count: 600)
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
                    // The same test the bridge uses to pick the ids it publishes in
                    // `waiting`, so the two copies of a request always agree.
                    let options = (event["options"] as? [[String: Any]]) ?? []
                    func isAllow(_ option: [String: Any]) -> Bool {
                        let kind = (option["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        return (kind ?? option["optionId"] as? String ?? "").lowercased().contains("allow")
                    }
                    pending = Self.permission(
                        requestId: requestId, command: command,
                        allow: options.first(where: isAllow)?["optionId"] as? String,
                        deny: options.first(where: { !isAllow($0) })?["optionId"] as? String)
                case "plan_review":
                    guard let requestId = event["requestId"] as? String else { break }
                    let plan = (event["planContent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    pending = WatchApproval(requestId: requestId,
                                            command: Self.clip(plan, bytes: Budget.commandBytes),
                                            kind: "plan")
                case "permission_resolved", "plan_resolved":
                    if let requestId = event["requestId"] as? String { resolved.insert(requestId) }
                default:
                    break
                }
            }

            // Only a running turn can be blocked. A request left unresolved in the
            // record by a process that died is not something anyone can still answer.
            if let found = pending {
                if !resolved.contains(found.requestId), detail.busy { detail.approval = found }
            } else if detail.busy, let fallback = listed.flatMap(Self.approval(for:)),
                      !resolved.contains(fallback.requestId) {
                // Only when the tail holds no request at all (it begins after it). The
                // listed copy can be minutes old on a phone in a pocket, and falling
                // back to it whenever the tail's request was answered brought that
                // answered request back to the wrist, with buttons that could only fail.
                detail.approval = fallback
            }

            let lastUser = lines.lastIndex { $0.kind == "user" }
            let lastGrok = lines.lastIndex { $0.kind == "grok" }
            if let lastUser {
                detail.lastUser = Self.clip(lines[lastUser].text.trimmingCharacters(in: .whitespacesAndNewlines), Budget.line)
            }
            if let lastGrok, lastGrok > (lastUser ?? -1) {
                let reply = lines[lastGrok].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty { detail.lastReply = Self.clipProse(reply, Budget.reply) }
            }
            detail.lines = lines.suffix(12).map { line in
                var line = line
                line.text = Self.clip(line.text.trimmingCharacters(in: .whitespacesAndNewlines), Budget.line)
                return line
            }
        } catch {
            detail.error = Self.clip(Self.readable(error), Budget.text)
        }
        return detail
    }

    /// Append a line, merging into the previous one when it is the same kind and the
    /// text is a continuation (streamed prose).
    private func append(_ lines: inout [WatchLine], kind: String, text: String, merge: Bool = false) {
        if merge, let last = lines.last, last.kind == kind {
            lines[lines.count - 1].text += text
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || merge else { return }
        lines.append(WatchLine(kind: kind, text: text, id: lines.count))
    }

    private func encoded<T: Encodable>(_ value: T, as key: String) -> [String: Any] {
        guard let data = try? JSONEncoder.watch.encode(value) else { return ["error": "could not encode"] }
        return [key: data]
    }

    /// Hold a background assertion while the bridge call runs. A watch message can
    /// launch this app in the background, and iOS suspends it soon after: the
    /// approval would be left half-sent and the watch waiting on a reply.
    private static func keepingAlive<T>(_ work: () async -> T) async -> T {
        let app = UIApplication.shared
        var id = UIBackgroundTaskIdentifier.invalid
        id = app.beginBackgroundTask(withName: "tethrx.watch-request") {
            if id != .invalid { app.endBackgroundTask(id); id = .invalid }
        }
        let result = await work()
        if id != .invalid { app.endBackgroundTask(id); id = .invalid }
        return result
    }

    private static func readable(_ error: Error) -> String {
        (error as? BridgeError)?.errorDescription ?? error.localizedDescription
    }

    /// The watch paints whatever comes back in "error" verbatim, so anything a
    /// person can actually hit has to be translated here, on the phone. This one
    /// fires whenever the phone is open with no computer paired, which is exactly
    /// when someone taps Approve on their wrist.
    private static var notConnected: String { String(loc: "Not connected to a computer.") }

    // MARK: Trimming

    /// At most `limit` characters, with an ellipsis when anything was cut.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))) + "…"
    }

    /// At most `limit` bytes of UTF-8, never splitting a character.
    static func clip(_ text: String, bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let ellipsis = "…"
        var used = ellipsis.utf8.count
        var end = text.startIndex
        for index in text.indices {
            let size = text[index].utf8.count
            if used + size > limit { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[..<end]) + ellipsis
    }

    /// Prose shortened at a word boundary where one is near, so the excerpt does not
    /// end halfway through a word.
    static func clipProse(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        var cut = String(text.prefix(limit - 1))
        if let space = cut.lastIndex(where: \.isWhitespace),
           cut.distance(from: space, to: cut.endIndex) < 40 {
            cut = String(cut[..<space])
        }
        while let last = cut.last, last.isWhitespace || last.isPunctuation && last != ")" { cut.removeLast() }
        return cut + "…"
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
