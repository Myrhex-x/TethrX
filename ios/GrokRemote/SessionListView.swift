import SwiftUI

/// Lists the bridge's Grok sessions and starts new ones. Tapping opens live chat.
/// With `onSelect` set (the iPad sidebar), taps report the choice to the split
/// view instead of pushing onto this view's own stack.
struct SessionListView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var snippets: SnippetStore
    var onSelect: ((SessionInfo) -> Void)? = nil
    @State private var path: [SessionInfo] = []
    @State private var creating = false
    @State private var pickingCwd = false
    @State private var renaming: SessionInfo?
    @State private var renameText = ""
    @State private var foldering: SessionInfo?   // session being moved into a new folder
    @State private var folderText = ""
    @State private var collapsed: Set<String> = []
    @State private var query = ""
    @State private var contentHits: [SearchResult] = []   // full-text matches from the bridge
    @State private var showSettings = false
    /// Which section Settings should open on. The header goes to the computers; the
    /// gear in the bar goes to the top.
    @State private var settingsAnchor: String?
    @State private var showSchedules = false
    @State private var showPrompts = false
    @State private var showUsage = false
    @FocusState private var searchFocused: Bool
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var deletingSession: SessionInfo?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            // A native grouped list, the way Mail, Notes and Settings are built: rows
            // in cards, the system's own highlight on a tap, swipe actions, and the
            // radius and spacing of whichever iOS it runs on.
            List {
                Section { accountHeader }
                if app.demoMode { Section { demoBanner } }
                if let err = app.errorMessage, !app.demoMode { Section { errorBanner(err) } }
                if app.health?.grokSignedIn == false, !app.demoMode { Section { signedOutBanner } }
                if app.bridgeNeedsUpdate { Section { updateBanner } }
                // What the app can do, then what you have been doing. Searching,
                // starting and configuring live in the bar at the bottom, where a
                // thumb is, so the top of the screen is content.
                //
                // Except when Grok is blocked on an answer. Four menu rows are
                // exactly enough to push that card off the bottom of the screen,
                // and the card is the reason the app exists.
                if somethingNeedsYou {
                    needsYou
                    if !searching { destinations }
                } else {
                    if !searching { destinations }
                    needsYou
                }
                sessions
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(.compact)
            // The first keystroke in Search takes four rows away; animated, the list
            // settles instead of jumping under the finger.
            .animation(.snappy(duration: 0.28), value: searching)
            .navigationTitle(Text("Sessions"))
            .navigationBarTitleDisplayMode(.large)
            .softScrollEdge(.bottom)
            .floatingBottomBar { bottomBar }
            .refreshable { await app.reloadSessions() }
            .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let s = renaming { Task { await app.renameSession(s.id, title: renameText) } }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("New folder", isPresented: Binding(get: { foldering != nil }, set: { if !$0 { foldering = nil } })) {
                TextField("Folder name", text: $folderText)
                Button("Move") {
                    if let s = foldering, !folderText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await app.setFolder(s.id, folder: folderText) }
                    }
                    foldering = nil
                }
                Button("Cancel", role: .cancel) { foldering = nil }
            }
            .alert("New folder", isPresented: $creatingFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") { app.createFolder(newFolderName); newFolderName = "" }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            } message: {
                Text("Then use the ••• button on any session to move it in.")
            }
            // One tap in a small menu permanently deletes the conversation on the
            // computer — that deserves the same confirmation Forget and Discard get.
            .confirmationDialog(
                Text("Delete \u{201C}\(deletingSession?.displayName ?? "")\u{201D}?"),
                isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete session", role: .destructive) {
                    if let s = deletingSession { Task { await app.deleteSession(s.id) } }
                    deletingSession = nil
                }
                Button("Cancel", role: .cancel) { deletingSession = nil }
            } message: {
                Text("Removes its conversation from the computer too. This cannot be undone.")
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(anchor: settingsAnchor)
                    .environmentObject(app).environmentObject(lock).environmentObject(snippets)
            }
            .sheet(isPresented: $showSchedules) { SchedulesSheet().environmentObject(app) }
            .sheet(isPresented: $showPrompts) { PromptLibraryView().environmentObject(snippets) }
            .sheet(isPresented: $showUsage) {
                if let client = app.client { UsageHistorySheet(client: client) }
            }
            .sheet(isPresented: $pickingCwd) {
                DirectoryPickerSheet().environmentObject(app)
            }
            .navigationDestination(for: SessionInfo.self) { session in
                if app.demoMode {
                    ChatView(vm: ChatViewModel(demoSession: session))
                } else if let client = app.client {
                    ChatView(vm: ChatViewModel(client: client, session: session))
                } else {
                    ZStack { Grok.bg.ignoresSafeArea(); ListSectionLabel("Disconnected") }
                }
            }
        }
        .task {
            #if DEBUG
            // Headless screenshots: `-openSettings` jumps straight to the sheet, and
            // `-search <text>` opens with the list already filtered, which is the one
            // state of this screen that needs a keyboard to reach.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-openSettings") { showSettings = true }
            if let i = args.firstIndex(of: "-search"), i + 1 < args.count { query = args[i + 1] }
            #endif
            // Back from a rebuild (a language change): Settings returns, on the page
            // it was on, without sliding up again.
            if let page = app.reopenSettingsPage {
                app.reopenSettingsPage = nil
                settingsAnchor = page
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { showSettings = true }
            }
            await app.reloadSessions(); openPending()
        }
        // The list used to be a snapshot from whenever it last appeared: a session
        // that started, finished, or blocked on an approval while you were looking
        // straight at it said nothing until you pulled to refresh. Poll while it is
        // on screen — briskly when something is in flight, sparingly when nothing is.
        .task(id: scenePhase) {
            guard scenePhase == .active, !app.demoMode else { return }
            while !Task.isCancelled {
                let busy = app.sessions.contains { $0.isRunning || $0.isWaitingOnYou }
                try? await Task.sleep(nanoseconds: busy ? 4_000_000_000 : 20_000_000_000)
                guard !Task.isCancelled else { return }
                // A chat on top of this one has its own live stream; two pollers on
                // the same bridge is just cellular data for nothing.
                guard path.isEmpty, app.client != nil, !app.switching else { continue }
                await app.reloadSessions(quiet: true)
                // Signed out is the one health fact that changes under you, and the
                // banner should clear once `grok login` has been run over there.
                if app.health?.grokSignedIn == false { await app.refreshHealth() }
            }
        }
        // Backing out of a session that was created by the compose button and never
        // written in: it goes, rather than sitting at the top of the list forever.
        .onChange(of: path) { _, now in
            guard let id = app.unusedSessionId, !now.contains(where: { $0.id == id }) else { return }
            Task { await app.discardUnusedSession() }
        }
        .onChange(of: app.pendingOpenSessionId) { _, _ in openPending() }
        // The whole array, not just its count: switching to another computer can
        // land on the same number of sessions, which would swallow the deep-open.
        .onChange(of: app.sessions) { _, _ in openPending() }
        // A chat left open across a computer switch kept its old view model, still
        // streaming from the previous computer (which then held back its alerts).
        .onChange(of: app.activeBridgeId) { _, _ in path = [] }
        // Debounced full-text search over conversation history (bridge-side).
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3, let client = app.client else { contentHits = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            contentHits = (try? await client.search(q)) ?? []
        }
    }

    /// Open the session a notification (or debug launch argument) pointed at.
    /// In the iPad split layout the split view owns this — don't double-handle.
    private func openPending() {
        guard onSelect == nil, let id = app.pendingOpenSessionId else { return }
        guard let session = app.sessions.first(where: { $0.id == id }) else {
            // Not on this computer — it may live on another paired one.
            Task { await app.locateAndOpen(id) }
            return
        }
        app.pendingOpenSessionId = nil
        // Compare ids, not whole values. SessionInfo's equality includes turnCount and
        // lastEventId, which change constantly, so a push deep link into a session the
        // user was already inside appended a SECOND copy with its own SSE stream.
        if !path.contains(where: { $0.id == session.id }) { path.append(session) }
    }

    // MARK: Header

    /// The masthead used to say "TethrX", which the person holding the phone already
    /// knows. What they cannot see is which Mac this is pointed at, so that is what it
    /// says now, and tapping it goes to the list of the others.
    private var accountHeader: some View {
        Button {
            settingsAnchor = "computers"
            showSettings = true
        } label: {
            HStack(spacing: 12) {
                // The mark sits on the canvas at the size a masthead wants. It used
                // to be dropped into a translucent disc with a ring around it, which
                // is the shape a contact photo goes in: it made the app's own logo
                // read as somebody's avatar, pasted on top of the screen rather than
                // drawn as part of it.
                TethrXMark(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: hostTitle)
                        .font(Grok.sans(17, .semibold)).foregroundStyle(Grok.text)
                        // A Mac name is arbitrary and can be long. Cut the middle: the
                        // tail is usually what tells two machines apart.
                        .lineLimit(1).truncationMode(.middle)
                    Text(verbatim: hostSubtitle)
                        .font(Grok.sans(13)).foregroundStyle(Grok.textDim)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Grok.textFaint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .foregroundStyle(Grok.text)
        .accessibilityLabel(Text("Computer: \(hostTitle). \(hostSubtitle)"))
        .accessibilityHint(Text("Opens settings"))
    }

    /// The computer this phone is pointed at. A Mac reports its Bonjour name, so the
    /// host normally arrives as "Name-MacBook-Pro.local"; the suffix is the one part
    /// of it that says nothing about which computer this is.
    private var hostTitle: String {
        if app.demoMode { return String(loc: "Tour") }
        let host = (app.health?.host ?? "")
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: ".home", with: "")
        return host.isEmpty ? String(loc: "No computer") : host
    }

    /// The line under it: what is running over there, or why nothing is.
    private var hostSubtitle: String {
        if app.demoMode { return String(loc: "Sample data") }
        if let grok = app.health?.grok, !grok.isEmpty {
            // The bridge reports "grok 1.0.13 (5e9a58528b76) [stable]". The build hash
            // and the channel are for a bug report, not for the line under the
            // computer's name.
            return grok
                .replacingOccurrences(of: #" *\([0-9a-f]{6,}\)"#, with: "",
                                      options: .regularExpression)
                .replacingOccurrences(of: #" *\[[^\]]*\]"#, with: "",
                                      options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return app.connected ? String(loc: "Connected") : String(loc: "Not connected")
    }

    private var somethingNeedsYou: Bool { app.sessions.contains { $0.isWaitingOnYou } }

    /// While a query is being typed the destinations step aside: the answer to
    /// "where is that conversation" should not be four rows down the screen.
    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What this phone can do besides talk, as four plain rows. These were buried:
    /// schedules and prompts inside Settings, usage two taps further in, and the
    /// project folder as a card marooned at the bottom of the conversation list.
    private var destinations: some View {
        Section {
            // Two of these run on the computer, so with nothing paired they are not
            // dimmed rows that go nowhere: they are simply not the list yet.
            if app.client != nil {
                destinationRow("Schedules", "clock.arrow.2.circlepath") { showSchedules = true }
            }
            destinationRow("Prompts", "text.badge.star",
                           value: snippets.items.isEmpty ? nil : "\(snippets.items.count)") {
                showPrompts = true
            }
            if app.client != nil {
                destinationRow("Usage", "chart.bar") { showUsage = true }
            }
            if !app.demoMode {
                destinationRow("Project folder", "folder", value: folderValue) { pickingCwd = true }
                    .contextMenu {
                        if !app.defaultCwd.isEmpty {
                            Button { app.defaultCwd = "" } label: {
                                Label("Reset to the computer's default", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
            }
        }
    }

    private func destinationRow(_ title: LocalizedStringKey, _ icon: String,
                                value: String? = nil,
                                action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            HStack(spacing: 12) {
                RowIcon(system: icon)
                Text(title).font(.body).foregroundStyle(Grok.text)
                    .lineLimit(1)
                    // The row's identity, so it takes its width first. The folder name
                    // beside it is a hint and middle-truncates.
                    .layoutPriority(1)
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

    private var folderValue: String? {
        guard !app.defaultCwd.isEmpty else { return nil }
        return (app.defaultCwd as NSString).lastPathComponent
    }

    /// Search, settings and new-session, in the third of the screen a thumb reaches.
    /// They used to sit in the top corners, which is the part of a phone you have to
    /// shift your grip to touch.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Outside the container on purpose. A glass container draws all of its
            // glass in one layer above everything inside it, so the field's own text
            // came out blurred behind its lens. On its own, the pill's glass stays
            // a background and the text sits crisply on top.
            searchPill
            // The two buttons are lenses over the same moving list, so they share
            // one container: it samples the backdrop once for both.
            GlassCluster {
                HStack(spacing: 12) {
                    barButton("gearshape", label: "Settings") {
                        settingsAnchor = nil
                        showSettings = true
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    barButton("square.and.pencil", label: "New session", busy: creating) {
                        Task { await startNew() }
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    // A folder is made about as often as the app is reinstalled, so it
                    // lives behind a long press rather than taking a fourth slot.
                    .contextMenu {
                        Button { newFolderName = ""; creatingFolder = true } label: {
                            Label("New folder", systemImage: "folder.badge.plus")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Grok.gutter)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(legacyBarFade)
    }

    /// Before iOS 26 the list had to be given something to come out of, or rows slid
    /// out from under the bar with a hard edge. A fade rather than a rule: a line
    /// across the screen here reads as a second window. iOS 26 draws this itself, as
    /// a soft blur along the scroll edge, and does it better.
    @ViewBuilder private var legacyBarFade: some View {
        if #available(iOS 26.0, *) {
            EmptyView()
        } else {
            Grok.fade(Grok.bg, [0, 0.92, 1])
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var searchPill: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Grok.textFaint)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text("Search").foregroundColor(Grok.textFaint))
                .font(Grok.sans(16)).foregroundStyle(Grok.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = ""; searchFocused = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(Grok.textDim)
                        // 44pt to tap, its own glyph box to the layout, so the pill
                        // does not change height on the first keystroke.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .frame(width: 20, height: 20)
                }
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        // The glass sits behind the field, never around it. A text field inside a
        // glass effect is re-rendered into the lens, and on iOS 26 the caret and
        // the newest characters blinked out while typing.
        .background { Color.clear.floatingGlass(in: Capsule(), interactive: false) }
        .contentShape(Capsule())
        .onTapGesture { searchFocused = true }
    }

    private func barButton(_ system: String, label: LocalizedStringKey,
                           busy: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Group {
                if busy {
                    ProgressView().controlSize(.small).tint(Grok.ink)
                } else {
                    Image(systemName: system)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Grok.text)
                }
            }
            .frame(width: 48, height: 48)
            .floatingGlass(in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(Text(label))
        .accessibilityValue(busy ? Text("busy") : Text(""))
    }

    // MARK: Banners

    /// One shape for everything the screen says to you before you have asked it
    /// anything: the tour notice, an error, the bridge-update warning. All three
    /// used to draw their own, and had drifted a point apart in every direction.
    private func banner<C: View>(alarming: Bool = false,
                                 @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The list row is the card. A warning tints it rather than drawing a
            // second box inside it.
            .listRowBackground(alarming
                ? AnyView(ZStack { Grok.raised; Grok.danger.opacity(0.10) })
                : AnyView(Grok.raised))
    }

    // MARK: Error banner

    /// Failures used to be written to `app.errorMessage` and rendered nowhere once
    /// connected — a failed delete/rename/switch just silently did nothing.
    private func errorBanner(_ message: String) -> some View {
        banner(alarming: true) {
            HStack(alignment: .top, spacing: 10) {
                Text("!").font(Grok.sans(15, .bold)).foregroundStyle(Grok.danger)
                    .accessibilityHidden(true)
                Text(message).font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(2)
                Spacer(minLength: 0)
                Button { app.errorMessage = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Grok.textDim)
                        // 44pt to tap, 32pt to the layout, so the banner keeps its height.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss error"))
            }
        }
    }

    // MARK: Grok signed out

    /// Every turn fails while grok is signed out on the computer, and the failure used
    /// to arrive one message at a time, inside whichever chat you happened to be in.
    private var signedOutBanner: some View {
        banner(alarming: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Grok is signed out on \(computerName)")
                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text)
                Text("Messages sent from here will fail until you sign in again. On that computer, run this in a terminal:")
                    .font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text(verbatim: "grok login")
                        .font(Grok.mono(14, .medium)).foregroundStyle(Grok.text)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Grok.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                    Button {
                        UIPasteboard.general.string = "grok login"
                        Haptics.success()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc").chip(on: false)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var computerName: String {
        let host = (app.health?.host ?? "")
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: ".home", with: "")
        return host.isEmpty ? String(loc: "the paired computer") : host
    }

    // MARK: Demo banner

    private var demoBanner: some View {
        banner {
            HStack(spacing: 10) {
                Text("Tour").font(Grok.sans(12, .semibold)).foregroundStyle(Grok.onInk)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Grok.accent).clipShape(Capsule())
                Text("Sample data: nothing is connected.")
                    .font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                Spacer(minLength: 0)
                Button { app.exitDemo() } label: {
                    Text("Exit").font(Grok.sans(14, .semibold)).foregroundStyle(Grok.text)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Running now

    /// Sessions with a turn in flight, surfaced above the folders — with schedules
    /// and long tasks, the RUNNING badges alone are too easy to lose in the list.
    /// What is happening right now, at the very top, with the answer in reach.
    ///
    /// A blocked session and a working one used to share one horizontal strip of
    /// identical pills that you had to swipe through and then open. The thing you
    /// came here to do is usually to answer something, so it is first and it is
    /// answerable in place.
    @ViewBuilder private var needsYou: some View {
        let waiting = app.sessions.filter { $0.isWaitingOnYou }
        let running = app.sessions.filter { $0.isRunning && !$0.isWaitingOnYou }
        if !waiting.isEmpty {
            Section {
                ForEach(waiting) { session in activeCard(session) }
            } header: {
                ListSectionLabel("Needs you")
            }
        }
        // A session that is merely working needs nothing from you, so it does not
        // sit under the heading that says something does.
        if !running.isEmpty {
            Section {
                ForEach(running) { session in runningRow(session) }
            } header: {
                ListSectionLabel("Working")
            }
        }
    }

    /// A blocked session: its name, and the approval, together.
    private func activeCard(_ session: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open(session)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Grok.text)
                        .accessibilityHidden(true)
                    Text(session.displayName)
                        .font(Grok.sans(17, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                    ElapsedLabel(since: Fmt.date(fromISO: session.waiting?.since))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Grok.textFaint)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if session.waiting?.requestId != nil {
                // Sharing the card's own edge and background. It used to draw a second
                // translucent panel 2pt inside the first, so the approval sat 12pt to
                // the left of the session name directly above it.
                Rectangle().fill(Grok.rule).frame(height: 1).padding(.leading, 16)
                InlineAnswer(session: session, nested: true)
            }
        }
        // The card is the list row; its parts set their own insets so the rule under
        // the name can start where the text does, as the system's separators do.
        .listRowInsets(EdgeInsets())
    }

    private func runningRow(_ session: SessionInfo) -> some View {
        Button { open(session) } label: {
            HStack(spacing: 10) {
                WorkingDot()
                Text(session.displayName)
                    .font(.body.weight(.medium)).foregroundStyle(Grok.text).lineLimit(1)
                ElapsedLabel(since: Fmt.date(fromISO: session.runningSince))
                Spacer(minLength: 0)
                RowChevron()
            }
            .contentShape(Rectangle())
        }
    }

    /// Open a session, whichever layout this list is driving.
    private func open(_ session: SessionInfo) {
        if let onSelect { onSelect(session) }
        else if !path.contains(where: { $0.id == session.id }) { path.append(session) }
    }

    // MARK: Bridge update banner

    /// Shown when the connected bridge predates what this app was built for —
    /// without it, the newer features fail with bare errors and no explanation.
    private var updateBanner: some View {
        banner {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Grok.text)
                    Text("Your bridge needs an update").font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text)
                }
                Text("This version of the app needs bridge \(AppState.wantedBridgeVersion) or newer. On your computer, run:")
                    .font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("npm i -g tethrx-bridge")
                        .font(Grok.mono(13)).foregroundStyle(Grok.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Button {
                        UIPasteboard.general.string = "npm i -g tethrx-bridge"
                        Haptics.tap()
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .medium)).foregroundStyle(Grok.textDim)
                            // 44pt to tap, 40pt to the layout, so the code box keeps its height.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel(Text("Copy command"))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Grok.bg)
                .overlay(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous)
                    .stroke(Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous))
                Text("Then restart the bridge and reconnect. Chat keeps working meanwhile; the newest features need the update.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sessions

    @ViewBuilder private var sessions: some View {
        if app.switching || (app.connecting && app.sessions.isEmpty) {
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading sessions…").font(.body).foregroundStyle(Grok.textDim)
                }
                .accessibilityElement(children: .combine)
            }
        } else if app.sessions.isEmpty {
            Section { emptyHistory }
        } else if filteredSessions.isEmpty {
            Section {
                Text("Nothing matches \u{201C}\(query)\u{201D}")
                    .font(.body).foregroundStyle(Grok.textDim)
            }
        } else {
            ForEach(historySections, id: \.key) { section in
                Section {
                    if !collapsed.contains(section.key) {
                        ForEach(section.items) { session in sessionLink(session) }
                        if section.items.isEmpty {
                            Text("Empty. Use ••• on a session to move it here.")
                                .font(.subheadline).foregroundStyle(Grok.textDim)
                        }
                    }
                } header: {
                    sectionHeader(section)
                }
            }
        }

        contentSearchResults
    }

    /// Sessions whose CONVERSATION matched the query (beyond title/folder/path).
    @ViewBuilder private var contentSearchResults: some View {
        let titleMatches = Set(filteredSessions.map { $0.id })
        let extras = contentHits.filter { !titleMatches.contains($0.sessionId) }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty, !extras.isEmpty {
            Section {
                ForEach(extras) { hit in
                    if let session = app.sessions.first(where: { $0.id == hit.sessionId }) {
                        Button {
                            if let onSelect { onSelect(session) } else if !path.contains(where: { $0.id == session.id }) { path.append(session) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayName)
                                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                                if let snippet = hit.hits.first?.snippet {
                                    Text("…\(snippet)…")
                                        .font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(Grok.text)
                    }
                }
            } header: {
                ListSectionLabel("Found in conversations")
            }
        }
    }

    // Session list, filtered by the search query (title, folder, working dir, id).
    private var filteredSessions: [SessionInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return app.sessions }
        return app.sessions.filter {
            $0.title.lowercased().contains(q)
            || ($0.folder?.lowercased().contains(q) ?? false)
            || ($0.cwd?.lowercased().contains(q) ?? false)
            || $0.id.lowercased().hasPrefix(q)
        }
    }

    /// One section of the history list.
    struct HistorySection {
        /// Stable identity for collapse state; also the folder name when it is one.
        var key: String
        var title: String
        var items: [SessionInfo]
        var isFolder: Bool
    }

    /// Pinned first, then any folders you made, then everything else by when you last
    /// touched it. Creation order buried the session you work in daily, and a flat
    /// list of forty gave no way in at all.
    private var historySections: [HistorySection] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        var used = Set<String>()
        var out: [HistorySection] = []

        let pinned = filteredSessions.filter { app.pinned.contains($0.id) }
        if !pinned.isEmpty {
            out.append(HistorySection(key: "\u{1}pinned", title: String(loc: "Pinned"),
                                      items: pinned, isFolder: false))
            used.formUnion(pinned.map(\.id))
        }

        for name in app.orderedFolders {
            let items = filteredSessions.filter { $0.folder == name && !used.contains($0.id) }
            // A folder you just made has nowhere to drop things if it vanishes, so it
            // survives empty — but not while searching, where it is only noise.
            if items.isEmpty && searching { continue }
            out.append(HistorySection(key: name, title: name, items: items,
                                      isFolder: true))
            used.formUnion(items.map(\.id))
        }

        let rest = filteredSessions.filter { !used.contains($0.id) }
        for bucket in RecencyBucket.allCases {
            let items = rest.filter { bucket.contains(Fmt.date(fromISO: $0.updatedAt)) }
            guard !items.isEmpty else { continue }
            out.append(HistorySection(key: "\u{1}" + bucket.rawValue, title: bucket.title,
                                      items: items, isFolder: false))
        }
        return out
    }

    /// A heading is a heading. This one used to carry a folder glyph, an uppercase
    /// tracked label, a count, a chevron and a rule that ran to the edge of the
    /// screen, above three conversations.
    private func sectionHeader(_ section: HistorySection) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsed.contains(section.key) { collapsed.remove(section.key) }
                    else { collapsed.insert(section.key) }
                }
            } label: {
                HStack(spacing: 6) {
                    ListSectionLabel(verbatim: section.title).lineLimit(1)
                    // Collapsed, the rows are gone and the heading is all that is left
                    // to say the section is still there. Open, it says nothing worth a
                    // glyph, so it does not draw one.
                    if collapsed.contains(section.key) {
                        Text(verbatim: "\(section.items.count)")
                            .font(Grok.sans(13, .medium)).monospacedDigit()
                            .foregroundStyle(Grok.textFaint.opacity(0.7))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Grok.textFaint)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(section.title), \(section.items.count) sessions"))
            .accessibilityHint(Text(collapsed.contains(section.key) ? "Expands the section" : "Collapses the section"))

            // Only a folder you made can be reordered or deleted; a date is a fact.
            if section.isFolder {
                Menu {
                    Button { app.moveFolder(section.key, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                    Button { app.moveFolder(section.key, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                    Button(role: .destructive) { Task { await app.deleteFolder(section.key) } } label: {
                        Label("Delete folder", systemImage: "folder.badge.minus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Grok.textFaint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        // 44pt to the finger, its glyph's box to the layout. Handed
                        // over whole it set the height of the whole heading.
                        .frame(width: 28, height: 16)
                }
                .accessibilityLabel(Text("Folder options for \(section.title)"))
            }
        }
        .textCase(nil)
    }

    /// Nothing here yet: say what to do, once, instead of a comment glyph.
    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No sessions yet").font(.headline).foregroundStyle(Grok.text)
            Text("Start one with the button below.")
                .font(.subheadline).foregroundStyle(Grok.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func sessionLink(_ session: SessionInfo) -> some View {
        // The answer lives ONLY in the block at the top of the screen. A session
        // still shows its state dot down here, but two identical approval cards on
        // one screen is a question asked twice.
        let pinned = app.pinned.contains(session.id)
        return HStack(spacing: 0) {
            Button { open(session) } label: {
                SessionRow(session: session, pinned: pinned)
                    .padding(.leading, 16)
            }
            .buttonStyle(RowPressStyle())
            // Visible affordance: the same actions used to be long-press only.
            Menu {
                menuItems(session)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Grok.textDim)
                    .frame(width: 48, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Session options for \(session.displayName)"))
        }
        .listRowInsets(EdgeInsets())
        .contextMenu { menuItems(session) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deletingSession = session } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { app.togglePin(session.id) } label: {
                pinned ? Label("Unpin", systemImage: "pin.slash") : Label("Pin", systemImage: "pin")
            }
            .tint(Color(uiColor: .systemGray))
        }
    }

    @ViewBuilder private func menuItems(_ session: SessionInfo) -> some View {
        Button { app.togglePin(session.id) } label: {
            app.pinned.contains(session.id)
                ? Label("Unpin", systemImage: "pin.slash")
                : Label("Pin to the top", systemImage: "pin")
        }
        Button { renameText = session.title; renaming = session } label: { Label("Rename", systemImage: "pencil") }
        moveMenu(session)
        // Branching a session with history costs a summary turn, so it stays out of
        // reach while one is running — same rule the bridge enforces.
        if !app.demoMode, !session.isRunning {
            Button { Task { await branch(session) } } label: {
                Label("Branch", systemImage: "arrow.triangle.branch")
            }
        }
        Button(role: .destructive) { deletingSession = session } label: { Label("Delete", systemImage: "trash") }
    }

    private func branch(_ session: SessionInfo) async {
        guard let client = app.client else { return }
        do {
            let fresh = try await client.branch(sessionId: session.id)
            Haptics.success()
            await app.reloadSessions()
            app.pendingOpenSessionId = fresh.id
        } catch {
            app.errorMessage = String(loc: "Couldn't branch that session.")
        }
    }

    private func moveMenu(_ session: SessionInfo) -> some View {
        Menu {
            ForEach(app.folders, id: \.self) { f in
                if f != session.folder {
                    Button { Task { await app.setFolder(session.id, folder: f) } } label: { Label(f, systemImage: "folder") }
                }
            }
            Button { folderText = ""; foldering = session } label: { Label("New folder…", systemImage: "folder.badge.plus") }
            if let cur = session.folder, !cur.isEmpty {
                Button(role: .destructive) { Task { await app.setFolder(session.id, folder: "") } } label: {
                    Label("Remove from folder", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label("Move to folder", systemImage: "folder")
        }
    }

    private func startNew() async {
        creating = true
        defer { creating = false }
        guard let session = await app.newSession() else { return }
        if let onSelect { onSelect(session) } else { path.append(session) }
    }
}

/// Answer what a session is blocked on without opening it.
///
/// The bridge sends the request and option ids with the waiting state, so the list
/// has everything it needs. Opening the conversation, scrolling to the bottom and
/// tapping there was three steps for a yes or a no, and the yes/no is most of what
/// this app is for.
struct InlineAnswer: View {
    let session: SessionInfo
    /// Inside a card that already draws a surface, this draws none of its own: one
    /// background, one border, one left edge.
    var nested = false
    @EnvironmentObject var app: AppState
    @State private var working = false
    /// The request the "Run …?" dialog is about. The row's session is replaced by every
    /// poll, so the dialog must answer THIS request or nothing, never whatever the row
    /// holds by the time it is confirmed.
    @State private var confirming: String?

    private var isPlan: Bool { session.waiting?.kind == "plan" }
    /// A permission can be approved from here only with an allow-once option to send.
    /// Without one, Approve sent no option at all, which the computer reads as cancel.
    private var canApprove: Bool { isPlan || session.waiting?.allow != nil }
    private var command: String { session.waiting?.commandText ?? "" }
    /// Only the start of the command is known (an older bridge cut it). It is judged
    /// and shown as what it is, and approving it always asks first.
    private var cut: Bool { !isPlan && session.waiting?.commandMayBeCut == true }
    private var risk: CommandRisk? { isPlan ? nil : CommandRisk.assess(command) }
    private var shownCommand: String { cut ? command + "\u{2026}" : command }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !command.isEmpty, !isPlan {
                // A shell command, so it wears the same face here as in the chat
                // approval card and on the watch. You are authorizing it from a list
                // row without having read the conversation.
                Text(verbatim: shownCommand)
                    .font(Grok.mono(13)).foregroundStyle(Grok.text)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let risk {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: risk.icon).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(risk.level == .destructive ? Grok.danger : Grok.textDim)
                        .accessibilityHidden(true)
                    Text(risk.reason)
                        .font(Grok.sans(13))
                        .foregroundStyle(risk.level == .destructive ? Grok.danger : Grok.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if cut {
                // Said on the card, not only in the dialog Approve opens: the reason
                // to open the session first is worth knowing before tapping anything.
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "eye.slash").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Grok.textDim)
                        .accessibilityHidden(true)
                    Text("Only the start of this command is shown.")
                        .font(Grok.sans(13))
                        .foregroundStyle(Grok.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                Button {
                    // Approving a deletion from a list row, without having read the
                    // conversation, is the one tap worth interrupting.
                    // So is approving a command whose end this card cannot show.
                    guard let requestId = session.waiting?.requestId else { return }
                    if risk?.level == .destructive || cut {
                        confirming = requestId
                    } else {
                        answer(true, requestId: requestId)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.mini).tint(Grok.onInk) }
                        // Half a card each, and "Genehmigen & umsetzen" does not fit in
                        // half a card at large text sizes. Same floor PillButton uses.
                        (isPlan ? Text("Approve & build") : Text("Approve"))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(Grok.sans(13, .semibold))
                    .foregroundStyle(Grok.onInk)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Grok.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(working || !canApprove)
                .opacity(canApprove ? 1 : 0.4)

                Button { answer(false, requestId: session.waiting?.requestId) } label: {
                    (isPlan ? Text("Keep planning") : Text("Deny"))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .font(Grok.sans(13, .semibold))
                        .foregroundStyle(Grok.textDim)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
        }
        .padding(.horizontal, nested ? 16 : Grok.pad)
        .padding(.vertical, 12)
        .background(risk?.level == .destructive ? Grok.danger.opacity(0.08)
                    : (nested ? Color.clear : Grok.raised))
        .overlay(nested ? nil : RoundedRectangle(cornerRadius: Grok.R.small, style: .continuous)
            .stroke(risk?.level == .destructive ? Grok.danger.opacity(0.4) : Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: nested ? 0 : Grok.R.small, style: .continuous))
        .padding(.bottom, nested ? 0 : 12)
        .confirmationDialog(Text("Run \u{201C}\(shownCommand)\u{201D}?"),
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            Button("Approve", role: .destructive) {
                if let requestId = confirming { answer(true, requestId: requestId) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if cut {
                Text("Only the start of this command is shown.")
            } else if let risk {
                Text(risk.reason)
            }
        }
        // Answered elsewhere while the dialog was up, or answered and followed at once by
        // the next request: the dialog is about something no longer on screen.
        .onChange(of: session.waiting?.requestId) { _, id in
            if id != confirming { confirming = nil }
        }
    }

    private func answer(_ allow: Bool, requestId: String?) {
        working = true
        Task {
            _ = await app.answerWaiting(session, allow: allow, requestId: requestId)
            working = false
        }
    }
}

/// A slowly breathing dot: a session that is working should look like it is.
struct WorkingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Grok.accent)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// A ticking "· 4m" beside a RUNNING or WAITING badge. A badge alone is the same
/// shape at four seconds and at forty minutes, which is the difference between
/// "it's working" and "it's stuck".
struct ElapsedLabel: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: "· \(Fmt.elapsed(since: since, now: context.date))")
                    .font(Grok.sans(11)).monospacedDigit()
                    .foregroundStyle(Grok.textFaint)
            }
            .accessibilityHidden(true)
        }
    }
}

/// How the history is cut when it is not in a folder you made.
enum RecencyBucket: String, CaseIterable {
    case today, yesterday, week, month, older

    var title: String {
        switch self {
        case .today:     return String(loc: "Today")
        case .yesterday: return String(loc: "Yesterday")
        case .week:      return String(loc: "Previous 7 days")
        case .month:     return String(loc: "Previous 30 days")
        case .older:     return String(loc: "Older")
        }
    }

    /// A session the bridge never dated falls into `older` rather than vanishing.
    func contains(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return self == .older }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return self == .today }
        if cal.isDateInYesterday(date) { return self == .yesterday }
        let days = cal.dateComponents([.day], from: date, to: now).day ?? 0
        switch self {
        case .week:  return days < 7
        case .month: return days >= 7 && days < 30
        case .older: return days >= 30
        default:     return false
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    var pinned: Bool = false

    private var name: String { session.displayName }

    /// The one line under the name. It used to be three lines: an id and a badge, the
    /// name, then the folder and two counts. The id told you nothing the folder does
    /// not, and the badge repeated what the block at the top of the screen already
    /// says, in capitals, on every row.
    private var subtitle: Text {
        var parts: [Text] = []
        // A session with no title of its own IS its folder name up top, so printing
        // the same word again directly underneath is a row that says one thing twice.
        if let cwd = session.cwd, !cwd.isEmpty {
            let leaf = (cwd as NSString).lastPathComponent
            if leaf != name { parts.append(Text(verbatim: leaf)) }
        }
        parts.append(session.turnCount == 1 ? Text("1 turn") : Text("\(session.turnCount) turns"))
        if let touched = Fmt.date(fromISO: session.updatedAt) {
            parts.append(Text(verbatim: Fmt.ago(touched)))
        }
        return parts.dropFirst().reduce(parts.first ?? Text(verbatim: "")) {
            $0 + Text(verbatim: " · ") + $1
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 10))
                            .foregroundStyle(Grok.textFaint)
                            .accessibilityLabel(Text("Pinned"))
                    }
                    Text(name)
                        .font(Grok.sans(17, .semibold)).foregroundStyle(Grok.text)
                        .lineLimit(1)
                }
                subtitle
                    .font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // A dot, not a word. Whichever state this is, the block at the top of the
            // screen names it and offers the buttons; down here it only has to mark
            // which row that block is talking about.
            if session.isWaitingOnYou {
                Circle().fill(Grok.text).frame(width: 8, height: 8)
                    .accessibilityLabel(Text("Waiting for your approval"))
            } else if session.isRunning {
                // WorkingDot hides itself from the accessibility tree, so a label put
                // on it from out here lands on nothing. This wrapper is the element.
                ZStack { WorkingDot() }
                    .accessibilityElement()
                    .accessibilityLabel(Text("Running"))
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}
