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
    // Text files picked from Files/iCloud. Grok can read anything on the COMPUTER,
    // so a log or a config that only exists on the phone has to travel in the prompt.
    @State private var files: [TextAttachment] = []
    @State private var importingFile = false
    @State private var fileError: String?
    /// A command that costs a full expensive turn, held until the user confirms.
    @State private var pendingCostlyCommand: String?
    // Find in this conversation. The session list searches ACROSS conversations; this
    // is the other half — a long turn buries the one command whose output you wanted.
    @State private var finding = false
    @State private var findQuery = ""
    @State private var findCursor = 0
    /// Set to jump the transcript to an item; the scroll reader owns the proxy.
    @State private var scrollTarget: UUID?
    @FocusState private var findFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var name: String { vm.session.displayName }

    var body: some View {
        ZStack {
            Grok.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                actionStrip
                if finding { findBar }
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
                        Text(name).font(Grok.sans(16, .semibold)).foregroundStyle(Grok.text).lineLimit(1)
                        Circle().fill(vm.live ? Grok.accent : Grok.textFaint).frame(width: 6, height: 6)
                            .accessibilityLabel(vm.live ? "Connected" : "Reconnecting")
                    }
                    // Context and tokens live here so they're readable at a glance,
                    // rather than only inside the details sheet. While a turn runs, so
                    // does how long it has been going — "working" says nothing about
                    // whether this is a pause or a hang.
                    HStack(spacing: 6) {
                        if let u = vm.usage, u.contextWindow > 0 {
                            Text("\(Int(u.contextFraction * 100))% ctx · \(Fmt.tokens(u.totalTokens)) tok")
                                .font(Grok.sans(11))
                                .foregroundStyle(u.contextFraction > 0.85 ? Grok.danger : Grok.textFaint)
                        }
                        if vm.busy, let started = vm.turnStartedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(verbatim: "· \(Fmt.elapsed(since: started, now: context.date))")
                                    .font(Grok.mono(9)).monospacedDigit()
                                    .foregroundStyle(Grok.textFaint)
                            }
                            .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .onAppear { vm.start() }
        .onDisappear {
            // Swiping back mid-dictation used to leave the mic hot (privacy dot on,
            // other apps' audio ducked) until the object happened to deallocate.
            if dictation.isRecording { dictation.stop() }
            vm.stop()
        }
        // The bridge stays silent while anyone is watching a session live, and a
        // backgrounded app still holds its SSE socket open. So locking the phone with a
        // session on screen meant its approval alert was never sent, not once. Drop the
        // stream when we genuinely go away, and pick it back up on return.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if dictation.isRecording { dictation.stop() }
                vm.stop()
            case .active:
                vm.start()
            default:
                break   // .inactive is a transient (control centre, call banner), not a departure
            }
        }
        .alert("Run this command?", isPresented: Binding(
            get: { pendingCostlyCommand != nil },
            set: { if !$0 { pendingCostlyCommand = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingCostlyCommand = nil }
            Button("Run") {
                if let text = pendingCostlyCommand {
                    pendingCostlyCommand = nil
                    draft = ""
                    Task { await vm.send(text) }
                }
            }
        } message: {
            Text("This one runs a long, expensive task that keeps going after you close the app.")
        }
        // The composer clears optimistically and the user bubble only arrives with the
        // turn_start event, so a send that failed took the typed message and every
        // attached photo with it. Put them back so retry is one tap.
        .onChange(of: vm.failedSend?.text) { _, _ in
            guard let failed = vm.failedSend else { return }
            if draft.trimmingCharacters(in: .whitespaces).isEmpty { draft = failed.text }
            if attachments.isEmpty {
                attachments = failed.images
                attachmentThumbs = failed.thumbnails
            }
            vm.failedSend = nil
        }
        .sheet(isPresented: $showDetails) { SessionDetailsSheet(vm: vm) }
        .sheet(isPresented: $showGit) { GitReviewSheet(client: vm.client, session: vm.session, demo: vm.isDemo) }
        .sheet(isPresented: $showFiles) { FileBrowserSheet(client: vm.client, session: vm.session) }
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPicked(items) }
        }
        .fileImporter(isPresented: $importingFile,
                      allowedContentTypes: [.plainText, .sourceCode, .json, .yaml, .xml, .commaSeparatedText, .log, .data],
                      allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .alert("Couldn't attach that file", isPresented: Binding(
            get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK", role: .cancel) { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
        .alert("Microphone access needed", isPresented: $dictation.denied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("To dictate messages, allow Microphone and Speech Recognition for TethrX in Settings.")
        }
        .alert("Dictation isn't available", isPresented: $dictation.unavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Speech recognition is off or unsupported for this language. Check Siri & Dictation in Settings.")
        }
    }

    // The session's places, as plainly labeled buttons in the app's own chip
    // language — Files (project tree), Changes (git), Session (usage/details).
    private var actionStrip: some View {
        HStack(spacing: 8) {
            if !vm.isDemo {   // these need a real computer behind them
                stripButton("Files") { showFiles = true }
                stripButton("Changes") { showGit = true }
            }
            stripButton("Session") { showDetails = true }
            stripButton("Find") {
                withAnimation(.easeOut(duration: 0.15)) { finding.toggle() }
                if finding { findFocused = true } else { findQuery = "" }
            }
            .keyboardShortcut("f", modifiers: .command)
            Spacer(minLength: 0)
            // Where grok is in its own checklist, without scrolling back to the card.
            if !vm.plan.isEmpty, vm.busy || !vm.plan.allDone {
                PlanProgressPill(entries: vm.plan)
            }
            if vm.mode == "plan" {
                Text("PLAN").font(Grok.mono(9, .bold)).tracking(0.8).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Grok.accent).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }

    // MARK: Find in this conversation

    /// Matching items, in transcript order. Cards without prose (approvals, plans)
    /// are searched on their text too — the command IS the text.
    private var findMatches: [ChatItem] {
        let q = findQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return vm.items.filter {
            $0.text.localizedCaseInsensitiveContains(q)
            || ($0.toolOutput?.localizedCaseInsensitiveContains(q) ?? false)
            || $0.planEntries.contains { $0.content.localizedCaseInsensitiveContains(q) }
        }
    }

    private var findBar: some View {
        let matches = findMatches
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Grok.textFaint)
                .accessibilityHidden(true)
            TextField("", text: $findQuery,
                      prompt: Text("find in this conversation").foregroundColor(Grok.textFaint))
                .font(Grok.mono(13)).foregroundStyle(Grok.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($findFocused)
                .submitLabel(.search)
                .onSubmit { step(+1, in: matches) }
            if !matches.isEmpty {
                Text(verbatim: "\(min(findCursor + 1, matches.count))/\(matches.count)")
                    .font(Grok.mono(11)).foregroundStyle(Grok.textDim).monospacedDigit()
                Button { step(-1, in: matches) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Grok.textDim).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Previous match"))
                Button { step(+1, in: matches) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Grok.textDim).frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Next match"))
            } else if findQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("none").font(Grok.sans(14)).foregroundStyle(Grok.textFaint)
            }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { finding = false }
                findQuery = ""
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Grok.textDim).frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Text("Close find"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14).padding(.bottom, 6)
        .onChange(of: findQuery) { _, _ in
            findCursor = 0
            if let first = findMatches.first { scrollTarget = first.id }
        }
    }

    /// Move the find cursor and scroll there, wrapping at both ends.
    private func step(_ delta: Int, in matches: [ChatItem]) {
        guard !matches.isEmpty else { return }
        findCursor = (findCursor + delta + matches.count) % matches.count
        scrollTarget = matches[findCursor].id
        Haptics.tap()
    }

    private func stripButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        // Transparent padding inside the button grows the tap area toward 44pt
        // without changing how the chip looks.
        Button { Haptics.tap(); action() } label: {
            Text(title).chip(on: false)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var transcript: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // A compacted/branched session opens empty but ISN'T amnesiac —
                        // its first message silently carries this summary. Without the
                        // card, people copied the summary over by hand.
                        if vm.items.isEmpty, let seed = vm.session.seedContext, !seed.isEmpty {
                            HandoffCard(summary: seed)
                        }
                        ForEach(vm.items) { item in
                            switch item.role {
                            case .permission:
                                PermissionCard(item: item, highlight: finding ? findQuery : "") { optionId, always, reason in
                                    Task { await vm.decide(item, optionId: optionId, always: always, reason: reason) }
                                }.id(item.id)
                            case .plan:
                                PlanCard(item: item, highlight: finding ? findQuery : "") { approved in
                                    Task { await vm.decidePlan(item, approved: approved) }
                                }.id(item.id)
                            case .tasks:
                                TaskListCard(entries: item.planEntries, highlight: finding ? findQuery : "").id(item.id)
                            default:
                                ChatBubble(item: item, highlight: finding ? findQuery : "").id(item.id)
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
                    // The sentinel is not rendered at all, which means we are scrolled
                    // well away from the bottom, not at it.
                    let bottom = minY != .greatestFiniteMagnitude && minY <= outer.size.height + 80
                    if bottom != atBottom { atBottom = bottom }
                }
                // While the find bar is open the reader is looking at a match, not at
                // the tail — a streaming turn must not drag them back down.
                .onChange(of: vm.items.count) { _, _ in if atBottom, !finding { scrollToBottom(proxy) } }
                .onChange(of: lastText) { _, _ in if atBottom, !finding { scrollToBottom(proxy) } }
                .onChange(of: vm.busy) { _, _ in if atBottom, !finding { scrollToBottom(proxy) } }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        if let pending = pendingApproval {
                            waitingPill(pending, proxy)
                        } else {
                            jumpButton(proxy)
                        }
                    }
                }
            }
        }
    }

    /// The approval grok is blocked on, if it has not been answered.
    ///
    /// A permission request ends the turn until you answer it, so it is always the
    /// last thing in the transcript — which is exactly where you are not looking
    /// when you have scrolled up to read what it did.
    private var pendingApproval: ChatItem? {
        vm.items.last { ($0.role == .permission || $0.role == .plan) && $0.decided == nil }
    }

    private func waitingPill(_ item: ChatItem, _ proxy: ScrollViewProxy) -> some View {
        Button {
            Haptics.tap()
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(item.id, anchor: .center) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
                Text("Waiting for you").font(Grok.mono(12, .semibold))
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Grok.accent, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Scrolls to the approval"))
        .padding(.trailing, 16).padding(.bottom, 12)
    }

    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Grok.text)
                .frame(width: 44, height: 44)
                .background(Grok.raisedPressed, in: Circle())
                .overlay(Circle().stroke(Grok.hairlineStrong, lineWidth: 1))
        }
        .accessibilityLabel(Text("Scroll to latest"))
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
            queuedRow
            attachmentsRow
            filesRow
            snippetsRow
            chatControls
            commandPalette
            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("", text: $draft,
                              prompt: (vm.busy ? Text("Queue a follow-up") : Text("Ask Grok anything")).foregroundColor(Grok.textFaint),
                              axis: .vertical)
                        .font(Grok.body())
                        .foregroundStyle(Grok.text)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                    // Attach a screenshot or photo; grok views the saved file.
                    if !vm.busy {
                        PhotosPicker(selection: $pickedItems, maxSelectionCount: 3, matching: .images) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(attachments.isEmpty ? Grok.textDim : Grok.accent)
                        }
                        .padding(.top, 1)
                        .accessibilityLabel("Attach images")
                    }
                    if !vm.busy {
                        Button { importingFile = true } label: {
                            Image(systemName: "paperclip")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(files.isEmpty ? Grok.textDim : Grok.accent)
                        }
                        .padding(.top, 1)
                        .accessibilityLabel("Attach a file")
                    }
                    if dictation.supported {
                        Button { dictation.toggle(base: draft) } label: {
                            Image(systemName: dictation.isRecording ? "waveform" : "mic")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(dictation.isRecording ? Grok.accent : Grok.textDim)
                                .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                        }
                        .padding(.top, 1)
                        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                        .accessibilityHint(Text("Long-press to change the dictation language"))
                        // Recognition language ≠ app language: someone using the app
                        // in English may well dictate in French.
                        .contextMenu {
                            Section("Dictation language: \(dictation.currentLanguageLabel)") {
                                ForEach(Dictation.languageChoices, id: \.id) { choice in
                                    Button {
                                        dictation.localeId = choice.id
                                        Haptics.tap()
                                    } label: {
                                        if choice.id == dictation.localeId {
                                            Label(choice.label, systemImage: "checkmark")
                                        } else {
                                            Text(choice.label)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .background(Grok.raised)
                .overlay(RoundedRectangle(cornerRadius: Grok.R.field, style: .continuous)
                    .stroke(dictation.isRecording ? Color.white.opacity(0.35) : .clear, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Grok.R.field, style: .continuous))

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
                Text(message).font(Grok.sans(15)).foregroundStyle(Grok.danger).lineSpacing(2)
                Spacer(minLength: 0)
                Button { vm.errorMessage = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Grok.textDim)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text("Dismiss error"))
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
                    CircleIconButton(system: "arrow.up", a11y: "Queue follow-up") {
                        // Must stop dictation here too, or the recogniser's next partial
                        // result refills the composer with the message just queued.
                        if dictation.isRecording { dictation.stop() }
                        let text = draft
                        draft = ""; Haptics.tap()
                        Task { await vm.enqueue(text) }
                    }
                }
                CircleIconButton(system: "stop.fill", danger: true, busy: vm.cancelling, a11y: "Stop the turn") { Task { await vm.cancel() } }
                    .keyboardShortcut(".", modifiers: .command)
            }
        } else {
            let sendable = !isEmptyDraft || !attachments.isEmpty || !files.isEmpty
            CircleIconButton(system: "arrow.up", filled: sendable, enabled: sendable, a11y: "Send") {
                submit(draft)
            }
            .keyboardShortcut(.return, modifiers: .command)
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
                                    .frame(width: 30, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .offset(x: 8, y: -8)
                            .accessibilityLabel(Text("Remove attachment"))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
            }
        }
    }

    /// Files attached to the draft, shown as removable chips beside the thumbnails.
    @ViewBuilder private var filesRow: some View {
        if !files.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files) { file in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text").font(.system(size: 10, weight: .medium))
                                .accessibilityHidden(true)
                            Text(file.name).lineLimit(1)
                            Text(file.sizeLabel).foregroundStyle(Grok.textFaint)
                            Button {
                                files.removeAll { $0.id == file.id }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(Text("Remove attachment"))
                        }
                        .font(Grok.mono(11, .medium))
                        .foregroundStyle(Grok.textDim)
                        .padding(.leading, 10)
                        .overlay(Capsule().stroke(Grok.hairlineStrong, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 14).padding(.top, 10)
            }
        }
    }

    /// Read the picked files as text. Grok reads files on the computer itself, so
    /// anything that only exists on the phone has to be carried in the prompt, which
    /// is why this is capped and why binaries are refused rather than mangled.
    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            if case .failure(let error) = result { fileError = error.localizedDescription }
            return
        }
        for url in urls.prefix(3) {
            // Files from other apps come as security-scoped URLs; reading one without
            // this is a silent permission failure.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                fileError = String(localized: "That file couldn't be read.")
                continue
            }
            guard data.count <= TextAttachment.limit else {
                fileError = String(localized: "That file is too large to send. The limit is 64 KB.")
                continue
            }
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.contains("\u{0}") else {
                fileError = String(localized: "That looks like a binary file. Only text can be sent.")
                continue
            }
            files.append(TextAttachment(name: url.lastPathComponent, text: text, bytes: data.count))
        }
        if !files.isEmpty { Haptics.tap() }
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
            // Keep a SMALL preview, not the 1600px bitmap. The renderer hands back a
            // fully decoded image (scale 1), and it was retained three times over
            // (attachmentThumbs, pendingEcho, the ChatItem) purely to be drawn at 110
            // and 64 points: roughly 4.7MB of live memory per attached photo.
            attachmentThumbs.append(Self.downscale(scaled, maxDimension: 320))
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

    // Follow-ups the computer is holding for when this turn ends; tap × to drop one.
    // They live on the bridge, so they run even if the app is closed — the chip is a
    // view of that, not the queue itself.
    @ViewBuilder private var queuedRow: some View {
        if !vm.queued.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.queued) { msg in
                        HStack(spacing: 6) {
                            Image(systemName: msg.source == "reply" ? "bell.badge" : "clock")
                                .font(.system(size: 9, weight: .semibold))
                            Text(msg.text.count > 22 ? String(msg.text.prefix(22)) + "…" : msg.text)
                                .lineLimit(1)
                            Button { Task { await vm.removeQueued(msg) } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                    .frame(width: 26, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Remove queued follow-up")
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
                    ForEach(Array(efforts.enumerated()), id: \.offset) { _, pair in
                        Button(pair.0) { Task { await vm.setConfig(effort: pair.1) } }
                    }
                } label: {
                    Label(effortLabel, systemImage: "gauge.with.dots.needle.50percent").chip(on: effectiveEffort != "high")
                }

                // Three states, not two. "Auto-approve" used to mean everything, so
                // turning it on so a long build would stop stalling on every read also
                // signed off on rm -rf, unattended.
                Menu {
                    Button("Ask each time") { Task { await vm.setApprovalPolicy("ask") } }
                    Button("Auto-approve reads only") { Task { await vm.setApprovalPolicy("reads") } }
                    Button("Auto-approve everything") { Task { await vm.setApprovalPolicy("all") } }
                } label: {
                    Label(approvalLabel, systemImage: approvalIcon).chip(on: vm.approvalPolicy != "ask")
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
                    ForEach(snippets.items) { prompt in
                        Button {
                            draft = prompt.text
                            composerFocused = true
                        } label: {
                            let label = prompt.title
                            HStack(spacing: 5) {
                                Image(systemName: "text.badge.plus").font(.system(size: 9, weight: .semibold))
                                Text(label.count > 26 ? String(label.prefix(26)) + "…" : label)
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
                        Text("skill").font(Grok.sans(8, .bold)).tracking(0.5).foregroundStyle(Grok.textFaint)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Grok.hairline, lineWidth: 1))
                    }
                }
                if !cmd.description.isEmpty {
                    Text(cmd.description).font(Grok.sans(13)).foregroundStyle(Grok.textDim)
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
        guard !text.isEmpty || !attachments.isEmpty || !files.isEmpty else { return }
        if dictation.isRecording { dictation.stop() }

        // Attached text rides along as fenced blocks, named, so grok can see what it
        // is looking at. This is a normal prompt from here on.
        if !files.isEmpty {
            let body = files.map(\.fenced).joined(separator: "\n\n")
            let images = attachments, thumbs = attachmentThumbs
            let prompt = text.isEmpty ? String(localized: "Here is a file:") + "\n\n" + body
                                      : text + "\n\n" + body
            files = []
            attachments = []
            attachmentThumbs = []
            draft = ""
            Task { await vm.send(prompt, images: images, thumbnails: thumbs) }
            return
        }

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
                    vm.errorMessage = String(localized: "Grok does not run /\(name) from here.")
                    return
                case .send:
                    // A bare /loop or /deep-research is a full, expensive turn that keeps
                    // running after you put the phone down. Confirm before spending it.
                    if command.costly {
                        pendingCostlyCommand = text
                        return
                    }
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

    /// grok advertises exactly three efforts, with high as its default. There used to be
    /// an "Auto" option mapped to the empty string, which only meant the bridge omitted
    /// the flag: grok then ran high anyway, so anyone choosing Auto believing grok would
    /// adapt was silently on the slowest and most expensive setting every turn.
    private var efforts: [(LocalizedStringKey, String)] { [("High", "high"), ("Medium", "medium"), ("Low", "low")] }
    /// Sessions stored before that fix carry "", which is high.
    private var effectiveEffort: String { vm.effort.isEmpty ? "high" : vm.effort }
    /// `.capitalized` would render the raw wire value, so the chip read "High" in every
    /// language. Map it back to the same keys the menu uses.
    private var effortLabel: LocalizedStringKey {
        switch effectiveEffort {
        case "medium": return "Medium"
        case "low":    return "Low"
        default:       return "High"
        }
    }

    private var approvalLabel: LocalizedStringKey {
        switch vm.approvalPolicy {
        case "all":   return "Auto-approve"
        case "reads": return "Reads only"
        default:      return "Ask each"
        }
    }
    private var approvalIcon: String {
        switch vm.approvalPolicy {
        case "all":   return "bolt.fill"
        case "reads": return "bolt.badge.checkmark"
        default:      return "hand.raised"
        }
    }

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
    /// "Not rendered", deliberately NOT zero.
    ///
    /// The only contributor is a sentinel inside the LazyVStack, so scrolling up far
    /// enough discards it and the aggregate falls back to this default. At zero that
    /// read as "the bottom marker is above the viewport", so `atBottom` flipped true and
    /// the next streamed token yanked the reader back down to the bottom mid-sentence.
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Animated three-dot "grok is thinking…" indicator, shown while a turn is in
/// flight and no text has streamed yet — mirrors the terminal TUI's typing dots.
/// Shown at the top of a freshly compacted or branched session: the summary it
/// carries, and the reassurance that grok gets it automatically with the first
/// message — no copy-pasting needed.
struct HandoffCard: View {
    let summary: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Grok.accent)
                    .accessibilityHidden(true)
                Text("CARRIED OVER").font(Grok.sans(13, .bold)).tracking(1.2).foregroundStyle(Grok.text)
            }
            Text("This session starts with a summary of the previous conversation. Grok receives it automatically with your first message — nothing to paste.")
                .font(Grok.mono(11)).foregroundStyle(Grok.textDim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .accessibilityHidden(true)
                    Text(expanded ? "Hide the summary" : "Read the summary")
                        .font(Grok.mono(11, .medium))
                }
                .foregroundStyle(Grok.textDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Text(summary)
                    .font(Grok.mono(11)).foregroundStyle(Grok.textDim).lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Grok.bg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Grok.hairline, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 14).padding(.top, 12)
    }
}

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
        .accessibilityElement()
        .accessibilityLabel(Text("Grok is thinking"))
    }
}

