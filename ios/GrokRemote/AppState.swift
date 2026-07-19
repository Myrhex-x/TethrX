import Foundation
import SwiftUI

/// Connection + session-list state. Persists the server address, pairing token,
/// and default working directory to UserDefaults so pairing survives relaunches.
@MainActor
final class AppState: ObservableObject {
    @Published var baseURLString: String { didSet { store("bridge.baseURL", baseURLString) } }
    @Published var token: String { didSet { Keychain.save(token) } }
    @Published var defaultCwd: String { didSet { store("bridge.cwd", defaultCwd) } }
    @Published var defaultEffort: String { didSet { store("bridge.effort", defaultEffort) } }   // "", high, medium, low
    @Published var defaultPlanMode: Bool { didSet { UserDefaults.standard.set(defaultPlanMode, forKey: "bridge.planMode") } }
    @Published var defaultAutoApprove: Bool { didSet { UserDefaults.standard.set(defaultAutoApprove, forKey: "bridge.autoApprove") } }

    @Published var health: HealthInfo?
    @Published var sessions: [SessionInfo] = []
    @Published var connected = false
    @Published var connecting = false
    @Published var errorMessage: String?

    /// Set by a debug launch argument to auto-open a session (UI testing only).
    @Published var pendingOpenSessionId: String?

    init() {
        let d = UserDefaults.standard
        baseURLString = d.string(forKey: "bridge.baseURL") ?? ""
        // A launch-arg token (debug) wins; otherwise load the secret from the Keychain.
        token = d.string(forKey: "bridge.token") ?? Keychain.load() ?? ""
        defaultCwd = d.string(forKey: "bridge.cwd") ?? ""
        defaultEffort = d.string(forKey: "bridge.effort") ?? ""
        defaultPlanMode = d.bool(forKey: "bridge.planMode")
        defaultAutoApprove = d.bool(forKey: "bridge.autoApprove")
    }

    private func store(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// A ready-to-use client, or nil if not enough info to build one.
    var client: BridgeClient? {
        guard let url = URL(string: normalizedBase), !token.isEmpty, !normalizedBase.isEmpty else { return nil }
        return BridgeClient(config: .init(baseURL: url, token: token))
    }

    /// Accepts "192.168.1.10:4180" or a full URL; defaults to http and trims a trailing slash.
    var normalizedBase: String {
        var s = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    func connect() async {
        guard let client else {
            errorMessage = "Enter the bridge address and pairing token."
            return
        }
        connecting = true
        errorMessage = nil
        defer { connecting = false }
        do {
            let h = try await client.health()
            health = h
            sessions = try await client.listSessions()
            connected = true
        } catch {
            connected = false
            errorMessage = friendly(error)
        }
    }

    func reloadSessions() async {
        guard let client else { return }
        do { sessions = try await client.listSessions() }
        catch { errorMessage = friendly(error) }
    }

    func newSession() async -> SessionInfo? {
        guard let client else { return nil }
        do {
            let s = try await client.createSession(cwd: defaultCwd.isEmpty ? nil : defaultCwd,
                                                   effort: defaultEffort.isEmpty ? nil : defaultEffort,
                                                   planMode: defaultPlanMode,
                                                   autoApprove: defaultAutoApprove)
            sessions.insert(s, at: 0)
            return s
        } catch {
            errorMessage = friendly(error)
            return nil
        }
    }

    func deleteSession(_ id: String) async {
        guard let client else { return }
        do {
            try await client.deleteSession(id)
            sessions.removeAll { $0.id == id }
        } catch { errorMessage = friendly(error) }
    }

    func renameSession(_ id: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty else { return }
        do {
            try await client.renameSession(id, title: trimmed)
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].title = trimmed }
        } catch { errorMessage = friendly(error) }
    }

    func disconnect() {
        connected = false
        health = nil
        sessions = []
        errorMessage = nil
    }

    /// Debug-only: `-autoconnect` connects on launch, `-openSession <id>` deep-opens
    /// a session. Used to screenshot the UI headlessly; inert in Release builds.
    func handleLaunchArguments() async {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-openSession"), i + 1 < args.count {
            pendingOpenSessionId = args[i + 1]
        }
        if args.contains("-autoconnect") {
            await connect()
        }
        #endif
    }

    private func friendly(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost:
                return "Can't reach the bridge. Check the address and that the daemon is running."
            default:
                return urlErr.localizedDescription
            }
        }
        return (error as? BridgeError)?.errorDescription ?? error.localizedDescription
    }
}
