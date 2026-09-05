import Foundation
import SwiftUI
import UIKit

/// Drives a single session: keeps a live SSE connection, folds streaming events
/// into `items`, and sends / cancels turns.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var busy = false
    @Published var live = false
    /// Grok is blocked on an approval or a plan review, rather than working.
    @Published var waitingOnYou = false
    @Published var mode: String?          // "plan" while Grok is planning
    @Published var errorMessage: String?
    @Published var usage: SessionUsage?   // live token/context/cost meter
    @Published var commands: [SlashCommand] = []   // grok's slash commands (/compact, skills…)
    /// Follow-ups the BRIDGE is holding. Mirrored from it (not owned here), so they
    /// survive the app closing and stay in step across devices.
    @Published var queued: [QueuedMessage] = []
    /// Grok's checklist for the turn in flight, so the header can show its position
    /// without scrolling back to the card.
    @Published var plan: [PlanEntry] = []
    /// When the running turn began, for the stopwatch under the title. Nil when idle.
    @Published var turnStartedAt: Date?

    // Live per-session settings (mirror the bridge; changed from the chat controls).
    @Published var planMode: Bool
    @Published var effort: String         // "", "high", "medium", "low"
    /// "ask" | "reads" | "all".
    @Published var approvalPolicy: String
    /// Legacy view, still used by the older call sites and by setConfig's wire format.
    var autoApprove: Bool {
        get { approvalPolicy == "all" }
        set { approvalPolicy = newValue ? "all" : "ask" }
    }

    let client: BridgeClient
    let session: SessionInfo
    /// Demo mode: canned transcript, scripted replies, zero networking.
    let isDemo: Bool

    private let liveActivity = LiveActivityManager()
    var sessionName: String { session.displayName }

    private var streamTask: Task<Void, Never>?
    /// Set by stop(), so a watchdog that was already sleeping cannot revive the stream.
    private var stopped = false
    private var watchdog: Task<Void, Never>?
    /// Streamed prose waiting to be folded in, in arrival order, with consecutive
    /// same-kind chunks already merged.
    private var pendingChunks: [(thought: Bool, text: String)] = []
    private var flushTask: Task<Void, Never>?
    /// When the turn already in flight began, per the bridge. Replay ends on that
    /// turn's `turn_start` with no `turn_complete`, so this is what the stopwatch reads.
    private let runningSince: Date?
    /// Highest SSE event id folded in. Sent on reconnect so the bridge resumes from
    /// there instead of replaying the whole session and duplicating the transcript.
    private var lastEventId = 0
    /// Events at or below this id are HISTORY replay. The transcript folds them
    /// normally, but side effects must not re-fire — opening an old session used to
    /// flash one lock-screen Live Activity per past turn.
    private let replayWatermark: Int
    private var assistantIndex: Int?   // current assistant bubble being appended to
    private var thoughtIndex: Int?     // current thought bubble being appended to
    /// The turn's plan card, revised in place as grok re-sends the whole checklist.
    private var planIndex: Int?
    /// Thumbnails of images just sent from THIS device; attached to the next
    /// turn_start's user bubble (history replay only knows the count).
    private var pendingEcho: [UIImage] = []

    init(client: BridgeClient, session: SessionInfo) {
        self.client = client
        self.session = session
        self.isDemo = false
        self.replayWatermark = session.lastEventId ?? 0
        self.runningSince = Fmt.date(fromISO: session.runningSince)
        self.planMode = session.planMode ?? false
        self.effort = session.effort ?? ""
        self.approvalPolicy = session.effectiveApprovalPolicy
        self.usage = session.usage
        self.queued = session.queue ?? []
        // Hand each activity's update token to the bridge, so the lock-screen
        // status keeps moving after the app is closed.
        liveActivity.onPushToken = { [client, session] token in
            Task { try? await client.registerLiveActivity(kind: "update-token", token: token, sessionId: session.id) }
        }
    }

    /// Demo sessions never touch the network; the client is an inert stub.
    init(demoSession: SessionInfo) {
        self.client = BridgeClient(config: .init(baseURL: URL(string: "http://127.0.0.1:9")!, token: "demo"))
        self.session = demoSession
        self.isDemo = true
        self.replayWatermark = 0
        self.runningSince = Fmt.date(fromISO: demoSession.runningSince)
        self.planMode = demoSession.planMode ?? false
        self.effort = demoSession.effort ?? ""
        self.approvalPolicy = demoSession.effectiveApprovalPolicy
        self.usage = demoSession.usage
    }

    /// Change plan mode / reasoning effort / auto-approve for this session, live.
    func setConfig(planMode: Bool? = nil, effort: String? = nil, autoApprove: Bool? = nil) async {
        if let planMode { self.planMode = planMode }
        if let effort { self.effort = effort }
        if let autoApprove { self.autoApprove = autoApprove }
        if isDemo { return }   // locals updated — that's the whole demo behavior
        do {
            let updated = try await client.setConfig(sessionId: session.id, planMode: planMode, effort: effort, autoApprove: autoApprove)
            self.planMode = updated.planMode ?? self.planMode
            self.effort = updated.effort ?? self.effort
            self.approvalPolicy = updated.effectiveApprovalPolicy
        } catch {
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Unstick a session whose turn is wedged. Cancel only asks politely, and a grok
    /// that has stopped reading never sees it, so every later message 409s forever.
    func restart() async {
        if isDemo { return }
        do {
            try await client.restartSession(session.id)
            busy = false
            waitingOnYou = false
            restartStream()
        } catch {
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Set how tool permissions are answered: "ask", "reads" or "all".
    func setApprovalPolicy(_ policy: String) async {
        let previous = approvalPolicy
        approvalPolicy = policy
        if isDemo { return }
        do {
            let updated = try await client.setConfig(sessionId: session.id, approvalPolicy: policy)
            approvalPolicy = updated.effectiveApprovalPolicy
        } catch {
            // An older bridge does not know approvalPolicy at all. "reads" has no
            // equivalent there, so do not silently promote it to "all".
            approvalPolicy = previous
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Open (and auto-reconnect) the event stream for this session.
    func start() {
        if isDemo {
            if items.isEmpty, let canned = DemoData.transcript(for: session.id) { items = canned }
            // The list says this one is running — the transcript should agree, down to
            // the stopwatch and the checklist's position.
            busy = session.isRunning
            turnStartedAt = busy ? runningSince : nil
            plan = items.last(where: { $0.role == .tasks })?.planEntries ?? []
            live = true
            return
        }
        guard streamTask == nil else { return }
        // Seed the "/" palette from the bridge's stored snapshot so it works the
        // moment the composer opens — the live list (an SSE "commands" event once
        // grok's process is up) replaces it.
        Task { @MainActor in
            if commands.isEmpty, let seed = try? await client.commands(sessionId: session.id), !seed.isEmpty {
                if commands.isEmpty { commands = seed }
            }
        }
        stopped = false
        streamTask = Task { @MainActor in
            var attempt = 0
            while !Task.isCancelled {
                // `live` turns on when the stream actually delivers (the synthetic
                // "_open" marker counts) — setting it before dialing showed a green
                // "Connected" dot against a bridge that wasn't answering.
                do {
                    for try await event in client.events(sessionId: session.id, lastEventId: lastEventId) {
                        if let id = event["_eventId"] as? Int { lastEventId = max(lastEventId, id) }
                        apply(event)
                    }
                    attempt = 0                     // a stream that delivered then ended is transient
                } catch {
                    // Not everything is transient. A deleted session (404) or a rotated
                    // token (401) will never recover, and retrying a fatal failure at a
                    // flat 2s meant a full handshake thirty times a minute, for as long
                    // as the view stayed open, with only a grey dot to show for it.
                    if case BridgeError.badStatus(let code) = error, code == 401 || code == 404 {
                        live = false
                        flushStream()
                        errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
                        break
                    }
                    attempt += 1
                }
                live = false
                if Task.isCancelled { break }
                // 2s, 4s, 8s, capped at 30s.
                let backoff = min(30.0, 2.0 * pow(2.0, Double(max(0, attempt - 1))))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    func stop() {
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        streamTask?.cancel()
        streamTask = nil
        flushStream()
        // A turn still running keeps its card: the bridge drives it from here via the
        // activity's push token. With nothing running there is nothing to report, and
        // leaving it meant the lock screen said WORKING for hours after a swipe back.
        if busy { liveActivity.detach() } else { liveActivity.end(phase: "done", detail: "Finished") }
    }

    /// The demo's canned-reply task, so Stop can actually stop it.
    private var demoReply: Task<Void, Never>?
    /// Set when the last turn_start folded in — the send watchdog keys off it.
    private var lastTurnStartAt = Date.distantPast

    func send(_ text: String, images: [Data] = [], thumbnails: [UIImage] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        if isDemo {
            var user = ChatItem(role: .user, text: trimmed)
            user.images = thumbnails
            user.imageCount = thumbnails.count
            items.append(user)
            busy = true
            demoReply = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                guard !Task.isCancelled else { return }
                items.append(ChatItem(role: .assistant, text: DemoData.cannedReply))
                busy = false
            }
            return
        }
        busy = true
        errorMessage = nil
        watchdog?.cancel()
        if !thumbnails.isEmpty { pendingEcho = thumbnails }
        let sentAt = Date()
        do {
            AppState.shared.markSessionUsed(session.id)
            try await client.send(sessionId: session.id, text: trimmed, images: images)
            watchdogAfterSend(sentAt)
        } catch {
            busy = false
            pendingEcho = []
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
            // The composer clears optimistically, and the user bubble only arrives with
            // the turn_start event, so a send that fails leaves nothing behind at all:
            // the typed message and up to three re-picked photos are simply gone.
            failedSend = FailedSend(text: trimmed, images: images, thumbnails: thumbnails)
        }
    }

    /// The last send that did not land, so the composer can put it back for one tap of retry.
    struct FailedSend { var text: String; var images: [Data]; var thumbnails: [UIImage] }
    @Published var failedSend: FailedSend?

    /// A Wi-Fi→cellular hop can leave the SSE stream half-dead: the POST lands (the
    /// turn runs on the computer) while the old stream never delivers another byte —
    /// no user bubble, typing dots forever. If the accepted send's turn_start hasn't
    /// folded in shortly, force a fresh stream; replay-from-lastEventId fills the gap.
    private func watchdogAfterSend(_ sentAt: Date) {
        watchdog?.cancel()
        // Held, and cancelled by stop()/send(). As a bare unstructured Task its own
        // `Task.isCancelled` was always false, so leaving the chat within five seconds
        // of a send still called restartStream() after stop(), spawning a stream that
        // captured self strongly and was never cancelled again.
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, !self.stopped else { return }
            if self.lastTurnStartAt < sentAt {
                self.restartStream()
            }
        }
    }

    private func restartStream() {
        streamTask?.cancel()
        streamTask = nil
        start()
    }

    /// True while the Stop request is in flight, so the button can show it.
    @Published var cancelling = false

    func cancel() async {
        if isDemo {
            demoReply?.cancel()
            demoReply = nil
            busy = false
            return
        }
        cancelling = true
        defer { cancelling = false }
        do {
            try await client.cancelOrThrow(sessionId: session.id)
            // Only clear follow-ups the bridge confirmed dropping — wiping them
            // locally on a failed call left them running while the UI said gone.
            if !queued.isEmpty {
                try await client.clearQueue(sessionId: session.id)
                queued.removeAll()
            }
        } catch {
            errorMessage = String(loc: "Couldn't reach the computer to stop the turn. It may still be running.")
        }
    }

    /// Queue a follow-up. The bridge runs it when the turn ends (or immediately, if
    /// nothing is running); it is held there, so closing the app doesn't lose it.
    func enqueue(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if isDemo {
            queued.append(QueuedMessage(id: UUID().uuidString, text: t, source: "phone", at: nil))
            return
        }
        // Optimistic, so the chip appears instantly; the bridge's reply (and the SSE
        // `queue` event) replaces this with the authoritative list.
        let pending = QueuedMessage(id: UUID().uuidString, text: t, source: "phone", at: nil)
        queued.append(pending)
        do {
            AppState.shared.markSessionUsed(session.id)
            let confirmed = try await client.enqueue(sessionId: session.id, text: t)
            queued = confirmed
        } catch {
            queued.removeAll { $0.id == pending.id }
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Drop one queued follow-up. Optimistic, but restored if the bridge didn't
    /// hear — a chip that vanishes while the follow-up still runs is a lie.
    func removeQueued(_ item: QueuedMessage) async {
        queued.removeAll { $0.id == item.id }
        if isDemo { return }
        do { try await client.dequeue(sessionId: session.id, itemId: item.id) }
        catch {
            if !queued.contains(where: { $0.id == item.id }) { queued.append(item) }
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case .badStatus(409) = (error as? BridgeError) ?? .badURL { return true }
        return false
    }

    /// Answer a permission request (Approve/Reject). optionId nil cancels the turn.
    /// A `reason` given while denying is queued as the next message, so "no, do it
    /// this way instead" is one action rather than deny-then-remember-to-explain.
    func decide(_ item: ChatItem, optionId: String?, always: Bool = false, reason: String? = nil) async {
        guard let requestId = item.requestId else { return }
        let idx = items.firstIndex(where: { $0.id == item.id })
        if let idx { items[idx].decided = optionId ?? "cancelled" }   // optimistic — hide the buttons
        if isDemo {
            if let reason, !reason.isEmpty { await enqueue(reason) }
            return
        }
        do {
            try await client.resolvePermission(sessionId: session.id, requestId: requestId,
                                               optionId: optionId, always: always, reason: reason)
            if always { autoApprove = true }
        } catch {
            if Self.isConflict(error) {
                // 409: nothing is waiting on this anymore (answered elsewhere, or the
                // session restarted). Re-showing the buttons would just fail again.
                if let idx, items.indices.contains(idx) { items[idx].decided = "cancelled" }
                errorMessage = String(loc: "That approval was no longer pending. Grok isn't waiting on it.")
            } else {
                // The bridge never heard the decision, so Grok is still blocked. Put the
                // buttons back rather than leaving a card that claims it was answered.
                if let idx, items.indices.contains(idx) { items[idx].decided = nil }
                errorMessage = String(loc: "Couldn't send that decision. Check the connection and try again.")
            }
        }
    }

    /// Approve or revise a plan (plan mode). Approving proceeds to execution.
    func decidePlan(_ item: ChatItem, approved: Bool) async {
        guard let requestId = item.requestId else { return }
        let idx = items.firstIndex(where: { $0.id == item.id })
        if let idx { items[idx].decided = approved ? "approved" : "rejected" }
        // The demo's plan card is decidable for show; nothing to send anywhere.
        if isDemo { return }
        do {
            try await client.resolvePlan(sessionId: session.id, requestId: requestId, approved: approved)
        } catch {
            if Self.isConflict(error) {
                if let idx, items.indices.contains(idx) { items[idx].decided = "rejected" }
                errorMessage = String(loc: "That plan review was no longer pending.")
            } else {
                if let idx, items.indices.contains(idx) { items[idx].decided = nil }
                errorMessage = String(loc: "Couldn't send that decision. Check the connection and try again.")
            }
        }
    }

    // MARK: Streamed-text buffering

    /// Merge into the tail run when it is the same kind, so a burst of chunks becomes
    /// one string append instead of hundreds.
    private func enqueueChunk(_ text: String, thought: Bool) {
        guard !text.isEmpty else { return }
        if let last = pendingChunks.last, last.thought == thought {
            pendingChunks[pendingChunks.count - 1].text += text
        } else {
            pendingChunks.append((thought, text))
        }
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushStream()
        }
    }

    /// Fold everything buffered into the transcript now. Safe to call at any time.
    func flushStream() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingChunks.isEmpty else { return }
        let runs = pendingChunks
        pendingChunks = []
        for run in runs {
            if run.thought {
                if let i = thoughtIndex, items.indices.contains(i) {
                    items[i].text += run.text
                } else {
                    append(.thought, run.text)
                    thoughtIndex = items.count - 1
                    items[items.count - 1].startedAt = Date()
                }
            } else {
                // Prose after reasoning ends the trace, which is what gives it a
                // duration and lets the card collapse.
                closeThought()
                if let i = assistantIndex, items.indices.contains(i) {
                    items[i].text += run.text
                } else {
                    append(.assistant, run.text)
                    assistantIndex = items.count - 1
                }
            }
        }
    }

    // MARK: Event folding

    private func apply(_ event: [String: Any]) {
        live = true
        // History replay folds into the transcript like anything else, but must not
        // re-fire side effects: without this, opening a finished 6-turn session
        // flashed six Live Activities across the lock screen.
        let isReplay = (event["_eventId"] as? Int ?? Int.max) <= replayWatermark
        let kind = event["kind"] as? String

        // Streamed prose is buffered and flushed on a short timer. grok streams about
        // 4.3 characters per event, so a 4000 character answer arrives as roughly 930
        // separate publishes, and each one re-ran the whole bubble's markdown parse and
        // code-fence split over the entire accumulated text. Anything that is NOT a
        // chunk has to flush first, or it would be folded in ahead of prose that was
        // streamed before it.
        if kind == "text" || kind == "thought" {
            enqueueChunk(event["text"] as? String ?? "", thought: kind == "thought")
            return
        }
        flushStream()

        switch kind {
        case "turn_start":
            assistantIndex = nil
            closeThought()
            thoughtIndex = nil
            // A new turn gets a new checklist; the previous one stays in the transcript
            // exactly as it ended.
            planIndex = nil
            plan = []
            busy = true
            // Replayed turns are history — except the last one, when the session is
            // still running: the bridge says when that began.
            turnStartedAt = isReplay ? runningSince : Date()
            if !isReplay {
                lastTurnStartAt = Date()
                liveActivity.start(sessionName: sessionName, sessionId: session.id,
                                   phase: "working", detail: "Grok is working…")
            }
            var item = ChatItem(role: .user, text: event["text"] as? String ?? "")
            item.imageCount = event["imageCount"] as? Int ?? 0
            if item.imageCount > 0, !pendingEcho.isEmpty {
                item.images = pendingEcho
                pendingEcho = []
            }
            items.append(item)

        case "tool_call":
            assistantIndex = nil
            closeThought()
            thoughtIndex = nil
            let tool = event["tool"] as? String ?? "tool"
            if !isReplay { liveActivity.update(phase: "working", detail: tool) }
            let label = (event["command"] as? String) ?? (event["title"] as? String) ?? tool
            var item = ChatItem(role: .tool, text: label)
            item.toolCallId = event["id"] as? String
            item.toolStatus = "running"
            items.append(item)

        case "tool_update":
            // Must match the TOOL row, not merely the last item carrying this id. The
            // permission card is appended after the tool row and copies the same
            // toolCallId, so `lastIndex` wrote status, exit code, output and diff onto a
            // card that renders none of them: the real tool row span forever, and the
            // auto-expand-on-failure could never fire.
            if let id = event["id"] as? String,
               let idx = items.lastIndex(where: { $0.role == .tool && $0.toolCallId == id }) {
                if let st = event["status"] as? String, !st.isEmpty { items[idx].toolStatus = st }
                if let code = event["exitCode"] as? Int, code != 0 { items[idx].toolStatus = "failed" }
                if let out = event["output"] as? String, !out.isEmpty { items[idx].toolOutput = out }
                if let d = event["diff"] as? [String: Any], let path = d["path"] as? String {
                    items[idx].diff = FileDiff(path: path,
                                               oldText: d["oldText"] as? String ?? "",
                                               newText: d["newText"] as? String ?? "")
                }
            }

        case "plan":
            assistantIndex = nil
            closeThought()
            thoughtIndex = nil   // else the next thought chunk appends ABOVE the plan card
            let entries = PlanEntry.decode(event["entries"] as? [[String: Any]] ?? [])
            guard !entries.isEmpty else { break }
            // ONE card per turn, revised in place. Grok re-sends the whole checklist
            // every time a step changes state, and appending each revision left a stack
            // of near-identical bullet dumps with no sign of which step was live — and
            // the status it sends with every entry was thrown away entirely.
            if let index = planIndex, items.indices.contains(index), items[index].role == .tasks {
                items[index].planEntries = entries
            } else {
                var item = ChatItem(role: .tasks, text: "")
                item.planEntries = entries
                items.append(item)
                planIndex = items.count - 1
            }
            plan = entries

        case "permission_request":
            assistantIndex = nil
            closeThought()
            thoughtIndex = nil
            if !isReplay {
                liveActivity.update(phase: "waiting", detail: "Waiting for your approval")
                // The screen may be in a pocket, or the card may be below the fold.
                Haptics.attention()
            }
            var item = ChatItem(role: .permission,
                                text: (event["command"] as? String) ?? (event["title"] as? String)
                                      ?? (event["tool"] as? String) ?? "Grok wants to run a tool")
            item.requestId = event["requestId"] as? String
            item.toolCallId = event["toolCallId"] as? String
            if let opts = event["options"] as? [[String: Any]] {
                item.options = opts.compactMap { o in
                    guard let oid = o["optionId"] as? String, let name = o["name"] as? String else { return nil }
                    return PermissionOption(optionId: oid, name: name, kind: o["kind"] as? String ?? "")
                }
            }
            items.append(item)

        case "permission_resolved":
            if let rid = event["requestId"] as? String,
               let idx = items.firstIndex(where: { $0.role == .permission && $0.requestId == rid && $0.decided == nil }) {
                items[idx].decided = (event["optionId"] as? String) ?? "cancelled"
            }

        case "plan_review":
            assistantIndex = nil
            closeThought()
            thoughtIndex = nil
            if !isReplay {
                liveActivity.update(phase: "waiting", detail: "Plan ready to review")
                Haptics.attention()
            }
            var item = ChatItem(role: .plan, text: event["planContent"] as? String ?? "Grok drafted a plan.")
            item.requestId = event["requestId"] as? String
            items.append(item)

        case "plan_resolved":
            if let rid = event["requestId"] as? String,
               let idx = items.firstIndex(where: { $0.role == .plan && $0.requestId == rid && $0.decided == nil }) {
                items[idx].decided = (event["approved"] as? Bool == true) ? "approved" : "rejected"
            }

        case "mode":
            mode = event["mode"] as? String

        case "usage":
            if let dict = event["usage"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: dict),
               let u = try? JSONDecoder().decode(SessionUsage.self, from: data) {
                usage = u
            }

        case "commands":
            if let arr = event["commands"] as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let cmds = try? JSONDecoder().decode([SlashCommand].self, from: data) {
                commands = cmds
            }

        case "queue":
            // The bridge owns the queue; this is it telling us what it now holds.
            if let arr = event["queue"] as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: arr),
               let items = try? JSONDecoder().decode([QueuedMessage].self, from: data) {
                queued = items
            }

        case "turn_complete":
            busy = false
            turnStartedAt = nil
            assistantIndex = nil
            closeThought()
            thoughtIndex = nil
            // The visible "turn ended" separator lives here — the bridge emits
            // turn_complete, not the "end" kind an older revision listened for.
            let reason = event["stopReason"] as? String ?? "done"
            append(.status, "· \(reason) ·")
            if !isReplay { liveActivity.end(phase: "done", detail: "Finished") }

        case "error":
            busy = false
            turnStartedAt = nil
            if !isReplay { liveActivity.end(phase: "error", detail: "Something went wrong") }
            append(.error, event["message"] as? String ?? "Something went wrong.")

        case "waiting":
            // Grok is blocked on you (or no longer is). The chip in the session list is
            // driven from the session metadata; here it only needs to stop the spinner
            // from implying work is happening.
            waitingOnYou = event["waiting"] != nil && !(event["waiting"] is NSNull)

        case "compacted":
            // grok compacted the conversation, either because you asked or because it
            // crossed its own threshold. Nothing else in the stream says the window
            // shrank, so without this the user waits for a reply that never comes.
            let before = event["tokensBefore"] as? Int
            let after = event["tokensAfter"] as? Int
            if let before, let after, after < before {
                append(.status, String(loc: "· compacted to \(Fmt.tokens(after)) tokens ·"))
            } else {
                append(.status, String(loc: "· compacted ·"))
            }

        case "_open":
            break   // synthetic stream-connected marker; `live` was set above

        default:
            break   // "log", "raw", heartbeats — ignored in the UI
        }
    }

    private func append(_ role: ChatRole, _ text: String) {
        items.append(ChatItem(role: role, text: text))
    }

    /// Stamp the open reasoning block as finished. Idempotent: anything that follows
    /// thinking calls it, and only the first call sets the time.
    private func closeThought() {
        guard let i = thoughtIndex, items.indices.contains(i), items[i].endedAt == nil else { return }
        items[i].endedAt = Date()
    }

    /// Compact JSON preview of a tool's arguments for display.
    private static func compact(_ any: Any?) -> String {
        guard let any,
              JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any),
              let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s.count > 140 ? String(s.prefix(140)) + "…" : s
    }
}