/// Renders one conversation line in the console style.
struct ChatBubble: View {
    let item: ChatItem
    /// Non-empty while the find bar is open: every occurrence is marked in place, so
    /// a match is visible where it sits rather than only counted in the toolbar.
    var highlight: String = ""

    /// Grok emits Markdown (**bold**, `code`, links). Render inline markdown while
    /// keeping line breaks; fall back to plain text on partial/streaming input.
    static func markdown(_ s: String) -> AttributedString {
        let text = s.isEmpty ? " " : s
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: opts)) ?? AttributedString(text)
    }

    /// Paint every occurrence of `query`. Returns the input untouched when there is
    /// nothing to find, so the non-searching path costs nothing.
    static func marking(_ base: AttributedString, query: String) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return base }
        var out = base
        var cursor = out.startIndex
        while cursor < out.endIndex,
              let found = out[cursor...].range(of: needle, options: [.caseInsensitive]) {
            out[found].backgroundColor = Color.white.opacity(0.22)
            out[found].foregroundColor = Grok.text
            cursor = found.upperBound
        }
        return out
    }

    private func marked(_ text: String) -> AttributedString {
        Self.marking(AttributedString(text), query: highlight)
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
                        Text(marked(item.text))
                            .font(Grok.body())
                            .foregroundStyle(Grok.text)
                            .lineSpacing(2)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(Color.white.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: Grok.R.bubble, style: .continuous))
                    }
                }
            }

        case .assistant:
            // No bubble and no "GROK" label: the reply IS the page, which is how
            // Grok's own app reads. Only what you said gets a container.
            VStack(alignment: .leading, spacing: 12) {
                // Index-keyed so streaming appends don't rebuild every segment.
                ForEach(Array(Self.segments(item.text).enumerated()), id: \.offset) { _, seg in
                    if seg.isCode {
                        CodeBlock(code: seg.text, language: seg.language)
                    } else {
                        Text(Self.marking(Self.markdown(seg.text), query: highlight))
                            .font(Grok.body())
                            .foregroundStyle(Grok.text)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .thought:
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(Grok.hairlineStrong).frame(width: 2)
                Text(marked(item.text))
                    .font(Grok.sans(15))
                    .foregroundStyle(Grok.textDim)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .tool:
            ToolLine(item: item, highlight: highlight)

        case .permission, .plan, .tasks:
            EmptyView()   // rendered by PermissionCard / PlanCard / TaskListCard above

        case .status:
            Text(item.text)
                .font(Grok.sans(12))
                .foregroundStyle(Grok.textFaint)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)

        case .error:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(Grok.danger)
                    .accessibilityHidden(true)
                Text(item.text).font(Grok.sans(15)).foregroundStyle(Grok.danger).lineSpacing(3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Grok.danger.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: Grok.R.card, style: .continuous))
        }
    }
}

