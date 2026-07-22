import Foundation
import SwiftUI

/// Connection + session-list state. Persists the server address, pairing token,
/// and default working directory to UserDefaults so pairing survives relaunches.
@MainActor
final class AppState: ObservableObject {
    /// The bridge version this app's features are built against. A connected
    /// bridge older than this gets a visible "update your bridge" banner —
    /// otherwise the new buttons would just 404 with no explanation.
    static let wantedBridgeVersion = "0.1.17"
    var bridgeNeedsUpdate: Bool {
        connected && Semver.isOlder(health?.version, than: Self.wantedBridgeVersion)
    }
    @Published var baseURLString: String { didSet { store("bridge.baseURL", baseURLString) } }
    @Published var token: String { didSet { Keychain.save(token) } }
    /// Cert fingerprint for pinned HTTPS to the ACTIVE bridge ("" = plain HTTP).
    /// Not a secret — it's the hash of the certificate every client receives.
    @Published var pin: String { didSet { store("bridge.pin", pin) } }
    /// The plain-HTTP address this computer was reached on before it was upgraded to
    /// pinned HTTPS. Kept so a pinned connection that stops answering — its port taken
    /// by a second bridge, a network that blocks it, a regenerated certificate — can
    /// fall back instead of stranding the app on an address that can never connect.
    @Published var plainBase: String { didSet { store("bridge.plainBase", plainBase) } }
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

    /// Browsing canned data with nothing connected (see DemoMode.swift).
    @Published var demoMode = false

    @Published var health: HealthInfo?
    @Published var sessions: [SessionInfo] = []
    @Published var lastUsage: UsageReport?      // for the home-screen widget
    @Published var connected = false
    @Published var connecting = false
    @Published var bootstrapping = false   // first-launch auto-reconnect in progress
    /// True while switching between paired computers. RootView keeps the normal UI
    /// mounted during it — without this, `connected = false` mid-switch unmounted
    /// everything and flashed the first-run pairing wizard for seconds.
    @Published var switching = false
    @Published var errorMessage: String?

    /// Set by a debug launch argument to auto-open a session (UI testing only).
    @Published var pendingOpenSessionId: String?

    /// Latest APNs device token (from PushManager); re-sent to the bridge on connect.
    var pushToken: String?
    /// ActivityKit push-to-start token — lets the bridge put a Live Activity on the
    /// lock screen with the app closed (iOS 17.2+). Re-sent on connect.
    var laStartToken: String?

    init() {
        let d = UserDefaults.standard
        baseURLString = d.string(forKey: "bridge.baseURL") ?? ""
        pin = d.string(forKey: "bridge.pin") ?? ""
        plainBase = d.string(forKey: "bridge.plainBase") ?? ""
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
        // When a launch auto-reconnect is coming, say so from the very first frame.
        // Defaulting to false flashed the pairing wizard for a beat before
        // bootstrap() flipped it — which read as "the app forgot my computer".
        bootstrapping = !baseURLString.isEmpty && !token.isEmpty && !userDisconnected
        // Existing pairings predate the share extension, so republish on every launch
        // rather than only when the list changes.
        publishToSharedGroup()
    }

    // MARK: Paired computers

    private func persistBridges() {
        if let data = try? JSONEncoder().encode(savedBridges) {
            UserDefaults.standard.set(data, forKey: "bridge.saved")
        }
        UserDefaults.standard.set(activeBridgeId, forKey: "bridge.activeId")
        publishToSharedGroup()
    }

    /// Mirror the paired computers into the App Group, and make sure each token lives
    /// in the shared Keychain group — the share extension is a separate process and
    /// can read neither the app's own defaults nor its private Keychain items.
    private func publishToSharedGroup() {
        SharedConfig.publish(
            bridges: savedBridges.map {
                SharedConfig.Bridge(id: $0.id, name: $0.name, address: $0.address, pin: $0.pin)
            },
            activeId: activeBridgeId)
        // Re-saving is how a token minted before the shared group existed gets moved
        // into it. Idempotent, and cheap for a handful of computers.
        for bridge in savedBridges {
            if let token = Keychain.load(account: bridge.tokenAccount), !token.isEmpty {
                SharedKeychain.save(token, account: bridge.tokenAccount)
            }
        }
    }

