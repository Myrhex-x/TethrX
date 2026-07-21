import Foundation

/// The slice of the bridge API the share extension needs: list the sessions, and
/// queue something into one. Deliberately tiny and separate from `BridgeClient` —
/// an extension has a hard memory budget and no business carrying the whole app.
struct ShareClient {
    let bridge: SharedConfig.Bridge
    let token: String

    private var session: URLSession {
        if let pin = bridge.pin, !pin.isEmpty { return PinnedSessions.session(for: pin) }
        return .shared
    }

    struct Session: Codable, Identifiable, Hashable {
        let id: String
        var title: String
        var cwd: String?
        var status: String
        var folder: String?

        var isRunning: Bool { status == "running" }
        var displayName: String {
            let named = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !named.isEmpty, named != "New session" { return named }
            if let cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
            return "session"
        }
    }

    private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil) throws -> URLRequest {
        guard var comps = URLComponents(string: bridge.address.contains("://")
                                        ? bridge.address
                                        : "http://\(bridge.address)") else {
            throw ShareError.badAddress
        }
        comps.path = path
        guard let url = comps.url else { throw ShareError.badAddress }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    func sessions() async throws -> [Session] {
        let (data, resp) = try await session.data(for: try request("/api/sessions"))
        try check(resp)
        struct Wrapper: Codable { let sessions: [Session] }
        return try JSONDecoder().decode(Wrapper.self, from: data).sessions
    }

    /// Queue the shared content. The bridge runs it now if the session is idle, or
    /// when the current turn finishes — either way this call returns straight away.
    func share(sessionId: String, text: String, images: [Data] = []) async throws {
        var body: [String: Any] = ["text": text, "source": "share"]
        if !images.isEmpty {
            body["images"] = images.map { ["data": $0.base64EncodedString(), "mimeType": "image/jpeg"] }
        }
        let (_, resp) = try await session.data(
            for: try request("/api/sessions/\(sessionId)/queue", method: "POST", json: body))
        try check(resp)
    }

    /// Start a new session on the bridge, for sharing without picking an existing one.
    func createSession() async throws -> Session {
        let (data, resp) = try await session.data(for: try request("/api/sessions", method: "POST", json: [:]))
        try check(resp)
        return try JSONDecoder().decode(Session.self, from: data)
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw ShareError.unauthorized }
        if !(200...299).contains(http.statusCode) { throw ShareError.status(http.statusCode) }
    }
}

enum ShareError: LocalizedError {
    case badAddress
    case unauthorized
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badAddress: return String(localized: "That computer's address looks wrong.")
        case .unauthorized: return String(localized: "Your computer rejected the pairing token. Re-pair in TethrX.")
        case .status(let code): return String(localized: "Your computer answered with an error (\(code)).")
        }
    }
}
