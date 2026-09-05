import SwiftUI

/// App settings: connection info, defaults for new sessions, and about.
struct SettingsView: View {
    /// Section to scroll to on open, matching the `.id` on that section.
    var anchor: String? = nil

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
    @State private var showingLibrary = false
    @State private var computerReachability: [String: Bool] = [:]
    @State private var probingComputers = false
    @State private var forgetting: SavedBridge?
    @State private var grokUpdate: GrokUpdateStatus?
    @State private var grokUpdating = false
    @State private var grokUpdateNote: String?
    @State private var plugins: [GrokPlugin]?
    @State private var pluginsSupported = true     // false = bridge too old; hide the section
    @State private var pluginsFailed = false
    @State private var pluginBusy: String?         // name (or "install") of the in-flight action
    @State private var pluginError: String?
    @State private var installSource = ""
    @State private var removingPlugin: GrokPlugin?
    @ObservedObject private var watch = WatchLink.shared
    @EnvironmentObject private var language: AppLanguage
    @State private var path: [SettingsPage] = []

    /// Settings used to be eleven blocks in one scroll, every one of them expanded,
    /// every one of them carrying a paragraph of explanation: about fifteen hundred
    /// points of grey text with no way in. A subject per page, and an index that
    /// tells you what is behind each one.
    enum SettingsPage: String, Hashable {
        case computers, usage, plugins, defaults, schedules, prompts
        case notifications, watch, language, security, about

        var title: LocalizedStringKey {
            switch self {
            case .computers:     return "Computers"
            case .usage:         return "Usage"
            case .plugins:       return "Grok plugins"
            case .defaults:      return "New session defaults"
            case .schedules:     return "Schedules"
            case .prompts:       return "Prompts"
            case .notifications: return "Notifications"
            case .watch:         return "Apple Watch"
            case .language:      return "Language"
            case .security:      return "Security"
            case .about:         return "About"
            }
        }
    }

