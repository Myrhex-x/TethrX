import SwiftUI

/// One conversation on the wrist: the approval it is blocked on, the last few
/// lines, and the two things worth doing from here — answer, or say something.
struct WatchDetailView: View {
    let session: WatchSession
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss

    @State private var detail: WatchDetail?
    @State private var working = false
    @State private var loadFailed = false

    /// The block to answer. The fetched transcript is better (it knows if the request
    /// was already resolved), but the snapshot's copy arrives without a live phone,
    /// which is exactly when a watch earns its place.
    private var approval: WatchApproval? {
        if let detail { return detail.approval }
        return session.approval
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let approval { approvalCard(approval) }
                transcript
                actions
                if let error = detail?.error ?? store.errorText {
                    Text(error).font(Grok.mono(10)).foregroundStyle(Grok.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 8)
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: The approval

    private func approvalCard(_ approval: WatchApproval) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: approval.isDestructive ? "exclamationmark.octagon.fill" : "lock.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Eyebrow(text: approval.isDestructive ? "destructive" : "permission")
                Spacer(minLength: 0)
            }
            .foregroundStyle(approval.isDestructive ? Grok.danger : Grok.accent)

            Text(approval.command)
                .font(Grok.mono(13)).foregroundStyle(Grok.text)
                .fixedSize(horizontal: false, vertical: true)

            // The same one-line reason the phone shows. Answering `rm -rf` from a
            // wrist, one-handed, is exactly when it matters most.
            if let risk = approval.risk {
                Text(risk)
                    .font(Grok.mono(11))
                    .foregroundStyle(approval.isDestructive ? Grok.danger : Grok.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.queuedAnswers.contains(approval.requestId) {
                // Answered from here, not yet confirmed by the phone. Showing the
                // buttons again would invite a second, contradictory tap.
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle").font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Sent, waiting for your iPhone")
                        .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    Task { await decide(approval.allowOptionId, on: approval) }
                } label: {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(WatchPill(kind: approval.isDestructive ? .subtle : .prominent))
                .disabled(working)

                Button {
                    Task { await decide(approval.denyOptionId, on: approval) }
                } label: {
                    Label("Deny", systemImage: "xmark")
                }
                .buttonStyle(WatchPill(kind: .danger))
                .disabled(working)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(approval.isDestructive ? Grok.danger.opacity(0.12) : Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(approval.isDestructive ? Grok.danger.opacity(0.45) : Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: The tail of the conversation

    @ViewBuilder private var transcript: some View {
        if let lines = detail?.lines, !lines.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(lines) { line in
                    switch line.kind {
                    case "user":
                        Text(line.text)
                            .font(Grok.sans(13)).foregroundStyle(Grok.text)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Grok.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    case "tool":
                        HStack(alignment: .top, spacing: 5) {
                            Text(verbatim: "›").font(Grok.mono(11, .bold)).foregroundStyle(Grok.accent)
                            Text(line.text).font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                                .lineLimit(2)
                        }
                    case "error":
                        Text(line.text).font(Grok.mono(11)).foregroundStyle(Grok.danger)
                    default:
                        Text(line.text)
                            .font(Grok.sans(13)).foregroundStyle(Grok.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        } else if loadFailed {
            Text("Couldn't load this conversation.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
        } else if detail == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("loading…").font(Grok.mono(11)).foregroundStyle(Grok.textDim)
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Nothing said yet.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
        }
    }

    // MARK: What you can do from here

    @ViewBuilder private var actions: some View {
        VStack(spacing: 8) {
            // Dictation, scribble or an emoji — whatever the watch offers. The text is
            // queued on the computer, so it runs whether or not grok is busy now.
            TextFieldLink(prompt: Text("Message Grok")) {
                Label(detail?.busy == true ? "Queue a follow-up" : "Send a message", systemImage: "mic.fill")
            } onSubmit: { text in
                Task {
                    working = true
                    _ = await store.reply(sessionId: session.id, text: text)
                    working = false
                    await load()
                }
            }
            .buttonStyle(WatchPill(kind: .subtle))
            .disabled(working)

            if detail?.busy == true {
                Button {
                    Task {
                        working = true
                        _ = await store.stop(sessionId: session.id)
                        working = false
                        await load()
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(WatchPill(kind: .danger))
                .disabled(working)
            }
        }
    }

    // MARK: Plumbing

    private func load() async {
        loadFailed = false
        guard let fresh = await store.detail(for: session.id) else {
            loadFailed = true
            return
        }
        detail = fresh
    }

    /// Answer, then refresh: the card has to disappear, or it looks like the tap
    /// did nothing.
    private func decide(_ optionId: String?, on approval: WatchApproval) async {
        working = true
        defer { working = false }
        let ok = await store.decide(sessionId: session.id, requestId: approval.requestId, optionId: optionId)
        if ok {
            detail?.approval = nil
            await store.refresh()
        }
        await load()
    }
}
