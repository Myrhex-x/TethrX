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
    /// True after the user taps Disconnect — suppresses launch auto-reconnect until they
    /// manually Connect again. Persisted so an explicit Disconnect survives relaunch.
    @Published var userDisconnected: Bool { didSet { UserDefaults.standard.set(userDisconnected, forKey: "bridge.userDisconnected") } }

    /// Every computer that's been paired, so you can switch between e.g. a laptop
    /// and a desktop. Tokens live in the Keychain, one slot per bridge.
    @Published var savedBridges: [SavedBridge] = []
    @Published var activeBridgeId: String?

    @Published var health: HealthInfo?
    @Published var sessions: [SessionInfo] = []
    @Published var lastUsage: UsageReport?      // for the home-screen widget
    @Published var connected = false
    @Published var connecting = false
    @Published var bootstrapping = false   // first-launch auto-reconnect in progress
    @Published var errorMessage: String?

    /// Set by a debug launch argument to auto-open a session (UI testing only).
    @Published var pendingOpenSessionId: String?

    /// Latest APNs device token (from PushManager); re-sent to the bridge on connect.
    var pushToken: String?

    init() {
        let d = UserDefaults.standard
        baseURLString = d.string(forKey: "bridge.baseURL") ?? ""
        // A launch-arg token (debug) wins; otherwise load the secret from the Keychain.
        token = d.string(forKey: "bridge.token") ?? Keychain.load() ?? ""
        defaultCwd = d.string(forKey: "bridge.cwd") ?? ""
        defaultEffort = d.string(forKey: "bridge.effort") ?? ""
        defaultPlanMode = d.bool(forKey: "bridge.planMode")
        defaultAutoApprove = d.bool(forKey: "bridge.autoApprove")
        userDisconnected = d.bool(forKey: "bridge.userDisconnected")
        activeBridgeId = d.string(forKey: "bridge.activeId")
        customFolders = d.stringArray(forKey: "bridge.folders") ?? []
        folderOrder = d.stringArray(forKey: "bridge.folderOrder") ?? []
        if let data = d.data(forKey: "bridge.saved"),
           let list = try? JSONDecoder().decode([SavedBridge].self, from: data) {
            savedBridges = list
        }
    }

    // MARK: Paired computers

    private func persistBridges() {
        if let data = try? JSONEncoder().encode(savedBridges) {
            UserDefaults.standard.set(data, forKey: "bridge.saved")
        }
        UserDefaults.standard.set(activeBridgeId, forKey: "bridge.activeId")
    }

    /// After a successful connect, remember this computer (and its token) so it can
    /// be switched back to later. Named from the bridge's reported hostname.
    private func rememberCurrentBridge() {
        let addr = normalizedBase
        guard !addr.isEmpty, !token.isEmpty else { return }
        let name = (health?.host?.isEmpty == false) ? health!.host! : (URL(string: addr)?.host ?? addr)
        if let i = savedBridges.firstIndex(where: { $0.address == addr }) {
            savedBridges[i].name = name
            activeBridgeId = savedBridges[i].id
            Keychain.save(token, account: savedBridges[i].tokenAccount)
        } else {
            let bridge = SavedBridge(id: UUID().uuidString, name: name, address: addr)
            savedBridges.append(bridge)
            activeBridgeId = bridge.id
            Keychain.save(token, account: bridge.tokenAccount)
        }
        persistBridges()
    }

    /// Switch the app to a different paired computer and connect to it.
    func switchTo(_ bridge: SavedBridge) async {
        guard let saved = Keychain.load(account: bridge.tokenAccount), !saved.isEmpty else {
            errorMessage = "No saved token for \(bridge.name) — pair that computer again."
            return
        }
        connected = false
        health = nil
        sessions = []
        baseURLString = bridge.address
        token = saved                  // didSet also refreshes the active Keychain slot
        activeBridgeId = bridge.id
        persistBridges()
        await connect()
    }

    /// Forget a paired computer and drop its stored token.
    func forget(_ bridge: SavedBridge) {
        Keychain.delete(account: bridge.tokenAccount)
        savedBridges.removeAll { $0.id == bridge.id }
        if activeBridgeId == bridge.id {
            // Without this the app stays connected with the credentials still in place,
            // and the next launch's rememberCurrentBridge() silently re-creates the
            // entry — so "Forget" appeared to do nothing.
            activeBridgeId = nil
            connected = false
            health = nil
            sessions = []
            baseURLString = ""
            token = ""
            userDisconnected = true
        }
        persistBridges()
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
        userDisconnected = false     // an explicit Connect re-enables launch auto-reconnect
        connecting = true
        errorMessage = nil
        defer { connecting = false }
        do {
            let h = try await client.health()
            health = h
            sessions = try await client.listSessions()
            connected = true
            rememberCurrentBridge()                                        // keep the paired-computer list current
            lastUsage = try? await client.usage()
            publishWidgetSnapshot()
            if let t = pushToken { try? await client.registerDevice(t) }   // (re)register for push
            if !bootstrapping { Haptics.success() }   // confirm an explicit connect (not silent launch reconnect)
        } catch {
            connected = false
            errorMessage = friendly(error)
        }
    }

    /// On launch, reconnect automatically from saved credentials so the user stays
    /// "logged in" across relaunches and TestFlight updates (token lives in the
    /// Keychain, address in UserDefaults — both survive updates).
    func bootstrap() async {
        guard !connected, client != nil, !userDisconnected else { return }
        bootstrapping = true
        await connect()
        bootstrapping = false
    }

    func reloadSessions() async {
        guard let client else { return }
        do {
            sessions = try await client.listSessions()
            publishWidgetSnapshot()
        }
        catch { errorMessage = friendly(error) }
    }

    /// Push a small status snapshot to the home-screen widget via the app group.
    private func publishWidgetSnapshot() {
        let running = sessions.filter { $0.isRunning }
        let active = running.first ?? sessions.first
        var snapshot = TethrXSnapshot()
        snapshot.computer = health?.host ?? (URL(string: normalizedBase)?.host ?? "")
        snapshot.sessionCount = sessions.count
        snapshot.runningCount = running.count
        snapshot.activeName = active?.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
        snapshot.totalTokens = lastUsage?.totals.totalTokens ?? 0
        snapshot.costUSD = lastUsage?.costUSD ?? 0
        snapshot.updatedAt = Date()
        WidgetBridge.publish(snapshot)
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

    /// Resolve a tool permission straight from a notification action — no session
    /// view involved, so this works even when the app was launched in the background.
    func resolvePermission(sessionId: String, requestId: String, optionId: String) async {
        guard let client else { return }
        try? await client.resolvePermission(sessionId: sessionId, requestId: requestId, optionId: optionId)
    }

    /// Store the APNs token and push it to the bridge (if we're connected).
    func registerDevice(_ token: String) async {
        pushToken = token
        guard let client, connected else { return }
        try? await client.registerDevice(token)
    }

    /// Folders the user created that may not have any sessions in them yet. Merged
    /// with the folders implied by existing sessions.
    @Published var customFolders: [String] = [] {
        didSet { UserDefaults.standard.set(customFolders, forKey: "bridge.folders") }
    }

    /// The order the user dragged folders into. Anything not listed sorts after, A to Z.
    @Published var folderOrder: [String] = [] {
        didSet { UserDefaults.standard.set(folderOrder, forKey: "bridge.folderOrder") }
    }

    /// Every folder name — created-but-empty ones included.
    var folders: [String] {
        let used = sessions.compactMap { $0.folder }.filter { !$0.isEmpty }
        return Array(Set(used).union(customFolders)).sorted()
    }

    /// Folders in the user's chosen order, with any new ones appended alphabetically.
    var orderedFolders: [String] {
        let all = folders
        let known = folderOrder.filter { all.contains($0) }
        let rest = all.filter { !known.contains($0) }.sorted()
        return known + rest
    }

    func createFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        customFolders.append(trimmed)
        folderOrder.append(trimmed)
    }

    /// Move a folder up (-1) or down (+1) in the list.
    func moveFolder(_ name: String, by delta: Int) {
        var order = orderedFolders                 // normalise first, so unordered folders get positions
        guard let from = order.firstIndex(of: name) else { return }
        let to = from + delta
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        folderOrder = order
        Haptics.tap()
    }

    /// Remove a folder; any sessions inside it move back to Ungrouped.
    func deleteFolder(_ name: String) async {
        customFolders.removeAll { $0 == name }
        folderOrder.removeAll { $0 == name }
        for session in sessions where session.folder == name {
            await setFolder(session.id, folder: "")
        }
    }

    /// Pair an additional computer without losing the current one: if the new
    /// credentials don't connect, the previous connection is restored.
    func addComputer(address: String, pairingToken: String) async -> Bool {
        let prevAddress = baseURLString
        let prevToken = token
        baseURLString = address
        token = pairingToken
        await connect()
        if connected { return true }
        // Failed — put the old computer back and reconnect to it.
        baseURLString = prevAddress
        token = prevToken
        await connect()
        return false
    }

    /// Move a session into a folder (or clear it with an empty string).
    func setFolder(_ id: String, folder: String) async {
        guard let client else { return }
        let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.setFolder(id, folder: trimmed)
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].folder = trimmed }
        } catch { errorMessage = friendly(error) }
    }

    func disconnect() {
        connected = false
        health = nil
        sessions = []
        errorMessage = nil
        userDisconnected = true       // stay on the pairing screen next launch, don't auto-reconnect
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
