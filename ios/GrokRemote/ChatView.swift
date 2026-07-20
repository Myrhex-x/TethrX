import SwiftUI
import UIKit
import PhotosUI

/// Live conversation for one session, styled as a Grok Build console.
struct ChatView: View {
    @StateObject var vm: ChatViewModel
    @EnvironmentObject var snippets: SnippetStore
    @StateObject private var dictation = Dictation()
    @State private var draft = ""
    @State private var showDetails = false
    @State private var showGit = false
    @State private var showFiles = false
    @State private var atBottom = true
    @FocusState private var composerFocused: Bool

    // Image attachments waiting in the composer (JPEG data + display thumbnails).
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var attachments: [Data] = []
    @State private var attachmentThumbs: [UIImage] = []

    private var name: String { vm.session.displayName }

    var body: some View {
        ZStack {
            Grok.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                actionStrip
                transcript
                errorBanner
                composer
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .grokBar()
        // No trailing toolbar items AT ALL: on iOS 26 the system wraps them in a
        // liquid-glass capsule, and three bare icons + a badge + a dot squeezed
        // into one pill read as broken. The actions live in `actionStrip` below,
        // as labeled buttons; the live dot rides next to the title.
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    HStack(spacing: 7) {
                        TethrXMark(size: 15)
                        Text(name).font(Grok.mono(13, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                        Circle().fill(vm.live ? Grok.accent : Grok.textFaint).frame(width: 6, height: 6)
                            .accessibilityLabel(vm.live ? "Connected" : "Reconnecting")
                    }
                    // Context and tokens live here so they're readable at a glance,
                    // rather than only inside the details sheet.
                    if let u = vm.usage, u.contextWindow > 0 {
                        Text("\(Int(u.contextFraction * 100))% ctx · \(Fmt.tokens(u.totalTokens)) tok")
                            .font(Grok.mono(9))
                            .foregroundStyle(u.contextFraction > 0.85 ? Grok.danger : Grok.textFaint)
                    }
                }
            }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        .sheet(isPresented: $showDetails) { SessionDetailsSheet(vm: vm) }
        .sheet(isPresented: $showGit) { GitReviewSheet(client: vm.client, session: vm.session) }
        .sheet(isPresented: $showFiles) { FileBrowserSheet(client: vm.client, session: vm.session) }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPicked(items) }
        }
        .alert("Microphone access needed", isPresented: $dictation.denied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To dictate messages, allow Microphone and Speech Recognition for TethrX in Settings.")
        }
    }

    // The session's places, as plainly labeled buttons in the app's own chip
    // language — Files (project tree), Changes (git), Session (usage/details).
    private var actionStrip: some View {
        HStack(spacing: 8) {
            stripButton("Files") { showFiles = true }
            stripButton("Changes") { showGit = true }
            stripButton("Session") { showDetails = true }
            Spacer(minLength: 0)
            if vm.mode == "plan" {
                Text("PLAN").font(Grok.mono(9, .bold)).tracking(0.8).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Grok.accent).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }

    private func stripButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: { Text(title).chip(on: false) }
            .buttonStyle(.plain)
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
                                    .contextMenu {
                                        copyButton(item.text)
                                        if item.role == .user, !item.text.isEmpty {
                                            Button {
                                                draft = item.text
                                                composerFocused = true
                                            } label: {
                                                Label("Edit & resend", systemImage: "arrow.uturn.left")
                                            }
                                        }
                                    }
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
            attachmentsRow
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
                    // Attach a screenshot or photo; grok views the saved file.
                    if !vm.busy {
                        PhotosPicker(selection: $pickedItems, maxSelectionCount: 3, matching: .images) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(attachments.isEmpty ? Grok.textDim : Grok.accent)
                        }
                        .padding(.top, 1)
                    }
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

    // Failures here used to be written to vm.errorMessage and never shown, so a
    // decision that didn't reach the bridge looked like it had worked.
    @ViewBuilder private var errorBanner: some View {
        if let message = vm.errorMessage {
            HStack(alignment: .top, spacing: 8) {
                Text("!").font(Grok.mono(12, .bold)).foregroundStyle(Grok.danger)
                Text(message).font(Grok.mono(12)).foregroundStyle(Grok.danger).lineSpacing(2)
                Spacer(minLength: 0)
                Button { vm.errorMessage = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Grok.textFaint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Grok.danger.opacity(0.10))
            .overlay(Rectangle().fill(Grok.danger.opacity(0.3)).frame(height: 1), alignment: .top)
        }
    }

    // Send when idle; when a turn is running, queue the draft (＋) or stop (■).
    @ViewBuilder private var trailingButtons: some View {
        if vm.busy {
            HStack(spacing: 8) {
                if !isEmptyDraft {
                    CircleIconButton(system: "arrow.up") {
                        // Must stop dictation here too, or the recogniser's next partial
                        // result refills the composer with the message just queued.
                        if dictation.isRecording { dictation.stop() }
                        vm.enqueue(draft); draft = ""; Haptics.tap()
                    }
                }
                CircleIconButton(system: "stop.fill", danger: true) { Task { await vm.cancel() } }
            }
        } else {
            let sendable = !isEmptyDraft || !attachments.isEmpty
            CircleIconButton(system: "arrow.up", filled: sendable, enabled: sendable) {
                submit(draft)
            }
        }
    }

    // Images attached to the draft, shown as removable thumbnails.
    @ViewBuilder private var attachmentsRow: some View {
        if !attachmentThumbs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(attachmentThumbs.enumerated()), id: \.offset) { i, img in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairlineStrong, lineWidth: 1))
                            Button {
                                if attachments.indices.contains(i) { attachments.remove(at: i) }
                                if attachmentThumbs.indices.contains(i) { attachmentThumbs.remove(at: i) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white, .black.opacity(0.7))
                            }
                            .offset(x: 6, y: -6)
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
            }
        }
    }

    /// Downscale + JPEG-compress the picked photos so a 12MP shot doesn't ship
    /// as 8MB of base64 over the hotspot.
    private func loadPicked(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard attachments.count < 3,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            let scaled = Self.downscale(image, maxDimension: 1600)
            guard let jpeg = scaled.jpegData(compressionQuality: 0.72) else { continue }
            attachments.append(jpeg)
            attachmentThumbs.append(scaled)
        }
        pickedItems = []
        if !attachments.isEmpty { Haptics.tap() }
    }

    static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
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
                            // The index is captured at render time while the queue is
                            // drained from the stream task — check it's still valid.
                            Button { if vm.queued.indices.contains(i) { vm.queued.remove(at: i) } } label: {
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

                // (The context meter moved under the session title, where it's always visible.)
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
        let usable = sorted.filter { $0.isUsable }   // don't offer commands grok ignores
        return q.isEmpty ? usable : usable.filter { $0.name.lowercased().hasPrefix(q) }
    }

    /// Route a typed message: skills go to grok, the built-ins the app can do itself are
    /// handled here, and the inert ones say so instead of silently doing nothing.
    private func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if dictation.isRecording { dictation.stop() }

        // With images attached this is a normal prompt, never a slash command.
        if !attachments.isEmpty {
            let images = attachments
            let thumbs = attachmentThumbs
            attachments = []
            attachmentThumbs = []
            draft = ""
            Task { await vm.send(text, images: images, thumbnails: thumbs) }
            return
        }

        if text.hasPrefix("/") {
            let parts = text.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts.first ?? "")
            let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
            if let command = vm.commands.first(where: { $0.name == name }) {
                switch command.action {
                case .openDetails:
                    draft = ""; showDetails = true; return
                case .autoApprove:
                    draft = ""
                    let on = argument.lowercased() != "off"
                    Task { await vm.setConfig(autoApprove: on) }
                    return
                case .unsupported:
                    vm.errorMessage = "Grok only runs /\(name) inside its own terminal, so it does nothing from here."
                    return
                case .send:
                    break
                }
            }
        }
        draft = ""
        Task { await vm.send(text) }
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

    /// One run of a message: either prose (inline markdown) or a fenced code block.
    struct Segment {
        let isCode: Bool
        let language: String
        let text: String
    }

    /// Split a (possibly still-streaming) message on ``` fences so code renders as a
    /// real block instead of collapsing into inline text.
    static func segments(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var inCode = false
        var language = ""
        var buf: [String] = []

        func flush() {
            let text = buf.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(Segment(isCode: inCode, language: language, text: text))
            }
            buf = []
        }

        for line in s.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if inCode {
                    inCode = false
                    language = ""
                } else {
                    inCode = true
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else {
                buf.append(line)
            }
        }
        flush()
        return out.isEmpty ? [Segment(isCode: false, language: "", text: s)] : out
    }

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                VStack(alignment: .trailing, spacing: 8) {
                    if !item.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(item.images.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img)
                                    .resizable().scaledToFill()
                                    .frame(width: 110, height: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairlineStrong, lineWidth: 1))
                            }
                        }
                    } else if item.imageCount > 0 {
                        // Replayed history: the pixels stayed on the computer.
                        HStack(spacing: 5) {
                            Image(systemName: "photo").font(.system(size: 10, weight: .semibold))
                            Text("\(item.imageCount) image\(item.imageCount == 1 ? "" : "s") attached")
                        }
                        .font(Grok.mono(10, .medium))
                        .foregroundStyle(Grok.textDim)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
                    }
                    if !item.text.isEmpty {
                        Text(item.text)
                            .font(Grok.sans(15))
                            .foregroundStyle(Grok.text)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Grok.raised)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Grok.hairlineStrong, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("GROK")
                // Index-keyed so streaming appends don't rebuild every segment.
                ForEach(Array(Self.segments(item.text).enumerated()), id: \.offset) { _, seg in
                    if seg.isCode {
                        CodeBlock(code: seg.text, language: seg.language)
                    } else {
                        Text(Self.markdown(seg.text))
                            .font(Grok.sans(15))
                            .foregroundStyle(Grok.text)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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

/// A fenced code block: monospace, horizontally scrollable so long lines aren't
/// wrapped into mush, with its own copy button.
struct CodeBlock: View {
    let code: String
    var language: String = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(Grok.mono(9, .medium)).tracking(0.6).foregroundStyle(Grok.textFaint)
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = code
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                        withAnimation(.easeIn(duration: 0.2)) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? Grok.accent : Grok.textDim)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            Rectangle().fill(Grok.hairline).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(Grok.mono(12))
                    .foregroundStyle(Grok.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .background(Grok.bg)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tool invocation line with a status glyph (running ▸ / done ✓ / failed ✗).
struct ToolLine: View {
    let item: ChatItem
    @State private var showOutput = false

    private var output: String? {
        guard let o = item.toolOutput, !o.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return o
    }

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
                if output != nil {
                    Button {
                        Haptics.tap()
                        withAnimation(.easeInOut(duration: 0.15)) { showOutput.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("output").font(Grok.mono(10))
                            Image(systemName: showOutput ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Grok.textFaint)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            if let output, showOutput {
                Rectangle().fill(Grok.hairline).frame(height: 1)
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Text(output)
                        .font(Grok.mono(11))
                        .foregroundStyle(item.toolStatus == "failed" ? Grok.danger.opacity(0.9) : Grok.textDim)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .frame(maxHeight: 220)
            }

            if let diff = item.diff {
                Rectangle().fill(Grok.hairline).frame(height: 1)
                DiffView(diff: diff)
            }
        }
        // A failure is exactly when you want the output without hunting for it.
        .onAppear { if item.toolStatus == "failed" { showOutput = true } }
        .onChange(of: item.toolStatus) { _, status in if status == "failed" { showOutput = true } }
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
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: ShareFile?
    @State private var confirmCompact = false
    @State private var compacting = false
    @State private var compactError: String?

    private var u: SessionUsage { vm.usage ?? SessionUsage() }
    private var session: SessionInfo { vm.session }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    context
                    tokens
                    technical
                    exportSection
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
        .sheet(item: $shareURL) { file in
            ActivityShareSheet(url: file.url)
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("EXPORT")
            Button {
                if let url = TranscriptExporter.write(session: session, items: vm.items) {
                    shareURL = ShareFile(url: url)
                }
            } label: {
                Label("Share transcript as Markdown", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PillButton(kind: .subtle))
            .disabled(vm.items.isEmpty)
        }
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

            if session.turnCount > 0, !vm.busy {
                Button { confirmCompact = true } label: {
                    HStack(spacing: 10) {
                        if compacting { ProgressView().controlSize(.small).tint(.white) }
                        Label(compacting ? "Compacting…" : "Compact into a fresh session",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(PillButton(kind: u.contextFraction > 0.85 ? .prominent : .subtle))
                .disabled(compacting)
                Text("Grok writes a handoff summary of this conversation, and a fresh session starts from it. This one stays untouched.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
                if let compactError {
                    Text(compactError).font(Grok.mono(11)).foregroundStyle(Grok.danger)
                }
            }
        }
        .alert("Compact this session?", isPresented: $confirmCompact) {
            Button("Compact") { Task { await compact() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Grok will summarize the conversation (uses some tokens), then a new session opens seeded with that summary.")
        }
    }

    private func compact() async {
        compacting = true
        compactError = nil
        defer { compacting = false }
        do {
            let fresh = try await vm.client.compact(sessionId: session.id)
            Haptics.success()
            await app.reloadSessions()
            dismiss()
            app.pendingOpenSessionId = fresh.id   // the list (or split view) opens it
        } catch {
            compactError = "Compaction failed — check the connection and try again."
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

/// Wraps a URL so `.sheet(item:)` can present the share sheet for it.
struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// UIKit share sheet (ShareLink can't be triggered from a plain Button tap).
struct ActivityShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Renders the loaded conversation as a portable Markdown file.
enum TranscriptExporter {
    static func write(session: SessionInfo, items: [ChatItem]) -> URL? {
        var md = "# \(session.displayName)\n\n"
        if let cwd = session.cwd, !cwd.isEmpty { md += "`\(cwd)` · " }
        md += "\(session.turnCount) turns · exported \(Date().formatted(date: .abbreviated, time: .shortened))\n\n---\n\n"
        for item in items {
            switch item.role {
            case .user:
                md += "**You:**"
                if item.imageCount > 0 { md += " *(\(item.imageCount) image\(item.imageCount == 1 ? "" : "s") attached)*" }
                md += "\n\n\(item.text)\n\n"
            case .assistant:
                md += "**Grok:**\n\n\(item.text)\n\n"
            case .thought:
                let quoted = item.text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }.joined(separator: "\n")
                md += "\(quoted)\n\n"
            case .tool:
                md += "`▸ \(item.text.replacingOccurrences(of: "\n", with: " ").prefix(200))`"
                md += (item.toolStatus == "failed") ? " ✗\n\n" : "\n\n"
                if let out = item.toolOutput, !out.isEmpty {
                    md += "```\n\(out)\n```\n\n"
                }
            case .permission:
                md += "*Permission: \(item.text) → \(item.decided ?? "pending")*\n\n"
            case .plan:
                md += "**Plan:**\n\n\(item.text)\n\n*(\(item.decided ?? "pending"))*\n\n"
            case .error:
                md += "> ⚠️ \(item.text)\n\n"
            case .status:
                continue
            }
        }
        let safe = session.displayName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).md")
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
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
