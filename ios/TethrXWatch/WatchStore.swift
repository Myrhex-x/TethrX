import Foundation
import WatchConnectivity
import WatchKit
import WidgetKit

/// Everything the watch knows, and the one way it asks for more.
///
/// There is no bridge client here on purpose. The watch sends a request to the
/// phone, which holds the pairing token and the pinned certificate and knows which
/// computer is selected, and the phone answers.
///
/// Two paths, because a wrist is often out of range of a pocket:
///   - the list, and the approval each session is blocked on, arrive as application
///     context, which the system delivers whenever it next can. Nothing here has to
///     be live for the watch to show what Grok is asking;
///   - an answer goes out as a live message when the phone is reachable, and is
///     handed to `transferUserInfo` when it is not. That queue is durable and is
///     delivered in the background, so a tap is never simply lost.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    @Published var snapshot = WatchSnapshot()
    /// Request ids answered from here that the phone has not confirmed yet, so the
    /// card can say so instead of looking like the tap did nothing.
    @Published var queuedAnswers: Set<String> = []
    /// True while a request is in flight, so a row can show it is working rather
    /// than looking inert.
    @Published var loading = false
    /// A genuine failure, in words. Cleared by the next success.
    @Published var errorText: String?
    /// Something worth saying that is not a failure, like an answer having been
    /// queued. Kept apart from `errorText` so good news is never painted red.
    @Published var notice: String?
    /// Set when the phone cannot be reached at all.
    @Published var phoneUnreachable = false

    private var session: WCSession { WCSession.default }

    func start() {
        #if DEBUG
        // `-fixture` fills the watch with canned state so its screens can be driven
        // and captured without a phone, a bridge or a grok. Never compiled into a
        // release build.
        if ProcessInfo.processInfo.arguments.contains("-fixture") {
            adopt(Self.fixture)   // through adopt, so the complication is filled too
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    #if DEBUG
    static let fixture = WatchSnapshot(
        computer: "demo-mac",
        connected: true,
        sessions: [
            WatchSession(id: "fixture-1", name: "Hunt the flaky auth test", folder: "Acme app",
                         status: "running",
                         waitingKind: "permission", waitingLabel: "rm -rf .build",
                         since: Date().addingTimeInterval(-74), turns: 3,
                         approval: WatchApproval(requestId: "req-1", command: "rm -rf .build",
                                                 risk: "Deletes a directory tree recursively, with no prompt.",
                                                 riskLevel: "destructive",
                                                 allowOptionId: "allow", denyOptionId: "reject")),
            WatchSession(id: "fixture-2", name: "Dark mode for settings", folder: "Acme app",
                         status: "running", since: Date().addingTimeInterval(-212), turns: 6),
            WatchSession(id: "fixture-3", name: "Landing page hero", turns: 1),
        ]
    )
    #endif

    // MARK: Requests

    /// Ask the phone for a fresh list. Safe to call on every appearance.
    func refresh() async {
        guard let reply = await send(["cmd": "snapshot"]) else { return }
        if let data = reply["snapshot"] as? Data,
           let fresh = try? JSONDecoder.watch.decode(WatchSnapshot.self, from: data) {
            adopt(fresh)
        }
    }

    func detail(for sessionId: String) async -> WatchDetail? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fixture") {
            let session = snapshot.sessions.first { $0.id == sessionId }
            return WatchDetail(
                sessionId: sessionId, name: session?.name ?? "", busy: session?.isRunning ?? false,
                lines: [
                    WatchLine(kind: "user", text: "The auth test fails once every ~20 CI runs.", id: 0),
                    WatchLine(kind: "tool", text: "swift test --filter AuthTests", id: 1),
                    WatchLine(kind: "grok", text: "Passes in isolation, so another test leaves state behind.", id: 2),
                ],
                approval: session?.approval)
        }
        #endif
        guard let reply = await send(["cmd": "detail", "sessionId": sessionId]) else { return nil }
        guard let data = reply["detail"] as? Data,
              let detail = try? JSONDecoder.watch.decode(WatchDetail.self, from: data) else { return nil }
        return detail
    }

    /// Answer an approval. `optionId` nil cancels the request outright.
    ///
    /// Returns true when the phone confirmed it. When the phone is out of reach the
    /// answer is queued instead and this returns false with `queuedAnswers` marked,
    /// which the card shows as "sent" rather than as a failure: the queue is durable.
    func decide(sessionId: String, requestId: String, optionId: String?, reason: String? = nil) async -> Bool {
        var message: [String: Any] = ["cmd": "decide", "sessionId": sessionId, "requestId": requestId]
        if let optionId { message["optionId"] = optionId }
        // Refusing on its own tells Grok "no" and nothing else, so it tries a
        // near-identical thing next. The reason is queued as the next message.
        if let reason, !reason.isEmpty { message["reason"] = reason }
        let reply = await send(message, queueIfUnreachable: true)
        let ok = reply?["ok"] as? Bool == true
        if !ok, phoneUnreachable { queuedAnswers.insert(requestId) }
        WKInterfaceDevice.current().play(ok ? .success : (phoneUnreachable ? .click : .failure))
        return ok
    }

    /// Queue a follow-up on the computer. It runs when the current turn ends, so
    /// this works whether or not grok is busy.
    func reply(sessionId: String, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let reply = await send(["cmd": "reply", "sessionId": sessionId, "text": trimmed],
                               queueIfUnreachable: true)
        let ok = reply?["ok"] as? Bool == true
        WKInterfaceDevice.current().play(ok ? .success : (phoneUnreachable ? .click : .failure))
        return ok
    }

    func stop(sessionId: String) async -> Bool {
        let reply = await send(["cmd": "stop", "sessionId": sessionId])
        let ok = reply?["ok"] as? Bool == true
        WKInterfaceDevice.current().play(ok ? .success : .failure)
        return ok
    }

    // MARK: Plumbing

    /// One round trip, with every failure turned into a message a person can act on.
    /// `queueIfUnreachable` hands anything that CHANGES something to the durable
    /// background queue rather than dropping it.
    private func send(_ message: [String: Any], queueIfUnreachable: Bool = false) async -> [String: Any]? {
        guard WCSession.isSupported(), session.activationState == .activated else {
            phoneUnreachable = true
            return nil
        }
        loading = true
        defer { loading = false }
        let reply: [String: Any]? = await withCheckedContinuation { continuation in
            var resumed = false
            // WatchConnectivity calls exactly one of these, but a continuation resumed
            // twice traps the process, and this is the one place both handlers meet.
            session.sendMessage(message) { response in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: response)
            } errorHandler: { _ in
                // The overwhelmingly common failure is WCErrorCodeNotReachable: the
                // phone app is not running in the foreground, or the two are simply
                // not connected. Nothing here can fix that, so it is reported in
                // words and, for anything that changes state, queued instead.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
        guard let reply else {
            // Not reachable is the NORMAL state of a wrist: the phone app is usually
            // not in the foreground. The list and the pending approval arrived as
            // application context and are still perfectly good, so this is not an
            // error and must not be painted like one — the views show a quiet "not
            // live" line instead, and only when there is nothing better to say.
            phoneUnreachable = true
            if queueIfUnreachable {
                // Delivered whenever the phone is next available, including a launch
                // in the background. Losing an approval because a wrist walked out of
                // range would be the worst possible failure here.
                session.transferUserInfo(message)
                notice = String(localized: "Sent. Your iPhone will pass it on when it's back in range.")
            }
            return nil
        }
        phoneUnreachable = false
        if let message = reply["error"] as? String {
            errorText = message
            return nil
        }
        errorText = nil
        notice = nil
        return reply
    }

    private func adopt(_ fresh: WatchSnapshot) {
        // A new approval that arrives while you are looking at the list deserves a tap
        // on the wrist; a routine refresh does not.
        if fresh.waitingCount > snapshot.waitingCount {
            WKInterfaceDevice.current().play(.notification)
        }
        // Anything the phone no longer reports as waiting has been answered, however
        // that answer got there.
        let stillWaiting = Set(fresh.sessions.compactMap { $0.approval?.requestId })
        queuedAnswers.formIntersection(stillWaiting)
        snapshot = fresh
        errorText = nil
        // A snapshot only arrives from a phone that is in touch, so "will pass it on
        // when it's back in range" has already happened. Left standing it displaces
        // the footer for the rest of the session.
        notice = nil
        phoneUnreachable = false
        publishComplication(fresh)
    }

    /// Hand the face complication what it needs. It reads this and nothing else, so
    /// it works with the app closed and with no phone in range.
    private func publishComplication(_ snapshot: WatchSnapshot) {
        let waiting = snapshot.sessions.first(where: \.isWaitingOnYou)
        let state = ComplicationState(
            waitingCount: snapshot.waitingCount,
            runningCount: snapshot.runningCount,
            sessionCount: snapshot.sessions.count,
            waitingName: waiting?.name ?? "",
            waitingSessionId: waiting?.id ?? "",
            updatedAt: Date()
        )
        guard let defaults = UserDefaults(suiteName: ComplicationState.suiteName),
              let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: ComplicationState.key)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            guard state == .activated else { return }
            // The phone pushes application context whenever its list changes; adopt
            // whatever arrived while this app was not running.
            self.applyContext(session.receivedApplicationContext)
            await self.refresh()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in self.applyContext(context) }
    }

    /// The phone confirming a queued answer landed.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            if let requestId = userInfo["answered"] as? String {
                self.queuedAnswers.remove(requestId)
                self.notice = nil
            }
        }
    }

    @MainActor
    private func applyContext(_ context: [String: Any]) {
        guard let data = context["snapshot"] as? Data,
              let fresh = try? JSONDecoder.watch.decode(WatchSnapshot.self, from: data) else { return }
        adopt(fresh)
    }
}
