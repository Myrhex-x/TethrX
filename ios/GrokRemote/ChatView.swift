import SwiftUI

/// Live conversation for one session, styled as a Grok Build console.
struct ChatView: View {
    @StateObject var vm: ChatViewModel
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var name: String {
        if let cwd = vm.session.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return "session"
    }

    var body: some View {
        ZStack {
            Grok.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                transcript
                composer
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .grokBar()
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 7) {
                    Text(">_").font(Grok.mono(13, .bold)).foregroundStyle(Grok.accent)
                    Text(name).font(Grok.mono(13, .semibold)).foregroundStyle(Grok.text)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    if vm.mode == "plan" {
                        Text("PLAN").font(Grok.mono(9, .bold)).tracking(0.8).foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Grok.accent).clipShape(Capsule())
                    }
                    HStack(spacing: 6) {
                        Circle().fill(vm.live ? Grok.accent : Grok.textFaint).frame(width: 7, height: 7)
                        Text(vm.live ? "LIVE" : "···").font(Grok.mono(10, .medium))
                            .foregroundStyle(vm.live ? Grok.accent : Grok.textFaint)
                    }
                }
            }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(vm.items) { item in
                        switch item.role {
                        case .permission:
                            PermissionCard(item: item) { optionId, always in
                                Task { await vm.decide(item, optionId: optionId, always: always) }
                            }.id(item.id)
                        case .plan:
                            PlanCard(item: item) { approved in
                                Task { await vm.decidePlan(item, approved: approved) }
                            }.id(item.id)
                        default:
                            ChatBubble(item: item).id(item.id)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.items.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: lastText) { _, _ in scrollToBottom(proxy) }
            .task {
                // On open, wait for replayed history to lay out, then jump to the latest.
                try? await Task.sleep(nanoseconds: 450_000_000)
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Grok.hairline).frame(height: 1)
            chatControls
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(">").font(Grok.mono(15, .bold)).foregroundStyle(Grok.accent).padding(.top, 2)
                    TextField("", text: $draft, prompt: Text("message grok…").foregroundColor(Grok.textFaint), axis: .vertical)
                        .font(Grok.mono(14))
                        .foregroundStyle(Grok.text)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Grok.raised)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                if vm.busy {
                    CircleIconButton(system: "stop.fill", danger: true) { Task { await vm.cancel() } }
                } else {
                    CircleIconButton(system: "arrow.up", filled: !isEmptyDraft, enabled: !isEmptyDraft) {
                        let text = draft; draft = ""
                        Task { await vm.send(text) }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Grok.bg)
    }

    // AI-app-style controls right by the composer: plan mode, reasoning effort, auto-approve.
    private var chatControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { Task { await vm.setConfig(planMode: !vm.planMode) } } label: {
                    Label("Plan", systemImage: "list.bullet.clipboard").chip(on: vm.planMode)
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(efforts, id: \.1) { label, value in
                        Button(label) { Task { await vm.setConfig(effort: value) } }
                    }
                } label: {
                    Label(effortLabel, systemImage: "gauge.with.dots.needle.50percent").chip(on: !vm.effort.isEmpty)
                }

                Button { Task { await vm.setConfig(autoApprove: !vm.autoApprove) } } label: {
                    Label(vm.autoApprove ? "Auto-approve" : "Ask each", systemImage: vm.autoApprove ? "bolt.fill" : "hand.raised")
                        .chip(on: vm.autoApprove)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 10)
    }

    private var efforts: [(String, String)] { [("Auto", ""), ("High", "high"), ("Medium", "medium"), ("Low", "low")] }
    private var effortLabel: String { vm.effort.isEmpty ? "Effort" : vm.effort.capitalized }

    private let bottomID = "bottom"
    private var lastText: String { vm.items.last?.text ?? "" }
    private var isEmptyDraft: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) }
    }
}

/// Renders one conversation line in the console style.
struct ChatBubble: View {
    let item: ChatItem

