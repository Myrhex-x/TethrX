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
    @AppStorage(Appearance.storageKey) private var appearanceRaw = Appearance.fallback.rawValue
    @AppStorage(ReadingSize.storageKey) private var readingRaw = ReadingSize.fallback.rawValue

    /// Settings used to be eleven blocks in one scroll, every one of them expanded,
    /// every one of them carrying a paragraph of explanation: about fifteen hundred
    /// points of grey text with no way in. A subject per page, and an index that
    /// tells you what is behind each one.
    enum SettingsPage: String, Hashable {
        case computers, usage, plugins, defaults, schedules, prompts
        case notifications, watch, appearance, language, security, about

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
            case .appearance:    return "Appearance"
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
        case .schedules:     SchedulesSection()
        case .prompts:       snippetsSection
        case .notifications: notifications
        case .watch:         appleWatch
        case .appearance:    appearanceSection
        case .language:      languageSection
        case .security:      security
        case .about:         about
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            // Native grouped lists, the way the system's own Settings is built: the
            // rows, separators, toggles and pickers people already know how to use.
            List { index }
                .listStyle(.insetGrouped)
                .listSectionSpacing(.compact)
                .navigationDestination(for: SettingsPage.self) { page in
                    List { body(of: page) }
                        .listStyle(.insetGrouped)
                        .listSectionSpacing(.compact)
                        .navigationTitle(page.title)
                        .navigationBarTitleDisplayMode(.inline)
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
            // Switching computers happens inside this very sheet. Without this the
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
            .sheet(isPresented: $showingLog) {
                if let client = app.client { BridgeLogSheet(client: client) }
            }
            .sheet(isPresented: $showingUsageHistory) {
                if let client = app.client { UsageHistorySheet(client: client) }
            }
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .grokScheme()
    }

    /// What is in Settings, and what each thing currently says. A row that reads
    /// "Language · Italiano" answers the question without being opened at all, which
    /// is most of what an index is for.
    @ViewBuilder private var index: some View {
        if app.demoMode {
            // Anything that needs a real computer is left out entirely rather than
            // shown empty or, worse, filled from the machine this phone happens to
            // still be paired with.
            Section {
                demoConnection
            } header: {
                ListSectionLabel("Connection")
            } footer: {
                Text("You're looking at sample data. Nothing here reaches a real computer, and nothing you type is sent anywhere.")
            }
            Section {
                indexRow(.defaults, "slider.horizontal.3")
                indexRow(.prompts, "text.badge.star", value: promptCountLabel)
                indexRow(.appearance, "circle.lefthalf.filled", value: appearanceLabel)
                indexRow(.language, "globe", value: language.currentLabel)
                indexRow(.security, "lock")
                indexRow(.about, "info.circle")
            }
        } else {
            Section { computerCard }
            Section {
                indexRow(.computers, "desktopcomputer", value: computerCountLabel)
                indexRow(.usage, "chart.bar")
                indexRow(.plugins, "puzzlepiece.extension")
            } header: {
                ListSectionLabel("Your computer")
            }
            Section {
                indexRow(.defaults, "slider.horizontal.3")
                indexRow(.schedules, "clock.arrow.2.circlepath")
                indexRow(.prompts, "text.badge.star", value: promptCountLabel)
            } header: {
                ListSectionLabel("Sessions")
            }
            Section {
                indexRow(.notifications, "bell", value: String(loc: push.enabled ? "On" : "Off"))
                indexRow(.watch, "applewatch", value: watchShortLabel)
                indexRow(.appearance, "circle.lefthalf.filled", value: appearanceLabel)
                indexRow(.language, "globe", value: language.currentLabel)
                indexRow(.security, "lock", value: String(loc: lock.enabled ? "On" : "Off"))
            } header: {
                ListSectionLabel("This phone")
            }
            Section { indexRow(.about, "info.circle") }
        }
    }



    private func indexRow(_ page: SettingsPage, _ icon: String, value: String? = nil) -> some View {
        Button { path.append(page) } label: {
            HStack(spacing: 12) {
                RowIcon(system: icon)
                Text(page.title).font(.body).foregroundStyle(Grok.text)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 10)
                if let value {
                    Text(verbatim: value)
                        .font(.body).foregroundStyle(Grok.textDim)
                        .lineLimit(1).truncationMode(.middle)
                }
                RowChevron()
            }
            .contentShape(Rectangle())
        }
    }

    /// The computer this phone is pointed at, at the top where the question "which
    /// machine am I about to change" gets answered before anything else.
    private var computerCard: some View {
        Button { path.append(.computers) } label: {
            HStack(spacing: 14) {
                RowIcon(system: app.connected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark",
                        tint: Color(uiColor: app.connected ? .systemGray : .systemGray3), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: hostLabel)
                        .font(.title3.weight(.semibold)).foregroundStyle(Grok.text)
                        .lineLimit(1).truncationMode(.middle)
                    (app.connected ? Text("Connected") : Text("Not connected"))
                        .font(.subheadline).foregroundStyle(Grok.textDim)
                }
                Spacer(minLength: 8)
                RowChevron()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
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

    private var appearance: Appearance { Appearance(rawValue: appearanceRaw) ?? .fallback }
    private var readingSize: ReadingSize { ReadingSize(rawValue: readingRaw) ?? .fallback }
    private var appearanceLabel: String { appearance.label }

    /// Light, dark or pure black, and how big a conversation reads. Each choice is
    /// drawn as what it looks like, because "Dark" and "Black" are words that only
    /// mean something side by side.
    @ViewBuilder private var appearanceSection: some View {
        Section {
            HStack(spacing: 10) {
                ForEach(Appearance.allCases) { option in
                    AppearanceSwatch(option: option, selected: option == appearance) {
                        Haptics.select()
                        withAnimation(.easeInOut(duration: 0.25)) { appearanceRaw = option.rawValue }
                    }
                }
            }
            .padding(.vertical, 6)
        } header: {
            ListSectionLabel("Theme")
        } footer: {
            Text(appearance.detail)
        }

        Section {
            Picker(selection: $readingRaw) {
                ForEach(ReadingSize.allCases) { size in size.title.tag(size.rawValue) }
            } label: {
                Text("Conversation text")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // What a reply will look like at this size, in the reply's own face,
            // measure and line spacing.
            Text("Done. The settings screen now has a dark mode toggle that persists across launches, and every screen follows it.")
                .font(Grok.sans(17 * readingSize.scale))
                .lineSpacing(ReadingSize.lineSpacing(for: 17 * readingSize.scale))
                .foregroundStyle(Grok.text)
                .padding(.vertical, 4)
                .animation(.easeInOut(duration: 0.2), value: readingRaw)
        } header: {
            ListSectionLabel("Conversation text")
        } footer: {
            Text("Applies to replies, your messages and Grok's thinking. Your iPhone's Text Size setting still applies on top.")
        }
    }

    /// Choosing the app's language without leaving the app.
    private var languageSection: some View {
        Section {
            languageRow(nil, label: String(loc: "System"))
            ForEach(AppLanguage.available, id: \.code) { choice in
                languageRow(choice.code, label: choice.label)
            }
        } footer: {
            Text("TethrX picks up the language of your iPhone. Choose another one here and it changes straight away, in this app only.")
        }
    }

    private func languageRow(_ code: String?, label: String) -> some View {
        let target = code ?? ""
        let selected = language.code == target
        return Button {
            Haptics.select()
            // Changing language rebuilds every screen so each string is looked up
            // again, which used to close this sheet under your finger. Ask for it
            // back, on this page.
            app.reopenSettingsPage = SettingsPage.language.rawValue
            language.set(target)
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: label).font(.body).foregroundStyle(Grok.text)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The demo has no computer behind it, and someone who paired one earlier still
    /// has a real address and token sitting in this screen — including a reveal
    /// button. None of that belongs in a demo, so it is replaced wholesale.
    @ViewBuilder private var demoConnection: some View {
        row("Computer", DemoData.health.host ?? "demo")
        row("Mode", String(loc: "Tour: nothing is connected"))
        Button { dismiss(); app.exitDemo() } label: { Text("Exit the tour") }
    }

    @ViewBuilder private var connection: some View {
        Section {
            row("Bridge", app.normalizedBase.isEmpty ? "·" : app.normalizedBase)
            LabeledContent {
                HStack(spacing: 5) {
                    Image(systemName: pinned ? "lock.fill" : "lock.open")
                        .font(.footnote.weight(.semibold))
                    (pinned ? Text("HTTPS · certificate pinned") : Text("HTTP"))
                }
            } label: {
                Text("Security")
            }
            LabeledContent {
                HStack(spacing: 4) {
                    Text(revealToken ? app.token : String(repeating: "•", count: min(max(app.token.count, 1), 18)))
                        .lineLimit(1).truncationMode(.middle)
                    Button { revealToken.toggle() } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                            .frame(width: 36, height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text(revealToken ? "Hide token" : "Reveal token"))
                }
            } label: {
                Text("Token")
            }
            if app.client != nil {
                Button { showingLog = true } label: {
                    Label("View bridge log", systemImage: "text.alignleft")
                }
            }
        } header: {
            ListSectionLabel("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The bridge is the small helper program running on your computer. This phone talks only to it, never to a cloud.")
                if !pinned {
                    Text("Update the bridge (npm i -g tethrx-bridge) and reconnect. The app upgrades to pinned HTTPS automatically.")
                }
            }
        }
        Section {
            Button(role: .destructive) { dismiss(); app.disconnect() } label: { Text("Disconnect") }
        }
    }

    @ViewBuilder private var usage: some View {
        Section {
            if let r = report {
                row("Total tokens", Fmt.tokens(r.totals.totalTokens))
                row("Input", Fmt.tokens(r.totals.inputTokens))
                row("Output", Fmt.tokens(r.totals.outputTokens))
                row("Thinking", Fmt.tokens(r.totals.reasoningTokens))
                row("Cached read", Fmt.tokens(r.totals.cachedReadTokens))
                row("Turns", "\(r.totals.turns)")
                row("Sessions", "\(r.sessionCount)")
                row("Est. cost", Fmt.cost(r.costUSD))
            } else if loadingUsage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(Grok.textDim)
                }
                .accessibilityElement(children: .combine)
            } else if app.connected {
                // Connected but the call failed: saying "connect to the bridge" here
                // sent people debugging a connection that was fine.
                Text("Couldn't load usage. Tap refresh to retry.").foregroundStyle(Grok.textDim)
            } else {
                Text("Connect to the bridge to see usage.").foregroundStyle(Grok.textDim)
            }
        } footer: {
            Text("Totals across every session on this computer. Cost is grok's own estimate, not billing data from your account.")
        }
        if app.client != nil {
            Section {
                Button { showingUsageHistory = true } label: {
                    Label("Day by day", systemImage: "chart.bar")
                }
                Button { Task { await loadUsage() } } label: {
                    Label("Refresh usage", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    @ViewBuilder private var defaults: some View {
        Section {
            Picker(selection: Binding(get: { effectiveEffort }, set: { app.defaultEffort = $0 })) {
                ForEach(Array(efforts.enumerated()), id: \.offset) { _, pair in
                    Text(pair.0).tag(pair.1)
                }
            } label: {
                Text("Reasoning effort")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            ListSectionLabel("Reasoning effort")
        } footer: {
            Text("Higher thinks longer and costs more tokens. High is Grok's default.")
        }
        if let catalog = app.modelCatalog {
            Section {
                modelRow(nil, catalog: catalog)
                ForEach(catalog.models) { m in modelRow(m, catalog: catalog) }
            } header: {
                ListSectionLabel("Model")
            } footer: {
                Text("The models Grok Build offers on this computer. Change it per session with the model chip in the message box.")
            }
        }
        Section {
            toggleRow("Plan mode", "Grok drafts a plan for you to approve before touching anything", $app.defaultPlanMode)
            toggleRow("Auto-approve tools", "Run commands and edits without asking each time: faster, less oversight", $app.defaultAutoApprove)
        } footer: {
            Text("How every new session starts. Nothing here is locked in. The same controls sit inside the message box in every session.")
        }
    }

    /// One model, or grok's own choice (`nil`), as a row with a tick.
    private func modelRow(_ model: GrokModel?, catalog: GrokModelCatalog) -> some View {
        let selected = (model?.id ?? "") == app.defaultModel
        return Button {
            Haptics.select()
            app.defaultModel = model?.id ?? ""
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let model {
                        Text(verbatim: model.id).font(.body).foregroundStyle(Grok.text)
                        if let ctx = model.contextTokens {
                            Text("\(Fmt.tokens(ctx)) context").font(.footnote).foregroundStyle(Grok.textDim)
                        }
                    } else {
                        Text("Grok's default").font(.body).foregroundStyle(Grok.text)
                        if let current = catalog.current {
                            Text(verbatim: current).font(.footnote).foregroundStyle(Grok.textDim)
                        }
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Says plainly whether the watch app is there and what it can do, so "is this
    /// even installed?" is answered in the app rather than by hunting on the wrist.
    @ViewBuilder private var appleWatch: some View {
        Section {
            HStack(spacing: 12) {
                RowIcon(system: watch.active ? "applewatch" : "applewatch.slash",
                        tint: Color(uiColor: watch.active ? .systemGray : .systemGray3))
                VStack(alignment: .leading, spacing: 2) {
                    watchStatusLabel.font(.body).foregroundStyle(Grok.text)
                    // iOS calls a watch reachable only while the app is open on it,
                    // so "Out of range" was shown for a watch sitting on the wrist.
                    // Say what actually happens instead: live while open, delivered
                    // in the background otherwise.
                    if watch.active {
                        (watch.reachable ? Text("The watch app is open")
                                         : Text("Updates arrive in the background"))
                            .font(.footnote).foregroundStyle(Grok.textDim)
                    }
                }
                Spacer(minLength: 0)
            }
            if watch.active {
                LabeledContent("Last sent") {
                    if let sent = watch.lastDelivered {
                        Text(verbatim: Fmt.ago(sent))
                    } else {
                        Text("Nothing sent yet")
                    }
                }
            }
        } footer: {
            watchExplanation
        }
        if watch.active {
            Section {
                // The one thing worth being able to do by hand. Out of range, iOS holds
                // the context and delivers it when the watch comes back.
                Button { watch.republish() } label: {
                    Label("Send the sessions again", systemImage: "arrow.clockwise")
                }
            }
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
        Section {
            // A device with no biometry gets its own whole sentence: "Require %@"
            // translates verb-first in half the languages, so a bare noun in the
            // slot came out ungrammatical.
            toggleRow(lock.biometryName.isEmpty ? "Require a passcode" : "Require \(lock.biometryName)",
                      "Lock the app on open: it can run commands on your computer", $lock.enabled)
        }
    }

    @ViewBuilder private var computers: some View {
        Section {
            if app.savedBridges.isEmpty {
                Text("Computers you pair show up here.").foregroundStyle(Grok.textDim)
            } else {
                ForEach(app.savedBridges) { bridge in
                    computerRow(bridge)
                }
            }
            Button { addingComputer = true } label: {
                Label("Add another computer", systemImage: "plus.circle")
            }
            .task(id: app.savedBridges.map(\.id)) { await probeComputers() }
        } header: {
            HStack(spacing: 8) {
                ListSectionLabel("Computers")
                if probingComputers {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel(Text("Checking which computers answer"))
                }
            }
        } footer: {
            if !app.savedBridges.isEmpty { Text("Tap to switch computers.") }
        }
    }

    private func computerRow(_ bridge: SavedBridge) -> some View {
        let isActive = bridge.id == app.activeBridgeId
        let reachable = computerReachability[bridge.id]
        return HStack(spacing: 10) {
            Button {
                Task { await app.switchTo(bridge) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isActive ? Color.accentColor : Color(uiColor: .tertiaryLabel))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bridge.name).font(.body).foregroundStyle(Grok.text).lineLimit(1)
                        HStack(spacing: 5) {
                            if let reachable {
                                // Filled against faint, not green against grey: the
                                // canvas is monochrome and the one tinted ink is
                                // reserved for errors.
                                Circle().fill(reachable ? Grok.text : Color(uiColor: .tertiaryLabel))
                                    .frame(width: 6, height: 6)
                                    .accessibilityHidden(true)
                            }
                            Text(statusLine(bridge, reachable: reachable))
                                .font(.footnote).foregroundStyle(Grok.textDim)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(app.switching)
            .accessibilityLabel(Text(rowA11y(bridge, isActive: isActive, reachable: reachable)))
            .accessibilityHint(Text("Switches to this computer"))

            Button { forgetting = bridge } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(Grok.textDim)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
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
            Section {
                if let plugins, plugins.isEmpty {
                    Text("No plugins installed. Their skills appear in the \u{201C}/\u{201D} menu once you add some.")
                        .foregroundStyle(Grok.textDim)
                } else if let plugins {
                    ForEach(plugins) { plugin in pluginRow(plugin) }
                } else if pluginsFailed {
                    Text("Couldn't load plugins. Check that grok is installed on the computer.")
                        .foregroundStyle(Grok.textDim)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(Grok.textDim)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let pluginError {
                    Text(pluginError).foregroundStyle(Grok.danger)
                }
            }
            Section {
                HStack(spacing: 8) {
                    TextField("", text: $installSource,
                              prompt: Text("git URL or owner/repo…"))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button { Task { await installPlugin() } } label: {
                        if pluginBusy == "install" {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(installDisabled || pluginBusy != nil)
                    .accessibilityLabel(Text("Install plugin"))
                }
                .task(id: pluginsReloadKey) { await loadPlugins() }
            } footer: {
                Text("Plugins bundle skills, agents, and tools for Grok, and can run code on your computer when Grok uses them. Install only sources you trust. Browse the marketplace with /plugins in the Grok terminal.")
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.body).foregroundStyle(plugin.isDisabled ? Grok.textDim : Grok.text)
                        .lineLimit(1)
                    if let v = plugin.version, !v.isEmpty {
                        Text("v\(v)").font(.footnote).foregroundStyle(Grok.textDim)
                    }
                }
                if let d = plugin.description, !d.isEmpty {
                    Text(d).font(.footnote).foregroundStyle(Grok.textDim).lineLimit(2)
                }
                if !plugin.sourceLabel.isEmpty {
                    Text(plugin.sourceLabel).font(.caption).foregroundStyle(Grok.textDim)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if pluginBusy == plugin.name {
                ProgressView().controlSize(.small)
            } else {
                Toggle(plugin.name, isOn: Binding(
                    get: { !plugin.isDisabled },
                    set: { on in Task { await pluginAction(on ? "enable" : "disable", plugin.name) } }
                )).labelsHidden()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { removingPlugin = plugin } label: {
                Label("Remove plugin", systemImage: "trash")
            }
        }
        .contextMenu {
            Button(role: .destructive) { removingPlugin = plugin } label: {
                Label("Remove plugin", systemImage: "trash")
            }
        }
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
        Section {
            toggleRow("Push notifications",
                      "Get alerted when Grok finishes a turn or needs approval, even with the app closed",
                      Binding(get: { push.enabled }, set: { $0 ? push.enable() : push.disable() }))
        } footer: {
            Text("Requires an APNs key configured on your bridge. Delivered to this phone when it isn't actively watching a session.")
        }
    }

    private var snippetsSection: some View {
        Section {
            Button { showingLibrary = true } label: {
                HStack(spacing: 12) {
                    RowIcon(system: "text.alignleft")
                    Text("Prompt library").font(.body).foregroundStyle(Grok.text)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(snippets.items.count)").font(.body).foregroundStyle(Grok.textDim)
                    RowChevron()
                }
                .contentShape(Rectangle())
            }
        } footer: {
            Text("Reusable prompts you write on this phone. They need no computer, and appear above the composer in every session.")
        }
    }

    private var about: some View {
        Section {
            row("App", "TethrX \(appVersion)")
                .task(id: app.connected) { await loadGrokUpdate() }
            row("Grok", app.health?.grok?.replacingOccurrences(of: "grok ", with: "") ?? "·")
            grokUpdateRows
            if let v = app.health?.version, !v.isEmpty {
                row("Bridge", bridgeOutdated ? String(loc: "v\(v) · update available") : "v\(v)")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if bridgeOutdated {
                    Text("On your computer: npm i -g tethrx-bridge, then restart the bridge.")
                }
                Text("A client for Grok Build · independent, not affiliated with xAI.")
            }
        }
    }

    /// Grok's own updates, managed from the phone. The bridge keeps grok current on
    /// its own (unless disabled on the computer); this shows state + a manual path.
    @ViewBuilder private var grokUpdateRows: some View {
        if let u = grokUpdate, u.updateAvailable, let latest = u.latest {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grok \(latest) is out").font(.body).foregroundStyle(Grok.text)
                    if u.autoUpdate == true {
                        Text("The bridge also installs this on its own once no session is running.")
                            .font(.footnote).foregroundStyle(Grok.textDim)
                    }
                }
                Spacer()
                Button {
                    Task { await installGrokUpdate() }
                } label: {
                    HStack(spacing: 6) {
                        if grokUpdating { ProgressView().controlSize(.mini).tint(Grok.onInk) }
                        (grokUpdating ? Text("Updating…") : Text("Update now"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(grokUpdating)
                .accessibilityLabel(Text("Update Grok to \(latest)"))
            }
        }
        if let note = grokUpdateNote {
            Text(note).font(.footnote).foregroundStyle(Grok.textDim)
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
        LabeledContent {
            Text(value).lineLimit(1).truncationMode(.middle)
        } label: {
            Text(key)
        }
    }

    /// The system switch, with its explanation under the title the way Settings
    /// writes it. The label names the switch for VoiceOver.
    private func toggleRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Grok.text)
                Text(subtitle).font(.footnote).foregroundStyle(Grok.textDim)
            }
        }
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