    /// After a successful connect, remember this computer (and its token) so it can
    /// be switched back to later. Named from the bridge's reported hostname.
    ///
    /// Matching is by the bridge's own stable serverId first: Tailscale and DHCP
    /// addresses CHANGE, and matching by address alone accreted one dead "computer"
    /// per old IP — same machine, listed twice, one of them unable to connect.
    private func rememberCurrentBridge() {
        let addr = normalizedBase
        guard !addr.isEmpty, !token.isEmpty else { return }
        let serverId = health?.serverId
        let name = (health?.host?.isEmpty == false) ? health!.host! : (URL(string: addr)?.host ?? addr)
        let host = URL(string: addr)?.host
        let index = savedBridges.firstIndex { b in
            if let serverId, b.serverId == serverId { return true }               // same install, any address
            if b.address == addr { return true }
            if let host, URL(string: b.address)?.host == host { return true }     // http→https upgrade
            return false
        }
        if let i = index {
            savedBridges[i].name = name
            savedBridges[i].address = addr
            savedBridges[i].pin = pin.isEmpty ? nil : pin
            savedBridges[i].plainBase = plainBase.isEmpty ? nil : plainBase
            if let serverId { savedBridges[i].serverId = serverId }
            activeBridgeId = savedBridges[i].id
            Keychain.save(token, account: savedBridges[i].tokenAccount)
        } else {
            let bridge = SavedBridge(id: UUID().uuidString, name: name, address: addr,
                                     pin: pin.isEmpty ? nil : pin, serverId: serverId,
                                     plainBase: plainBase.isEmpty ? nil : plainBase)
            savedBridges.append(bridge)
            activeBridgeId = bridge.id
            Keychain.save(token, account: bridge.tokenAccount)
        }
        sweepDuplicateBridges()
        persistBridges()
    }

    /// Collapse older entries that are really the just-connected computer: same
    /// serverId, or (for entries saved before serverIds existed) the same reported
    /// hostname AND address host. Their dead addresses are exactly the "previous
    /// computers that can't connect" the list kept showing after an IP change.
    /// Hostname alone is NOT enough — Apple's default names collide ("MacBook-Pro"),
    /// and sweeping on a name match could delete a different physical machine's
    /// pairing.
    private func sweepDuplicateBridges() {
        guard let activeId = activeBridgeId,
              let current = savedBridges.first(where: { $0.id == activeId }) else { return }
        let currentHost = URL(string: current.address)?.host
        let goners = savedBridges.filter { b in
            guard b.id != current.id else { return false }
            if let sid = current.serverId, b.serverId == sid { return true }
            return b.serverId == nil && b.name == current.name
                && currentHost != nil && URL(string: b.address)?.host == currentHost
        }
        for b in goners { Keychain.delete(account: b.tokenAccount) }
        if !goners.isEmpty {
            let ids = Set(goners.map(\.id))
            savedBridges.removeAll { ids.contains($0.id) }
        }
    }