/// A fenced code block: monospace, horizontally scrollable so long lines aren't
/// wrapped into mush, with its own copy button.
struct CodeBlock: View {
    let code: String
    var language: String = ""
    @State private var copied = false
    /// Tokenized off the render pass and cached: a streaming reply re-evaluates this
    /// body every 50ms, and highlighting the whole block each time would undo the
    /// buffering that made streaming smooth in the first place.
    @State private var rendered: AttributedString?

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
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Text(copied ? "Copied" : "Copy code"))
            }
            .padding(.horizontal, 10).padding(.vertical, 2)

            Rectangle().fill(Grok.hairline).frame(height: 1)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(rendered ?? AttributedString(code))
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
        .task(id: code) {
            guard Syntax.supports(language) else { rendered = nil; return }
            rendered = Syntax.highlight(code, language: language, size: 12)
        }
    }
}

/// A tool invocation line with a status glyph (running ▸ / done ✓ / failed ✗).
struct ToolLine: View {
    let item: ChatItem
    var highlight: String = ""
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
                Text(ChatBubble.marking(AttributedString(item.text), query: highlight))
                    .font(Grok.mono(12)).foregroundStyle(Grok.textDim)
                Spacer(minLength: 0)
                if output != nil {
                    Button {
                        Haptics.tap()
                        withAnimation(.easeInOut(duration: 0.15)) { showOutput.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("output").font(Grok.sans(13))
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
                    Text(ChatBubble.marking(AttributedString(output), query: highlight))
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
        // A find hit inside collapsed output is a hit you cannot see.
        .onChange(of: highlight) { _, query in
            guard query.count >= 2, let output else { return }
            if output.localizedCaseInsensitiveContains(query) { showOutput = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Grok.raised)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Monochrome unified diff for an edit tool call.
///
/// This used to print every old line, then every new line, one block under the other.
/// For grok's usual edit — a few lines changed inside forty — that meant reading two
/// nearly identical walls and finding the difference yourself. Now the two sides are
/// interleaved, untouched runs are folded away, and on a one-for-one replacement the
/// part of the line that actually changed is marked.
struct DiffView: View {
    let diff: FileDiff
    /// Rows materialize synchronously inside a plain VStack, which is a multi-second
    /// hitch on a large edit. Cap it, and let the reader ask for the rest.
    private static let previewRows = 140
    @State private var showAll = false
    @State private var result = UnifiedDiff.Result()

    private var shown: ArraySlice<UnifiedDiff.Row> {
        showAll ? result.rows[...] : result.rows.prefix(Self.previewRows)
    }
    private var hidden: Int { max(0, result.rows.count - shown.count) }
    /// Highlighting is per line, so it stays off for the very large rewrites where it
    /// would cost more than it reveals.
    private var syntax: String {
        result.rows.count <= 400 ? Syntax.language(forPath: diff.path) : ""
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            header
            ForEach(shown) { row in DiffRowView(row: row, language: syntax) }
            if hidden > 0 {
                Button { showAll = true } label: {
                    Text("Show \(hidden) more lines")
                        .font(Grok.mono(10, .medium)).foregroundStyle(Grok.textDim)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        // Aligning the two sides is real work, and the tool row re-renders whenever
        // its status or output changes. Do it once per diff, not once per layout.
        .task(id: diff) { result = UnifiedDiff.build(old: diff.oldLines, new: diff.newLines) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(Grok.textFaint)
                .accessibilityHidden(true)
            Text(diff.filename).font(Grok.mono(10, .medium)).foregroundStyle(Grok.textDim)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            if result.added > 0 {
                Text(verbatim: "+\(result.added)").font(Grok.mono(10, .semibold)).foregroundStyle(Grok.text)
                    .monospacedDigit()
            }
            if result.removed > 0 {
                Text(verbatim: "−\(result.removed)").font(Grok.mono(10, .semibold)).foregroundStyle(Grok.danger)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(diff.filename), \(result.added) lines added, \(result.removed) removed"))
    }
}

/// One line of a unified diff: gutter marker, line number, and the code itself.
struct DiffRowView: View {
    let row: UnifiedDiff.Row
    var language: String = ""

    var body: some View {
        switch row.kind {
        case .gap:
            HStack(spacing: 8) {
                Text(verbatim: "⋯").font(Grok.mono(11)).foregroundStyle(Grok.textFaint)
                    .frame(width: 10, alignment: .leading)
                    .accessibilityHidden(true)
                (row.hidden == 1 ? Text("1 unchanged line") : Text("\(row.hidden) unchanged lines"))
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 3)
        default:
            HStack(alignment: .top, spacing: 8) {
                Text(marker).font(Grok.mono(11, .bold))
                    .foregroundStyle(row.kind == .removed ? Grok.danger : (row.kind == .added ? Grok.text : Grok.textFaint))
                    .frame(width: 10, alignment: .leading)
                    .accessibilityHidden(true)
                Text(number).font(Grok.mono(9)).foregroundStyle(Grok.textFaint)
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
                    .accessibilityHidden(true)
                Text(styled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
            .background(background)
            .accessibilityLabel(Text(spoken))
        }
    }

    private var marker: String {
        switch row.kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }
    /// Numbered against the file as it now stands, so context reads as one run:
    /// only a removed line, which no longer exists, carries its old number.
    private var number: String {
        switch row.kind {
        case .removed: return row.oldNumber.map(String.init) ?? ""
        default: return row.newNumber.map(String.init) ?? ""
        }
    }
    private var background: Color {
        switch row.kind {
        case .added: return Color.white.opacity(0.06)
        case .removed: return Grok.danger.opacity(0.10)
        default: return .clear
        }
    }
    private var spoken: String {
        switch row.kind {
        case .added: return String(localized: "Added: \(row.text)")
        case .removed: return String(localized: "Removed: \(row.text)")
        default: return row.text
        }
    }

    /// Syntax-highlighted where a grammar exists, tinted by the row's side, with the
    /// changed span marked when the diff could pair the line one-for-one.
    private var styled: AttributedString {
        let text = row.text.isEmpty ? " " : row.text
        var attributed: AttributedString
        if !language.isEmpty, Syntax.supports(language), text.count < 600 {
            attributed = Syntax.highlight(text, language: language, size: 11)
            if row.kind == .removed {
                // Red is the app's only non-white ink and here it means "gone", so it
                // wins over the highlighter's ranking. The weights still carry across.
                attributed.foregroundColor = Grok.danger.opacity(0.85)
            }
        } else {
            attributed = AttributedString(text)
            attributed.font = Grok.mono(11)
            attributed.foregroundColor = row.kind == .removed ? Grok.danger.opacity(0.85)
                                       : (row.kind == .context ? Grok.textDim : Grok.text)
        }
        if let emphasis = row.emphasis {
            let characters = attributed.characters
            let count = characters.count
            let low = min(emphasis.lowerBound, count)
            let high = min(emphasis.upperBound, count)
            if low < high {
                let lower = characters.index(characters.startIndex, offsetBy: low)
                let upper = characters.index(characters.startIndex, offsetBy: high)
                attributed[lower..<upper].backgroundColor = row.kind == .removed
                    ? Grok.danger.opacity(0.28) : Color.white.opacity(0.18)
            }
        }
        return attributed
    }
}

/// Approval card for a pending permission request. Allow options render as white
/// pills, reject as outline; once decided, the buttons collapse to the outcome.
struct PermissionCard: View {
    let item: ChatItem
    var highlight: String = ""
    let onDecide: (String?, Bool, String?) -> Void   // (optionId, alwaysAllow, denyReason)

    /// Denying on its own tells Grok "no" and nothing else, so it usually tries a
    /// near-identical thing next. Typing the reason here sends it as the follow-up.
    @State private var explaining = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool
    /// "Always allow" on a card that deletes things is the one tap you cannot take
    /// back, so it asks first.
    @State private var confirmAlways = false

    private var denyOptions: [PermissionOption] { item.options.filter { !$0.isAllow } }
    /// What this command does that is worth a second look. Computed once per card.
    private var risk: CommandRisk? { CommandRisk.assess(item.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").font(.system(size: 13, weight: .semibold))
                Eyebrow("PERMISSION", comment: false)
                Spacer()
            }
            .foregroundStyle(Grok.accent)

            if let risk { riskBanner(risk) }

            Text(ChatBubble.marking(AttributedString(item.text), query: highlight))
                .font(Grok.mono(13))
                .foregroundStyle(Grok.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let decided = item.decided {
                Text(outcomeLabel(decided))
                    .font(Grok.mono(12, .semibold))
                    .foregroundStyle(Grok.textDim)
            } else if explaining, let deny = denyOptions.first {
                explainBox(deny)
            } else {
                VStack(spacing: 8) {
                    if let allow = item.options.first(where: { $0.isAllow }) {
                        Button { onDecide(allow.optionId, false, nil) } label: {
                            Text(allow.name).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .buttonStyle(PillButton(kind: .prominent))
                        Button {
                            // Destructive commands do not get a one-tap "and every
                            // one after this, unattended".
                            if risk?.level == .destructive { confirmAlways = true }
                            else { onDecide(allow.optionId, true, nil) }
                        } label: {
                            Label("Always allow", systemImage: "bolt.fill").lineLimit(1)
                        }
                        .buttonStyle(PillButton(kind: .subtle))
                        .confirmationDialog("Approve everything from now on?", isPresented: $confirmAlways, titleVisibility: .visible) {
                            Button("Always allow", role: .destructive) { onDecide(allow.optionId, true, nil) }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This session will stop asking, including for commands like this one that delete or overwrite things.")
                        }
                    }
                    ForEach(denyOptions) { opt in
                        Button { onDecide(opt.optionId, false, nil) } label: {
                            Text(opt.name).lineLimit(2).multilineTextAlignment(.center)
                        }
                        .buttonStyle(PillButton(kind: .subtle))
                    }
                    if !denyOptions.isEmpty {
                        Button {
                            explaining = true
                            reasonFocused = true
                        } label: {
                            Label("Deny & explain", systemImage: "text.bubble").lineLimit(1)
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

    /// What this command does, said plainly, above the buttons. Not a blocker and not
    /// a guess at intent — every card looks alike on a phone, and `rm -rf build` and
    /// `rm -rf ~` are one character apart.
    private func riskBanner(_ risk: CommandRisk) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: risk.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(risk.level == .destructive ? Grok.danger : Grok.text)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(risk.label)
                    .font(Grok.mono(9, .bold)).tracking(1.0)
                    .foregroundStyle(risk.level == .destructive ? Grok.danger : Grok.text)
                Text(risk.reason)
                    .font(Grok.mono(11)).foregroundStyle(Grok.textDim).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(risk.level == .destructive ? Grok.danger.opacity(0.10) : Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(risk.level == .destructive ? Grok.danger.opacity(0.45) : Grok.hairlineStrong, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    /// Deny, and say why in the same breath. The text is queued as the next message,
    /// so Grok reads the correction instead of guessing at a bare refusal.
    @ViewBuilder private func explainBox(_ deny: PermissionOption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("", text: $reason,
                      prompt: Text("why not? e.g. use the staging database instead")
                          .foregroundColor(Grok.textFaint),
                      axis: .vertical)
                .font(Grok.mono(13))
                .foregroundStyle(Grok.text)
                .lineLimit(1...4)
                .focused($reasonFocused)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Grok.bg)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Grok.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Reason for denying")

            HStack(spacing: 8) {
                Button { explaining = false; reason = "" } label: {
                    Text("Back").lineLimit(1)
                }
                .buttonStyle(PillButton(kind: .subtle))

                Button {
                    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDecide(deny.optionId, false, trimmed.isEmpty ? nil : trimmed)
                } label: {
                    Text("Deny & send").lineLimit(1)
                }
                .buttonStyle(PillButton(kind: .prominent))
            }
        }
    }

    private func outcomeLabel(_ optionId: String) -> String {
        if optionId == "cancelled" { return String(localized: "· cancelled ·") }
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
    @State private var confirmRestart = false
    @State private var compacting = false
    @State private var compactError: String?
    @State private var confirmBranch = false
    @State private var branching = false
    @State private var branchError: String?

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

            if session.turnCount > 0, !vm.busy, !vm.isDemo {
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
                    Text(compactError).font(Grok.sans(14)).foregroundStyle(Grok.danger)
                }
            }

            if !vm.busy, !vm.isDemo {
                Button { confirmBranch = true } label: {
                    HStack(spacing: 10) {
                        if branching { ProgressView().controlSize(.small).tint(.white) }
                        Label(branching ? "Branching…" : "Branch this session",
                              systemImage: "arrow.triangle.branch")
                    }
                }
                .buttonStyle(PillButton(kind: .subtle))
                .disabled(branching)
                Text("Starts a second session that already knows everything this one knows — for trying another approach without losing this one.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
                if let branchError {
                    Text(branchError).font(Grok.sans(14)).foregroundStyle(Grok.danger)
                }
            }

            // Only while a turn is actually in flight: this is the escape hatch for one
            // that has stopped responding. Stop asks politely, and a grok that is no
            // longer reading never hears it, after which every message is refused.
            if vm.busy, !vm.isDemo {
                Button { confirmRestart = true } label: {
                    Label("Restart this session", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButton(kind: .subtle))
                Text("Use this if Grok has stopped responding. It ends the stuck turn and keeps the conversation.")
                    .font(Grok.mono(10)).foregroundStyle(Grok.textFaint).lineSpacing(2)
            }
        }
        // Deliberately not "Restart this session?": a string catalog derives its symbol
        // from the key, so that and the button's "Restart this session" collide and the
        // build fails.
        .alert("Stop the stuck turn?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { Task { await vm.restart() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The turn that is running now will end. The conversation is kept, and your next message carries on from it.")
        }
        .alert("Compact this session?", isPresented: $confirmCompact) {
            Button("Compact") { Task { await compact() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Grok will summarize the conversation (uses some tokens), then a new session opens seeded with that summary.")
        }
        .alert("Branch this session?", isPresented: $confirmBranch) {
            Button("Branch") { Task { await branch() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Worth saying plainly: an empty session costs nothing to branch, one with
            // history costs a summary turn.
            Text(session.turnCount > 0
                 ? "Grok will summarize this conversation (uses some tokens) so the new session starts with the same context. This session keeps running as it is."
                 : "A second session opens with the same folder and settings.")
        }
    }

    private func branch() async {
        branching = true
        branchError = nil
        defer { branching = false }
        do {
            let fresh = try await vm.client.branch(sessionId: session.id)
            Haptics.success()
            await app.reloadSessions()
            dismiss()
            app.pendingOpenSessionId = fresh.id
        } catch {
            branchError = String(localized: "Couldn't branch this session — check the connection and try again.")
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
            row("Model", u.lastModelId.isEmpty ? (session.model?.isEmpty == false ? session.model! : String(localized: "grok default")) : u.lastModelId)
            row("Reasoning effort", vm.effort.isEmpty ? String(localized: "auto") : vm.effort)
            row("Plan mode", vm.planMode ? String(localized: "on") : String(localized: "off"))
            row("Auto-approve", vm.autoApprove ? String(localized: "on") : String(localized: "off"))
            row("Transport", session.transport ?? "acp")
            row("Directory", session.cwd.map { ($0 as NSString).lastPathComponent } ?? "—")
            row("Session ID", String(session.id.prefix(8)))
        }
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack {
            Text(k).font(Grok.sans(15)).foregroundStyle(Grok.textDim)
            Spacer()
            Text(v).font(Grok.sans(15)).foregroundStyle(Grok.text).lineLimit(1).truncationMode(.middle)
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
            case .tasks:
                md += "**Checklist** (\(item.planEntries.completedCount)/\(item.planEntries.count)):\n\n"
                for entry in item.planEntries {
                    md += "- [\(entry.isDone ? "x" : " ")] \(entry.content)\(entry.isActive ? "  ← in progress" : "")\n"
                }
                md += "\n"
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
    var highlight: String = ""
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard.fill").font(.system(size: 13, weight: .semibold))
                Eyebrow("PLAN", comment: false)
                Spacer()
            }
            .foregroundStyle(Grok.accent)

            Text(ChatBubble.marking(ChatBubble.markdown(item.text), query: highlight))
                .font(Grok.sans(14))
                .foregroundStyle(Grok.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let decided = item.decided {
                (decided == "approved" ? Text("✓ Approved — building") : Text("✗ Kept planning"))
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
