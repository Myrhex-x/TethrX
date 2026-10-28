import SwiftUI

/// One conversation on the wrist: what Grok is blocked on, what it last said, and
/// the two things worth doing from here, answer or say something.
///
/// Holds an id, not a session. The session itself is looked up in the live snapshot
/// every time, so a request answered on the phone vanishes from this screen too.
struct WatchDetailView: View {
    let sessionId: String
    @EnvironmentObject var store: WatchStore

    @State private var detail: WatchDetail?
    @State private var fetchedAt: Date?
    @State private var working = false
    @State private var loadFailed = false
    /// The request a "Run it anyway" dialog is asking about. The dialog answers this
    /// one and no other, whatever is on screen by the time it is confirmed.
    @State private var confirming: WatchApproval?

    private var session: WatchSession? { store.snapshot.sessions.first { $0.id == sessionId } }
    private var name: String { session?.name ?? detail?.name ?? "" }

    /// Whether the fetched transcript is newer than the snapshot on screen.
    ///
    /// By the phone's clock when the phone says when it read each: the order things
    /// arrive on the watch says nothing about which was read last, and re-sending an
    /// old list made a correct transcript lose to it.
    private var detailIsFresher: Bool {
        guard let detail else { return false }
        if let read = detail.fetchedAt { return read >= store.snapshot.updatedAt }
        guard let fetchedAt else { return false }
        return fetchedAt >= (store.receivedAt ?? .distantPast)
    }

