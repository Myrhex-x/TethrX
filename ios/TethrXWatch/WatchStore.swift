import Foundation
import WatchConnectivity
import WatchKit

/// Everything the watch knows, and the one way it asks for more.
///
/// There is no bridge client here on purpose. The watch sends a request to the
/// phone, which holds the pairing token and the pinned certificate and knows which
/// computer is selected, and the phone answers.
///
/// Two paths, because a wrist is often out of range of a pocket:
///   - the list, and the request each session is blocked on, arrive as application
///     context, which the system delivers whenever it next can. Nothing here has to
///     be live for the watch to show what Grok is asking;
///   - an answer goes out as a live message when the phone is reachable, and is
///     handed to `transferUserInfo` when it is not. That queue is durable and is
///     delivered in the background, so a tap is never simply lost. The phone reports
///     on each queued answer with `["answered": requestId, "ok": Bool]`.
@MainActor
final class WatchStore: NSObject, ObservableObject {
    static let shared = WatchStore()

    /// The phone's snapshot as the screens show it: a request answered from here is
    /// already gone, even before the phone's next snapshot says so.
    @Published private(set) var snapshot = WatchSnapshot()
    /// Request ids answered from here that the phone has not confirmed yet, so the
    /// card can say so instead of offering the buttons a second time.
    @Published private(set) var queuedAnswers: Set<String> = []
    /// A genuine failure, in words. Cleared by the next snapshot.
    @Published var errorText: String?
    /// Whether the phone app can be reached right now. Being out of reach is the
    /// ordinary state of a wrist and is never painted as an error.
    @Published private(set) var reachable = false
    /// When the snapshot on screen arrived here, by this watch's clock.
    @Published private(set) var receivedAt: Date?
    /// Whether a snapshot has ever arrived on this watch. Remembered across launches:
    /// it separates "open the phone app once" from "nothing is running".
    @Published private(set) var hasEverReceived: Bool
    /// True until the first attempt to hear from the phone has finished, so a first
    /// launch shows a spinner rather than an instruction it may not need.
    @Published private(set) var lookingForPhone = true

    enum AnswerOutcome {
        /// The phone performed it and said so.
        case confirmed
        /// The phone is out of reach; the answer is in the durable queue.
        case queued
        /// The phone refused it, with `errorText` set.
        case failed
        /// The phone did not reply in time. It may well have performed it, so the
        /// answer was not sent again: a duplicate would be refused as already answered,
        /// or worse, land on the next request.
        case unknown
    }

    private var session: WCSession { WCSession.default }
    private var started = false
    /// The snapshot exactly as the phone sent it.
    private var received = WatchSnapshot()
    /// Requests the phone confirmed answering, hidden until a snapshot without them
    /// arrives. Application context and the confirmation travel separately, and the
    /// confirmation often wins.
    private var answered: Set<String> = []
    /// The request ids the last snapshot carried, so a NEW one can be told apart from
    /// one already on screen.
    private var knownRequestIds: Set<String> = []
    private var adoptedOnce = false
    /// Messages for `transferUserInfo` that arrived before the session finished
    /// activating, when handing them over would be refused.
    private var heldTransfers: [[String: Any]] = []
    private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    private var observations: [NSKeyValueObservation] = []

    private static let everReceivedKey = "tethrx.watch.everReceived"

    private override init() {
        hasEverReceived = UserDefaults.standard.bool(forKey: Self.everReceivedKey)
        super.init()
    }