    @ViewBuilder private func body(of page: SettingsPage) -> some View {
        switch page {
        case .computers:     connection; computers
        case .usage:         usage
        case .plugins:       pluginsSection
        case .defaults:      defaults
        case .schedules:     SchedulesSection(showsHeading: false)
        case .prompts:       snippetsSection
        case .notifications: notifications
        case .watch:         appleWatch
        case .language:      languageSection
        case .security:      security
        case .about:         about
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                index
                    .padding(.horizontal, Grok.gutter).padding(.vertical, 20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .navigationDestination(for: SettingsPage.self) { page in
                ScrollView {
                    VStack(alignment: .leading, spacing: Grok.groupGap) {
                        body(of: page)
                    }
                    .padding(.horizontal, Grok.gutter).padding(.vertical, 20)
                }
                .background(Grok.bg)
                .scrollIndicators(.hidden)
                .navigationTitle(page.title)
                .navigationBarTitleDisplayMode(.inline)
                .grokBar()
            }
            .task {
                #if DEBUG
                // Headless screenshots: `-settingsAnchor plugins` opens on that page.
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-settingsAnchor"), i + 1 < args.count,
                   let page = SettingsPage(rawValue: args[i + 1]) {
                    path.append(page)
                }
                #endif
                // The home screen's computer row opens this sheet already on the
                // Computers page, which is two taps fewer than landing on the index
                // and hunting for it.
                if let anchor, let page = SettingsPage(rawValue: anchor) { path.append(page) }
            }
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
            .sheet(isPresented: $showingLibrary) {
                PromptLibraryView().environmentObject(snippets)
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

    /// What is in Settings, and what each thing currently says. A row that reads
    /// "Language · Italiano" answers the question without being opened at all, which
    /// is most of what an index is for.
    private var index: some View {
        VStack(alignment: .leading, spacing: Grok.groupGap) {
            if app.demoMode {
                // Anything that needs a real computer is left out entirely rather
                // than shown empty or, worse, filled from the machine this phone
                // happens to still be paired with.
                demoConnection
                indexGroup(nil) {
                    indexRow(.defaults, "slider.horizontal.3")
                    indexRow(.prompts, "text.badge.star", value: promptCountLabel)
                    indexRow(.language, "globe", value: language.currentLabel)
                    indexRow(.security, "lock")
                    indexRow(.about, "info.circle")
                }
            } else {
                computerCard
                indexGroup("Your computer") {
                    indexRow(.computers, "desktopcomputer", value: computerCountLabel)
                    indexRow(.usage, "chart.bar")
                    indexRow(.plugins, "puzzlepiece.extension")
                }
                indexGroup("Sessions") {
                    indexRow(.defaults, "slider.horizontal.3")
                    indexRow(.schedules, "clock.arrow.2.circlepath")
                    indexRow(.prompts, "text.badge.star", value: promptCountLabel)
                }
                indexGroup("This phone") {
                    indexRow(.notifications, "bell", value: push.enabled ? "On" : "Off")
                    indexRow(.watch, "applewatch", value: watchShortLabel)
                    indexRow(.language, "globe", value: language.currentLabel)
                    indexRow(.security, "lock", value: lock.enabled ? "On" : "Off")
                }
                indexGroup(nil) { indexRow(.about, "info.circle") }
            }
        }
    }

    @ViewBuilder private func indexGroup<C: View>(_ title: LocalizedStringKey?,
                                                 @ViewBuilder _ rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title { ListSectionLabel(title).padding(.bottom, 2) }
            rows()
        }
    }

    private func indexRow(_ page: SettingsPage, _ icon: String, value: String? = nil) -> some View {
        Button { Haptics.tap(); path.append(page) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Grok.textDim)
                    // One fixed column, so the labels start at the same x however
                    // wide their glyphs happen to be.
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(page.title).font(Grok.sans(16, .medium)).foregroundStyle(Grok.text)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 10)
                if let value {
                    Text(verbatim: value)
                        .font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Grok.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The computer this phone is pointed at, at the top where the question "which
    /// machine am I about to change" gets answered before anything else.
    private var computerCard: some View {
        Button { Haptics.tap(); path.append(.computers) } label: {
            HStack(spacing: 12) {
                Image(systemName: app.connected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.system(size: 20))
                    .foregroundStyle(app.connected ? Grok.text : Grok.textFaint)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: hostLabel)
                        .font(Grok.sans(17, .semibold)).foregroundStyle(Grok.text)
                        .lineLimit(1).truncationMode(.middle)
                    (app.connected ? Text("Connected") : Text("Not connected"))
                        .font(Grok.sans(13)).foregroundStyle(Grok.textDim)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Grok.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Grok.pad).padding(.vertical, 14)
            .background(Grok.raised)
            .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A Mac reports its Bonjour name, so the host arrives as "Name-MacBook.local";
    /// the suffix is the one part of it that says nothing about which computer it is.
    private var hostLabel: String {
        let host = (app.health?.host ?? "")
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: ".home", with: "")
        return host.isEmpty ? String(loc: "No computer") : host
    }
    private var computerCountLabel: String? {
        app.savedBridges.count > 1 ? "\(app.savedBridges.count)" : nil
    }
    private var promptCountLabel: String? {
        snippets.items.isEmpty ? nil : "\(snippets.items.count)"
    }
    private var watchShortLabel: String? {
        watch.active ? String(loc: "Installed") : nil
    }

    /// Choosing the app's language without leaving the app.
    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TethrX picks up the language of your iPhone. Choose another one here and it changes straight away, in this app only.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textDim).lineSpacing(2)
            VStack(alignment: .leading, spacing: 0) {
                languageRow(nil, label: String(loc: "System"))
                ForEach(AppLanguage.available, id: \.code) { choice in
                    languageRow(choice.code, label: choice.label)
                }
            }
        }
    }

    private func languageRow(_ code: String?, label: String) -> some View {
        let target = code ?? ""
        let selected = language.code == target
        return Button {
            Haptics.tap()
            language.set(target)
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: label)
                    .font(Grok.sans(16)).foregroundStyle(Grok.text)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Grok.text)
                }
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The demo has no computer behind it, and someone who paired one earlier still
    /// has a real address and token sitting in this screen — including a reveal
    /// button. None of that belongs in a demo, so it is replaced wholesale.
    private var demoConnection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ListSectionLabel("Connection")
            row("Computer", DemoData.health.host ?? "demo")
            row("Mode", String(loc: "Tour: nothing is connected"))
            Text("You're looking at sample data. Nothing here reaches a real computer, and nothing you type is sent anywhere.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textDim).lineSpacing(2)
            Button { dismiss(); app.exitDemo() } label: {
                Text("Exit the tour").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButton(kind: .subtle))
            .padding(.top, 4)
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The bridge is the small helper program running on your computer. This phone talks only to it, never to a cloud.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textDim).lineSpacing(2)
            row("Bridge", app.normalizedBase.isEmpty ? "·" : app.normalizedBase)
            HStack {
                Text("Security").font(Grok.sans(15)).foregroundStyle(Grok.textDim)
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: pinned ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .semibold))
                    (pinned ? Text("HTTPS · certificate pinned") : Text("HTTP"))
                }
                .font(Grok.sans(15)).foregroundStyle(pinned ? Grok.text : Grok.textDim)
            }
            if !pinned {
                Text("Update the bridge (npm i -g tethrx-bridge) and reconnect. The app upgrades to pinned HTTPS automatically.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
            }
            HStack {
                Text("Token").font(Grok.sans(15)).foregroundStyle(Grok.textDim)
                Spacer()
                Text(revealToken ? app.token : String(repeating: "•", count: min(max(app.token.count, 1), 18)))
                    .font(Grok.sans(15)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
                Button { revealToken.toggle() } label: {
                    Image(systemName: revealToken ? "eye.slash" : "eye").font(.caption)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
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
                Spacer()
                Button { Task { await loadUsage() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
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
                    Text("Loading…").font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                }
                .accessibilityElement(children: .combine)
            } else if app.connected {
                // Connected but the call failed — saying "connect to the bridge"
                // here sent people debugging a connection that was fine.
                Text("Couldn't load usage. Tap refresh to retry.")
                    .font(Grok.sans(14)).foregroundStyle(Grok.textDim)
            } else {
                Text("Connect to the bridge to see usage.").font(Grok.sans(14)).foregroundStyle(Grok.textDim)
            }

            if app.client != nil {
                Button { showingUsageHistory = true } label: {
                    Label("Day by day", systemImage: "chart.bar")
                }
                .buttonStyle(PillButton(kind: .subtle))
                .padding(.top, 2)
            }

            Text("Totals across every session on this computer. Cost is grok's own estimate, not billing data from your account.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
        }
        .sheet(isPresented: $showingUsageHistory) {
            if let client = app.client { UsageHistorySheet(client: client) }
        }
    }

    private var defaults: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How every new session starts. Nothing here is locked in. The same controls sit inside the message box in every session.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textDim).lineSpacing(2)
            VStack(alignment: .leading, spacing: 8) {
                Text("Reasoning effort").font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                Text("Higher thinks longer and costs more tokens. High is Grok's default.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
                HStack(spacing: 8) {
                    ForEach(Array(efforts.enumerated()), id: \.offset) { _, pair in
                        // No font here: a font on the Text itself beats the one
                        // SegPill sets, and the selected pill loses its weight step.
                        Button { app.defaultEffort = pair.1 } label: { Text(pair.0) }
                            .buttonStyle(SegPill(selected: effectiveEffort == pair.1))
                    }
                    Spacer(minLength: 0)
                }
            }
            toggleRow("Plan mode", "Grok drafts a plan for you to approve before touching anything", $app.defaultPlanMode)
            toggleRow("Auto-approve tools", "Run commands and edits without asking each time: faster, less oversight", $app.defaultAutoApprove)
        }
    }

    /// Says plainly whether the watch app is there and what it can do, so "is this
    /// even installed?" is answered in the app rather than by hunting on the wrist.
    private var appleWatch: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: watch.active ? "applewatch" : "applewatch.slash")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(watch.active ? Grok.text : Grok.textFaint)
                    .accessibilityHidden(true)
                watchStatusLabel
                    .font(Grok.sans(15)).foregroundStyle(Grok.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Grok.pad).padding(.vertical, 13)
            .background(Grok.raised)
            .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
            .accessibilityElement(children: .combine)

            watchExplanation
                .font(Grok.sans(14)).foregroundStyle(Grok.textFaint).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var watchStatusLabel: some View {
        if watch.active { Text("Installed") }
        else if watch.paired { Text("Not installed") }
        else { Text("No Apple Watch paired") }
    }

    @ViewBuilder private var watchExplanation: some View {
        if watch.active {
            Text("Answer approvals, read the last few lines and dictate a follow-up from your wrist. The watch asks this phone, so your pairing token never leaves it.")
        } else if watch.paired {
            Text("Install TethrX on your Apple Watch from the Watch app on this iPhone to answer approvals from your wrist.")
        } else {
            Text("Pair an Apple Watch with this iPhone, then install TethrX on it to answer approvals from your wrist.")
        }
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A device with no biometry gets its own whole sentence: "Require %@"
            // translates verb-first in half the languages, so a bare noun in the
            // slot came out ungrammatical.
            toggleRow(lock.biometryName.isEmpty ? "Require a passcode" : "Require \(lock.biometryName)",
                      "Lock the app on open: it can run commands on your computer", $lock.enabled)
        }
    }

    private var computers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if probingComputers {
                    ProgressView().controlSize(.mini).tint(Grok.textFaint)
                        .accessibilityLabel(Text("Checking which computers answer"))
                }
                Spacer()
            }
            if app.savedBridges.isEmpty {
                Text("Computers you pair show up here.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textDim)
            } else {
                ForEach(app.savedBridges) { bridge in
                    computerRow(bridge)
                }
                Text("Tap to switch computers.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
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
                        Text(bridge.name).font(Grok.sans(15)).foregroundStyle(Grok.text).lineLimit(1)
                        HStack(spacing: 5) {
                            if let reachable {
                                // Filled against faint, not green against grey: the
                                // canvas is monochrome and the one tinted ink is
                                // reserved for errors.
                                Circle().fill(reachable ? Grok.text : Grok.textFaint)
                                    .frame(width: 5, height: 5)
                                    .accessibilityHidden(true)
                            }
                            Text(statusLine(bridge, reachable: reachable))
                                .font(Grok.sans(13))
                                .foregroundStyle(reachable == false ? Grok.textDim : Grok.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                // Two lines of text come to 36pt; the row is already 44 tall next to
                // the trash button, so this only widens the target, never the row.
                .frame(minHeight: 44)
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
            // A button is named by what it does, not by the question the dialog it
            // opens will ask. The computer's name moves to the value.
            .accessibilityLabel(Text("Forget this computer"))
            .accessibilityValue(Text(bridge.name))
        }
        .contextMenu {
            Button(role: .destructive) { forgetting = bridge } label: {
                Label("Forget", systemImage: "trash")
            }
        }
    }

    private func statusLine(_ bridge: SavedBridge, reachable: Bool?) -> String {
        guard let reachable else { return bridge.address }
        return reachable ? bridge.address : String(loc: "not answering · \(bridge.address)")
    }

    /// VoiceOver name for a computer row, from localized pieces.
    private func rowA11y(_ bridge: SavedBridge, isActive: Bool, reachable: Bool?) -> String {
        var parts = [bridge.name]
        if isActive { parts.append(String(loc: "active")) }
        if reachable == true { parts.append(String(loc: "online")) }
        if reachable == false { parts.append(String(loc: "not answering")) }
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

    /// Manage grok's plugins from the phone. Their skills join the "/" palette on
    /// their own once installed — this section only lists, toggles, and installs.
    @ViewBuilder private var pluginsSection: some View {
        if pluginsSupported {
            VStack(alignment: .leading, spacing: 12) {
                if let plugins, plugins.isEmpty {
                    Text("No plugins installed. Their skills appear in the \u{201C}/\u{201D} menu once you add some.")
                        .font(Grok.sans(13)).foregroundStyle(Grok.textDim).lineSpacing(2)
                } else if let plugins {
                    ForEach(plugins) { plugin in pluginRow(plugin) }
                } else if pluginsFailed {
                    Text("Couldn't load plugins. Check that grok is installed on the computer.")
                        .font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("Loading…").font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let pluginError {
                    Text(pluginError).font(Grok.sans(14)).foregroundStyle(Grok.danger).lineSpacing(2)
                }
                HStack(spacing: 8) {
                    FieldBox {
                        TextField("", text: $installSource,
                                  prompt: Text("git URL or owner/repo…").foregroundColor(Grok.textFaint))
                            .font(Grok.sans(15)).foregroundStyle(Grok.text)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    Button { Task { await installPlugin() } } label: {
                        if pluginBusy == "install" {
                            ProgressView().controlSize(.small).tint(.white)
                                .frame(width: 44, height: 44)
                        } else {
                            Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(installDisabled ? Grok.textFaint : Grok.text)
                    .disabled(installDisabled || pluginBusy != nil)
                    .accessibilityLabel(Text("Install plugin"))
                }
                Text("Plugins bundle skills, agents, and tools for Grok, and can run code on your computer when Grok uses them. Install only sources you trust. Browse the marketplace with /plugins in the Grok terminal.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
            }
            .task(id: pluginsReloadKey) { await loadPlugins() }
            .confirmationDialog(
                Text("Remove \(removingPlugin?.name ?? "")?"),
                isPresented: Binding(get: { removingPlugin != nil }, set: { if !$0 { removingPlugin = nil } }),
                titleVisibility: .visible
            ) {
                Button("Remove plugin", role: .destructive) {
                    if let p = removingPlugin { Task { await pluginAction("uninstall", p.name) } }
                    removingPlugin = nil
                }
                Button("Cancel", role: .cancel) { removingPlugin = nil }
            } message: {
                Text("Uninstalls it from the computer. Its skills disappear from new sessions.")
            }
        }
    }

    private var installDisabled: Bool {
        installSource.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Reload when the computer changes *and* when the connection comes back: keyed
    /// on the computer alone, a load that failed while disconnected stayed failed.
    private var pluginsReloadKey: String { "\(app.activeBridgeId ?? "-")|\(app.connected)" }

    private func pluginRow(_ plugin: GrokPlugin) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(Grok.sans(15)).foregroundStyle(plugin.isDisabled ? Grok.textDim : Grok.text)
                        .lineLimit(1)
                    if let v = plugin.version, !v.isEmpty {
                        Text("v\(v)").font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
                    }
                }
                if let d = plugin.description, !d.isEmpty {
                    Text(d).font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineLimit(2)
                }
                if !plugin.sourceLabel.isEmpty {
                    Text(plugin.sourceLabel).font(Grok.sans(11)).foregroundStyle(Grok.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if pluginBusy == plugin.name {
                ProgressView().controlSize(.small).tint(.white).padding(.top, 6)
            } else {
                Toggle(plugin.name, isOn: Binding(
                    get: { !plugin.isDisabled },
                    set: { on in Task { await pluginAction(on ? "enable" : "disable", plugin.name) } }
                )).labelsHidden().tint(.white)
                Button { removingPlugin = plugin } label: {
                    Image(systemName: "trash").font(.system(size: 12))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Grok.textDim)
                .padding(.top, -6)
                .accessibilityLabel(Text("Remove plugin"))
                .accessibilityValue(Text(plugin.name))
            }
        }
        .padding(.horizontal, Grok.pad).padding(.vertical, 13)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
    }

    private func loadPlugins() async {
        // A reconnect blip lands here with no client. Returning quietly left
        // `plugins` nil with no failure recorded, and the section spun forever.
        guard let client = app.client, app.connected else {
            if plugins == nil { pluginsFailed = true }
            return
        }
        do {
            plugins = try await client.grokPlugins()
            pluginsFailed = false
            pluginsSupported = true
        } catch {
            // A 404 means the bridge predates plugins — hide rather than nag; the
            // update banner already covers "your bridge is old".
            if case .badStatus(404) = (error as? BridgeError) ?? .badURL { pluginsSupported = false }
            else if plugins == nil { pluginsFailed = true }
        }
    }

    private func pluginAction(_ action: String, _ name: String) async {
        guard let client = app.client else { return }
        pluginBusy = name
        pluginError = nil
        defer { pluginBusy = nil }
        do { plugins = try await client.grokPluginAction(action, name: name) }
        catch { pluginError = String(loc: "That didn't go through. Check the bridge log for details.") }
    }

    private func installPlugin() async {
        guard let client = app.client else { return }
        let source = installSource.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return }
        pluginBusy = "install"
        pluginError = nil
        defer { pluginBusy = nil }
        do {
            plugins = try await client.grokPluginAction("install", source: source)
            installSource = ""
            Haptics.success()
        } catch {
            pluginError = String(loc: "Install failed. Check the URL and that the computer can reach it.")
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow("Push notifications",
                      "Get alerted when Grok finishes a turn or needs approval, even with the app closed",
                      Binding(get: { push.enabled }, set: { $0 ? push.enable() : push.disable() }))
            Text("Requires an APNs key configured on your bridge. Delivered to this phone when it isn't actively watching a session.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
        }
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reusable prompts you write on this phone. They need no computer, and appear above the composer in every session.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
            Button { showingLibrary = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.alignleft").font(.system(size: 12)).foregroundStyle(Grok.textDim)
                    Text("Prompt library").font(Grok.sans(15)).foregroundStyle(Grok.text)
                    Spacer(minLength: 8)
                    Text("\(snippets.items.count)").font(Grok.sans(15)).foregroundStyle(Grok.textDim)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Grok.textFaint)
                }
                .padding(.horizontal, Grok.pad).padding(.vertical, 13)
                .background(Grok.raised)
                .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous).stroke(Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("App", "TethrX \(appVersion)")
            row("Grok", app.health?.grok?.replacingOccurrences(of: "grok ", with: "") ?? "·")
            grokUpdateRows
            if let v = app.health?.version, !v.isEmpty {
                row("Bridge", bridgeOutdated ? String(loc: "v\(v) · update available") : "v\(v)")
            }
            if bridgeOutdated {
                Text("On your computer: npm i -g tethrx-bridge, then restart the bridge.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
            }
            Text("A client for Grok Build · independent, not affiliated with xAI.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
        }
        .task(id: app.connected) { await loadGrokUpdate() }
    }

    /// Grok's own updates, managed from the phone. The bridge keeps grok current on
    /// its own (unless disabled on the computer); this shows state + a manual path.
    @ViewBuilder private var grokUpdateRows: some View {
        if let u = grokUpdate, u.updateAvailable, let latest = u.latest {
            HStack(spacing: 10) {
                Text("Grok \(latest) is out").font(Grok.sans(14)).foregroundStyle(Grok.text)
                Spacer()
                Button {
                    Task { await installGrokUpdate() }
                } label: {
                    HStack(spacing: 6) {
                        if grokUpdating { ProgressView().controlSize(.mini).tint(.black) }
                        (grokUpdating ? Text("Updating…") : Text("Update now")).font(Grok.sans(14, .semibold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 12)
                    .background(Capsule().fill(Color.white))
                    .foregroundStyle(.black)
                    // The capsule itself is shorter than a finger; the plain style
                    // hands over exactly the shape it is given, so ask for 44.
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(grokUpdating)
                .accessibilityLabel(Text("Update Grok to \(latest)"))
            }
            if u.autoUpdate == true {
                Text("The bridge also installs this on its own once no session is running.")
                    .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
            }
        }
        if let note = grokUpdateNote {
            Text(note).font(Grok.sans(13)).foregroundStyle(Grok.textDim)
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
                ? String(loc: "Updated.")
                : String(loc: "Updated to \(version).")
            grokUpdate = try? await client.grokUpdateStatus()
        } catch {
            grokUpdateNote = (error as? BridgeError)?.errorDescription
                ?? String(loc: "Update didn't finish. Try again when no session is running.")
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
            Text(key).font(Grok.sans(15)).foregroundStyle(Grok.textDim)
            Spacer()
            Text(value).font(Grok.sans(15)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
        }
    }

    private func toggleRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Grok.sans(15)).foregroundStyle(Grok.text)
                Text(subtitle).font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
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

    // No "Auto": grok has three efforts and omitting the flag simply runs high, so
    // the option promised adaptive behaviour while quietly picking the dearest one.
    private var efforts: [(LocalizedStringKey, String)] { [("High", "high"), ("Med", "medium"), ("Low", "low")] }
    /// Sessions set up before "Auto" went away still store "", which is high.
    private var effectiveEffort: String { app.defaultEffort.isEmpty ? "high" : app.defaultEffort }
    private var appVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "" }
}
