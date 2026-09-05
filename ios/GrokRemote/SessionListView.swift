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
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var deletingSession: SessionInfo?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if app.demoMode { demoBanner }
                    if let err = app.errorMessage, !app.demoMode { errorBanner(err) }
                    if app.bridgeNeedsUpdate { updateBanner }
                    searchField
                    needsYou
                    sessions
                    projectFolderRow
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 28)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
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
                SettingsView().environmentObject(app).environmentObject(lock).environmentObject(snippets)
            }
            .sheet(isPresented: $pickingCwd) {
                DirectoryPickerSheet().environmentObject(app)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SessionInfo.self) { session in
                if app.demoMode {
                    ChatView(vm: ChatViewModel(demoSession: session))
                } else if let client = app.client {
                    ChatView(vm: ChatViewModel(client: client, session: session))
                } else {
                    ZStack { Grok.bg.ignoresSafeArea(); Eyebrow("DISCONNECTED") }
                }
            }
        }
        .task {
            #if DEBUG
            // Headless screenshots: `-openSettings` jumps straight to the sheet.
            if ProcessInfo.processInfo.arguments.contains("-openSettings") { showSettings = true }
            #endif
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
            }
        }
        .onChange(of: app.pendingOpenSessionId) { _, _ in openPending() }
        // The whole array, not just its count: switching to another computer can
        // land on the same number of sessions, which would swallow the deep-open.
        .onChange(of: app.sessions) { _, _ in openPending() }
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

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                TethrXMark(size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "TethrX")
                        .font(Grok.display(26)).tracking(-0.4).foregroundStyle(Grok.text)
                    SectionLabel(verbatim: statusLine)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Shortcuts hang off the buttons that already exist, so an iPad keyboard
            // is faster without inventing anything invisible.
            CircleIconButton(system: "gearshape", a11y: "Settings") { showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
            CircleIconButton(system: "plus", filled: true, busy: creating, a11y: "New session") {
                Task { await startNew() }
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.bottom, 4)
    }

    /// What this phone is attached to, said the way a console says it.
    private var statusLine: String {
        if app.demoMode { return String(localized: "Tour") }
        var parts: [String] = []
        if let host = app.health?.host, !host.isEmpty {
            parts.append(host.replacingOccurrences(of: ".home", with: ""))
        }
        if let grok = app.health?.grok, !grok.isEmpty {
            parts.append(grok.replacingOccurrences(of: "grok ", with: ""))
        }
        if parts.isEmpty { return String(localized: "Not connected") }
        return parts.joined(separator: " · ")
    }

    // MARK: Error banner

    /// Failures used to be written to `app.errorMessage` and rendered nowhere once
    /// connected — a failed delete/rename/switch just silently did nothing.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("!").font(Grok.sans(15, .bold)).foregroundStyle(Grok.danger)
                .accessibilityHidden(true)
            Text(message).font(Grok.sans(14)).foregroundStyle(Grok.textDim).lineSpacing(2)
            Spacer(minLength: 0)
            Button { app.errorMessage = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Grok.textDim)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss error"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.danger.opacity(0.35), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Demo banner

    private var demoBanner: some View {
        HStack(spacing: 10) {
            Text("TOUR").font(Grok.sans(11, .bold)).tracking(0.8).foregroundStyle(.black)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Grok.accent).clipShape(Capsule())
            Text("Sample data — nothing is connected.")
                .font(Grok.sans(14)).foregroundStyle(Grok.textDim)
            Spacer(minLength: 0)
            Button { app.exitDemo() } label: {
                Text("Exit").font(Grok.sans(14, .semibold)).foregroundStyle(Grok.text)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        if !waiting.isEmpty || !running.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(waiting.isEmpty ? "WORKING" : "NEEDS YOU")
                ForEach(waiting) { session in activeCard(session) }
                if !running.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(running.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { Rectangle().fill(Grok.rule).frame(height: 1) }
                            runningRow(session)
                        }
                    }
                }
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
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if session.waiting?.requestId != nil {
                InlineAnswer(session: session).padding(.horizontal, 2)
            }
        }
        .background(Grok.raised)
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
    }

    private func runningRow(_ session: SessionInfo) -> some View {
        Button { open(session) } label: {
            HStack(spacing: 10) {
                WorkingDot()
                Text(session.displayName)
                    .font(Grok.sans(16, .medium)).foregroundStyle(Grok.text).lineLimit(1)
                ElapsedLabel(since: Fmt.date(fromISO: session.runningSince))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    .font(Grok.sans(15)).foregroundStyle(Grok.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = "npm i -g tethrx-bridge"
                    Haptics.tap()
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .medium)).foregroundStyle(Grok.textDim)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Copy command"))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Grok.bg)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Grok.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            Text("Then restart the bridge and reconnect. Chat keeps working meanwhile; the newest features need the update.")
                .font(Grok.sans(13)).foregroundStyle(Grok.textFaint).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Working directory

    /// Where a NEW session starts. It is a default, not a thing you came here to
    /// manage, so it sits at the bottom as one row instead of a card, a paragraph
    /// and a heading at the top of everything.
    private var projectFolderRow: some View {
        Button {
            guard !app.demoMode else { return }
            Haptics.tap()
            pickingCwd = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 14))
                    .foregroundStyle(Grok.textFaint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("New sessions start in")
                        .font(Grok.sans(13)).foregroundStyle(Grok.textFaint)
                    Text(app.defaultCwd.isEmpty
                         ? String(localized: "the computer's default folder")
                         : (app.defaultCwd as NSString).lastPathComponent)
                        .font(Grok.sans(15, .medium)).foregroundStyle(Grok.textDim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if !app.demoMode {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Grok.textFaint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Grok.raised)
            .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.defaultCwd.isEmpty
                            ? Text("New sessions start in the computer's default folder")
                            : Text("New sessions start in \(app.defaultCwd)"))
        .accessibilityHint(Text("Opens the folder picker"))
        .contextMenu {
            if !app.defaultCwd.isEmpty {
                Button { app.defaultCwd = "" } label: {
                    Label("Reset to the computer's default", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    // MARK: Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.switching || (app.connecting && app.sessions.isEmpty) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Loading sessions…").font(Grok.sans(15)).foregroundStyle(Grok.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)
            } else if app.sessions.isEmpty {
                emptyHistory
            } else if filteredSessions.isEmpty {
                Text("Nothing matches \u{201C}\(query)\u{201D}")
                    .font(Grok.sans(15)).foregroundStyle(Grok.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ForEach(historySections, id: \.key) { section in
                    sectionHeader(section)
                    if !collapsed.contains(section.key) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Rectangle().fill(Grok.rule).frame(height: 1) }
                                sessionLink(session)
                            }
                            if section.items.isEmpty {
                                Text("Empty — use ••• on a session to move it here")
                                    .font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
                                    .padding(.vertical, 14)
                            }
                        }
                    }
                    Color.clear.frame(height: 16)
                }
            }

            contentSearchResults
        }
    }

    /// Sessions whose CONVERSATION matched the query (beyond title/folder/path).
    @ViewBuilder private var contentSearchResults: some View {
        let titleMatches = Set(filteredSessions.map { $0.id })
        let extras = contentHits.filter { !titleMatches.contains($0.sessionId) }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty, !extras.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("FOUND IN CONVERSATIONS")
                    .padding(.top, 18).padding(.bottom, 10)
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
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if hit.id != extras.last?.id { Rectangle().fill(Grok.hairline).frame(height: 1) }
                    }
                }
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
        var systemImage: String
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
            out.append(HistorySection(key: "\u{1}pinned", title: String(localized: "Pinned"),
                                      items: pinned, isFolder: false, systemImage: "pin.fill"))
            used.formUnion(pinned.map(\.id))
        }

        for name in app.orderedFolders {
            let items = filteredSessions.filter { $0.folder == name && !used.contains($0.id) }
            // A folder you just made has nowhere to drop things if it vanishes, so it
            // survives empty — but not while searching, where it is only noise.
            if items.isEmpty && searching { continue }
            out.append(HistorySection(key: name, title: name, items: items,
                                      isFolder: true, systemImage: "folder.fill"))
            used.formUnion(items.map(\.id))
        }

        let rest = filteredSessions.filter { !used.contains($0.id) }
        for bucket in RecencyBucket.allCases {
            let items = rest.filter { bucket.contains(Fmt.date(fromISO: $0.updatedAt)) }
            guard !items.isEmpty else { continue }
            out.append(HistorySection(key: "\u{1}" + bucket.rawValue, title: bucket.title,
                                      items: items, isFolder: false, systemImage: "clock"))
        }
        return out
    }

    // Kept for the iPad sidebar's older call sites.
    private var groupedSessions: [(folder: String, items: [SessionInfo])] {
        let groups = Dictionary(grouping: filteredSessions) { ($0.folder?.isEmpty == false) ? $0.folder! : "" }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let matched = Set(groups.keys.filter { !$0.isEmpty })
        var out: [(String, [SessionInfo])] = []
        // Folders first, in the user's chosen order. While searching, only ones with hits.
        for name in app.orderedFolders where !searching || matched.contains(name) {
            out.append((name, groups[name] ?? []))
        }
        // Ungrouped last, so the folders you made are what you see first.
        if let ungrouped = groups[""], !ungrouped.isEmpty { out.append(("", ungrouped)) }
        return out
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            searchBox
            Button { Haptics.tap(); newFolderName = ""; creatingFolder = true } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Grok.textDim)
                    .frame(width: 44, height: 44)
                    .background(Grok.raised, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("New folder"))
        }
    }

    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Grok.textFaint)
            TextField("", text: $query, prompt: Text("Search sessions").foregroundColor(Grok.textFaint))
                .font(Grok.sans(16)).foregroundStyle(Grok.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Grok.textDim)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Grok.raised)
        .clipShape(RoundedRectangle(cornerRadius: Grok.R.field, style: .continuous))
    }

    private func sectionHeader(_ section: HistorySection) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsed.contains(section.key) { collapsed.remove(section.key) }
                    else { collapsed.insert(section.key) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Grok.textFaint)
                        .accessibilityHidden(true)
                    SectionLabel(verbatim: section.title)
                    Text(verbatim: "\(section.items.count)")
                        .font(Grok.sans(11, .semibold)).monospacedDigit()
                        .foregroundStyle(Grok.textFaint.opacity(0.7))
                    Image(systemName: collapsed.contains(section.key) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Grok.textFaint)
                        .accessibilityHidden(true)
                    Rectangle().fill(Grok.rule).frame(height: 1)
                }
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
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Folder options for \(section.title)"))
            }
        }
        .padding(.bottom, 8)
    }

    /// Nothing here yet: say what to do, once, instead of a comment glyph.
    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No sessions yet").font(Grok.sans(17, .semibold)).foregroundStyle(Grok.text)
            Text("Tap + to start one on your computer.")
                .font(Grok.sans(15)).foregroundStyle(Grok.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 28)
    }

    private func sessionLink(_ session: SessionInfo) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if let onSelect {
                    Button { onSelect(session) } label: { SessionRow(session: session, pinned: app.pinned.contains(session.id)) }
                        .buttonStyle(.plain)
                } else {
                    NavigationLink(value: session) { SessionRow(session: session, pinned: app.pinned.contains(session.id)) }
                        .buttonStyle(.plain)
                }
                // Visible affordance — the same actions used to be long-press only.
                Menu {
                    menuItems(session)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Grok.textDim)
                        .frame(width: 44, height: 48)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Session options for \(session.displayName)"))
            }
            // The answer lives ONLY in the section at the top. A session still shows
            // its WAITING badge down here, but two identical approval cards on one
            // screen is a question asked twice.
        }
        .contextMenu { menuItems(session) }
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
            app.errorMessage = String(localized: "Couldn't branch that session.")
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
    @EnvironmentObject var app: AppState
    @State private var working = false
    @State private var confirmDestructive = false

    private var isPlan: Bool { session.waiting?.kind == "plan" }
    private var command: String { session.waiting?.label ?? "" }
    private var risk: CommandRisk? { isPlan ? nil : CommandRisk.assess(command) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !command.isEmpty, !isPlan {
                Text(command)
                    .font(Grok.sans(15)).foregroundStyle(Grok.text)
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
            HStack(spacing: 8) {
                Button {
                    // Approving a deletion from a list row, without having read the
                    // conversation, is the one tap worth interrupting.
                    if risk?.level == .destructive { confirmDestructive = true } else { answer(true) }
                } label: {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.mini).tint(.black) }
                        (isPlan ? Text("Approve & build") : Text("Approve")).lineLimit(1)
                    }
                    .font(Grok.sans(13, .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Grok.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(working)

                Button { answer(false) } label: {
                    (isPlan ? Text("Keep planning") : Text("Deny")).lineLimit(1)
                        .font(Grok.sans(13, .semibold))
                        .foregroundStyle(Grok.textDim)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
        }
        .padding(12)
        .background(risk?.level == .destructive ? Grok.danger.opacity(0.08) : Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(risk?.level == .destructive ? Grok.danger.opacity(0.4) : Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.bottom, 12)
        .confirmationDialog(Text("Run \u{201C}\(command)\u{201D}?"), isPresented: $confirmDestructive,
                            titleVisibility: .visible) {
            Button("Approve", role: .destructive) { answer(true) }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let risk { Text(risk.reason) }
        }
    }

    private func answer(_ allow: Bool) {
        working = true
        Task {
            _ = await app.answerWaiting(session, allow: allow)
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
        case .today:     return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .week:      return String(localized: "Previous 7 days")
        case .month:     return String(localized: "Previous 30 days")
        case .older:     return String(localized: "Older")
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

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                            .foregroundStyle(Grok.textFaint)
                            .accessibilityLabel(Text("Pinned"))
                    }
                    // An id is an identifier, so it keeps the mono face.
                    Text(session.id.prefix(8))
                        .font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
                    // Blocked on you outranks running: it is the state that needs an
                    // action, and it used to be invisible.
                    if session.isWaitingOnYou {
                        HStack(spacing: 5) {
                            Image(systemName: "hand.raised.fill").font(.system(size: 8, weight: .bold))
                            Text("WAITING FOR YOU").font(Grok.sans(11, .semibold)).tracking(0.4)
                            ElapsedLabel(since: Fmt.date(fromISO: session.waiting?.since))
                        }
                        .foregroundStyle(Grok.text)
                        .accessibilityLabel(Text("Waiting for your approval"))
                    } else if session.isRunning {
                        HStack(spacing: 5) {
                            Circle().fill(Grok.accent).frame(width: 6, height: 6)
                            Text("RUNNING").font(Grok.sans(11, .semibold)).tracking(0.4).foregroundStyle(Grok.accent)
                            ElapsedLabel(since: Fmt.date(fromISO: session.runningSince))
                        }
                    }
                }
                Text(name).font(Grok.sans(17, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                HStack(spacing: 8) {
                    if let cwd = session.cwd, !cwd.isEmpty {
                        Text((cwd as NSString).lastPathComponent)
                            .font(Grok.sans(14)).foregroundStyle(Grok.textDim)
                            .lineLimit(1)
                    }
                    Text("· \(session.turnCount) turn\(session.turnCount == 1 ? "" : "s")")
                        .font(Grok.sans(14)).foregroundStyle(Grok.textFaint).fixedSize()
                    // Only when nothing is happening: a live session already carries
                    // a stopwatch, and two clocks in one row is one too many.
                    if !session.isRunning, !session.isWaitingOnYou,
                       let touched = Fmt.date(fromISO: session.updatedAt) {
                        Text(verbatim: "· \(Fmt.ago(touched))")
                            .font(Grok.sans(14)).foregroundStyle(Grok.textFaint).fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}