    /// Switch the app to a different paired computer and connect to it. If that
    /// computer doesn't answer, the previous connection is put back — tapping a
    /// dead entry must not cost you the live one you were on.
    func switchTo(_ bridge: SavedBridge) async {
        guard let saved = Keychain.load(account: bridge.tokenAccount), !saved.isEmpty else {
            errorMessage = String(localized: "No saved token for \(bridge.name) — pair that computer again.")
            return
        }
        let prev = (base: baseURLString, pin: pin, plain: plainBase, token: token,
                    activeId: activeBridgeId, wasConnected: connected)
        switching = true
        defer { switching = false }
        connected = false
        health = nil
        sessions = []
        baseURLString = bridge.address
        pin = bridge.pin ?? ""
        plainBase = bridge.plainBase ?? ""   // each computer keeps its own fallback address
        token = saved                  // didSet also refreshes the active Keychain slot
        activeBridgeId = bridge.id
        persistBridges()
        await connect()
        if !connected && prev.wasConnected && prev.activeId != bridge.id {
            let failure = errorMessage
            baseURLString = prev.base
            pin = prev.pin
            plainBase = prev.plain
            token = prev.token
            activeBridgeId = prev.activeId
            persistBridges()
            await connect()
            // Say "staying on the current computer" only when that's true — if the
            // rollback also failed, its own error is the honest one to keep.
            if connected {
                errorMessage = failure.map { String(localized: "\(bridge.name) didn't answer — staying on the current computer. (\($0))") }
            }
        }
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
            pin = ""
            userDisconnected = true
        }
        persistBridges()
    }

    private func store(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// A ready-to-use client, or nil if not enough info to build one.
    ///
    /// Demo mode deliberately has NO client. Someone who paired a computer earlier and
    /// then taps "Try the demo" still has a valid address and token, so every screen
    /// that reached for a client went and talked to their real machine behind the demo
    /// — search hit real conversations, Settings showed real usage and real computers.
    /// Cutting it off here fixes all of them at once, because every caller already
    /// handles "no client".
    var client: BridgeClient? {
        guard !demoMode else { return nil }
        guard let url = URL(string: normalizedBase), !token.isEmpty, !normalizedBase.isEmpty else { return nil }
        return BridgeClient(config: .init(baseURL: url, token: token, pin: pin.isEmpty ? nil : pin))
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
        // Connecting for real ends the demo. This has to happen BEFORE the client is
        // built, because demo mode deliberately has none.
        if demoMode { exitDemo() }
        guard let client else {
            errorMessage = String(localized: "Enter the bridge address and pairing token.")
            return
        }
        userDisconnected = false     // an explicit Connect re-enables launch auto-reconnect
        connecting = true
        errorMessage = nil
        defer { connecting = false }
        do {
            try await establish(with: client)
        } catch {
            // A pinned HTTPS address that stops answering used to strand the app for
            // good: the upgrade path only runs when there is NO pin, so every later
            // Reconnect retried the same dead port and the only way out was walking
            // the whole setup wizard again. Try the plain-HTTP address instead.
            if await recoverFromDeadPin() { return }
            connected = false
            errorMessage = friendly(error)
        }
    }

    /// One connection attempt against an already-built client. Throws so the caller
    /// can decide whether a failure is recoverable.
    private func establish(with c: BridgeClient) async throws {
        // Short probe: a live bridge replies instantly, and failing fast is what lets
        // the pinned-HTTPS fallback below happen while the user is still watching.
        let h = try await c.health(timeout: 8)
        // The user can flip into the demo (or Forget the computer) while this was
        // awaiting — `client` is nil then, and finishing the connect would fight it.
        guard !demoMode else { throw CancellationError() }
        health = h
        await upgradeToPinnedTLS(from: h)                                   // http → pinned https when offered
        // Re-resolve after the possible upgrade; never force-unwrap a computed
        // property that goes nil the moment credentials are cleared mid-flight.
        guard let live = client else { throw CancellationError() }
        sessions = try await live.listSessions()
        connected = true
        rememberCurrentBridge()                                             // keep the paired-computer list current
        lastUsage = try? await live.usage()
        publishWidgetSnapshot()
        if let t = pushToken { try? await live.registerDevice(t) }          // (re)register for push
        if let t = laStartToken { try? await live.registerLiveActivity(kind: "start-token", token: t) }
        if !bootstrapping { Haptics.success() }   // confirm an explicit connect (not silent launch reconnect)
    }

    /// Pinned HTTPS failed. Drop back to the plain-HTTP address and try again; on
    /// success the upgrade runs afresh, which also re-pins if the bridge minted a new
    /// certificate. Restores the previous address if the fallback is no better.
    private func recoverFromDeadPin() async -> Bool {
        guard !pin.isEmpty else { return false }
        let fallback = plainFallbackAddress()
        guard !fallback.isEmpty, fallback != normalizedBase else { return false }

        let prevBase = baseURLString, prevPin = pin
        baseURLString = fallback
        pin = ""
        guard let plain = client else {
            baseURLString = prevBase; pin = prevPin
            return false
        }
        do {
            try await establish(with: plain)
            return true
        } catch {
            baseURLString = prevBase; pin = prevPin
            return false
        }
    }

    /// Where to fall back to when pinned HTTPS stops working: the address this bridge
    /// was reached on before the upgrade, or failing that the same host one port down
    /// (the TLS listener defaults to the HTTP port + 1).
    private func plainFallbackAddress() -> String {
        if !plainBase.isEmpty { return plainBase }
        guard let url = URL(string: normalizedBase), let host = url.host else { return "" }
        let httpPort = (url.port ?? 4181) - 1
        return "http://\(host):\(httpPort)"
    }

    /// If we're on plain HTTP and the bridge advertises its pinned-HTTPS listener,
    /// switch to it: same host, TLS port, certificate pinned by fingerprint. Rolls
    /// straight back if the TLS port turns out to be unreachable (a firewall, say),
    /// so upgrading can never strand a working connection.
    private func upgradeToPinnedTLS(from h: HealthInfo) async {
        guard pin.isEmpty,
              normalizedBase.lowercased().hasPrefix("http://"),
              let tls = h.tls, !tls.fingerprint.isEmpty,
              let host = URL(string: normalizedBase)?.host else { return }
        let prevBase = baseURLString
        baseURLString = "https://\(host):\(tls.port)"
        pin = tls.fingerprint
        if let upgraded = client, let refreshed = try? await upgraded.health() {
            health = refreshed        // the pinned channel is live — stay on it
            plainBase = prevBase      // remembered, so a dead pin can climb back down
            return
        }
        baseURLString = prevBase
        pin = ""
    }

    /// On launch, reconnect automatically from saved credentials so the user stays
    /// "logged in" across relaunches and TestFlight updates (token lives in the
    /// Keychain, address in UserDefaults — both survive updates).
    func bootstrap() async {
        // Never yank someone out of the demo: the launch reconnect would replace the
        // sample sessions with the real computer's, mid-look.
        guard !demoMode else { bootstrapping = false; return }
        guard !connected, client != nil, !userDisconnected else { bootstrapping = false; return }
        bootstrapping = true
        await connect()
        bootstrapping = false
    }

    // MARK: Demo mode

    func enterDemo() {
        demoMode = true
        health = DemoData.health
        sessions = DemoData.sessions
        Haptics.tap()
    }

    func exitDemo() {
        demoMode = false
        health = nil
        sessions = []
    }

    func reloadSessions() async {
        guard !demoMode else { return }
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
        if demoMode {
            let s = DemoData.freshSession(cwd: defaultCwd)
            sessions.insert(s, at: 0)
            return s
        }
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
        if demoMode { sessions.removeAll { $0.id == id }; return }
        guard let client else { return }
        do {
            try await client.deleteSession(id)
            sessions.removeAll { $0.id == id }
        } catch { errorMessage = friendly(error) }
    }

    func renameSession(_ id: String, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if demoMode {
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].title = trimmed }
            return
        }
        guard let client else { return }
        do {
            try await client.renameSession(id, title: trimmed)
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].title = trimmed }
        } catch { errorMessage = friendly(error) }
    }

    /// A client for any paired computer (not just the active one), using its own
    /// Keychain token slot and pin. Normalizes the stored address the same way the
    /// active one is — legacy entries hold bare "host:port", which URL(string:)
    /// misparses (scheme "host", no host) and would silently skip that computer.
    func client(for bridge: SavedBridge) -> BridgeClient? {
        guard let saved = Keychain.load(account: bridge.tokenAccount), !saved.isEmpty else { return nil }
        var addr = bridge.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !addr.contains("://") { addr = "http://" + addr }
        while addr.hasSuffix("/") { addr.removeLast() }
        guard let url = URL(string: addr), url.host != nil else { return nil }
        return BridgeClient(config: .init(baseURL: url, token: saved, pin: bridge.pin))
    }

    /// Resolve a tool permission straight from a notification action — no session
    /// view involved, so this works even when the app was launched in the background.
    ///
    /// The push may have come from a computer that ISN'T the active one (you can be
    /// paired to several). Sending the decision only to the active bridge meant a
    /// 404 that was silently swallowed — the button "worked" and grok stayed blocked
    /// forever. Try the active computer first, then every other paired one.
    func resolvePermission(sessionId: String, requestId: String, optionId: String) async {
        if let client, (try? await client.resolvePermission(sessionId: sessionId, requestId: requestId, optionId: optionId)) != nil {
            return
        }
        for bridge in savedBridges where bridge.id != activeBridgeId {
            guard let other = client(for: bridge) else { continue }
            if (try? await other.resolvePermission(sessionId: sessionId, requestId: requestId, optionId: optionId)) != nil {
                return
            }
        }
    }

    /// A reply typed into a notification. Queued on the bridge, which runs it when the
    /// turn ends (or immediately, when nothing is running) — so the app never has to
    /// open. Fans out across paired computers for the same reason approvals do: the
    /// session might not belong to whichever computer happens to be active.
    func queueReply(sessionId: String, text: String) async {
        if let client, (try? await client.enqueue(sessionId: sessionId, text: text, source: "reply")) != nil {
            await reloadSessions()
            return
        }
        for bridge in savedBridges where bridge.id != activeBridgeId {
            guard let other = client(for: bridge) else { continue }
            if (try? await other.enqueue(sessionId: sessionId, text: text, source: "reply")) != nil { return }
        }
    }

    /// Tapping a notification should open its session — even when that session lives
    /// on a different paired computer. Probe the other computers; if one has it,
    /// switch there (the session list then opens it via `pendingOpenSessionId`).
    private var locatingSessionId: String?
    func locateAndOpen(_ id: String) async {
        guard locatingSessionId != id else { return }
        locatingSessionId = id
        defer { locatingSessionId = nil }
        guard !sessions.contains(where: { $0.id == id }) else { return }   // it's local after all
        for bridge in savedBridges where bridge.id != activeBridgeId {
            guard let other = client(for: bridge),
                  let list = try? await other.listSessions(),
                  list.contains(where: { $0.id == id }) else { continue }
            await switchTo(bridge)   // reachability was just proven by listSessions
            return
        }
        // Nowhere to be found (deleted, or its computer is offline). Clear it so it
        // can't fire as a surprise navigation after some later manual switch.
        if pendingOpenSessionId == id { pendingOpenSessionId = nil }
    }

    /// Store the APNs token and push it to the bridge (if we're connected).
    func registerDevice(_ token: String) async {
        pushToken = token
        guard let client, connected else { return }
        try? await client.registerDevice(token)
    }

    /// Store an ActivityKit push-to-start token and forward it (if connected).
    func registerLiveActivityStart(_ token: String) async {
        laStartToken = token
        guard let client, connected else { return }
        try? await client.registerLiveActivity(kind: "start-token", token: token)
    }

    /// Register the update token of a (possibly push-started) activity for its session.
    func registerLiveActivityUpdate(sessionId: String, token: String) async {
        guard !sessionId.isEmpty, let client else { return }
        try? await client.registerLiveActivity(kind: "update-token", token: token, sessionId: sessionId)
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
    func addComputer(address: String, pairingToken: String, pin newPin: String = "") async -> Bool {
        let prev = (base: baseURLString, pin: pin, plain: plainBase, token: token)
        switching = true               // keep the UI mounted while we probe
        defer { switching = false }
        baseURLString = address
        token = pairingToken
        pin = newPin
        plainBase = ""                 // a fresh computer has no fallback address yet
        await connect()
        if connected { return true }
        // Failed — put the old computer back and reconnect to it. The reconnect
        // clears errorMessage, so hold on to the REAL reason (wrong token reads
        // very differently from unreachable) and put it back for the sheet.
        let failure = errorMessage
        baseURLString = prev.base
        token = prev.token
        pin = prev.pin
        plainBase = prev.plain
        await connect()
        errorMessage = failure
        return false
    }

    /// Move a session into a folder (or clear it with an empty string).
    func setFolder(_ id: String, folder: String) async {
        if demoMode {
            let t = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].folder = t }
            return
        }
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
        if args.contains("-demo") {
            enterDemo()
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
                return String(localized: "Can't reach the bridge. Check the address and that the daemon is running.")
            default:
                return urlErr.localizedDescription
            }
        }
        return (error as? BridgeError)?.errorDescription ?? error.localizedDescription
    }
}
