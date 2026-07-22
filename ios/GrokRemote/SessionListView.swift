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

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if app.demoMode { demoBanner }
                    if let err = app.errorMessage, !app.demoMode { errorBanner(err) }
                    if app.bridgeNeedsUpdate { updateBanner }
                    workingDir
                    runningNow
                    sessions
                }
                .padding(20)
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
        if !path.contains(session) { path.append(session) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                TethrXMark(size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TETHRX").font(Grok.mono(13, .semibold)).tracking(1.2).foregroundStyle(Grok.text)
                    if let grok = app.health?.grok {
                        Text(grok.replacingOccurrences(of: "grok ", with: "v"))
                            .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineLimit(1)
                    }
                }
            }
            Spacer()
            CircleIconButton(system: "gearshape", a11y: "Settings") { showSettings = true }
            CircleIconButton(system: "plus", filled: true, busy: creating, a11y: "New session") {
                Task { await startNew() }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Error banner

    /// Failures used to be written to `app.errorMessage` and rendered nowhere once
    /// connected — a failed delete/rename/switch just silently did nothing.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                .accessibilityHidden(true)
            Text(message).font(Grok.mono(11)).foregroundStyle(Grok.textDim).lineSpacing(2)
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
            Text("DEMO").font(Grok.mono(9, .bold)).tracking(0.8).foregroundStyle(.black)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Grok.accent).clipShape(Capsule())
            Text("Sample data — nothing is connected.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
            Spacer(minLength: 0)
            Button { app.exitDemo() } label: {
                Text("Exit").font(Grok.mono(11, .semibold)).foregroundStyle(Grok.text)
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
    @ViewBuilder private var runningNow: some View {
        let running = app.sessions.filter { $0.isRunning }
        if !running.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("RUNNING NOW")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(running) { session in
                            Button {
                                if let onSelect { onSelect(session) } else if !path.contains(session) { path.append(session) }
                            } label: {
                                HStack(spacing: 7) {
                                    Circle().fill(Grok.accent).frame(width: 6, height: 6)
                                    Text(session.displayName).font(Grok.mono(12, .medium)).lineLimit(1)
                                }
                                .foregroundStyle(Grok.text)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
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
                .font(Grok.mono(11)).foregroundStyle(Grok.textDim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("npm i -g tethrx-bridge")
                    .font(Grok.mono(12)).foregroundStyle(Grok.text)
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
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Working directory

    private var workingDir: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow("WORKING DIRECTORY")
            FieldBox {
                HStack(spacing: 10) {
                    TextField("", text: $app.defaultCwd,
                              prompt: Text("/Users/you/project — blank = daemon default").foregroundColor(Grok.textFaint))
                        .font(Grok.mono(13))
                        .foregroundStyle(Grok.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Browse instead of typing a Unix path on a phone keyboard.
                    // Hidden in demo: it browses the real computer (like Files/Changes).
                    if !app.demoMode {
                        Button { Haptics.tap(); pickingCwd = true } label: {
                            Image(systemName: "folder").font(.system(size: 14, weight: .medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .foregroundStyle(Grok.textDim)
                        .accessibilityLabel(Text("Browse folders"))
                    }
                }
            }
            Text("New sessions run Grok in this folder. Plan mode, effort, and approvals are set inside each session.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
        }
    }

    // MARK: Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Eyebrow("SESSIONS")
                Spacer()
                Button { Haptics.tap(); newFolderName = ""; creatingFolder = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 12, weight: .medium))
                        Text("New folder").font(Grok.mono(11))
                    }
                    .foregroundStyle(Grok.textDim)
                }
                .buttonStyle(.plain)
                Text("\(app.sessions.count)").font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
            }
            .padding(.bottom, 12)

            // `|| !query.isEmpty`: the field must not vanish (at ≤6 sessions) while
            // its query still filters the list — that stranded an unclearable filter.
            if app.sessions.count > 6 || !query.isEmpty { searchField.padding(.bottom, 14) }

            if app.switching || (app.connecting && app.sessions.isEmpty) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("loading sessions…").font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 24)
                .accessibilityElement(children: .combine)
            } else if app.sessions.isEmpty {
                Text("// no sessions yet — tap + to start")
                    .font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else if filteredSessions.isEmpty {
                Text("// nothing matches \u{201C}\(query)\u{201D}")
                    .font(Grok.mono(12)).foregroundStyle(Grok.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                let groups = groupedSessions
                let hasFolders = groups.contains { !$0.folder.isEmpty }
                ForEach(groups, id: \.folder) { group in
                    if !group.folder.isEmpty || hasFolders {
                        folderHeader(group.folder.isEmpty ? String(localized: "Ungrouped") : group.folder,
                                     key: group.folder, count: group.items.count)
                    }
                    if !collapsed.contains(group.folder) {
                        if group.items.isEmpty {
                            Text("// empty — use ••• on a session to move it here")
                                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                                .padding(.vertical, 10)
                        }
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { Rectangle().fill(Grok.hairline).frame(height: 1) }
                            sessionLink(session)
                        }
                    }
                    if hasFolders { Color.clear.frame(height: 8) }
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
                            if let onSelect { onSelect(session) } else if !path.contains(session) { path.append(session) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayName)
                                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                                if let snippet = hit.hits.first?.snippet {
                                    Text("…\(snippet)…")
                                        .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
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

    // Ungrouped sessions first, then folders alphabetically; order within a group preserved.
    // Freshly-created (still empty) folders are shown too, so they're somewhere to drop
    // sessions into — but they're hidden while searching, where they'd just be noise.
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Grok.textFaint)
            TextField("", text: $query, prompt: Text("search sessions").foregroundColor(Grok.textFaint))
                .font(Grok.mono(13)).foregroundStyle(Grok.text)
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
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func folderHeader(_ name: String, key: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Grok.textFaint).frame(width: 10)
                    Image(systemName: key.isEmpty ? "tray" : "folder.fill")
                        .font(.system(size: 11)).foregroundStyle(Grok.textDim)
                    Text(name).font(Grok.mono(12, .semibold)).tracking(0.5).foregroundStyle(Grok.textDim)
                    Text("\(count)").font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(name), \(count) sessions"))
            .accessibilityHint(Text(collapsed.contains(key) ? "Expands the folder" : "Collapses the folder"))

            // Visible, like the row menus — reordering shouldn't be a hidden gesture.
            if !key.isEmpty {
                Menu {
                    Button { app.moveFolder(key, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                    Button { app.moveFolder(key, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                    Button(role: .destructive) { Task { await app.deleteFolder(key) } } label: {
                        Label("Delete folder", systemImage: "folder.badge.minus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Grok.textFaint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Folder options for \(name)"))
            }
        }
        .padding(.vertical, 10)
    }

    private func sessionLink(_ session: SessionInfo) -> some View {
        HStack(spacing: 2) {
            if let onSelect {
                Button { onSelect(session) } label: { SessionRow(session: session) }
                    .buttonStyle(.plain)
            } else {
                NavigationLink(value: session) { SessionRow(session: session) }
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
        .contextMenu { menuItems(session) }
    }

    @ViewBuilder private func menuItems(_ session: SessionInfo) -> some View {
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

struct SessionRow: View {
    let session: SessionInfo

    private var name: String { session.displayName }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(session.id.prefix(8))
                        .font(Grok.mono(11, .medium)).foregroundStyle(Grok.textFaint)
                    if session.isRunning {
                        HStack(spacing: 5) {
                            Circle().fill(Grok.accent).frame(width: 6, height: 6)
                            Text("RUNNING").font(Grok.mono(9, .semibold)).tracking(0.8).foregroundStyle(Grok.accent)
                        }
                    }
                }
                Text(name).font(Grok.sans(16, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                HStack(spacing: 8) {
                    if let cwd = session.cwd, !cwd.isEmpty {
                        Text(cwd).font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Text("· \(session.turnCount) turn\(session.turnCount == 1 ? "" : "s")")
                        .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}
