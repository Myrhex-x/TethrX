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

    func send(sessionId: String, text: String) async throws {
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/messages", method: "POST", json: ["text": text]))
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

                    // SSE frames are line-delimited; we only care about `data:` lines,
                    // each of which carries one JSON event from the bridge.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
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
