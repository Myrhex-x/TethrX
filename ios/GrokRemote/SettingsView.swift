import SwiftUI

/// App settings: connection info, defaults for new sessions, and about.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var snippets: SnippetStore
    @ObservedObject private var push = PushManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var revealToken = false
    @State private var addingComputer = false
    @State private var showingLog = false
    @State private var report: UsageReport?
    @State private var loadingUsage = false
    @State private var showingUsageHistory = false
    @State private var newSnippet = ""
    @State private var computerReachability: [String: Bool] = [:]
    @State private var probingComputers = false
    @State private var forgetting: SavedBridge?
    @State private var grokUpdate: GrokUpdateStatus?
    @State private var grokUpdating = false
    @State private var grokUpdateNote: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if app.demoMode {
                        // Anything that needs a real computer is left out entirely
                        // rather than shown empty or, worse, filled from the machine
                        // this phone happens to still be paired with.
                        demoConnection
                        defaults
                        security
                        snippetsSection
                        about
                    } else {
                        connection
                        computers
                        usage
                        defaults
                        SchedulesSection()
                        notifications
                        security
                        snippetsSection
                        about
                    }
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .task { await loadUsage() }
            // Switching computers happens inside this very sheet — without this the
            // usage panel kept showing the PREVIOUS computer's totals.
            .onChange(of: app.activeBridgeId) { _, _ in
                report = nil
                Task { await loadUsage() }
            }
            .sheet(isPresented: $addingComputer) {
                AddComputerSheet().environmentObject(app)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The demo has no computer behind it, and someone who paired one earlier still
    /// has a real address and token sitting in this screen — including a reveal
    /// button. None of that belongs in a demo, so it is replaced wholesale.
    private var demoConnection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("CONNECTION")
            row("Computer", DemoData.health.host ?? "demo")
            row("Mode", String(localized: "Demo — nothing is connected"))
            Text("You're looking at sample data. Nothing here reaches a real computer, and nothing you type is sent anywhere.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textDim).lineSpacing(2)
            Button { dismiss(); app.exitDemo() } label: {
                Text("Exit demo").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButton(kind: .subtle))
            .padding(.top, 4)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("CONNECTION")
            row("Bridge", app.normalizedBase.isEmpty ? "—" : app.normalizedBase)
            HStack {
                Text("Security").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: pinned ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .semibold))
                    Text(pinned ? "HTTPS · certificate pinned" : "HTTP")
                }
                .font(Grok.mono(12)).foregroundStyle(pinned ? Grok.text : Grok.textDim)
            }
            if !pinned {
                Text("Update the bridge (npm i -g tethrx-bridge) and reconnect — the app upgrades to pinned HTTPS automatically.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
            }
            HStack {
                Text("Token").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                Spacer()
                Text(revealToken ? app.token : String(repeating: "•", count: min(max(app.token.count, 1), 18)))
                    .font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
                Button { revealToken.toggle() } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye").font(.caption)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .foregroundStyle(Grok.textDim)
                .accessibilityLabel(Text(revealToken ? "Hide token" : "Reveal token"))
            }
            if app.client != nil {
                Button { showingLog = true } label: {
                    Label("View bridge log", systemImage: "text.alignleft")
                }
                .buttonStyle(PillButton(kind: .subtle))
                .padding(.top, 4)
            }
            Button { dismiss(); app.disconnect() } label: { Text("Disconnect").frame(maxWidth: .infinity) }
                .buttonStyle(PillButton(kind: .subtle))
                .padding(.top, 4)
        }
        .sheet(isPresented: $showingLog) {
            if let client = app.client { BridgeLogSheet(client: client) }
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("USAGE")
                Spacer()
                Button { Task { await loadUsage() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .foregroundStyle(Grok.textDim)
                .accessibilityLabel(Text("Refresh usage"))
            }

            if let r = report {
                row("Total tokens", Fmt.tokens(r.totals.totalTokens))
                row("Input", Fmt.tokens(r.totals.inputTokens))
                row("Output", Fmt.tokens(r.totals.outputTokens))
                row("Thinking", Fmt.tokens(r.totals.reasoningTokens))
                row("Cached read", Fmt.tokens(r.totals.cachedReadTokens))
                Rectangle().fill(Grok.hairline).frame(height: 1).padding(.vertical, 2)
                row("Turns", "\(r.totals.turns)")
                row("Sessions", "\(r.sessionCount)")
                row("Est. cost", Fmt.cost(r.costUSD))
            } else if loadingUsage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Loading…").font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                }
                .accessibilityElement(children: .combine)
            } else if app.connected {
                // Connected but the call failed — saying "connect to the bridge"
                // here sent people debugging a connection that was fine.
                Text("Couldn't load usage — tap refresh to retry.")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
            } else {
                Text("Connect to the bridge to see usage.").font(Grok.mono(11)).foregroundStyle(Grok.textDim)
            }

            if app.client != nil {
                Button { showingUsageHistory = true } label: {
                    Label("Day by day", systemImage: "chart.bar")
                }
                .buttonStyle(PillButton(kind: .subtle))
                .padding(.top, 2)
            }

            Text("Totals across every session on this computer. Cost is grok's own estimate, not billing data from your account.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
        }
        .sheet(isPresented: $showingUsageHistory) {
            if let client = app.client { UsageHistorySheet(client: client) }
        }
    }

    private var defaults: some View {
        VStack(alignment: .leading, spacing: 16) {
            Eyebrow("NEW SESSION DEFAULTS")
            VStack(alignment: .leading, spacing: 8) {
                Text("Reasoning effort").font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                HStack(spacing: 8) {
                    ForEach(Array(efforts.enumerated()), id: \.offset) { _, pair in
                        Button { app.defaultEffort = pair.1 } label: { Text(pair.0).font(Grok.mono(12, .medium)) }
                            .buttonStyle(SegPill(selected: app.defaultEffort == pair.1))
                    }
                    Spacer(minLength: 0)
                }
            }
            toggleRow("Plan mode", "Grok drafts a plan to approve first", $app.defaultPlanMode)
            toggleRow("Auto-approve tools", "Skip the approve/reject prompt", $app.defaultAutoApprove)
            Text("Each session can override these from its own controls.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("SECURITY")
            toggleRow("Require \(lock.biometryName)", "Lock the app on open — it can run commands on your computer", $lock.enabled)
        }
    }

    private var computers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Eyebrow("COMPUTERS")
                if probingComputers {
                    ProgressView().controlSize(.mini).tint(Grok.textFaint)
                        .accessibilityLabel(Text("Checking which computers answer"))
                }
                Spacer()
            }
            if app.savedBridges.isEmpty {
                Text("Computers you pair show up here.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textDim)
            } else {
                ForEach(app.savedBridges) { bridge in
                    computerRow(bridge)
                }
                Text("Tap to switch computers.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
            Button { Haptics.tap(); addingComputer = true } label: {
                Label("Add another computer", systemImage: "plus.circle")
            }
            .buttonStyle(PillButton(kind: .subtle))
        }
        .task(id: app.savedBridges.map(\.id)) { await probeComputers() }
        .confirmationDialog(
            Text("Forget \(forgetting?.name ?? "")?"),
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget this computer", role: .destructive) {
                if let b = forgetting { app.forget(b) }
                forgetting = nil
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("Removes it from this phone and drops its pairing token. Pair again anytime from the computer's QR code.")
        }
    }

    private func computerRow(_ bridge: SavedBridge) -> some View {
        let isActive = bridge.id == app.activeBridgeId
        let reachable = computerReachability[bridge.id]
        return HStack(spacing: 10) {
            Button {
                Haptics.tap()
                Task { await app.switchTo(bridge) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isActive ? Grok.accent : Grok.textFaint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bridge.name).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1)
                        HStack(spacing: 5) {
                            if let reachable {
                                Circle().fill(reachable ? Color.green.opacity(0.85) : Grok.textFaint)
                                    .frame(width: 5, height: 5)
                                    .accessibilityHidden(true)
                            }
                            Text(statusLine(bridge, reachable: reachable))
                                .font(Grok.mono(10))
                                .foregroundStyle(reachable == false ? Grok.textDim : Grok.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(rowA11y(bridge, isActive: isActive, reachable: reachable)))
            .accessibilityHint(Text("Switches to this computer"))

            Button { forgetting = bridge } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Grok.textDim)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Forget \(bridge.name)?"))   // same key as the dialog title
        }
        .contextMenu {
            Button(role: .destructive) { forgetting = bridge } label: {
                Label("Forget", systemImage: "trash")
            }
        }
    }

    private func statusLine(_ bridge: SavedBridge, reachable: Bool?) -> String {
        guard let reachable else { return bridge.address }
        return reachable ? bridge.address : String(localized: "not answering · \(bridge.address)")
    }

    /// VoiceOver name for a computer row, from localized pieces.
    private func rowA11y(_ bridge: SavedBridge, isActive: Bool, reachable: Bool?) -> String {
        var parts = [bridge.name]
        if isActive { parts.append(String(localized: "active")) }
        if reachable == true { parts.append(String(localized: "online")) }
        if reachable == false { parts.append(String(localized: "not answering")) }
        return parts.joined(separator: ", ")
    }

    /// Ping every saved computer (4s cap each, in parallel) so dead entries are
    /// visibly dead instead of failing only after you tap them.
    private func probeComputers() async {
        guard !app.savedBridges.isEmpty, !app.demoMode else { return }
        probingComputers = true
        defer { probingComputers = false }
        await withTaskGroup(of: (String, Bool).self) { group in
            for bridge in app.savedBridges {
                group.addTask { @MainActor in
                    guard let client = app.client(for: bridge) else { return (bridge.id, false) }
                    let ok = (try? await client.health(timeout: 4)) != nil
                    return (bridge.id, ok)
                }
            }
            for await (id, ok) in group { computerReachability[id] = ok }
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("NOTIFICATIONS")
            toggleRow("Push notifications",
                      "Get alerted when Grok finishes a turn or needs approval — even with the app closed",
                      Binding(get: { push.enabled }, set: { $0 ? push.enable() : push.disable() }))
            Text("Requires an APNs key configured on your bridge. Delivered to this phone when it isn't actively watching a session.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
        }
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("PROMPT SNIPPETS")
            Text("Reusable prompts you can tap to send from a session.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            ForEach(Array(snippets.items.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    Text(s).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(2)
                    Spacer(minLength: 8)
                    Button { snippets.remove(at: IndexSet(integer: i)) } label: {
                        Image(systemName: "minus.circle").font(.caption)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .foregroundStyle(Grok.textDim)
                    .accessibilityLabel(Text("Remove snippet"))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Grok.raised)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                FieldBox {
                    TextField("", text: $newSnippet, prompt: Text("add a snippet…").foregroundColor(Grok.textFaint), axis: .vertical)
                        .font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1...3)
                }
                Button { snippets.add(newSnippet); newSnippet = "" } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(newSnippet.trimmingCharacters(in: .whitespaces).isEmpty ? Grok.textFaint : Grok.text)
                .disabled(newSnippet.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel(Text("Add snippet"))
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("ABOUT")
            row("App", "TethrX \(appVersion)")
            row("Grok", app.health?.grok?.replacingOccurrences(of: "grok ", with: "") ?? "—")
            grokUpdateRows
            if let v = app.health?.version, !v.isEmpty {
                row("Bridge", "v\(v)" + (bridgeOutdated ? " · update available" : ""))
            }
            if bridgeOutdated {
                Text("On your computer: npm i -g tethrx-bridge, then restart the bridge.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
            Text("A client for Grok Build · independent, not affiliated with xAI.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
        }
        .task(id: app.connected) { await loadGrokUpdate() }
    }

    /// Grok's own updates, managed from the phone. The bridge keeps grok current on
    /// its own (unless disabled on the computer); this shows state + a manual path.
    @ViewBuilder private var grokUpdateRows: some View {
        if let u = grokUpdate, u.updateAvailable, let latest = u.latest {
            HStack(spacing: 10) {
                Text("Grok \(latest) is out").font(Grok.mono(11)).foregroundStyle(Grok.text)
                Spacer()
                Button {
                    Task { await installGrokUpdate() }
                } label: {
                    HStack(spacing: 6) {
                        if grokUpdating { ProgressView().controlSize(.mini).tint(.black) }
                        Text(grokUpdating ? "Updating…" : "Update now").font(Grok.mono(11, .semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white))
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(grokUpdating)
                .accessibilityLabel(Text("Update Grok to \(latest)"))
            }
            if u.autoUpdate == true {
                Text("The bridge also installs this on its own once no session is running.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
        }
        if let note = grokUpdateNote {
            Text(note).font(Grok.mono(10)).foregroundStyle(Grok.textDim)
        }
    }

    private func loadGrokUpdate() async {
        guard let client = app.client, app.connected else { grokUpdate = nil; return }
        grokUpdate = try? await client.grokUpdateStatus()
    }

    private func installGrokUpdate() async {
        guard let client = app.client else { return }
        grokUpdating = true
        grokUpdateNote = nil
        defer { grokUpdating = false }
        do {
            let version = try await client.grokUpdateInstall()
            Haptics.success()
            grokUpdateNote = version.isEmpty
                ? String(localized: "Updated.")
                : String(localized: "Updated — now \(version).")
            grokUpdate = try? await client.grokUpdateStatus()
        } catch {
            grokUpdateNote = (error as? BridgeError)?.errorDescription
                ?? String(localized: "Update didn't finish — try again when no session is running.")
        }
    }

    private var pinned: Bool { !app.pin.isEmpty && app.normalizedBase.lowercased().hasPrefix("https") }

    /// Numeric semver compare, so a dev build "ahead" of npm doesn't nag.
    private var bridgeOutdated: Bool {
        guard let cur = app.health?.version?.split(separator: ".").compactMap({ Int($0) }),
              let latest = app.health?.latestVersion?.split(separator: ".").compactMap({ Int($0) }),
              cur.count == 3, latest.count == 3 else { return false }
        for i in 0..<3 where latest[i] != cur[i] { return latest[i] > cur[i] }
        return false
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(key).font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            Spacer()
            Text(value).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Grok.mono(12)).foregroundStyle(Grok.text)
                Text(subtitle).font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
            }
            Spacer()
            // The title inside the Toggle (visually hidden) is what names the switch
            // for VoiceOver — a bare `Toggle("")` announces just "switch".
            Toggle(title, isOn: binding).labelsHidden().tint(.white)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadUsage() async {
        guard let client = app.client else { return }
        loadingUsage = true
        defer { loadingUsage = false }
        report = try? await client.usage()
    }

    private var efforts: [(LocalizedStringKey, String)] { [("Auto", ""), ("High", "high"), ("Med", "medium"), ("Low", "low")] }
    private var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
}