    /// Idempotent: the app delegate calls it at launch (also a background launch, which
    /// has no scene), and the scene calls it again.
    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        // `-fixture…` fills the watch with canned state so its screens can be driven
        // and captured without a phone, a bridge or a Grok. Never compiled into a
        // release build.
        if let name = Self.fixtureArgument {
            loadFixture(named: name)
            return
        }
        #endif
        guard WCSession.isSupported() else {
            lookingForPhone = false
            return
        }
        session.delegate = self
        // A background task may only be completed once the session is activated and
        // has handed over everything pending; both change without a delegate call.
        observations = [
            session.observe(\.activationState) { [weak self] _, _ in
                Task { @MainActor in self?.completeBackgroundTasksIfIdle() }
            },
            session.observe(\.hasContentPending) { [weak self] _, _ in
                Task { @MainActor in self?.completeBackgroundTasksIfIdle() }
            },
        ]
        session.activate()
        // Never leave a first launch on a spinner: if the phone has not answered by
        // now, the instruction is the right screen.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            self?.lookingForPhone = false
        }
    }

    // MARK: Requests

    /// Ask the phone for a fresh list. Safe to call on every appearance: out of
    /// reach, it simply leaves the pushed snapshot in place.
    func refresh() async {
        #if DEBUG
        if Self.fixtureArgument != nil { return }
        #endif
        guard case .reply(let reply) = await send(["cmd": "snapshot"]),
              let data = reply["snapshot"] as? Data,
              let fresh = try? JSONDecoder.watch.decode(WatchSnapshot.self, from: data) else { return }
        adopt(fresh, receivedAt: Date())
    }

    func detail(for sessionId: String) async -> WatchDetail? {
        #if DEBUG
        if Self.fixtureArgument != nil { return fixtureDetail(for: sessionId) }
        #endif
        guard case .reply(let reply) = await send(["cmd": "detail", "sessionId": sessionId]),
              let data = reply["detail"] as? Data,
              let detail = try? JSONDecoder.watch.decode(WatchDetail.self, from: data) else { return nil }
        return detail
    }

    /// Whether the phone has confirmed this request answered.
    func isAnswered(_ requestId: String) -> Bool { answered.contains(requestId) }

    /// Answer a permission request or a plan review. A `reason` on a refusal is
    /// queued as the next message: refusing on its own tells Grok "no" and nothing
    /// else, so it tries a near-identical thing next.
    func answer(sessionId: String, approval: WatchApproval, allow: Bool, reason: String? = nil) async -> AnswerOutcome {
        var message: [String: Any] = ["sessionId": sessionId, "requestId": approval.requestId]
        if approval.isPlan {
            message["cmd"] = "plan"
            message["approved"] = allow
        } else {
            message["cmd"] = "decide"
            // Deny with no option id cancels the request outright, which the bridge
            // treats as a refusal. Allow with none is disabled in the UI.
            if let optionId = allow ? approval.allowOptionId : approval.denyOptionId {
                message["optionId"] = optionId
            }
        }
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { message["reason"] = trimmed }

        switch await send(message) {
        case .reply:
            answered.insert(approval.requestId)
            rebuild()
            play(.success)
            return .confirmed
        case .unreachable:
            // Delivered whenever the phone is next available, including a launch in
            // the background. Losing an approval because a wrist walked out of range
            // would be the worst possible failure here.
            transfer(message)
            queuedAnswers.insert(approval.requestId)
            play(.success)
            return .queued
        case .error(let text):
            errorText = text
            play(.failure)
            return .failed
        case .undelivered:
            errorText = String(localized: "Your iPhone did not answer in time.")
            play(.failure)
            return .unknown
        }
    }

    /// Queue a follow-up on the computer. It runs when the current turn ends, so
    /// this works whether or not Grok is busy.
    func reply(sessionId: String, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let message: [String: Any] = ["cmd": "reply", "sessionId": sessionId, "text": trimmed]
        switch await send(message) {
        case .reply:
            play(.success)
            return true
        case .unreachable:
            // Safe to queue: the bridge runs each follow-up once, in order. If the
            // phone cannot deliver it, it hands the words back in a notification.
            transfer(message)
            play(.success)
            return true
        case .error(let text):
            errorText = text
            play(.failure)
            return false
        case .undelivered:
            errorText = String(localized: "Your iPhone did not answer in time.")
            play(.failure)
            return false
        }
    }

    /// Never queued: a Stop delivered an hour late would end whatever turn is running
    /// by then.
    func stop(sessionId: String) async -> Bool {
        switch await send(["cmd": "stop", "sessionId": sessionId]) {
        case .reply:
            play(.success)
            return true
        case .unreachable:
            errorText = String(localized: "Open TethrX on your iPhone to stop this.")
            play(.failure)
            return false
        case .error(let text):
            errorText = text
            play(.failure)
            return false
        case .undelivered:
            errorText = String(localized: "Your iPhone did not answer in time.")
            play(.failure)
            return false
        }
    }

    // MARK: Background wake-ups

    /// A connectivity background task: new application context (or a report on a
    /// queued answer) arrived while the app was not running. Held until the session
    /// is activated and has handed everything over, which is when the snapshot has
    /// been adopted and the face complication rewritten, then completed.
    func hold(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        backgroundTasks.append(task)
        start()
        if session.activationState == .activated {
            applyContext(session.receivedApplicationContext)
        }
        completeBackgroundTasksIfIdle()
        // Never keep the system waiting indefinitely: whatever has arrived by then is
        // on the face already. Well inside the few seconds a background task gets, so
        // the fallback is never the reason the system ends the app.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.complete(task)
        }
    }

    private func completeBackgroundTasksIfIdle() {
        guard !backgroundTasks.isEmpty,
              session.activationState == .activated, !session.hasContentPending else { return }
        let tasks = backgroundTasks
        backgroundTasks = []
        for task in tasks { task.setTaskCompletedWithSnapshot(false) }
    }

    private func complete(_ task: WKWatchConnectivityRefreshBackgroundTask) {
        guard let index = backgroundTasks.firstIndex(where: { $0 === task }) else { return }
        backgroundTasks.remove(at: index)
        task.setTaskCompletedWithSnapshot(false)
    }

    // MARK: Plumbing

    private enum Outcome {
        case reply([String: Any])
        /// The phone cannot be reached or the session is not up: safe to queue.
        case unreachable
        /// The phone replied with a failure, in words.
        case error(String)
        /// Sent, but no reply came. The phone may have acted on it.
        case undelivered
    }

    /// One round trip, with every failure sorted into something the caller can act
    /// on. Only `.unreachable` means the message never left this watch.
    private func send(_ message: [String: Any]) async -> Outcome {
        guard WCSession.isSupported(), session.activationState == .activated else { return .unreachable }
        let result: Result<[String: Any], Error> = await withCheckedContinuation { continuation in
            // WatchConnectivity calls exactly one of these, on a queue of its own, but a
            // continuation resumed twice traps the process, and this is the one place
            // both handlers meet.
            let once = ResumeOnce(continuation)
            session.sendMessage(message) { response in
                once.resume(.success(response))
            } errorHandler: { error in
                once.resume(.failure(error))
            }
        }
        switch result {
        case .success(let reply):
            reachable = true
            if let text = reply["error"] as? String { return .error(text) }
            return .reply(reply)
        case .failure(let error):
            switch (error as? WCError)?.code {
            case .notReachable, .sessionNotActivated:
                // The NORMAL state of a wrist: the phone app is not in the foreground,
                // or the two are simply not connected. The message never left.
                reachable = false
                return .unreachable
            case .messageReplyTimedOut, .messageReplyFailed:
                // It left. Whether the phone acted on it is unknown.
                return .undelivered
            default:
                return .error(error.localizedDescription)
            }
        }
    }

    /// Hand a message to the durable queue, or hold it until the session can take it.
    private func transfer(_ message: [String: Any]) {
        if session.activationState == .activated {
            session.transferUserInfo(message)
        } else {
            heldTransfers.append(message)
        }
    }

    private func adopt(_ fresh: WatchSnapshot, receivedAt date: Date) {
        // Two copies can cross on the way: a reply to `refresh()` built before a push
        // and arriving after it. Both carry the phone's time for when the list was
        // read, so the older one loses, whichever came last. It used to win, and put
        // a request answered a moment ago back on the wrist.
        if adoptedOnce, fresh.updatedAt < received.updatedAt { return }
        // A request that was not there a moment ago deserves a tap on the wrist, but
        // only while someone is looking: the first snapshot after launch is simply
        // what the face already told them, and a background wake-up has no one to tap.
        let requestIds = Set(fresh.sessions.compactMap { $0.approval?.requestId })
        if adoptedOnce, WKApplication.shared().applicationState == .active,
           !requestIds.subtracting(knownRequestIds).isEmpty {
            play(.notification)
        }
        adoptedOnce = true
        knownRequestIds = requestIds
        // Anything the phone no longer reports as waiting has been answered, however
        // that answer got there.
        queuedAnswers.formIntersection(requestIds)
        answered.formIntersection(requestIds)
        received = fresh
        receivedAt = date
        errorText = nil
        lookingForPhone = false
        if !hasEverReceived {
            hasEverReceived = true
            UserDefaults.standard.set(true, forKey: Self.everReceivedKey)
        }
        rebuild()
    }

    /// The snapshot as shown: the phone's, minus requests already answered from here.
    private func rebuild() {
        var shown = received
        for index in shown.sessions.indices {
            guard let id = shown.sessions[index].approval?.requestId, answered.contains(id) else { continue }
            shown.sessions[index].approval = nil
            shown.sessions[index].waitingKind = nil
            shown.sessions[index].waitingLabel = nil
        }
        if shown != snapshot { snapshot = shown }
        ComplicationState.publish(shown)
    }

    private func applyContext(_ context: [String: Any]) {
        guard let data = context["snapshot"] as? Data,
              let fresh = try? JSONDecoder.watch.decode(WatchSnapshot.self, from: data) else { return }
        adopt(fresh, receivedAt: Date())
    }

    private func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

