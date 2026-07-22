import Foundation

struct BridgeConfig: Equatable {
    var baseURL: URL
    var token: String
    /// SHA-256 fingerprint of the bridge's self-signed cert; set for pinned HTTPS.
    var pin: String? = nil
}

enum BridgeError: LocalizedError {
    case badURL
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid server address."
        case .badStatus(401): return "Unauthorized — check your pairing token."
        case .badStatus(let code): return "Server returned status \(code)."
        }
    }
}

/// Talks to the TethrX bridge daemon. All calls are async; `events(…)`
/// returns a live stream of normalized Server-Sent Events.
struct BridgeClient {
    let config: BridgeConfig
    private var session: URLSession {
        if let pin = config.pin, !pin.isEmpty { return PinnedSessions.session(for: pin) }
        return .shared
    }

    // MARK: Requests

    private func url(_ path: String) throws -> URL {
        guard var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.path = path
        guard let u = comps.url else { throw BridgeError.badURL }
        return u
    }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.timeoutInterval = 15   // bound failed reconnects (streaming sets its own)
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw BridgeError.badStatus(http.statusCode)
        }
    }

    // MARK: Endpoints

    /// `timeout` exists for the connect-time probe: a reachable bridge answers in
    /// milliseconds, but a port that accepts the connection and then stalls (a dead
    /// TLS listener, something else squatting the port) holds the default timeout
    /// open — long enough that Reconnect looks like it simply doesn't work.
    func health(timeout: TimeInterval? = nil) async throws -> HealthInfo {
        var req = try request("/api/health")
        if let timeout { req.timeoutInterval = timeout }
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(HealthInfo.self, from: data)
    }

    func listSessions() async throws -> [SessionInfo] {
        let (data, resp) = try await session.data(for: try request("/api/sessions"))
        try Self.check(resp)
        struct Wrapper: Codable { let sessions: [SessionInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).sessions
    }

    /// Overall token/cost usage across all sessions (`GET /api/usage`).
    func usage() async throws -> UsageReport {
        let (data, resp) = try await session.data(for: try request("/api/usage"))
        try Self.check(resp)
        return try JSONDecoder().decode(UsageReport.self, from: data)
    }

    func createSession(cwd: String?, effort: String? = nil, planMode: Bool = false, autoApprove: Bool = false) async throws -> SessionInfo {
        var body: [String: Any] = [:]
        if let cwd, !cwd.isEmpty { body["cwd"] = cwd }
        if let effort, !effort.isEmpty { body["effort"] = effort }
        if planMode { body["planMode"] = true }
        if autoApprove { body["autoApprove"] = true }
        let (data, resp) = try await session.data(for: try request("/api/sessions", method: "POST", json: body))
        try Self.check(resp)
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }

    func deleteSession(_ id: String) async throws {
        let (_, resp) = try await session.data(for: try request("/api/sessions/\(id)", method: "DELETE"))
        try Self.check(resp)
    }

    func renameSession(_ id: String, title: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(id)", method: "PATCH", json: ["title": title]))
        try Self.check(resp)
    }

    /// Set (or clear, with "") a session's folder grouping.
    func setFolder(_ id: String, folder: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(id)", method: "PATCH", json: ["folder": folder]))
        try Self.check(resp)
    }

    /// Register this device's APNs token so the bridge can push alerts.
    func registerDevice(_ token: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/devices", method: "POST", json: ["token": token]))
        try Self.check(resp)
    }

    /// Send a message; images ride along as base64 JPEG/PNG and the bridge saves
    /// them to disk for grok's vision-capable read tool (ACP itself rejects image
    /// content blocks, so the file path IS the transport).
    func send(sessionId: String, text: String, images: [Data] = [], mimeType: String = "image/jpeg") async throws {
        var body: [String: Any] = ["text": text]
        if !images.isEmpty {
            body["images"] = images.map { ["data": $0.base64EncodedString(), "mimeType": mimeType] }
        }
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/messages", method: "POST", json: body))
        try Self.check(resp)
    }

    // MARK: Filesystem (picker + project browser)

    private func getQuery(_ path: String, query: [String: String]) throws -> URLRequest {
        guard var comps = URLComponents(url: try url(path), resolvingAgainstBaseURL: false) else { throw BridgeError.badURL }
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Browse folders on the computer (home-jailed) for the working-dir picker.
    func listDirs(path: String?) async throws -> DirListing {
        let req = try path.map { try getQuery("/api/fs/dirs", query: ["path": $0]) } ?? request("/api/fs/dirs")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(DirListing.self, from: data)
    }

    /// List one folder of the session's project (path relative to its cwd).
    func listFiles(sessionId: String, path: String) async throws -> [FileEntry] {
        let (data, resp) = try await session.data(
            for: try getQuery("/api/sessions/\(sessionId)/files", query: ["path": path]))
        try Self.check(resp)
        struct Wrapper: Codable { let entries: [FileEntry] }
        return try JSONDecoder().decode(Wrapper.self, from: data).entries
    }

    /// Fetch a text file's content from the session's project.
    func fileContent(sessionId: String, path: String) async throws -> FileContent {
        let (data, resp) = try await session.data(
            for: try getQuery("/api/sessions/\(sessionId)/file", query: ["path": path]))
        try Self.check(resp)
        return try JSONDecoder().decode(FileContent.self, from: data)
    }

    // MARK: Scheduled tasks

    func listSchedules() async throws -> [BridgeSchedule] {
        let (data, resp) = try await session.data(for: try request("/api/schedules"))
        try Self.check(resp)
        struct Wrapper: Codable { let schedules: [BridgeSchedule] }
        return try JSONDecoder().decode(Wrapper.self, from: data).schedules
    }

    @discardableResult
    func createSchedule(sessionId: String, prompt: String, hour: Int, minute: Int, weekdays: [Int]) async throws -> BridgeSchedule {
        let (data, resp) = try await session.data(
            for: try request("/api/schedules", method: "POST",
                             json: ["sessionId": sessionId, "prompt": prompt, "hour": hour, "minute": minute, "weekdays": weekdays]))
        try Self.check(resp)
        return try JSONDecoder().decode(BridgeSchedule.self, from: data)
    }

    func setScheduleEnabled(_ id: String, enabled: Bool) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/schedules/\(id)", method: "PATCH", json: ["enabled": enabled]))
        try Self.check(resp)
    }

    func deleteSchedule(_ id: String) async throws {
        let (_, resp) = try await session.data(for: try request("/api/schedules/\(id)", method: "DELETE"))
        try Self.check(resp)
    }

    /// Compact a session: the bridge runs one summary turn, then returns a fresh
    /// session seeded with the handoff. Slow (a real grok turn) — long timeout.
    func compact(sessionId: String) async throws -> SessionInfo {
        var req = try request("/api/sessions/\(sessionId)/compact", method: "POST", json: [:])
        req.timeoutInterval = 300
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }

    // MARK: Follow-up queue

    /// Queue a follow-up. The bridge runs it when the current turn ends — or straight
    /// away if nothing is running, which is what lets a notification reply or a share
    /// use this one call without knowing the session's state.
    @discardableResult
    func enqueue(sessionId: String, text: String, source: String = "phone") async throws -> [QueuedMessage] {
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/queue", method: "POST",
                             json: ["text": text, "source": source]))
        try Self.check(resp)
        struct Wrapper: Codable { let queue: [QueuedMessage] }
        return (try? JSONDecoder().decode(Wrapper.self, from: data).queue) ?? []
    }

    func dequeue(sessionId: String, itemId: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/queue/\(itemId)", method: "DELETE"))
        try Self.check(resp)
    }

    func clearQueue(sessionId: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/queue", method: "DELETE"))
        try Self.check(resp)
    }

    /// Fork a session: a new one that starts knowing everything this one knows.
    /// Slow when there's history (the bridge runs a summary turn) — long timeout.
    func branch(sessionId: String, title: String? = nil) async throws -> SessionInfo {
        var body: [String: Any] = [:]
        if let title, !title.isEmpty { body["title"] = title }
        var req = try request("/api/sessions/\(sessionId)/branch", method: "POST", json: body)
        req.timeoutInterval = 300
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }

    /// Day-by-day token/cost rollups (`GET /api/usage/history`).
    func usageHistory(days: Int = 30) async throws -> [UsageDay] {
        let (data, resp) = try await session.data(for: try getQuery("/api/usage/history", query: ["days": String(days)]))
        try Self.check(resp)
        struct Wrapper: Codable { let days: [UsageDay] }
        return try JSONDecoder().decode(Wrapper.self, from: data).days
    }

    /// Full-text search across every session's conversation history.
    func search(_ query: String) async throws -> [SearchResult] {
        let (data, resp) = try await session.data(for: try getQuery("/api/search", query: ["q": query]))
        try Self.check(resp)
        struct Wrapper: Codable { let results: [SearchResult] }
        return try JSONDecoder().decode(Wrapper.self, from: data).results
    }

    /// The bridge's recent console output (startup, grok stderr, errors).
    func logs() async throws -> [String] {
        let (data, resp) = try await session.data(for: try request("/api/logs"))
        try Self.check(resp)
        struct Wrapper: Codable { let lines: [String] }
        return try JSONDecoder().decode(Wrapper.self, from: data).lines
    }

    /// Register ActivityKit push tokens so the bridge can drive lock-screen
    /// activities with the app closed. kind: "start-token" | "update-token".
    func registerLiveActivity(kind: String, token: String, sessionId: String? = nil) async throws {
        var body: [String: Any] = ["kind": kind, "token": token]
        if let sessionId { body["sessionId"] = sessionId }
        let (_, resp) = try await session.data(
            for: try request("/api/live-activity", method: "POST", json: body))
        try Self.check(resp)
    }

    func cancel(sessionId: String) async {
        _ = try? await session.data(
            for: try request("/api/sessions/\(sessionId)/cancel", method: "POST", json: [:]))
    }

    /// Like `cancel`, but the caller learns whether the bridge actually heard it —
    /// a Stop that silently failed left the turn running while the UI shrugged.
    func cancelOrThrow(sessionId: String) async throws {
        var req = try request("/api/sessions/\(sessionId)/cancel", method: "POST", json: [:])
        req.timeoutInterval = 10
        let (_, resp) = try await session.data(for: req)
        try Self.check(resp)
    }

    /// Answer a pending ACP permission request. Pass nil to cancel. A `reason` is
    /// queued as the next message, so denying can say why in one step.
    func resolvePermission(sessionId: String, requestId: String, optionId: String?,
                           always: Bool = false, reason: String? = nil) async throws {
        var body: [String: Any] = optionId.map { ["optionId": $0] } ?? [:]
        if always { body["always"] = true }
        if let reason, !reason.isEmpty { body["reason"] = reason }
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/permissions/\(requestId)", method: "POST", json: body))
        try Self.check(resp)
    }

    /// Live per-session settings (plan mode, reasoning effort, auto-approve).
    @discardableResult
    func setConfig(sessionId: String, planMode: Bool? = nil, effort: String? = nil, autoApprove: Bool? = nil) async throws -> SessionInfo {
        var body: [String: Any] = [:]
        if let planMode { body["planMode"] = planMode }
        if let effort { body["effort"] = effort }
        if let autoApprove { body["autoApprove"] = autoApprove }
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/config", method: "POST", json: body))
        try Self.check(resp)
        return try JSONDecoder().decode(SessionInfo.self, from: data)
    }

    /// Approve or reject a plan (plan mode). Approving proceeds to execution.
    func resolvePlan(sessionId: String, requestId: String, approved: Bool) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/plan/\(requestId)", method: "POST", json: ["approved": approved]))
        try Self.check(resp)
    }

    // MARK: Git review

    /// `dir` picks among the repos the session touched (nil = the bridge's default:
    /// the session folder when it's a repo, else the most recently edited repo).
    func gitStatus(sessionId: String, dir: String? = nil) async throws -> GitStatus {
        let req = try dir.map { try getQuery("/api/sessions/\(sessionId)/git", query: ["dir": $0]) }
            ?? request("/api/sessions/\(sessionId)/git")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(GitStatus.self, from: data)
    }

    func gitDiff(sessionId: String, file: String, dir: String? = nil) async throws -> String {
        var query = ["file": file]
        if let dir { query["dir"] = dir }
        var req = try getQuery("/api/sessions/\(sessionId)/git", query: query)
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let diff: String }
        return (try? JSONDecoder().decode(Wrapper.self, from: data).diff) ?? ""
    }

    @discardableResult
    func gitCommit(sessionId: String, message: String, dir: String? = nil) async throws -> String {
        var body: [String: Any] = ["action": "commit", "message": message]
        if let dir { body["dir"] = dir }
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/git", method: "POST", json: body))
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let output: String?; let error: String? }
        let r = try JSONDecoder().decode(Result.self, from: data)
        if !r.ok { throw BridgeError.badStatus(500) }
        return r.output ?? ""
    }

    @discardableResult
    func gitDiscard(sessionId: String, dir: String? = nil) async throws -> String {
        var body: [String: Any] = ["action": "discard"]
        if let dir { body["dir"] = dir }
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/git", method: "POST", json: body))
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let output: String?; let error: String? }
        let r = try JSONDecoder().decode(Result.self, from: data)
        return r.output ?? ""
    }

    /// Grok's slash commands for this session — the "/" palette.
    func commands(sessionId: String) async throws -> [SlashCommand] {
        let (data, resp) = try await session.data(for: try request("/api/sessions/\(sessionId)/commands"))
        try Self.check(resp)
        struct Wrapper: Codable { let commands: [SlashCommand] }
        return try JSONDecoder().decode(Wrapper.self, from: data).commands
    }

    /// Saved grok workflows visible to this session (user scope + its project).
    func workflows(sessionId: String?) async throws -> [WorkflowInfo] {
        let req = try sessionId.map { try getQuery("/api/workflows", query: ["sessionId": $0]) }
            ?? request("/api/workflows")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let workflows: [WorkflowInfo] }
        return try JSONDecoder().decode(Wrapper.self, from: data).workflows
    }

    /// Installed grok plugins on the computer.
    func grokPlugins() async throws -> [GrokPlugin] {
        var req = try request("/api/grok/plugins")
        req.timeoutInterval = 30
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let plugins: [GrokPlugin] }
        return try JSONDecoder().decode(Wrapper.self, from: data).plugins
    }

    /// Manage a plugin. `install` takes `source` (git URL / GitHub shorthand);
    /// the rest take `name`. Returns the refreshed list.
    func grokPluginAction(_ action: String, name: String? = nil, source: String? = nil) async throws -> [GrokPlugin] {
        var body: [String: Any] = ["action": action]
        if let name { body["name"] = name }
        if let source { body["source"] = source }
        var req = try request("/api/grok/plugins", method: "POST", json: body)
        req.timeoutInterval = 200      // installs clone a repo
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let output: String?; let plugins: [GrokPlugin] }
        let r = try JSONDecoder().decode(Result.self, from: data)
        if !r.ok { throw BridgeError.badStatus(500) }
        return r.plugins
    }

    /// Grok binary version state on the computer (current vs latest).
    func grokUpdateStatus() async throws -> GrokUpdateStatus {
        var req = try request("/api/grok/update")
        req.timeoutInterval = 30       // may run `grok update --check` on the spot
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try JSONDecoder().decode(GrokUpdateStatus.self, from: data)
    }

    /// Ask the bridge to install the latest grok now. Throws .busy (409) while a
    /// session is running. Slow: downloads + swaps the binary.
    func grokUpdateInstall() async throws -> String {
        var req = try request("/api/grok/update", method: "POST")
        req.timeoutInterval = 320
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let upToDate: Bool?; let version: String?; let output: String? }
        let r = try JSONDecoder().decode(Result.self, from: data)
        return r.version ?? ""
    }

    /// Live event stream for a session. Each yielded value is one normalized
    /// event object (e.g. `["kind": "text", "text": "…"]`). The stream ends when
    /// the connection closes; callers typically reconnect.
    func events(sessionId: String, lastEventId: Int = 0) -> AsyncThrowingStream<[String: Any], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = try request("/api/sessions/\(sessionId)/stream")
                    req.timeoutInterval = 3600
                    req.setValue(String(lastEventId), forHTTPHeaderField: "Last-Event-ID")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, resp) = try await session.bytes(for: req)
                    try Self.check(resp)
                    // Tell the fold loop the stream is genuinely open — the UI's
                    // "connected" state keys off delivery, not off dialing.
                    continuation.yield(["kind": "_open"])

                    // SSE frames are line-delimited: an `id:` line then a `data:` line.
                    // The id has to be surfaced, otherwise a reconnect can't tell the
                    // bridge where it left off and the whole history replays again.
                    var currentId = 0
                    for try await line in bytes.lines {
                        if line.hasPrefix("id:") {
                            currentId = Int(line.dropFirst(3).trimmingCharacters(in: .whitespaces)) ?? currentId
                            continue
                        }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        if currentId > 0 { obj["_eventId"] = currentId }
                        continuation.yield(obj)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
