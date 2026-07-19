import SwiftUI
import UIKit

/// Live conversation for one session, styled as a Grok Build console.
struct ChatView: View {
    @StateObject var vm: ChatViewModel
    @EnvironmentObject var snippets: SnippetStore
    @StateObject private var dictation = Dictation()
    @State private var draft = ""
    @State private var showDetails = false
    @State private var atBottom = true
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
                    TethrXMark(size: 15)
                    Text(name).font(Grok.mono(13, .semibold)).foregroundStyle(Grok.text)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    Button { showDetails = true } label: {
                        Image(systemName: "chart.bar.doc.horizontal").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Grok.textDim)
                    .accessibilityLabel("Session details")

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
        .sheet(isPresented: $showDetails) { SessionDetailsSheet(vm: vm) }
    }

    private var transcript: some View {
        GeometryReader { outer in
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
                                    .contextMenu { copyButton(item.text) }
                            }
                        }
                        if showTyping { TypingIndicator().id("typing") }
                        Color.clear.frame(height: 1).id(bottomID)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: BottomOffsetKey.self,
                                                       value: g.frame(in: .named("transcript")).minY)
                            })
                    }
                    .padding(18)
                }
                .coordinateSpace(name: "transcript")
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onPreferenceChange(BottomOffsetKey.self) { minY in
                    let bottom = minY <= outer.size.height + 80
                    if bottom != atBottom { atBottom = bottom }
                }
                .onChange(of: vm.items.count) { _, _ in if atBottom { scrollToBottom(proxy) } }
                .onChange(of: lastText) { _, _ in if atBottom { scrollToBottom(proxy) } }
                .onChange(of: vm.busy) { _, _ in if atBottom { scrollToBottom(proxy) } }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom { jumpButton(proxy) }
                }
            }
        }
    }

    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Grok.text)
                .frame(width: 40, height: 40)
                .background(Grok.raisedPressed, in: Circle())
                .overlay(Circle().stroke(Grok.hairlineStrong, lineWidth: 1))
        }
        .padding(.trailing, 16).padding(.bottom, 12)
    }

    @ViewBuilder private func copyButton(_ text: String) -> some View {
        if !text.isEmpty {
            Button { UIPasteboard.general.string = text; Haptics.tap() } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Grok.hairline).frame(height: 1)
            queuedRow
            snippetsRow
            chatControls
            commandPalette
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(">").font(Grok.mono(15, .bold)).foregroundStyle(Grok.accent).padding(.top, 2)
                    TextField("", text: $draft,
                              prompt: Text(vm.busy ? "queue a follow-up…" : "message grok…").foregroundColor(Grok.textFaint),
                              axis: .vertical)
                        .font(Grok.mono(14))
                        .foregroundStyle(Grok.text)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                    if dictation.supported {
                        Button { dictation.toggle(base: draft) } label: {
                            Image(systemName: dictation.isRecording ? "waveform" : "mic")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(dictation.isRecording ? Grok.accent : Grok.textDim)
                                .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                        }
                        .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Grok.raised)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(dictation.isRecording ? Grok.accent.opacity(0.5) : Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                trailingButtons
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Grok.bg)
        .onChange(of: dictation.transcript) { _, v in if dictation.isRecording { draft = v } }
    }

    // Send when idle; when a turn is running, queue the draft (＋) or stop (■).
    @ViewBuilder private var trailingButtons: some View {
        if vm.busy {
            HStack(spacing: 8) {
                if !isEmptyDraft {
                    CircleIconButton(system: "arrow.up") {
                        vm.enqueue(draft); draft = ""; Haptics.tap()
                    }
                }
                CircleIconButton(system: "stop.fill", danger: true) { Task { await vm.cancel() } }
            }
        } else {
            CircleIconButton(system: "arrow.up", filled: !isEmptyDraft, enabled: !isEmptyDraft) {
                if dictation.isRecording { dictation.stop() }
                let text = draft; draft = ""
                Task { await vm.send(text) }
            }
        }
    }

    // Queued follow-ups waiting for the current turn to finish; tap × to drop one.
    @ViewBuilder private var queuedRow: some View {
        if !vm.queued.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(vm.queued.enumerated()), id: \.offset) { i, msg in
                        HStack(spacing: 6) {
                            Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                            Text(msg.count > 22 ? String(msg.prefix(22)) + "…" : msg).lineLimit(1)
                            Button { vm.queued.remove(at: i) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                        }
                        .font(Grok.mono(11, .medium))
                        .foregroundStyle(Grok.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.top, 10)
        }
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

                // Live context-window meter — tap for full session usage.
                if let u = vm.usage, u.contextWindow > 0 {
                    Button { showDetails = true } label: {
                        Label("\(Int(u.contextFraction * 100))% ctx", systemImage: "gauge.with.needle").chip(on: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 10)
    }

    // Tappable reusable prompts, shown above the composer while the draft is empty.
    @ViewBuilder private var snippetsRow: some View {
        if isEmptyDraft && !snippets.items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(snippets.items.enumerated()), id: \.offset) { _, s in
                        Button {
                            draft = s
                            composerFocused = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "text.badge.plus").font(.system(size: 9, weight: .semibold))
                                Text(s.count > 26 ? String(s.prefix(26)) + "…" : s)
                            }.chip(on: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.top, 10)
        }
    }

    // Grok Build slash commands (/compact, /context, skills…). Appears above the
    // composer while the draft is a "/…" token, filtered by prefix — like the TUI menu.
    @ViewBuilder private var commandPalette: some View {
        let matches = matchingCommands
        if !matches.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { cmd in
                        Button { insertCommand(cmd) } label: { commandRow(cmd) }
                            .buttonStyle(.plain)
                        if cmd.id != matches.last?.id {
                            Rectangle().fill(Grok.hairline).frame(height: 1).padding(.leading, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: 190)
            .background(Grok.raised)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairlineStrong, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }

    private func commandRow(_ cmd: SlashCommand) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cmd.display).font(Grok.mono(13, .semibold)).foregroundStyle(Grok.accent)
                    if cmd.scope != "builtin" {
                        Text("skill").font(Grok.mono(8, .bold)).tracking(0.5).foregroundStyle(Grok.textFaint)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
                    }
                }
                if !cmd.description.isEmpty {
                    Text(cmd.description).font(Grok.mono(10)).foregroundStyle(Grok.textDim)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 0)
            if cmd.takesArgs {
                Image(systemName: "text.cursor").font(.system(size: 10)).foregroundStyle(Grok.textFaint)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Commands matching the current "/…" draft token (empty unless typing a command).
    private var matchingCommands: [SlashCommand] {
        guard draft.hasPrefix("/"), !vm.commands.isEmpty else { return [] }
        let afterSlash = draft.dropFirst()
        if afterSlash.contains(" ") { return [] }          // args started — stop suggesting
        let q = afterSlash.lowercased()
        let sorted = vm.commands.sorted {
            ($0.scope == "builtin" ? 0 : 1, $0.name) < ($1.scope == "builtin" ? 0 : 1, $1.name)
        }
        return q.isEmpty ? sorted : sorted.filter { $0.name.lowercased().hasPrefix(q) }
    }

    private func insertCommand(_ cmd: SlashCommand) {
        Haptics.tap()
        draft = cmd.takesArgs ? cmd.display + " " : cmd.display
        composerFocused = true
    }

    /// Show the animated "grok is thinking" dots while busy and no text is streaming yet.
    private var showTyping: Bool {
        guard vm.busy else { return false }
        switch vm.items.last?.role {
        case .assistant, .thought: return false
        default: return true
        }
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

/// Tracks the bottom marker's position in the scroll viewport, so the chat view
/// can show a "jump to latest" button once the user scrolls up from the bottom.
private struct BottomOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Animated three-dot "grok is thinking…" indicator, shown while a turn is in
/// flight and no text has streamed yet — mirrors the terminal TUI's typing dots.
struct TypingIndicator: View {
    @State private var animating = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("GROK")
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Grok.textDim)
                        .frame(width: 6, height: 6)
                        .opacity(animating ? 1 : 0.22)
                        .scaleEffect(animating ? 1 : 0.7)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18), value: animating)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(glyph).font(Grok.mono(12, .bold)).foregroundStyle(tint)
                Text(item.text).font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if let diff = item.diff {
                Rectangle().fill(Grok.hairline).frame(height: 1)
                DiffView(diff: diff)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Monochrome before/after diff for an edit tool call (removed = red −, added = white +).
struct DiffView: View {
    let diff: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(Grok.textFaint)
                Text(diff.filename).font(Grok.mono(10, .medium)).foregroundStyle(Grok.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
            ForEach(Array(diff.oldLines.enumerated()), id: \.offset) { _, l in row("−", l, removed: true) }
            ForEach(Array(diff.newLines.enumerated()), id: \.offset) { _, l in row("+", l, removed: false) }
        }
        .padding(.bottom, 8)
    }

    private func row(_ marker: String, _ text: String, removed: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker).font(Grok.mono(11, .bold))
                .foregroundStyle(removed ? Grok.danger : Grok.text).frame(width: 10, alignment: .leading)
            Text(text.isEmpty ? " " : text)
                .font(Grok.mono(11))
                .foregroundStyle(removed ? Grok.danger.opacity(0.85) : Grok.text)
                .strikethrough(removed, color: Grok.danger.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
        .background(removed ? Grok.danger.opacity(0.10) : Color.white.opacity(0.06))
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

/// Per-session usage + technical detail: live context-window meter, token
/// breakdown (incl. thinking), cost, and the session's configuration.
struct SessionDetailsSheet: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    private var u: SessionUsage { vm.usage ?? SessionUsage() }
    private var session: SessionInfo { vm.session }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    context
                    tokens
                    technical
                }
                .padding(20)
            }
            .background(Grok.bg)
            .scrollIndicators(.hidden)
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .grokBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Grok.text).fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("CONTEXT WINDOW")
            if u.contextWindow > 0 {
                UsageBar(fraction: u.contextFraction)
                HStack {
                    Text("\(Fmt.tokens(u.contextTokens)) / \(Fmt.tokens(u.contextWindow))")
                        .font(Grok.mono(13, .semibold)).foregroundStyle(Grok.text)
                    Spacer()
                    Text("\(Int(u.contextFraction * 100))% used · \(Fmt.tokens(u.contextRemaining)) left")
                        .font(Grok.mono(11)).foregroundStyle(Grok.textDim)
                }
            } else {
                Text("Send a message to see context usage.")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
            }
        }
    }

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("THIS SESSION")
            row("Total tokens", Fmt.tokens(u.totalTokens))
            row("Input", Fmt.tokens(u.inputTokens))
            row("Output", Fmt.tokens(u.outputTokens))
            row("Thinking", Fmt.tokens(u.reasoningTokens))
            row("Cached read", Fmt.tokens(u.cachedReadTokens))
            Rectangle().fill(Grok.hairline).frame(height: 1).padding(.vertical, 2)
            row("Turns", "\(u.turns)")
            row("Est. cost", Fmt.cost(u.costUSD))
            row("Compute time", Fmt.duration(u.apiDurationMs))
            Text("Cost is grok's own reported estimate.")
                .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
        }
    }

    private var technical: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("TECHNICAL")
            row("Model", u.lastModelId.isEmpty ? (session.model?.isEmpty == false ? session.model! : "grok default") : u.lastModelId)
            row("Reasoning effort", vm.effort.isEmpty ? "auto" : vm.effort)
            row("Plan mode", vm.planMode ? "on" : "off")
            row("Auto-approve", vm.autoApprove ? "on" : "off")
            row("Transport", session.transport ?? "acp")
            row("Directory", session.cwd.map { ($0 as NSString).lastPathComponent } ?? "—")
            row("Session ID", String(session.id.prefix(8)))
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(Grok.mono(12)).foregroundStyle(Grok.textDim)
            Spacer()
            Text(v).font(Grok.mono(12)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Thin horizontal fill meter (0…1), white on a raised track.
struct UsageBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Grok.raised)
                Capsule().fill(Grok.accent)
                    .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
        .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
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