/// Resumes a continuation at most once, from whichever thread gets there first.
private final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - WatchConnectivity

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        let canReach = session.isReachable
        // Answers handed to the queue by an earlier launch and not yet delivered. The
        // set used to live in memory only, so relaunching the app put the buttons back
        // under a decision that was still on its way.
        let outstanding = session.outstandingUserInfoTransfers.compactMap { transfer -> String? in
            guard let cmd = transfer.userInfo["cmd"] as? String, cmd == "decide" || cmd == "plan" else { return nil }
            return transfer.userInfo["requestId"] as? String
        }
        Task { @MainActor in
            self.reachable = canReach
            guard state == .activated else {
                // Nothing will arrive on a session that did not come up.
                self.lookingForPhone = false
                for task in self.backgroundTasks { self.complete(task) }
                return
            }
            for message in self.heldTransfers { WCSession.default.transferUserInfo(message) }
            self.heldTransfers = []
            self.queuedAnswers.formUnion(outstanding)
            // The phone pushes application context whenever its list changes; adopt
            // whatever arrived while this app was not running.
            self.applyContext(context)
            self.completeBackgroundTasksIfIdle()
            if canReach, WKApplication.shared().applicationState == .active {
                await self.refresh()
            }
            self.lookingForPhone = false
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let canReach = session.isReachable
        Task { @MainActor in
            self.reachable = canReach
            // Coming back into range is the moment to catch up.
            if canReach, WKApplication.shared().applicationState == .active {
                await self.refresh()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in
            self.applyContext(context)
            self.completeBackgroundTasksIfIdle()
        }
    }

    /// A queued answer left this watch, or failed to. Without this, an answer whose
    /// transfer failed, or whose phone was ended before it could report back, said
    /// "Sent, waiting for your iPhone" with no buttons until the app was relaunched.
    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let info = userInfoTransfer.userInfo
        guard let cmd = info["cmd"] as? String, cmd == "decide" || cmd == "plan",
              let requestId = info["requestId"] as? String else { return }
        let failed = error != nil
        Task { @MainActor in
            if failed {
                // It never reached the phone: the buttons come back, and say why.
                guard self.queuedAnswers.remove(requestId) != nil else { return }
                self.errorText = String(localized: "Your iPhone could not pass that answer on.")
                if WKApplication.shared().applicationState == .active { self.play(.failure) }
            } else {
                // On the phone now, which reports back once the computer has it. A
                // report that never comes must not hold the buttons back for good: a
                // second answer is safe, since the computer refuses a repeat.
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                self.queuedAnswers.remove(requestId)
            }
        }
    }

    /// The phone reporting on a queued answer: delivered, or refused.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let requestId = userInfo["answered"] as? String
        let failed = userInfo["ok"] as? Bool == false
        let reason = userInfo["error"] as? String
        Task { @MainActor in
            defer { self.completeBackgroundTasksIfIdle() }
            guard let requestId else { return }
            let wasQueued = self.queuedAnswers.remove(requestId) != nil
            if failed {
                // The buttons come back. Said out loud only while the request is still
                // on screen: one that has since gone needs no answer from anyone.
                guard wasQueued else { return }
                self.errorText = reason ?? String(localized: "Your iPhone could not pass that answer on.")
                if WKApplication.shared().applicationState == .active { self.play(.failure) }
            } else {
                // Older phones send the id alone, and only on success.
                self.answered.insert(requestId)
                self.rebuild()
            }
        }
    }
}