    /// Grok emits Markdown (**bold**, `code`, links). Render inline markdown while
    /// keeping line breaks; fall back to plain text on partial/streaming input.
    static func markdown(_ s: String) -> AttributedString {
        let text = s.isEmpty ? " " : s
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
    }

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(item.text)
                    .font(Grok.sans(15))
                    .foregroundStyle(Grok.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Grok.raised)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("GROK")
                Text(Self.markdown(item.text))
                    .font(Grok.sans(15))
                    .foregroundStyle(Grok.text)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .thought:
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Grok.hairlineStrong).frame(width: 2)
                Text(item.text)
                    .font(Grok.mono(12))
                    .foregroundStyle(Grok.textDim)
                    .lineSpacing(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            ToolLine(item: item)

        case .permission, .plan:
            EmptyView()   // rendered by PermissionCard / PlanCard in the transcript

        case .status:
            Text(item.text)
                .font(Grok.mono(11)).tracking(0.5)
                .foregroundStyle(Grok.textFaint)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)

        case .error:
            HStack(alignment: .top, spacing: 8) {
                Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                Text(item.text).font(Grok.mono(12)).foregroundStyle(Grok.danger).lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.danger.opacity(0.4), lineWidth: 1))
        }
    }
}

/// A tool invocation line with a status glyph (running ▸ / done ✓ / failed ✗).
struct ToolLine: View {
    let item: ChatItem

    private var glyph: String {
        switch item.toolStatus {
        case "completed": return "✓"
        case "failed": return "✗"
        case "running": return "▸"
        default: return "›"
        }
    }
    private var tint: Color { item.toolStatus == "failed" ? Grok.danger : Grok.accent }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(glyph).font(Grok.mono(12, .bold)).foregroundStyle(tint)
            Text(item.text).font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Approval card for a pending permission request. Allow options render as white
/// pills, reject as outline; once decided, the buttons collapse to the outcome.
struct PermissionCard: View {
    let item: ChatItem
    let onDecide: (String?, Bool) -> Void   // (optionId, alwaysAllow)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").font(.system(size: 13, weight: .semibold))
                Eyebrow("PERMISSION", comment: false)
                Spacer()
            }
            .foregroundStyle(Grok.accent)

            Text(item.text)
                .font(Grok.mono(13))
                .foregroundStyle(Grok.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let decided = item.decided {
                Text(outcomeLabel(decided))
                    .font(Grok.mono(12, .semibold))
                    .foregroundStyle(Grok.textDim)
            } else {
                VStack(spacing: 8) {
                    if let allow = item.options.first(where: { $0.isAllow }) {
                        Button { onDecide(allow.optionId, false) } label: {
                            Text(allow.name).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .buttonStyle(PillButton(kind: .prominent))
                        Button { onDecide(allow.optionId, true) } label: {
                            Label("Always allow", systemImage: "bolt.fill").lineLimit(1)
                        }
                        .buttonStyle(PillButton(kind: .subtle))
                    }
                    ForEach(item.options.filter { !$0.isAllow }) { opt in
                        Button { onDecide(opt.optionId, false) } label: {
                            Text(opt.name).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .buttonStyle(PillButton(kind: .subtle))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func outcomeLabel(_ optionId: String) -> String {
        if optionId == "cancelled" { return "— cancelled —" }
        if let opt = item.options.first(where: { $0.optionId == optionId }) {
            return (opt.isAllow ? "✓ " : "✗ ") + opt.name
        }
        return "✓ responded"
    }
}

/// Plan-mode review card: Grok's drafted plan (markdown) with Approve & build /
/// Keep planning. Collapses to the outcome once decided.
struct PlanCard: View {
    let item: ChatItem
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard.fill").font(.system(size: 13, weight: .semibold))
                Eyebrow("PLAN", comment: false)
                Spacer()
            }
            .foregroundStyle(Grok.accent)

            Text(ChatBubble.markdown(item.text))
                .font(Grok.sans(14))
                .foregroundStyle(Grok.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let decided = item.decided {
                Text(decided == "approved" ? "✓ Approved — building" : "✗ Kept planning")
                    .font(Grok.mono(12, .semibold)).foregroundStyle(Grok.textDim)
            } else {
                VStack(spacing: 8) {
                    Button { onDecide(true) } label: { Text("Approve & build").frame(maxWidth: .infinity) }
                        .buttonStyle(PillButton(kind: .prominent))
                    Button { onDecide(false) } label: { Text("Keep planning").frame(maxWidth: .infinity) }
                        .buttonStyle(PillButton(kind: .subtle))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
