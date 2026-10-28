import SwiftUI

/// The watch's root: every session on the selected computer, the ones blocked on you
/// first, in a plain list like Mail's.
struct WatchSessionList: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.scenePhase) private var scenePhase
    /// Ids, not sessions: the detail looks its session up in the live snapshot, so a
    /// request answered elsewhere disappears from a screen that is already open.
    @State private var path: [String] = []
    /// A session a complication asked for, held until it appears in the snapshot.
    @State private var pendingOpenId: String?
    /// Whether the first snapshot with anything in it has been looked at, so the
    /// launch rule below runs once per launch rather than on every update.
    @State private var launchDecided = false
    /// The request this list last opened on its own. Backing out of it is a choice,
    /// and coming back to the app must not undo it.
    @State private var autoOpened: String?
    @State private var debugOpened = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("TethrX")
                .navigationDestination(for: String.self) { id in
                    WatchDetailView(sessionId: id)
                }
                .containerBackground(for: .navigation) {
                    WatchBackdrop(alert: store.snapshot.waitingCount > 0)
                }
        }
        .task {
            // Decided on what is already here (the pushed snapshot) before asking the
            // phone for anything, so the wrist lands on the request without a pause.
            openDebugSession()
            decideLaunch()
            await store.refresh()
        }
        .onChange(of: store.snapshot) { _, _ in
            openDebugSession()
            openPending()
            decideLaunch()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Coming back to the app is a launch as far as the wrist is concerned.
            openSoleRequest()
            Task { await store.refresh() }
        }
        // The complication reports a block; tapping it has to land on THAT session,
        // not on the list with the answer still a scroll away.
        .onOpenURL { url in open(url) }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if store.snapshot.sessions.isEmpty {
            // Scrollable, so the instruction is never cut off at the largest text
            // sizes on the smallest watch.
            ScrollView {
                emptyState
                    .frame(maxWidth: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                List {
                    section("Needs you", store.snapshot.needsYou)
                    section("Running", store.snapshot.running)
                    section("Recent", store.snapshot.recent)
                    footer.id("footer")
                }
                #if DEBUG
                // `-scrollToEnd`: capture the bottom of the list without a crown.
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("-scrollToEnd") else { return }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    proxy.scrollTo("footer", anchor: .bottom)
                }
                #endif
            }
        }
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey, _ sessions: [WatchSession]) -> some View {
        if !sessions.isEmpty {
            Section(title) {
                ForEach(sessions) { session in
                    NavigationLink(value: session.id) { WatchSessionRow(session: session) }
                }
            }
        }
    }

    /// How old the list is, and the one failure worth a line.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = store.errorText {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.receivedAt != nil {
                // The phone's own timestamp: a snapshot delivered late is as old as
                // the moment it was taken, not the moment it arrived.
                Text("Updated \(Text(store.snapshot.updatedAt, style: .relative)) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var emptyState: some View {
        if !store.hasEverReceived {
            if store.lookingForPhone {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("Open TethrX on your iPhone once", systemImage: "iphone")
                } description: {
                    Text("Your watch gets its list from there.")
                }
            }
        } else if !store.snapshot.connected {
            ContentUnavailableView {
                Label("No computer paired", systemImage: "desktopcomputer")
            } description: {
                Text("Pair one in TethrX on your iPhone.")
            }
        } else {
            ContentUnavailableView {
                Label("Nothing running", systemImage: "moon.zzz")
            } description: {
                Text("Start one on your iPhone.")
            }
        }
    }

    // MARK: Opening a session

    private func open(_ url: URL) {
        guard url.scheme?.lowercased() == "tethrx", url.host?.lowercased() == "session" else { return }
        let id = url.pathComponents.first { $0 != "/" } ?? ""
        guard !id.isEmpty else { return }
        launchDecided = true
        pendingOpenId = id
        openPending()
    }

    /// The complication can be tapped before the snapshot has arrived, so the request
    /// is held until the session it names actually exists.
    private func openPending() {
        guard let id = pendingOpenId,
              store.snapshot.sessions.contains(where: { $0.id == id }) else { return }
        pendingOpenId = nil
        if path != [id] { path = [id] }
    }

    /// Decided once, on the first snapshot that has anything in it.
    private func decideLaunch() {
        guard !launchDecided, !store.snapshot.sessions.isEmpty else { return }
        launchDecided = true
        openSoleRequest()
    }

    /// Exactly one thing waiting is the common case, and the whole reason the wrist
    /// was raised: open on it, through the same path the complication's link takes.
    /// Only from the list, and never twice for the same request.
    private func openSoleRequest() {
        guard path.isEmpty, pendingOpenId == nil else { return }
        let waiting = store.snapshot.needsYou
        guard waiting.count == 1, let only = waiting.first else { return }
        let key = only.approval?.requestId ?? only.id
        guard key != autoOpened else { return }
        autoOpened = key
        path = [only.id]
    }

    /// `-openSession <id>` on launch, so a screen deeper than the list can be
    /// captured without a tap. Same hook the phone app uses.
    private func openDebugSession() {
        #if DEBUG
        guard !debugOpened else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openSession"), i + 1 < args.count else { return }
        let id = args[i + 1]
        guard store.snapshot.sessions.contains(where: { $0.id == id }) else { return }
        debugOpened = true
        launchDecided = true
        path = [id]
        #endif
    }
}

/// One session: its name, and on the second line what it is doing and for how long.
struct WatchSessionRow: View {
    let session: WatchSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if session.isWaitingOnYou {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        // Sits on the first line's x-height rather than its baseline.
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
                        .accessibilityHidden(true)
                }
                Text(session.name)
                    .font(.headline)
                    .lineLimit(2)
            }
            HStack(spacing: 4) {
                if session.isWaitingOnYou {
                    Image(systemName: session.waitingKind == "plan" ? "list.bullet.clipboard" : "hand.raised.fill")
                    if let since = session.since {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    } else {
                        Text("Waiting")
                    }
                } else if session.isRunning {
                    Image(systemName: "clock")
                    if let since = session.since {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                    } else {
                        Text("Working")
                    }
                } else if let last = session.lastActivity {
                    Image(systemName: "moon.zzz")
                    Text("\(Text(last, style: .relative)) ago")
                } else {
                    Image(systemName: "moon.zzz")
                    if session.turns == 1 { Text("1 turn") } else { Text("\(session.turns) turns") }
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    /// Built as separate `Text`s rather than one ternary, because a ternary that
    /// mixes a literal with `session.name` resolves as a plain String and is never
    /// translated.
    private var label: Text {
        if session.isWaitingOnYou { return Text("\(session.name), waiting for your approval") }
        if session.isRunning { return Text("\(session.name), running") }
        return Text(verbatim: session.name)
    }
}

/// The navigation background: a quiet grey, or a red cast when something is waiting,
/// so the state reads before a single word does.
struct WatchBackdrop: View {
    var alert: Bool

    var body: some View {
        LinearGradient(
            colors: alert
                ? [Color.red.opacity(0.45), Color.red.opacity(0.08)]
                : [Color.gray.opacity(0.32), Color.gray.opacity(0.05)],
            startPoint: .top, endPoint: .bottom
        )
        .animation(.easeInOut(duration: 0.3), value: alert)
    }
}
