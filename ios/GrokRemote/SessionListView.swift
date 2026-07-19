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

            if app.sessions.isEmpty {
                Text("// no sessions yet — tap + to start")
                    .font(Grok.mono(12)).foregroundStyle(Grok.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(app.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Rectangle().fill(Grok.hairline).frame(height: 1) }
                    NavigationLink(value: session) { SessionRow(session: session) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { renameText = session.title; renaming = session } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { Task { await app.deleteSession(session.id) } } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
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
