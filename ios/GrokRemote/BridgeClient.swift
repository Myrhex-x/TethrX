import Foundation

struct BridgeConfig: Equatable {
    var baseURL: URL
    var token: String
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
    private var session: URLSession { .shared }

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

    func health() async throws -> HealthInfo {
        let (data, resp) = try await session.data(for: try request("/api/health"))
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

    /// Answer a pending ACP permission request. Pass nil to cancel.
    func resolvePermission(sessionId: String, requestId: String, optionId: String?, always: Bool = false) async throws {
        var body: [String: Any] = optionId.map { ["optionId": $0] } ?? [:]
        if always { body["always"] = true }
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

    func gitStatus(sessionId: String) async throws -> GitStatus {
        let (data, resp) = try await session.data(for: try request("/api/sessions/\(sessionId)/git"))
        try Self.check(resp)
        return try JSONDecoder().decode(GitStatus.self, from: data)
    }

    func gitDiff(sessionId: String, file: String) async throws -> String {
        guard var comps = URLComponents(url: try url("/api/sessions/\(sessionId)/git"), resolvingAgainstBaseURL: false) else {
            throw BridgeError.badURL
        }
        comps.queryItems = [URLQueryItem(name: "file", value: file)]
        guard let u = comps.url else { throw BridgeError.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 20
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct Wrapper: Codable { let diff: String }
        return (try? JSONDecoder().decode(Wrapper.self, from: data).diff) ?? ""
    }

    @discardableResult
    func gitCommit(sessionId: String, message: String) async throws -> String {
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/git", method: "POST",
                             json: ["action": "commit", "message": message]))
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let output: String?; let error: String? }
        let r = try JSONDecoder().decode(Result.self, from: data)
        if !r.ok { throw BridgeError.badStatus(500) }
        return r.output ?? ""
    }

    @discardableResult
    func gitDiscard(sessionId: String) async throws -> String {
        let (data, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/git", method: "POST", json: ["action": "discard"]))
        try Self.check(resp)
        struct Result: Codable { let ok: Bool; let output: String?; let error: String? }
        let r = try JSONDecoder().decode(Result.self, from: data)
        return r.output ?? ""
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
