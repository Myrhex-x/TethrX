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
    @Published var mode: String?          // "plan" while Grok is planning
    @Published var errorMessage: String?
    @Published var usage: SessionUsage?   // live token/context/cost meter
    @Published var commands: [SlashCommand] = []   // grok's slash commands (/compact, skills…)
    @Published var queued: [String] = []           // follow-ups to send when the turn ends

    // Live per-session settings (mirror the bridge; changed from the chat controls).
    @Published var planMode: Bool
    @Published var effort: String         // "", "high", "medium", "low"
    @Published var autoApprove: Bool

    let client: BridgeClient
    let session: SessionInfo
    /// Demo mode: canned transcript, scripted replies, zero networking.
    let isDemo: Bool

    private let liveActivity = LiveActivityManager()
    var sessionName: String { session.displayName }

    private var streamTask: Task<Void, Never>?
    /// Highest SSE event id folded in. Sent on reconnect so the bridge resumes from
    /// there instead of replaying the whole session and duplicating the transcript.
    private var lastEventId = 0
    private var assistantIndex: Int?   // current assistant bubble being appended to
    private var thoughtIndex: Int?     // current thought bubble being appended to
    /// Thumbnails of images just sent from THIS device; attached to the next
    /// turn_start's user bubble (history replay only knows the count).
    private var pendingEcho: [UIImage] = []

    init(client: BridgeClient, session: SessionInfo) {
        self.client = client
        self.session = session
        self.isDemo = false
        self.planMode = session.planMode ?? false
        self.effort = session.effort ?? ""
        self.autoApprove = session.autoApprove ?? false
        self.usage = session.usage
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
        self.planMode = demoSession.planMode ?? false
        self.effort = demoSession.effort ?? ""
        self.autoApprove = demoSession.autoApprove ?? false
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
            self.autoApprove = updated.autoApprove ?? self.autoApprove
        } catch {
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Open (and auto-reconnect) the event stream for this session.
    func start() {
        if isDemo {
            if items.isEmpty, session.id == "demo-settings-dark" { items = DemoData.transcript }
            live = true
            return
        }
        guard streamTask == nil else { return }
        streamTask = Task { @MainActor in
            while !Task.isCancelled {
                live = true
                do {
                    for try await event in client.events(sessionId: session.id, lastEventId: lastEventId) {
                        if let id = event["_eventId"] as? Int { lastEventId = max(lastEventId, id) }
                        apply(event)
                    }
                } catch {
                    // transient — fall through to reconnect
                }
                live = false
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func send(_ text: String, images: [Data] = [], thumbnails: [UIImage] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }
        if isDemo {
            var user = ChatItem(role: .user, text: trimmed)
            user.images = thumbnails
            user.imageCount = thumbnails.count
            items.append(user)
            busy = true
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            items.append(ChatItem(role: .assistant, text: DemoData.cannedReply))
            busy = false
            return
        }
        busy = true
        errorMessage = nil
        if !thumbnails.isEmpty { pendingEcho = thumbnails }
        do {
            try await client.send(sessionId: session.id, text: trimmed, images: images)
        } catch {
            busy = false
            pendingEcho = []
            errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancel() async {
        queued.removeAll()                       // stopping drops any queued follow-ups
        if isDemo { busy = false; return }
        await client.cancel(sessionId: session.id)
    }

    /// Queue a follow-up to send automatically once the current turn finishes.
    func enqueue(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queued.append(t)
    }

    /// Send the next queued follow-up (after a beat, so the bridge is idle again).
    /// The message stays in the queue until the bridge has actually accepted it —
    /// popping first meant a failed send silently destroyed what the user typed.
    private func drainQueue() {
        guard let next = queued.first else { return }
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard queued.first == next else { return }   // something else already handled it
            do {
                try await client.send(sessionId: session.id, text: next)
                if queued.first == next { queued.removeFirst() }
            } catch {
                // 409 just means a turn is still running — e.g. the bridge auto-continuing
                // after an approved plan. Leave it queued; the next turn_complete retries.
                if !Self.isConflict(error) {
                    errorMessage = (error as? BridgeError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private static func isConflict(_ error: Error) -> Bool {
        if case .badStatus(409) = (error as? BridgeError) ?? .badURL { return true }
        return false
    }

    /// Answer a permission request (Approve/Reject). optionId nil cancels the turn.
    func decide(_ item: ChatItem, optionId: String?, always: Bool = false) async {
        guard let requestId = item.requestId else { return }
        let idx = items.firstIndex(where: { $0.id == item.id })
        if let idx { items[idx].decided = optionId ?? "cancelled" }   // optimistic — hide the buttons
        do {
            try await client.resolvePermission(sessionId: session.id, requestId: requestId, optionId: optionId, always: always)
            if always { autoApprove = true }
        } catch {
            if Self.isConflict(error) {
                // 409: nothing is waiting on this anymore (answered elsewhere, or the
                // session restarted). Re-showing the buttons would just fail again.
                if let idx, items.indices.contains(idx) { items[idx].decided = "cancelled" }
                errorMessage = String(localized: "That approval was no longer pending — grok isn't waiting on it.")
            } else {
                // The bridge never heard the decision, so Grok is still blocked. Put the
                // buttons back rather than leaving a card that claims it was answered.
                if let idx, items.indices.contains(idx) { items[idx].decided = nil }
                errorMessage = String(localized: "Couldn't send that decision. Check the connection and try again.")
            }
        }
    }

    /// Approve or revise a plan (plan mode). Approving proceeds to execution.
    func decidePlan(_ item: ChatItem, approved: Bool) async {
        guard let requestId = item.requestId else { return }
        let idx = items.firstIndex(where: { $0.id == item.id })
        if let idx { items[idx].decided = approved ? "approved" : "rejected" }
        do {
            try await client.resolvePlan(sessionId: session.id, requestId: requestId, approved: approved)
        } catch {
            if Self.isConflict(error) {
                if let idx, items.indices.contains(idx) { items[idx].decided = "rejected" }
                errorMessage = String(localized: "That plan review was no longer pending.")
            } else {
                if let idx, items.indices.contains(idx) { items[idx].decided = nil }
                errorMessage = String(localized: "Couldn't send that decision. Check the connection and try again.")
            }
        }
    }

    // MARK: Event folding

    private func apply(_ event: [String: Any]) {
        live = true
        switch event["kind"] as? String {
        case "turn_start":
            assistantIndex = nil
            thoughtIndex = nil
            busy = true
            liveActivity.start(sessionName: sessionName, sessionId: session.id,
                               phase: "working", detail: "Grok is working…")
            var item = ChatItem(role: .user, text: event["text"] as? String ?? "")
            item.imageCount = event["imageCount"] as? Int ?? 0
            if item.imageCount > 0, !pendingEcho.isEmpty {
                item.images = pendingEcho
                pendingEcho = []
            }
            items.append(item)

        case "text":
            let t = event["text"] as? String ?? ""
            if let i = assistantIndex, items.indices.contains(i) {
                items[i].text += t
            } else {
                append(.assistant, t)
                assistantIndex = items.count - 1
            }

        case "thought":
            let t = event["text"] as? String ?? ""
            if let i = thoughtIndex, items.indices.contains(i) {
                items[i].text += t
            } else {
                append(.thought, t)
                thoughtIndex = items.count - 1
            }

        case "tool_call":
            assistantIndex = nil
            thoughtIndex = nil
            let tool = event["tool"] as? String ?? "tool"
            liveActivity.update(phase: "working", detail: tool)
            let label = (event["command"] as? String) ?? (event["title"] as? String) ?? tool
            var item = ChatItem(role: .tool, text: label)
            item.toolCallId = event["id"] as? String
            item.toolStatus = "running"
            items.append(item)

        case "tool_update":
            if let id = event["id"] as? String,
               let idx = items.lastIndex(where: { $0.toolCallId == id }) {
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
            let entries = event["entries"] as? [[String: Any]] ?? []
            let lines = entries.compactMap { $0["content"] as? String }
            if !lines.isEmpty { append(.tool, "plan\n" + lines.map { "• \($0)" }.joined(separator: "\n")) }

        case "permission_request":
            assistantIndex = nil
            thoughtIndex = nil
            liveActivity.update(phase: "waiting", detail: "Waiting for your approval")
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

        case "end":
            let reason = event["stopReason"] as? String ?? "done"
            append(.status, "· \(reason) ·")
            assistantIndex = nil
            thoughtIndex = nil

        case "permission_resolved":
            if let rid = event["requestId"] as? String,
               let idx = items.firstIndex(where: { $0.role == .permission && $0.requestId == rid && $0.decided == nil }) {
                items[idx].decided = (event["optionId"] as? String) ?? "cancelled"
            }

        case "plan_review":
            assistantIndex = nil
            thoughtIndex = nil
            liveActivity.update(phase: "waiting", detail: "Plan ready to review")
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

        case "turn_complete":
            busy = false
            assistantIndex = nil
            thoughtIndex = nil
            liveActivity.end(phase: "done", detail: "Finished")
            drainQueue()

        case "error":
            busy = false
            liveActivity.end(phase: "error", detail: "Something went wrong")
            append(.error, event["message"] as? String ?? "Something went wrong.")

        default:
            break   // "log", "raw", heartbeats — ignored in the UI
        }
    }

    private func append(_ role: ChatRole, _ text: String) {
        items.append(ChatItem(role: role, text: text))
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