    /// Whichever source is fresher decides whether there is still something to
    /// answer: the fetched transcript knows about a request resolved a second ago,
    /// and a snapshot pushed after that fetch knows about one resolved since. The
    /// content comes from the transcript whenever it describes the same request,
    /// since it has the whole command and the plan's text.
    private var approval: WatchApproval? {
        guard let live = detailIsFresher ? detail?.approval : session?.approval,
              !store.isAnswered(live.requestId) else { return nil }
        if let rich = detail?.approval, rich.requestId == live.requestId { return rich }
        return live
    }
    private var queued: Bool { approval.map { store.queuedAnswers.contains($0.requestId) } ?? false }
    /// Blocked on you, by the same freshness rule as the card, so the status line
    /// never says "Waiting for you" over a request the transcript shows answered.
    /// The snapshot alone can also report a block with nothing to answer it by, from
    /// a bridge too old to send the request id.
    private var waiting: Bool {
        if approval != nil { return true }
        if detailIsFresher { return false }
        return session?.isWaitingOnYou == true
    }
    private var busy: Bool {
        if detailIsFresher, let detail { return detail.busy }
        return session?.isRunning ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // In the content rather than the bar: a session name rarely fits
                // beside the back button, and a title that scrolls past is never
                // readable at once.
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name)
                        .font(.headline)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    status
                }
                if let approval {
                    let card = WatchApprovalCard(approval: approval, queued: queued)
                    if card.hasContent { card }
                }
                if let reply = detail?.lastReply, !reply.isEmpty {
                    block("Grok said", Text(Self.prose(reply)))
                }
                if let asked = detail?.lastUser, !asked.isEmpty {
                    block("You said", Text(verbatim: asked))
                }
                loading
                secondaryActions
                if let error = detail?.error ?? store.errorText {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if DEBUG
        // `-scrollToEnd`: capture the bottom of the screen without a crown.
        .defaultScrollAnchor(ProcessInfo.processInfo.arguments.contains("-scrollToEnd") ? .bottom : nil)
        #endif
        .toolbar { bottomBar }
        .confirmationDialog(
            Text(verbatim: confirming?.risk ?? confirming?.command ?? ""),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { tapped in
            Button("Run it anyway", role: .destructive) {
                Task { await answer(tapped, allow: true) }
            }
        } message: { tapped in
            if tapped.risk != nil {
                Text(verbatim: tapped.command)
            }
        }
        .containerBackground(for: .navigation) {
            WatchBackdrop(alert: waiting)
        }
        // Answered on the phone while the dialog was up, or answered and followed at
        // once by the next request: either way the dialog is about something that is
        // no longer on screen, and must not approve whatever replaced it.
        .onChange(of: approval?.requestId) { _, id in
            if id != confirming?.requestId { confirming = nil }
        }
        // Runs on appearing and again whenever this session's row changes in a pushed
        // snapshot: the request may have been answered, or a new one asked.
        .task(id: session) {
            await load()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-confirmDestructive"), let shown = approval, shown.isDestructive {
                confirming = shown
            }
            // `-autoAnswer allow|deny`: answer the open request as a tap would, to test
            // the round trip to the phone and the computer without a finger.
            if let i = args.firstIndex(of: "-autoAnswer"), i + 1 < args.count, let shown = approval {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await answer(shown, allow: args[i + 1] == "allow")
            }
            #endif
        }
    }

    // MARK: Pieces

    /// Working 2:14 / Waiting for you / Idle.
    private var status: some View {
        HStack(spacing: 5) {
            if waiting {
                Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                Text("Waiting for you")
            } else if busy {
                Image(systemName: "clock")
                Text("Working")
                if let since = session?.since {
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                }
            } else {
                Image(systemName: "moon.zzz")
                Text("Idle")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func block(_ title: LocalizedStringKey, _ text: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            text
                .font(.body)
                .privacySensitive()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var loading: some View {
        if detail == nil {
            if loadFailed {
                (store.reachable
                 ? Text("Couldn't load this conversation.")
                 : Text("Open TethrX on your iPhone to read the conversation."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    /// Dictation, Scribble or an emoji, whatever the watch offers. A bare refusal
    /// makes Grok try a near-identical thing next, so saying why is one action here
    /// rather than two.
    @ViewBuilder private var secondaryActions: some View {
        if let approval, !queued {
            TextFieldLink(prompt: Text("Why not?")) {
                if approval.isPlan {
                    Label("Reject with a reason", systemImage: "text.bubble")
                } else {
                    Label("Deny with a reason", systemImage: "text.bubble")
                }
            } onSubmit: { reason in
                Task { await answer(approval, allow: false, reason: reason) }
            }
            .disabled(working)
            // A new request is a new link: a reason dictated about one request is
            // never delivered as the answer to the next.
            .id(approval.requestId)
        }
        // The text is queued on the computer, so it runs whether or not Grok is busy.
        TextFieldLink(prompt: Text("Message Grok")) {
            Label("Message Grok", systemImage: "mic.fill")
        } onSubmit: { text in
            Task {
                working = true
                _ = await store.reply(sessionId: sessionId, text: text)
                working = false
                await load()
            }
        }
        .disabled(working)
    }

    /// The decision stays on screen without scrolling. A destructive command does
    /// not run on one tap: Allow asks once more, in red.
    @ToolbarContentBuilder private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            if let approval {
                // Nothing to press while an answer from here is on its way: the card
                // says so, and a second tap could only contradict the first.
                if !queued { answerButtons(approval) }
            } else if busy {
                Spacer()
                Button(role: .destructive) {
                    Task {
                        working = true
                        _ = await store.stop(sessionId: sessionId)
                        working = false
                        await store.refresh()
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .tint(.red)
                .disabled(working)
            }
        }
    }

    @ViewBuilder private func answerButtons(_ approval: WatchApproval) -> some View {
        Button {
            Task { await answer(approval, allow: false) }
        } label: {
            if approval.isPlan {
                Label("Reject", systemImage: "xmark")
            } else {
                Label("Deny", systemImage: "xmark")
            }
        }
        .disabled(working)

        Spacer()

        Button {
            if approval.isDestructive {
                confirming = approval
            } else {
                Task { await answer(approval, allow: true) }
            }
        } label: {
            if approval.isPlan {
                Label("Approve", systemImage: "checkmark")
            } else {
                Label("Allow", systemImage: "checkmark")
            }
        }
        .tint(approval.isDestructive ? Color.red : nil)
        .disabled(working || !approval.canAllow)
    }

    // MARK: Plumbing

    private func load() async {
        loadFailed = false
        guard let fresh = await store.detail(for: sessionId) else {
            if detail == nil { loadFailed = true }
            return
        }
        // A request to the phone cannot be called back, so a load superseded while it
        // waited (the session changed) still finishes. It must not replace a newer one.
        if Task.isCancelled, detail != nil { return }
        if let current = detail?.fetchedAt, let read = fresh.fetchedAt, read < current { return }
        detail = fresh
        fetchedAt = Date()
    }

    /// Answer `tapped`, the request the tap or the dictation was about.
    ///
    /// The request on screen can change between a tap and this line: answered on the
    /// phone, and Grok straight on to the next one. Reading `approval` here used to
    /// send the answer to whatever was current by then, which could approve a
    /// destructive command nobody had seen.
    private func answer(_ tapped: WatchApproval, allow: Bool, reason: String? = nil) async {
        guard approval?.requestId == tapped.requestId else { return }
        working = true
        defer { working = false }
        switch await store.answer(sessionId: sessionId, approval: tapped, allow: allow, reason: reason) {
        case .confirmed:
            // The card is already gone (the store hides a confirmed request); the
            // fresh list moves the row out of "Needs you".
            await store.refresh()
        case .queued:
            // The card itself now says "Sent, waiting for your iPhone".
            break
        case .failed, .unknown:
            await load()
        }
    }

    /// Grok writes Markdown. Inline emphasis and code read better rendered; block
    /// syntax (lists, headings) is left as written, which still reads fine.
    private static func prose(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// The request itself: what Grok wants to run (or the plan it drafted), why it
/// deserves a second look, and whether an answer from here is still on its way.
struct WatchApprovalCard: View {
    let approval: WatchApproval
    let queued: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A command speaks for itself in mono; a plan is prose and needs saying.
            // The status line above already says Grok is waiting, so a permission
            // spends no line on it: on a 41mm face that line is the risk's last one.
            if approval.isPlan {
                Label("Plan ready to review", systemImage: "list.bullet.clipboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !approval.command.isEmpty {
                Text(verbatim: approval.command)
                    .font(approval.isPlan ? .footnote : .footnote.monospaced())
                    .privacySensitive()
                    // A command is shown whole: it is what Allow runs, and the end of
                    // one is where the part that matters often is. A plan shows its
                    // start; the phone has the rest.
                    .lineLimit(approval.isPlan ? 12 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The same one-line reason the phone shows. Answering `rm -rf` from a
            // wrist, one-handed, is exactly when it matters most.
            if let risk = approval.risk, !risk.isEmpty {
                Label {
                    Text(verbatim: risk)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: approval.isDestructive ? "exclamationmark.triangle.fill" : "eye")
                }
                .font(.footnote)
                .foregroundStyle(approval.isDestructive ? Color.red : Color.secondary)
            }

            if queued {
                // Answered from here, not yet confirmed by the phone. Showing the
                // buttons again would invite a second, contradictory tap.
                Label("Sent, waiting for your iPhone", systemImage: "arrow.up.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !approval.canAllow {
                Text("This one can only be denied from here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            approval.isDestructive ? AnyShapeStyle(Color.red.opacity(0.22)) : AnyShapeStyle(.quaternary),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// Whether there is anything to put on the card. A bridge that sent no command
    /// and no risk leaves only the buttons, which live in the bar.
    var hasContent: Bool {
        approval.isPlan || !approval.command.isEmpty || approval.risk?.isEmpty == false
            || queued || !approval.canAllow
    }
}