// MARK: - Fixtures (debug builds only)

#if DEBUG
extension WatchStore {
    /// Canned states for capturing the screens:
    ///   -fixture          something waiting, a plan to review, something running, something idle
    ///   -fixtureQuiet     the same computer with nothing waiting
    ///   -fixtureEmpty     a computer with no sessions
    ///   -fixtureUnpaired  no computer paired on the phone
    ///   -fixtureFirstRun  nothing has ever arrived and the phone is out of reach
    ///   -fixtureOne       exactly one request waiting, which the list opens on
    /// and `-queued` marks the first request as answered from here, still in transit.
    static var fixtureArgument: String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-fixture") }
    }

    private func loadFixture(named name: String) {
        let arrived = Date().addingTimeInterval(-170)
        if ProcessInfo.processInfo.arguments.contains("-queued") { queuedAnswers = ["req-1"] }
        switch name {
        case "-fixtureOne":
            var one = Self.fixture
            one.sessions.removeAll { $0.id == "fixture-4" }
            adopt(one, receivedAt: arrived)
        case "-fixtureQuiet":
            adopt(Self.fixtureQuiet, receivedAt: arrived)
        case "-fixtureEmpty":
            adopt(WatchSnapshot(computer: "demo-mac", connected: true, sessions: [], updatedAt: arrived),
                  receivedAt: arrived)
        case "-fixtureUnpaired":
            adopt(WatchSnapshot(connected: false, updatedAt: arrived), receivedAt: arrived)
        case "-fixtureFirstRun":
            hasEverReceived = false
            reachable = false
            lookingForPhone = false
        default:
            adopt(Self.fixture, receivedAt: arrived)
        }
    }

    static var fixture: WatchSnapshot {
        WatchSnapshot(
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
                                                     allowOptionId: "allow", denyOptionId: "reject",
                                                     kind: "permission")),
                WatchSession(id: "fixture-4", name: "Migrate the billing cron to Postgres", folder: "Acme app",
                             status: "running",
                             waitingKind: "plan", waitingLabel: "Plan ready to review",
                             since: Date().addingTimeInterval(-31), turns: 2,
                             approval: WatchApproval(requestId: "plan-1", command: "", kind: "plan")),
                WatchSession(id: "fixture-2", name: "Dark mode for settings", folder: "Acme app",
                             status: "running", since: Date().addingTimeInterval(-212), turns: 6),
                WatchSession(id: "fixture-3", name: "Landing page hero", turns: 1,
                             lastActivity: Date().addingTimeInterval(-3_900)),
            ],
            updatedAt: Date().addingTimeInterval(-170)
        )
    }

    static var fixtureQuiet: WatchSnapshot {
        WatchSnapshot(
            computer: "demo-mac",
            connected: true,
            sessions: [
                WatchSession(id: "fixture-2", name: "Dark mode for settings", folder: "Acme app",
                             status: "running", since: Date().addingTimeInterval(-212), turns: 6),
                WatchSession(id: "fixture-3", name: "Landing page hero", turns: 1,
                             lastActivity: Date().addingTimeInterval(-3_900)),
                WatchSession(id: "fixture-5", name: "Rename the API package", turns: 14,
                             lastActivity: Date().addingTimeInterval(-86_400 * 2)),
            ],
            updatedAt: Date().addingTimeInterval(-170)
        )
    }

    private func fixtureDetail(for sessionId: String) -> WatchDetail {
        let session = received.sessions.first { $0.id == sessionId }
        var approval = session?.approval
        if approval?.isPlan == true {
            approval?.command = "1. Add a jobs table with a unique (name, run_at) key.\n2. Port the three cron scripts to pg-boss workers.\n3. Keep the old cron for a week behind a flag."
        }
        let isPlan = approval?.isPlan == true
        return WatchDetail(
            sessionId: sessionId, name: session?.name ?? "", busy: session?.isRunning ?? false,
            lines: [
                WatchLine(kind: "user", text: "The auth test fails once every ~20 CI runs.", id: 0),
                WatchLine(kind: "tool", text: "swift test --filter AuthTests", id: 1),
                WatchLine(kind: "grok", text: "Passes in isolation, so another test leaves state behind.", id: 2),
            ],
            approval: approval,
            lastReply: isPlan
                ? "I have a plan for the migration. The cron jobs become pg-boss workers, so retries and locking come from the database instead of three shell scripts."
                : "It passes in isolation, so another test is leaving **state** behind. The stale `.build` directory is the most likely culprit; I would like to remove it and run the suite again.",
            lastUser: isPlan
                ? "Move the billing cron jobs to Postgres. Plan it first."
                : "The auth test fails once every ~20 CI runs. Find out why."
        )
    }
}
#endif
