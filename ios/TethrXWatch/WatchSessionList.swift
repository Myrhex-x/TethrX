import SwiftUI

/// The watch's root: every session on the selected computer, blocked ones first.
struct WatchSessionList: View {
    @EnvironmentObject var store: WatchStore
    @State private var path: [WatchSession] = []
    /// A session a complication asked for, held until it appears in the snapshot.
    @State private var pendingOpenId: String?

    var body: some View {
        NavigationStack(path: $path) {
            content
        }
    }

    private var content: some View {
        List {
            if store.snapshot.sessions.isEmpty {
                emptyState
            } else {
                if store.snapshot.waitingCount > 0 { waitingBanner }
                ForEach(store.snapshot.ordered) { session in
                    NavigationLink(value: session) { row(session) }
                        .listRowBackground(rowBackground(session))
                }
            }
            footer
        }
        .listStyle(.carousel)
        .navigationTitle("TethrX")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: WatchSession.self) { session in
            WatchDetailView(session: session)
        }
        .refreshable { await store.refresh() }
        .task {
            await store.refresh()
            openDebugSession()
        }
        .onChange(of: store.snapshot) { _, _ in
            openDebugSession()
            openPending()
        }
        // The complication reports a block; tapping it has to land on THAT session,
        // not on the list with the answer still a scroll away.
        .onOpenURL { url in open(url) }
    }

    private func open(_ url: URL) {
        guard url.scheme?.lowercased() == "tethrx", url.host?.lowercased() == "session" else { return }
        let id = url.pathComponents.first { $0 != "/" } ?? ""
        guard !id.isEmpty else { return }
        pendingOpenId = id
        openPending()
    }

    /// The complication can be tapped before the snapshot has arrived, so the request
    /// is held until the session it names actually exists.
    private func openPending() {
        guard let id = pendingOpenId,
              let session = store.snapshot.sessions.first(where: { $0.id == id }) else { return }
        pendingOpenId = nil
        if path.last?.id != session.id { path = [session] }
    }

    /// `-openSession <id>` on launch, so a screen deeper than the list can be
    /// captured without a tap. Same hook the phone app uses.
    private func openDebugSession() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openSession"), i + 1 < args.count else { return }
        let id = args[i + 1]
        guard path.isEmpty, let session = store.snapshot.sessions.first(where: { $0.id == id }) else { return }
        path.append(session)
        #endif
    }

    // MARK: Pieces

    private var waitingBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.raised.fill").font(.system(size: 12, weight: .bold))
                .accessibilityHidden(true)
            (store.snapshot.waitingCount == 1
             ? Text("1 needs you")
             : Text("\(store.snapshot.waitingCount) need you"))
                .font(Grok.sans(15, .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Grok.text)
        .padding(.vertical, 4)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 12).fill(Grok.danger.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.danger.opacity(0.45), lineWidth: 1))
        )
    }

    private func row(_ session: WatchSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name)
                .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text)
                .lineLimit(2).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                if session.isWaitingOnYou {
                    Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Grok.text)
                    Text("waiting").font(Grok.mono(11, .semibold)).foregroundStyle(Grok.text)
                } else if session.isRunning {
                    Circle().fill(Grok.accent).frame(width: 5, height: 5)
                    Text("running").font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                } else {
                    (session.turns == 1 ? Text("1 turn") : Text("\(session.turns) turns"))
                        .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                }
                ElapsedLabel(since: session.since)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(session.isWaitingOnYou
                                 ? "\(session.name), waiting for your approval"
                                 : (session.isRunning ? "\(session.name), running" : session.name)))
    }

    private func rowBackground(_ session: WatchSession) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(session.isWaitingOnYou ? Color.white.opacity(0.14) : Grok.raised)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            TethrXMark(size: 24)
            if store.phoneUnreachable {
                Text("Can't reach your iPhone")
                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text)
                Text("Open TethrX on your iPhone once, and keep it nearby.")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
            } else if !store.snapshot.connected {
                Text("No computer connected")
                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text)
                Text("Pair one in TethrX on your iPhone.")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
            } else {
                Text("No sessions yet")
                    .font(Grok.sans(15, .semibold)).foregroundStyle(Grok.text)
                Text("Start one on your iPhone.")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = store.errorText {
                Text(error).font(Grok.mono(10)).foregroundStyle(Grok.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = store.notice {
                Text(notice).font(Grok.mono(10)).foregroundStyle(Grok.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !store.snapshot.computer.isEmpty {
                Eyebrow(text: "computer")
                Text(store.snapshot.computer)
                    .font(Grok.mono(11)).foregroundStyle(Grok.textFaint).lineLimit(1)
                // Being out of touch with the phone is ordinary, and the list above is
                // still true — say it quietly, and only once there is a list to qualify.
                if store.phoneUnreachable {
                    Text("Not live. Open TethrX on your iPhone to refresh.")
                        .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listRowBackground(Color.clear)
    }
}
