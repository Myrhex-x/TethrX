import SwiftUI

/// Lists the bridge's Grok sessions and starts new ones. Tapping opens live chat.
struct SessionListView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var lock: AppLock
    @EnvironmentObject var snippets: SnippetStore
    @State private var path: [SessionInfo] = []
    @State private var creating = false
    @State private var renaming: SessionInfo?
    @State private var renameText = ""
    @State private var foldering: SessionInfo?   // session being moved into a new folder
    @State private var folderText = ""
    @State private var collapsed: Set<String> = []
    @State private var query = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    workingDir
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
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(app).environmentObject(lock).environmentObject(snippets)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SessionInfo.self) { session in
                if let client = app.client {
                    ChatView(vm: ChatViewModel(client: client, session: session))
                } else {
                    ZStack { Grok.bg.ignoresSafeArea(); Eyebrow("DISCONNECTED") }
                }
            }
        }
        .task { await app.reloadSessions(); openPending() }
        .onChange(of: app.pendingOpenSessionId) { _, _ in openPending() }
        .onChange(of: app.sessions.count) { _, _ in openPending() }
    }

    /// Debug deep-open (see AppState.handleLaunchArguments).
    private func openPending() {
        guard let id = app.pendingOpenSessionId,
              let session = app.sessions.first(where: { $0.id == id }) else { return }
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
            CircleIconButton(system: "gearshape") { showSettings = true }
            CircleIconButton(system: "plus", filled: true, enabled: !creating) {
                Task { await startNew() }
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: Working directory

    private var workingDir: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow("WORKING DIRECTORY")
            FieldBox {
                TextField("", text: $app.defaultCwd,
                          prompt: Text("/Users/you/project — blank = daemon default").foregroundColor(Grok.textFaint))
                    .font(Grok.mono(13))
                    .foregroundStyle(Grok.text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("New sessions run Grok in this folder. Plan mode, effort, and approvals are set inside each session.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
        }
    }

    // MARK: Sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("SESSIONS")
                Spacer()
                Text("\(app.sessions.count)").font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
            }
            .padding(.bottom, 12)

            if app.sessions.count > 6 { searchField.padding(.bottom, 14) }

            if app.sessions.isEmpty {
                Text("// no sessions yet — tap + to start")
                    .font(Grok.mono(12)).foregroundStyle(Grok.textFaint)
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
                        folderHeader(group.folder.isEmpty ? "Ungrouped" : group.folder,
                                     key: group.folder, count: group.items.count)
                    }
                    if !collapsed.contains(group.folder) {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { Rectangle().fill(Grok.hairline).frame(height: 1) }
                            sessionLink(session)
                        }
                    }
                    if hasFolders { Color.clear.frame(height: 8) }
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
    private var groupedSessions: [(folder: String, items: [SessionInfo])] {
        let groups = Dictionary(grouping: filteredSessions) { ($0.folder?.isEmpty == false) ? $0.folder! : "" }
        var out: [(String, [SessionInfo])] = []
        if let ungrouped = groups[""], !ungrouped.isEmpty { out.append(("", ungrouped)) }
        for name in groups.keys.filter({ !$0.isEmpty }).sorted() { out.append((name, groups[name]!)) }
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
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(Grok.textFaint)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func folderHeader(_ name: String, key: String, count: Int) -> some View {
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
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sessionLink(_ session: SessionInfo) -> some View {
        NavigationLink(value: session) { SessionRow(session: session) }
            .buttonStyle(.plain)
            .contextMenu {
                Button { renameText = session.title; renaming = session } label: { Label("Rename", systemImage: "pencil") }
                moveMenu(session)
                Button(role: .destructive) { Task { await app.deleteSession(session.id) } } label: { Label("Delete", systemImage: "trash") }
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
        if let session = await app.newSession() { path.append(session) }
    }
}

struct SessionRow: View {
    let session: SessionInfo

    private var name: String {
        if let cwd = session.cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return "session"
    }

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
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Grok.textFaint)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }
}
